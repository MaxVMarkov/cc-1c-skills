# access-profiles v1.1 — Профили групп доступа и назначенные им роли
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Каким профилям групп доступа назначена роль и какие роли входят в профиль.

.DESCRIPTION
    Профили групп доступа — это ДАННЫЕ базы, а не метаданные: в XML-выгрузке их состава нет.
    Скрипт читает справочник ПрофилиГруппДоступа (ТЧ "Роли") двумя путями:
      1) через COM-соединение 1С (V8x.COMConnector) — основной;
      2) напрямую из MS SQL — если COM-коннектор не зарегистрирован (-NoCom форсирует этот путь).
    Таблицы в СУБД находятся по данным, без хардкода номеров: идентификаторы ролей видны по
    строкам "<синоним> (Роль)", а таблица профилей — по ссылкам на эти идентификаторы.

.PARAMETER Command
    profiles — профили, в которых есть роль (-Role)
    roles    — роли, назначенные профилю (-Profile)
    list     — все пары "профиль | роль"

.PARAMETER Role
    Роль для profiles. Шаблон: подстрока без * и ? или маска с * и ?.

.PARAMETER Profile
    Профиль для roles. Шаблон: подстрока без * и ? или маска с * и ?.

.EXAMPLE
    .\access-profiles.ps1 profiles -Role БазовыеПраваБСП -InfoBaseRef ut11-test -OutFile out.txt

.EXAMPLE
    .\access-profiles.ps1 roles -Profile БухгалтерОсновной -InfoBaseRef ut11-test -NoCom -OutFile out.txt
#>

[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('profiles', 'roles', 'list')]
    [string]$Command,

    [string]$Role,
    [string]$Profile,

    [string]$InfoBasePath,
    [string]$InfoBaseServer,
    [string]$InfoBaseRef,
    [string]$UserName,
    [string]$Password,

    # ProgID COM-коннектора. По умолчанию определяется по версии платформы из .v8-project.json.
    [string]$ProgId,

    # Не пробовать COM, читать сразу из СУБД.
    [switch]$NoCom,

    [switch]$IncludeMarked,
    [switch]$Exact,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:lines = @()
function Out([string]$text) { $script:lines += $text }

function Fail([string]$message) {
    Write-Host "[ERROR] $message"
    if ($OutFile) { Write-Output $script:lines }
    exit 1
}

# --- Реестр баз и запись базы -------------------------------------------------
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

