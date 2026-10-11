# Проби сканера. Кожна отримує опис перевірки ($Check з checks.json) і контекст ($Ctx)
# та повертає нуль або більше знахідок (New-D9Finding) або New-D9Skip, якщо перевірити не вдалося.
# Нуль знахідок = усе гаразд.
#
# $Ctx: System, Catalog, Recommendation, Deep, IsAdmin, Now, Lifecycle, KnownBloat

function New-D9Finding {
    param(
        [Parameter(Mandatory)]$Check,
        [Parameter(Mandatory)][ValidateSet('critical', 'warning', 'suggestion', 'info')][string]$Severity,
        [Parameter(Mandatory)][string]$Title,
        [string]$Details,
        $Fix,                # @{ type = 'tweaks'|'maintenance'|'drivers'|'manual'; ... }
        [object[]]$Links,    # @{ label; url }
        [string]$Key,        # розрізняє кілька знахідок однієї перевірки (наприклад, пристрій)
        $Data
    )
    [pscustomobject]@{
        checkId  = $Check.id
        category = $Check.category
        severity = $Severity
        title    = $Title
        details  = $Details
        fix      = $Fix
        links    = @($Links | Where-Object { $_ })
        key      = if ($Key) { $Key } else { $Check.id }
        data     = $Data
    }
}

function New-D9Skip {
    param([Parameter(Mandatory)]$Check, [Parameter(Mandatory)][string]$Reason)
    [pscustomobject]@{ checkId = $Check.id; category = $Check.category; severity = 'skipped'; title = $Reason; key = $Check.id }
}

function New-D9Link { param([string]$Label, [string]$Url) [pscustomobject]@{ label = $Label; url = $Url } }

function Format-D9Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return (T-D9 '{0:N1} ГБ' ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return (T-D9 '{0:N0} МБ' ($Bytes / 1MB)) }
    return ((T-D9 '{0:N0} КБ') -f ($Bytes / 1KB))   # -f окремо: T-D9 не форматує, коли єдине значення — 0
}

# Розмір папки з обмеженням часу; недоступні підпапки пропускаються
function Get-D9FolderSize {
    param([string]$Path, [int]$TimeLimitMs = 4000)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $total = [long]0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -and $sw.ElapsedMilliseconds -lt $TimeLimitMs) {
        $dir = $stack.Pop()
        try {
            $info = New-Object IO.DirectoryInfo $dir
            foreach ($f in $info.GetFiles()) { $total += $f.Length }
            foreach ($d in $info.GetDirectories()) {
                if (-not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($d.FullName) }
            }
        } catch { }
    }
    return $total
}

# ======================= Безпека =======================

function Test-D9WindowsSupport {
    param($Check, $Ctx)
    $rel = $Ctx.Lifecycle.releases | Where-Object { $_.build -eq $Ctx.System.Build } | Select-Object -First 1
    if (-not $rel) { return New-D9Skip $Check (T-D9 'Збірка {0} відсутня в таблиці підтримки' $Ctx.System.Build) }
    $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
    $kind = if ($edition -like 'Enterprise*S*' -or $edition -like 'IoTEnterpriseS*') { 'ltsc' }
            elseif ($edition -like 'Enterprise*' -or $edition -like 'Education*') { 'enterprise' }
            else { 'consumer' }
    $endText = if ($rel.$kind) { $rel.$kind } else { $rel.consumer }
    $end = [datetime]::ParseExact($endText, 'yyyy-MM-dd', $null)
    $days = [int]($end - $Ctx.Now.Date).TotalDays
    $name = "$($Ctx.System.OsName) $($rel.version)"
    $links = @(New-D9Link (T-D9 'Терміни підтримки Windows (Microsoft)') ($Ctx.Lifecycle.sources | Select-Object -First 1))
    $steps = if ($rel.family -eq 'win10') {
        T-D9 'Варіанти: перейти на Windows 11 (якщо ПК підтримує або через Rufus на непідтримуваному), продовжити оновлення на рік через ESU (потрібен акаунт Microsoft) або перейти на Linux.'
    } else {
        T-D9 'Встановіть новішу версію Windows 11: Параметри → Windows Update → «Отримати останні оновлення» або через інсталяційну флешку.'
    }
    $note = Get-D9Text $rel.note
    if ($days -lt 0) {
        return New-D9Finding $Check critical (T-D9 '{0} більше не отримує оновлень безпеки (з {1})' $name ($end.ToString('dd.MM.yyyy'))) "$steps $note".Trim() @{ type = 'manual' } $links
    }
    if ($days -le $Check.thresholds.warnDays) {
        return New-D9Finding $Check warning (T-D9 '{0} перестане отримувати оновлення безпеки через {1} дн. ({2})' $name $days ($end.ToString('dd.MM.yyyy'))) $steps @{ type = 'manual' } $links
    }
}

function Get-D9SecurityProducts {
    param([string]$Class)
    try {
        Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName $Class -ErrorAction Stop | ForEach-Object {
            $hex = [Convert]::ToString([int]$_.productState, 16).PadLeft(6, '0')
            [pscustomobject]@{ Name = $_.displayName; Enabled = ($hex.Substring(2, 2) -in '10', '11'); UpToDate = ($hex.Substring(4, 2) -eq '00') }
        }
    } catch { @() }
}

