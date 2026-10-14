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
        Text = (@((Get-D9Text $c), (Get-D9Text $cls)) | Where-Object { $_ }) -join ' '
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
    $since = Get-D9EventSince $Check $Ctx $days
    $bsod  = @(Get-D9EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since })
    $power = @(Get-D9EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since })
    $links = @((New-D9Link (T-D9 'Перевірка пам''яті Windows') 'mdsched.exe'))
    if ($bsod.Count) {
        $infos = @($bsod | ForEach-Object { ConvertTo-D9BugcheckKey ([string]$_.Properties[0].Value) } | Where-Object { $_ } | ForEach-Object { Get-D9BugcheckInfo $_ })
        $byCode = @($infos | Group-Object Key | Sort-Object Count -Descending)
        $codes = ($byCode | ForEach-Object { "$($_.Group[0].Name) ×$($_.Count)" }) -join ', '
        $severity = if ($bsod.Count -ge $Check.thresholds.critical) { 'critical' } else { 'warning' }
        $title = if ($codes) { T-D9 'Сині екрани за {0} днів: {1} ({2})' $days $bsod.Count $codes } else { T-D9 'Сині екрани за {0} днів: {1}' $days $bsod.Count }
        $last = ($bsod | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        $classes = @($infos | Group-Object Class | Sort-Object Count -Descending)
        if ($byCode.Count -ge 3 -and $classes.Count -ge 2) {
            # Різні коди від різних підсистем — класична ознака нестабільної пам'яті чи розгону
            $details = T-D9 'Коди різні ({0}), тож причина, найімовірніше, не в одному драйвері, а в залізі: оперативна пам''ять, розгін/XMP, живлення або перегрів. Debora запланує перевірку пам''яті під час перезавантаження.' $byCode.Count
            $fix = ConvertTo-D9CrashFix 'memoryTest'
        } elseif ($infos) {
            $main = $byCode[0].Group[0]
            $details = "$($main.Name): $($main.Text)"
            $fix = ConvertTo-D9CrashFix $main.Fix
        } else {
            $details = T-D9 'Можливі причини: драйвер (оновіть відео, чипсет, мережу), перегрів, оперативна пам''ять, блок живлення.'
            $fix = ConvertTo-D9CrashFix 'driverUpdate'
        }
        if ($last) { $details += ' ' + (T-D9 'Останній — {0}.' $last.ToString('dd.MM.yyyy HH:mm')) }
        $details += ' ' + (T-D9 'Точний драйвер-винуватець покаже програма WhoCrashed або BlueScreenView (вкладка «Програми» → «Діагностика заліза»).')
        return New-D9Finding $Check $severity $title $details $fix $links -Data @{ codes = @($byCode | ForEach-Object { @{ code = "0x$($_.Name)"; name = $_.Group[0].Name; count = $_.Count } }) }
    }
    if ($power.Count -ge 3) {
        New-D9Finding $Check warning (T-D9 'Аварійні вимкнення за {0} днів: {1}' $days $power.Count) (T-D9 'Комп''ютер вимикався або перезавантажувався без завершення роботи, без синього екрана. Так буває при зависанні, проблемах із живленням (блок живлення, батарея, розетка) і перегріві. Якщо ви самі вимикали кнопкою — це теж рахується.') @{ type = 'manual' } $links
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
    $events = Get-D9Events @{ LogName = 'Application'; ProviderName = @('Application Error', 'Application Hang'); Id = @(1000, 1002); StartTime = (Get-D9EventSince $Check $Ctx $Check.thresholds.days) }
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
        New-D9Finding $Check warning (T-D9 'Програми падають у відеодрайвері: {0} разів ({1})' $g.Count (& $names $g)) (T-D9 'Збій стається в модулі драйвера відеокарти ({0}). Debora знайде й встановить новіший драйвер. Якщо не допоможе — перевірте температуру відеокарти й зніміть розгін.' (@($g.Module | Sort-Object -Unique) -join ', ')) @{ type = 'maintenance'; action = 'driverUpdate' } -Key "$($Check.id):gpu"
    }
    if (@($byClass['vcrt']).Count -ge $min) {
        $v = @($byClass['vcrt'])
        New-D9Finding $Check suggestion (T-D9 'Програми падають у бібліотеках Visual C++: {0} разів ({1})' $v.Count (& $names $v)) (T-D9 'Пошкоджені або застарілі бібліотеки Visual C++ — часта причина вильотів ігор і програм. Debora перевстановить Visual C++ 2015–2022 (x64 і x86).') @{ type = 'maintenance'; action = 'vcRedist' } -Key "$($Check.id):vcrt"
    }
    if (@($byClass['dotnet']).Count -ge $min) {
        $d = @($byClass['dotnet'])
        New-D9Finding $Check info (T-D9 '.NET-програми завершуються з помилкою: {0} разів ({1})' $d.Count (& $names $d)) (T-D9 'Помилка всередині самої програми на .NET. Оновіть або перевстановіть її; якщо програма просить певну версію .NET — встановіть її на вкладці «Програми» → «Системні компоненти».') -Key "$($Check.id):dotnet"
    }
    # Різні програми з порушенням доступу до пам'яті — ознака проблем з RAM або розгоном
    $av = @($crashes | Where-Object { $_.Code -match 'c0000005' -and -not (Get-D9CrashModuleClass $_.Module) } | Group-Object App)
    if ($av.Count -ge 5) {
        New-D9Finding $Check suggestion (T-D9 '{0} різних програм падають з порушенням доступу до пам''яті' $av.Count) (T-D9 'Коли падає багато різних програм, причина часто в оперативній пам''яті або нестабільному розгоні (XMP/EXPO). Перевірте пам''ять: Debora запланує перевірку на наступне перезавантаження.') @{ type = 'maintenance'; action = 'memoryTest' } @((New-D9Link (T-D9 'Перевірка пам''яті Windows') 'mdsched.exe')) -Key "$($Check.id):memory"
    }
    if ($apps) {
        $list = ($apps | Select-Object -First 6 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', '
        New-D9Finding $Check suggestion (T-D9 'Програми, що часто падають або зависають: {0}' $list) (T-D9 'Оновіть або перевстановіть ці програми (вкладка «Програми» → «Оновити всі»). Якщо падають різні програми — причина може бути в пам''яті чи драйверах.') @{ type = 'manual' }
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
    if (-not $m) { return New-D9Skip $Check (T-D9 'Монітор стабільності вимкнено або ще не зібрав даних') }
    $index = [math]::Round([double]$m.SystemStabilityIndex, 1)
    $t = $Check.thresholds
    if ($index -ge $t.suggestion) { return }
    $summary = try { Get-D9ReliabilitySummary $Ctx.Now.AddDays(-$t.days) } catch { $null }
    # Ключі зведення — українські назви груп; перекладаються лише під час показу
    $parts = if ($summary) { @($summary.Keys | Where-Object { $summary[$_] } | ForEach-Object { "$(T-D9 $_) — $($summary[$_])" }) } else { @() }
    $details = T-D9 'Windows оцінює стабільність від 1 до 10 за збоями останніх тижнів.'
    if ($parts) { $details += ' ' + (T-D9 'За {0} днів: {1}.' $t.days ($parts -join ', ')) }
    $details += ' ' + (T-D9 'Причини розібрано в інших пунктах цього звіту; подробиці по днях — «Монітор стабільності системи».')
    $severity = if ($index -lt $t.warning) { 'warning' } else { 'suggestion' }
    New-D9Finding $Check $severity (T-D9 'Індекс стабільності Windows: {0} з 10' "$index") $details @{ type = 'manual' } @((New-D9Link (T-D9 'Монітор стабільності') 'perfmon.exe'))
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
    if ($null -eq $events) { return New-D9Skip $Check (T-D9 'журнал продуктивності недоступний (потрібні права адміністратора)') }
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
    $details = T-D9 'Норма для цього диска — до {0} с.' "$limit"
    if ($main -and $post) { $details += ' ' + (T-D9 'До появи робочого столу — {0:N0} с, ще {1:N0} с довантажується автозапуск.' $main $post) }
    # Kind — українська мітка з даних (за нею перевіряється логіка нижче); перекладається лише під час показу
    if ($culprits) { $details += ' ' + (T-D9 'Найбільше сповільнюють: {0}.' (($culprits | ForEach-Object { T-D9 '{0} ({1}, +{2} с)' $_.Name (T-D9 $_.Kind) "$($_.Seconds)" }) -join ', ')) }
    $fix = @{ type = 'manual' }
    if ($post -gt $main -and $post -gt 20) {
        $details += ' ' + (T-D9 'Основний час забирають програми автозапуску — вимкніть непотрібні на вкладці «Автозавантаження» (Debora позначить, які безпечно вимкнути).')
    } elseif ($Ctx.System.SystemDisk -eq 'hdd') {
        $details += ' ' + (T-D9 'Найбільше прискорить запуск заміна жорсткого диска на SSD.')
    } else {
        $details += ' ' + (T-D9 'Оновіть драйвери з цього списку й вимкніть зайве в автозавантаженні.')
        if (@($culprits | Where-Object Kind -in 'драйвер', 'пристрій')) { $fix = @{ type = 'maintenance'; action = 'driverUpdate' } }
    }
    New-D9Finding $Check warning (T-D9 'Windows завантажується в середньому {0:N0} с' $sec) $details $fix -Data @{ culprits = @($culprits) }
}

# ======================= Мережа =======================

function Test-D9NetworkHealth {
    param($Check, $Ctx)
    $up = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    if (-not $up) { return New-D9Skip $Check (T-D9 'Немає підключених мережевих адаптерів') }
    # Адаптер підключено, але адреса 169.254.x.x — роутер не видав адресу (DHCP)
    $apipa = @(foreach ($a in $up) {
        $ip = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        if ($ip -and -not ($ip | Where-Object { $_.IPAddress -notlike '169.254.*' })) { $a.Name }
    })
    if ($apipa) {
        New-D9Finding $Check warning (T-D9 'Мережа без адреси від роутера: {0}' ($apipa -join ', ')) (T-D9 'Адаптер підключено, але роутер не видав IP-адресу (169.254.x.x) — інтернету не буде. Перезавантажте роутер; якщо не допоможе — Debora скине мережеві налаштування Windows.') @{ type = 'maintenance'; action = 'networkReset' } -Key "$($Check.id):apipa"
    }
    # Є мережа, але немає інтернету (за даними самої Windows, без запитів у мережу)
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -in $up.ifIndex })
    if ($profiles -and -not ($profiles | Where-Object { [string]$_.IPv4Connectivity -eq 'Internet' -or [string]$_.IPv6Connectivity -eq 'Internet' }) -and -not $apipa) {
        New-D9Finding $Check warning (T-D9 'Мережа підключена, але Windows не бачить інтернету') (T-D9 'Перевірте, чи працює інтернет на інших пристроях. Якщо там працює — причина в цьому ПК (DNS, проксі, VPN, мережевий стек): Debora скине мережеві налаштування.') @{ type = 'maintenance'; action = 'networkReset' } -Key "$($Check.id):internet"
    }
    # Помилки пакетів на кабелі — поганий кабель, роз'єм або драйвер
    foreach ($a in $up) {
        $s = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        $total = [double]$s.ReceivedUnicastPackets + [double]$s.ReceivedMulticastPackets + [double]$s.ReceivedBroadcastPackets
        $errors = [double]$s.ReceivedPacketErrors + [double]$s.OutboundPacketErrors
        if ($total -gt 10000 -and $errors / $total -gt $Check.thresholds.errorRate) {
            $hint = if ($a.MediaType -match '802\.3' -or $a.PhysicalMediaType -match '802\.3') { T-D9 'Замініть мережевий кабель або спробуйте інший порт роутера.' } else { T-D9 'Підійдіть ближче до роутера або змініть канал Wi-Fi.' }
            New-D9Finding $Check suggestion (T-D9 'Помилки передачі на «{0}»: {1:N2}% пакетів' $a.Name ($errors * 100 / $total)) (T-D9 'Частина даних передається з помилками — звідси обриви й низька швидкість. {0} Також оновіть драйвер мережевого адаптера.' $hint) @{ type = 'maintenance'; action = 'driverUpdate' } -Key "$($Check.id):errors:$($a.Name)"
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
    New-D9Finding $Check warning (T-D9 'Служби з незахищеним шляхом: {0}' (($bad.Name) -join ', ')) (T-D9 'Шлях до програми служби містить пробіли й не взятий у лапки — шкідлива програма може підкласти файл (наприклад, C:\Program.exe) і отримати права системи. Debora візьме шляхи в лапки (служби працюватимуть як раніше; відкат — у «Журналі змін»).') (New-D9ActionsFix $actions)
}

function Test-D9Tpm {
    param($Check, $Ctx)
    if (-not $Ctx.IsAdmin) { return New-D9Skip $Check (T-D9 'потрібні права адміністратора') }
    $tpm = try { Get-Tpm -ErrorAction Stop } catch { $null }
    if (-not $tpm) { return New-D9Skip $Check (T-D9 'Не вдалося прочитати стан TPM') }
    $version = try { [string](Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop).SpecVersion } catch { '' }
    $is20 = $version -match '^2\.0'
    $bios = T-D9 'Увімкніть його в BIOS/UEFI: Intel PTT або AMD fTPM (розділ Security / Advanced). Дані на диску не зачіпаються.'
    if (-not $tpm.TpmPresent) {
        $text = if ($Ctx.System.OsFamily -eq 'win10') { T-D9 'Без TPM 2.0 Windows 11 не встановиться штатно, а BitLocker і Windows Hello працюють гірше. Майже всі процесори з 2017 року мають вбудований TPM — він просто вимкнений. {0}' $bios } else { T-D9 'Windows Hello, BitLocker і частина захисту працюють без апаратної підтримки. {0}' $bios }
        return New-D9Finding $Check suggestion (T-D9 'Модуль безпеки TPM вимкнено або відсутній') $text @{ type = 'manual' }
    }
    if ($version -and -not $is20) {
        New-D9Finding $Check info (T-D9 'Версія TPM: {0}' (($version -split ',')[0])) (T-D9 'Windows 11 потребує TPM 2.0. Іноді в BIOS можна перемкнути TPM на версію 2.0 або увімкнути вбудований у процесор (PTT / fTPM).') -Key "$($Check.id):version"
    }
    if ($tpm.TpmPresent -and -not $tpm.TpmReady) {
        New-D9Finding $Check info (T-D9 'TPM не готовий до роботи') (T-D9 'Відкрийте «Безпека Windows» → «Безпека пристрою» → «Процесор безпеки» → «Усунення несправностей», або виконайте очищення TPM у BIOS (лише якщо не використовуєте BitLocker).') @{ type = 'manual' } @((New-D9Link (T-D9 'Безпека пристрою') 'windowsdefender://devicesecurity')) -Key "$($Check.id):ready"
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
    New-D9Finding $Check suggestion (T-D9 'Пошуковий індекс Windows займає {0}' (Format-D9Size $size)) (T-D9 'Індекс розрісся (часто через пошту Outlook або папки з тисячами дрібних файлів) і сповільнює пошук і диск. Debora перебудує його з нуля: місце звільниться, пошук відновиться за кілька годин.') @{ type = 'maintenance'; action = 'searchReset' }
}

function Test-D9HddFragmentation {
    param($Check, $Ctx)
    if ($Ctx.System.SystemDisk -ne 'hdd') { return }
    if (-not $Ctx.IsAdmin) { return New-D9Skip $Check (T-D9 'потрібні права адміністратора') }
    $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter = '$env:SystemDrive'" -ErrorAction SilentlyContinue
    if (-not $vol) { return }
    $r = try { Invoke-CimMethod -InputObject $vol -MethodName DefragAnalysis -ErrorAction Stop } catch { $null }
    $percent = [int]$r.DefragAnalysis.FilePercentFragmentation
    if ($percent -ge $Check.thresholds.percent) {
        New-D9Finding $Check suggestion (T-D9 'Жорсткий диск фрагментовано на {0}%' $percent) (T-D9 'Файли розкидано по диску частинами — HDD читає їх повільніше. Debora дефрагментує диск (до години; комп''ютером можна користуватися).') @{ type = 'maintenance'; action = 'defragHdd' }
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
    $text = if ($public) { T-D9 'Їх можуть відкрити інші пристрої в мережі. Зараз ПК підключено до загальнодоступної мережі — переконайтеся, що доступ до папок мають лише потрібні люди (з паролем). Якщо доступ уже не потрібен — припиніть спільний доступ (властивості папки → «Доступ»).' } else { T-D9 'Їх можуть відкрити інші пристрої в мережі. Якщо доступ уже не потрібен — припиніть спільний доступ (властивості папки → «Доступ»).' }
    New-D9Finding $Check $severity (T-D9 'Папки, відкриті для мережі: {0}' $list) $text @{ type = 'manual' } @((New-D9Link (T-D9 'Спільні папки') 'fsmgmt.msc'))
}

function Test-D9OtherDrivesSpace {
    param($Check, $Ctx)
    $t = $Check.thresholds
    $full = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue | Where-Object {
        $_.DeviceID -ne $env:SystemDrive -and $_.Size -gt $t.minSizeGB * 1GB -and $_.FreeSpace * 100 / $_.Size -lt $t.percent
    })
    if (-not $full) { return }
    $list = ($full | ForEach-Object { T-D9 '{0} — вільно {1} з {2}' $_.DeviceID (Format-D9Size $_.FreeSpace) (Format-D9Size $_.Size) }) -join '; '
    New-D9Finding $Check suggestion (T-D9 'Майже заповнені диски: {0}' $list) (T-D9 'На заповненому диску не вистачає місця для нових файлів, а NTFS працює повільніше. Знайти, що займає місце, допоможуть WinDirStat чи WizTree (вкладка «Програми» → «Утиліти»).') @{ type = 'manual' }
}

# ======================= Зміни, які скасувала Windows =======================

# Після оновлень Windows повертає Copilot, рекламу, застосунки, політики: порівнюємо журнал Debora з поточним станом
function Test-D9GuardReverted {
    param($Check, $Ctx)
    $items = @(Find-D9GuardDrift -Catalog $Ctx.Catalog)
    try { Save-D9GuardStatus -SystemInfo $Ctx.System -Drift $items.Count } catch { }
    if (-not $items) { return }
    $names = ($items | Select-Object -First 8 | ForEach-Object { $_.Text }) -join '; '
    New-D9Finding $Check warning (T-D9 'Windows скасувала ваші зміни: {0}' $items.Count) (T-D9 'Ці зміни ви застосували через Debora, а Windows (зазвичай після оновлення) або сама програма повернула їх назад: {0}. Debora поверне їх (окремою сесією в «Журналі змін»).' $names) @{ type = 'maintenance'; action = 'guardRestore' }
}

# ======================= Записи від видалених програм =======================

function Test-D9OrphanEntries {
    param($Check, $Ctx)
    $items = @(Get-D9OrphanRegistryEntries)
    if (-not $items) { return }
    $names = ($items | Select-Object -First 8 | ForEach-Object { $_.Name }) -join ', '
    New-D9Finding $Check suggestion (T-D9 'Записів від уже видалених програм: {0}' $items.Count) (T-D9 'Програм і їхніх файлів на диску вже немає, а записи лишились у «Програмах і засобах» чи реєстрі: {0}. Debora прибере їх (кожен — з резервною копією .reg).' $names) @{ type = 'maintenance'; action = 'orphanEntries' }
}
