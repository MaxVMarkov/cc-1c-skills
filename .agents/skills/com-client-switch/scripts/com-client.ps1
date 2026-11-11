<#
Переключение COM-регистрации клиента 1С между версиями платформы, установленными в один корень.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'list',
    [string]$Version,
    [string]$Root = 'C:\Program Files\1cv8',
    [string]$SnapshotFile,
    [string]$FromFile,
    [string]$InfoBaseRef,
    [string]$Server,
    [string]$Ref,
    [string]$UserName,
    [string]$Password,
    [string]$ProgId = 'V85.COMConnector',
    [switch]$NoApplication
)

$ErrorActionPreference = 'Stop'

# Вывод кириллицей, поэтому кодировку ставим сами — внешний wrapper не нужен.
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch { }

# Fallback-таблица CLSID: нужна, когда ProgID уже отвалился (регистрация стёрта) и достать CLSID негде.
$KnownClsids = @{
    'V85.COMConnector' = '{BBAB44B3-6C80-43B1-AFEC-3094B12122BE}'
    'V83.COMConnector' = '{181E893D-73A4-4722-B61D-D604B3D67D47}'
    'V85.Application'  = '{B088C36F-3356-4791-A605-A1E50F4FA5F0}'
    'V85C.Application' = '{1214491F-1936-44C6-B8DC-CA6AC927FE73}'
    'V83.Application'  = '{E92B75E3-2EA1-4FEC-B493-CEF3EC59FCA6}'
    'V83C.Application' = '{27665EFC-55CA-4885-B491-6B90F04D6257}'
}
# Inproc = comcntr.dll (regsvr32), Local = 1cv8*.exe (/regserver).
$InprocProgIds = 'V85.COMConnector', 'V83.COMConnector'
$LocalProgIds = 'V85.Application', 'V85C.Application'

function Get-Clsid([string]$progId) {
    $v = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$progId\CLSID" -ErrorAction SilentlyContinue).'(default)'
    if ($v) { return $v }
    if ($KnownClsids.ContainsKey($progId)) { return $KnownClsids[$progId] }
    return $null
}

function Get-TypeLibPath([string]$tlGuid) {
    if (-not $tlGuid) { return '' }
    $tlKey = "HKLM:\SOFTWARE\Classes\TypeLib\$tlGuid"
    if (-not (Test-Path $tlKey)) { return "<типелиб ${tlGuid} не зарегистрирована>" }
    foreach ($ver in (Get-ChildItem $tlKey -ErrorAction SilentlyContinue)) {
        # У 6-битной платформы путь лежит в 0\win64, а не в 0\win32 — скан только по win32 даёт ложное «нет».
        foreach ($loc in 'win64', 'win32') {
            $w = Join-Path $ver.PSPath "0\$loc"
            if (Test-Path $w) { return (Get-ItemProperty $w).'(default)' }
        }
    }
    return "<типелиб ${tlGuid}: путь не найден>"
}

function Get-Registration([string]$progId) {
    $clsid = Get-Clsid $progId
    $o = [pscustomobject]@{
        ProgId = $progId; Clsid = $clsid; Kind = ''; Server = ''; FileVersion = ''
        ThreadingModel = ''; TypeLib = ''; TypeLibPath = ''; ClsidKeyExists = $false
    }
    if ($clsid) {
        $clsKey = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
        $o.ClsidKeyExists = Test-Path $clsKey
        $ips = Join-Path $clsKey 'InprocServer32'
        $ls = Join-Path $clsKey 'LocalServer32'
        if (Test-Path $ips) {
            $o.Kind = 'Inproc'; $o.Server = (Get-ItemProperty $ips).'(default)'
            $o.ThreadingModel = (Get-ItemProperty $ips).ThreadingModel
        } elseif (Test-Path $ls) {
            $o.Kind = 'Local'; $o.Server = (Get-ItemProperty $ls).'(default)'
        }
        if ($o.Server -match '^"(.+?)"') { $o.Server = $Matches[1] }
        if ($o.Server -and (Test-Path $o.Server)) { $o.FileVersion = (Get-Item $o.Server).VersionInfo.FileVersion }
        $tl = (Get-ItemProperty (Join-Path $clsKey 'TypeLib') -ErrorAction SilentlyContinue).'(default)'
        $o.TypeLib = $tl
        $o.TypeLibPath = Get-TypeLibPath $tl
    }
    return $o
}

