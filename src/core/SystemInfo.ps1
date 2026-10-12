# Відомості про ОС і залізо, від яких залежать придатність твіків і рекомендації.

# Числове значення властивості CIM напряму, повз надбудови модулів. Модуль Storage, якщо його
# завантажено в сесії (Get-PhysicalDisk тощо), підміняє MediaType/BusType/HealthStatus/PartitionStyle
# текстом («SSD», «Healthy») — і [int]$x.MediaType падає.
function Get-D9CimInt {
    param($Instance, [string]$Name)
    $p = $Instance.CimInstanceProperties[$Name]
    if ($p -and $null -ne $p.Value) { return [int]$p.Value }
    return $null
}

# Напряму через CIM-класи Storage: модуль Storage (Get-PhysicalDisk) вантажиться кілька секунд
function Get-D9SystemDisk {
    $ns = 'root\Microsoft\Windows\Storage'
    $result = [pscustomobject]@{ Type = 'unknown'; PartitionStyle = 'unknown' }
    try {
        $letter = [char]$env:SystemDrive.TrimEnd(':')
        $partition = Get-CimInstance -Namespace $ns -ClassName MSFT_Partition -Filter "DriveLetter = '$letter'" -ErrorAction Stop | Select-Object -First 1
        if (-not $partition) { return $result }
        $disk = Get-CimInstance -Namespace $ns -ClassName MSFT_Disk -Filter "Number = $($partition.DiskNumber)" -ErrorAction Stop
        $result.PartitionStyle = @{ 1 = 'MBR'; 2 = 'GPT' }[(Get-D9CimInt $disk PartitionStyle)]
        $physical = Get-CimInstance -Namespace $ns -ClassName MSFT_PhysicalDisk -Filter "DeviceId = '$($partition.DiskNumber)'" -ErrorAction Stop
        if (-not $physical) { return $result }
        $result.Type = if ((Get-D9CimInt $physical BusType) -eq 17) { 'nvme' }       # 17 = NVMe
                       elseif ((Get-D9CimInt $physical MediaType) -eq 3) { 'hdd' }  # 3 = HDD
                       elseif ((Get-D9CimInt $physical MediaType) -eq 4) { 'ssd' }  # 4 = SSD
                       else { 'unknown' }
    } catch { }
    return $result
}

# Час останнього завантаження Windows з точністю до хвилини — без звернення до CIM.
# Environment.TickCount (мс від завантаження) — int32, після ~25 днів стає від'ємним, тому доводимо до uint32.
function Get-D9BootStamp {
    $ms = [long][Environment]::TickCount
    if ($ms -lt 0) { $ms += 4294967296 }
    (Get-Date).AddMilliseconds(-$ms).ToString('yyyy-MM-ddTHH:mm')
}