# Автоматичне виправлення готовими діями (реєстр, служба, команда) — виконується рушієм з журналом і відкатом
function New-D9ActionsFix {
    param([object[]]$Actions, [switch]$Reboot)
    $fix = @{ type = 'actions'; actions = @($Actions | ForEach-Object { [pscustomobject]$_ }) }
    if ($Reboot) { $fix.reboot = $true }
    return $fix
}

function Test-D9Antivirus {
    param($Check, $Ctx)
    $products = @(Get-D9SecurityProducts 'AntiVirusProduct')
    $enabled  = @($products | Where-Object Enabled)
    $settings = New-D9Link (T-D9 'Відкрити «Безпека Windows»') 'windowsdefender:'
    if ($products.Count -and -not $enabled.Count) {
        return New-D9Finding $Check critical (T-D9 'Антивірусний захист вимкнено') (T-D9 'Жоден антивірус не працює. Debora увімкне Захисник Windows і оновить бази.') @{ type = 'maintenance'; action = 'defenderUpdate' } @($settings)
    }
    if ($enabled.Count -gt 1) {
        New-D9Finding $Check warning (T-D9 'Працюють кілька антивірусів одночасно: {0}' ($enabled.Name -join ', ')) (T-D9 'Два антивіруси конфліктують і сильно гальмують ПК. Залиште один (для більшості достатньо Захисника Windows).') @{ type = 'manual' } @((New-D9Link (T-D9 'Програми та компоненти') 'ms-settings:appsfeatures'))
    }
    $defenderActive = -not $enabled.Count -or ($enabled | Where-Object { $_.Name -like '*Defender*' -or $_.Name -like '*Microsoft*' })
    if ($defenderActive) {
        $mp = try { Get-MpComputerStatus -ErrorAction Stop } catch { $null }
        if ($mp) {
            if (-not $mp.RealTimeProtectionEnabled) {
                New-D9Finding $Check critical (T-D9 'Захист у реальному часі вимкнено') (T-D9 'Захисник Windows не перевіряє файли під час відкриття. Debora увімкне «Захист у реальному часі».') @{ type = 'maintenance'; action = 'defenderUpdate' } @($settings)
            }
            if ($mp.AntivirusSignatureAge -gt $Check.thresholds.signatureAgeDays) {
                # Причина: остання помилка оновлення баз (подія 2001) — коли Windows сама не може їх оновити
                $fail = @(Get-D9EventCount @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 2001; StartTime = $Ctx.Now.AddDays(-14) }) | Sort-Object TimeCreated -Descending | Select-Object -First 1
                $why = if ($fail) {
                    $failMsg = ([string](([string]$fail.Message -split "`r?`n" | Where-Object { $_ -match '0x[0-9a-fA-F]{8}' } | Select-Object -First 1))).Trim()
                    ' ' + (T-D9 'Windows намагалася оновити їх сама, але отримала помилку ({0}): {1}. Якщо після оновлення через Debora бази знову застаріють — скиньте Windows Update на вкладці «Обслуговування».' ($fail.TimeCreated.ToString('dd.MM.yyyy')) $failMsg)
                } else { '' }
                New-D9Finding $Check warning (T-D9 'Антивірусні бази застаріли ({0} дн.)' $mp.AntivirusSignatureAge) ((T-D9 'Debora оновить бази (потрібен інтернет).') + $why) @{ type = 'maintenance'; action = 'defenderUpdate' } @($settings)
            }
        }
    }
}

function Test-D9Firewall {
    param($Check, $Ctx)
    $profiles = try { @(Get-NetFirewallProfile -ErrorAction Stop) } catch { return New-D9Skip $Check (T-D9 'Не вдалося прочитати стан брандмауера') }
    $off = @($profiles | Where-Object { -not $_.Enabled })
    if (-not $off.Count) { return }
    if (@(Get-D9SecurityProducts 'FirewallProduct' | Where-Object Enabled).Count) { return }   # працює сторонній брандмауер
    $names = ($off.Name -join ',')
    $fix = New-D9ActionsFix @(@{ type = 'command'; run = "Set-NetFirewallProfile -Profile $names -Enabled True"; undoRun = "Set-NetFirewallProfile -Profile $names -Enabled False"
                                 test = "-not @(Get-NetFirewallProfile -Profile $names | Where-Object { -not `$_.Enabled })"; label = @{ uk = "Увімкнути брандмауер ($names)"; en = "Enable firewall ($names)" } })
    New-D9Finding $Check critical (T-D9 'Брандмауер вимкнено для мереж: {0}' ($off.Name -join ', ')) (T-D9 'Debora увімкне брандмауер Windows для цих мереж.') $fix @((New-D9Link (T-D9 'Брандмауер і захист мережі') 'windowsdefender://network'))
}

function Test-D9Uac {
    param($Check, $Ctx)
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    if ($p.EnableLUA -eq 0) {
        return New-D9Finding $Check critical (T-D9 'Контроль облікових записів (UAC) вимкнено') (T-D9 'Будь-яка програма може непомітно отримати права адміністратора. Debora увімкне UAC; запрацює після перезавантаження.') (New-D9ActionsFix @(@{ type = 'registry'; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; name = 'EnableLUA'; value = 1; kind = 'DWord' }) -Reboot) @((New-D9Link (T-D9 'Параметри UAC') 'UserAccountControlSettings.exe'))
    }
    if ($p.ConsentPromptBehaviorAdmin -eq 0) {
        return New-D9Finding $Check warning (T-D9 'UAC не питає підтвердження для адміністратора') (T-D9 'Підвищення прав відбувається без запиту. Debora поверне стандартний рівень «Повідомляти лише коли програми намагаються внести зміни».') (New-D9ActionsFix @(@{ type = 'registry'; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; name = 'ConsentPromptBehaviorAdmin'; value = 5; kind = 'DWord' })) @((New-D9Link (T-D9 'Параметри UAC') 'UserAccountControlSettings.exe'))
    }
}

