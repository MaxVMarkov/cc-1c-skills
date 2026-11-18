---
name: db-version
description: Версии расширений конфигурации в базе и актуальная версия самой конфигурации. Используй когда нужно узнать версию конфигурации/расширений, проверить актуальность XML-выгрузки, отследить дрейф версии после обновления или перезаливки базы
argument-hint: <ext-list|config-version> [database] [-ConfigDir <каталог выгрузки>] [-OutFile <файл>]
allowed-tools:
  - Bash
  - Read
  - Glob
---

# /db-version — версии конфигурации и расширений

## Почему версия конфигурации — через выгрузку

В СУБД релиза конфигурации нет. Файл `version` таблицы `Config` хранит идентификатор
формата (`{216,0,{80327,0}}`), а не «11.5.27.47»; ни `ibcmd`, ни SQL версии конфигурации
не отдают. Единственный надёжный путь — обновить существующую XML-выгрузку режимом
`Changes` (`/db-dump-xml`) и прочитать `<Version>` из `Configuration.xml` до и после.
Расхождение до/после и есть дрейф. Версии расширений, наоборот, отдаёт `ibcmd` напрямую.

## Команды

| Команда | Что делает |
|---|---|
| `ext-list` | Подключённые расширения с версиями (`ibcmd infobase config extension list`) |
| `config-version` | Тихая выгрузка `Changes` в `-ConfigDir` и вывод версии до/после + `DRIFT=yes/no` |

## Параметры подключения

База — из `.v8-project.json` вверх от текущей папки (id / ref / name / алиас), либо
`-InfoBaseServer` + `-InfoBaseRef`, либо `-InfoBasePath`. Учётка ИБ — `-UserName`/`-Password`,
иначе `HKCU\Environment\V8_DB_USER` / `V8_DB_PASS`. Пароль в вывод не попадает.

## Команда

```powershell
powershell.exe -NoProfile -File ".qoder/skills/db-version/scripts/db-version.ps1" ext-list -InfoBaseRef <база> -OutFile <файл>
powershell.exe -NoProfile -File ".qoder/skills/db-version/scripts/db-version.ps1" config-version -InfoBaseRef <база> -ConfigDir <каталог> -OutFile <файл>
```

| Параметр | Описание |
|---|---|
| `-Command` | `ext-list` или `config-version` (позиция 0) |
| `-ConfigDir` | Обязателен для `config-version`: существующая выгрузка с `ConfigDumpInfo.xml` |
| `-InfoBaseRef` | База из реестра |
| `-InfoBaseServer`, `-InfoBasePath` | Соединение мимо реестра |
| `-UserName`, `-Password` | Учётка базы |
| `-OutFile` | Отчёт в UTF-8-файл; без него кириллица в консоли ломается |

## Формат вывода config-version

```
CONFIG_VERSION_BEFORE=11.5.27.47
CONFIG_VERSION_AFTER=11.5.27.47
DRIFT=no
```

`DRIFT=unknown` — одна из сторон пустая (в выгрузке не было `<Version>`); `DRIFT=yes` —
версия изменилась, выгрузка обновлена и её содержимое теперь соответствует базе.

## Требования и грабли

- `config-version` работает только с **существующей** выгрузкой: режим `Changes` опирается на
  `ConfigDumpInfo.xml`. Нет выгрузки — сперва `/db-dump-xml -Mode Full`.
- `ext-list` требует `ibcmd` рядом с платформой (не во всех установках он есть) и блок `dbms`
  в записи базы для серверной базы (подключение идёт через СУБД, пароль — `SQL_DB_PASS`).
- ibcmd без учётки ИБ виснет на консольном приглашении входа: без `-UserName`/`V8_DB_USER`
  навык отказывает.
- Мёртвый процесс в `lock.pid` (`%LOCALAPPDATA%\1C\1cv8\standalone-server`) блокирует любые
  следующие запуски ibcmd — навык снимает файл, если его pid не жив.
- В режиме `extension` у ibcmd нет `--user`, вход передаётся только через
  `infobase config extension list` (сам навык так и делает).

## Смежное

| Задача | Навык |
|---|---|
| Полная выгрузка на чистом каталоге | `/db-dump-xml -Mode Full` |
| Сравнить состав расширений с выгрузкой | `/cfe-diff`, `/db-cfe-admin list` |
| Прочитать данные из СУБД без 1С | `/db-sql-read` |
