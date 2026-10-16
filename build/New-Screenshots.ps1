<#
.SYNOPSIS
    Скріншоти для README: кожна вкладка з демо-даними (нічого з цього ПК, крім списку вбудованих застосунків
    на вкладці «Деблоат»), вікно рендериться за межами екрана й не активується.
.EXAMPLE
    .\build\New-Screenshots.ps1                       # англійська → docs\images
    .\build\New-Screenshots.ps1 -Lang uk              # українська → docs\images\uk
    .\build\New-Screenshots.ps1 -Theme dark -Only overview
#>
param([ValidateSet('en', 'uk')][string]$Lang = 'en', [ValidateSet('light', 'dark')][string]$Theme = 'light',
      [string]$Out, [string[]]$Only)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Out) { $Out = if ($Lang -eq 'uk') { Join-Path $root 'docs\images\uk' } else { Join-Path $root 'docs\images' } }
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out | Out-Null }
. (Join-Path $root 'tests\_Load.ps1')
$env:D9_DATA_ROOT = Join-Path $env:TEMP "debora-shots-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
Set-D9Language $Lang
# Формат чисел і дат — як у людини з цією мовою (а не за регіональними налаштуваннями цього ПК)
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]$(if ($Lang -eq 'uk') { 'uk-UA' } else { 'en-US' })
$script:D9LaptopPlatformCache = @{ Value = $null }   # поради батареї — за демо-виробником, а не за платформою цього ПК
$script:D9Theme = $Theme
$suffix = if ($Theme -eq 'dark') { '-dark' } else { '' }
function L([string]$uk, [string]$en) { if ($Lang -eq 'uk') { $uk } else { $en } }

$catalog = Import-D9Catalog
# Журнал змін: демо-сесії (рендериться вкладка «Журнал змін» з деталями першої)
$sessDir = Join-Path $env:D9_DATA_ROOT 'sessions'
New-Item -ItemType Directory -Path $sessDir -Force | Out-Null
$now = Get-Date
$demoSessions = @(
    @{ ago = 0.1; sel = (L 'Повернення змін, скасованих Windows (3)' 'Restore changes undone by Windows (3)'); tweaks = @('privacy.telemetry', 'apps.disable-copilot', 'ui.start-no-recommended') }
    @{ ago = 2; sel = (L 'Деблоат: рекомендовано (40)' 'Debloat: recommended (40)'); tweaks = @('apps.disable-copilot', 'privacy.telemetry', 'ui.start-no-recommended', 'privacy.ads-tips', 'ui.explorer') }
    @{ ago = 2.1; sel = (L 'Виправлення: телеметрія, автозавантаження' 'Fix: telemetry, startup apps'); tweaks = @('privacy.telemetry') }
    @{ ago = 9; sel = (L 'Пресет «Ігровий»' 'Preset "Gaming"'); tweaks = @('perf.games-priority', 'ui.explorer'); undone = $true }
    @{ ago = 15; sel = (L 'Налаштування з нуля' 'Setup from scratch'); tweaks = @('privacy.telemetry', 'ui.explorer', 'perf.games-priority') }
)
$i = 0
foreach ($s in $demoSessions) {
    $t = $now.AddDays(-$s.ago)
    $entries = @(foreach ($tw in $s.tweaks) {
        [ordered]@{ tweak = $tw; action = @((Get-D9Tweak $catalog $tw).actions)[0]
                    before = [ordered]@{ exists = $true; value = 3 }; result = 'ok'; time = $t.ToString('s') }
    })
    $undo = New-Object Collections.ArrayList
    if ($s.undone) { [void]$undo.Add([ordered]@{ time = $t.AddHours(1).ToString('s'); result = 'ok' }) }
    $obj = [ordered]@{ id = ('{0:yyyy-MM-ddTHH-mm-ss}-{1:d4}' -f $t, $i++); started = $t.ToString('s'); machine = 'DEMO'; os = 'Windows 11 Pro 24H2 (26100)'
                       selection = $s.sel; restorePoint = $null; entries = $entries; undo = $undo }
    [IO.File]::WriteAllText((Join-Path $sessDir "$($obj.id).json"), (ConvertTo-Json $obj -Depth 8), (New-Object Text.UTF8Encoding $false))
}