function Test-D9SecureBoot {
    param($Check, $Ctx)
    if ($Ctx.System.Firmware -ne 'UEFI') {
        return New-D9Finding $Check info (T-D9 'Комп''ютер завантажується в режимі Legacy BIOS') (T-D9 'Безпечне завантаження недоступне. Для Windows 11 і кращого захисту бажано перейти на UEFI (потрібне перевстановлення або MBR2GPT).')
    }
    $state = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled
    if ($state -eq 0) {
        New-D9Finding $Check suggestion (T-D9 'Безпечне завантаження (Secure Boot) вимкнено') (T-D9 'Увімкніть Secure Boot у налаштуваннях UEFI/BIOS (вкладка Boot або Security). Захищає від шкідливих програм, що запускаються до Windows.') @{ type = 'manual' }
    }
}

# ======================= Оновлення =======================

function Test-D9LastUpdate {
    param($Check, $Ctx)
    $last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if (-not $last) { return New-D9Skip $Check (T-D9 'Історія оновлень недоступна') }
    $days = [int]($Ctx.Now - $last.InstalledOn).TotalDays
    if ($days -gt $Check.thresholds.warnDays) {
        New-D9Finding $Check warning (T-D9 'Windows не оновлювалась {0} дн. (останнє: {1}, {2})' $days $last.HotFixID ($last.InstalledOn.ToString('dd.MM.yyyy'))) (T-D9 'Debora знайде й встановить оновлення Windows (лише програмні; драйвери — окремо, на вкладці «Драйвери»).') @{ type = 'maintenance'; action = 'windowsUpdate' } @((New-D9Link 'Windows Update' 'ms-settings:windowsupdate'))
    }
}

function Test-D9PendingReboot {
    param($Check, $Ctx)
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    if ($keys | Where-Object { Test-Path $_ }) {
        New-D9Finding $Check warning (T-D9 'Windows чекає перезавантаження, щоб завершити оновлення') (T-D9 'Поки ПК не перезавантажено, частина оновлень не діє, а нові можуть не встановлюватись.') @{ type = 'maintenance'; action = 'reboot' }
    }
}

$script:D9DeviceErrors = @{
    1 = 'не налаштовано'; 3 = 'драйвер пошкоджено або бракує пам''яті'; 10 = 'пристрій не може запуститися'
    12 = 'бракує ресурсів'; 14 = 'потрібне перезавантаження'; 18 = 'драйвер треба перевстановити'
    19 = 'пошкоджено реєстр'; 21 = 'видаляється'; 24 = 'пристрій відсутній або не працює'
    28 = 'драйвер не встановлено'; 31 = 'драйвер не завантажився'; 32 = 'службу драйвера вимкнено'
    37 = 'драйвер повернув помилку'; 39 = 'драйвер пошкоджено або відсутній'; 43 = 'Windows зупинила пристрій (збій)'
    48 = 'драйвер заблоковано'; 52 = 'драйвер без дійсного цифрового підпису'
}

# Опис коду помилки пристрою мовою інтерфейсу (тексти — ті самі, що в $script:D9DeviceErrors)
function Get-D9DeviceErrorText {
    param([int]$Code)
    switch ($Code) {
        1  { T-D9 'не налаштовано' }
        3  { T-D9 'драйвер пошкоджено або бракує пам''яті' }
        10 { T-D9 'пристрій не може запуститися' }
        12 { T-D9 'бракує ресурсів' }
        14 { T-D9 'потрібне перезавантаження' }
        18 { T-D9 'драйвер треба перевстановити' }
        19 { T-D9 'пошкоджено реєстр' }
        21 { T-D9 'видаляється' }
        24 { T-D9 'пристрій відсутній або не працює' }
        28 { T-D9 'драйвер не встановлено' }
        31 { T-D9 'драйвер не завантажився' }
        32 { T-D9 'службу драйвера вимкнено' }
        37 { T-D9 'драйвер повернув помилку' }
        39 { T-D9 'драйвер пошкоджено або відсутній' }
        43 { T-D9 'Windows зупинила пристрій (збій)' }
        48 { T-D9 'драйвер заблоковано' }
        52 { T-D9 'драйвер без дійсного цифрового підпису' }
        default { T-D9 'код помилки {0}' $Code }
    }
}

function Test-D9ProblemDevices {
    param($Check, $Ctx)
    $devices = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue |
        Where-Object { $_.ConfigManagerErrorCode -notin 22, 45 })   # 22 — вимкнено користувачем, 45 — не під'єднано
    $oem = if ($devices) { Get-D9OemSupport $Ctx.System } else { $null }
    foreach ($d in $devices) {
        $hwid = @($d.HardwareID) | Select-Object -First 1
        $info = Resolve-D9Device @($d.HardwareID)
        $name = Get-D9DeviceDisplayName $info $d.Name
        $reason = Get-D9DeviceErrorText ([int]$d.ConfigManagerErrorCode)
        $links = @(Get-D9DriverLinks $info $oem) + @(New-D9Link (T-D9 'Диспетчер пристроїв') 'devmgmt.msc')
        $details = T-D9 'ID обладнання: {0}. Debora спершу сам пошукає драйвер у каталозі Microsoft і Windows Update та встановить його.' $hwid
        if ($oem) { $details += ' ' + (T-D9 'Якщо не знайде — драйвер з сайту {0} для вашої моделі: завантажте в папку «Драйвери» й виберіть «Встановити драйвери з папки».' $oem.Name) }
        New-D9Finding $Check warning "$name — $reason" $details @{ type = 'drivers' } $links -Key "$($Check.id):$($d.PNPDeviceID)" -Data ([pscustomobject]@{
            name = $name; hwid = $hwid; class = $d.PNPClass; code = [int]$d.ConfigManagerErrorCode; deviceId = $d.PNPDeviceID
        })
    }
}

