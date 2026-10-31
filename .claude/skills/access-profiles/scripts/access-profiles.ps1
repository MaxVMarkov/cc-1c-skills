# access-profiles v1.0 — Профили групп доступа и назначенные им роли (через COM-соединение)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Каким профилям групп доступа назначена роль и какие роли входят в профиль.

.DESCRIPTION
    Профили групп доступа — это ДАННЫЕ базы, а не метаданные: в XML-выгрузке их состава нет.
    Скрипт читает справочник ПрофилиГруппДоступа (ТЧ "Роли") через COM-соединение 1С.

    Роль в ТЧ — составная ссылка: базовые роли лежат в Справочник.ИдентификаторыОбъектовМетаданных,
    роли расширений — в Справочник.ИдентификаторыОбъектовРасширений. Учитываются оба вида.

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
    .\access-profiles.ps1 roles -Profile БухгалтерОсновной -InfoBaseRef ut11-test -OutFile out.txt

.EXAMPLE
    .\access-profiles.ps1 list -InfoBaseRef ut11-test -OutFile all-pairs.txt
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

    [switch]$IncludeMarked,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:lines = @()
function Out([string]$text) { $script:lines += $text }

function Fail([string]$message) {
    Write-Host "[ERROR] $message"
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
    # Не зарегистрированная база: считаем, что передано имя базы на сервере.
    $server = 'localhost'
    $ref = $InfoBaseRef
} elseif ($InfoBaseRef) {
    $ref = $InfoBaseRef
}

if (-not $path -and -not ($server -and $ref)) {
    Fail 'Укажите базу: -InfoBaseRef <id|имя|алиас из .v8-project.json> либо -InfoBaseServer/-InfoBaseRef, либо -InfoBasePath.'
}

# --- Учётные данные: параметры, затем HKCU\Environment ------------------------
$envRec = Get-ItemProperty 'HKCU:\Environment' -ErrorAction SilentlyContinue
$user = $UserName
if (-not $user -and $envRec) { $user = [string]$envRec.V8_DB_USER }
$pwd = $Password
if (-not $pwd -and $envRec) { $pwd = [string]$envRec.V8_DB_PASS }

# --- ProgID коннектора по версии платформы ------------------------------------
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

$candidates = if ($ProgId) { @($ProgId) } else { Get-ProgIdCandidates $v8path }

$com = $null
$usedProgId = $null
foreach ($prog in $candidates) {
    try {
        $com = New-Object -ComObject $prog
        $usedProgId = $prog
        break
    } catch {
        $com = $null
    }
}
if (-not $com) {
    Out "[ERROR] COM-коннектор не зарегистрирован (проверены: $($candidates -join ', '))."
    Out 'Регистрация (от имени администратора), каталог bin обязателен как рабочий:'
    Out '  powershell -Command "Start-Process regsvr32 -ArgumentList ''/s'',''comcntr.dll'' -WorkingDirectory ''C:\Program Files\1cv8\<версия>\bin'' -Wait"'
    Out 'Без рабочего каталога bin regsvr32 не находит core<NN>.dll/nuke<NN>.dll и падает с кодом 3.'
    if ($OutFile) { [System.IO.File]::WriteAllLines($OutFile, $script:lines, (New-Object System.Text.UTF8Encoding($true))) }
    exit 1
}

# --- Соединение ---------------------------------------------------------------
if ($path) {
    $cs = 'File="' + $path + '"'
} else {
    $cs = 'Srvr="' + $server + '";Ref="' + $ref + '"'
}
if ($user) { $cs += ';Usr="' + $user + '"' }
if ($pwd) { $cs += ';Pwd="' + $pwd + '"' }

$conn = $null
try {
    $conn = $com.Connect($cs)
} catch {
    $msg = $_.Exception.Message
    if ($pwd) { $msg = $msg.Replace($pwd, '***') }
    Fail ("Не удалось подключиться ($usedProgId): " + $msg)
}

# --- Запрос -------------------------------------------------------------------
# Без соединения со справочниками идентификаторов: Р.Роль — составная ссылка
# (ИдентификаторыОбъектовМетаданных + ИдентификаторыОбъектовРасширений), сравнение
# такой ссылки с однотипной в условии соединения платформа отвергает. Зато доступ
# к общему стандартному реквизиту через точку (`Р.Роль.Наименование`) работает
# и покрывает оба вида ролей — базовые и из расширений.
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
    Fail ('Ошибка выполнения запроса: ' + $_.Exception.Message)
}

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
    if ($pattern -match '[*?]') {
        return ($value -like $pattern)
    }
    return ($value.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# Роль ищется и по имени метаданных, и по синониму: в профиле хранится ссылка на
# идентификатор, где Имя = «БазовыеПраваБСП», а Наименование = «Базовые права БСП (Роль)».
function Test-RoleMatch($row, [string]$pattern) {
    if (-not $pattern) { return $true }
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
