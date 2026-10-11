# Проби заліза: пам'ять, екран, процесор, відео, диски, BIOS, апаратні помилки.

# Режими екрана через WinAPI: WMI не знає, яку частоту підтримує саме монітор
function Initialize-D9DisplayApi {
    if ('D9Display' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class D9Display {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string name, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);

    // Для кожного активного екрана: назва, поточні ширина/висота/частота,
    // найвища частота при поточній роздільній здатності, найбільша роздільна здатність
    public static List<object[]> Describe() {
        var result = new List<object[]>();
        var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
        for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++, dd.cb = Marshal.SizeOf(dd)) {
            if ((dd.StateFlags & 1) == 0) continue;   // не під'єднано до робочого столу
            var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(cur);
            if (!EnumDisplaySettings(dd.DeviceName, -1, ref cur)) continue;
            int maxHz = cur.dmDisplayFrequency, maxW = cur.dmPelsWidth, maxH = cur.dmPelsHeight;
            var m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(m);
            for (int k = 0; EnumDisplaySettings(dd.DeviceName, k, ref m); k++) {
                if (m.dmPelsWidth == cur.dmPelsWidth && m.dmPelsHeight == cur.dmPelsHeight && m.dmDisplayFrequency > maxHz) maxHz = m.dmDisplayFrequency;
                if ((long)m.dmPelsWidth * m.dmPelsHeight > (long)maxW * maxH) { maxW = m.dmPelsWidth; maxH = m.dmPelsHeight; }
            }
            result.Add(new object[] { dd.DeviceString, cur.dmPelsWidth, cur.dmPelsHeight, cur.dmDisplayFrequency, maxHz, maxW, maxH });
        }
        return result;
    }
}
'@
}

function Test-D9Display {
    param($Check, $Ctx)
    try { Initialize-D9DisplayApi; $screens = [D9Display]::Describe() } catch { return New-D9Skip $Check (T-D9 'Не вдалося прочитати режими екрана') }
    $link = New-D9Link (T-D9 'Параметри дисплея') 'ms-settings:display-advanced'
    $i = 0
    foreach ($s in $screens) {
        $i++
        $name, $w, $h, $hz, $maxHz, $maxW, $maxH = $s
        if ($maxHz -ge $hz + 10) {
            New-D9Finding $Check suggestion (T-D9 'Екран {0} працює на {1} Гц, хоча підтримує {2} Гц' $i $hz $maxHz) (T-D9 'Вища частота оновлення — плавніше прокручування й рух мишки. Параметри → Дисплей → Розширені параметри → Частота оновлення. Відеоадаптер: {0}.' $name) @{ type = 'manual' } @($link) -Key "$($Check.id):hz:$i"
        }
        if ([long]$maxW * $maxH -gt [long]$w * $h * 1.2) {
            New-D9Finding $Check suggestion (T-D9 'Екран {0}: роздільна здатність {1}×{2}, рідна — {3}×{4}' $i $w $h $maxW $maxH) (T-D9 'Нерідна роздільна здатність дає розмите зображення. Щоб збільшити текст, краще змінити масштаб (125%, 150%), а не роздільну здатність.') @{ type = 'manual' } @($link) -Key "$($Check.id):res:$i"
        }
    }
}