# Глибоке сканування: чи є в каталозі Microsoft новіші драйвери для пристроїв цього ПК
function Test-D9DriverUpdates {
    param($Check, $Ctx)
    $all = @(Find-D9DriverUpdates -SystemInfo $Ctx.System -IncludeWindowsUpdate)
    $main = @($all | Where-Object { -not $_.Optional })
    if (-not $main) { return }
    $list = ($main | Select-Object -First 8 | ForEach-Object { "$($_.Device.Name) ($(if ($_.Device.Version) { $_.Device.Version } else { T-D9 'без драйвера' }) → $($_.Row.Version))" }) -join '; '
    $extra = if ($all.Count -gt $main.Count) { ' ' + (T-D9 'Ще {0} необов''язкових — на вкладці «Драйвери».' ($all.Count - $main.Count)) } else { '' }
    $severity = if ($main | Where-Object Status -eq 'missing') { 'warning' } else { 'suggestion' }
    New-D9Finding $Check $severity (T-D9 'Новіші драйвери в каталозі Microsoft: {0}' $main.Count) ((T-D9 '{0}. Debora завантажить і встановить їх, зберігши попередні для відкату.' $list) + $extra) @{ type = 'maintenance'; action = 'driverUpdate' }
}

function Test-D9AppUpdates {
    param($Check, $Ctx)
    if (-not (Get-D9WingetPath)) { return New-D9Skip $Check (T-D9 'winget не встановлено') }
    $apps = @(Get-D9AppUpgrades)
    if ($apps.Count) {
        $names = ($apps | Select-Object -First 8 | ForEach-Object Name) -join ', '
        New-D9Finding $Check suggestion (T-D9 'Для {0} програм є оновлення' $apps.Count) (T-D9 'Наприклад: {0}' $names) @{ type = 'maintenance'; action = 'wingetUpgrade' }
    }
}

# ======================= Диск =======================

function Test-D9DiskHealth {
    param($Check, $Ctx)
    $disks = @(try { Get-D9DiskHealth } catch { })
    if (-not $disks) { return New-D9Skip $Check (T-D9 'Не вдалося прочитати стан дисків') }
    $backup = T-D9 'Негайно скопіюйте важливі файли на інший диск або в хмару. Диск варто замінити.'
    # Флешки й карти пам'яті не оцінюємо: програму часто запускають саме з флешки
    foreach ($d in @($disks | Where-Object { -not $_.Removable })) {
        $v = Get-D9DiskVerdict $d -WearPercent $Check.thresholds.wearPercent -TempC $Check.thresholds.tempC
        if ($v.Level -notin 'bad', 'warn') { continue }
        $letters = if ($d.Letters) { ' (' + ($d.Letters -join ', ') + ')' } else { '' }
        $name = T-D9 'Диск {0}{1}' ([string]$d.Model) $letters
        $problems = $v.Problems -join '; '
        $info = T-D9 '{0}. Подробиці — вкладка «Обслуговування» → «Стан дисків».' (Format-D9DiskDetails $d)
        if ($v.Level -eq 'bad') {
            New-D9Finding $Check critical "${name}: $problems" "$backup $info" @{ type = 'manual' } -Key "$($Check.id):$($d.Number)"
        } elseif ($d.Temperature -ge $Check.thresholds.tempC -and $v.Problems.Count -eq 1) {
            New-D9Finding $Check warning "${name}: $problems" (T-D9 'Перевірте охолодження: чистка від пилу, вентиляція корпусу; для M.2 SSD — радіатор. {0}' $info) @{ type = 'manual' } -Key "$($Check.id):$($d.Number)"
        } else {
            New-D9Finding $Check warning "${name}: $problems" (T-D9 'Робіть резервні копії й плануйте заміну диска. {0}' $info) @{ type = 'manual' } -Key "$($Check.id):$($d.Number)"
        }
    }
}

function Test-D9FreeSpace {
    param($Check, $Ctx)
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'" -ErrorAction SilentlyContinue
    if (-not $c -or -not $c.Size) { return New-D9Skip $Check (T-D9 'Не вдалося прочитати диск C:') }
    $freeGB = [math]::Round($c.FreeSpace / 1GB, 1)
    $percent = [math]::Round($c.FreeSpace * 100 / $c.Size)
    $t = $Check.thresholds
    $title = T-D9 'На диску C: вільно лише {0:N1} ГБ ({1}%)' $freeGB $percent
    $details = T-D9 'Коли місця мало, Windows гальмує й не може встановити оновлення. Дивіться пункти очищення нижче, перенесіть фото й відео на інший диск.'
    $fix = @{ type = 'tweaks'; ids = @('cleanup.temp', 'cleanup.update-cache') }
    if ($percent -lt $t.criticalPercent -or $freeGB -lt $t.criticalGB) { return New-D9Finding $Check critical $title $details $fix }
    if ($percent -lt $t.warningPercent -or $freeGB -lt $t.warningGB) { return New-D9Finding $Check warning $title $details $fix }
}

