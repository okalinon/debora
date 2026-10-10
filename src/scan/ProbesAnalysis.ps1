# Глибокий аналіз: не лише «є проблема», а що саме її спричиняє і що Debora зробить.
# Сині екрани (коди BugCheck → причина), збої програм (модуль, у якому падають), індекс стабільності,
# повільне завантаження (хто і скільки секунд забирає), мережа, служби з вразливими шляхами, пошуковий індекс, HDD, TPM.

# ======================= Сині екрани =======================

function Get-D9BugcheckCatalog {
    if (-not $script:D9BugcheckCatalog) { $script:D9BugcheckCatalog = ConvertFrom-Json (Get-D9ConfigText 'bugchecks.json') }
    $script:D9BugcheckCatalog
}

# «0x000000d1 (0x…, …)» → D1; 0xc000021a → C000021A
function ConvertTo-D9BugcheckKey {
    param([string]$Text)
    if ($Text -notmatch '0x([0-9a-fA-F]{1,16})') { return $null }
    $hex = $Matches[1].TrimStart('0').ToUpper()
    if (-not $hex) { return '0' }
    return $hex
}

# Опис коду: Key, Name, Class, Text (пояснення коду або групи), Fix
function Get-D9BugcheckInfo {
    param([string]$Key)
    $cat = Get-D9BugcheckCatalog
    $c = $cat.codes.$Key
    $class = if ($c) { $c.class } else { 'driver' }   # невідомі коди найчастіше теж від драйверів
    $cls = $cat.classes.$class
    [pscustomobject]@{
        Key = $Key; Name = if ($c) { $c.name } else { "0x$Key" }; Class = $class
        Text = (@($c.uk, $cls.uk) | Where-Object { $_ }) -join ' '
        Fix = $cls.fix
    }
}

# Перетворює групу причин на виправлення для чекліста
function ConvertTo-D9CrashFix {
    param([string]$Fix)
    switch ($Fix) {
        'driverUpdate' { return @{ type = 'maintenance'; action = 'driverUpdate' } }
        'chkdskScan'   { return @{ type = 'maintenance'; action = 'chkdskScan' } }
        'repairSystem' { return @{ type = 'maintenance'; action = 'repairSystem' } }
        'memoryTest'   { return @{ type = 'maintenance'; action = 'memoryTest' } }
        default        { return @{ type = 'manual' } }
    }
}

function Test-D9Crashes {
    param($Check, $Ctx)
    $days = $Check.thresholds.days
    $since = $Ctx.Now.AddDays(-$days)
    $bsod  = @(Get-D9EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since })
    $power = @(Get-D9EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since })
    $links = @((New-D9Link 'Перевірка пам''яті Windows' 'mdsched.exe'))
    if ($bsod.Count) {
        $infos = @($bsod | ForEach-Object { ConvertTo-D9BugcheckKey ([string]$_.Properties[0].Value) } | Where-Object { $_ } | ForEach-Object { Get-D9BugcheckInfo $_ })
        $byCode = @($infos | Group-Object Key | Sort-Object Count -Descending)
        $codes = ($byCode | ForEach-Object { "$($_.Group[0].Name) ×$($_.Count)" }) -join ', '
        $severity = if ($bsod.Count -ge $Check.thresholds.critical) { 'critical' } else { 'warning' }
        $title = "Сині екрани за $days днів: $($bsod.Count)$(if ($codes) { " ($codes)" })"
        $last = ($bsod | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        $classes = @($infos | Group-Object Class | Sort-Object Count -Descending)
        if ($byCode.Count -ge 3 -and $classes.Count -ge 2) {
            # Різні коди від різних підсистем — класична ознака нестабільної пам'яті чи розгону
            $details = "Коди різні ($($byCode.Count)), тож причина, найімовірніше, не в одному драйвері, а в залізі: оперативна пам'ять, розгін/XMP, живлення або перегрів. Debora запланує перевірку пам'яті під час перезавантаження."
            $fix = ConvertTo-D9CrashFix 'memoryTest'
        } elseif ($infos) {
            $main = $byCode[0].Group[0]
            $details = "$($main.Name): $($main.Text)"
            $fix = ConvertTo-D9CrashFix $main.Fix
        } else {
            $details = 'Можливі причини: драйвер (оновіть відео, чипсет, мережу), перегрів, оперативна пам''ять, блок живлення.'
            $fix = ConvertTo-D9CrashFix 'driverUpdate'
        }
        if ($last) { $details += " Останній — $($last.ToString('dd.MM.yyyy HH:mm'))." }
        $details += ' Точний драйвер-винуватець покаже програма WhoCrashed або BlueScreenView (вкладка «Програми» → «Діагностика заліза»).'
        return New-D9Finding $Check $severity $title $details $fix $links -Data @{ codes = @($byCode | ForEach-Object { @{ code = "0x$($_.Name)"; name = $_.Group[0].Name; count = $_.Count } }) }
    }
    if ($power.Count -ge 3) {
        New-D9Finding $Check warning "Аварійні вимкнення за $days днів: $($power.Count)" "Комп'ютер вимикався або перезавантажувався без завершення роботи, без синього екрана. Так буває при зависанні, проблемах із живленням (блок живлення, батарея, розетка) і перегріві. Якщо ви самі вимикали кнопкою — це теж рахується." @{ type = 'manual' } $links
    }
}

