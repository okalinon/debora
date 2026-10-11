# Менеджер драйверів: звіт «що потрібно і де взяти» та встановлення драйверів з папки.

# ---------- Звіт ----------

$script:D9KeyDriverClasses = @{
    Display = 'Відеокарта'; Net = 'Мережа'; Media = 'Звук'; Bluetooth = 'Bluetooth'
    HIDClass = 'Тачпад / пристрої введення'; Mouse = 'Миша / тачпад'; System = 'Системні (чипсет)'
    SCSIAdapter = 'Контролер дисків'; HDC = 'Контролер дисків'; Camera = 'Камера'; Image = 'Камера'
}

# Назви класів пристроїв (як у Диспетчері пристроїв); невідомий клас показується як є
$script:D9DeviceClassNames = @{
    System = 'Системні пристрої'; HIDClass = 'Пристрої введення (HID)'; Processor = 'Процесори'; Net = 'Мережа'
    Bluetooth = 'Bluetooth'; MEDIA = 'Звук, відео та ігрові контролери'; SoftwareDevice = 'Програмні пристрої'; Volume = 'Томи дисків'
    USB = 'Контролери USB'; SoftwareComponent = 'Програмні компоненти'; Firmware = 'Мікропрограми (UEFI)'; AudioEndpoint = 'Аудіовходи й аудіовиходи'
    SCSIAdapter = 'Контролери дисків'; HDC = 'Контролери дисків'; Keyboard = 'Клавіатури'; Ports = 'Порти (COM і LPT)'; VolumeSnapshot = 'Тіньові копії'
    DiskDrive = 'Диски'; Display = 'Відеоадаптери'; Mouse = 'Миші й тачпади'; Battery = 'Батареї'; Computer = 'Комп''ютер'
    USBDevice = 'Пристрої USB'; Monitor = 'Монітори'; AudioProcessingObject = 'Звукові ефекти'; UCM = 'USB Type-C'
    Camera = 'Камери'; Image = 'Камери й сканери'; SecurityDevices = 'Безпека (TPM)'; Printer = 'Принтери'; PrintQueue = 'Черги друку'
    Biometric = 'Біометрія'; SmartCardReader = 'Зчитувачі смарт-карт'; Sensor = 'Датчики'; Extension = 'Розширення драйверів'
    CDROM = 'Оптичні приводи'; WPD = 'Портативні пристрої'; MTD = 'Пам''ять'; SDHost = 'Кардридери (SD)'; Infrared = 'Інфрачервоні пристрої'
}

function Get-D9DeviceClassName {
    param([string]$Class)
    if (-not $Class) { return (T-D9 'Інші пристрої') }
    $n = $script:D9DeviceClassNames[$Class]
    if ($n) { T-D9 $n } else { $Class }
}

# Віртуальні й програмні пристрої (томи, програмні пристрої Windows, кореневі віртуальні адаптери) — не «залізо»
function Test-D9VirtualDevice {
    param([string]$InstanceId, [string]$Class)
    $u = $InstanceId.ToUpper()
    if ($Class -in 'Volume', 'VolumeSnapshot', 'SoftwareDevice', 'AudioEndpoint', 'AudioProcessingObject', 'PrintQueue', 'LegacyDriver') { return $true }
    $u -match '^(ROOT|SWD|SW|HTREE|ACPI_HAL|UMB|STORAGE\\VOLUME|\{[0-9A-F-]+\})\\'
}

