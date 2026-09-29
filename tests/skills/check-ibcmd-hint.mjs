#!/usr/bin/env node
// Инвариант: вызов ibcmd, который подключается к базе, обязательно предупреждает о зависании.
//
// Без --user ibcmd спрашивает «Имя пользователя:» у консоли, а не у stdin: закрытый stdin его
// не останавливает, и пакетный запуск печатает строку по кругу, пока его не убьют (замерено на
// 8.5.1.1529: 9.7–13 МБ за 25–30 с — одинаково на файловой и на серверной базе). Предупреждение
// печатают оба порта: IBCMD_NOUSER_HINT в .py, $script:IbcmdNoUserHint в .ps1.
//
// Три правила:
//   1. Каждый `Write-Host "Running: ibcmd` в .ps1 через не больше трёх строк даёт строку с
//      `IbcmdNoUserHint -ForegroundColor`, и файл определяет `$script:IbcmdNoUserHint`.
//   2. Ни один `run_ibcmd(...)` не пишет `warn_no_user=False` без исключения из списка ниже —
//      молчаливый подавляющий флаг и есть способ потерять предупреждение.
//   3. `sys.stdout.write(IBCMD_NOUSER_HINT)` флашит stdout, а не stderr: подсказку печатают до
//      запуска, который собираются убить, — flush не того потока её теряет.
//
// Почему гард, а не рантайм-кейсы: зависание неотличимо в снапшоте (его надо убивать по таймеру),
// а предупреждение живёт в 12 портах — проверять каждый кейсом дороже, чем одним статическим
// правилом.
//
// Запуск: node tests/skills/check-ibcmd-hint.mjs
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');

// Поднятие базы с нуля: аутентифицироваться там не у кого, предупреждение — шум.
const SUPPRESS_OK = new Set(['db-create.ps1', 'db-create.py', 'stub-db-create.py']);
const HINT_WINDOW = 3;

const errors = [];
let psSites = 0, pyCalls = 0, hintWrites = 0;

const strip = (s) => s.replace(/^\uFEFF/, '').split(/\r?\n/);

for (const skill of readdirSync(SKILLS)) {
  const dir = join(SKILLS, skill, 'scripts');
  if (!existsSync(dir)) continue;

  for (const file of readdirSync(dir)) {
    const path = join(dir, file);
    const exempt = SUPPRESS_OK.has(file);
    if (file.endsWith('.ps1')) {
      const lines = strip(readFileSync(path, 'utf8'));
      const defines = lines.some((l) => /^\$script:IbcmdNoUserHint\s*=/.test(l));
      lines.forEach((l, i) => {
        if (!/Write-Host "Running: ibcmd/.test(l)) return;
        psSites++;
        if (exempt) return;
        const near = lines.slice(i + 1, i + 1 + HINT_WINDOW).some((n) => /IbcmdNoUserHint -ForegroundColor/.test(n));
        if (!near) {
          errors.push(`${skill}/${file}:${i + 1}: запуск ibcmd без предупреждения — следом нужна `
            + '`if (-not $UserName) { Write-Host $script:IbcmdNoUserHint -ForegroundColor Yellow }`');
        }
        if (!defines) {
          errors.push(`${skill}/${file}: используется $script:IbcmdNoUserHint, но он нигде не определён`);
        }
      });
      continue;
    }

    if (!file.endsWith('.py')) continue;
    const lines = strip(readFileSync(path, 'utf8'));
    // Вызов может быть разбит на строки, поэтому ищем литерал False в строке, где стоит
    // warn_no_user=, а не пытаемся сопоставить вызов целиком.
    lines.forEach((l, i) => {
      if (/\bdef run_ibcmd\(/.test(l)) return;
      if (/\brun_ibcmd\(/.test(l)) pyCalls++;
      if (!/warn_no_user\s*=\s*False/.test(l)) return;
      if (exempt) return;
      errors.push(`${skill}/${file}:${i + 1}: run_ibcmd подавляет предупреждение константой `
        + 'warn_no_user=False — исключение должно быть выражено признаком базы (например, база создана навыком)');
    });
    lines.forEach((l, i) => {
      if (!/sys\.stdout\.write\(IBCMD_NOUSER_HINT\)/.test(l)) return;
      hintWrites++;
      const near = lines.slice(i + 1, i + 1 + HINT_WINDOW);
      if (near.some((n) => /sys\.stderr\.flush\(\)/.test(n))) {
        errors.push(`${skill}/${file}:${i + 1}: подсказка в stdout, а флашится stderr — flush не того `
          + 'потока теряет её при убийстве зависшего процесса');
      } else if (!near.some((n) => /sys\.stdout\.flush\(\)/.test(n))) {
        errors.push(`${skill}/${file}:${i + 1}: sys.stdout.write(IBCMD_NOUSER_HINT) без sys.stdout.flush() — `
          + 'буферизованный stdout не дойдёт до убийства процесса');
      }
    });
  }
}

console.log(`Проверено: точек запуска ibcmd в .ps1 — ${psSites}, вызовов run_ibcmd в .py — ${pyCalls}, `
  + `печатей подсказки в .py — ${hintWrites}`);
if (errors.length === 0) {
  console.log('OK — каждый вызов ibcmd предупреждает о зависании, подсказка флашит свой поток.');
  process.exit(0);
}
console.log(`\n${errors.length} НАРУШЕНИЙ:`);
for (const e of errors) console.log(`  [ERROR] ${e}`);
process.exit(1);
