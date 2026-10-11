# Пакет діагностики: один zip з усім, що потрібно, щоб розібратися з проблемою на чужому ПК без доступу до нього.
# Відомості про систему, останні сканування, журнал змін, логи програми, стан драйверів і пристроїв,
# хвіст setupapi.dev.log (встановлення драйверів), свіжі помилки з журналів подій.
# Особистих файлів не містить; є ім'я комп'ютера й користувача (у шляхах).

# Кожен розділ — окремий файл; збій одного розділу не зупиняє решту, а записується в той самий файл.
function Add-D9DiagSection {
    param([string]$Dir, [string]$Name, [scriptblock]$Body)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $text = & $Body | Out-String -Width 400 }
    catch { $text = (T-D9 'ПОМИЛКА: {0}' $_.Exception.Message) }
    [IO.File]::WriteAllText((Join-Path $Dir $Name), [string]$text, (New-Object Text.UTF8Encoding $true))
    Write-D9Log ('  ' + (T-D9 '{0} ({1} с)' $Name ([int]$sw.Elapsed.TotalSeconds))) Detail
}

# Найновіші файли з папки даних програми (сканування, сесії, логи)
function Copy-D9DiagFiles {
    param([string]$From, [string]$To, [string]$Filter, [int]$Count)
    if (-not (Test-Path $From)) { return 0 }
    $files = @(Get-ChildItem $From -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $Count)
    if (-not $files) { return 0 }
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $To -ErrorAction SilentlyContinue }
    return $files.Count
}

function Get-D9DiagEvents {
    param([string]$Log, [int]$Days, [int]$Max = 400)
    $events = Get-D9Events @{ LogName = $Log; Level = @(1, 2); StartTime = (Get-Date).AddDays(-$Days) }
    if ($null -eq $events) { return (T-D9 'Журнал {0} недоступний.' $Log) }
    (T-D9 '=== {0}: критичні й помилки за {1} дн. — {2} (показано до {3}) ===' $Log $Days @($events).Count $Max)
    @($events) | Select-Object -First $Max | ForEach-Object {
        $msg = ([string]$_.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '…' }
        '{0:yyyy-MM-dd HH:mm:ss}  {1,-5} {2} | {3}' -f $_.TimeCreated, $_.Id, $_.ProviderName, $msg
    }
    ''
    (T-D9 '=== Підсумок за джерелами ===')
    @($events) | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 40 | Format-Table Count, Name -AutoSize
}