$sys = [pscustomobject]@{ OsName = 'Windows 11 Pro'; OsFamily = 'win11'; Build = 26100; DisplayVersion = '24H2'; Manufacturer = 'LENOVO'; Model = 'ThinkPad T14 Gen 3'
                          Cpu = 'Intel Core i7-1260P'; Cores = 12; RamGB = 16; SystemDisk = 'nvme'; HasBattery = $true; Firmware = 'UEFI'; PartitionStyle = 'GPT' }
$rec = [pscustomobject]@{ Preset = 'Standard'; Reasons = @('demo') }
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # powershell -File передає список одним рядком
$want = { param($n) -not $Only -or $Only -contains $n }

Show-D9Gui -Catalog $catalog -SystemInfo $sys -Recommendation $rec -ReportDir "$env:D9_DATA_ROOT\r" -DriverDir "$env:D9_DATA_ROOT\d" -TestAction {
    function Pump { $f = New-Object Windows.Threading.DispatcherFrame; [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Action]{ $f.Continue = $false }, [Windows.Threading.DispatcherPriority]::Background); [Windows.Threading.Dispatcher]::PushFrame($f) }
    function Wait { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($state.Job -and $sw.Elapsed.TotalSeconds -lt 120) { & $onTick; Pump; Start-Sleep -Milliseconds 100 }; & $onTick; Pump }
    function Tab([string]$uid) { $ui.Tabs.SelectedItem = @($ui.Tabs.Items | Where-Object Uid -eq $uid)[0]; Pump; Wait }
    function Shot([string]$name) {
        $win.UpdateLayout(); Pump; Start-Sleep -Milliseconds 300; Pump
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$win.Content.ActualWidth), ([int]$win.Content.ActualHeight), 96, 96, 'Pbgra32'
        # Фон вікна окремо: у вмісту він прозорий (у темній темі текст опинявся на білому)
        $dv = New-Object Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $rect = New-Object Windows.Rect 0, 0, $win.Content.ActualWidth, $win.Content.ActualHeight
        $dc.DrawRectangle($win.Background, $null, $rect)
        $brush = New-Object Windows.Media.VisualBrush $win.Content
        $brush.Stretch = 'None'; $brush.AlignmentX = 'Left'; $brush.AlignmentY = 'Top'
        $dc.DrawRectangle($brush, $null, $rect)
        $dc.Close()
        $bmp.Render($dv)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $path = Join-Path $Out "$name$suffix.png"
        $fs = [IO.File]::Create($path); $enc.Save($fs); $fs.Close()
        Write-Host "  $path"
    }
    $win.Width = 1280; $win.Height = 800; $win.WindowStyle = 'None'; $win.ShowInTaskbar = $false; $win.ShowActivated = $false; $win.Left = -3000; $win.Top = 0
    $win.Show(); $timer.Stop()
    $ui.SystemLine.Text = "Lenovo ThinkPad T14 Gen 3`nWindows 11 Pro 24H2`n16 GB, NVMe SSD"
    $ui.AdminBadge.Text = (T-D9 'Адміністратор'); $ui.BtnElevate.Visibility = 'Collapsed'

    # ---------- Огляд ----------
    if (& $want 'overview') {
        $cfg = Import-D9ScanConfig
        $cats = $cfg.Checks.categories
        $mk = { param($id, $cat, $sev, $t, $d, $fix) New-D9Finding ([pscustomobject]@{ id = $id; category = $cat }) $sev $t $d $fix }
        $findings = @(
            (& $mk 'clean.guard-reverted' 'cleanliness' 'warning' (T-D9 'Windows скасувала ваші зміни: {0}' 3) (L 'Copilot, рекомендації в «Пуску» й видалений застосунок повернулись після оновлення Windows. Debora поверне їх назад.' 'Copilot, Start recommendations and an app you removed came back after a Windows update. Debora will restore them.') @{ type = 'maintenance'; action = 'guardRestore' })
            (& $mk 'privacy.telemetry' 'privacy' 'warning' (L 'Телеметрія — на рівні «Повна»' 'Telemetry is set to Full') (L 'Windows надсилає Microsoft розширені діагностичні дані.' 'Windows sends extended diagnostic data to Microsoft.') @{ type = 'tweaks'; ids = @('privacy.telemetry') })
            (& $mk 'upd.apps' 'updates' 'warning' (L 'Програми з відомими вразливостями: 2' 'Programs with known vulnerabilities: 2') (L '7-Zip 23.01 і VLC 3.0.18 мають виправлення безпеки в новіших версіях.' '7-Zip 23.01 and VLC 3.0.18 have security fixes in newer versions.') @{ type = 'apps' })
            (& $mk 'disk.free' 'disk' 'suggestion' (L 'Тимчасові файли й кеш оновлень: 6,2 ГБ' 'Temporary files and update cache: 6.2 GB') (L 'Debora безпечно звільнить це місце.' 'Debora can free this space safely.') @{ type = 'tweaks'; ids = @('cleanup.temp') })
            (& $mk 'perf.startup' 'performance' 'suggestion' (L 'Програми в автозавантаженні сповільнюють запуск ≈ на 9 с' 'Startup programs slow down boot by about 9 s') (L 'Лаунчери ігор і оновлювачі стартують разом із Windows.' 'Game launchers and updaters start with Windows.') @{ type = 'manual' })
        )
        $scan = [pscustomobject]@{ id = '2026-10-16T12-00-00'; time = (Get-Date).ToString('s'); durationSec = 7.4; findings = $findings; checks = @(1..185)
            score = (Get-D9ScanScore -Categories $cats -Findings $findings -CheckedCategories @($cats.id)) }
        & $fillOverview $scan $cats
        Shot 'overview'
    }
    if ($Theme -eq 'dark') { $win.Hide(); return }

    if (& $want 'debloat') { Tab 'debloat'; Shot 'debloat' }
    if (& $want 'setup') { Tab 'setup'; Shot 'setup' }
    if (& $want 'programs') { $state.AppsLoaded = $true; Tab 'apps'; Shot 'programs' }

    # ---------- Драйвери ----------
    if (& $want 'drivers') {
        function Ent($id, $name, $class, $hw) { [pscustomobject]@{ DeviceID = $id; Name = $name; PNPClass = $class; ConfigManagerErrorCode = 0; HardwareID = @($hw); Manufacturer = $null } }
        function Drv($id, $ver, $date, $prov, $inf) { [pscustomobject]@{ DeviceID = $id; DriverVersion = $ver; DriverDate = [datetime]$date; DriverProviderName = $prov; InfName = $inf; IsSigned = $true } }
        $ents = @(
            (Ent 'PCI\VEN_8086&DEV_46A6\1' 'Intel(R) Iris(R) Xe Graphics' 'Display' 'PCI\VEN_8086&DEV_46A6')
            (Ent 'PCI\VEN_8086&DEV_51F0\1' 'Intel(R) Wi-Fi 6E AX211 160MHz' 'Net' 'PCI\VEN_8086&DEV_51F0')
            (Ent 'PCI\VEN_10EC&DEV_8168\1' 'Realtek PCIe GbE Family Controller' 'Net' 'PCI\VEN_10EC&DEV_8168')
            (Ent 'HDAUDIO\FUNC_01&VEN_10EC&DEV_0257\1' 'Realtek(R) Audio' 'Media' 'HDAUDIO\FUNC_01&VEN_10EC&DEV_0257')
            (Ent 'USB\VID_8087&PID_0033\1' 'Intel(R) Wireless Bluetooth(R)' 'Bluetooth' 'USB\VID_8087&PID_0033')
            (Ent 'USB\VID_04F2&PID_B6CB\1' 'Integrated Camera' 'Camera' 'USB\VID_04F2&PID_B6CB')
            (Ent 'PCI\VEN_144D&DEV_A80A\1' 'Samsung NVMe Controller' 'SCSIAdapter' 'PCI\VEN_144D&DEV_A80A')
            (Ent 'ACPI\SYNA8018\1' 'Synaptics TouchPad' 'Mouse' 'ACPI\SYNA8018')
            (Ent 'PCI\VEN_8086&DEV_51E8\1' 'Intel(R) Serial IO I2C Host Controller' 'System' 'PCI\VEN_8086&DEV_51E8')
            (Ent 'PCI\VEN_8086&DEV_51E9\1' 'Intel(R) Serial IO I2C Host Controller' 'System' 'PCI\VEN_8086&DEV_51E8')
            (Ent 'ACPI\GENUINEINTEL\0' '12th Gen Intel(R) Core(TM) i7-1260P' 'Processor' 'ACPI\GENUINEINTEL')
            (Ent 'ACPI\GENUINEINTEL\1' '12th Gen Intel(R) Core(TM) i7-1260P' 'Processor' 'ACPI\GENUINEINTEL')
        )
        $drvs = @(
            (Drv 'PCI\VEN_8086&DEV_46A6\1' '31.0.101.5186' '2024-01-10' 'Intel Corporation' 'oem41.inf')
            (Drv 'PCI\VEN_8086&DEV_51F0\1' '23.60.0.10' '2024-06-12' 'Intel' 'oem52.inf')
            (Drv 'PCI\VEN_10EC&DEV_8168\1' '10.38.1118.2019' '2019-11-18' 'Realtek' 'oem7.inf')
            (Drv 'HDAUDIO\FUNC_01&VEN_10EC&DEV_0257\1' '6.0.9405.1' '2022-09-15' 'Realtek Semiconductor Corp.' 'oem23.inf')
            (Drv 'USB\VID_8087&PID_0033\1' '23.60.0.1' '2024-06-03' 'Intel Corporation' 'oem55.inf')
            (Drv 'USB\VID_04F2&PID_B6CB\1' '10.0.26100.1' '2006-06-21' 'Microsoft' 'usbvideo.inf')
            (Drv 'PCI\VEN_144D&DEV_A80A\1' '10.0.26100.1' '2006-06-21' 'Microsoft' 'stornvme.inf')
            (Drv 'ACPI\SYNA8018\1' '19.5.35.70' '2021-03-02' 'Synaptics' 'oem12.inf')
            (Drv 'PCI\VEN_8086&DEV_51E8\1' '30.100.2129.8' '2021-07-21' 'Intel Corporation' 'oem31.inf')
            (Drv 'PCI\VEN_8086&DEV_51E9\1' '30.100.2129.8' '2021-07-21' 'Intel Corporation' 'oem31.inf')
            (Drv 'ACPI\GENUINEINTEL\0' '10.0.26100.1' '2006-06-21' 'Microsoft' 'cpu.inf')
            (Drv 'ACPI\GENUINEINTEL\1' '10.0.26100.1' '2006-06-21' 'Microsoft' 'cpu.inf')
        )
        $devices = @(Get-D9DeviceInventory -Entities $ents -Drivers $drvs -Manufacturers @{ x = 'y' })
        & $fillDrivers ([pscustomobject]@{ Oem = [pscustomobject]@{ Name = 'Lenovo'; Url = 'https://pcsupport.lenovo.com'; Note = $null; Serial = $null }; Problems = @(); Devices = $devices })
        function Cand($dev, $cur, $curDate, $title, $ver, $date, $size, $status, [switch]$Rec) {
            [pscustomobject]@{ Device = [pscustomobject]@{ Name = $dev; Version = $cur; Date = [datetime]$curDate }; Status = $status; Optional = $false; Recommended = [bool]$Rec
                               Row = [pscustomobject]@{ Title = $title; Version = $ver; Date = [datetime]$date; Size = $size } }
        }
        & $fillOnline @(
            (Cand 'Realtek PCIe GbE Family Controller' '10.38.1118.2019' '2019-11-18' 'Realtek - Net - 10.68.815.2023' '10.68.815.2023' '2023-08-15' 1.1MB 'newer' -Rec)
            (Cand 'Intel(R) Iris(R) Xe Graphics' '31.0.101.5186' '2024-01-10' 'Intel Corporation - Display - 32.0.101.6078' '32.0.101.6078' '2025-09-02' 612MB 'newer')
            (Cand 'Synaptics TouchPad' '19.5.35.70' '2021-03-02' 'Synaptics - Mouse - 19.5.35.94' '19.5.35.94' '2024-02-20' 9.8MB 'newer' -Rec)
            (Cand 'Intel(R) Serial IO I2C Host Controller' '30.100.2129.8' '2021-07-21' 'INTEL - System - 30.100.2237.26' '30.100.2237.26' '2023-02-13' 0.4MB 'newer')
        )
        $ui.StatusText.Text = (T-D9 'Готово')
        Tab 'drivers'; Shot 'drivers'
    }

    # ---------- Видалення ----------
    if (& $want 'uninstall') {
        function Prog($n, $p, $v, $mb, $days, $bloat, [switch]$Quiet) {
            [pscustomobject]@{ Name = $n; Publisher = $p; Version = $v; Size = [long]$mb * 1MB; InstallDate = (Get-Date).AddDays(-$days); Bloat = $bloat
                               UninstallString = 'MsiExec.exe /X{6D2F8E0A-1B3C-4D5E-8F9A-0B1C2D3E4F5A}'; QuietUninstallString = $(if ($Quiet) { 'MsiExec.exe /X{6D2F8E0A-1B3C-4D5E-8F9A-0B1C2D3E4F5A} /qn' }) }
        }
        & $fillUninst @(
            (Prog 'McAfee WebAdvisor' 'McAfee, LLC' '4.1.1.950' 74 420 (L 'реклама, встановлюється разом з іншими програмами' 'adware, bundled with other installers') -Quiet)
            (Prog 'Lenovo Vantage Service' 'Lenovo Group Ltd.' '4.2.12.0' 160 600 (L 'фонова служба виробника з рекламою' 'vendor background service with ads') -Quiet)
            (Prog 'Steam' 'Valve Corporation' '2.10.91.91' 812 210 $null -Quiet)
            (Prog 'Microsoft Office Home 2024' 'Microsoft Corporation' '16.0.18129' 3120 300 $null)
            (Prog 'Adobe Acrobat Reader (64-bit)' 'Adobe' '25.001.20531' 1210 180 $null)
            (Prog 'Zoom Workplace' 'Zoom Video Communications, Inc.' '6.2.7' 402 95 $null -Quiet)
            (Prog 'Spotify' 'Spotify AB' '1.2.48.405' 335 60 $null -Quiet)
            (Prog 'VLC media player' 'VideoLAN' '3.0.21' 168 400 $null -Quiet)
            (Prog 'Discord' 'Discord Inc.' '1.0.9168' 412 30 $null -Quiet)
            (Prog '7-Zip 24.08 (x64)' 'Igor Pavlov' '24.08' 6 500 $null -Quiet)
            (Prog 'Notepad++ (64-bit x64)' 'Notepad++ Team' '8.7' 15 120 $null -Quiet)
        )
        Tab 'uninstall'; Shot 'uninstall'
    }

    # ---------- Автозавантаження ----------
    if (& $want 'startup') {
        function St($n, $p, $where, $verdict, $reason, [bool]$on = $true) { [pscustomobject]@{ Name = $n; Publisher = $p; Where = $where; Command = "C:\Program Files\$n\$n.exe"; Exe = "$n.exe"; Enabled = $on; Verdict = $verdict; Reason = $reason } }
        $state.BootCulprits = @([pscustomobject]@{ Name = 'Steam'; Seconds = 4.2 }, [pscustomobject]@{ Name = 'EpicGamesLauncher'; Seconds = 3.1 })
        & $fillStartup @(
            (St 'Steam' 'Valve Corporation' 'HKCU\Run' 'disable' (L 'лаунчер ігор: відкриється, коли запустите гру' 'game launcher: opens when you start a game'))
            (St 'EpicGamesLauncher' 'Epic Games, Inc.' 'HKCU\Run' 'disable' (L 'лаунчер ігор' 'game launcher'))
            (St 'Microsoft Teams' 'Microsoft Corporation' 'HKCU\Run' 'optional' (L 'потрібен, лише якщо чекаєте дзвінків' 'only needed if you expect calls'))
            (St 'Spotify' 'Spotify AB' 'HKCU\Run' 'disable' (L 'музика: запускайте, коли потрібно' 'music: start it when you need it'))
            (St 'Discord' 'Discord Inc.' 'HKCU\Run' 'optional' (L 'чат' 'chat'))
            (St 'Adobe Acrobat Update' 'Adobe Inc.' 'HKLM\Run' 'optional' (L 'оновлювач' 'updater') $false)
            (St 'SecurityHealth' 'Microsoft Corporation' 'HKLM\Run' 'keep' (L 'значок Захисника Windows' 'Windows Security icon'))
            (St 'RtkAudUService' 'Realtek Semiconductor' 'HKLM\Run' 'keep' (L 'звук' 'audio'))
        )
        Tab 'startup'; Shot 'startup'
    }

    # ---------- Обслуговування: диски й батарея ----------
    if (& $want 'maintenance') {
        $state.DisksLoaded = $true
        $disk = [pscustomobject]@{ Number = 0; Model = 'Samsung SSD 980 PRO 1TB'; Bus = 'NVMe'; Media = 'SSD'; SizeBytes = 1000204886016; Letters = @('C:'); IsSystem = $true
                                   HealthStatus = 'Healthy'; HasCounters = $true; CountersAvailable = $true; Temperature = 41; TemperatureMax = 82; Wear = 4; PowerOnHours = 3120; StartStopCycles = 1460
                                   ReadErrorsUncorrected = 0; WriteErrorsUncorrected = 0; PredictFailure = $false; Firmware = '5B2QGXA7'; Removable = $false }
        $v = Get-D9DiskVerdict $disk
        $row = New-Object D9Row
        $row.Title = Format-D9DiskTitle $disk; $row.Status = T-D9 ([string]$script:D9DiskLevelText[$v.Level]); $row.Color = '#248A3D'; $row.Detail = Format-D9DiskDetails $disk
        Set-D9Items $ui.DisksList @($row)
        $ui.DisksState.Text = (T-D9 'Перевірено {0}. Температура, знос SSD, години роботи й помилки (SMART).' '12:00')
        $weeks = 100
        $fulls = @(0..($weeks - 1) | ForEach-Object { [math]::Round(57000 * (0.99 - 0.13 * $_ / ($weeks - 1)) + (Get-Random -Minimum -300 -Maximum 300)) })
        $start = (Get-Date).AddDays(-7 * $weeks)
        $h = for ($i = 0; $i -lt $weeks; $i++) { "<HistoryEntry LocalStartDate='$($start.AddDays(7 * $i).ToString('s'))' DesignCapacity='57000' FullChargeCapacity='$($fulls[$i])' CycleCount='0' BatteryChanged='0' ActiveAcTime='P4DT2H' ActiveDcTime='PT9H' CsAcTime='PT0S' CsDcTime='PT0S'/>" }
        $xml = [xml]"<BatteryReport><Batteries><Battery Id='x' Chemistry='LiP' DesignCapacity='57000' FullChargeCapacity='$($fulls[-1])' CycleCount='212'/></Batteries><RuntimeEstimates><FullChargeCapacity Capacity='$($fulls[-1])' ActiveRuntime='PT7H40M'/><DesignCapacity Capacity='57000' ActiveRuntime='PT8H50M'/></RuntimeEstimates><History>$($h -join '')</History></BatteryReport>"
        & $fillBattery (ConvertFrom-D9BatteryReport $xml)
        Tab 'maintenance'; Shot 'maintenance'
    }

    # ---------- Журнал змін ----------
    if (& $want 'history') {
        Tab 'history'
        & $fillSessions
        $ui.SessionGrid.SelectedIndex = 1; Pump
        Shot 'history'
    }
    $win.Hide()
}
[IO.Directory]::Delete($env:D9_DATA_ROOT, $true)
