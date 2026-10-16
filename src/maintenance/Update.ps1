# Оновлення самої Debora з GitHub Releases (config/update.json → repo «власник/назва»; порожньо — перевірку вимкнено).
# Реліз має zip-архів пакета (Debora-<версія>.zip: Debora.ps1, Debora.dat, Debora.exe, run.bat…). Архів перевіряється
# за SHA-256 (поле digest від GitHub або SHA256SUMS релізу) — без збігу нічого не замінюється. Попередні файли
# зберігаються в %ProgramData%\Debora\update-backup\<версія>; папки користувача («Звіти», «Драйвери») не чіпаються.

$script:D9UpdateFiles = @('Debora.ps1', 'Debora.dat', 'Debora.exe', 'run.bat', 'run-menu.bat', 'Інструкція.txt', 'SHA256SUMS', 'CHANGELOG.md', 'README.md', 'README.uk.md')

function Get-D9UpdateRepo {
    $cfg = try { ConvertFrom-Json (Get-D9ConfigText 'update.json') } catch { $null }
    $repo = [string]$cfg.repo
    if ($repo -match '^[\w.-]+/[\w.-]+$') { return $repo }
    $null
}

# Чи є новіша версія: @{ Available; Version; Current; Asset; Release; Notes; Url } або $null (немає репозиторію, збірка розробника, немає мережі)
function Get-D9UpdateInfo {
    param([string]$Current = $script:D9Version, $Release)
    $repo = Get-D9UpdateRepo
    if (-not $repo -or -not $Current -or $Current -like '*-dev') { return $null }
    if (-not $Release) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $Release = try { Get-D9GithubRelease $repo } catch { Write-D9Log (T-D9 'Не вдалося перевірити оновлення: {0}' $_.Exception.Message) Detail; return $null }
    }
    $version = ConvertFrom-D9ReleaseTag ([string]$Release.tag_name)
    $asset = @($Release.assets | Where-Object { $_.name -match '(?i)^Debora.*\.zip$' }) | Select-Object -First 1
    [pscustomobject]@{
        Available = [bool]($asset -and (Test-D9VersionNewer $version $Current))
        Version   = $version
        Current   = $Current
        Asset     = $asset
        Release   = $Release
        Notes     = [string]$Release.body
        Url       = [string]$Release.html_url
    }
}

# Завантажити, перевірити й замінити файли програми. Повертає шлях нового Debora.ps1.
function Install-D9Update {
    param([Parameter(Mandatory)]$Info, [string]$ProgramDir = $(if ($script:D9ScriptPath) { Split-Path $script:D9ScriptPath }), [string]$DownloadFile)
    if (-not $ProgramDir -or -not (Test-Path -LiteralPath (Join-Path $ProgramDir 'Debora.ps1'))) { throw (T-D9 'Папку програми не знайдено — оновіть вручну: {0}' $Info.Url) }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("debora-update-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $zip = Join-Path $tmp $Info.Asset.name
        if ($DownloadFile) { Copy-Item -LiteralPath $DownloadFile -Destination $zip }
        else {
            $url = [string]$Info.Asset.browser_download_url
            if ($url -notmatch '^https://(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com)/') { throw (T-D9 'Неочікуване джерело оновлення: {0}' $url) }
            Write-D9Log (T-D9 'Завантаження Debora {0}...' $Info.Version)
            Invoke-WebRequest $url -OutFile $zip -UseBasicParsing -TimeoutSec 300
        }
        $expected = Get-D9GithubAssetHash -Release $Info.Release -Asset $Info.Asset
        if (-not $expected) { throw (T-D9 'Для архіву оновлення немає контрольної суми — оновлення скасовано.') }
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpper()
        if ($actual -ne $expected) { throw (T-D9 'Контрольна сума архіву не збігається — оновлення скасовано (очікувано {0}, отримано {1}).' $expected $actual) }
        $x = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $x -Force
        $new = Get-ChildItem $x -Recurse -Filter 'Debora.ps1' | Select-Object -First 1
        if (-not $new) { throw (T-D9 'В архіві оновлення немає Debora.ps1.') }
        $src = $new.DirectoryName
        # Резервна копія поточних файлів
        $backup = Join-Path (Join-Path (Get-D9DataRoot) 'update-backup') ($Info.Current -replace '[^\w.-]', '_')
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        foreach ($n in $script:D9UpdateFiles) {
            $old = Join-Path $ProgramDir $n
            if (Test-Path -LiteralPath $old) { Copy-Item -LiteralPath $old -Destination (Join-Path $backup $n) -Force }
        }
        foreach ($n in $script:D9UpdateFiles) {
            $f = Join-Path $src $n
            if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $ProgramDir $n) -Force }
        }
        Write-D9Log (T-D9 'Debora оновлено: {0} → {1}. Попередні файли: {2}' $Info.Current $Info.Version $backup) Ok
        # Копія для автообслуговування за розкладом — теж нова
        $appCopy = Join-Path (Join-Path (Get-D9DataRoot) 'app') 'Debora.ps1'
        if (Test-Path -LiteralPath $appCopy) { try { [void](Install-D9AppCopy -SourceScript (Join-Path $ProgramDir 'Debora.ps1')) } catch { Write-D9Log (T-D9 'Копію для розкладу не оновлено: {0}' $_.Exception.Message) Warn } }
        Join-Path $ProgramDir 'Debora.ps1'
    } finally {
        try { [IO.Directory]::Delete($tmp, $true) } catch { }
    }
}

# Стан перевірки (раз на добу): %ProgramData%\Debora\update-check.json
function Get-D9UpdateCheckPath { Join-Path (Get-D9DataRoot) 'update-check.json' }

# Автоматична перевірка вимикається в «Параметрах» (HKCU:\Software\Debora\UpdateCheck = 0); кнопкою — завжди можна
function Test-D9UpdateCheckEnabled {
    (Get-ItemProperty 'HKCU:\Software\Debora' -Name UpdateCheck -ErrorAction SilentlyContinue).UpdateCheck -ne 0
}

function Test-D9UpdateCheckDue {
    param([int]$Hours = 20, [datetime]$Now = (Get-Date))
    if (-not (Get-D9UpdateRepo) -or $script:D9Version -like '*-dev' -or -not (Test-D9UpdateCheckEnabled)) { return $false }
    $path = Get-D9UpdateCheckPath
    $s = try { ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) } catch { $null }
    if (-not $s) { return $true }
    $at = try { [datetime]$s.checked } catch { [datetime]::MinValue }
    ($Now - $at).TotalHours -ge $Hours
}

function Save-D9UpdateCheck {
    param([string]$Latest)
    try {
        $root = Get-D9DataRoot
        if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        [IO.File]::WriteAllText((Get-D9UpdateCheckPath), (ConvertTo-Json ([ordered]@{ checked = (Get-Date).ToString('s'); latest = $Latest })), (New-Object Text.UTF8Encoding $false))
    } catch { }
}