# ======================= Збої програм =======================

# Модуль, у якому падають програми → причина
$script:D9CrashModules = @(
    @{ Class = 'gpu';    Pattern = '^(nvwgf2um|nvd3dum|nvoglv|nvldumd|nvcuda|nvgpucomp|nvapi|atiumd|atiuxp|atidxx|amdxc|amdxx|aticfx|atio6axx|amdihk|igd10|igd12|igdumd|igdusc|ig\d+icd|igxelp|igc\d+|intelocl)' }
    @{ Class = 'vcrt';   Pattern = '^(msvcp\d+|vcruntime\d+|msvcr\d+|concrt\d+|vcomp\d+)' }
    @{ Class = 'dotnet'; Pattern = '^(clr|coreclr|clrjit|mscorwks|mscorlib)\.dll$' }
)

function Get-D9CrashModuleClass {
    param([string]$Module)
    foreach ($m in $script:D9CrashModules) { if ($Module -match $m.Pattern) { return $m.Class } }
    return $null
}

function Test-D9AppCrashes {
    param($Check, $Ctx)
    $events = Get-D9Events @{ LogName = 'Application'; ProviderName = @('Application Error', 'Application Hang'); Id = @(1000, 1002); StartTime = $Ctx.Now.AddDays(-$Check.thresholds.days) }
    if (-not $events) { return }
    $min = $Check.thresholds.min
    $apps = @($events | ForEach-Object { $_.Properties[0].Value } | Group-Object | Where-Object Count -ge $min | Sort-Object Count -Descending)
    $crashes = @($events | Where-Object Id -eq 1000 | ForEach-Object {
        [pscustomobject]@{ App = [string]$_.Properties[0].Value; Module = [string]$_.Properties[3].Value; Code = [string]$_.Properties[6].Value }
    })
    $byClass = @{}
    foreach ($c in $crashes) {
        $class = Get-D9CrashModuleClass $c.Module
        if (-not $class -and $c.Code -match 'e0434352') { $class = 'dotnet' }
        if ($class) { $byClass[$class] = @($byClass[$class]) + $c }
    }
    $names = { param($list) (@($list | Group-Object App | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object Name)) -join ', ' }
    if (@($byClass['gpu']).Count -ge $min) {
        $g = @($byClass['gpu'])
        New-D9Finding $Check warning "Програми падають у відеодрайвері: $($g.Count) разів ($(& $names $g))" "Збій стається в модулі драйвера відеокарти ($(@($g.Module | Sort-Object -Unique) -join ', ')). Debora знайде й встановить новіший драйвер. Якщо не допоможе — перевірте температуру відеокарти й зніміть розгін." @{ type = 'maintenance'; action = 'driverUpdate' } -Key "$($Check.id):gpu"
    }
    if (@($byClass['vcrt']).Count -ge $min) {
        $v = @($byClass['vcrt'])
        New-D9Finding $Check suggestion "Програми падають у бібліотеках Visual C++: $($v.Count) разів ($(& $names $v))" 'Пошкоджені або застарілі бібліотеки Visual C++ — часта причина вильотів ігор і програм. Debora перевстановить Visual C++ 2015–2022 (x64 і x86).' @{ type = 'maintenance'; action = 'vcRedist' } -Key "$($Check.id):vcrt"
    }
    if (@($byClass['dotnet']).Count -ge $min) {
        $d = @($byClass['dotnet'])
        New-D9Finding $Check info ".NET-програми завершуються з помилкою: $($d.Count) разів ($(& $names $d))" 'Помилка всередині самої програми на .NET. Оновіть або перевстановіть її; якщо програма просить певну версію .NET — встановіть її на вкладці «Програми» → «Системні компоненти».' -Key "$($Check.id):dotnet"
    }
    # Різні програми з порушенням доступу до пам'яті — ознака проблем з RAM або розгоном
    $av = @($crashes | Where-Object { $_.Code -match 'c0000005' -and -not (Get-D9CrashModuleClass $_.Module) } | Group-Object App)
    if ($av.Count -ge 5) {
        New-D9Finding $Check suggestion "$($av.Count) різних програм падають з порушенням доступу до пам'яті" 'Коли падає багато різних програм, причина часто в оперативній пам''яті або нестабільному розгоні (XMP/EXPO). Перевірте пам''ять: Debora запланує перевірку на наступне перезавантаження.' @{ type = 'maintenance'; action = 'memoryTest' } @((New-D9Link 'Перевірка пам''яті Windows' 'mdsched.exe')) -Key "$($Check.id):memory"
    }
    if ($apps) {
        $list = ($apps | Select-Object -First 6 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', '
        New-D9Finding $Check suggestion "Програми, що часто падають або зависають: $list" 'Оновіть або перевстановіть ці програми (вкладка «Програми» → «Оновити всі»). Якщо падають різні програми — причина може бути в пам''яті чи драйверах.' @{ type = 'manual' }
    }
}

# ======================= Індекс стабільності =======================

# Записи «Монітора стабільності системи» → зрозумілі групи
function Get-D9ReliabilitySummary {
    param([datetime]$Since)
    $dmtf = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($Since)
    $records = @(Get-CimInstance Win32_ReliabilityRecords -Filter "TimeGenerated >= '$dmtf'" -ErrorAction Stop)
    $groups = [ordered]@{ 'сині екрани' = 0; 'аварійні вимкнення' = 0; 'збої програм' = 0; 'невдалі оновлення' = 0; 'невдалі встановлення програм' = 0 }
    foreach ($r in $records) {
        switch ("$($r.SourceName)|$($r.EventIdentifier)") {
            'Microsoft-Windows-WER-SystemErrorReporting|1001' { $groups['сині екрани']++ }
            'EventLog|6008'                                  { $groups['аварійні вимкнення']++ }
            'Application Error|1000'                         { $groups['збої програм']++ }
            'Application Hang|1002'                          { $groups['збої програм']++ }
            'Microsoft-Windows-WindowsUpdateClient|20'       { $groups['невдалі оновлення']++ }
            'MsiInstaller|11708'                             { $groups['невдалі встановлення програм']++ }
        }
    }
    $groups
}

function Test-D9Reliability {
    param($Check, $Ctx)
    $m = try { Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Sort-Object TimeGenerated -Descending | Select-Object -First 1 } catch { $null }
    if (-not $m) { return New-D9Skip $Check 'Монітор стабільності вимкнено або ще не зібрав даних' }
    $index = [math]::Round([double]$m.SystemStabilityIndex, 1)
    $t = $Check.thresholds
    if ($index -ge $t.suggestion) { return }
    $summary = try { Get-D9ReliabilitySummary $Ctx.Now.AddDays(-$t.days) } catch { $null }
    $parts = if ($summary) { @($summary.Keys | Where-Object { $summary[$_] } | ForEach-Object { "$_ — $($summary[$_])" }) } else { @() }
    $details = 'Windows оцінює стабільність від 1 до 10 за збоями останніх тижнів.'
    if ($parts) { $details += " За $($t.days) днів: $($parts -join ', ')." }
    $details += ' Причини розібрано в інших пунктах цього звіту; подробиці по днях — «Монітор стабільності системи».'
    $severity = if ($index -lt $t.warning) { 'warning' } else { 'suggestion' }
    New-D9Finding $Check $severity "Індекс стабільності Windows: $index з 10" $details @{ type = 'manual' } @((New-D9Link 'Монітор стабільності' 'perfmon.exe'))
}

# ======================= Повільне завантаження =======================

function Get-D9EventData {
    param($Event)
    $h = @{}
    try { foreach ($d in ([xml]$Event.ToXml()).Event.EventData.Data) { $h[[string]$d.Name] = [string]$d.'#text' } } catch { }
    $h
}

# Хто сповільнює запуск: події 101–110 журналу Diagnostics-Performance → назва і середня затримка, с
function Get-D9BootCulprits {
    param([object[]]$Events)
    $rows = foreach ($e in $Events) {
        $d = Get-D9EventData $e
        $name = @($d.FriendlyName, $d.Name) | Where-Object { $_ } | Select-Object -First 1
        $ms = [double]$(if ($d.DegradationTime) { $d.DegradationTime } elseif ($d.TotalTime) { $d.TotalTime } else { 0 })
        if ($name -and $ms -gt 0) { [pscustomobject]@{ Name = $name; Ms = $ms; Kind = @{ 101 = 'програма'; 102 = 'драйвер'; 103 = 'служба'; 106 = 'фонове завдання'; 109 = 'пристрій' }[[int]$e.Id] } }
    }
    @($rows | Group-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Kind = $_.Group[0].Kind; Seconds = [math]::Round(($_.Group | Measure-Object Ms -Average).Average / 1000, 1); Count = $_.Count }
    } | Sort-Object Seconds -Descending)
}