# Усі пристрої ПК з драйверами: тип, назва, виробник, версія/дата/постачальник/INF драйвера, підпис, стан,
# ідентифікатор обладнання. $Entities — уже прочитаний Win32_PnPEntity (читання триває кілька секунд).
function Get-D9DeviceInventory {
    param([object[]]$Entities, [datetime]$Now = (Get-Date))
    if (-not $Entities) { $Entities = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue) }
    $drivers = @{}
    foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)) { if ($d.DeviceID) { $drivers[[string]$d.DeviceID] = $d } }
    foreach ($e in $Entities) {
        if (-not $e.DeviceID) { continue }
        $d = $drivers[[string]$e.DeviceID]
        $class = if ($e.PNPClass) { [string]$e.PNPClass } elseif ($d.DeviceClass) { [string]$d.DeviceClass } else { '' }
        $hwid = @($e.HardwareID) | Select-Object -First 1
        $info = if ($hwid -match '^(PCI|USB|HDAUDIO|INTELAUDIO|ACPI|HID)\\') { Resolve-D9Device @($e.HardwareID) } else { $null }
        $date = if ($d.DriverDate) { [datetime]$d.DriverDate } else { $null }
        $provider = [string]$d.DriverProviderName
        $code = [int]$e.ConfigManagerErrorCode
        $status = if ($code -eq 0) { 'ok' } elseif ($code -eq 22) { 'disabled' } elseif ($code -eq 28) { 'nodriver' } else { 'problem' }
        # Вбудовані драйвери Windows мають умовну дату 21.06.2006, чипсетні INF Intel — 1968 р.: вік за ними не рахуємо
        $inbox = $date -and $date.Year -lt 2010
        $ageYears = if ($date -and -not $inbox) { [math]::Round(($Now - $date).TotalDays / 365.25, 1) } else { $null }
        [pscustomobject]@{
            Class       = $class
            ClassName   = Get-D9DeviceClassName $class
            Name        = $(if ($e.Name) { [string]$e.Name } else { Get-D9DeviceDisplayName $info $null })
            Recognized  = $(if ($info -and ($info.Name -or $info.Vendor)) { Get-D9DeviceDisplayName $info $null })
            Manufacturer = [string]$e.Manufacturer
            Provider    = $provider
            Version     = [string]$d.DriverVersion
            Date        = $date
            DateText    = $(if (-not $date) { '' } elseif ($date.Year -lt 1990) { T-D9 'INF чипсета' } elseif ($inbox) { T-D9 'вбудований' } else { $date.ToString('dd.MM.yyyy') })
            AgeYears    = $ageYears
            Inf         = [string]$d.InfName
            Signed      = $(if ($d) { [bool]$d.IsSigned } else { $null })
            Status      = $status
            StatusText  = $(switch ($status) { 'ok' { T-D9 'працює' } 'disabled' { T-D9 'вимкнено' } 'nodriver' { T-D9 'немає драйвера' } default { Get-D9DeviceErrorText $code } })
            ErrorCode   = $code
            HardwareId  = [string]$hwid
            InstanceId  = [string]$e.DeviceID
            Virtual     = Test-D9VirtualDevice ([string]$e.DeviceID) $class
            ThirdParty  = [bool]($provider -and $provider -ne 'Microsoft')
        }
    }
}

# Фільтр переліку для вікна й командного рядка: hardware (типово) | all | thirdparty | problems | old
function Select-D9DeviceInventory {
    param([object[]]$Devices, [string]$View = 'hardware', [string]$Search, [double]$OldYears = 3)
    $list = switch ($View) {
        'all'        { @($Devices) }
        'thirdparty' { @($Devices | Where-Object ThirdParty) }
        'problems'   { @($Devices | Where-Object { $_.Status -ne 'ok' }) }
        'old'        { @($Devices | Where-Object { $_.ThirdParty -and $_.AgeYears -ge $OldYears }) }
        default      { @($Devices | Where-Object { -not $_.Virtual }) }
    }
    if ($Search) {
        $s = $Search.Trim()
        $list = @($list | Where-Object { "$($_.Name) $($_.Recognized) $($_.ClassName) $($_.Manufacturer) $($_.Provider) $($_.Version) $($_.Inf) $($_.HardwareId)" -like "*$s*" })
    }
    @($list | Sort-Object ClassName, Name)
}

# Однакові пристрої з тим самим драйвером (20 потоків процесора, кілька HID-колекцій) — одним рядком з кількістю
function Group-D9DeviceInventory {
    param([object[]]$Devices)
    foreach ($g in @($Devices | Group-Object { "$($_.ClassName)|$($_.Name)|$($_.Version)|$($_.Provider)|$($_.Status)" })) {
        $first = $g.Group[0]
        $first | Select-Object *, @{ n = 'Count'; e = { $g.Count } }
    }
}

