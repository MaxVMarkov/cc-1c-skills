# db-sql-read v0.1 — чтение таблиц 1С напрямую из MS SQL без сеанса 1С
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Прямое чтение данных информационной базы 1С из MS SQL (без запуска 1С).

.DESCRIPTION
    map        — показать таблицу и колонки объекта из сохранённой карты хранения (.1c-db-map.json)
    find-ref   — найти таблицу, где живёт строка с таким _IDRRef (это PK любой таблицы 1С)
    tables     — какие семейства таблиц в базе и сколько их (_Document*, _Reference*, _InfoRg*, …)
    find-table — найти таблицу, где живёт документ с указанным номером (по колонке _Number)
    diff       — сравнить две строки таблицы по номерам и показать отличающиеся колонки
    row        — прочитать строку таблицы по _IDRRef и показать непустые колонки
    sql        — произвольный SELECT (изменяющие конструкции отклоняются)

    Физические имена таблиц и колонок 1С выдаёт только изнутри сеанса — см. «Карта хранения»
    в SKILL.md. Здесь работаем по тому, что видно из самой СУБД: _Number, _IDRRef, _Fld<N>.

.PARAMETER Command
    tables | find-table | find-ref | diff | row | sql | map

.PARAMETER InfoBaseRef
    Имя базы из реестра .v8-project.json (ref, id или alias): оттуда берутся dbms.server,
    dbms.name, dbms.user; пароль — из записи базы, иначе из HKCU\Environment.

.PARAMETER Number
    Отображаемый номер документа, например КАТН-000758.

.PARAMETER NumberTail2
    Хвост второго номера для diff в паре с -NumberTail.

.PARAMETER NumberTail
    ASCII-безопасная замена Number: хвост номера (000758) — когда кириллицу нельзя
    передать в аргументе командной строки.

.PARAMETER Out
    Записать результат в файл UTF-8 (консоль Windows в cp866 ломает кириллицу в выводе).

.EXAMPLE
    .\db-sql-read.ps1 -Command tables -InfoBaseRef ut11-test

.EXAMPLE
    .\db-sql-read.ps1 -Command find-table -InfoBaseRef ut11-test -NumberTail 000758

