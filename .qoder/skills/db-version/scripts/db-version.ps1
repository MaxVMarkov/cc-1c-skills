# db-version v1.0 — версия конфигурации и расширений информационной базы 1С
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
<#
.SYNOPSIS
    Показывает версии расширений в базе и актуальную версию конфигурации.

.DESCRIPTION
    Версии конфигурации в СУБД нет: файл version таблицы Config хранит идентификатор формата
    ({216,0,{80327,0}}), а не релиз. Поэтому config-version обновляет существующую выгрузку
    режимом Changes и читает <Version> из Configuration.xml до и после — расхождение и есть дрейф.
    Расширения и их версии читает ibcmd (infobase config extension list); в режиме extension
    у ibcmd нет --user, creds передаются только в этой форме.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('ext-list', 'config-version')]
    [string]$Command,

    [string]$ConfigDir,

    [string]$InfoBasePath,
    [string]$InfoBaseServer,
    [string]$InfoBaseRef,
    [string]$UserName,
    [string]$Password,

    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:IbcmdNoUserTimeoutSec = 10
$script:IbcmdNoUserHint = '[ibcmd] Без -UserName/пароля ibcmd читает вход из консоли и может зависнуть.'
$script:IbcmdAborted = "[ibcmd] Прервано через $script:IbcmdNoUserTimeoutSec с — ibcmd ждал вход в ИБ."

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

# --- Платформа и ibcmd --------------------------------------------------------
$v8path = $null
if ($rec -and $rec.v8path) { $v8path = [string]$rec.v8path }
if (-not $v8path -and $script:project -and $script:project.v8path) { $v8path = [string]$script:project.v8path }