# Підсумок: «Пристроїв 228 (обладнання 140), сторонніх драйверів 45, з проблемами 0, старших за 3 роки 6»
function Get-D9DeviceInventorySummary {
    param([object[]]$Devices, [double]$OldYears = 3)
    T-D9 'Пристроїв: {0} (обладнання — {1}), сторонніх драйверів: {2}, з проблемами: {3}, сторонніх драйверів старших за {4} роки: {5}.' @($Devices).Count @($Devices | Where-Object { -not $_.Virtual }).Count @($Devices | Where-Object ThirdParty).Count @($Devices | Where-Object { $_.Status -ne 'ok' }).Count $OldYears @($Devices | Where-Object { $_.ThirdParty -and $_.AgeYears -ge $OldYears }).Count
}

# CSV для Excel: роздільник — із регіональних налаштувань (у нас «;»), UTF-8 з BOM, щоб кирилиця відкрилась правильно
function Export-D9DeviceInventoryCsv {
    param([Parameter(Mandatory)][object[]]$Devices, [Parameter(Mandatory)][string]$Path)
    $rows = foreach ($d in @($Devices | Sort-Object ClassName, Name)) {
        $o = [ordered]@{}
        $o[(T-D9 'Тип')] = $d.ClassName; $o[(T-D9 'Пристрій')] = $d.Name; $o[(T-D9 'Розпізнано')] = $d.Recognized
        $o[(T-D9 'Виробник')] = $d.Manufacturer; $o[(T-D9 'Версія')] = $d.Version; $o[(T-D9 'Дата')] = $d.DateText
        $o[(T-D9 'Постачальник')] = $d.Provider; $o['INF'] = $d.Inf
        $o[(T-D9 'Підписаний')] = if ($null -eq $d.Signed) { '' } elseif ($d.Signed) { T-D9 'так' } else { T-D9 'ні' }
        $o[(T-D9 'Стан')] = $d.StatusText; $o[(T-D9 'Віртуальний')] = $(if ($d.Virtual) { T-D9 'так' } else { T-D9 'ні' }); $o['Hardware ID'] = $d.HardwareId; $o['Instance ID'] = $d.InstanceId
        [pscustomobject]$o
    }
    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Delimiter ((Get-Culture).TextInfo.ListSeparator)
}

function Get-D9DriverReport {
    param([Parameter(Mandatory)]$SystemInfo)
    $oem = Get-D9OemSupport $SystemInfo
    $entities = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)
    $problems = @($entities | Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
        Where-Object { $_.ConfigManagerErrorCode -notin 22, 45 } | ForEach-Object {
            $info = Resolve-D9Device @($_.HardwareID)
            $reason = $script:D9DeviceErrors[[int]$_.ConfigManagerErrorCode]
            [pscustomobject]@{
                Name     = Get-D9DeviceDisplayName $info $_.Name
                Windows  = $_.Name
                Class    = $_.PNPClass
                Reason   = if ($reason) { Get-D9DeviceErrorText ([int]$_.ConfigManagerErrorCode) } else { T-D9 'код {0}' $_.ConfigManagerErrorCode }
                Info     = $info
                Links    = @(Get-D9DriverLinks $info $oem)
            }
        })
    $devices = @(Get-D9DeviceInventory -Entities $entities)
    # Важливі встановлені драйвери (коротка таблиця для командного рядка): відео, мережа, звук… від виробників
    $important = @($devices | Where-Object {
            $_.Version -and $script:D9KeyDriverClasses.ContainsKey($_.Class) -and $_.ThirdParty -and $_.InstanceId -match '^(PCI|HDAUDIO|ACPI|USB)\\'
        } | Sort-Object Class, Name -Unique | ForEach-Object {
            [pscustomobject]@{ Group = T-D9 $script:D9KeyDriverClasses[$_.Class]; Name = $_.Name; Version = $_.Version; Date = $_.DateText; Provider = $_.Provider }
        })
    [pscustomobject]@{ Oem = $oem; Problems = $problems; Important = $important; Devices = $devices }
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

