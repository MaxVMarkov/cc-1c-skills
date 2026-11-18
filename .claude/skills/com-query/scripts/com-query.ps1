# com-query v1.0 — произвольный запрос к ИБ 1С через COM-коннектор
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Выполняет запрос к информационной базе через COM-коннектор и печатает строки.

.DESCRIPTION
    IDispatch коннектора отдаёт методы по-английски: NewObject('Query') / Text / SetParameter /
    Execute / Choose / Next / Get. Кириллические Выполнить/НовыйОбъект в PowerShell не резолвятся.
    Закрывать соединение нечем — Disconnect/Close не резолвятся, сеанс умирает с процессом.

.EXAMPLE
    .\com-query.ps1 -Sql "ВЫБРАТЬ ПЕРВЫЕ 5 П.Наименование ИЗ Справочник.Пользователи КАК П" -InfoBaseRef demo-base -OutFile out.txt
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Mandatory=$false)]
    [string]$Sql,

    [string]$SqlFile,

    [string[]]$Param,
    [string[]]$ParamInt,

    [int]$MaxRows = 1000,

    [string]$InfoBasePath,
    [string]$InfoBaseServer,
    [string]$InfoBaseRef,
    [string]$UserName,
    [string]$Password,

    # ProgID COM-коннектора. По умолчанию определяется по версии платформы из .v8-project.json.
    [string]$ProgId,

    [string]$Separator = ' | ',
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

if (-not $Sql -and -not $SqlFile) { Fail 'Укажите текст запроса: -Sql "<запрос>" или -SqlFile <файл>.' }
if ($Sql -and $SqlFile) { Fail 'Передайте что-то одно: -Sql или -SqlFile.' }
if ($SqlFile) {
    if (-not (Test-Path $SqlFile)) { Fail "Файл запроса не найден: $SqlFile" }
    $Sql = Get-Content $SqlFile -Raw -Encoding UTF8
}

# --- Учётные данные ИБ: параметры, затем HKCU\Environment ---------------------
$envRec = Get-ItemProperty 'HKCU:\Environment' -ErrorAction SilentlyContinue
$user = $UserName
if (-not $user -and $envRec) { $user = [string]$envRec.V8_DB_USER }
$pwd = $Password
if (-not $pwd -and $envRec) { $pwd = [string]$envRec.V8_DB_PASS }

# --- ProgID коннектора по версии платформы ------------------------------------
$v8path = $null
if ($rec -and $rec.v8path) { $v8path = [string]$rec.v8path }
if (-not $v8path -and $script:project -and $script:project.v8path) { $v8path = [string]$script:project.v8path }

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

# --- Выполнение ---------------------------------------------------------------
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
    Fail "COM-коннектор не зарегистрирован (проверены: $($candidates -join ', ')). Регистрация: Start-Process regsvr32 -ArgumentList '/s','comcntr.dll' -WorkingDirectory '<каталог bin платформы>' -Wait"
}

if ($path) { $cs = 'File="' + $path + '"' } else { $cs = 'Srvr="' + $server + '";Ref="' + $ref + '"' }
if ($user) { $cs += ';Usr="' + $user + '"' }
if ($pwd) { $cs += ';Pwd="' + $pwd + '"' }

try { $conn = $com.Connect($cs) } catch {
    $msg = $_.Exception.Message
    if ($pwd) { $msg = $msg.Replace($pwd, '***') }
    Fail "Не удалось подключиться ($usedProgId): $msg"
}

$rows = 0
try {
    $q = $conn.NewObject('Query')
    $q.Text = $Sql
    if ($Param) {
        foreach ($pair in $Param) {
            $i = $pair.IndexOf('=')
            if ($i -lt 1) { Fail "Параметр без имени: '$pair' (нужно Имя=значение)." }
            $q.SetParameter($pair.Substring(0, $i), $pair.Substring($i + 1)) | Out-Null
        }
    }
    if ($ParamInt) {
        foreach ($pair in $ParamInt) {
            $i = $pair.IndexOf('=')
            if ($i -lt 1) { Fail "Числовой параметр без имени: '$pair' (нужно Имя=число)." }
            $q.SetParameter($pair.Substring(0, $i), [decimal]$pair.Substring($i + 1)) | Out-Null
        }
    }

    $sel = $q.Execute().Choose()
    while ($sel.Next()) {
        if ($rows -ge $MaxRows) { break }
        $row = $sel
        $values = @()
        for ($j = 0; $j -lt 64; $j++) {
            try { $v = $row.Get($j) } catch { break }
            $values += ([string]$v)
        }
        Out ($values -join $Separator)
        $rows++
    }
    if ($rows -eq 0) { Out 'строк: 0' }
} catch {
    $msg = $_.Exception.Message
    if ($pwd) { $msg = $msg.Replace($pwd, '***') }
    Fail "Ошибка выполнения запроса ($usedProgId): $msg"
}

$header = "источник: COM ($usedProgId)"
if ($OutFile) {
    $all = @($header) + $script:lines
    $all | Set-Content -Encoding UTF8 -LiteralPath $OutFile
    Write-Host "OK: $OutFile (строк: $rows)"
} else {
    Write-Host $header
    $script:lines | ForEach-Object { Write-Output $_ }
}
