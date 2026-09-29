---
name: db-dump-dt
description: Выгрузка информационной базы 1С в DT-файл (вся база — конфигурация + данные). Используй когда нужно выгрузить информационную базу, выгрузить архив базы, сделать бэкап, выгрузить dt
argument-hint: "[database] [output.dt]"
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-dump-dt — Выгрузка информационной базы в DT-файл

Выгружает информационную базу целиком (конфигурация **+ данные**) в DT-файл — полный снимок ИБ.

> В отличие от `/db-dump-cf` (только конфигурация), `.dt` содержит **всю базу**: данные,
> настройки, пользователей. Это бэкап/точка отката, а не выгрузка метаданных.

## Usage

```
/db-dump-dt [database] [output.dt]
/db-dump-dt dev backup.dt
/db-dump-dt                          — база по умолчанию, имя файла по базе и дате
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

## Команда

```powershell
powershell.exe -NoProfile -File ".windsurf/skills/db-dump-dt/scripts/db-dump-dt.ps1" <параметры>
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
| `-OutputFile <путь>` | да | Путь к выходному DT-файлу |
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

`ibcmd infobase dump` выгружает и данные, и это долгая операция: на 8.5.1.1529 полная выгрузка
серверной базы (~7 ГБ) обрывалась кодом 143. Для DT движок по умолчанию — конфигуратор, `ibcmd`
сюда ставят только осознанно.

## Примеры

```powershell
# Выгрузка ИБ (файловая база)
powershell.exe -NoProfile -File ".windsurf/skills/db-dump-dt/scripts/db-dump-dt.ps1" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -OutputFile "C:\backup\base.dt"

# Серверная база
powershell.exe -NoProfile -File ".windsurf/skills/db-dump-dt/scripts/db-dump-dt.ps1" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Dev" -UserName "Admin" -Password "secret" -OutputFile "base.dt"

# То же через ibcmd: адреса кластера у него нет, нужны прямые реквизиты СУБД
powershell.exe -NoProfile -File ".windsurf/skills/db-dump-dt/scripts/db-dump-dt.ps1" -V8Path "C:\Program Files\1cv8\8.5.1.1529\bin\ibcmd.exe" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Dev" -UserName "Admin" -Password "secret" -Dbms MSSQLServer -DbServer "db01" -DbName "MyApp_Dev" -DbUser sa -DbPassword "…" -OutputFile "base.dt"
```

## Связанные навыки

- `/db-load-dt` — загрузка ИБ из DT (обратная операция)
- `/db-dump-cf` — выгрузка только конфигурации (без данных)
- `/db-create` — создать новую базу (в т.ч. из DT-шаблона)