function Get-Clients {
    if (-not (Test-Path $Root)) { throw "Каталог платформы не найден: $Root" }
    Get-ChildItem $Root -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } | ForEach-Object {
        $bin = Join-Path $_.FullName 'bin'
        $com = Join-Path $bin 'comcntr.dll'
        if (-not (Test-Path $com)) { return }
        [pscustomobject]@{
            Version   = $_.Name
            Bin       = $bin
            Comcntr   = $com
            FileVer   = (Get-Item $com).VersionInfo.FileVersion
            HasClient = (Test-Path (Join-Path $bin '1cv8.exe')) -and (Test-Path (Join-Path $bin '1cv8c.exe'))
        }
    } | Sort-Object Version
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Regsvr32([string]$bin, [string]$dll) {
    # Обязательное условие: рабочая папка = bin самой платформы. Без неё regsvr32 возвращает exit=3,
    # потому что не находит зависимости DLL (каталог загружаемой DLL сам по себе в порядке поиска не участвует).
    $p = Start-Process regsvr32 -ArgumentList '/s', "`"$dll`"" -WorkingDirectory $bin -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch {}; return -1 }
    return $p.ExitCode
}

function Invoke-RegServer([string]$exe) {
    $bin = Split-Path $exe
    $p = Start-Process $exe -ArgumentList '/regserver' -WorkingDirectory $bin -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch {}; return -1 }
    return $p.ExitCode
}

function Get-LoadedConnector {
    $ps = Get-Process -Id $PID
    $m = $ps.Modules | Where-Object { $_.ModuleName -eq 'comcntr.dll' } | Select-Object -First 1
    if (-not $m) { return $null }
    return [pscustomobject]@{ Path = $m.FileName; Version = $m.FileVersionInfo.FileVersion }
}

function Get-LoadedConnectorFresh {
    # Какой DLL реально грузится — видно только в свежем процессе: уже запущенные держат старый DLL.
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Command '__loaded' 2>&1
    ($out | Out-String).Trim()
}

function Get-ProjectConfig {
    $dir = (Get-Location).Path
    while ($dir) {
        $f = Join-Path $dir '.v8-project.json'
        if (Test-Path $f) { return (Get-Content $f -Raw | ConvertFrom-Json), $f }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null, $null
}

function Show-Clients {
    $reg = Get-Registration $ProgId
    $clients = Get-Clients
    if (-not $clients) { 'Установленных клиентов не найдено в ' + $Root; return }
    $registered = $reg.FileVersion
    'Установленные клиенты в ' + $Root + ':'
    foreach ($c in $clients) {
        $mark = if ($c.FileVer -eq $registered) { '*' } else { ' ' }
        '  {0} {1,-12} client={2,-3} {3}' -f $mark, $c.Version, $(if ($c.HasClient) { 'да' } else { 'нет' }), $c.Bin
    }
    ''
    'Сейчас зарегистрировано: ' + $ProgId + ' -> ' + $(if ($reg.Server) { $reg.Server + '  (ver=' + $reg.FileVersion + ')' } else { 'НИЧЕГО (не зарегистрирован)' })
    '  типелиб: ' + $(if ($reg.TypeLibPath) { $reg.TypeLibPath } else { 'нет' })
    '  (*) = версия, на которую сейчас указывает регистрация'
}

function Show-State {
    foreach ($prog in @($InprocProgIds) + @($LocalProgIds)) {
        $r = Get-Registration $prog
        '{0,-18} {1,-6} {2}' -f $r.ProgId, $r.Kind, $(if ($r.Server) { $r.Server } elseif ($r.ClsidKeyExists) { 'CLSID есть, сервера нет' } else { 'НЕ ЗАРЕГИСТРИРОВАН' })
        if ($r.FileVersion) { '     ver=' + $r.FileVersion + '  ThreadingModel=' + $r.ThreadingModel }
        if ($r.TypeLibPath) { '     типелиб: ' + $r.TypeLibPath }
    }
    ''
    'Загружаемый DLL в свежем процессе: ' + (Get-LoadedConnectorFresh)
    $other = Get-CimInstance Win32_Process -Filter "Name='1cv8.exe' or Name='1cv8c.exe' or Name='rphost.exe' or Name='rmngr.exe'" -ErrorAction SilentlyContinue
    if ($other) {
        ''
        'Работающие процессы платформы (старый DLL держится в памяти до выхода):'
        $other | ForEach-Object {
            $v = if ($_.ExecutablePath -match '\\(\d+\.\d+\.\d+\.\d+)\\') { $Matches[1] } else { '?' }
            '  {0,-12} pid={1,-7} {2}' -f $v, $_.ProcessId, $_.ExecutablePath
        }
    }
}

function Do-Switch([string]$ver) {
    if (-not (Test-IsAdmin)) { Write-Error 'Нужны права администратора (пишем в HKLM\SOFTWARE\Classes)'; exit 2 }
    $client = Get-Clients | Where-Object { $_.Version -eq $ver } | Select-Object -First 1
    if (-not $client) {
        Write-Error "Клиент $ver не найден. Доступны: " + ((Get-Clients | ForEach-Object Version) -join ', ')
        exit 5
    }
    $before = Get-Registration $ProgId
    $snap = [pscustomobject]@{
        Timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        ProgId     = $ProgId
        Before     = $before
        Target     = $ver
    }
    $snapFile = $SnapshotFile
    if (-not $snapFile) {
        $snapFile = Join-Path (Get-Location) ("com-registration-{0}-before-{1}.json" -f $ver, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $snap | ConvertTo-Json -Depth 6 | Set-Content -Path $snapFile -Encoding UTF8
    'Снимок текущей регистрации: ' + $snapFile
    '  было: ' + $(if ($before.Server) { $before.Server + ' (' + $before.FileVersion + ')' } else { 'ничего не зарегистрировано' })
    ''
    "regsvr32 comcntr.dll ($ver) из $($client.Bin): " + (Invoke-Regsvr32 $client.Bin $client.Comcntr)

    if (-not $NoApplication) {
        if (-not $client.HasClient) { Write-Warning 'В этом каталоге нет 1cv8.exe/1cv8c.exe — V85.Application не переносим' }
        else {
            foreach ($exe in '1cv8.exe', '1cv8c.exe') {
                '  {0} /regserver: exit={1}' -f $exe, (Invoke-RegServer (Join-Path $client.Bin $exe))
            }
        }
    }

    ''
    $after = Get-Registration $ProgId
    'Стало: ' + $(if ($after.Server) { $after.Server + '  ver=' + $after.FileVersion } else { 'НИЧЕГО — регистрация не восстановилась, поднимай снимок выше' })
    '  типелиб: ' + $(if ($after.TypeLibPath) { $after.TypeLibPath } else { 'НЕТ — Connect упадёт с TYPE_E_LIBNOTREGISTERED' })
    'Загружается в свежем процессе: ' + (Get-LoadedConnectorFresh)
    ''
    if ($after.FileVersion -ne $ver) {
        Write-Error "Регистрация не совпала с целью ($ver). Откат: выполни regsvr32 из каталога той версии, что была до переключения (см. снимок)."
        exit 4
    }
    'OK: COM-клиент переключён на ' + $ver
    'Гейт версий точный: базы, чей сервер другой версии, теперь через COM не откроются.'
}

function Do-Check {
    'Загружаемый коннектор: ' + (Get-LoadedConnectorFresh)
    $srv = $Server; $rf = $Ref
    if ($InfoBaseRef) {
        $cfg, $cfgFile = Get-ProjectConfig
        if (-not $cfg) { Write-Error '.v8-project.json не найден (идём вверх от текущей папки)'; exit 5 }
        $db = $cfg.databases | Where-Object {
            $_.id -eq $InfoBaseRef -or $_.ref -eq $InfoBaseRef -or $_.name -eq $InfoBaseRef -or
            (@($_.aliases) -contains $InfoBaseRef)
        } | Select-Object -First 1
        if (-not $db) { Write-Error "База $InfoBaseRef не найдена в $cfgFile"; exit 5 }
        $srv = $db.server; $rf = $db.ref
        if (-not $UserName -and $db.user) { $UserName = $db.user }
        if (-not $Password -and $db.password) { $Password = $db.password }
    }
    if (-not $srv -or -not $rf) { 'Параметры соединения не заданы — проверена только регистрация.'; return }
    if (-not $UserName) { $UserName = [Environment]::GetEnvironmentVariable('V8_DB_USER', 'User') }
    if (-not $Password) { $Password = [Environment]::GetEnvironmentVariable('V8_DB_PASS', 'User') }

    $cs = 'Srvr="{0}";Ref="{1}"' -f $srv, $rf
    if ($UserName -and $Password) { $cs += ';Usr="{0}";Pwd="{1}"' -f $UserName, $Password }
    'Проба соединения: Srvr="{0}";Ref="{1}"  (учётка: {2})' -f $srv, $rf, $(if ($UserName) { 'передана' } else { 'без учётки' })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $conn = New-Object -ComObject $ProgId
        $c = $conn.Connect($cs)
        $sw.Stop()
        '  CONNECTED  {0:N1} с' -f $sw.Elapsed.TotalSeconds
        try { $c.Disconnect() } catch {}
    } catch {
        $sw.Stop()
        $msg = $_.Exception.Message -replace '\s+', ' '
        $cls = 'OTHER'
        if ($msg -match 'Информационная база не обнаружена') { $cls = 'базы нет на сервере' }
        elseif ($msg -match 'Несоответствие версий') { $cls = 'ДРУГАЯ ВЕРСИЯ СЕРВЕРА (гейт точный)' }
        elseif ($msg -match 'Неверно указан пользователь|Не задан пользователь') { $cls = 'база есть, нужна учётка' }
        elseif ($msg -match 'TYPE_E_LIBNOTREGISTERED|Library not registered') { $cls = 'не зарегистрирована типелиб' }
        '  FAILED  {0:N1} с  [{1}]' -f $sw.Elapsed.TotalSeconds, $cls
        '  ' + $msg.Substring(0, [Math]::Min(200, $msg.Length))
        exit 1
    }
}

switch ($Command.ToLower()) {
    'list' { Show-Clients }
    'state' { Show-State }
    'switch' {
        if (-not $Version) { Write-Error 'Нужен -Version (см. list)'; exit 5 }
        Do-Switch $Version
    }
    'restore' {
        if (-not $FromFile -or -not (Test-Path $FromFile)) { Write-Error 'Нужен -FromFile <снимок.json>'; exit 5 }
        $snap = Get-Content $FromFile -Raw | ConvertFrom-Json
        $old = $snap.Before.Server
        if (-not $old -or $old -notmatch '\\(\d+\.\d+\.\d+\.\d+)\\') { Write-Error "В снимке нет пути с версией: $old"; exit 5 }
        Write-Host ("Откат на {0} (по снимку {1})" -f $Matches[1], $snap.Before.Server)
        $Version = $Matches[1]
        Do-Switch $Version
    }
    'check' { Do-Check }
    '__loaded' {
        $conn = New-Object -ComObject $ProgId
        $l = Get-LoadedConnector
        if ($l) { $l.Path + '  ver=' + $l.Version } else { 'comcntr.dll не загружен' }
    }
    default { Write-Error "Неизвестная команда: $Command (list|state|switch|restore|check)"; exit 5 }
}
