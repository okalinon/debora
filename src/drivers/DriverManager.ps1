# Менеджер драйверів: звіт «що потрібно і де взяти» та встановлення драйверів з папки.

# ---------- Звіт ----------

$script:D9KeyDriverClasses = @{
    Display = 'Відеокарта'; Net = 'Мережа'; Media = 'Звук'; Bluetooth = 'Bluetooth'
    HIDClass = 'Тачпад / пристрої введення'; Mouse = 'Миша / тачпад'; System = 'Системні (чипсет)'
    SCSIAdapter = 'Контролер дисків'; HDC = 'Контролер дисків'; Camera = 'Камера'; Image = 'Камера'
}

function Get-D9DriverReport {
    param([Parameter(Mandatory)]$SystemInfo)
    $oem = Get-D9OemSupport $SystemInfo
    $problems = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue |
        Where-Object { $_.ConfigManagerErrorCode -notin 22, 45 } | ForEach-Object {
            $info = Resolve-D9Device @($_.HardwareID)
            $reason = $script:D9DeviceErrors[[int]$_.ConfigManagerErrorCode]
            [pscustomobject]@{
                Name     = Get-D9DeviceDisplayName $info $_.Name
                Windows  = $_.Name
                Class    = $_.PNPClass
                Reason   = if ($reason) { $reason } else { "код $($_.ConfigManagerErrorCode)" }
                Info     = $info
                Links    = @(Get-D9DriverLinks $info $oem)
            }
        })
    # Важливі встановлені драйвери: щоб бачити версію й вік
    $important = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object {
            $_.DeviceName -and $script:D9KeyDriverClasses.ContainsKey([string]$_.DeviceClass) -and $_.DriverProviderName -ne 'Microsoft' -and $_.DeviceID -match '^(PCI|HDAUDIO|ACPI|USB)\\'
        } | Sort-Object DeviceClass, DeviceName -Unique | ForEach-Object {
            [pscustomobject]@{
                Group    = $script:D9KeyDriverClasses[[string]$_.DeviceClass]
                Name     = $_.DeviceName
                Version  = $_.DriverVersion
                # Чипсетні INF Intel мають умовну дату 1968 р. — вони лише називають пристрій, оновлювати нічого
                Date     = if (-not $_.DriverDate) { '' } elseif (([datetime]$_.DriverDate).Year -lt 1990) { 'INF чипсета' } else { ([datetime]$_.DriverDate).ToString('dd.MM.yyyy') }
                Provider = $_.DriverProviderName
            }
        })
    [pscustomobject]@{ Oem = $oem; Problems = $problems; Important = $important }
}

# ---------- Розбір пакетів драйверів ----------

# Інформація з INF: клас, постачальник, версія й дата, усі Hardware ID з розділів моделей
function Get-D9InfInfo {
    param([Parameter(Mandatory)][string]$Path)
    $text = try { [IO.File]::ReadAllText($Path) } catch { return $null }
    if ($text.IndexOf([char]0) -ge 0) { $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::Unicode) }   # INF у UTF-16
    $class = if ($text -match '(?im)^\s*Class\s*=\s*"?([^"\r\n;]+)') { $Matches[1].Trim() }
    $provider = if ($text -match '(?im)^\s*Provider\s*=\s*([^\r\n;]+)') { $Matches[1].Trim().Trim('%', '"') }
    $date = $null; $version = $null
    if ($text -match '(?im)^\s*DriverVer\s*=\s*([0-9/]+)\s*,\s*([0-9.]+)') {
        $date = try { [datetime]::ParseExact($Matches[1], 'MM/dd/yyyy', $null) } catch { $null }
        $version = $Matches[2]
    }
    $ids = @([regex]::Matches($text, '(?i)\b(?:PCI|USB|ACPI|HDAUDIO|INTELAUDIO|HID|BTH|BTHENUM|SD|SWC|DISPLAY)\\[^\s,;"\r\n]+|(?<=[,\s])\*[A-Z]{3}[0-9A-F]{4}\b') |
        ForEach-Object { $_.Value.Trim() } | Where-Object { $_ -notmatch '[%{}]' } | Sort-Object -Unique)
    $is64 = $text -match '(?i)NTamd64'
    [pscustomobject]@{ Path = $Path; Class = $class; Provider = $provider; Version = $version; Date = $date; Ids = $ids; Is64 = $is64 }
}

