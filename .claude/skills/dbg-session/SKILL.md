---
name: dbg-session
description: Управление отладчиком 1С:Предприятие 8.5 через MCP-сервер 1c-debug и сервер отладки кластера (dbgs/RDBG) — точки останова по имени модуля, останов, стек, eval/locals, шаги, останов на исключении, без EDT и кликов. Используй когда нужно отладить серверный код 1С: поймать выполнение процедуры, посмотреть значения переменных, понять почему падает обмен, фоновая задача или HTTP-сервис, запустить отладочный MCP-сервер.
argument-hint: <ensure|status|start|stop|targets|bp-set|wait|locals|eval|step|rte|auto-attach|raw> [--base <alias>]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /dbg-session — отладчик 1С 8.5 через MCP 1c-debug

Отладка серверного кода 1С:Предприятие 8.5 через штатный сервер отладки кластера
(`dbgs.exe`, протокол RDBG поверх HTTP). Конфигуратор и EDT не нужны, клиентские клики —
тоже: цель отладки создаёт любой живой сеанс базы, включая HTTP/SOAP-вызов и фоновое
задание.

## Два способа работы

1. **MCP-инструменты плагина `1c-debug`** — если в сессии видны `debug_status`,
   `session_start`, `breakpoints_set`, `wait_stop`, `eval`, `locals`, `step`. Это
   предпочтительный путь: вызывай инструменты напрямую.
2. **CLI-обёртка** `${CLAUDE_SKILL_DIR}/scripts/dbg.py` — те же инструменты через
   HTTP-MCP `http://127.0.0.1:8123/mcp`. Нужна, когда MCP-сервер не подключён к агенту,
   но работает как процесс, либо когда удобнее шелл.

Оба пути эквивалентны: CLI — тонкий JSON-RPC клиент к тому же серверу.

## Предпосылки

- Кластер 1С запущен с `ragent -debug` — тогда поднимается `dbgs.exe` (по умолчанию
  порт 1550).
- Для безголового сценария база опубликована: веб-сервисы `/ws/`, HTTP-сервисы `/hs/`
  или OData. Иначе серверный код нечем вызвать.
- Для точек по имени модуля нужна XML-выгрузка конфигурации (каталог с
  `ConfigDumpInfo.xml`) — путь передаётся в `--config` или берётся из `V8_CONFIG_SRC`.
- Пароль сервера отладки — только через `DBGSRV_PASSWORD`/`DBGSRV_USER` окружения или
  аргументы `start`. В командную строку и в переписку его не кладут.

## Запуск MCP-сервера

```bash
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" ensure
```

`ensure` проверяет `http://127.0.0.1:8123/`; если сервер не отвечает — ищет репозиторий
`1c-debug-mcp` (в порядке: `--home`, `V8_DEBUG_MCP_HOME`, ключ `debugMcpHome` или
`tools.debugMcpHome` в `.v8-project.json`) и запускает
`qoder-1c-debug/server/debug_mcp_http.py` отдельным процессом.

Если репозитория нет — скачай публичный: <https://github.com/MaxVMarkov/1c-debug-mcp>
(или поставь плагин `1c-debug` из ZIP релиза и запусти `scripts/start-server.ps1`).

## Типовой порядок вызовов

Обычный сценарий (есть клиентский сеанс, фоновое задание или уже идущий вызов):

```
status                                   — жив ли dbgs, какие сеансы открыты
start --base <alias>                     — attachDebugUI + фоновый сбор событий
bp-set --base <alias> --config <dump> --module "CommonModule.Х:42"
wait --base <alias> --timeout 60         — кадры стека, строка, аргументы
locals --base <alias>; eval --base <alias> --expr "Х = Истина"
step --base <alias> --action Continue
stop --base <alias>                      — detachDebugUI (обязательно)
```

Безголовый сценарий (клиента нет вообще):

```
start --base <alias>
auto-attach --base <alias>               — Server, JOB, WEBService, HTTPService
rte --base <alias> --on                  — останов на любом исключении языка
# ... HTTP/SOAP-вызов опубликованного сервиса базы ...
wait --base <alias>                      — кадр даёт moduleID/objectID/propertyID/version
step --base <alias> --action Continue; rte --base <alias> --off
bp-set --base <alias> --config <dump> --module "CommonModule.Х:71"
# ... тот же вызов -> останов уже обычной точкой ...
stop --base <alias>
```

## Команды CLI

| Команда | MCP-инструмент | Назначение |
|---|---|---|
| `ensure` | — | проверить/поднять HTTP-MCP сервер на `:8123` |
| `status` | `debug_status` | жив ли `dbgs`, какие сеансы открыты (CLI-вызов — без `--base`) |
| `start` / `stop` | `session_start` / `session_stop` | подключить/отключить отладочный UI |
| `targets` | `targets` | снимок целей (цель живёт в снимке дольше сеанса) |
| `attach` | `target_attach` | присоединить/отсоединить цель (`--detach`) |
| `bp-list` | `breakpoints_list` | точки из рабочего листа конфигуратора |
| `bp-set` | `breakpoints_set` | точка по имени модуля или явная тройка GUID |
| `bp-clear` | `breakpoints_clear` | снять все точки базы |
| `wait` | `wait_stop` | дождаться останова, вернуть стек |
| `locals` | `locals` | локальные переменные и параметры кадра |
| `eval` | `eval` | вычислить выражение в кадре |
| `set-var` | `set_variable` | присвоить значение (с перечитыванием) |
| `step` | `step` | `Step`, `StepIn`, `StepOut`, `Continue` |
| `rte` | `stop_on_error` | останов на ран-тайм ошибке (`--on`/`--off`) |
| `auto-attach` | `auto_attach_targets` | авто-присоединение короткоживущих целей |
| `raw <tool>` | любой | вызов инструмента с JSON в `--json` |