function New-D9DiagnosticsBundle {
    param($SystemInfo, [Parameter(Mandatory)][string]$OutDir, [string]$ReportDir, [int]$EventDays = 7)
    $work = Join-Path ([IO.Path]::GetTempPath()) ("d9diag-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $data = Get-D9DataRoot
    Write-D9Log (T-D9 'Збираю діагностику (до хвилини)...')
    try {
        Add-D9DiagSection $work 'system.txt' {
            (T-D9 'Debora {0}, зібрано {1}, {2}' $script:D9Version (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $(if (Test-D9IsAdmin) { T-D9 'адміністратор' } else { T-D9 'без прав адміністратора' }))
            ''
            if ($SystemInfo) { $SystemInfo | Format-List }
            $os = Get-CimInstance Win32_OperatingSystem
            (T-D9 'ОС: {0} {1}, встановлено {2}, запущено {3}' $os.Caption $os.Version $os.InstallDate $os.LastBootUpTime)
            (T-D9 'Пам''ять: вільно {0} з {1} ГБ' ([math]::Round($os.FreePhysicalMemory / 1MB, 2)) ([math]::Round($os.TotalVisibleMemorySize / 1MB, 2)))
            $bios = Get-CimInstance Win32_BIOS
            "BIOS: $($bios.Manufacturer) $($bios.SMBIOSBIOSVersion), $($bios.ReleaseDate)"
            ''
            Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | Format-Table DeviceID, FileSystem, @{ n = (T-D9 'Розмір, ГБ'); e = { [math]::Round($_.Size / 1GB, 1) } }, @{ n = (T-D9 'Вільно, ГБ'); e = { [math]::Round($_.FreeSpace / 1GB, 1) } } -AutoSize
            Get-PhysicalDisk -ErrorAction SilentlyContinue | Format-Table FriendlyName, MediaType, BusType, HealthStatus, OperationalStatus, @{ n = (T-D9 'ГБ'); e = { [math]::Round($_.Size / 1GB) } } -AutoSize
            $plan = (& powercfg.exe /getactivescheme 2>&1 | Out-String).Trim()
            if (-not $plan) { $plan = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction SilentlyContinue).ActivePowerScheme }
            (T-D9 'Схема живлення: {0}' $plan)
        }
        Add-D9DiagSection $work 'disks.txt' { Format-D9DiskHealthReport }
        if ($SystemInfo.HasBattery) { Add-D9DiagSection $work 'battery.txt' { Format-D9BatteryReport -Manufacturer $SystemInfo.Manufacturer } }
        Add-D9DiagSection $work 'devices.txt' {
            (T-D9 '=== Пристрої з помилками (ConfigManagerErrorCode ≠ 0) ===')
            Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
                Format-Table ConfigManagerErrorCode, PNPClass, Name, DeviceID -AutoSize
            (T-D9 '=== Усі присутні пристрої ===')
            Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Sort-Object Class, FriendlyName |
                Format-Table Status, Class, FriendlyName, InstanceId -AutoSize
        }
        Add-D9DiagSection $work 'drivers.txt' {
            (T-D9 '=== Драйвери пристроїв (Win32_PnPSignedDriver) ===')
            Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceName | Sort-Object DeviceClass, DeviceName |
                Format-Table DeviceClass, DeviceName, DriverVersion, @{ n = (T-D9 'Дата'); e = { if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } } }, DriverProviderName, InfName -AutoSize
            (T-D9 '=== Сторонні пакети драйверів (pnputil /enum-drivers) ===')
            & pnputil.exe /enum-drivers
        }
        Add-D9DiagSection $work 'setupapi-tail.log' {
            $log = Join-Path $env:windir 'INF\setupapi.dev.log'
            if (Test-Path $log) { Get-Content -LiteralPath $log -Tail 5000 -ErrorAction Stop } else { T-D9 'setupapi.dev.log не знайдено' }
        }
        Add-D9DiagSection $work 'events-system.txt' { Get-D9DiagEvents 'System' $EventDays }
        Add-D9DiagSection $work 'events-application.txt' { Get-D9DiagEvents 'Application' $EventDays }
        Add-D9DiagSection $work 'services.txt' {
            Get-CimInstance Win32_Service | Sort-Object Name | Format-Table Name, State, StartMode, DisplayName, PathName -AutoSize
        }
        Add-D9DiagSection $work 'startup.txt' {
            Get-CimInstance Win32_StartupCommand | Format-Table Location, Name, Command -AutoSize
        }

        $copied = [ordered]@{
            (T-D9 'сканування') = Copy-D9DiagFiles (Join-Path $data 'scans') (Join-Path $work 'scans') '*.json' 3
            (T-D9 'сесії змін') = Copy-D9DiagFiles (Join-Path $data 'sessions') (Join-Path $work 'sessions') '*.json' 30
            (T-D9 'логи') = Copy-D9DiagFiles (Join-Path $data 'logs') (Join-Path $work 'logs') '*.log' 3
            (T-D9 'чекліст') = Copy-D9DiagFiles (Join-Path $data 'checklists') (Join-Path $work 'checklists') '*.json' 1
            (T-D9 'HTML-звіт') = $(if ($ReportDir) { Copy-D9DiagFiles $ReportDir (Join-Path $work 'reports') '*.html' 1 } else { 0 })
        }
        Add-D9DiagSection $work 'driver-backup.txt' {
            $b = Join-Path $data 'driver-backup'
            if (Test-Path $b) { Get-ChildItem $b -Directory | Format-Table Name, LastWriteTime -AutoSize } else { T-D9 'Резервних копій драйверів немає.' }
        }
        Add-D9DiagSection $work 'README.txt' {
            (T-D9 'Пакет діагностики Debora — {0}, {1}' $env:COMPUTERNAME (Get-Date -Format 'yyyy-MM-dd HH:mm'))
            (T-D9 'Містить відомості про систему, пристрої, драйвери, служби, автозапуск, помилки з журналів подій і файли програми:')
            foreach ($k in $copied.Keys) { "  $k — $($copied[$k])" }
            (T-D9 'Особистих файлів і паролів немає. Є ім''я комп''ютера й користувача (у шляхах до файлів).')
        }

        if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
        $zip = Join-Path $OutDir (T-D9 'Діагностика {0} {1:yyyy-MM-dd HH-mm}.zip' $env:COMPUTERNAME (Get-Date))
        Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -Force
        Write-D9Log (T-D9 'Пакет діагностики: {0} ({1})' $zip (Format-D9Size (Get-Item $zip).Length)) Ok
        return $zip
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