function Test-D9BootTime {
    param($Check, $Ctx)
    $log = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    $events = Get-D9Events @{ LogName = $log; Id = 100 }
    if ($null -eq $events) { return New-D9Skip $Check 'журнал продуктивності недоступний (потрібні права адміністратора)' }
    $recent = @($events | Sort-Object TimeCreated -Descending | Select-Object -First 5)
    if (-not $recent) { return }
    $data = @($recent | ForEach-Object { Get-D9EventData $_ })
    $avg = { param($n) ($data | ForEach-Object { [double]$_[$n] } | Measure-Object -Average).Average / 1000 }
    $sec = & $avg 'BootTime'
    $main = & $avg 'MainPathBootTime'
    $post = & $avg 'BootPostBootTime'
    $limit = if ($Ctx.System.SystemDisk -eq 'hdd') { $Check.thresholds.hddSec } else { $Check.thresholds.ssdSec }
    if ($sec -le $limit) { return }
    $culprits = @(Get-D9BootCulprits @(Get-D9EventCount @{ LogName = $log; Id = @(101, 102, 103, 106, 109); StartTime = $Ctx.Now.AddDays(-30) }) | Where-Object Seconds -ge 1 | Select-Object -First 6)
    $details = "Норма для цього диска — до $limit с."
    if ($main -and $post) { $details += (" До появи робочого столу — {0:N0} с, ще {1:N0} с довантажується автозапуск." -f $main, $post) }
    if ($culprits) { $details += ' Найбільше сповільнюють: ' + (($culprits | ForEach-Object { "$($_.Name) ($($_.Kind), +$($_.Seconds) с)" }) -join ', ') + '.' }
    $fix = @{ type = 'manual' }
    if ($post -gt $main -and $post -gt 20) {
        $details += ' Основний час забирають програми автозапуску — вимкніть непотрібні на вкладці «Автозавантаження» (Debora позначить, які безпечно вимкнути).'
    } elseif ($Ctx.System.SystemDisk -eq 'hdd') {
        $details += ' Найбільше прискорить запуск заміна жорсткого диска на SSD.'
    } else {
        $details += ' Оновіть драйвери з цього списку й вимкніть зайве в автозавантаженні.'
        if (@($culprits | Where-Object Kind -in 'драйвер', 'пристрій')) { $fix = @{ type = 'maintenance'; action = 'driverUpdate' } }
    }
    New-D9Finding $Check warning ("Windows завантажується в середньому {0:N0} с" -f $sec) $details $fix -Data @{ culprits = @($culprits) }
}