# Чи ідентифікує ID конкретне обладнання виробника. Загальні ID (ACPI\PNP0A08 — шина PCI Express,
# *PNP0C50, PCI\CC_0C03 — клас пристрою) є в кожному ПК: за ними драйвер іншого виробника «підійшов» би
# до чужого заліза (наприклад, фільтр шини AMD — до ПК з Intel). Такі збіги не враховуємо.
function Test-D9SpecificId {
    param([string]$Id)
    $u = "$Id".ToUpper()
    if ($u -match '^PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}') { return $true }
    if ($u -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}') { return $true }
    if ($u -match '^(HDAUDIO|INTELAUDIO)\\FUNC_[0-9A-F]+&VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}') { return $true }
    if ($u -match '^HID\\(VID|VEN)_[0-9A-F]{4}&(PID|DEV)_[0-9A-F]{4}') { return $true }
    if ($u -match '^(ACPI|HID)\\VEN_([A-Z0-9]+)&DEV_') { return $Matches[2] -ne 'PNP' }
    if ($u -match '^(ACPI|HID)\\([A-Z]{3,4})[0-9A-F]{4}\b') { return $Matches[2] -notin 'PNP', 'VEN' }
    if ($u -match '^(BTHENUM|BTHLEDEVICE)\\.*(VID|VEN)&?[_]?[0-9A-F]{4}') { return $true }
    return $false
}

function Expand-D9DriverArchives {
    param([string]$Folder)
    # Кілька проходів: архіви бувають усередині архівів
    for ($pass = 0; $pass -lt 3; $pass++) {
        $new = 0
        foreach ($zip in Get-ChildItem $Folder -Filter '*.zip' -Recurse -File -ErrorAction SilentlyContinue) {
            $target = Join-Path $zip.DirectoryName ("_розпаковано\" + $zip.BaseName)
            if (Test-Path $target) { continue }
            Write-D9Log ('  ' + (T-D9 'Розпаковую {0}...' $zip.Name)) Detail
            try { Expand-Archive -LiteralPath $zip.FullName -DestinationPath $target -Force; $new++ }
            catch { Write-D9Log ('  ' + (T-D9 'Не вдалося розпакувати {0}: {1}' $zip.Name $_.Exception.Message)) Warn }
        }
        if (-not $new) { break }
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
        $specific = @($inf.Ids | Where-Object { Test-D9SpecificId $_ })
        $hits = @($specific | ForEach-Object { $index[$_.ToUpper()] } | Where-Object { $_ })
        if (-not $hits) { continue }
        $matchedDevices = @($hits.Device | Sort-Object PNPDeviceID -Unique)
        [pscustomobject]@{
            Inf     = $inf
            Devices = $matchedDevices
            Exact   = [bool]($hits | Where-Object Exact)
            Ids     = @($specific | Where-Object { $index.ContainsKey($_.ToUpper()) })
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
    # Пакети, з яких не підійшов жоден INF, але є інсталятор (.exe/.msi) — їх людина запускає вручну
    $used = @($chosen | ForEach-Object { $_.Inf.Path })
    $roots = @(Get-ChildItem (Join-Path $Folder '_розпаковано') -Directory -ErrorAction SilentlyContinue) +
             @(Get-ChildItem $Folder -Directory -ErrorAction SilentlyContinue | Where-Object Name -ne '_розпаковано')
    $installers = foreach ($r in $roots) {
        if ($used | Where-Object { $_.StartsWith($r.FullName + '\', [StringComparison]::OrdinalIgnoreCase) }) { continue }
        $exe = Get-ChildItem $r.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)(setup|install)[^\\]*\.exe$|\.msi$' } |
            Sort-Object { ($_.FullName.Split('\')).Count }, { -$_.Length } | Select-Object -First 1
        if ($exe) { [pscustomobject]@{ Package = $r.Name; Path = $exe.FullName; Name = $exe.Name } }
    }
    [pscustomobject]@{ Folder = $Folder; Infs = $infs.Count; Packages = @($result | Sort-Object Order, Name); Installers = @($installers) }
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
