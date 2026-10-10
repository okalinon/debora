# Відомості про ОС і залізо, від яких залежать придатність твіків і рекомендації.

# Напряму через CIM-класи Storage: модуль Storage (Get-PhysicalDisk) вантажиться кілька секунд
function Get-D9SystemDisk {
    $ns = 'root\Microsoft\Windows\Storage'
    $result = [pscustomobject]@{ Type = 'unknown'; PartitionStyle = 'unknown' }
    try {
        $letter = [char]$env:SystemDrive.TrimEnd(':')
        $partition = Get-CimInstance -Namespace $ns -ClassName MSFT_Partition -Filter "DriveLetter = '$letter'" -ErrorAction Stop | Select-Object -First 1
        if (-not $partition) { return $result }
        $disk = Get-CimInstance -Namespace $ns -ClassName MSFT_Disk -Filter "Number = $($partition.DiskNumber)" -ErrorAction Stop
        $result.PartitionStyle = @{ 1 = 'MBR'; 2 = 'GPT' }[[int]$disk.PartitionStyle]
        $physical = Get-CimInstance -Namespace $ns -ClassName MSFT_PhysicalDisk -Filter "DeviceId = '$($partition.DiskNumber)'" -ErrorAction Stop
        if (-not $physical) { return $result }
        $result.Type = if ([int]$physical.BusType -eq 17) { 'nvme' }       # 17 = NVMe
                       elseif ([int]$physical.MediaType -eq 3) { 'hdd' }  # 3 = HDD
                       elseif ([int]$physical.MediaType -eq 4) { 'ssd' }  # 4 = SSD
                       else { 'unknown' }
    } catch { }
    return $result
}

function Get-D9SystemInfo {
    $os    = Get-CimInstance Win32_OperatingSystem
    $cs    = Get-CimInstance Win32_ComputerSystem
    $cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
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
        Cpu            = ($cpu.Name -replace '\s+', ' ').Trim()
        Cores          = [int]$cpu.NumberOfCores
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
        return & $ok ("лише " + ((@($Requires.os) | ForEach-Object { $_ -replace 'win', 'Windows ' }) -join ' / '))
    }
    if ($Requires.minBuild -and $SystemInfo.Build -lt $Requires.minBuild) { return & $ok "потрібна збірка $($Requires.minBuild)+" }
    if ($Requires.maxBuild -and $SystemInfo.Build -gt $Requires.maxBuild) { return & $ok "лише до збірки $($Requires.maxBuild)" }

    $hw = $Requires.hardware
    if ($hw) {
        if ($hw.systemDisk -and @($hw.systemDisk) -notcontains $SystemInfo.SystemDisk) {
            $names = @{ hdd = 'HDD'; ssd = 'SSD'; nvme = 'NVMe' }
            $need = (@($hw.systemDisk) | ForEach-Object { $names[$_] }) -join '/'
            if ($SystemInfo.SystemDisk -eq 'unknown') { return & $ok "лише для $need (тип диска не визначено)" }
            return & $ok "лише для $need"
        }
        if ($hw.maxRamGB -and $SystemInfo.RamGB -gt $hw.maxRamGB) { return & $ok "лише для ПК з RAM до $($hw.maxRamGB) ГБ" }
        if ($hw.minRamGB -and $SystemInfo.RamGB -lt $hw.minRamGB) { return & $ok "потрібно від $($hw.minRamGB) ГБ RAM" }
        if ($null -ne $hw.battery -and [bool]$hw.battery -ne $SystemInfo.HasBattery) {
            if ($hw.battery) { return & $ok "лише для ноутбуків" } else { return & $ok "лише для ПК без батареї" }
        }
    }
    return & $ok $null
}
