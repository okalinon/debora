<#
.SYNOPSIS
    Реліз Debora: збірка → усі тести → zip-пакет із контрольними сумами й нотатками з CHANGELOG.md →
    (з -Publish) реліз на GitHub через GitHub CLI (gh).
.PARAMETER Repo
    «власник/назва» репозиторію GitHub: записується в config\update.json (з нього Debora перевіряє оновлення)
    ще до збірки, тож зібраний файл уже знає, звідки оновлюватись.
.EXAMPLE
    .\build\Release.ps1 -Version 1.0.0
.EXAMPLE
    .\build\Release.ps1 -Version 1.0.0 -Repo olegdev/debora -Publish
#>
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$Repo,
    [switch]$Publish,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$utf8 = New-Object Text.UTF8Encoding $false

if ($Repo) {
    if ($Repo -notmatch '^[\w.-]+/[\w.-]+$') { throw "Repo має бути у вигляді власник/назва: $Repo" }
    $cfgPath = Join-Path $root 'config\update.json'
    $cfg = ConvertFrom-Json ([IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8))
    if ($cfg.repo -ne $Repo) {
        $cfg.repo = $Repo
        [IO.File]::WriteAllText($cfgPath, ((ConvertTo-Json $cfg) + "`n"), $utf8)
        Write-Host "config\update.json: repo = $Repo" -ForegroundColor Cyan
    }
}

# 1. Збірка (з самоперевіркою вікна; оновлює й Live\)
& (Join-Path $PSScriptRoot 'Compile.ps1') -Version $Version
$dist = Join-Path $root 'dist'

# 2. Тести
if (-not $SkipTests) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-All.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Тести не пройшли — реліз зупинено.' }
}

# 3. Пакет: папка Debora-<версія> у zip, щоб після розпакування все лежало разом
$out = Join-Path $root 'release'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }
$name = "Debora-$Version"
$stage = Join-Path $out $name
if (Test-Path $stage) { [IO.Directory]::Delete($stage, $true) }
New-Item -ItemType Directory -Path $stage | Out-Null
Get-ChildItem $dist -File | Copy-Item -Destination $stage
$zip = Join-Path $out "$name.zip"
if (Test-Path $zip) { [IO.File]::Delete($zip) }
Compress-Archive -Path $stage -DestinationPath $zip
[IO.Directory]::Delete($stage, $true)
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$sums = Join-Path $out 'SHA256SUMS'
[IO.File]::WriteAllText($sums, "$zipHash  $name.zip`n", $utf8)

# Нотатки: розділ цієї версії з CHANGELOG.md
$log = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'), [Text.Encoding]::UTF8)
$m = [regex]::Match($log, "(?ms)^## $([regex]::Escape($Version))\b.*?(?=^## |\z)")
$notes = if ($m.Success) { $m.Value.Trim() } else { "## $Version" }
$notesFile = Join-Path $out "notes-$Version.md"
[IO.File]::WriteAllText($notesFile, $notes + "`n`n**SHA-256** ``$name.zip``: ``$zipHash```n", $utf8)

Write-Host ""
Write-Host "Пакет: $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) МБ)" -ForegroundColor Green
Write-Host "SHA256: $zipHash"
Write-Host "Нотатки: $notesFile"

# 4. GitHub
if ($Publish) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw 'GitHub CLI (gh) не встановлено: winget install GitHub.cli, потім gh auth login.' }
    $cfg = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'config\update.json'), [Text.Encoding]::UTF8))
    if (-not $cfg.repo) { throw 'Не вказано репозиторій: -Repo власник/назва.' }
    & gh release create "v$Version" $zip $sums --repo $cfg.repo --title "Debora $Version" --notes-file $notesFile
    if ($LASTEXITCODE -ne 0) { throw 'gh release create не вдався.' }
    Write-Host "Опубліковано: https://github.com/$($cfg.repo)/releases/tag/v$Version" -ForegroundColor Green
}