.EXAMPLE
    .\db-sql-read.ps1 -Command diff -InfoBaseRef ut11-test -Table _DocumentJournal15829 `
        -Number "КАТН-000758" -Number2 "КАТН-000781" -Out result.txt

.EXAMPLE
    .\db-sql-read.ps1 -Command sql -InfoBaseRef ut11-test -Sql "SELECT COUNT(*) FROM _Document667"
#>

[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Mandatory=$false)][string]$Command,
    [Parameter(Mandatory=$false)][string]$InfoBaseRef,
    [Parameter(Mandatory=$false)][string]$Table,
    [Parameter(Mandatory=$false)][string]$Number,
    [Parameter(Mandatory=$false)][string]$Number2,
    [Parameter(Mandatory=$false)][string]$NumberTail,
    [Parameter(Mandatory=$false)][string]$NumberTail2,
    [Parameter(Mandatory=$false)][string]$Ref,
    [Parameter(Mandatory=$false)][string]$MapFile,
    [Parameter(Mandatory=$false)][string]$Object,
    [Parameter(Mandatory=$false)][string]$Field,
    [Parameter(Mandatory=$false)][string]$Sql,
    [Parameter(Mandatory=$false)][string]$ProjectFile,
    [Parameter(Mandatory=$false)][string]$Out
)
$ErrorActionPreference = 'Stop'

# Вывод идёт через Emit: Write-Host не попадает в pipeline функции и не подмешивается
# в возвращаемое значение (из-за Write-Output внутри Open-Connection $conn становился строкой).
$script:lines = New-Object System.Collections.Generic.List[string]
function Emit([string]$s) { Write-Host $s; $script:lines.Add($s) | Out-Null }
function Save-Out { if ($Out -and $script:lines.Count) { [IO.File]::WriteAllLines($Out, $script:lines, (New-Object Text.UTF8Encoding $false)) } }
function Fail([string]$m) { Emit "ОШИБКА: $m"; Save-Out; exit 1 }
function QID([string]$n) { return "[" + $n.Replace("]", "]]") + "]" }

if (-not $Command) { Fail "нужен -Command: tables | find-table | find-ref | diff | row | sql" }

# --- реестр баз: подъём вверх за .v8-project.json (тот же приём, что в db-cfe-admin) ---
function Find-V8Project([string]$startDir) {
    $d = $startDir
    for ($i = 0; $i -lt 20 -and $d; $i++) {
        $pj = Join-Path $d ".v8-project.json"
        if (Test-Path $pj) { return $pj }
        $parent = [System.IO.Path]::GetDirectoryName($d)
        if ($parent -eq $d) { break }
        $d = $parent
    }
    return $null
}

function Get-DbmsSettings([string]$Ref) {
    $pf = if ($ProjectFile) { $ProjectFile } else { Find-V8Project (Get-Location).Path }
    if (-not $pf) { return $null }
    $proj = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($db in @($proj.databases)) {
        $match = ($db.ref -eq $Ref) -or ($db.id -eq $Ref) -or (@($db.aliases) -contains $Ref)
        if ($match -and $db.dbms -and $db.dbms.kind -eq 'MSSQLServer') {
            $pwd = $db.password; $usr = $db.dbms.user
            if (-not $pwd) {
                # пароль в реестре не хранится — берём из переменных пользователя, не печатая
                $pwd = [Environment]::GetEnvironmentVariable('SQL_DB_PASS', 'User')
                $usr = [Environment]::GetEnvironmentVariable('SQL_DB_USER', 'User')
            }
            return @{ Server = $db.dbms.server; Database = $db.dbms.name; User = $usr; Password = $pwd }
        }
    }
    return $null
}

function Open-Connection {
    if (-not $InfoBaseRef) { Fail "нужен -InfoBaseRef (имя базы в .v8-project.json)" }
    $s = Get-DbmsSettings -Ref $InfoBaseRef
    if (-not $s) { Fail "база '$InfoBaseRef' не найдена в .v8-project.json как MSSQLServer (нет секции dbms?)" }
    if (-not $s.Password) { Fail "нет пароля SQL: ни в записи базы, ни в HKCU\Environment (SQL_DB_PASS)" }
    Emit ("подключение: " + $s.Server + " / " + $s.Database + " / пользователь " + $s.User)
    $c = New-Object System.Data.SqlClient.SqlConnection(
        "Server=" + $s.Server + ";Database=" + $s.Database + ";User Id=" + $s.User +
        ";Password=" + $s.Password + ";Encrypt=false")
    $c.Open()
    return $c
}

function Invoke-Query([string]$Text) {
    $cmd = $script:conn.CreateCommand(); $cmd.CommandText = $Text; $cmd.CommandTimeout = 300
    $rd = $cmd.ExecuteReader()
    $cols = @(); for ($i = 0; $i -lt $rd.FieldCount; $i++) { $cols += $rd.GetName($i) }
    Emit ($cols -join "`t")
    $rows = 0
    while ($rd.Read()) {
        $vals = @()
        for ($i = 0; $i -lt $rd.FieldCount; $i++) {
            if ($rd.IsDBNull($i)) { $vals += ""; continue }
            $v = $rd.GetValue($i)
            if ($v -is [byte[]]) { $vals += ("0x" + (($v | ForEach-Object { $_.ToString("X2") }) -join "")) }
            else { $vals += $v.ToString() }
        }
        Emit ($vals -join "`t"); $rows++
    }
    $rd.Close(); Emit ("(строк: " + $rows + ")")
}

function Format-Value($v) {
    if ($null -eq $v -or $v -is [DBNull]) { return "" }
    if ($v -is [byte[]]) { return "0x" + (($v | ForEach-Object { $_.ToString("X2") }) -join "") }
    return $v.ToString().Trim()
}

