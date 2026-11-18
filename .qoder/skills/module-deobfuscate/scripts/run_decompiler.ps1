param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$Ref,
    [string]$Server = 'localhost',
    [string]$User = '',
    [string]$Pass = '',
    [string]$ClientExe = 'C:\Program Files\1cv8\8.5.1.1529\bin\1cv8c.exe',
    [string]$Epf = '',
    [string]$Handoff = 'C:\Users\Public\deobf',
    [int]$TimeoutSec = 3600,
    [string]$WorkDir = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function FullPath([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return [System.IO.Path]::GetFullPath($p) }
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $p))
}
if (-not $Epf) { $Epf = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\Assambler.epf')) } else { $Epf = FullPath $Epf }
$Manifest = FullPath $Manifest
if (-not $WorkDir) { $WorkDir = Join-Path (Get-Location) '.tmp\deobf-run' } else { $WorkDir = FullPath $WorkDir }
$Handoff = FullPath $Handoff
$reg = Get-ItemProperty HKCU:\Environment
if (-not $User) { $User = $reg.V8_DB_USER }
if (-not $Pass) { $Pass = $reg.V8_DB_PASS }

# Каталог обмена зашит в модуль обработки: манифест = <Handoff>\manifest.txt,
# отчёт = <Handoff>\_report.log, журнал = <Handoff>\boot.log.
New-Item -ItemType Directory -Force -Path $Handoff | Out-Null
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$dll = Join-Path $PSScriptRoot '..\assets\WebExDeobfuscator1CWin64_1002.dll'
if (Test-Path -LiteralPath $dll) {
    Copy-Item -LiteralPath $dll -Destination $Handoff -Force
    Write-Output ('компонента скопирована: ' + (Join-Path $Handoff (Split-Path -Leaf $dll)))
}
$boot = Join-Path $Handoff 'boot.log'
$report = Join-Path $Handoff '_report.log'
$addin = Join-Path $Handoff 'addin.log'
foreach ($f in @($boot, $report, $addin)) { if (Test-Path $f) { Remove-Item $f } }
Copy-Item -LiteralPath $Manifest -Destination (Join-Path $Handoff 'manifest.txt') -Force

$lines = @(Get-Content -LiteralPath $Manifest -Encoding UTF8 | Where-Object { $_.Trim() })
foreach ($line in $lines) {
    $target = ($line -split '\|')[1]
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
}

$out = Join-Path $WorkDir 'client-out.txt'
$logDir = Join-Path $WorkDir 'client-log'
if (Test-Path $logDir) { Remove-Item $logDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$argString = 'ENTERPRISE'
$argString += (' /S "{0}/{1}"' -f $Server, $Ref)
$argString += (' /N"{0}"' -f $User)
$argString += (' /P"{0}"' -f $Pass)
$argString += (' /Execute"{0}"' -f $Epf)
$argString += ' /DisableStartupDialogs'
$argString += (' /Out"{0}"' -f $out)
$argString += (' /Log"{0}"' -f $logDir)

Write-Output ('каталог обмена: ' + $Handoff)
Write-Output ('модулей в манифесте: ' + $lines.Count)
if (-not (Test-Path -LiteralPath $ClientExe)) { throw "клиент не найден: $ClientExe" }
if (-not (Test-Path -LiteralPath $Epf)) { throw "обработка не найдена: $Epf" }
Write-Output ('аргументы: ' + ($argString -replace ('/P"' + $Pass + '"'), '/P*****'))
$proc = Start-Process -FilePath $ClientExe -ArgumentList $argString -WorkingDirectory (Get-Location) -PassThru
Write-Output ('pid: ' + $proc.Id)

$done = 0
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $report) {
        $done = @(Get-Content -LiteralPath $report -Encoding UTF8 | Where-Object { $_.Trim() }).Count
    }
    if ($done -ge $lines.Count) { break }
    if ($proc.HasExited) { break }
    Start-Sleep -Seconds 5
}

Write-Output ('готово модулей: ' + $done + ' из ' + $lines.Count)
if (-not $proc.HasExited) {
    Write-Output 'клиент ещё работает — завершаю принудительно'
    Stop-Process -Id $proc.Id -Force
}
foreach ($f in @($boot, $report, $addin)) {
    if (Test-Path $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $WorkDir (Split-Path -Leaf $f)) -Force }
}
$bad = @()
if (Test-Path $report) {
    $bad = @(Get-Content -LiteralPath $report -Encoding UTF8 | Where-Object { $_.StartsWith('ERR|') -or $_.StartsWith('BAD|') })
}
foreach ($line in $bad) { Write-Output ('ОШИБКА ' + $line) }
if ($done -ge $lines.Count -and $bad.Count -eq 0) {
    Write-Output 'ОТДЕКОМПИЛИРОВАНО ВСЁ'
    exit 0
}
if (Test-Path $boot) {
    Write-Output '--- boot.log ---'
    Get-Content -LiteralPath $boot -Encoding UTF8 | ForEach-Object { Write-Output $_ }
}
if (Test-Path $addin) {
    Write-Output '--- addin.log ---'
    Get-Content -LiteralPath $addin -Encoding UTF8 | ForEach-Object { Write-Output $_ }
}
if (Test-Path $out) {
    Write-Output '--- вывод клиента (20 строк) ---'
    Get-Content -LiteralPath $out -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -Last 20 | ForEach-Object { Write-Output $_ }
}
exit 1
