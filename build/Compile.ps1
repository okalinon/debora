<#
.SYNOPSIS
    Збирає dist\Debora.ps1 — один файл з усім кодом і вбудованою конфігурацією.
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
# Звичайна збірка (без -OutDir) ще й оновлює Live\ — «живу» версію, яку користувач запускає для перевірки
$updateLive = -not $OutDir
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
$configFiles = 'tweaks.json', 'presets.json', 'checks.json', 'lifecycle.json', 'known-bloat.json', 'software-risks.json', 'driver-sources.json', 'apps.json', 'startup-known.json', 'bugchecks.json', 'battery-charge-limit.json', 'debloat.json'
$configFiles += @(Get-ChildItem (Join-Path $PSScriptRoot '..\config') -Filter 'lang-*.json' | ForEach-Object Name)   # словники мов
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
# Стиснено (gzip + base64, «назва NUL вміст NUL …»): ≈880 КБ JSON і розмітки PowerShell розбирав і передавав
# на перевірку антивірусу (AMSI) на кожному запуску (≈0,1 с); розпакування — ≈20 мс
[void]$sb.AppendLine('# ----- config -----')
$pack = New-Object Text.StringBuilder
foreach ($name in $configFiles) {
    $json = Read-Utf8 (Join-Path $config $name)
    [void]$pack.Append($name).Append([char]0).Append($json.TrimEnd()).Append([char]0)
}
foreach ($name in 'MainWindow.xaml') {
    $xaml = Read-Utf8 (Join-Path $src "ui\$name")
    [xml]$xaml | Out-Null   # розмітка має бути коректним XML
    [void]$pack.Append($name).Append([char]0).Append($xaml.TrimEnd()).Append([char]0)
}
$bytes = [Text.Encoding]::UTF8.GetBytes($pack.ToString())
$ms = New-Object IO.MemoryStream
$gz = New-Object IO.Compression.GZipStream $ms, ([IO.Compression.CompressionLevel]::Optimal)
$gz.Write($bytes, 0, $bytes.Length); $gz.Dispose()
$b64 = [Convert]::ToBase64String($ms.ToArray())
[void]$sb.AppendLine('$script:D9Embedded = @{}')
[void]$sb.AppendLine('& {')
[void]$sb.AppendLine("    `$text = '" + (([regex]::Matches($b64, '.{1,120}') | ForEach-Object Value) -join "`n") + "'")
[void]$sb.AppendLine('    $packed = [Convert]::FromBase64String(($text -replace ''\s'', ''''))')
[void]$sb.AppendLine(@'
    $gz = New-Object IO.Compression.GZipStream (New-Object IO.MemoryStream (, $packed)), ([IO.Compression.CompressionMode]::Decompress)
    $parts = (New-Object IO.StreamReader $gz, ([Text.Encoding]::UTF8)).ReadToEnd().Split([char]0)
    for ($i = 0; $i + 1 -lt $parts.Count; $i += 2) { $script:D9Embedded[$parts[$i]] = $parts[$i + 1] }
}
'@)
[void]$sb.AppendLine('#endregion D9-COMPILED')

# Великі бази — в окремому файлі Debora.dat (читає Get-D9TrailingBlob): як рядкові константи вони
# сповільнювали кожен запуск на ~3 с, а коментарем у кінці Debora.ps1 — ще на ≈0,14 с (розбір і AMSI)
$data = New-Object Text.StringBuilder
[void]$data.AppendLine('<#D9-DATA')
# Іконки програм (knowledge/app-icons/*.png, збирає build\Update-AppIcons.ps1): «id<TAB>base64» у gzip
$iconDir = Join-Path $root 'knowledge\app-icons'
if (Test-Path $iconDir) {
    $tsv = New-Object Text.StringBuilder
    foreach ($f in Get-ChildItem $iconDir -Filter '*.png' | Sort-Object Name) {
        [void]$tsv.Append($f.BaseName).Append("`t").Append([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))).Append("`n")
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($tsv.ToString())
    $ms = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream $ms, ([IO.Compression.CompressionLevel]::Optimal)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Dispose()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    [void]$data.AppendLine('@@app-icons.tsv.gz')
    [void]$data.AppendLine((([regex]::Matches($b64, '.{1,120}') | ForEach-Object Value) -join "`n"))
}
foreach ($name in $knowledgeFiles) {
    [void]$data.AppendLine("@@$name.gz")
    [void]$data.AppendLine((ConvertTo-D9EmbeddedIds (Join-Path $root "knowledge\$name")))
}
[void]$data.AppendLine('D9-DATA#>')

$compiled = [regex]::Replace($main, $pattern, { param($m) $sb.ToString().TrimEnd() })
$compiled = $compiled.TrimEnd() + "`r`n"
if ($Version) {
    $compiled = $compiled -replace "\`$script:D9Version\s*=\s*'[^']*'", "`$script:D9Version  = '$Version'"
}

# 4. Запис (UTF-8 з BOM — інакше PowerShell 5.1 ламає кирилицю)
Write-Host "4/5 Запис..." -ForegroundColor Cyan
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$outFile = Join-Path $OutDir 'Debora.ps1'
[IO.File]::WriteAllText($outFile, $compiled, $utf8Bom)
$datFile = Join-Path $OutDir 'Debora.dat'
[IO.File]::WriteAllText($datFile, $data.ToString(), (New-Object Text.UTF8Encoding $false))
Copy-Item (Join-Path $PSScriptRoot 'run.bat') (Join-Path $OutDir 'run.bat') -Force
Copy-Item (Join-Path $PSScriptRoot 'run-menu.bat') (Join-Path $OutDir 'run-menu.bat') -Force
Copy-Item (Join-Path $PSScriptRoot 'Інструкція.txt') (Join-Path $OutDir 'Інструкція.txt') -Force
$hash = (Get-FileHash $outFile -Algorithm SHA256).Hash.ToLower()
$datHash = (Get-FileHash $datFile -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS'), "$hash  Debora.ps1`n$datHash  Debora.dat`n", (New-Object Text.UTF8Encoding $false))

# 5. Перевірка результату парсером
Write-Host "5/5 Перевірка парсером..." -ForegroundColor Cyan
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($outFile, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { $parseErrors | ForEach-Object { Write-Host "  $($_.Message) @ $($_.Extent.StartLineNumber)" -ForegroundColor Red }; throw "Зібраний файл не розбирається" }
# Самоперевірка вікна в окремому процесі (без показу): ловить помилки, яких парсер не бачить
# (наприклад, вбудована конфігурація не розпакувалась) — до того, як збірка потрапить у Live\
$selfLog = Join-Path ([IO.Path]::GetTempPath()) "d9-selftest-$PID.log"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $outFile -Gui -SelfTest -LogPath $selfLog *> $null
$selfCode = $LASTEXITCODE
if ($selfCode -ne 0) {
    $tail = if (Test-Path $selfLog) { (Get-Content $selfLog -Tail 3 -Encoding UTF8) -join "`n" } else { '' }
    throw "Самоперевірка зібраного файлу не пройшла (код $selfCode):`n$tail"
}
if (Test-Path $selfLog) { [IO.File]::Delete($selfLog) }
Write-Host "    самоперевірка вікна: OK"

$size = [math]::Round((Get-Item $outFile).Length / 1KB, 1)
Write-Host ""
Write-Host "Готово: $outFile ($size КБ)" -ForegroundColor Green
Write-Host "SHA256: $hash"

# Жива версія: лише файли пакета; папки «Звіти», «Драйвери» та інше, що створила програма, не чіпаємо
if ($updateLive) {
    $live = Join-Path $root 'Live'
    if (-not (Test-Path $live)) { New-Item -ItemType Directory -Path $live | Out-Null }
    Get-ChildItem $OutDir -File | Copy-Item -Destination $live -Force
    Write-Host "Live: $live (запуск — run.bat)" -ForegroundColor Green
}