function Test-D9RamConfig {
    param($Check, $Ctx)
    $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    if (-not $sticks) { return New-D9Skip $Check (T-D9 'Дані про модулі пам''яті недоступні') }
    $slots = (Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Measure-Object MemoryDevices -Sum).Sum
    $total = [math]::Round(($sticks | Measure-Object Capacity -Sum).Sum / 1GB)
    if ($sticks.Count -eq 1 -and $slots -ge 2) {
        New-D9Finding $Check suggestion (T-D9 'Пам''ять працює в одноканальному режимі (1 модуль на {0} ГБ, слотів: {1})' $total $slots) (T-D9 'Другий такий самий модуль увімкне двоканальний режим: до +20–40% швидкості пам''яті, особливо помітно на вбудованій графіці.') @{ type = 'manual' } -Key "$($Check.id):single"
    }
    $sizes = @($sticks | ForEach-Object { [math]::Round($_.Capacity / 1GB) } | Sort-Object -Unique)
    if ($sticks.Count -ge 2 -and $sizes.Count -gt 1) {
        New-D9Finding $Check info (T-D9 'Встановлено модулі різного обсягу: {0} ГБ' ($sizes -join ' + ')) (T-D9 'Частина пам''яті може працювати в одноканальному режимі. Для найкращої швидкості — однакові модулі.') -Key "$($Check.id):mixed"
    }
    $rated = ($sticks | Measure-Object Speed -Maximum).Maximum
    $actual = ($sticks | Where-Object ConfiguredClockSpeed | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
    # Для DDR3 і старіших BIOS часто віддає реальну частоту (667 МГц), а не ефективну (1333 МТ/с)
    if ($rated -and $actual -and $actual -lt $rated * 0.55) { $actual *= 2 }
    # На ноутбуках частоту обмежує процесор або BIOS — користувач нічого не змінить, не шумимо
    if ($rated -and $actual -and $actual -lt $rated * 0.9 -and -not $Ctx.System.HasBattery) {
        New-D9Finding $Check suggestion (T-D9 'Пам''ять працює на {0} МГц замість {1} МГц' $actual $rated) (T-D9 'На настільних ПК увімкніть профіль XMP / EXPO / DOCP в BIOS. На ноутбуках частоту зазвичай обмежує процесор — тоді нічого робити не треба.') @{ type = 'manual' } -Key "$($Check.id):speed"
    }
    if ($Ctx.System.OsFamily -eq 'win11' -and $total -lt 8) {
        New-D9Finding $Check info (T-D9 'Оперативної пам''яті {0} ГБ' $total) (T-D9 'Для комфортної роботи Windows 11 з браузером потрібно від 8 ГБ. Якщо є вільний слот — це найдешевше покращення.') -Key "$($Check.id):amount"
    }
}

# Чи обмежено максимальну частоту процесора в схемі живлення; режим «Найкраща енергоефективність» від мережі
function Test-D9CpuLimits {
    param($Check, $Ctx)
    $out = powercfg /qh SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 2>$null | Out-String
    $hex = [regex]::Matches($out, '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToInt32($_.Value, 16) }
    if ($hex.Count -ge 2) {
        $ac = $hex[$hex.Count - 2]
        if ($ac -eq 99) {
            New-D9Finding $Check info (T-D9 'Turbo Boost вимкнено (максимальний стан процесора 99%)') (T-D9 'Так часто роблять навмисно, щоб ноутбук менше грівся. Якщо потрібна максимальна швидкість — поставте 100% у додаткових параметрах схеми живлення.') -Key "$($Check.id):turbo"
        } elseif ($ac -lt 99) {
            New-D9Finding $Check warning (T-D9 'Максимальна частота процесора обмежена до {0}% (від мережі)' $ac) (T-D9 'Схема живлення не дає процесору працювати на повну. Панель керування → Електроживлення → Змінити додаткові параметри → Керування живленням процесора → Максимальний стан процесора = 100%.') @{ type = 'tweaks'; ids = @('perf.power-high') } -Key "$($Check.id):max"
        }
    }
    if ($Ctx.System.OsFamily -eq 'win11') {
        $overlay = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction SilentlyContinue).ActiveOverlayAcPowerScheme
        if ($overlay -eq '961cc777-2547-4f9d-8174-7d86181b8a7a') {
            New-D9Finding $Check suggestion (T-D9 'Режим живлення від мережі — «Найкраща енергоефективність»') (T-D9 'Коли ноутбук на зарядці, режим «Збалансований» або «Найкраща продуктивність» помітно швидший. Параметри → Система → Живлення → Режим живлення.') @{ type = 'manual' } @((New-D9Link (T-D9 'Живлення') 'ms-settings:powersleep')) -Key "$($Check.id):overlay"
        }
    }
}

function Test-D9Thermal {
    param($Check, $Ctx)
    $since = Get-D9EventSince $Check $Ctx $Check.thresholds.days
    $events = @(Get-D9EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = $since })
    if ($events.Count -ge $Check.thresholds.minEvents) {
        # На ноутбуках прошивка регулярно обмежує частоту при живленні від батареї — це не завжди проблема
        $severity = if ($Ctx.System.HasBattery) { 'suggestion' } else { 'warning' }
        New-D9Finding $Check $severity (T-D9 'Процесор примусово сповільнювався: {0} разів за {1} днів' $events.Count $Check.thresholds.days) (T-D9 'Прошивка обмежувала частоту — найчастіше через перегрів або слабке живлення. Почистіть систему охолодження, замініть термопасту, перевірте блок живлення / зарядку.') @{ type = 'manual' }
    }
}

function Test-D9HardwareErrors {
    param($Check, $Ctx)
    $since = Get-D9EventSince $Check $Ctx $Check.thresholds.days
    $whea = @(Get-D9EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = @(1, 2, 3); StartTime = $since })
    if ($whea.Count) {
        $fatal = @($whea | Where-Object { $_.Level -le 2 -and $_.Id -in 1, 18, 20, 46 })
        $severity = if ($fatal.Count) { 'critical' } else { 'warning' }
        New-D9Finding $Check $severity (T-D9 'Апаратні помилки (WHEA): {0} за {1} днів' $whea.Count $Check.thresholds.days) (T-D9 'Процесор, пам''ять або шина PCIe повідомляють про збої. Часті причини: розгін або андервольт, нестабільна пам''ять (перевірте mdsched.exe), перегрів, погано вставлена відеокарта чи SSD.') @{ type = 'manual' } @((New-D9Link (T-D9 'Перевірка пам''яті Windows') 'mdsched.exe')) -Key "$($Check.id):whea"
    }
    $tdr = @(Get-D9EventCount @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $since })
    if ($tdr.Count) {
        New-D9Finding $Check warning (T-D9 'Відеодрайвер аварійно перезапускався: {0} разів за {1} днів' $tdr.Count $Check.thresholds.days) (T-D9 'Мерехтіння або чорний екран на секунду — ознака збою відеодрайвера. Встановіть драйвер з сайту виробника відеокарти, перевірте температуру, приберіть розгін.') @{ type = 'drivers' } -Key "$($Check.id):tdr"
    }
}

