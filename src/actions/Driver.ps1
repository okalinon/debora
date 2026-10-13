# Дія "driver": встановлення драйвера з INF-файлу через pnputil, з резервною копією попереднього.
#   { "type": "driver", "inf": "D:\\Драйвери\\wifi\\netathr10x.inf", "name": "...", "hwids": ["PCI\\VEN_168C&DEV_0042", ...] }
# Знімок стану — які драйвери (oemNN.inf) зараз стоять на пристроях з hwids.
# Перед встановленням поточні сторонні драйвери експортуються в %ProgramData%\Debloater9\driver-backup\<oemNN.inf>.

function Get-D9DriverBackupDir {
    $dir = Join-Path (Get-D9DataRoot) 'driver-backup'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# Копія драйвера є, лише якщо в її папці лежить INF (порожня папка лишається після невдалого експорту)
function Test-D9DriverBackup {
    param([string]$Dir)
    [bool](Test-Path -LiteralPath $Dir) -and [bool](Get-ChildItem -LiteralPath $Dir -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# Список пристроїв читається кілька секунд — тримаємо його хвилину (ідентифікатори обладнання не змінюються)
$script:D9PnpCache = $null
$script:D9PnpCacheTime = [datetime]::MinValue

function Clear-D9PnpCache { $script:D9PnpCache = $null }

# Лише потрібні властивості: Manufacturer сам додає ≈1,5 с до ≈1,5 с решти (виробника беремо з Win32_PnPSignedDriver)
$script:D9PnpProps = @('Name', 'PNPClass', 'ConfigManagerErrorCode', 'DeviceID', 'PNPDeviceID', 'HardwareID', 'CompatibleID', 'Present', 'Status')

# Запит CIM в окремому runspace, щоб два повільні запити (пристрої й драйвери, по 1,5–2,3 с) ішли паралельно
function Start-D9CimQuery {
    param([Parameter(Mandatory)][string]$ClassName, [string[]]$Property)
    $ps = [powershell]::Create()
    [void]$ps.AddCommand('Get-CimInstance').AddParameter('ClassName', $ClassName).AddParameter('ErrorAction', 'SilentlyContinue')
    if ($Property) { [void]$ps.AddParameter('Property', $Property) }
    @{ PS = $ps; Handle = $ps.BeginInvoke() }
}
function Receive-D9CimQuery {
    param([Parameter(Mandatory)]$Query)
    try { @($Query.PS.EndInvoke($Query.Handle)) } catch { @() } finally { $Query.PS.Dispose() }
}

# Виробник пристрою (Win32_PnPEntity.Manufacturer) окремим запитом у фоні: DeviceID → виробник
function Start-D9ManufacturerQuery { Start-D9CimQuery Win32_PnPEntity -Property 'DeviceID', 'Manufacturer' }
function Receive-D9ManufacturerQuery {
    param([Parameter(Mandatory)]$Query)
    $map = @{}
    foreach ($m in @(Receive-D9CimQuery $Query)) { if ($m.DeviceID) { $map[[string]$m.DeviceID] = [string]$m.Manufacturer } }
    $map
}

function Get-D9PnpEntities {
    if (-not $script:D9PnpCache -or ((Get-Date) - $script:D9PnpCacheTime).TotalSeconds -gt 60) {
        $script:D9PnpCache = @(Get-CimInstance Win32_PnPEntity -Property $script:D9PnpProps -ErrorAction SilentlyContinue)
        $script:D9PnpCacheTime = Get-Date
    }
    return $script:D9PnpCache
}

# Пристрої, яким підходить драйвер (за точним збігом Hardware ID або Compatible ID)
function Get-D9DevicesForIds {
    param([string[]]$Ids)
    $want = @{}; foreach ($i in $Ids) { $want[$i.ToUpper()] = $true }
    @(Get-D9PnpEntities | Where-Object {
        @(@($_.HardwareID) + @($_.CompatibleID) | Where-Object { $_ -and $want.ContainsKey($_.ToUpper()) }).Count
    })
}

function Get-D9DeviceDriverInfo {
    param([string]$InstanceId)
    $props = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverDate' -ErrorAction SilentlyContinue
    $get = { param($k) ($props | Where-Object KeyName -eq $k).Data }
    $date = & $get 'DEVPKEY_Device_DriverDate'
    [ordered]@{
        id      = $InstanceId
        inf     = [string](& $get 'DEVPKEY_Device_DriverInfPath')
        version = [string](& $get 'DEVPKEY_Device_DriverVersion')
        date    = if ($date) { ([datetime]$date).ToString('yyyy-MM-dd') } else { $null }
    }
}

function Get-D9DriverState {
    param([Parameter(Mandatory)]$Action)
    $devices = Get-D9DevicesForIds @($Action.hwids)
    return [ordered]@{ devices = @($devices | Sort-Object PNPDeviceID | ForEach-Object { Get-D9DeviceDriverInfo $_.PNPDeviceID }) }
}

# Стан невідомий заздалегідь: pnputil сам вирішує, чи кращий цей драйвер за встановлений
function Test-D9Driver { param([Parameter(Mandatory)]$Action) return $null }

function Invoke-D9Driver {
    param([Parameter(Mandatory)]$Action)
    if (-not (Test-Path -LiteralPath $Action.inf)) { throw (T-D9 'Файл драйвера не знайдено: {0}' "$($Action.inf)") }
    $backup = Get-D9DriverBackupDir
    foreach ($d in (Get-D9DriverState $Action).devices) {
        $dir = Join-Path $backup $d.inf
        if ($d.inf -like 'oem*.inf' -and -not (Test-D9DriverBackup $dir)) {
            # pnputil не створює цільову папку сам («Missing or invalid target directory»)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $out = & pnputil.exe /export-driver $d.inf $dir 2>&1
            if ($LASTEXITCODE -ne 0 -or -not (Test-D9DriverBackup $dir)) {
                [IO.Directory]::Delete($dir, $true)   # порожня папка інакше вважалась би готовою копією
                throw (T-D9 'Не вдалося зберегти поточний драйвер {0} для відкату: {1}' $d.inf "$out")
            }
        }
    }
    $out = & pnputil.exe /add-driver $Action.inf /install 2>&1 | Out-String
    # 0 — встановлено; 3010 — потрібне перезавантаження; 259 — додано, але жоден пристрій не оновлено (вже стоїть кращий)
    if ($LASTEXITCODE -notin 0, 3010, 259) { throw (T-D9 'pnputil завершився з кодом {0}: {1}' "$LASTEXITCODE" $out.Trim()) }
}

function Restore-D9Driver {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Before)
    $backup = Get-D9DriverBackupDir
    $current = (Get-D9DriverState $Action).devices
    $notes = @()
    foreach ($old in @($Before.devices)) {
        $now = $current | Where-Object id -eq $old.id | Select-Object -First 1
        if (-not $now -or $now.inf -eq $old.inf) { continue }
        if ($now.inf -like 'oem*.inf') { & pnputil.exe /delete-driver $now.inf /uninstall /force | Out-Null }
        if ($old.inf -like 'oem*.inf') {
            $saved = Join-Path $backup $old.inf
            if (Test-D9DriverBackup $saved) { & pnputil.exe /add-driver (Join-Path $saved '*.inf') /subdirs /install | Out-Null }
            else { $notes += (T-D9 'резервної копії {0} немає' "$($old.inf)") }
        }
    }
    & pnputil.exe /scan-devices | Out-Null
    if ($notes) { return (T-D9 'Драйвер повернуто не повністю: {0}' ($notes -join '; ')) }
}

function Get-D9DriverDescription {
    param([Parameter(Mandatory)]$Action, $State)
    $old = @($State.devices | ForEach-Object { if ($_.version) { "$($_.version) ($($_.date))" } else { (T-D9 'без драйвера') } } | Sort-Object -Unique) -join ', '
    if (-not $old) { $old = '?' }
    return (T-D9 'Драйвер {0}: {1} -> {2} ({3})' "$($Action.name)" $old "$($Action.version)" "$($Action.date)")
}