# ======================= Мережа =======================

function Test-D9NetworkHealth {
    param($Check, $Ctx)
    $up = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    if (-not $up) { return New-D9Skip $Check 'Немає підключених мережевих адаптерів' }
    # Адаптер підключено, але адреса 169.254.x.x — роутер не видав адресу (DHCP)
    $apipa = @(foreach ($a in $up) {
        $ip = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        if ($ip -and -not ($ip | Where-Object { $_.IPAddress -notlike '169.254.*' })) { $a.Name }
    })
    if ($apipa) {
        New-D9Finding $Check warning "Мережа без адреси від роутера: $($apipa -join ', ')" 'Адаптер підключено, але роутер не видав IP-адресу (169.254.x.x) — інтернету не буде. Перезавантажте роутер; якщо не допоможе — Debora скине мережеві налаштування Windows.' @{ type = 'maintenance'; action = 'networkReset' } -Key "$($Check.id):apipa"
    }
    # Є мережа, але немає інтернету (за даними самої Windows, без запитів у мережу)
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -in $up.ifIndex })
    if ($profiles -and -not ($profiles | Where-Object { [string]$_.IPv4Connectivity -eq 'Internet' -or [string]$_.IPv6Connectivity -eq 'Internet' }) -and -not $apipa) {
        New-D9Finding $Check warning 'Мережа підключена, але Windows не бачить інтернету' 'Перевірте, чи працює інтернет на інших пристроях. Якщо там працює — причина в цьому ПК (DNS, проксі, VPN, мережевий стек): Debora скине мережеві налаштування.' @{ type = 'maintenance'; action = 'networkReset' } -Key "$($Check.id):internet"
    }
    # Помилки пакетів на кабелі — поганий кабель, роз'єм або драйвер
    foreach ($a in $up) {
        $s = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        $total = [double]$s.ReceivedUnicastPackets + [double]$s.ReceivedMulticastPackets + [double]$s.ReceivedBroadcastPackets
        $errors = [double]$s.ReceivedPacketErrors + [double]$s.OutboundPacketErrors
        if ($total -gt 10000 -and $errors / $total -gt $Check.thresholds.errorRate) {
            $hint = if ($a.MediaType -match '802\.3' -or $a.PhysicalMediaType -match '802\.3') { 'Замініть мережевий кабель або спробуйте інший порт роутера.' } else { 'Підійдіть ближче до роутера або змініть канал Wi-Fi.' }
            New-D9Finding $Check suggestion ("Помилки передачі на «{0}»: {1:N2}% пакетів" -f $a.Name, ($errors * 100 / $total)) "Частина даних передається з помилками — звідси обриви й низька швидкість. $hint Також оновіть драйвер мережевого адаптера." @{ type = 'maintenance'; action = 'driverUpdate' } -Key "$($Check.id):errors:$($a.Name)"
        }
    }
}

