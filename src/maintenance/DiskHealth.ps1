# Стан фізичних дисків: модель, тип, розмір, томи, оцінка Windows і лічильники надійності (SMART).
# Лічильники (температура, знос, години роботи, помилки) і прогноз відмови SMART Windows віддає лише адміністратору.

$script:D9DiskMedia = @{ 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
$script:D9DiskBus = @{ 1 = 'SCSI'; 2 = 'ATAPI'; 3 = 'ATA'; 7 = 'USB'; 8 = 'RAID'; 9 = 'iSCSI'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 13 = 'MMC'; 15 = 'віртуальний'; 16 = 'Storage Spaces'; 17 = 'NVMe' }

function Get-D9CimLong {
    param($Instance, [string]$Name)
    $p = $Instance.CimInstanceProperties[$Name]
    if ($p -and $null -ne $p.Value) { return [long]$p.Value }
    return $null
}

# Прогноз відмови SMART (root\wmi): номер диска → $true/$false. Для NVMe і USB часто «не підтримується» — тоді порожньо.
function Get-D9DiskFailurePrediction {
    $result = @{}
    $status = @(try { Get-CimInstance -Namespace 'root\wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop } catch { })
    if (-not $status) { return $result }
    foreach ($d in @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)) {
        $s = $status | Where-Object { ($_.InstanceName -replace '_\d+$', '') -eq $d.PNPDeviceID } | Select-Object -First 1
        if ($s) { $result[[int]$d.Index] = [bool]$s.PredictFailure }
    }
    return $result
}

function Get-D9DiskHealth {
    $ns = 'root\Microsoft\Windows\Storage'
    $disks = @(Get-CimInstance -Namespace $ns -ClassName MSFT_PhysicalDisk -ErrorAction Stop)
    $partitions = @(Get-CimInstance -Namespace $ns -ClassName MSFT_Partition -ErrorAction SilentlyContinue)
    $systemLetter = [char]$env:SystemDrive.TrimEnd(':')
    $admin = Test-D9IsAdmin
    $predict = if ($admin) { Get-D9DiskFailurePrediction } else { @{} }
    foreach ($d in $disks | Sort-Object { [int]$_.DeviceId }) {
        $number = [int]$d.DeviceId
        $letters = @($partitions | Where-Object { (Get-D9CimInt $_ DiskNumber) -eq $number -and [int][char]$_.DriveLetter -ne 0 } | ForEach-Object { "$([char]$_.DriveLetter):" } | Sort-Object)
        $rel = $null
        if ($admin) { $rel = try { $d | Get-CimAssociatedInstance -ResultClassName MSFT_StorageReliabilityCounter -ErrorAction Stop | Select-Object -First 1 } catch { $null } }
        $counter = { param($n) if ($rel) { Get-D9CimLong $rel $n } }
        $media = Get-D9CimInt $d MediaType
        $bus = Get-D9CimInt $d BusType
        [pscustomobject]@{
            Number = $number
            Model = ([string]$d.FriendlyName).Trim()
            Media = if ($script:D9DiskMedia.ContainsKey([int]$media)) { $script:D9DiskMedia[[int]$media] } else { '' }
            Bus = if ($script:D9DiskBus.ContainsKey([int]$bus)) { T-D9 $script:D9DiskBus[[int]$bus] } else { '' }
            Removable = $bus -in 7, 12, 13
            SizeBytes = Get-D9CimLong $d Size
            Letters = $letters
            IsSystem = $letters -contains "${systemLetter}:"
            Firmware = ([string]$d.FirmwareVersion).Trim()
            HealthStatus = Get-D9CimInt $d HealthStatus          # 0 справний, 1 попередження, 2 несправний, 5 невідомо
            HasCounters = [bool]$rel
            Temperature = & $counter Temperature
            TemperatureMax = & $counter TemperatureMax
            Wear = & $counter Wear                               # % використаного ресурсу (SSD)
            PowerOnHours = & $counter PowerOnHours
            ReadErrorsUncorrected = & $counter ReadErrorsUncorrected
            WriteErrorsUncorrected = & $counter WriteErrorsUncorrected
            StartStopCycles = & $counter StartStopCycleCount
            PredictFailure = if ($predict.ContainsKey($number)) { $predict[$number] } else { $null }
            CountersAvailable = $admin
        }
    }
}

# Оцінка одного диска: Level ok | warn | bad | unknown і список причин українською
function Get-D9DiskVerdict {
    param([Parameter(Mandatory)]$Disk, [int]$WearPercent = 80, [int]$TempC = 60)
    $bad = @(); $warn = @()
    if ($Disk.HealthStatus -eq 2) { $bad += T-D9 'Windows вважає диск несправним' }
    if ($Disk.PredictFailure) { $bad += T-D9 'SMART прогнозує скору відмову' }
    if ($Disk.ReadErrorsUncorrected -gt 0) { $bad += T-D9 'невиправні помилки читання: {0}' $Disk.ReadErrorsUncorrected }
    if ($Disk.WriteErrorsUncorrected -gt 0) { $bad += T-D9 'невиправні помилки запису: {0}' $Disk.WriteErrorsUncorrected }
    if ($Disk.Wear -ge 100) { $bad += T-D9 'ресурс записів вичерпано ({0}%)' $Disk.Wear }
    elseif ($Disk.Wear -ge $WearPercent) { $warn += T-D9 'зношений на {0}%' $Disk.Wear }
    if ($Disk.HealthStatus -eq 1) { $warn += T-D9 'Windows повідомляє про попередження' }
    if ($Disk.Temperature -ge $TempC) { $warn += T-D9 'гарячий: {0} °C' $Disk.Temperature }
    $level = if ($bad) { 'bad' } elseif ($warn) { 'warn' } elseif ($Disk.HealthStatus -eq 0 -or $Disk.HasCounters) { 'ok' } else { 'unknown' }
    [pscustomobject]@{ Level = $level; Problems = @($bad + $warn) }
}

# Рядок «Диск 0 · KINGSTON … · NVMe SSD · 1,8 ТБ · C:, D: (системний)»
function Format-D9DiskTitle {
    param([Parameter(Mandatory)]$Disk)
    $kind = (@($Disk.Bus, $Disk.Media) | Where-Object { $_ }) -join ' '
    $parts = @((T-D9 'Диск {0}' "$($Disk.Number)"), $Disk.Model)
    if ($kind) { $parts += $kind }
    if ($Disk.SizeBytes) { $parts += Format-D9Size $Disk.SizeBytes }
    if ($Disk.Letters) { $parts += (($Disk.Letters -join ', ') + $(if ($Disk.IsSystem) { ' ' + (T-D9 '(системний)') })) }
    $parts -join ' · '
}

# Подробиці: температура, знос, години роботи, помилки — що є
function Format-D9DiskDetails {
    param([Parameter(Mandatory)]$Disk)
    $p = @()
    if ($null -ne $Disk.Temperature -and $Disk.Temperature -gt 0) {
        $p += (T-D9 'температура {0} °C' $Disk.Temperature) + $(if ($Disk.TemperatureMax -gt 0) { ' ' + (T-D9 '(макс. {0} °C)' $Disk.TemperatureMax) })
    }
    if ($null -ne $Disk.Wear -and $Disk.Media -ne 'HDD') { $p += T-D9 'знос {0}%' "$($Disk.Wear)" }
    if ($Disk.PowerOnHours -gt 0) {
        $p += T-D9 'напрацювання {0} год (≈ {1} р.)' $Disk.PowerOnHours ([math]::Round($Disk.PowerOnHours / 24 / 365, 1))
    }
    if ($Disk.StartStopCycles -gt 0) { $p += T-D9 'увімкнень {0}' $Disk.StartStopCycles }
    if ($Disk.HasCounters) { $p += T-D9 'невиправних помилок: {0}' "$([long]$Disk.ReadErrorsUncorrected + [long]$Disk.WriteErrorsUncorrected)" }
    if ($Disk.Firmware) { $p += T-D9 'прошивка {0}' $Disk.Firmware }
    if (-not $Disk.CountersAvailable) { $p += T-D9 'температура й знос — після запуску від адміністратора' }
    elseif (-not $Disk.HasCounters) { $p += T-D9 'диск не віддає лічильників SMART (типово для флешок і USB-кишень)' }
    $p -join '; '
}

$script:D9DiskLevelText = @{ ok = 'Справний'; warn = 'Увага'; bad = 'Несправний'; unknown = 'Невідомо' }

# Назва рівня поточною мовою (таблиця вище — українські шаблони)
function Get-D9DiskLevelText {
    param([string]$Level)
    $t = $script:D9DiskLevelText[$Level]
    if ($t) { T-D9 $t } else { $Level }
}

# Текстовий звіт (CLI і діагностика)
function Format-D9DiskHealthReport {
    param([object[]]$Disks = @(Get-D9DiskHealth))
    foreach ($d in $Disks) {
        $v = Get-D9DiskVerdict $d
        "[$(Get-D9DiskLevelText $v.Level)] $(Format-D9DiskTitle $d)"
        if ($v.Problems) { '    ' + (T-D9 'Проблеми: {0}' ($v.Problems -join '; ')) }
        "    $(Format-D9DiskDetails $d)"
    }
}

# Кеш іконок і ескізів Провідника: коли замість значків білі аркуші, ескізи старі або значки переплутані.
# Права адміністратора не потрібні (кеш — у профілі користувача). Провідник перезапускається.
function Get-D9IconCacheFiles {
    param([string]$LocalAppData = $env:LOCALAPPDATA)
    $explorer = Join-Path $LocalAppData 'Microsoft\Windows\Explorer'
    $files = @(Get-ChildItem -LiteralPath $explorer -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'iconcache_*.db' -or $_.Name -like 'thumbcache_*.db' })
    $legacy = Join-Path $LocalAppData 'IconCache.db'
    if (Test-Path -LiteralPath $legacy) { $files += Get-Item -LiteralPath $legacy -Force }
    $files
}

function Reset-D9IconCache {
    Write-D9Log (T-D9 'Скидання кешу іконок і ескізів (Провідник перезапуститься, відкриті вікна папок закриються)...')
    $before = @(Get-D9IconCacheFiles)
    $size = [long](($before | Measure-Object Length -Sum).Sum)
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500
    $removed = 0
    foreach ($f in $before) {
        try { [IO.File]::Delete($f.FullName); $removed++ } catch { Write-D9Log ('  ' + (T-D9 'Зайнятий, пропущено: {0}' $f.Name)) Detail }
    }
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Write-D9Log (T-D9 'Видалено файлів кешу: {0} з {1} ({2}). Windows створить кеш заново; значки з''являться за хвилину.' $removed $before.Count (Format-D9Size $size)) Ok
    if ($removed -lt $before.Count) { Write-D9Log (T-D9 'Частину файлів тримає інша програма — після перезавантаження скиньте кеш ще раз.') Warn }
    [pscustomobject]@{ Done = $true; RebootRecommended = $false; Removed = $removed }
}