Подробности и формы аргументов:

```bash
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" bp-set --help
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" raw --help
```

## Примеры

Точка по имени модуля и ожидание останова:

```bash
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" ensure
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" start --base demo-base
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" bp-set --base demo-base \
  --config "D:/dump/cf" --module "CommonModule.ОбменДаннымиСлужебный:459"
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" wait --base demo-base --timeout 120
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" locals --base demo-base
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" step --base demo-base --action Continue
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" stop --base demo-base
```

Явная тройка вместо имени (если выгрузки нет):

```bash
python "${CLAUDE_SKILL_DIR}/scripts/dbg.py" bp-set --base demo-base \
  --module-json '[{"objectID":"…","propertyID":"…","version":"…","lines":[42]}]'
```

## Правила

- **`stop` в конце обязателен.** Незакрытый UI держит базу в `ibInDebug` 90–150 с и
  блокирует следующие `attach`.
- **Одно вычисление за раз.** `eval` и `locals` параллельно на одном UI утаскивают чужое
  событие `exprEvaluated`; сервер сериализует их локом, но не запускай их из двух
  процессов одновременно.
- **`rte --off` обязателен** после включения, иначе база будет вставать на каждой ошибке.
- `wait` без останова — это не ошибка: проверь, что код действительно выполняется и что
  цель присоединена (`targets`, поле `attachedByThisUI`).
- На строке, которая уже вызвала исключение, `Step` повторно выполняет её и роняет сеанс:
  используй `Continue` или точку выше по коду.
- **Цель отладки даёт клиентский сеанс, не COM.** Вызов через `V85.COMConnector` цель не создаёт:
  `attach` уходит в `targetQuit`, точка не реализуется. Серверный код, дёргаемый из COM, отлаживайте
  из клиентского сеанса: `/DEBUG /Execute <epf>` с задержкой вызова (`ПодключитьОбработчикОжидания`,
  20–25 с), стартовать сеанс в стартовом окне, затем `attach` и `wait`.
- **`version` в тройке точки — реальный `configVersion` модуля** из `ConfigDumpInfo.xml`; нулевой
  платформа принимает только для именованных точек, и с ним точка часто молчит. Для модуля объекта
  документа propertyID — `a637f77f-3840-441d-a1c3-699c8c5cb7e0`, версию берите по строке
  `<Metadata name="Документ.Х.ObjectModule">`.
- **Встроенный резолвер вида модулей перепутан** (`не в таблице констант`) — ставьте точку через
  `--module-json` с тройкой objectID/propertyID/version.
- Незакрытый или убитый отладочный UI держит базу в `ibInDebug` 90–150 с, `start` отвечает «база
  занята» — выжди ~120 с или перезапусти процесс `dbgs.exe` (ragent поднимет его сам).
- Пока стоишь на точке, запись того же объекта из другого процесса падает «Конфликт блокировок»
  (таймаут транзакции): сначала `Continue`, затем `stop`, и только потом писать.

### Запуск клиентского сеанса под отладку

- Диалог «Работа программы в режиме толстого клиента невозможна» — штатный для управляемых
  конфигураций, а не сбой: жмите «ОК» UIA-инвоком по элементу-кнопке (в дереве окна — кнопка с
  именем «ОК»), затем стартуйте сеанс инвоком пункта «1С:Предприятие» в стартовом окне.
- Снимки окон — `PrintWindow(hwnd, hdc, 2)` с флагом `PW_RENDERFULLCONTENT`: обычный снимок
  управляемого окна чёрный.
- `/Execute` обработки срабатывает до появления цели отладки — закладывайте задержку в форму
  (`ПодключитьОбработчикОжидания("Вызвать", 20)`), а путь к EPF проверяйте до запуска: битый путь
  роняет клиент диалогом «Файл не обнаружен».

## Ограничения

- Клиентский код (`Client`/`ManagedClient`/`WEBClient`) недостижим: это канал EDT и
  WebSocket. Отлаживается сервер: `Server`, `JOB`, `WEBService`, `HTTPService`.
- `propertyID` для `RecordSetModule`/`ValueManagerModule` снимается только с кадра
  останова — статически из поставки не извлекается.
- `version` для `--module-json` нужен настоящий: пустая версия принимается, но точка молчит.

## Документация

- Репозиторий и плагин: <https://github.com/MaxVMarkov/1c-debug-mcp>
- Спецификация RDBG по кадрам: `docs/rdbg-protocol-2026-10-09.md` в том же репозитории.
- Инструменты и их контракты: `qoder-1c-debug/README.md`.