function Test-D9Trim {
    param($Check, $Ctx)
    if ($Ctx.System.SystemDisk -notin 'ssd', 'nvme') { return }
    $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name DisableDeleteNotification -ErrorAction SilentlyContinue).DisableDeleteNotification
    if ($v -eq 1) {
        New-D9Finding $Check warning (T-D9 'TRIM для SSD вимкнено') (T-D9 'Без TRIM SSD поступово сповільнюється і швидше зношується.') @{ type = 'tweaks'; ids = @('perf.enable-trim') }
    }
}

# ======================= Швидкодія =======================

function Test-D9Startup {
    param($Check, $Ctx)
    $system  = @('SecurityHealth', 'Windows Defender', 'WindowsDefender')   # значок «Безпека Windows» — не чіпаємо
    $all = @(Get-D9StartupItems)
    # Те, що безпечно вимкнути (лаунчери ігор, «помічники», реклама виробника) — Debora вимкне сам, з відкатом
    $rec = @($all | Where-Object { $_.Enabled -and $_.Verdict -eq 'disable' })
    if ($rec) {
        $list = ($rec | ForEach-Object { "$($_.Name) ($($_.Reason))" }) -join '; '
        New-D9Finding $Check $(if ($rec.Count -ge 3) { 'warning' } else { 'suggestion' }) (T-D9 'Непотрібне в автозапуску: {0}' $rec.Count) (T-D9 'Debora вимкне автозапуск (програми не видаляються, відкат — у «Журналі змін»): {0}' $list) (New-D9ActionsFix @($rec | ForEach-Object { New-D9StartupAction $_ $false })) -Key "$($Check.id):recommended"
    }
    $enabled = @($all | Where-Object { $_.Kind -eq 'reg' -and $_.Enabled -and $system -notcontains $_.Name -and $_.Verdict -ne 'disable' })
    $t = $Check.thresholds
    $weak = $Ctx.Recommendation.Preset -eq 'WeakPC'
    $limit = if ($weak) { $t.weakPcSuggestion } else { $t.suggestion }
    if ($enabled.Count -le $limit) { return }
    $severity = if ($enabled.Count -gt $t.warning -or ($weak -and $enabled.Count -gt $t.suggestion)) { 'warning' } else { 'suggestion' }
    New-D9Finding $Check $severity (T-D9 '{0} програм запускаються разом із Windows' $enabled.Count) (T-D9 'Вимкніть непотрібні: вкладка «Автозавантаження» в Debora (з можливістю відкату) або Диспетчер завдань. Зараз: {0}' ($enabled.Name -join ', ')) @{ type = 'manual' } @((New-D9Link (T-D9 'Програми автозавантаження') 'ms-settings:startupapps'))
}

function Test-D9Memory {
    param($Check, $Ctx)
    $os = Get-CimInstance Win32_OperatingSystem
    $used = [math]::Round(100 - $os.FreePhysicalMemory * 100 / $os.TotalVisibleMemorySize)
    if ($used -lt $Check.thresholds.warningPercent) { return }
    $top = Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Bytes = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum }
    } | Sort-Object Bytes -Descending | Select-Object -First 5
    $list = ($top | ForEach-Object { "$($_.Name) $(Format-D9Size $_.Bytes)" }) -join ', '
    New-D9Finding $Check warning (T-D9 'Зайнято {0}% оперативної пам''яті' $used) (T-D9 'Найбільше займають: {0}. Закрийте зайві програми й вкладки браузера.' $list) @{ type = 'manual' }
}

function Test-D9HardwareFit {
    param($Check, $Ctx)
    $sys = $Ctx.System
    if ($sys.SystemDisk -eq 'hdd') {
        foreach ($pair in @(@('perf.disable-sysmain', (T-D9 'SysMain (Superfetch) постійно навантажує жорсткий диск')), @('perf.disable-search-index', (T-D9 'Індексація пошуку постійно навантажує жорсткий диск')))) {
            $tweak = Get-D9Tweak $Ctx.Catalog $pair[0]
            if ($tweak -and (Get-D9TweakState $tweak $sys) -in 'notApplied', 'partial') {
                New-D9Finding $Check warning $pair[1] (Get-D9Text $tweak.description) @{ type = 'tweaks'; ids = @($pair[0]) } -Key "$($Check.id):$($pair[0])"
            }
        }
    }
    if ($sys.SystemDisk -in 'ssd', 'nvme') {
        $svc = Get-D9ServiceState ([pscustomobject]@{ name = 'SysMain' })
        if ($svc.exists -and $svc.startup -eq 'Disabled') {
            New-D9Finding $Check suggestion (T-D9 'SysMain вимкнено, хоча диск — SSD') (T-D9 'На SSD служба SysMain пришвидшує запуск програм. Debora увімкне її знову.') (New-D9ActionsFix @(@{ type = 'service'; name = 'SysMain'; startup = 'Automatic'; start = $true })) -Key "$($Check.id):sysmain-ssd"
        }
    }
    $active = Get-D9ActivePowerScheme
    if ($active -eq $script:D9PowerSchemes.saver -and -not $sys.HasBattery) {
        New-D9Finding $Check warning (T-D9 'Увімкнено схему живлення «Економія енергії» на ПК без батареї') (T-D9 'Процесор працює на зниженій частоті без потреби.') @{ type = 'tweaks'; ids = @('perf.power-high') } -Key "$($Check.id):power"
    }
}

