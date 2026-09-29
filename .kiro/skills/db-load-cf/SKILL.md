---
name: db-load-cf
description: Загрузка конфигурации 1С из CF-файла. Используй когда нужно загрузить конфигурацию из CF, восстановить из бэкапа CF
argument-hint: <input.cf> [database]
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-load-cf — Загрузка конфигурации из CF-файла

Загружает конфигурацию из бинарного CF-файла в информационную базу.

## Usage

```
/db-load-cf <input.cf> [database]
/db-load-cf config.cf dev
```

> **Внимание**: загрузка CF **полностью заменяет** конфигурацию в базе. Перед выполнением запроси подтверждение у пользователя.

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта и разреши базу:
1. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
2. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
3. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
4. Если ветка не совпала — используй `default`
Платформа — `v8path` найденной записи базы, иначе корневой `v8path`. Не задан ни там, ни там — `-V8Path` не передавай.
Если файла нет — предложи `/db-list add`.
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.

## Команда

```powershell
powershell.exe -NoProfile -File ".kiro/skills/db-load-cf/scripts/db-load-cf.ps1" <параметры>
```

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-V8Path <путь>` | нет | Каталог bin платформы, или полный путь к `1cv8.exe` / `ibcmd.exe` |
| `-InfoBasePath <путь>` | * | Файловая база |
| `-InfoBaseServer <сервер>` | * | Сервер 1С (для серверной базы) |
| `-InfoBaseRef <имя>` | * | Имя базы на сервере |
| `-UserName <имя>` | нет | Имя пользователя |
| `-Password <пароль>` | нет | Пароль |
| `-Dbms <вид>` | нет | Вид СУБД серверной базы: `MSSQLServer` / `PostgreSQL` / `IBMDB2` / `OracleDatabase` |
| `-DbServer <сервер>` | нет | Сервер СУБД |
| `-DbName <имя>` | нет | Имя базы в СУБД |
| `-DbUser <имя>` | нет | Пользователь СУБД |
| `-DbPassword <пароль>` | нет | Пароль пользователя СУБД |
| `-InputFile <путь>` | да | Путь к CF-файлу |
| `-Extension <имя>` | нет | Загрузить как расширение |
| `-NoApplyCheck` | нет | Не проверять применимость расширения после загрузки |
| `-AllExtensions` | нет | Загрузить все расширения из архива |
| `-AdditionalV8Arguments <список>` | нет | Доп. аргументы запуска `1cv8.exe` через запятую, напр. `/UseHwLicenses+` |
| `-AdditionalIbcmdArguments <список>` | нет | Доп. аргументы `ibcmd` через запятую, в форме `--ключ=значение` |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`

Реквизиты СУБД (`-Db*`) нужны только `ibcmd`: у него нет адреса кластера, и к серверной базе он
подключается напрямую к СУБД. Конфигуратор берёт серверную базу из пары `-InfoBaseServer` +
`-InfoBaseRef`, поэтому при движке `1cv8` и при файловой базе навык на эти параметры отказывает.
В реестре баз реквизиты лежат в блоке `databases[].dbms` (`kind` / `server` / `name` / `user` /
`password`) — явные параметры сильнее реестра. `-UserName`/`-Password` — вход в саму ИБ,
`-DbUser`/`-DbPassword` — вход в СУБД; это разные учётные записи.
Без `-UserName` `ibcmd` не выполняет команду, а требует вход в ИБ у консоли (закрытый stdin его
не останавливает): навык прерывает такой запуск через 10 с.

## После выполнения

**Предложи выполнить `/db-update`** — загрузка CF обновляет только «основную» конфигурацию конфигуратора, для применения к БД нужен `/UpdateDBCfg`

## Примеры

```powershell
# Файловая база
powershell.exe -NoProfile -File ".kiro/skills/db-load-cf/scripts/db-load-cf.ps1" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -InputFile "C:\backup\config.cf"

# Серверная база
powershell.exe -NoProfile -File ".kiro/skills/db-load-cf/scripts/db-load-cf.ps1" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Test" -UserName "Admin" -Password "secret" -InputFile "config.cf"

# То же через ibcmd: адреса кластера у него нет, нужны прямые реквизиты СУБД
powershell.exe -NoProfile -File ".kiro/skills/db-load-cf/scripts/db-load-cf.ps1" -V8Path "C:\Program Files\1cv8\8.5.1.1529\bin\ibcmd.exe" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Test" -UserName "Admin" -Password "secret" -Dbms MSSQLServer -DbServer "db01" -DbName "MyApp_Test" -DbUser sa -DbPassword "…" -InputFile "config.cf"

# Загрузка расширения
powershell.exe -NoProfile -File ".kiro/skills/db-load-cf/scripts/db-load-cf.ps1" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -InputFile "ext.cfe" -Extension "МоёРасширение"
```