function Test-D9GpuDriver {
    param($Check, $Ctx)
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI\*' }
    foreach ($g in $gpus) {
        if (-not $g.DriverDate) { continue }
        $age = [int]($Ctx.Now - $g.DriverDate).TotalDays
        $discrete = $g.Name -match 'NVIDIA|Radeon RX|Radeon Pro|Arc '
        $limit = if ($discrete) { $Check.thresholds.discreteDays } else { $Check.thresholds.integratedDays }
        if ($g.Name -match 'Microsoft Basic Display') {
            New-D9Finding $Check warning (T-D9 'Відеокарта працює без драйвера ({0})' $g.Name) (T-D9 'Без драйвера немає апаратного прискорення, нормальної частоти екрана й енергозбереження.') @{ type = 'drivers' } -Key "$($Check.id):$($g.PNPDeviceID)"
        } elseif ($age -gt $limit) {
            $years = [math]::Round($age / 365, 1)
            New-D9Finding $Check suggestion (T-D9 'Драйверу відеокарти {0} вже {1} р. (версія {2})' $g.Name $years $g.DriverVersion) (T-D9 'Нові драйвери виправляють збої та додають продуктивність в іграх і браузерах. Debora пошукає новіший у каталозі Microsoft; найсвіжіші версії — також у NVIDIA App, AMD Adrenalin, Intel Driver & Support Assistant (вкладка «Програми» / сайт виробника).') @{ type = 'maintenance'; action = 'driverUpdate' } -Key "$($Check.id):$($g.PNPDeviceID)"
        }
    }
}

function Test-D9DiskLayout {
    param($Check, $Ctx)
    $ns = 'root\Microsoft\Windows\Storage'
    $physical = @(Get-CimInstance -Namespace $ns -ClassName MSFT_PhysicalDisk -ErrorAction SilentlyContinue)
    $fast = @($physical | Where-Object { (Get-D9CimInt $_ MediaType) -eq 4 -or (Get-D9CimInt $_ BusType) -eq 17 })
    if ($Ctx.System.SystemDisk -eq 'hdd' -and $fast) {
        $sizeGB = [math]::Round(($fast | Select-Object -First 1).Size / 1GB)
        New-D9Finding $Check suggestion (T-D9 'Windows стоїть на HDD, хоча в комп''ютері є SSD ({0} ГБ)' $sizeGB) (T-D9 'Перенесення Windows на SSD — найбільше можливе прискорення: запуск у 3–5 разів швидший. Перенести можна безкоштовними програмами клонування або перевстановленням.') @{ type = 'manual' } -Key "$($Check.id):system-on-hdd"
    }
    # Вирівнювання розділів на SSD: зсув має бути кратним 4 КБ
    foreach ($d in $fast) {
        $parts = @(Get-CimInstance -Namespace $ns -ClassName MSFT_Partition -Filter "DiskNumber = $($d.DeviceId)" -ErrorAction SilentlyContinue)
        # Службовий розділ Microsoft (MSR) даних не містить — його вирівнювання ні на що не впливає
        $msr = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
        $bad = @($parts | Where-Object { $_.Offset % 4096 -ne 0 -and $_.GptType -ne $msr -and $_.Size -ge 64MB })
        if ($bad) {
            New-D9Finding $Check warning (T-D9 'Розділи на SSD {0} не вирівняні' $d.FriendlyName) (T-D9 'Невирівняні розділи сповільнюють SSD і прискорюють знос. Зазвичай наслідок клонування старою програмою; виправляється програмами для роботи з розділами (з резервною копією!).') @{ type = 'manual' } -Key "$($Check.id):align:$($d.DeviceId)"
        }
    }
}

function Test-D9Bios {
    param($Check, $Ctx)
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    if (-not $bios.ReleaseDate) { return }
    $years = [math]::Round(($Ctx.Now - $bios.ReleaseDate).TotalDays / 365, 1)
    if ($years -ge $Check.thresholds.years) {
        New-D9Finding $Check info (T-D9 'BIOS/UEFI версії {0} від {1} ({2} р.)' $bios.SMBIOSBIOSVersion $bios.ReleaseDate.ToString('dd.MM.yyyy') $years) (T-D9 'Перевірте на сайті виробника, чи є новіша версія: оновлення BIOS виправляють стабільність і вразливості. Оновлюйте лише від мережі й не вимикайте ПК під час прошивки.')
    }
}
