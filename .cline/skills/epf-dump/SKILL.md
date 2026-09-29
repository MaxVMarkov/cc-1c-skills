---
name: epf-dump
description: Разобрать EPF-файл обработки 1С (EPF/ERF) в XML-исходники. Используй когда пользователь просит разобрать, декомпилировать обработку, получить исходники из EPF/ERF файла
argument-hint: <EpfFile>
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
---

# /epf-dump — Разборка обработки

## Usage

```
/epf-dump <EpfFile> [OutDir]
```

| Параметр | Обязательный | По умолчанию | Описание                            |
|----------|:------------:|--------------|-------------------------------------|
| EpfFile  | да           | —            | Путь к EPF-файлу                    |
| OutDir   | нет          | `src`        | Каталог для выгрузки исходников     |

## Параметры подключения (обязательно)

Для разборки EPF/ERF требуется информационная база с конфигурацией. Без базы ссылочные типы безвозвратно теряются.

1. Прочитай `.v8-project.json` из корня проекта и разреши базу:
2. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
3. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
4. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
5. Если ветка не совпала — используй `default`
6. Если `.v8-project.json` нет или база не найдена — **сообщи пользователю об ошибке**. Для dump база обязательна: в пустой базе ссылочные типы (CatalogRef, DocumentRef и т.д.) безвозвратно сбрасываются в строки. Предложи указать базу или зарегистрировать через `/db-list add`.

Платформа — `v8path` найденной записи базы, иначе корневой `v8path`. Не задан ни там, ни там — `-V8Path` не передавай.
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.

## Команда

```powershell
python ".cline/skills/epf-dump/scripts/epf-dump.py" <параметры>
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
| `-InputFile <путь>` | да | Путь к EPF/ERF-файлу |
| `-OutputDir <путь>` | да | Каталог для выгрузки исходников |
| `-Format <формат>` | нет | `Hierarchical` (по умолч.) / `Plain` |
| `-AdditionalV8Arguments <список>` | нет | Доп. аргументы запуска `1cv8.exe` через запятую, напр. `/UseHwLicenses+` |
| `-AdditionalIbcmdArguments <список>` | нет | Доп. аргументы `ibcmd` через запятую, в форме `--ключ=значение` |

> `*` — обязательно хотя бы одно подключение. Без базы скрипт завершится с ошибкой (dump в пустой базе безвозвратно теряет ссылочные типы)

Реквизиты СУБД (`-Db*`) нужны только `ibcmd`: у него нет адреса кластера, и к серверной базе он
подключается напрямую к СУБД. Конфигуратор берёт серверную базу из пары `-InfoBaseServer` +
`-InfoBaseRef`, поэтому при движке `1cv8` и при файловой базе навык на эти параметры отказывает.
В реестре баз реквизиты лежат в блоке `databases[].dbms` (`kind` / `server` / `name` / `user` /
`password`) — явные параметры сильнее реестра. `-UserName`/`-Password` — вход в саму ИБ,
`-DbUser`/`-DbPassword` — вход в СУБД; это разные учётные записи.
Без `-UserName` `ibcmd` не выполняет команду, а требует вход в ИБ у консоли (закрытый stdin его
не останавливает): навык прерывает такой запуск через 10 с.

## Примеры

```powershell
# Разборка обработки (файловая база)
python ".cline/skills/epf-dump/scripts/epf-dump.py" -InfoBasePath "C:\Bases\MyDB" -InputFile "build/МояОбработка.epf" -OutputDir "src"

# Серверная база
python ".cline/skills/epf-dump/scripts/epf-dump.py" -InfoBaseServer "srv01" -InfoBaseRef "MyDB" -UserName "Admin" -Password "secret" -InputFile "build/МояОбработка.epf" -OutputDir "src"
# То же через ibcmd: адреса кластера у него нет, нужны прямые реквизиты СУБД
python ".cline/skills/epf-dump/scripts/epf-dump.py" -V8Path "C:\Program Files\1cv8\8.5.1.1529\bin\ibcmd.exe" -InfoBaseServer "srv01" -InfoBaseRef "MyDB" -UserName "Admin" -Password "secret" -Dbms MSSQLServer -DbServer "db01" -DbName "MyDB" -DbUser sa -DbPassword "…" -InputFile "build/МояОбработка.epf" -OutputDir "src"
```