# ======================= Безпека =======================

# Шлях служби з пробілами без лапок: C:\Program Files\App\svc.exe → Windows спершу спробує C:\Program.exe
function Get-D9UnquotedServicePath {
    param([string]$ImagePath)
    if (-not $ImagePath -or $ImagePath.StartsWith('"')) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($ImagePath)
    if ($expanded -match '^(?i)(\\SystemRoot\\|system32\\|\\\?\?\\)') { return $null }
    if ($ImagePath -notmatch '^(?i)(.+?\.exe)(\s.*)?$') { return $null }
    $exe = $Matches[1]; $rest = $Matches[2]
    if ($exe -notmatch '\s') { return $null }
    if ([Environment]::ExpandEnvironmentVariables($exe) -like "$env:SystemRoot\*") { return $null }
    return "`"$exe`"$rest"
}

function Test-D9UnquotedServicePaths {
    param($Check, $Ctx)
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    $bad = @(foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $p = (Get-ItemProperty -LiteralPath $k.PSPath -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
        $fixed = Get-D9UnquotedServicePath $p
        if ($fixed) {
            $kind = try { [string]$k.GetValueKind('ImagePath') } catch { 'ExpandString' }
            [pscustomobject]@{ Name = $k.PSChildName; Path = "$root\$($k.PSChildName)"; Fixed = $fixed; Kind = $kind }
        }
    })
    if (-not $bad) { return }
    $actions = @($bad | ForEach-Object { @{ type = 'registry'; path = $_.Path; name = 'ImagePath'; value = $_.Fixed; kind = $_.Kind } })
    New-D9Finding $Check warning "Служби з незахищеним шляхом: $(($bad.Name) -join ', ')" 'Шлях до програми служби містить пробіли й не взятий у лапки — шкідлива програма може підкласти файл (наприклад, C:\Program.exe) і отримати права системи. Debora візьме шляхи в лапки (служби працюватимуть як раніше; відкат — у «Журналі змін»).' (New-D9ActionsFix $actions)
}

function Test-D9Tpm {
    param($Check, $Ctx)
    if (-not $Ctx.IsAdmin) { return New-D9Skip $Check 'потрібні права адміністратора' }
    $tpm = try { Get-Tpm -ErrorAction Stop } catch { $null }
    if (-not $tpm) { return New-D9Skip $Check 'Не вдалося прочитати стан TPM' }
    $version = try { [string](Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop).SpecVersion } catch { '' }
    $is20 = $version -match '^2\.0'
    $bios = 'Увімкніть його в BIOS/UEFI: Intel PTT або AMD fTPM (розділ Security / Advanced). Дані на диску не зачіпаються.'
    if (-not $tpm.TpmPresent) {
        $text = if ($Ctx.System.OsFamily -eq 'win10') { "Без TPM 2.0 Windows 11 не встановиться штатно, а BitLocker і Windows Hello працюють гірше. Майже всі процесори з 2017 року мають вбудований TPM — він просто вимкнений. $bios" } else { "Windows Hello, BitLocker і частина захисту працюють без апаратної підтримки. $bios" }
        return New-D9Finding $Check suggestion 'Модуль безпеки TPM вимкнено або відсутній' $text @{ type = 'manual' }
    }
    if ($version -and -not $is20) {
        New-D9Finding $Check info "Версія TPM: $(($version -split ',')[0])" 'Windows 11 потребує TPM 2.0. Іноді в BIOS можна перемкнути TPM на версію 2.0 або увімкнути вбудований у процесор (PTT / fTPM).' -Key "$($Check.id):version"
    }
    if ($tpm.TpmPresent -and -not $tpm.TpmReady) {
        New-D9Finding $Check info 'TPM не готовий до роботи' 'Відкрийте «Безпека Windows» → «Безпека пристрою» → «Процесор безпеки» → «Усунення несправностей», або виконайте очищення TPM у BIOS (лише якщо не використовуєте BitLocker).' @{ type = 'manual' } @((New-D9Link 'Безпека пристрою' 'windowsdefender://devicesecurity')) -Key "$($Check.id):ready"
    }
}

# ======================= Швидкодія =======================

function Test-D9SearchIndex {
    param($Check, $Ctx)
    $dir = Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows'
    $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.edb', '.db' })
    if (-not $files) { return }
    $size = [long](($files | Measure-Object Length -Sum).Sum)
    if ($size -lt $Check.thresholds.sizeGB * 1GB) { return }
    New-D9Finding $Check suggestion "Пошуковий індекс Windows займає $(Format-D9Size $size)" 'Індекс розрісся (часто через пошту Outlook або папки з тисячами дрібних файлів) і сповільнює пошук і диск. Debora перебудує його з нуля: місце звільниться, пошук відновиться за кілька годин.' @{ type = 'maintenance'; action = 'searchReset' }
}

function Test-D9HddFragmentation {
    param($Check, $Ctx)
    if ($Ctx.System.SystemDisk -ne 'hdd') { return }
    if (-not $Ctx.IsAdmin) { return New-D9Skip $Check 'потрібні права адміністратора' }
    $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter = '$env:SystemDrive'" -ErrorAction SilentlyContinue
    if (-not $vol) { return }
    $r = try { Invoke-CimMethod -InputObject $vol -MethodName DefragAnalysis -ErrorAction Stop } catch { $null }
    $percent = [int]$r.DefragAnalysis.FilePercentFragmentation
    if ($percent -ge $Check.thresholds.percent) {
        New-D9Finding $Check suggestion "Жорсткий диск фрагментовано на $percent%" 'Файли розкидано по диску частинами — HDD читає їх повільніше. Debora дефрагментує диск (до години; комп''ютером можна користуватися).' @{ type = 'maintenance'; action = 'defragHdd' }
    }
}

# ======================= Мережеві папки й інші диски =======================

function Test-D9NetworkShares {
    param($Check, $Ctx)
    # Type 0 — звичайна папка; адміністративні C$, ADMIN$, IPC$ не рахуємо
    $shares = @(Get-CimInstance Win32_Share -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 0 -and $_.Name -notlike '*$' })
    if (-not $shares) { return }
    $list = ($shares | ForEach-Object { "$($_.Name) ($($_.Path))" }) -join ', '
    $public = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { [string]$_.NetworkCategory -eq 'Public' })
    $severity = if ($public) { 'warning' } else { 'info' }
    $why = if ($public) { ' Зараз ПК підключено до загальнодоступної мережі — переконайтеся, що доступ до папок мають лише потрібні люди (з паролем).' } else { '' }
    New-D9Finding $Check $severity "Папки, відкриті для мережі: $list" "Їх можуть відкрити інші пристрої в мережі.$why Якщо доступ уже не потрібен — припиніть спільний доступ (властивості папки → «Доступ»)." @{ type = 'manual' } @((New-D9Link 'Спільні папки' 'fsmgmt.msc'))
}

function Test-D9OtherDrivesSpace {
    param($Check, $Ctx)
    $t = $Check.thresholds
    $full = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue | Where-Object {
        $_.DeviceID -ne $env:SystemDrive -and $_.Size -gt $t.minSizeGB * 1GB -and $_.FreeSpace * 100 / $_.Size -lt $t.percent
    })
    if (-not $full) { return }
    $list = ($full | ForEach-Object { "{0} — вільно {1} з {2}" -f $_.DeviceID, (Format-D9Size $_.FreeSpace), (Format-D9Size $_.Size) }) -join '; '
    New-D9Finding $Check suggestion "Майже заповнені диски: $list" 'На заповненому диску не вистачає місця для нових файлів, а NTFS працює повільніше. Знайти, що займає місце, допоможуть WinDirStat чи WizTree (вкладка «Програми» → «Утиліти»).' @{ type = 'manual' }
}

# ======================= Записи від видалених програм =======================

function Test-D9OrphanEntries {
    param($Check, $Ctx)
    $items = @(Get-D9OrphanRegistryEntries)
    if (-not $items) { return }
    $names = ($items | Select-Object -First 8 | ForEach-Object { $_.Name }) -join ', '
    New-D9Finding $Check suggestion "Записів від уже видалених програм: $($items.Count)" "Програм і їхніх файлів на диску вже немає, а записи лишились у «Програмах і засобах» чи реєстрі: $names. Debora прибере їх (кожен — з резервною копією .reg)." @{ type = 'maintenance'; action = 'orphanEntries' }
}