function Get-IbcmdPath([string]$v8path) {
    if (-not $v8path) { return $null }
    if ($v8path -match '\\bin\\?$') { return (Join-Path $v8path 'ibcmd.exe') }
    $dir = [System.IO.Path]::GetDirectoryName($v8path)
    if ($dir -and $dir -match '\\bin\\?$') { return (Join-Path $dir.TrimEnd('\') 'ibcmd.exe') }
    return (Join-Path $v8path 'bin\ibcmd.exe')
}

# Реквизиты СУБД для ibcmd: из dbms-блока записи, пароль — из него же или SQL_DB_PASS.
function Get-IbcmdDbArgs {
    $usr = $null; $pass = $null
    if ($rec -and $rec.dbms -and [string]$rec.dbms.kind -eq 'MSSQLServer') {
        $usr = [string]$rec.dbms.user
        $pass = [string]$rec.dbms.password
    }
    $sUsr = [Environment]::GetEnvironmentVariable('SQL_DB_USER', 'User')
    $sPass = [Environment]::GetEnvironmentVariable('SQL_DB_PASS', 'User')
    if (-not $pass -and $sPass) { $pass = $sPass; if (-not $usr) { $usr = $sUsr } }
    if (-not $pass -and -not $path) { return $null }
    if (-not $rec -or -not $rec.dbms) { return $null }
    $args = @()
    if (-not $path) {
        if ($pass -and $usr) { $args += "--db-user=$usr"; $args += "--db-pwd=$pass" }
    }
    return $args
}

# --- Ограниченный запуск платформы -------------------------------------------
function Invoke-PlatformProcess {
    # Возвращает @{ Output; ExitCode; TimedOut }. Вывод берётся из редиректов, чтобы не
    # мешать потоки; по таймауту процесс убивается и помечается TimedOut.
    param([string]$Exe, [string[]]$ProcArgs, [int]$TimeoutSec = 0)
    $argLine = ($ProcArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    # Потоки сбрасываются параллельно: последовательное чтение взаимо-блокируется на буфере.
    $outMs = New-Object System.IO.MemoryStream
    $errMs = New-Object System.IO.MemoryStream
    $outTask = $p.StandardOutput.BaseStream.CopyToAsync($outMs)
    $errTask = $p.StandardError.BaseStream.CopyToAsync($errMs)
    $timedOut = $false
    if ($TimeoutSec -gt 0) {
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
            [void]$p.WaitForExit(5000)
        }
    } else {
        $p.WaitForExit()
    }
    [void][System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 1000)
    $outB = $outMs.ToArray()
    $errB = $errMs.ToArray()
    $utf8 = [System.Text.Encoding]::UTF8
    $outText = $utf8.GetString($outB)
    if ($outText.Contains([char]0xFFFD)) {
        try { $outText = [System.Text.Encoding]::GetEncoding(866).GetString($outB) } catch { }
    }
    $errText = $utf8.GetString($errB)
    if ($errText.Contains([char]0xFFFD)) {
        try { $errText = [System.Text.Encoding]::GetEncoding(866).GetString($errB) } catch { }
    }
    $code = if ($timedOut -or -not $p.HasExited) { -1 } else { $p.ExitCode }
    return @{ Output = ($outText + $errText); ExitCode = $code; TimedOut = $timedOut }
}

# --- Команда ext-list ---------------------------------------------------------
function Invoke-ExtList {
    $ibcmd = Get-IbcmdPath $v8path
    if (-not $ibcmd -or -not (Test-Path $ibcmd)) {
        Fail "ibcmd не найден рядом с платформой ($v8path) — расширения читает только он."
    }
    if (-not $user) { Fail 'Нет -UserName (и пусто V8_DB_USER): ibcmd без учётки ИБ виснет на приглашении входа.' }

    # Мёртвый процесс в lock.pid блокирует следующие запуски ibcmd — файл снимаем.
    $lockFile = Join-Path $env:LOCALAPPDATA '1C\1cv8\standalone-server\lock.pid'
    if (Test-Path $lockFile) {
        $lockPid = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($lockPid -match '^\d+$' -and -not (Get-Process -Id ([int]$lockPid) -ErrorAction SilentlyContinue)) {
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        }
    }

    $opArgs = @('infobase', 'config', 'extension', 'list')
    $dbArgs = Get-IbcmdDbArgs
    $conn = @()
    if ($path) {
        $conn += "--db-path=$path"
        if ($dbArgs) { $conn += $dbArgs }
    } else {
        if (-not $dbArgs) {
            Fail 'Серверная база: ibcmd подключается через СУБД — нужен блок dbms в записи базы (kind/server/name) и SQL_DB_PASS, либо -InfoBasePath.'
        }
        $conn += '--dbms=MSSQLServer'
        $conn += "--db-server=$server"
        $conn += "--db-name=$ref"
        $conn += $dbArgs
    }
    $conn += "--user=$user"
    if ($pwd) { $conn += "--password=$pwd" }

    $displayArgs = @($opArgs) + @($conn | ForEach-Object { if ($_ -match '^--password=|^--db-pwd=') { ($_ -split '=')[0] + '=***' } else { $_ } })
    Write-Host "Running: ibcmd $($displayArgs -join ' ')"
    if (-not $user) { Write-Host $script:IbcmdNoUserHint -ForegroundColor Yellow }
    $ibTimeout = 120
    $res = Invoke-PlatformProcess $ibcmd ($opArgs + $conn) -TimeoutSec $ibTimeout
    if ($res.TimedOut) { Write-Host $script:IbcmdAborted -ForegroundColor Red; Fail 'ibcmd не ответил за отведённое время.' }
    if ($res.ExitCode -ne 0) { Fail "ibcmd завершился с кодом $($res.ExitCode): $($res.Output)" }

    $rows = ($res.Output -split "`r?`n") | Where-Object { $_ -match '^\s*(name|version)\s*:' }
    if (-not $rows) { Fail "ibcmd не вернул список расширений. Вывод: $($res.Output)" }
    foreach ($r in $rows) { Out $r.TrimEnd() }
}

# --- Команда config-version ---------------------------------------------------
function Invoke-ConfigVersion {
    if (-not $ConfigDir) { Fail 'Укажите -ConfigDir: каталог существующей выгрузки с ConfigDumpInfo.xml (обновление идёт режимом Changes).' }
    $cfgXml = Join-Path $ConfigDir 'Configuration.xml'
    if (-not (Test-Path $cfgXml)) { Fail "В $ConfigDir нет Configuration.xml — сперва полная выгрузка (/db-dump-xml -Mode Full)." }
    if (-not (Test-Path (Join-Path $ConfigDir 'ConfigDumpInfo.xml'))) {
        Fail "В $ConfigDir нет ConfigDumpInfo.xml — режим Changes невозможен; нужна полная выгрузка (/db-dump-xml -Mode Full)."
    }

    function Read-Version([string]$file) {
        $m = Select-String -LiteralPath $file -Pattern '<Version>([^<]*)</Version>' -ErrorAction SilentlyContinue
        if ($m -and $m.Matches.Count -gt 0) { return $m.Matches[0].Groups[1].Value }
        return $null
    }

    $before = Read-Version $cfgXml
    Out "CONFIG_VERSION_BEFORE=$before"

    $skillsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $dumper = Join-Path $skillsRoot 'db-dump-xml\scripts\db-dump-xml.ps1'
    if (-not (Test-Path $dumper)) { Fail "Не найден скрипт выгрузки: $dumper" }

    $params = @{ ConfigDir = $ConfigDir; Mode = 'Changes' }
    if ($path) { $params.InfoBasePath = $path } else { $params.InfoBaseServer = $server; $params.InfoBaseRef = $ref }
    if ($user) { $params.UserName = $user }
    if ($pwd) { $params.Password = $pwd }

    $log = [System.IO.Path]::GetTempFileName()
    try {
        & $dumper @params *> $log
        $code = $LASTEXITCODE
    } finally {
        $logText = Get-Content $log -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        Remove-Item $log -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) {
        $tail = ($logText -split "`r?`n" | Select-Object -Last 6) -join ' / '
        Fail "Выгрузка не удалась (код $code): $tail"
    }

    $after = Read-Version $cfgXml
    Out "CONFIG_VERSION_AFTER=$after"
    if ($before -and $after -and $before -ne $after) {
        Out 'DRIFT=yes'
    } elseif ($before -and $after) {
        Out 'DRIFT=no'
    } else {
        Out 'DRIFT=unknown'
    }
}

# --- Диспетчер и вывод --------------------------------------------------------
switch ($Command) {
    'ext-list'       { Invoke-ExtList }
    'config-version' { Invoke-ConfigVersion }
}

if ($OutFile) {
    $script:lines | Set-Content -Encoding UTF8 -LiteralPath $OutFile
    Write-Host "OK: $OutFile"
} else {
    $script:lines | ForEach-Object { Write-Output $_ }
}
