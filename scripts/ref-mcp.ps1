<#
.SYNOPSIS
  Проверка доступности справочного MCP-сервера по платформе 1С (1c-syntax-helper).

.DESCRIPTION
  Отвечает на один вопрос: можно ли сейчас задать скиллам вопрос по синтаксису платформы.

  Скиллы работают и без справочника — он необязателен. Но его отсутствие выглядит как
  «такого метода не существует»: пустой ответ из tools, отвечающего поиском, неотличим от
  неверного имени. Поэтому перед тем как полагаться на ответ (или на его отсутствие),
  навык вызывает эту пробу.

  Проба ходит по HTTP напрямую, минуя коннектор: скрипт навыка не может вызвать MCP-инструмент,
  а проверить, поднят ли сервер, может.

  Код возврата:
    0 — сервер здоров и индекс построен, вопросам про синтаксис можно верить;
    1 — сервер отвечает, но нездоров или индекс пуст (ответы поиску не верь);
    2 — сервер недоступен (не запущен / другой порт / закрыт брандмауэром).

.PARAMETER Url
  Адрес /health. По умолчанию совпадает с .mcp.json этого комплекта.

.PARAMETER TimeoutSec
  Таймаут запроса, секунд.

.PARAMETER Tools
  Дополнительно запросить список инструментов (GET /mcp/tools) — убедиться, что коннектор
  отдаёт ожидаемые 5, а не пустой набор при живом сервере.

.EXAMPLE
  powershell.exe -NoProfile -File scripts/ref-mcp.ps1

.EXAMPLE
  powershell.exe -NoProfile -File scripts/ref-mcp.ps1 -Url "http://<host>:<port>/health" -Tools
#>
param(
    [string]$Url = 'http://localhost:8000/health',
    [int]$TimeoutSec = 5,
    [switch]$Tools
)

$ErrorActionPreference = 'Stop'

function Write-Field([string]$Name, $Value) {
    Write-Host ('  {0,-20} {1}' -f $Name, $Value)
}

# /health и /mcp/tools живут на одном.origin — базовый адрес выводим из -Url.
$base = $Url -replace '/health/?$', ''

try {
    $h = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec $TimeoutSec
} catch {
    Write-Host "Справочник 1С: недоступен — $Url"
    if ($_.Exception.Response) {
        Write-Host ('  HTTP-ответ           {0}' -f [int]$_.Exception.Response.StatusCode)
        Write-Host '  Сервер поднят, но эндпоинт /health не отвечает — смотри логи сервиса.'
    } else {
        Write-Host '  Соединение не установлено.'
        Write-Host '  Подними сервис: в каталоге 1c-syntax-helper-mcp — `docker compose up -d`.'
        Write-Host '  Без справочника скилы работают; вопросы по синтаксису платформа не проверит.'
    }
    Write-Host '  Подробности: docs/reference-mcp-guide.md'
    exit 2
}

Write-Host "Справочник 1С: $Url"
Write-Field 'статус'        $h.status
Write-Field 'elasticsearch' $(if ($h.elasticsearch) { 'OK' } else { 'нет связи с хранилищем' })
Write-Field 'индекс'        $(if ($h.index_exists) { "есть, $($h.documents_count) документов" } else { 'не построен' })
Write-Field 'индексация'    $h.indexing_status
Write-Field 'версия'        $h.version

$ready = ($h.status -eq 'healthy') -and $h.elasticsearch -and $h.index_exists

if ($Tools) {
    try {
        $t = Invoke-RestMethod -Uri "$base/mcp/tools" -Method Get -TimeoutSec $TimeoutSec
        $names = @($t.tools | ForEach-Object { $_.name })
        Write-Field 'инструменты' "$($names.Count): $($names -join ', ')"
    } catch {
        Write-Field 'инструменты' 'список не получен'
        $ready = $false
    }
}

if ($ready) {
    Write-Host 'Вывод: справочник готов — ответам find_1c_help / list_object_members можно верить,'
    Write-Host '       но помни: он знает платформу, а не вашу конфигурацию (см. docs/reference-mcp-guide.md).'
    exit 0
}

Write-Host 'Вывод: справочник НЕ готов — пустой ответ поиска означает «не проиндексировано»,'
Write-Host '       а не «метода не существует». Синтаксис проверяй конфигуратором.'
exit 1
