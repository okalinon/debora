<#
.SYNOPSIS
    Збирає dist\Debloater9.ps1 — один файл з усім кодом і вбудованою конфігурацією.
.EXAMPLE
    .\build\Compile.ps1
.EXAMPLE
    .\build\Compile.ps1 -Version 0.1.0
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'

$root   = Split-Path $PSScriptRoot -Parent
$src    = Join-Path $root 'src'
$config = Join-Path $root 'config'
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
$utf8Bom = New-Object Text.UTF8Encoding $true

function Read-Utf8([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF) }

# Порядок важливий: core (Common першим), потім дії
$modules = @(
    'core\Common.ps1', 'core\Catalog.ps1', 'core\SystemInfo.ps1', 'core\Recommender.ps1', 'core\Journal.ps1', 'core\Engine.ps1'
) | ForEach-Object { Join-Path $src $_ }
foreach ($folder in 'actions', 'scan', 'drivers', 'maintenance', 'ui') {
    $modules += Get-ChildItem (Join-Path $src $folder) -Filter '*.ps1' | Sort-Object Name | ForEach-Object FullName
}
$configFiles = 'tweaks.json', 'presets.json', 'checks.json', 'lifecycle.json', 'known-bloat.json', 'software-risks.json', 'driver-sources.json', 'apps.json'
$knowledgeFiles = 'pci.ids', 'usb.ids'

# Бази ідентифікаторів: лише рядки виробників і пристроїв (без коментарів, підсистем і класів), gzip + base64
function ConvertTo-D9EmbeddedIds([string]$Path) {
    $keep = New-Object Text.StringBuilder
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if ($line.StartsWith('C ')) { break }
        if ($line.Length -lt 6 -or $line[0] -eq '#' -or $line.StartsWith("`t`t")) { continue }
        [void]$keep.Append($line).Append("`n")
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($keep.ToString())
    $ms = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream $ms, ([IO.Compression.CompressionLevel]::Optimal)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Dispose()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    return ([regex]::Matches($b64, '.{1,120}') | ForEach-Object Value) -join "`n"
}

# 1. Перевірка каталогу тими самими функціями, що й під час роботи
Write-Host "1/5 Перевірка каталогу..." -ForegroundColor Cyan
foreach ($m in $modules) { . $m }
$script:D9ConfigDir = $config
$catalogErrors = Test-D9Catalog (Import-D9Catalog)
if ($catalogErrors.Count) {
    $catalogErrors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "Каталог містить помилки: $($catalogErrors.Count)"
}
Write-Host "    OK: $(@((Import-D9Catalog).Tweaks).Count) твіків"

# 2. Статичний аналіз (якщо встановлено PSScriptAnalyzer)
Write-Host "2/5 PSScriptAnalyzer..." -ForegroundColor Cyan
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $issues = @(Invoke-ScriptAnalyzer -Path $src -Recurse -Severity Error)
    if ($issues) { $issues | Format-Table -AutoSize | Out-String | Write-Host; throw "PSScriptAnalyzer: помилок $($issues.Count)" }
    Write-Host "    OK"
} else {
    Write-Host "    пропущено: модуль не встановлено (Install-Module PSScriptAnalyzer -Scope CurrentUser)" -ForegroundColor Yellow
}

# 3. Склеювання
Write-Host "3/5 Збирання..." -ForegroundColor Cyan
$main = Read-Utf8 (Join-Path $src 'Main.ps1')
$pattern = '(?s)#region D9-LOAD.*?#endregion D9-LOAD'
if ($main -notmatch $pattern) { throw "У Main.ps1 не знайдено блок #region D9-LOAD" }

$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('#region D9-COMPILED')
foreach ($m in $modules) {
    $relative = $m.Substring($src.Length + 1)
    [void]$sb.AppendLine("# ----- $relative -----")
    [void]$sb.AppendLine((Read-Utf8 $m).TrimEnd())
}
# Вбудована конфігурація — після модулів, бо Catalog.ps1 ініціалізує $script:D9Embedded
[void]$sb.AppendLine('# ----- config -----')
[void]$sb.AppendLine('$script:D9Embedded = @{')
foreach ($name in $configFiles) {
    $json = Read-Utf8 (Join-Path $config $name)
    if ($json -match "(?m)^'@") { throw "$name містить рядок, що починається з '@ — це зламає here-string" }
    [void]$sb.AppendLine("    '$name' = @'")
    [void]$sb.AppendLine($json.TrimEnd())
    [void]$sb.AppendLine("'@")
}
foreach ($name in 'MainWindow.xaml') {
    $xaml = Read-Utf8 (Join-Path $src "ui\$name")
    if ($xaml -match "(?m)^'@") { throw "$name містить рядок, що починається з '@" }
    [xml]$xaml | Out-Null   # розмітка має бути коректним XML
    [void]$sb.AppendLine("    '$name' = @'")
    [void]$sb.AppendLine($xaml.TrimEnd())
    [void]$sb.AppendLine("'@")
}
foreach ($name in $knowledgeFiles) {
    [void]$sb.AppendLine("    '$name.gz' = @'")
    [void]$sb.AppendLine((ConvertTo-D9EmbeddedIds (Join-Path $root "knowledge\$name")))
    [void]$sb.AppendLine("'@")
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('#endregion D9-COMPILED')

$compiled = [regex]::Replace($main, $pattern, { param($m) $sb.ToString().TrimEnd() })
if ($Version) {
    $compiled = $compiled -replace "\`$script:D9Version\s*=\s*'[^']*'", "`$script:D9Version  = '$Version'"
}

# 4. Запис (UTF-8 з BOM — інакше PowerShell 5.1 ламає кирилицю)
Write-Host "4/5 Запис..." -ForegroundColor Cyan
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$outFile = Join-Path $OutDir 'Debloater9.ps1'
[IO.File]::WriteAllText($outFile, $compiled, $utf8Bom)
Copy-Item (Join-Path $PSScriptRoot 'run.bat') (Join-Path $OutDir 'run.bat') -Force
Copy-Item (Join-Path $PSScriptRoot 'run-menu.bat') (Join-Path $OutDir 'run-menu.bat') -Force
Copy-Item (Join-Path $PSScriptRoot 'Інструкція.txt') (Join-Path $OutDir 'Інструкція.txt') -Force
$hash = (Get-FileHash $outFile -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS'), "$hash  Debloater9.ps1`n", (New-Object Text.UTF8Encoding $false))

# 5. Перевірка результату парсером
Write-Host "5/5 Перевірка парсером..." -ForegroundColor Cyan
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($outFile, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { $parseErrors | ForEach-Object { Write-Host "  $($_.Message) @ $($_.Extent.StartLineNumber)" -ForegroundColor Red }; throw "Зібраний файл не розбирається" }

$size = [math]::Round((Get-Item $outFile).Length / 1KB, 1)
Write-Host ""
Write-Host "Готово: $outFile ($size КБ)" -ForegroundColor Green
Write-Host "SHA256: $hash"
