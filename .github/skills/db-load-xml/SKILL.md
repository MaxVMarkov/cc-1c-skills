---
name: db-load-xml
description: Загрузка конфигурации 1С из XML-файлов. Используй когда нужно загрузить конфигурацию из файлов, XML, исходников, LoadConfigFromFiles
argument-hint: <configDir> [database]
allowed-tools:
  - Bash
  - Read
  - Glob
  - AskUserQuestion
---

# /db-load-xml — Загрузка конфигурации из XML

Загружает конфигурацию в информационную базу из XML-файлов (исходников). Поддерживает полную и частичную загрузку.

## Usage

```
/db-load-xml <configDir> [database]
/db-load-xml src/config dev
/db-load-xml src/config dev -Mode Partial -Files "Catalogs/Номенклатура.xml,Catalogs/Номенклатура/Ext/ObjectModule.bsl"
```

> **Внимание**: полная загрузка **заменяет всю конфигурацию** в базе. Перед выполнением запроси подтверждение у пользователя.

## Параметры подключения

Прочитай `.v8-project.json` из корня проекта и разреши базу:
1. Если пользователь указал параметры подключения (путь, сервер) — используй напрямую
2. Если указал базу по имени — ищи по id / alias / name в `.v8-project.json`
3. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
4. Если ветка не совпала — используй `default`
Платформа — `v8path` найденной записи базы, иначе корневой `v8path`. Не задан ни там, ни там — `-V8Path` не передавай.
Если файла нет — предложи `/db-list add`.
Если использованная база не зарегистрирована — после выполнения предложи добавить через `/db-list add`.
Если в записи базы указан `configSrc` — используй как каталог загрузки по умолчанию.
Для `-Extension` каталог берётся из `extensions[].src` записи базы, если он там указан.

## Команда

```powershell
powershell.exe -NoProfile -File ".github/skills/db-load-xml/scripts/db-load-xml.ps1" <параметры>
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
| `-ConfigDir <путь>` | да | Каталог XML-исходников |
| `-Mode <режим>` | нет | `Full` (по умолч.) / `Partial` |
| `-Files <список>` | для Partial | Относительные пути файлов через запятую |
| `-ListFile <путь>` | для Partial | Путь к файлу со списком (альтернатива `-Files`) |
| `-Extension <имя>` | нет | Загрузить в расширение |
| `-AllExtensions` | нет | Загрузить все расширения (только полностью; частями — по одному через `-Extension`) |
| `-NoApplyCheck` | нет | Не проверять применимость расширения после загрузки |
| `-Format <формат>` | нет | `Hierarchical` (по умолч.) / `Plain` |
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

### Режимы загрузки

| Режим | Описание |
|-------|----------|
| `Full` | Полная загрузка — замена всей конфигурации из каталога XML |
| `Partial` | Частичная — перечисленные объекты вместе с их дочерними (формы, макеты) и `Ext/` |

> Если в список файлов включить `Configuration.xml`, платформа выполнит **полную загрузку конфигурации**, а не только перечисленных объектов.

### Формат файла списка (listFile)

Файл содержит **относительные пути к файлам** в каталоге выгрузки (один на строку), кодировка **UTF-8 с BOM**:

```
Catalogs/Номенклатура.xml
Catalogs/Номенклатура/Ext/ObjectModule.bsl
Documents/Заказ.xml
Documents/Заказ/Forms/ФормаДокумента.xml
```

## После выполнения

Если `-UpdateDB` не был указан — **предложи выполнить `/db-update`** для применения изменений к БД

## Примеры

```powershell
# Полная загрузка
powershell.exe -NoProfile -File ".github/skills/db-load-xml/scripts/db-load-xml.ps1" -V8Path "C:\Program Files\1cv8\8.3.25.1257\bin" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Full

# Частичная загрузка конкретных файлов
powershell.exe -NoProfile -File ".github/skills/db-load-xml/scripts/db-load-xml.ps1" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Partial -Files "Catalogs/Номенклатура.xml,Catalogs/Номенклатура/Ext/ObjectModule.bsl"

# Загрузка расширения
powershell.exe -NoProfile -File ".github/skills/db-load-xml/scripts/db-load-xml.ps1" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\ext_src" -Mode Full -Extension "МоёРасширение"

# Загрузка + обновление БД в одном запуске
powershell.exe -NoProfile -File ".github/skills/db-load-xml/scripts/db-load-xml.ps1" -InfoBasePath "C:\Bases\MyDB" -UserName "Admin" -ConfigDir "C:\WS\cfsrc" -Mode Full -UpdateDB

# То же через ibcmd: адреса кластера у него нет, нужны прямые реквизиты СУБД
powershell.exe -NoProfile -File ".github/skills/db-load-xml/scripts/db-load-xml.ps1" -V8Path "C:\Program Files\1cv8\8.5.1.1529\bin\ibcmd.exe" -InfoBaseServer "srv01" -InfoBaseRef "MyApp_Dev" -UserName "Admin" -Password "secret" -Dbms MSSQLServer -DbServer "db01" -DbName "MyApp_Dev" -DbUser sa -DbPassword "…" -ConfigDir "C:\WS\cfsrc" -Mode Full
```