switch ($Command) {

    "tables" {
        $script:conn = Open-Connection
        Emit ""
        Emit "=== семейства таблиц (префикс -> число таблиц) ==="
        Invoke-Query @"
SELECT LEFT(t.name, PATINDEX('%[0-9]%', t.name + '0') - 1) AS prefix, COUNT(*) AS tables_no
FROM sys.tables t GROUP BY LEFT(t.name, PATINDEX('%[0-9]%', t.name + '0') - 1)
HAVING COUNT(*) > 2 ORDER BY COUNT(*) DESC
"@
        Emit ""
        Emit "=== сколько таблиц имеют колонку _Number ==="
        Invoke-Query "SELECT COUNT(*) AS with_number FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id AND c.name = '_Number'"
        $script:conn.Close()
    }

    "find-table" {
        $script:conn = Open-Connection
        if ($NumberTail) { $pat = "%" + $NumberTail; $like = $true }
        elseif ($Number) { $pat = $Number; $like = $false }
        else { Fail "нужен -Number или -NumberTail" }
        Emit ("ищем номер: " + $pat + $(if ($like) { " (LIKE по хвосту)" } else { " (точное совпадение)" }))
        $c = $script:conn.CreateCommand()
        $c.CommandText = @"
SELECT t.name FROM sys.tables t
JOIN sys.columns col ON col.object_id = t.object_id AND col.name = '_Number'
JOIN sys.types ty ON ty.user_type_id = col.user_type_id
WHERE ty.name IN ('nvarchar','varchar','nchar','char') AND t.name LIKE '[_]Document%'
ORDER BY t.name
"@
        $tables = New-Object System.Collections.Generic.List[string]
        $rd = $c.ExecuteReader(); while ($rd.Read()) { $tables.Add($rd.GetString(0)) }; $rd.Close()
        Emit ("таблиц документов с символьным _Number: " + $tables.Count)
        $hits = 0
        foreach ($t in $tables) {
            $q = $script:conn.CreateCommand()
            if ($like) { $q.CommandText = "SELECT COUNT(*) FROM " + (QID $t) + " WHERE _Number LIKE @n" }
            else { $q.CommandText = "SELECT COUNT(*) FROM " + (QID $t) + " WHERE _Number = @n" }
            [void]$q.Parameters.AddWithValue("@n", $pat)
            try { if ([int]$q.ExecuteScalar() -gt 0) { Emit ("НАЙДЕНО в: " + $t); $hits++ } } catch { }
        }
        if ($hits -eq 0) { Emit "не найдено: номер может храниться числом, а собранный номер — в таблице журнала (см. SKILL.md)" }
        $script:conn.Close()
    }

    "map" {
        # Карту хранения выдаёт только сеанс 1С: ПолучитьСтруктуруХраненияБазыДанных(объекты, Истина).
        # Здесь читаем заранее сохранённый JSON (формат — в SKILL.md) и показываем таблицу и колонки.
        if (-not $MapFile) { Fail "map: нужен -MapFile (путь к .1c-db-map.json)" }
        if (-not (Test-Path $MapFile)) { Fail ("map: файл не найден: " + $MapFile) }
        $map = Get-Content $MapFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $Object) {
            Emit ("объектов в карте: " + @($map.objects).Count)
            Emit "уточни -Object, например: Документ.ЗаказКлиента"
            exit 0
        }
        $o = @($map.objects) | Where-Object { $_.name -eq $Object } | Select-Object -First 1
        if (-not $o) { Fail ("map: объекта '" + $Object + "' в карте нет") }
        Emit ("объект   : " + $o.name)
        Emit ("таблица  : " + $o.table)
        Emit ("назначение: " + $o.purpose)
        Emit ("колонок  : " + @($o.columns).Count)
        foreach ($c in @($o.columns)) {
            if ($Field -and $c.name -ne $Field) { continue }
            Emit ("   " + $c.name + " -> " + $c.column + $(if ($c.reference) { "  (ссылка)" } else { "" }))
        }
    }

    "find-ref" {
        $script:conn = Open-Connection
        if (-not $Ref) { Fail "find-ref: нужен -Ref (0x... из _IDRRef или _DocumentRRef)" }
        $hex = $Ref.Replace("0x", "").Replace("0X", "")
        if ($hex.Length -ne 32) { Fail ("find-ref: Expected 16 bytes, got " + ($hex.Length / 2)) }
        $bytes = [byte[]]([regex]::Matches($hex, "..") | ForEach-Object { [Convert]::ToByte($_.Value, 16) })
        $c = $script:conn.CreateCommand()
        $c.CommandText = @"
SELECT t.name FROM sys.tables t
JOIN sys.columns col ON col.object_id = t.object_id AND col.name = '_IDRRef'
WHERE t.name NOT LIKE '%VT%' ORDER BY t.name
"@
        $tables = New-Object System.Collections.Generic.List[string]
        $rd = $c.ExecuteReader(); while ($rd.Read()) { $tables.Add($rd.GetString(0)) }; $rd.Close()
        Emit ("таблиц с _IDRRef: " + $tables.Count + " ; ищем " + $Ref)
        $hits = 0
        foreach ($t in $tables) {
            $q = $script:conn.CreateCommand()
            $q.CommandText = "SELECT COUNT(*) FROM " + (QID $t) + " WHERE _IDRRef = @r"
            $p2 = $q.Parameters.Add("@r", [System.Data.SqlDbType]::VarBinary, 16); $p2.Value = $bytes
            try { if ([int]$q.ExecuteScalar() -gt 0) { Emit ("НАЙДЕНО в: " + $t); $hits++ } } catch { }
        }
        if ($hits -eq 0) { Emit "ни одна таблица не содержит этот _IDRRef" }
        $script:conn.Close()
    }

    "diff" {
        $script:conn = Open-Connection
        if (-not $Table) { Fail "diff: нужен -Table" }
        if ($Number -and $Number2) {
            $a = $Number; $b = $Number2
        } elseif ($NumberTail -and $NumberTail2) {
            # номера достаём из таблицы: аргументом передаём только ASCII-хвосты
            $f = $script:conn.CreateCommand()
            $f.CommandText = "SELECT DISTINCT _Number FROM " + (QID $Table) + " WHERE _Number LIKE @ta OR _Number LIKE @tb"
            [void]$f.Parameters.AddWithValue("@ta", "%" + $NumberTail)
            [void]$f.Parameters.AddWithValue("@tb", "%" + $NumberTail2)
            $found = @(); $rdf = $f.ExecuteReader()
            while ($rdf.Read()) { $found += $rdf.GetValue(0).ToString().Trim() }
            $rdf.Close()
            $a = $found | Where-Object { $_.EndsWith($NumberTail) } | Select-Object -First 1
            $b = $found | Where-Object { $_.EndsWith($NumberTail2) } | Select-Object -First 1
            if (-not $a -or -not $b) { Fail ("diff: по хвостам найдено " + ($found -join ", ")) }
            Emit ("номера: " + $a + " и " + $b)
        } else { Fail "diff: нужны -Table и пара -Number/-Number2 или -NumberTail/-NumberTail2" }
        $q = $script:conn.CreateCommand()
        $q.CommandText = "SELECT * FROM " + (QID $Table) + " WHERE _Number = @a OR _Number = @b"
        [void]$q.Parameters.AddWithValue("@a", $a); [void]$q.Parameters.AddWithValue("@b", $b)
        $tbl = New-Object System.Data.DataTable
        $ad = New-Object System.Data.SqlClient.SqlDataAdapter($q); [void]$ad.Fill($tbl)
        Emit ("таблица " + $Table + ": строк " + $tbl.Rows.Count + ", колонок " + $tbl.Columns.Count)
        if ($tbl.Rows.Count -lt 2) { Fail ("diff: нужны обе строки, найдено " + $tbl.Rows.Count) }
        $srow = $null; $drow = $null
        foreach ($r in $tbl.Rows) { if ((Format-Value $r["_Number"]) -eq $a) { $srow = $r } else { $drow = $r } }
        Emit ""
        Emit "=== отличающиеся колонки (первая строка -> вторая) ==="
        foreach ($col in $tbl.Columns) {
            $a = Format-Value $srow[$col]; $b = Format-Value $drow[$col]
            if ($a -eq $b) { continue }
            if ($a.Length -gt 48) { $a = $a.Substring(0, 48) + "..." }
            if ($b.Length -gt 48) { $b = $b.Substring(0, 48) + "..." }
            Emit ("   " + $col.ColumnName + " (" + $col.DataType.Name + "): " + $a + "  ->  " + $b)
        }
        $script:conn.Close()
    }

    "row" {
        $script:conn = Open-Connection
        if (-not $Table -or -not $Ref) { Fail "row: нужны -Table и -Ref (0x... из _IDRRef)" }
        $hex = $Ref.Replace("0x", "").Replace("0X", "")
        $bytes = [byte[]]([regex]::Matches($hex, "..") | ForEach-Object { [Convert]::ToByte($_.Value, 16) })
        $q = $script:conn.CreateCommand()
        $q.CommandText = "SELECT * FROM " + (QID $Table) + " WHERE _IDRRef = @r"
        $p = $q.Parameters.Add("@r", [System.Data.SqlDbType]::VarBinary, 16); $p.Value = $bytes
        $rd = $q.ExecuteReader()
        if (-not $rd.Read()) { Emit "строки с таким _IDRRef нет"; $rd.Close(); $script:conn.Close(); Save-Out; exit 0 }
        Emit ("=== " + $Table + " ===")
        for ($i = 0; $i -lt $rd.FieldCount; $i++) {
            if ($rd.IsDBNull($i)) { continue }
            $s = Format-Value $rd.GetValue($i)
            if ($s -eq "") { continue }
            if ($s.Length -gt 70) { $s = $s.Substring(0, 70) + "..." }
            Emit ($rd.GetName($i) + " = " + $s)
        }
        $rd.Close(); $script:conn.Close()
    }

    "sql" {
        if (-not $Sql) { Fail "sql: нужен -Sql '<SELECT ...>'" }
        if ($Sql -match '(?i)\b(insert|update|delete|drop|alter|truncate|exec|merge)\b') {
            Fail "sql: изменяющий или исполняющий запрос отклонён — навык только читает"
        }
        $script:conn = Open-Connection
        Invoke-Query $Sql
        $script:conn.Close()
    }

    default { Fail "неизвестный -Command: $Command" }
}
Save-Out
if ($Out) { Write-Host ("результат также в " + $Out) }