function Expand-D9DriverArchives {
    param([string]$Folder)
    foreach ($zip in Get-ChildItem $Folder -Filter '*.zip' -Recurse -File -ErrorAction SilentlyContinue) {
        $target = Join-Path $zip.DirectoryName ("_розпаковано\" + $zip.BaseName)
        if (Test-Path $target) { continue }
        try { Expand-Archive -LiteralPath $zip.FullName -DestinationPath $target -Force } catch { Write-D9Log "  Не вдалося розпакувати $($zip.Name): $($_.Exception.Message)" Warn }
    }
}

$script:D9DriverClassOrder = @{ System = 0; Net = 1; Bluetooth = 2; Display = 3; HIDClass = 4; Mouse = 4; Keyboard = 4; Media = 5; Camera = 6; Image = 6 }

# Знаходить у папці драйвери, що підходять до пристроїв цього ПК, і вирішує, які варто ставити
function Find-D9DriverPackages {
    param([Parameter(Mandatory)][string]$Folder)
    Expand-D9DriverArchives $Folder
    $infs = @(Get-ChildItem $Folder -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'autorun.inf')
    $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -or $_.CompatibleID })
    $index = @{}
    foreach ($d in $devices) {
        foreach ($id in @($d.HardwareID)) { if ($id) { $index[$id.ToUpper()] += @([pscustomobject]@{ Device = $d; Exact = $true }) } }
        foreach ($id in @($d.CompatibleID)) { if ($id) { $index[$id.ToUpper()] += @([pscustomobject]@{ Device = $d; Exact = $false }) } }
    }
    $candidates = foreach ($f in $infs) {
        $inf = Get-D9InfInfo $f.FullName
        if (-not $inf -or -not $inf.Ids) { continue }
        if ([Environment]::Is64BitOperatingSystem -and -not $inf.Is64) { continue }
        $hits = @($inf.Ids | ForEach-Object { $index[$_.ToUpper()] } | Where-Object { $_ })
        if (-not $hits) { continue }
        $matchedDevices = @($hits.Device | Sort-Object PNPDeviceID -Unique)
        [pscustomobject]@{
            Inf     = $inf
            Devices = $matchedDevices
            Exact   = [bool]($hits | Where-Object Exact)
            Ids     = @($inf.Ids | Where-Object { $index.ContainsKey($_.ToUpper()) })
        }
    }
    # На кожен пристрій — найкращий пакет: точний збіг > загальний, потім новіша дата/версія
    $best = @{}
    foreach ($c in ($candidates | Sort-Object @{ Expression = { $_.Exact }; Descending = $true }, @{ Expression = { $_.Inf.Date }; Descending = $true }, @{ Expression = { ConvertTo-D9Version $_.Inf.Version }; Descending = $true })) {
        foreach ($d in $c.Devices) { if (-not $best.ContainsKey($d.PNPDeviceID)) { $best[$d.PNPDeviceID] = $c } }
    }
    $chosen = @($best.Values | Sort-Object { $_.Inf.Path } -Unique)
    $result = foreach ($c in $chosen) {
        $devs = @($c.Devices | Where-Object { $best[$_.PNPDeviceID] -eq $c })
        $current = @($devs | ForEach-Object { Get-D9DeviceDriverInfo $_.PNPDeviceID })
        $missing = @($devs | Where-Object { $_.ConfigManagerErrorCode -in 1, 10, 18, 28, 31, 37, 39 })
        $newest = ($current | Where-Object date | ForEach-Object { [datetime]$_.date } | Sort-Object -Descending | Select-Object -First 1)
        $status = if ($missing) { 'missing' } elseif (-not $newest -or ($c.Inf.Date -and $c.Inf.Date -gt $newest)) { 'newer' } else { 'current' }
        $info = Resolve-D9Device @($devs[0].HardwareID)
        [pscustomobject]@{
            Name     = Get-D9DeviceDisplayName $info $devs[0].Name
            Class    = $c.Inf.Class
            Status   = $status
            Package  = $c
            Current  = $current
            Order    = $(if ($script:D9DriverClassOrder.ContainsKey([string]$c.Inf.Class)) { $script:D9DriverClassOrder[[string]$c.Inf.Class] } else { 7 })
        }
    }
    $installers = @(Get-ChildItem $Folder -Recurse -File -Include 'setup.exe', 'install.exe', '*.msi' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike '*\_розпаковано\*\_розпаковано\*' })
    [pscustomobject]@{ Folder = $Folder; Infs = $infs.Count; Packages = @($result | Sort-Object Order, Name); Installers = $installers }
}

# Перетворює вибрані пакети на «твіки» з дією driver — далі їх виконує той самий рушій (точка відновлення, журнал, відкат)
function New-D9DriverCatalog {
    param([Parameter(Mandatory)][object[]]$Packages)
    $i = 0
    $tweaks = foreach ($p in $Packages) {
        $i++
        $ver = $p.Package.Inf.Version
        $date = if ($p.Package.Inf.Date) { $p.Package.Inf.Date.ToString('yyyy-MM-dd') } else { '?' }
        [pscustomobject]@{
            id = ('driver.{0:d2}' -f $i); category = 'updates'; risk = 'moderate'; rebootRequired = $true
            name = [pscustomobject]@{ uk = "Драйвер: $($p.Name)"; en = "Driver: $($p.Name)" }
            description = [pscustomobject]@{ uk = $p.Package.Inf.Path; en = $p.Package.Inf.Path }
            actions = @([pscustomobject]@{ type = 'driver'; inf = $p.Package.Inf.Path; name = $p.Name; version = $ver; date = $date; hwids = @($p.Package.Ids) })
        }
    }
    [pscustomobject]@{ Tweaks = @($tweaks); Presets = @() }
}
