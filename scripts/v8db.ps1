<#
.SYNOPSIS
  Обёртка над db-* скиллами: подставляет учётные данные из реестра пользователя.

.DESCRIPTION
  Читает HKCU\Environment:
    V8_DB_USER / V8_DB_PASS   — пользователь информационной базы 1С (-UserName/-Password)
    SQL_DB_USER / SQL_DB_PASS — пользователь СУБД (-DbUser/-DbPassword)

  Значения из реестра подставляются ТОЛЬКО если вызывающий не передал их сам.
  Пароли не печатаются и не пишутся на диск — читаются в память на время вызова.

  Реквизиты СУБД (kind/server/name) берутся из блока dbms записи базы в
  .v8-project.json; сюда их передавать не нужно.

.PARAMETER Skill
  Имя db-скилла, например db-cfe-admin или db-dump-xml.

.PARAMETER Arguments
  Аргументы целевого скрипта скилла (передаются как есть).

.EXAMPLE
  powershell -File scripts/v8db.ps1 -Skill db-cfe-admin -Arguments @('-Command','list','-InfoBaseServer','<server>','-InfoBaseRef','<base>','-UserName','<user>')

.EXAMPLE
  # из bash
  powershell.exe -NoProfile -File scripts/v8db.ps1 -Skill db-dump-xml -Arguments '-InfoBaseServer','<server>','-InfoBaseRef','<base>','-UserName','<user>','-ConfigDir','src/config','-Mode','Changes'
#>
param(
    [Parameter(Mandatory = $true)][string]$Skill,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments = @(),
    # Каталог скиллов; по умолчанию рядом лежащие project-скиллы.
    [string]$SkillsRoot,
    [switch]$ShowCommand
)

$ErrorActionPreference = 'Stop'

# powershell.exe -File склеивает список в одну строку через запятую — разбираем обратно,
# если аргумент пришёл единым токеном с запятыми.
if ($Arguments.Count -eq 1 -and $Arguments[0] -match ',') {
    $Arguments = @($Arguments[0] -split ',')
}

function Read-RegValue([string]$Name) {
    $key = 'HKCU:\Environment'
    try {
        $item = Get-ItemProperty -Path $key -Name $Name -ErrorAction Stop
        return [string]$item.$Name
    } catch {
        return $null
    }
}

function Get-ArgKeys([string[]]$list) {
    $keys = @{}
    foreach ($t in $list) {
        if ($t -match '^-([A-Za-z][A-Za-z0-9]*)$') { $keys[$Matches[1].ToLower()] = $true }
    }
    return $keys
}

function Get-ScriptParams([string]$path) {
    # Имена параметров целевого скрипта (нижний регистр) — чтобы не инжектить то, чего он не знает.
    $set = @{}
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $cmd = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.ParamBlockAst] }, $true)
        if ($cmd) {
            foreach ($p in $cmd.Parameters) { $set[$p.Name.VariablePath.UserPath.ToLower()] = $true }
        }
    } catch { }
    return $set
}

# --- locate skill script ---
if (-not $SkillsRoot) {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.qoder\skills'),
        (Join-Path $PSScriptRoot '..\.qoder\skills'),
        (Join-Path $PSScriptRoot '..\..\skills')
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c $Skill)) { $SkillsRoot = (Resolve-Path $c).Path; break }
    }
}
if (-not $SkillsRoot) { Write-Error "Не найден каталог скиллов. Укажите -SkillsRoot." }

$scriptPath = Join-Path $SkillsRoot "$Skill\scripts\$Skill.ps1"
if (-not (Test-Path $scriptPath)) {
    # fallback: единственный .ps1 в scripts/
    $dir = Join-Path $SkillsRoot (Join-Path $Skill 'scripts')
    if (Test-Path $dir) {
        $ps1 = Get-ChildItem $dir -Filter *.ps1 | Select-Object -First 1
        if ($ps1) { $scriptPath = $ps1.FullName }
    }
}
if (-not (Test-Path $scriptPath)) { Write-Error "Скрипт скилла не найден: $Skill" }

# --- read secrets from registry ---
# Инжектим только пароли: имена пользователей не секретны, а часть скиллов не принимает
# -DbUser вовсе (реквизиты СУБД берутся из блока dbms реестра). Логины передавай явно.
$v8Pass = Read-RegValue 'V8_DB_PASS'
$sqlPass = Read-RegValue 'SQL_DB_PASS'

$present = Get-ArgKeys $Arguments
$targetParams = Get-ScriptParams $scriptPath

$inject = @()
if ($v8Pass  -and -not $present.ContainsKey('password')   -and $targetParams.ContainsKey('password'))   { $inject += @('-Password', $v8Pass) }
if ($sqlPass -and -not $present.ContainsKey('dbpassword') -and $targetParams.ContainsKey('dbpassword')) { $inject += @('-DbPassword', $sqlPass) }

$all = @($Arguments) + @($inject)

if ($ShowCommand) {
    # Маскируем значение, идущее сразу за ключом секрета (-Password/-DbPassword), и сами токены ключей.
    $secretKeys = @('-Password', '-DbPassword')
    $shown = @()
    for ($i = 0; $i -lt $all.Count; $i++) {
        $tok = $all[$i]
        if ($secretKeys -contains $tok) { $shown += $tok; $shown += '***'; $i++; continue }
        if ($tok -match '^-Password=|^-DbPassword=') { $shown += ($tok -replace '=.*$', '=***'); continue }
        $shown += $tok
    }
    Write-Host "v8db -> $Skill $($shown -join ' ')"
}

# Собираем именованные параметры в хеш-таблицу для splatting: цель принимает -Key value,
# а не позиционные токены.
$params = @{}
$i = 0
while ($i -lt $all.Count) {
    $tok = $all[$i]
    if ($tok -match '^-([A-Za-z][A-Za-z0-9]*)$') {
        $name = $Matches[1]
        if ($i + 1 -lt $all.Count -and $all[$i + 1] -notmatch '^-') {
            $params[$name] = $all[$i + 1]; $i += 2
        } else {
            $params[$name] = $true; $i += 1
        }
    } else {
        Write-Error "Неожиданный позиционный аргумент: $tok (ожидается -Ключ значение)"
    }
}

& $scriptPath @params
exit $LASTEXITCODE
