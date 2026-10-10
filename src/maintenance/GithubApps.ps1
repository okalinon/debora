# Програми з релізів GitHub (у config/apps.json: "source": "github", "repo": "власник/назва", "match": "регулярний вираз назви в
# «Програмах і засобах»). Для програм, яких немає у winget: останній реліз → MSI під архітектуру Windows → перевірка SHA-256
# (digest від GitHub або SHA256SUMS.txt автора) → тихе встановлення msiexec. Оновлення — той самий MSI новішої версії поверх.

$script:D9GithubReleases = @{}

function Get-D9GithubRelease {
    param([Parameter(Mandatory)][string]$Repo)
    if (-not $script:D9GithubReleases.ContainsKey($Repo)) {
        $headers = @{ 'User-Agent' = 'Debora'; 'Accept' = 'application/vnd.github+json' }
        $script:D9GithubReleases[$Repo] = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -UseBasicParsing -TimeoutSec 20
    }
    $script:D9GithubReleases[$Repo]
}

# Архітектура Windows (не процесу): x64 | arm64 | x86
function Get-D9OsArch {
    $a = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($a -eq 'ARM64') { return 'arm64' }
    if ($a -eq 'AMD64') { return 'x64' }
    return 'x86'
}

# Інсталятор MSI для архітектури; на ARM64 підходить і x64 (емуляція). Портативні архіви не беремо.
function Select-D9GithubAsset {
    param([Parameter(Mandatory)]$Release, [string]$Arch = (Get-D9OsArch))
    $msi = @($Release.assets | Where-Object { $_.name -match '\.msi$' -and $_.name -notmatch 'portable' })
    $patterns = @{
        arm64 = @('arm64|aarch64', 'x64|amd64|x86_64')
        x64   = @('x64|amd64|x86_64')
        x86   = @('x86(?!_64)|i686|win32')
    }[$Arch]
    foreach ($p in $patterns) {
        $hit = $msi | Where-Object { $_.name -match "(?i)(^|[-_.])($p)([-_.]|$)" } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

# Версія з тегу: v0.6.0 → 0.6.0, artcraft-v0.41.0 → 0.41.0
function ConvertFrom-D9ReleaseTag {
    param([string]$Tag)
    if ($Tag -match '(\d+(\.\d+){1,3})') { return $Matches[1] }
    return $Tag
}

# Очікуваний SHA-256 файлу релізу: поле digest від GitHub, інакше SHA256SUMS.txt автора
function Get-D9GithubAssetHash {
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)]$Asset)
    if ([string]$Asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { return $Matches[1].ToUpper() }
    $sums = $Release.assets | Where-Object { $_.name -match '(?i)^sha256sums(\.txt)?$' } | Select-Object -First 1
    if (-not $sums) { return $null }
    $text = (Invoke-WebRequest $sums.browser_download_url -UseBasicParsing -TimeoutSec 30).Content
    if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    foreach ($line in $text -split "`n") {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $Asset.name) { return $Matches[1].ToUpper() }
    }
    return $null
}

# Встановлена версія (з «Програм і засобів») або $null
function Get-D9GithubAppVersion {
    param([Parameter(Mandatory)]$App)
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $pattern = if ($App.match) { [string]$App.match } else { '^' + [regex]::Escape([string]$App.name) + '$' }
    foreach ($root in $roots) {
        foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and $p.DisplayName -match $pattern) { return [string]$(if ($p.DisplayVersion) { $p.DisplayVersion } else { '?' }) }
        }
    }
    return $null
}

function Test-D9VersionNewer {
    param([string]$Available, [string]$Installed)
    $a = $null; $i = $null
    if ([version]::TryParse(($Available -replace '[^\d.]', ''), [ref]$a) -and [version]::TryParse(($Installed -replace '[^\d.]', ''), [ref]$i)) { return $a -gt $i }
    return $Available -ne $Installed
}

# Завантажує, перевіряє й тихо встановлює MSI. Повертає рядок як Install-D9Apps: id, name, result, code.
function Install-D9GithubApp {
    param([Parameter(Mandatory)]$App)
    $row = { param($result, $code) [pscustomobject]@{ id = $App.id; name = $App.name; result = $result; code = $code } }
    try {
        $rel = Get-D9GithubRelease $App.repo
        $asset = Select-D9GithubAsset $rel
        if (-not $asset) { Write-D9Log "  $($App.name): у релізі $($rel.tag_name) немає інсталятора для Windows $(Get-D9OsArch)" Error; return & $row 'notFound' -1 }
        $version = ConvertFrom-D9ReleaseTag $rel.tag_name
        $installed = Get-D9GithubAppVersion $App
        if ($installed -and -not (Test-D9VersionNewer $version $installed)) { Write-D9Log "  $($App.name): уже встановлено версію $installed" Ok; return & $row 'already' 0 }
        $dir = Join-Path ([IO.Path]::GetTempPath()) 'debora-apps'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $file = Join-Path $dir $asset.name
        Write-D9Log "  Завантаження $($asset.name) ($(Format-D9Size $asset.size)) з github.com/$($App.repo)..." Detail
        Invoke-WebRequest $asset.browser_download_url -OutFile $file -UseBasicParsing -TimeoutSec 600
        $expected = Get-D9GithubAssetHash $rel $asset
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($expected -and $expected -ne $actual) { [IO.File]::Delete($file); Write-D9Log "  $($App.name): контрольна сума не збігається — файл пошкоджено або підмінено, не встановлюю" Error; return & $row 'failed' -2 }
        if (-not $expected) { Write-D9Log "  Автор не опублікував контрольної суми — встановлюю без перевірки." Warn }
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$file`" /qn /norestart" -Wait -PassThru
        [IO.File]::Delete($file)
        $result = switch ($p.ExitCode) { 0 { 'installed' } 3010 { 'reboot' } 1641 { 'reboot' } 1638 { 'already' } default { 'failed' } }
        $text = @{ installed = "встановлено версію $version"; reboot = "встановлено $version, потрібне перезавантаження"; already = 'уже встановлено'; failed = "помилка msiexec (код $($p.ExitCode))" }[$result]
        Write-D9Log "  $($App.name): $text" $(if ($result -eq 'failed') { 'Error' } elseif ($result -eq 'reboot') { 'Warn' } else { 'Ok' })
        return & $row $result $p.ExitCode
    } catch {
        Write-D9Log "  $($App.name): $($_.Exception.Message)" Error
        return & $row 'failed' -1
    }
}

# Встановлені програми з GitHub: id → версія
function Get-D9GithubInstalled {
    param([object[]]$Apps = @((Import-D9AppCatalog).apps | Where-Object source -eq 'github'))
    $result = @{}
    foreach ($a in $Apps) { $v = Get-D9GithubAppVersion $a; if ($v) { $result[$a.id] = $v } }
    $result
}

# Оновлення для встановлених програм з GitHub — у форматі Get-D9AppUpgrades (Name, Id, Version, Available)
function Get-D9GithubUpgrades {
    param([object[]]$Apps = @((Import-D9AppCatalog).apps | Where-Object source -eq 'github'))
    $installed = Get-D9GithubInstalled $Apps
    foreach ($a in $Apps | Where-Object { $installed.ContainsKey($_.id) }) {
        $latest = try { ConvertFrom-D9ReleaseTag (Get-D9GithubRelease $a.repo).tag_name } catch { $null }
        if ($latest -and (Test-D9VersionNewer $latest $installed[$a.id])) {
            [pscustomobject]@{ Name = $a.name; Id = $a.id; Version = $installed[$a.id]; Available = $latest }
        }
    }
}
