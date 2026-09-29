---
name: db-load-git
description: Загрузка изменений из Git в базу 1С. Используй когда нужно загрузить изменения из гита, обновить базу из репозитория, partial load из коммита
argument-hint: "[database] [source]"
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-load-git — Загрузка изменений из Git

Определяет изменённые файлы конфигурации по данным Git и выполняет частичную загрузку в информационную базу.

> Если в изменениях есть `Configuration.xml`, платформа выполнит **полную загрузку конфигурации**, а не только изменённых объектов.

> Удалённый объект уйдёт из базы, только если удалён и из состава владельца (`ChildObjects` объекта или `Configuration.xml`). Удалённый файл-часть объекта (модуль, файлы `Ext/`) загрузкой частями не удаляется: скрипт перечислит такие удаления в `[ВНИМАНИЕ]`, а если кроме них загружать нечего, завершится ошибкой. Применить их можно только полной загрузкой (`/db-load-xml -Mode Full`); чтобы убрать код модуля, достаточно оставить файл пустым.

## Usage

```
/db-load-git [database]
/db-load-git dev                              — все незафиксированные изменения
/db-load-git dev -Source Staged               — только staged
/db-load-git dev -Source Commit -CommitRange "HEAD~3..HEAD"
/db-load-git dev -DryRun                      — только показать что будет загружено
```

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта и разреши базу:
1. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
2. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
3. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
4. Если ветка не совпала — используй `default`
Платформа — `v8path` найденной записи базы, иначе корневой `v8path`. Не задан ни там, ни там — `-V8Path` не передавай.
Если файла нет — предложи `/db-list add`.
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.
Если в записи базы указан `configSrc` — используй как каталог конфигурации.

## Команда

```powershell
python ".agents/skills/db-load-git/scripts/db-load-git.py" <параметры>
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
| `-ConfigDir <путь>` | да | Каталог XML-выгрузки (git-репозиторий) |
| `-Source <источник>` | нет | `All` (по умолч.) / `Staged` / `Unstaged` / `Commit` |
| `-CommitRange <range>` | для Commit | Диапазон коммитов (напр. `HEAD~3..HEAD`) |
| `-Extension <имя>` | нет | Загрузить в расширение |
| `-NoApplyCheck` | нет | Не проверять применимость расширения после загрузки |
| `-Format <формат>` | нет | `Hierarchical` (по умолч.) / `Plain` |
| `-DryRun` | нет | Только показать что будет загружено (без загрузки) |
| `-UpdateDB` | нет | После загрузки сразу обновить конфигурацию БД (`/UpdateDBCfg`) |
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

Если `-UpdateDB` не был указан — **предложить `/db-update`** для применения изменений к БД

## Примеры

```powershell
# Все незафиксированные изменения
python ".agents/skills/db-load-git/scripts/db-load-git.py" -V8Path "C:\Program Files\1cv8\8.3.25.1257\bin" -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\WS\cfsrc" -Source All -UpdateDB

# Из диапазона коммитов
python ".agents/skills/db-load-git/scripts/db-load-git.py" -InfoBasePath "C:\Bases\MyDB" -ConfigDir "C:\WS\cfsrc" -Source Commit -CommitRange "HEAD~3..HEAD"

# То же через ibcmd: адреса кластера у него нет, нужны прямые реквизиты СУБД
python ".agents/skills/db-load-git/scripts/db-load-git.py" -V8Path "C:\Program Files\1cv8\8.5.1.1529\bin\ibcmd.exe" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Dev" -UserName "Admin" -Password "secret" -Dbms MSSQLServer -DbServer "db01" -DbName "MyApp_Dev" -DbUser sa -DbPassword "…" -ConfigDir "C:\WS\cfsrc" -Source All
```