function Test-D9Uptime {
    param($Check, $Ctx)
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $days = [int]($Ctx.Now - $boot).TotalDays
    if ($days -gt $Check.thresholds.days) {
        New-D9Finding $Check suggestion (T-D9 'Комп''ютер не перезавантажувався {0} дн.' $days) (T-D9 'Через «швидкий запуск» вимкнення не очищує пам''ять. Перезавантаження («Пуск → Перезавантажити») звільняє ресурси й завершує оновлення.') @{ type = 'maintenance'; action = 'reboot' }
    }
}

function Test-D9KnownBloat {
    param($Check, $Ctx)
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installed = Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 }
    $found = foreach ($rule in $Ctx.KnownBloat.programs) {
        $installed | Where-Object DisplayName -like $rule.pattern | ForEach-Object {
            [pscustomobject]@{ Name = $_.DisplayName; Reason = Get-D9Text $rule.reason }
        }
    }
    $found = @($found | Sort-Object Name -Unique)
    if (-not $found.Count) { return }
    $details = ($found | ForEach-Object { "$($_.Name) — $($_.Reason)" }) -join '; '
    New-D9Finding $Check warning (T-D9 'Знайдено небажані програми: {0}' $found.Count) (T-D9 'Debora видалить їх (перед цим — точка відновлення): {0}' $details) @{ type = 'uninstall'; names = @($found.Name) } @((New-D9Link (T-D9 'Встановлені програми') 'ms-settings:appsfeatures')) -Data ([pscustomobject]@{ programs = @($found.Name) })
}

# Твіки рекомендованого профілю з указаних категорій, які ще не застосовано
function Test-D9ProfileTweaks {
    param($Check, $Ctx)
    $preset = Get-D9Preset $Ctx.Catalog $Ctx.Recommendation.Preset
    $skip = @('perf.disable-sysmain', 'perf.disable-search-index')   # їх показує perf.hardware-fit
    $pending = foreach ($id in $preset.tweaks) {
        if ($skip -contains $id) { continue }
        $t = Get-D9Tweak $Ctx.Catalog $id
        if ($t.category -notin $Check.params.categories -or $t.irreversible) { continue }
        if ((Get-D9TweakState $t $Ctx.System) -in 'notApplied', 'partial') { $t }
    }
    $pending = @($pending)
    if (-not $pending.Count) { return }
    $presetName = Get-D9Text $preset.name
    $names = ($pending | ForEach-Object { Get-D9Text $_.name }) -join '; '
    New-D9Finding $Check suggestion (T-D9 'Не застосовано налаштувань профілю «{0}»: {1}' $presetName $pending.Count) $names @{ type = 'tweaks'; ids = @($pending.id) }
}

function Test-D9BloatApps {
    param($Check, $Ctx)
    $preset = Get-D9Preset $Ctx.Catalog $Ctx.Recommendation.Preset
    $pending = @($preset.tweaks | ForEach-Object { Get-D9Tweak $Ctx.Catalog $_ } |
        Where-Object { $_.category -eq 'apps' -and (Get-D9TweakState $_ $Ctx.System) -in 'notApplied', 'partial' })
    if (-not $pending.Count) { return }
    $apps = @(foreach ($t in $pending) {
        foreach ($a in (Get-D9ApplicableActions $t $Ctx.System | Where-Object type -eq 'appx')) {
            (Get-D9AppxInstalled $a.package).Name
        }
    }) | Where-Object { $_ } | Sort-Object -Unique
    $title = if ($apps.Count) { T-D9 'Встановлено рекламних і непотрібних застосунків: {0}' $apps.Count } else { T-D9 'Не вимкнено автоустановку рекламних застосунків' }
    $details = (($pending | ForEach-Object { Get-D9Text $_.name }) -join '; ')
    if ($apps.Count) { $details += '. ' + (T-D9 'Знайдено: {0}' (($apps | Select-Object -First 12) -join ', ')) }
    New-D9Finding $Check suggestion $title $details @{ type = 'tweaks'; ids = @($pending.id) }
}

# ======================= Стабільність =======================

function Get-D9EventCount {
    param([hashtable]$Filter)
    $events = Get-D9Events $Filter
    if ($null -eq $events) { @() } else { @($events) }
}