function Find-DatabaseRecord([string]$key) {
    $pf = Find-V8Project (Get-Location).Path
    if (-not $pf) { return $null }
    try { $proj = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    $script:project = $proj
    if (-not $proj.databases) { return $null }
    if (-not $key) {
        foreach ($db in $proj.databases) { if ($db.default) { return $db } }
        return $null
    }
    foreach ($db in $proj.databases) {
        if ($db.id -and $db.id.Equals($key, [System.StringComparison]::OrdinalIgnoreCase)) { return $db }
        if ($db.name -and $db.name.Equals($key, [System.StringComparison]::OrdinalIgnoreCase)) { return $db }
        if ($db.ref -and $db.ref.Equals($key, [System.StringComparison]::OrdinalIgnoreCase)) { return $db }
        if ($db.aliases) {
            foreach ($a in $db.aliases) {
                if ($a -and $a.Equals($key, [System.StringComparison]::OrdinalIgnoreCase)) { return $db }
            }
        }
    }
    return $null
}

$script:project = $null
$rec = Find-DatabaseRecord $InfoBaseRef

$server = $InfoBaseServer
$ref = $null
$path = $InfoBasePath
if ($rec) {
    if (-not $server -and $rec.server) { $server = [string]$rec.server }
    if ($rec.ref) { $ref = [string]$rec.ref }
    if (-not $path -and $rec.path) { $path = [string]$rec.path }
} elseif ($InfoBaseRef -and -not $InfoBaseServer) {
    $server = 'localhost'
    $ref = $InfoBaseRef
} elseif ($InfoBaseRef) {
    $ref = $InfoBaseRef
}

if (-not $path -and -not ($server -and $ref)) {
    Fail 'Укажите базу: -InfoBaseRef <id|имя|алиас из .v8-project.json> либо -InfoBaseServer/-InfoBaseRef, либо -InfoBasePath.'
}

# --- Учётные данные ИБ: параметры, затем HKCU\Environment ---------------------
$envRec = Get-ItemProperty 'HKCU:\Environment' -ErrorAction SilentlyContinue
$user = $UserName
if (-not $user -and $envRec) { $user = [string]$envRec.V8_DB_USER }
$pwd = $Password
if (-not $pwd -and $envRec) { $pwd = [string]$envRec.V8_DB_PASS }

# --- Источник данных: COM или прямая СУБД -------------------------------------
function Get-SqlSettings {
    # Реквизиты СУБД берутся из dbms-блока записи базы; пароль — из неё же или из env.
    if (-not $rec) { return $null }
    if (-not $rec.dbms -or [string]$rec.dbms.kind -ne 'MSSQLServer') { return $null }
    $usr = [string]$rec.dbms.user
    $pass = [string]$rec.dbms.password
    $sUser = [Environment]::GetEnvironmentVariable('SQL_DB_USER', 'User')
    $sPass = [Environment]::GetEnvironmentVariable('SQL_DB_PASS', 'User')
    if (-not $pass -and $sPass) { $pass = $sPass; if (-not $usr) { $usr = $sUser } }
    if (-not $pass) { return $null }
    return @{ Server = [string]$rec.dbms.server; Database = [string]$rec.dbms.name; User = $usr; Password = $pass }
}

function Get-ProgIdCandidates([string]$v8path) {
    $list = New-Object System.Collections.ArrayList
    if ($v8path -and ($v8path -match '(\d+)\.(\d+)\.\d+')) {
        [void]$list.Add(('V{0}{1}.COMConnector' -f $Matches[1], $Matches[2]))
    }
    foreach ($p in @('V85.COMConnector', 'V84.COMConnector', 'V83.COMConnector')) {
        if (-not $list.Contains($p)) { [void]$list.Add($p) }
    }
    return $list
}

$v8path = $null
if ($rec -and $rec.v8path) { $v8path = [string]$rec.v8path }
if (-not $v8path -and $script:project -and $script:project.v8path) { $v8path = [string]$script:project.v8path }

function Read-ViaCom {
    $candidates = if ($ProgId) { @($ProgId) } else { Get-ProgIdCandidates $v8path }
    $com = $null
    $usedProgId = $null
    foreach ($prog in $candidates) {
        try {
            $com = New-Object -ComObject $prog
            $usedProgId = $prog
            break
        } catch { $com = $null }
    }
    if (-not $com) {
        return @{ Error = "COM-коннектор не зарегистрирован (проверены: $($candidates -join ', ')). Регистрация: Start-Process regsvr32 -ArgumentList '/s','comcntr.dll' -WorkingDirectory '<каталог bin платформы>' -Wait" }
    }

    if ($path) { $cs = 'File="' + $path + '"' } else { $cs = 'Srvr="' + $server + '";Ref="' + $ref + '"' }
    if ($user) { $cs += ';Usr="' + $user + '"' }
    if ($pwd) { $cs += ';Pwd="' + $pwd + '"' }

    try { $conn = $com.Connect($cs) } catch {
        $msg = $_.Exception.Message
        if ($pwd) { $msg = $msg.Replace($pwd, '***') }
        return @{ Error = "Не удалось подключиться ($usedProgId): $msg" }
    }

    # Без соединения со справочниками идентификаторов: Р.Роль — составная ссылка,
    # сравнение такой с однотипной в условии соединения платформа отвергает. Зато
    # обращение через точку к общим реквизитам работает для обоих видов ролей.
    $queryText = @"
ВЫБРАТЬ
	П.Наименование КАК Profile,
	П.ПометкаУдаления КАК Marked,
	Р.Роль.Имя КАК RoleName,
	Р.Роль.Наименование КАК RoleSynonym
ИЗ
	Справочник.ПрофилиГруппДоступа.Роли КАК Р
	ВНУТРЕННЕЕ СОЕДИНЕНИЕ Справочник.ПрофилиГруппДоступа КАК П
		ПО Р.Ссылка = П.Ссылка

УПОРЯДОЧИТЬ ПО
	Profile, RoleName
"@
    $rows = New-Object System.Collections.ArrayList
    try {
        $q = $conn.NewObject('Query')
        $q.Text = $queryText
        $sel = $q.Execute().Choose()
        while ($sel.Next()) {
            [void]$rows.Add([pscustomobject]@{
                Profile     = [string]$sel.Get(0)
                Marked      = [bool]$sel.Get(1)
                RoleName    = [string]$sel.Get(2)
                RoleSynonym = [string]$sel.Get(3)
            })
        }
    } catch {
        return @{ Error = ('Ошибка выполнения запроса: ' + $_.Exception.Message) }
    }
    return @{ Rows = $rows; Source = "COM ($usedProgId)" }
}

# --- Прямое чтение из MSSQL ---------------------------------------------------
function Open-Sql([hashtable]$s) {
    $cs = 'Server=' + $s.Server + ';Database=' + $s.Database + ';User Id=' + $s.User + ';Password=' + $s.Password + ';Encrypt=false'
    $c = New-Object System.Data.SqlClient.SqlConnection($cs)
    $c.Open()
    return $c
}

function Invoke-SqlTable([string]$text, [hashtable]$params) {
    $cmd = $script:sql.CreateCommand()
    $cmd.CommandText = $text
    $cmd.CommandTimeout = 300
    if ($params) {
        foreach ($k in $params.Keys) {
            $p = $cmd.CreateParameter()
            $p.ParameterName = $k
            $p.Value = $params[$k]
            [void]$cmd.Parameters.Add($p)
        }
    }
    $da = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt = New-Object System.Data.DataTable
    [void]$da.Fill($dt)
    # Запятая обязательна: DataTable — IEnumerable, и return без неё развернёт его в массив строк.
    return ,$dt
}

function Get-StringColumns([string]$table) {
    $dt = Invoke-SqlTable @"
SELECT c.name FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(@t) AND t.name IN ('nvarchar','varchar','nchar','char')
ORDER BY c.column_id
"@ @{ '@t' = $table }
    $names = @()
    foreach ($r in $dt.Rows) { if ([string]$r.name -ne '_Description') { $names += [string]$r.name } }
    return $names
}

function Get-MetadataNameColumn([string]$table) {
    # В справочнике идентификаторов Наименование (_Description) — синоним, а имя метаданных
    # лежит в пользовательском реквизите «Имя». Ищем его структурно: значение — суффикс
    # реквизита «ПолноеИмя» («Роль.БазовыеПраваБСП» → «БазовыеПраваБСП»). Сэмпл берём по
    # строкам-ролям: у объектов расширений ПолноеИмя несёт ещё и UUID в скобках.
    $cols = Get-StringColumns $table
    if ($cols.Count -lt 2) { return $null }
    $sel = "SELECT TOP 20 " + ($cols -join ', ') + " FROM [" + $table + "] "
    $dt = Invoke-SqlTable ($sel + 'WHERE _Description LIKE @p') @{ '@p' = '%(Роль)' }
    if ($dt.Rows.Count -eq 0) { $dt = Invoke-SqlTable ($sel + 'WHERE _Description IS NOT NULL') @{} }
    $best = $null; $bestRatio = 0
    foreach ($a in $cols) {
        foreach ($b in $cols) {
            if ($a -eq $b) { continue }
            $ok = 0; $total = 0
            foreach ($row in $dt.Rows) {
                $va = [string]$row[$a]; $vb = [string]$row[$b]
                if (-not $va -or -not $vb) { continue }
                $total++
                if ($vb.EndsWith('.' + $va)) { $ok++ }
            }
            if ($total -gt 0 -and ($ok / $total) -ge 0.8 -and ($ok / $total) -gt $bestRatio) {
                $best = $a; $bestRatio = $ok / $total
            }
        }
    }
    return $best
}

function Get-IdentifierTables {
    # Таблицы справочников идентификаторов видны по строкам-ролям "<синоним> (Роль)".
    $sql = @"
DECLARE @p nvarchar(64) = @pat;
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'SELECT ''' + t.name + N''' AS T, COUNT(*) AS C FROM ' + QUOTENAME(t.name) + N' WHERE _Description LIKE @p UNION ALL '
FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id AND c.name = N'_Description'
WHERE t.name LIKE N'_Reference%' AND t.name NOT LIKE N'%[_]VT[_]%';
SET @sql = LEFT(@sql, LEN(@sql) - LEN(N' UNION ALL '));
IF @sql = N'' SELECT CAST(NULL AS nvarchar(200)) AS T, CAST(0 AS int) AS C WHERE 1 = 0;
ELSE EXEC sp_executesql @sql, N'@p nvarchar(64)', @p;
"@
    $dt = Invoke-SqlTable $sql @{ '@pat' = '%(Роль)' }
    $res = @()
    foreach ($r in $dt.Rows) { if ($r.T -and [int]$r.C -gt 0) { $res += [string]$r.T } }
    return $res
}

function Get-ProfileSchema([string[]]$idTables) {
    # Таблица профилей — та ТЧ, где на идентификаторы ссылаются именно РОЛИ и таких ссылок
    # больше всего (у профилей их сотни/тысячи). Прочие таблицы тоже ссылаются на идентификаторы,
    # поэтому «первая попавшаяся» не годится.
    $dt = Invoke-SqlTable @"
SELECT c.TABLE_NAME, c.COLUMN_NAME, COALESCE(p.rows, 0) AS RowCnt
FROM INFORMATION_SCHEMA.COLUMNS c
JOIN sys.tables t ON t.name = c.TABLE_NAME
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE c.DATA_TYPE = 'binary' AND c.CHARACTER_MAXIMUM_LENGTH = 16
  AND c.COLUMN_NAME LIKE '%[_]RRRef' AND c.TABLE_NAME LIKE '[_]Reference%[_]VT%'
"@ @{}
    $ids = ($idTables | ForEach-Object { "SELECT _IDRRef FROM [$_] WHERE _Description LIKE @p" }) -join ' UNION ALL '
    $best = $null; $bestCnt = 0
    foreach ($r in $dt.Rows) {
        if ([long]$r.RowCnt -lt 5) { continue }
        $vt = [string]$r.TABLE_NAME
        $col = [string]$r.COLUMN_NAME
        try {
            $probe = Invoke-SqlTable ("SELECT COUNT(*) AS C FROM (SELECT DISTINCT v.[" + $col + "] AS r FROM [" + $vt + "] v) x JOIN (" + $ids + ") i ON i._IDRRef = x.r") @{ '@p' = '%(Роль)' }
            $cnt = if ($probe.Rows.Count -gt 0) { [int]$probe.Rows[0].C } else { 0 }
            if ($cnt -gt $bestCnt) { $best = @{ Vt = $vt; RoleCol = $col }; $bestCnt = $cnt }
        } catch { }
    }
    if (-not $best -or $bestCnt -lt 5) { return $null }

    $own = Invoke-SqlTable @"
SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = @t AND COLUMN_NAME LIKE '[_]Reference%[_]IDRRef'
"@ @{ '@t' = $best.Vt }
    if ($own.Rows.Count -eq 0) { return $null }
    $best.OwnerCol = [string]$own.Rows[0].COLUMN_NAME
    $best.ProfileTable = ($best.Vt -replace '_VT.*$', '')
    return $best
}

function Read-ViaSql([hashtable]$s) {
    try { $script:sql = Open-Sql $s } catch {
        return @{ Error = ('Не удалось подключиться к СУБД ' + $s.Server + '/' + $s.Database + ': ' + $_.Exception.Message) }
    }
    try {
        $idTables = @(Get-IdentifierTables)
        if ($idTables.Count -eq 0) {
            return @{ Error = 'В базе не найдены справочники идентификаторов объектов метаданных (строки "(Роль)") — профили групп доступа не обнаружены.' }
        }
        $schema = Get-ProfileSchema $idTables
        if (-not $schema) {
            return @{ Error = 'Не найдена таблица профилей групп доступа: ни одна ТЧ справочников не ссылается на идентификаторы объектов метаданных.' }
        }

        $nameCols = @{}
        foreach ($t in $idTables) { $nameCols[$t] = Get-MetadataNameColumn $t }

        $joins = ''
        $cols = @('p._Description AS RoleProfile', 'p._Marked AS Marked')
        $i = 0
        foreach ($t in $idTables) {
            $i++
            $alias = "i$i"
            $joins += " LEFT JOIN [" + $t + "] " + $alias + " ON " + $alias + "._IDRRef = v.[" + $schema.RoleCol + "]"
            $nc = $nameCols[$t]
            $nameExpr = if ($nc) { $alias + '.[' + $nc + ']' } else { 'CAST(NULL AS nvarchar(400))' }
            $cols += "COALESCE(" + $nameExpr + ", N'') AS RoleName_$i"
            $cols += "COALESCE(" + $alias + "._Description, N'') AS RoleSyn_$i"
        }
        $sql = "SELECT p._Description AS ProfileName, p._Marked AS Marked, " +
               ($cols[2..($cols.Count - 1)] -join ', ') +
               " FROM [" + $schema.Vt + "] v JOIN [" + $schema.ProfileTable + "] p ON p._IDRRef = v.[" + $schema.OwnerCol + "]" + $joins

        $dt = Invoke-SqlTable $sql @{}
        $rows = New-Object System.Collections.ArrayList
        foreach ($r in $dt.Rows) {
            $name = ''; $syn = ''
            for ($k = 1; $k -le $i; $k++) {
                if (-not $name -and $r["RoleName_$k"]) { $name = [string]$r["RoleName_$k"] }
                if (-not $syn -and $r["RoleSyn_$k"]) { $syn = [string]$r["RoleSyn_$k"] }
            }
            [void]$rows.Add([pscustomobject]@{
                Profile     = [string]$r.ProfileName
                Marked      = ([byte[]]$r.Marked)[0] -ne 0
                RoleName    = $name
                RoleSynonym = $syn
            })
        }
        return @{ Rows = $rows; Source = ('SQL ' + $s.Server + '/' + $s.Database) }
    } finally {
        if ($script:sql) { $script:sql.Close() }
    }
}

# --- Выбор источника ----------------------------------------------------------
$data = $null
$errors = @()
if (-not $NoCom) {
    $data = Read-ViaCom
    if ($data.Error) { $errors += $data.Error; $data = $null }
}
if (-not $data) {
    $sqlSettings = Get-SqlSettings
    if ($sqlSettings) {
        $data = Read-ViaSql $sqlSettings
        if ($data.Error -and $errors.Count -gt 0) {
            Fail ('COM недоступен (' + ($errors -join '; ') + '), и SQL-путь не сработал: ' + $data.Error)
        } elseif ($data.Error) {
            Fail $data.Error
        }
    } else {
        $why = if ($errors.Count -gt 0) { ($errors -join '; ') } else { 'соединение с базой не задано' }
        Fail ($why + '. Прямое чтение из СУБД тоже недоступно: у базы нет dbms-блока MSSQLServer в .v8-project.json или нет пароля SQL (SQL_DB_PASS).')
    }
}

$rows = $data.Rows

$markedSkipped = 0
if (-not $IncludeMarked) {
    $kept = New-Object System.Collections.ArrayList
    foreach ($r in $rows) {
        if ($r.Marked) { $markedSkipped++ } else { [void]$kept.Add($r) }
    }
    $rows = $kept
}

# --- Фильтр: подстрока без масок, иначе маска ---------------------------------
function Test-Match([string]$value, [string]$pattern) {
    if (-not $pattern) { return $true }
    if ($pattern -match '[*?]') { return ($value -like $pattern) }
    return ($value.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# Роль ищется и по имени метаданных, и по синониму: в профиле хранится ссылка на
# идентификатор, где Имя = «БазовыеПраваБСП», а Наименование = «Базовые права БСП (Роль)».
function Test-RoleMatch($row, [string]$pattern) {
    if (-not $pattern) { return $true }
    if ($Exact) {
        return ($row.RoleName -eq $pattern) -or ($row.RoleSynonym -eq $pattern)
    }
    return ((Test-Match $row.RoleName $pattern) -or (Test-Match $row.RoleSynonym $pattern))
}

function Format-Role($row) {
    if ($row.RoleSynonym -and $row.RoleSynonym -ne $row.RoleName) { return "$($row.RoleName) — $($row.RoleSynonym)" }
    return $row.RoleName
}

$note = if ($markedSkipped -gt 0) { "пропущено помеченных на удаление: $markedSkipped" } else { $null }

function Out-Note([string]$prefix) {
    if ($note) { Out "  ($prefix $note)" }
}

Out "источник: $($data.Source)"
Out ''

switch ($Command) {
    'profiles' {
        if (-not $Role) { Fail 'Для команды profiles укажите -Role (имя роли или шаблон).' }
        $groups = $rows | Where-Object { Test-RoleMatch $_ $Role } | Group-Object RoleName | Sort-Object Name
        if (-not $groups) { Out "Роль не найдена ни в одном профиле: $Role"; Out-Note 'итого'; break }
        foreach ($g in $groups) {
            $first = $g.Group | Select-Object -First 1
            Out "=== Роль: $(Format-Role $first) ==="
            Out "  профилей: $($g.Count)"
            Out-Note 'по базе'
            foreach ($item in ($g.Group | Sort-Object Profile)) { Out "  $($item.Profile)" }
            Out ''
        }
    }
    'roles' {
        if (-not $Profile) { Fail 'Для команды roles укажите -Profile (имя профиля или шаблон).' }
        $groups = $rows | Where-Object { Test-Match $_.Profile $Profile } | Group-Object Profile | Sort-Object Name
        if (-not $groups) { Out "Профиль не найден или без ролей: $Profile"; Out-Note 'итого'; break }
        foreach ($g in $groups) {
            Out "=== Профиль: $($g.Name) ==="
            Out "  ролей: $($g.Count)"
            Out-Note 'по базе'
            foreach ($item in ($g.Group | Sort-Object RoleName)) { Out "  $(Format-Role $item)" }
            Out ''
        }
    }
    'list' {
        $filtered = $rows | Where-Object { (Test-Match $_.Profile $Profile) -and (Test-RoleMatch $_ $Role) }
        if (-not $filtered) { Out 'Нет данных.'; break }
        $profiles = ($filtered | Select-Object -ExpandProperty Profile -Unique).Count
        $roles = ($filtered | Select-Object -ExpandProperty RoleName -Unique).Count
        Out "пар: $(@($filtered).Count) · профилей: $profiles · ролей: $roles"
        Out-Note 'по базе'
        Out ''
        foreach ($item in ($filtered | Sort-Object Profile, RoleName)) { Out "$($item.Profile) | $(Format-Role $item)" }
    }
}

# --- Вывод --------------------------------------------------------------------
if ($OutFile) {
    $full = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location).Path $OutFile }
    [System.IO.File]::WriteAllLines($full, $script:lines, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "OK: $full"
} else {
    foreach ($l in $script:lines) { Write-Host $l }
}
