#!/usr/bin/env node
// Инвариант: вызов ibcmd без учётки предупреждён И ограничен — он не может висеть вечно.
//
// Без --user ibcmd спрашивает «Имя пользователя:» у консоли, а не у stdin: закрытый stdin его
// не останавливает, и пакетный запуск печатает строку по кругу, пока его не убьют (замерено на
// 8.5.1.1529: 9.7–13 МБ за 25–30 с; одинаково на файловой базе, на серверной и на базе, где
// пользователи вообще не заданы). Поэтому порт сам ждёт $ibTimeout секунд, убивает процесс и
// печатает, чего не хватило: -UserName и -Password.
//
// Правила для .ps1 (кроме исключений):
//   1. Каждый `Write-Host "Running: ibcmd` через не больше трёх строк даёт строку с
//      `IbcmdNoUserHint -ForegroundColor`.
//   2. В пределах шести строк от него запуск идёт с `-TimeoutSec`, а прерывание печатает
//      `$script:IbcmdAborted`. Ограничение и сообщение бессмысленны друг без друга.
//   3. Файл определяет `$script:IbcmdNoUserTimeoutSec`, `$script:IbcmdNoUserHint` и
//      `$script:IbcmdAborted`.
//
// Правила для .py:
//   4. Ни один `run_ibcmd(...)` не пишет `warn_no_user=False` без исключения — молчаливый
//      подавляющий флаг и есть способ потерять предупреждение.
//   5. `sys.stdout.write(IBCMD_NOUSER_HINT)` флашит stdout, а не stderr: подсказку печатают до
//      запуска, который собираются убить, — flush не того потока её теряет.
//   6. Тело `def run_ibcmd` ограничивает запуск (`timeout=IBCMD_NOUSER_TIMEOUT_SEC if bounded
//      else None`), перехватывает `subprocess.TimeoutExpired` и печатает `IBCMD_ABORTED`.
//
// Зависание теперь проверяется и рантайм-кейсом (cases/db-cfe-admin/list-ibcmd-hang-aborted):
// висячая заглушка ibcmd убивается по таймауту, и список берётся у Конфигуратора. Гард остаётся:
// предупреждение и ограничение живут в 12 портах, проверять каждый кейсом дороже одного правила.
//
// Запуск: node tests/skills/check-ibcmd-hint.mjs
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');

// Поднятие базы с нуля: аутентифицироваться там не у кого, предупреждение — шум, а таймаут
// обрезал бы законно долгий create.
const SUPPRESS_OK = new Set(['db-create.ps1', 'db-create.py', 'stub-db-create.py']);
const HINT_WINDOW = 3;
const CALL_WINDOW = 6;

const errors = [];
let psSites = 0, pyCalls = 0, hintWrites = 0, boundedBodies = 0;

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
      const definesTimeout = lines.some((l) => /^\$script:IbcmdNoUserTimeoutSec\s*=/.test(l));
      const definesAborted = lines.some((l) => /^\$script:IbcmdAborted\s*=/.test(l));
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
        const launch = lines.slice(i + 1, i + 1 + CALL_WINDOW);
        if (!launch.some((n) => /Invoke-PlatformProcess\b.*-TimeoutSec \$(?:ibTimeout|timeout)\b/.test(n))) {
          errors.push(`${skill}/${file}:${i + 1}: запуск ibcmd не ограничен по времени — без -UserName он `
            + 'висит вечно, вызов обязан идти с `-TimeoutSec $ibTimeout`');
        }
        if (!launch.some((n) => /Write-Host \$script:IbcmdAborted -ForegroundColor Red/.test(n))) {
          errors.push(`${skill}/${file}:${i + 1}: прерывание зависшего ibcmd ни о чём не сообщает — нужен `
            + '`if ($res.TimedOut) { Write-Host $script:IbcmdAborted -ForegroundColor Red }`');
        }
        if (!definesTimeout) {
          errors.push(`${skill}/${file}: $script:IbcmdNoUserTimeoutSec используется, но не определён`);
        }
        if (!definesAborted) {
          errors.push(`${skill}/${file}: $script:IbcmdAborted используется, но не определён`);
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
    // Тело run_ibcmd: от def до следующего def верхнего уровня.
    lines.forEach((l, i) => {
      if (!/^def run_ibcmd\(/.test(l)) return;
      let end = lines.length;
      for (let j = i + 1; j < lines.length; j++) {
        if (/^def /.test(lines[j])) { end = j; break; }
      }
      const body = lines.slice(i, end).join('\n');
      if (exempt) return;
      boundedBodies++;
      if (!/timeout=IBCMD_NOUSER_TIMEOUT_SEC if bounded else None/.test(body)) {
        errors.push(`${skill}/${file}:${i + 1}: run_ibcmd запускает ibcmd без ограничения — `
          + 'нужен `timeout=IBCMD_NOUSER_TIMEOUT_SEC if bounded else None`');
      }
      if (!/except subprocess\.TimeoutExpired/.test(body)) {
        errors.push(`${skill}/${file}:${i + 1}: run_ibcmd не перехватывает subprocess.TimeoutExpired — `
          + 'убитый по таймауту процесс выйдет исключением из навыка');
      }
      if (!/print\(IBCMD_ABORTED, end=""\)/.test(body)) {
        errors.push(`${skill}/${file}:${i + 1}: прерывание зависшего ibcmd ни о чём не сообщает — `
          + 'нужен `print(IBCMD_ABORTED, end="")`');
      }
    });
    if (!exempt && lines.some((l) => /^def run_ibcmd\(/.test(l))) {
      if (!lines.some((l) => /^IBCMD_NOUSER_TIMEOUT_SEC = /.test(l))) {
        errors.push(`${skill}/${file}: IBCMD_NOUSER_TIMEOUT_SEC используется, но не определён`);
      }
      if (!lines.some((l) => /^IBCMD_ABORTED = \(/.test(l))) {
        errors.push(`${skill}/${file}: IBCMD_ABORTED используется, но не определён`);
      }
    }
  }
}

console.log(`Проверено: точек запуска ibcmd в .ps1 — ${psSites}, вызовов run_ibcmd в .py — ${pyCalls}, `
  + `печатей подсказки в .py — ${hintWrites}, ограниченных тел run_ibcmd — ${boundedBodies}`);
if (errors.length === 0) {
  console.log('OK — каждый вызов ibcmd без учётки предупреждён и ограничен по времени.');
  process.exit(0);
}
console.log(`\n${errors.length} НАРУШЕНИЙ:`);
for (const e of errors) console.log(`  [ERROR] ${e}`);
process.exit(1);
