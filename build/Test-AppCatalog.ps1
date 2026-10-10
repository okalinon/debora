# Перевіряє, що кожен пакет із config/apps.json існує в джерелі winget / msstore.
# Потрібен інтернет; ≈2–4 хвилини. Запускати після змін каталогу: .\build\Test-AppCatalog.ps1
param([string]$Only)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$catalog = Get-Content (Join-Path $PSScriptRoot '..\config\apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$bad = @()
foreach ($app in $catalog.apps | Where-Object { -not $Only -or $_.id -like $Only }) {
    $source = if ($app.source) { $app.source } else { 'winget' }
    $out = & winget show --id $app.id --exact --source $source --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { Write-Host "OK    $($app.id)" -ForegroundColor Green }
    else { Write-Host "НЕМАЄ $($app.id) ($source): код $LASTEXITCODE" -ForegroundColor Red; $bad += $app.id }
}
if ($bad) { Write-Host "Не знайдено: $($bad -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'Усі пакети знайдено.' -ForegroundColor Green
