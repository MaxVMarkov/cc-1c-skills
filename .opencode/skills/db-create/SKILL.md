---
name: db-create
description: Создание информационной базы 1С. Используй когда нужно создать базу, новую ИБ, пустую базу
argument-hint: <path|name>
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - AskUserQuestion
---

# /db-create — Создание информационной базы

Создаёт новую информационную базу 1С (файловую или серверную) и предлагает зарегистрировать в `.v8-project.json`.

## Usage

```
/db-create <path>                   — файловая база по указанному пути
/db-create <server>/<name>          — серверная база
/db-create                          — интерактивно
```

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта. Платформа — `v8path` записи создаваемой базы,
если она уже в реестре, иначе корневой `v8path`. Не задан ни там, ни там — `-V8Path` не передавай.
После создания базы предложи зарегистрировать через `/db-list add`.

## Команда

```powershell
python ".opencode/skills/db-create/scripts/db-create.py" <параметры>
```

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-V8Path <путь>` | нет | Каталог bin платформы, или полный путь к `1cv8.exe` / `ibcmd.exe` |
| `-InfoBasePath <путь>` | * | Путь к файловой базе |
| `-InfoBaseServer <сервер>` | * | Сервер 1С (для серверной базы) |
| `-InfoBaseRef <имя>` | * | Имя базы на сервере |
| `-Dbms <вид>` | нет | Вид СУБД серверной базы: `MSSQLServer` / `PostgreSQL` / `IBMDB2` / `OracleDatabase` |
| `-DbServer <сервер>` | нет | Сервер СУБД |
| `-DbName <имя>` | нет | Имя базы в СУБД |
| `-DbUser <имя>` | нет | Пользователь СУБД |
| `-DbPassword <пароль>` | нет | Пароль пользователя СУБД |
| `-UseTemplate <файл>` | нет | Создать из шаблона (.cf или .dt) |
| `-AddToList` | нет | Добавить в список баз 1С |
| `-ListName <имя>` | нет | Имя базы в списке |
| `-AdditionalV8Arguments <список>` | нет | Доп. аргументы запуска `1cv8.exe` через запятую, напр. `/UseHwLicenses+` |
| `-AdditionalIbcmdArguments <список>` | нет | Доп. аргументы `ibcmd` через запятую, в форме `--ключ=значение` |

> `*` — нужен либо `-InfoBasePath`, либо пара `-InfoBaseServer` + `-InfoBaseRef`,
> либо для `ibcmd` — прямые реквизиты СУБД (`-Dbms` + `-DbServer` + `-DbName`)

Реквизиты СУБД (`-Db*`) нужны только `ibcmd`: у него нет адреса кластера, и серверную базу он
создаёт прямым подключением к СУБД. Конфигуратор серверную базу достигает через пару
`-InfoBaseServer` + `-InfoBaseRef`, поэтому при движке `1cv8` и при файловой базе навык на эти
параметры отказывает. В реестре баз реквизиты лежат в блоке `databases[].dbms` (`kind` / `server` /
`name` / `user` / `password`) — явные параметры сильнее реестра.

## После создания

Предложи зарегистрировать базу в `.v8-project.json` (через `/db-list add`)
3. Если указан шаблон `/UseTemplate` — предупреди что конфигурация будет загружена из шаблона

## Примеры

```powershell
# Создать файловую базу
python ".opencode/skills/db-create/scripts/db-create.py" -InfoBasePath "C:\Bases\NewDB"

# Создать серверную базу
python ".opencode/skills/db-create/scripts/db-create.py" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Test"

# То же через ibcmd: адреса кластера у него нет, нужны прямые реквизиты СУБД
python ".opencode/skills/db-create/scripts/db-create.py" -V8Path "C:\Program Files\1cv8\8.5.1.1529\bin\ibcmd.exe" -Dbms MSSQLServer -DbServer "db01" -DbName "MyApp_Test" -DbUser sa -DbPassword "…"

# Создать из шаблона CF
python ".opencode/skills/db-create/scripts/db-create.py" -InfoBasePath "C:\Bases\NewDB" -UseTemplate "C:\Templates\config.cf"

# Создать и добавить в список баз
python ".opencode/skills/db-create/scripts/db-create.py" -InfoBasePath "C:\Bases\NewDB" -AddToList -ListName "Новая база"
```