# -UseCache: відомості про залізо між перезавантаженнями не змінюються — зберігаємо їх у
# %LOCALAPPDATA%\Debora\sysinfo.json і до наступного перезавантаження не опитуємо CIM (≈1–1,5 с запуску)
function Get-D9SystemInfo {
    param([switch]$UseCache)
    if ($UseCache) {
        $file = Join-Path $env:LOCALAPPDATA 'Debora\sysinfo.json'
        $stamp = Get-D9BootStamp
        try {
            $c = ConvertFrom-Json ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8))
            # Хвилина може «перескочити» між запусками — допускаємо розбіжність до 2 хв
            if ($c.Boot -and $c.Version -eq 1 -and [math]::Abs(([datetime]$c.Boot - [datetime]$stamp).TotalMinutes) -le 2 -and $c.Info.OsName) {
                $i = $c.Info
                return [pscustomobject]@{ OsName = [string]$i.OsName; OsFamily = [string]$i.OsFamily; Build = [int]$i.Build; DisplayVersion = [string]$i.DisplayVersion
                                          Manufacturer = [string]$i.Manufacturer; Model = [string]$i.Model; Cpu = [string]$i.Cpu; Cores = [int]$i.Cores; RamGB = [double]$i.RamGB
                                          SystemDisk = [string]$i.SystemDisk; HasBattery = [bool]$i.HasBattery; Firmware = [string]$i.Firmware; PartitionStyle = [string]$i.PartitionStyle }
            }
        } catch { }
        $info = Get-D9SystemInfo
        try {
            $dir = Split-Path $file
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllText($file, (ConvertTo-Json @{ Version = 1; Boot = $stamp; Info = $info } -Depth 3), (New-Object Text.UTF8Encoding $false))
        } catch { }
        return $info
    }
    $os    = Get-CimInstance Win32_OperatingSystem
    $cs    = Get-CimInstance Win32_ComputerSystem
    # Назва процесора — з реєстру, з CIM лише кількість ядер: повний Win32_Processor триває понад секунду
    $cpuName = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue).ProcessorNameString
    $cores = (Get-CimInstance Win32_Processor -Property NumberOfCores -ErrorAction SilentlyContinue | Measure-Object NumberOfCores -Sum).Sum
    if (-not $cpuName) { $cpuName = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name }
    $build = [int]$os.BuildNumber
    $displayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
    $disk  = Get-D9SystemDisk

    [pscustomobject]@{
        OsName         = ($os.Caption -replace '^Microsoft\s+', '')
        OsFamily       = if ($build -ge 22000) { 'win11' } else { 'win10' }
        Build          = $build
        DisplayVersion = $displayVersion
        Manufacturer   = $cs.Manufacturer
        Model          = $cs.Model
        Cpu            = ([string]$cpuName -replace '\s+', ' ').Trim()
        Cores          = [int]$cores
        RamGB          = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        SystemDisk     = $disk.Type
        HasBattery     = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        Firmware       = if ($env:firmware_type) { $env:firmware_type } else { 'unknown' }
        PartitionStyle = $disk.PartitionStyle
    }
}

# Чи підходить твік (або окрема дія) до цієї системи. Повертає Applicable + Reason.
function Test-D9Applicable {
    param($Requires, [Parameter(Mandatory)]$SystemInfo)
    $ok = { param($reason) [pscustomobject]@{ Applicable = ($null -eq $reason); Reason = $reason } }
    if (-not $Requires) { return & $ok $null }

    if ($Requires.os -and @($Requires.os) -notcontains $SystemInfo.OsFamily) {
        return & $ok (T-D9 'лише {0}' ((@($Requires.os) | ForEach-Object { $_ -replace 'win', 'Windows ' }) -join ' / '))
    }
    if ($Requires.minBuild -and $SystemInfo.Build -lt $Requires.minBuild) { return & $ok (T-D9 'потрібна збірка {0}+' "$($Requires.minBuild)") }
    if ($Requires.maxBuild -and $SystemInfo.Build -gt $Requires.maxBuild) { return & $ok (T-D9 'лише до збірки {0}' "$($Requires.maxBuild)") }

    $hw = $Requires.hardware
    if ($hw) {
        if ($hw.systemDisk -and @($hw.systemDisk) -notcontains $SystemInfo.SystemDisk) {
            $names = @{ hdd = 'HDD'; ssd = 'SSD'; nvme = 'NVMe' }
            $need = (@($hw.systemDisk) | ForEach-Object { $names[$_] }) -join '/'
            if ($SystemInfo.SystemDisk -eq 'unknown') { return & $ok (T-D9 'лише для {0} (тип диска не визначено)' $need) }
            return & $ok (T-D9 'лише для {0}' $need)
        }
        if ($hw.maxRamGB -and $SystemInfo.RamGB -gt $hw.maxRamGB) { return & $ok (T-D9 'лише для ПК з RAM до {0} ГБ' "$($hw.maxRamGB)") }
        if ($hw.minRamGB -and $SystemInfo.RamGB -lt $hw.minRamGB) { return & $ok (T-D9 'потрібно від {0} ГБ RAM' "$($hw.minRamGB)") }
        if ($null -ne $hw.battery -and [bool]$hw.battery -ne $SystemInfo.HasBattery) {
            if ($hw.battery) { return & $ok (T-D9 'лише для ноутбуків') } else { return & $ok (T-D9 'лише для ПК без батареї') }
        }
    }
    return & $ok $null
}