# Томи за літерою, шляхом \\?\Volume{GUID} і міткою → чи це системний том
function Get-D9VolumeIndex {
    $index = @{}
    foreach ($v in @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue)) {
        $isSystem = $v.DriveLetter -eq $env:SystemDrive
        foreach ($key in @($v.DriveLetter, ([string]$v.DeviceID).TrimEnd('\'), $v.Label) | Where-Object { $_ }) {
            # Однакова мітка на кількох томах — не розрізняємо; системний має перевагу
            if (-not $index.ContainsKey($key) -or $isSystem) { $index[$key] = $isSystem }
        }
    }
    return $index
}

# Подія NTFS стосується системного тому? Невідомий том — вважаємо системним (краще зайве попередження).
function Test-D9NtfsEventOnSystem {
    param($Event, [hashtable]$Volumes)
    $drive = $null; $device = $null
    try {
        $data = ([xml]$Event.ToXml()).Event.EventData.Data
        $drive = [string](@($data | Where-Object Name -eq 'DriveName') | Select-Object -First 1).'#text'
        $device = [string](@($data | Where-Object Name -eq 'DeviceName') | Select-Object -First 1).'#text'
    } catch { }
    if ($device -like '*ShadowCopy*') { return $false }   # тіньові копії (точки відновлення), а не сам диск
    if (-not $drive) { return $true }
    $drive = $drive.TrimEnd('\')
    if ($Volumes.ContainsKey($drive)) { return $Volumes[$drive] }
    if ($drive -match '^[A-Za-z]:$' -or $drive -like '\\?\Volume{*') { return $false }   # інший том, якого вже немає (витягнута флешка)
    return $true
}

function Test-D9DiskErrors {
    param($Check, $Ctx)
    $days = $Check.thresholds.days
    $since = $Ctx.Now.AddDays(-$days)
    # Лише помилки й попередження: Ntfs 98 з рівнем «Відомості» означає «том справний»
    $events = @(Get-D9EventCount @{ LogName = 'System'; ProviderName = @('disk', 'Ntfs', 'Microsoft-Windows-Ntfs'); Id = @(7, 51, 55, 98, 153); Level = @(1, 2, 3); StartTime = $since })
    if (-not $events.Count) { return }
    $systemDisk = try {
        (Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName MSFT_Partition -Filter "DriveLetter = '$([char]$env:SystemDrive.TrimEnd(':'))'" -ErrorAction Stop | Select-Object -First 1).DiskNumber
    } catch { $null }
    # Події диска (disk) містять \Device\HarddiskN, події NTFS — том (DriveName): відділяємо системний диск
    # від флешок і зовнішніх (програму часто запускають саме з флешки, і помилки на ній — не про C:)
    $volumes = Get-D9VolumeIndex
    $onSystem = @($events | Where-Object {
        if ($_.ProviderName -eq 'disk') { $null -eq $systemDisk -or ($_.Message -match 'Harddisk(\d+)' -and [int]$Matches[1] -eq $systemDisk) }
        else { Test-D9NtfsEventOnSystem $_ $volumes }
    })
    $other = $events.Count - $onSystem.Count
    $smart = if ($Ctx.IsAdmin) { T-D9 'Стан SMART (температура, знос, помилки) — вкладка «Обслуговування» → «Стан дисків».' } else { T-D9 'Для перевірки SMART запустіть сканування від адміністратора.' }
    # Два різні випадки: пошкоджені блоки (disk 7) — сам диск не може прочитати дані, це залізо, і chkdsk тут
    # не допоможе; помилки файлової системи (Ntfs 55, 98) — їх виправляє chkdsk
    $blocks = @($onSystem | Where-Object { $_.ProviderName -eq 'disk' -and $_.Id -eq 7 })
    $fsErrors = @($onSystem | Where-Object { $_.ProviderName -ne 'disk' -and $_.Id -in 55, 98 })
    $found = @()
    if ($blocks.Count) {
        $lastB = ($blocks | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        $today = @($blocks | Where-Object { $_.TimeCreated -gt $Ctx.Now.AddDays(-1) }).Count
        $severity = if ($blocks.Count -ge 3) { 'critical' } else { 'warning' }
        # Від адміністратора звіряємо з SMART: якщо диск справний і не рахує невиправних помилок, події можуть
        # бути збоями зв'язку з диском (драйвер, прошивка, живлення) — це попередження, а не «диск помирає»
        $sys = if ($Ctx.IsAdmin) { @(try { Get-D9DiskHealth } catch { }) | Where-Object IsSystem | Select-Object -First 1 }
        $smartClean = $sys -and (Get-D9DiskVerdict $sys).Level -eq 'ok' -and [long]$sys.ReadErrorsUncorrected -eq 0
        if ($smartClean) { $severity = 'warning' }
        $title = T-D9 'Системний диск повідомляє про пошкоджені блоки: {0} за {1} днів (остання {2})' $blocks.Count $days ($lastB.ToString('dd.MM.yyyy HH:mm'))
        $details = (T-D9 'Диск сам не може прочитати частину даних — це ознака зносу або несправності накопичувача, і перевірка файлової системи (chkdsk) тут не допоможе.') + ' ' +
            $(if ($today -ge 3) { (T-D9 'За останню добу — {0}: проблема наростає.' $today) + ' ' }) +
            (T-D9 'Негайно скопіюйте важливі файли на інший диск або в хмару.') + ' ' +
            $(if ($smartClean) { T-D9 'SMART диска поки чистий (невиправних помилок 0): можливо, це збої зв''язку з диском — оновіть прошивку й драйвер накопичувача і стежте, чи події повторюються.' } else { $smart })
        $found += New-D9Finding $Check $severity $title $details @{ type = 'manual' } -Key 'stab.disk-errors:blocks'
    }
    if ($fsErrors.Count) {
        $lastF = ($fsErrors | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        $severity = if ($fsErrors.Count -ge 3) { 'critical' } else { 'warning' }
        $details = (T-D9 'Зробіть резервну копію важливих файлів.') + ' ' + $smart + ' ' + (T-D9 'Debora перевірить файлову систему (chkdsk) і, якщо треба, виправить її під час перезавантаження.')
        $found += New-D9Finding $Check $severity (T-D9 'Помилки файлової системи на системному диску: {0} за {1} днів (остання {2})' $fsErrors.Count $days ($lastF.ToString('dd.MM.yyyy'))) $details @{ type = 'maintenance'; action = 'chkdskScan' } -Key 'stab.disk-errors:fs'
    }
    if ($found) { return $found }
    $details = (T-D9 'Зробіть резервну копію важливих файлів.') + ' ' + $smart
    if ($onSystem.Count) {
        return New-D9Finding $Check warning (T-D9 'Помилки звернення до системного диска: {0} за {1} днів' $onSystem.Count $days) (T-D9 'Можливо, поганий кабель, перегрів або початок проблем з диском. {0}' $details) @{ type = 'manual' }
    }
    if ($other) {
        New-D9Finding $Check info (T-D9 'Помилки на інших дисках (флешки, зовнішні): {0} за {1} днів' $other $days) (T-D9 'Системного диска не стосується. Якщо на тих дисках важливі дані — перевірте їх.')
    }
}

function Test-D9SystemFiles {
    param($Check, $Ctx)
    $r = try { Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop } catch { return New-D9Skip $Check (T-D9 'Не вдалося перевірити: {0}' $_.Exception.Message) }
    switch ([string]$r.ImageHealthState) {
        'Repairable'    { New-D9Finding $Check warning (T-D9 'Системні файли Windows пошкоджено (можна відновити)') (T-D9 'Відновлення: DISM /RestoreHealth, потім sfc /scannow (10–30 хв, потрібен інтернет).') @{ type = 'maintenance'; action = 'repairSystem' } }
        'NonRepairable' { New-D9Finding $Check critical (T-D9 'Системні файли Windows пошкоджено безповоротно') (T-D9 'Рекомендується перевстановлення Windows зі збереженням файлів (оновлення поверх інсталяційною флешкою).') @{ type = 'manual' } }
    }
}

# ======================= Батарея =======================

# Звіт powercfg (Get-D9BatteryHealth, працює без адміністратора); якщо його немає — класи root\wmi.
# Один звіт на сканування: його використовують дві перевірки, а створення триває ~1 с.
function Get-D9ScanBattery {
    param($Ctx)
    if ($Ctx -and $Ctx.PSObject.Properties['Battery'] -and $Ctx.Battery) { return $Ctx.Battery }
    $b = Get-D9BatteryHealth
    if (-not $b) {
        try {
            $full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
            $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
            $cycles = try { [int](Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop | Select-Object -First 1).CycleCount } catch { 0 }
            if ($full -and $design) { $b = [pscustomobject]@{ Design = [double]$design; Full = [double]$full; Health = [math]::Round($full * 100 / $design); Cycles = $(if ($cycles -gt 0) { $cycles }); History = @(); WearPerYear = $null; Forecast60 = $null; AcShare = $null; RuntimeNow = $null; RuntimeDesign = $null } }
        } catch { }
    }
    if ($Ctx) { $Ctx | Add-Member -NotePropertyName Battery -NotePropertyValue $b -Force }
    $b
}

function Test-D9BatteryWear {
    param($Check, $Ctx)
    if (-not $Ctx.System.HasBattery) { return New-D9Skip $Check (T-D9 'Батареї немає') }
    $b = Get-D9ScanBattery $Ctx
    if (-not $b) {
        return New-D9Skip $Check $(if ($Ctx.IsAdmin) { T-D9 'Батарея не повідомляє ємність (можливо, вийнята або несправна)' } else { T-D9 'Дані батареї недоступні (потрібні права адміністратора)' })
    }
    $t = $Check.thresholds
    $level = Get-D9BatteryLevel $b -WarningPercent $t.warningPercent -CriticalPercent $t.criticalPercent
    if ($level -notin 'warn', 'bad') { return }
    $title = T-D9 'Батарея зберігає {0}% початкової ємності' $b.Health
    $details = (T-D9 'Час роботи від батареї помітно скоротився. Батарею можна замінити в сервісі.') + ' ' + (Format-D9BatteryDetails $b) + '.'
    if ($b.Cycles -gt 0 -and $b.Cycles -lt 300) { $details += ' ' + (T-D9 'Циклів заряду: {0} — для такого зносу це мало: ймовірно, батарея старіє від нагріву або постійного заряду 100%. Якщо виробник ноутбука має режим «обмеження заряду» (80%), увімкніть його.' $b.Cycles) }
    New-D9Finding $Check $(if ($level -eq 'bad') { 'critical' } else { 'warning' }) $title $details @{ type = 'manual' }
}

# Батарея ще не зношена, але старіє швидко, бо ноутбук майже весь час на зарядці
function Test-D9BatteryHabits {
    param($Check, $Ctx)
    if (-not $Ctx.System.HasBattery) { return New-D9Skip $Check (T-D9 'Батареї немає') }
    $b = Get-D9ScanBattery $Ctx
    if (-not $b -or $null -eq $b.AcShare) { return New-D9Skip $Check (T-D9 'Історії використання батареї ще немає') }
    if (-not (Test-D9BatteryAlwaysPlugged $b -MinAcShare $Check.thresholds.acShare -MinWearPerYear $Check.thresholds.wearPerYear)) { return }
    $title = T-D9 'Батарея старіє швидко: ноутбук {0}% часу на зарядці' ([int]($b.AcShare * 100))
    $details = (T-D9 'Постійний заряд 100% — головна причина зносу батареї. Обмежте заряд до 80%:') + ' ' + (Get-D9ChargeLimitTip $Ctx.System.Manufacturer) + ' ' + (Format-D9BatteryDetails $b) + '.'
    New-D9Finding $Check suggestion $title $details @{ type = 'manual' }
}
