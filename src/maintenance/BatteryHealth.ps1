# Стан батареї ноутбука з powercfg /batteryreport (працює без прав адміністратора):
# ємність зараз і нової, історія ємності (з останньої заміни батареї), швидкість зносу й прогноз,
# частка часу від мережі (постійні 100% заряду старять батарею) і час роботи від батареї.

# Тривалість ISO 8601 (PT1H39M18S, P3DT18H…) → TimeSpan; порожнє або неправильне → $null
function ConvertFrom-D9IsoDuration {
    param([string]$Text)
    if (-not $Text) { return $null }
    try { [Xml.XmlConvert]::ToTimeSpan($Text) } catch { $null }
}

# Розбір XML звіту. $Now — для тестів.
function ConvertFrom-D9BatteryReport {
    param([Parameter(Mandatory)][xml]$Xml, [datetime]$Now = (Get-Date))
    $r = $Xml.BatteryReport
    $b = @($r.Batteries.Battery) | Select-Object -First 1
    if (-not $b -or -not [double]$b.DesignCapacity) { return $null }
    $design = [double]$b.DesignCapacity; $full = [double]$b.FullChargeCapacity

    # Історія ємності — лише з моменту останньої заміни батареї. Прапорцю BatteryChanged вірити не можна
    # (на частині ноутбуків він стоїть щотижня), тож заміну видно з даних: інша паспортна ємність
    # або стрибок фактичної ємності вгору більш ніж на 10% паспортної
    $entries = @($r.History.HistoryEntry | Where-Object { $_ -and $_.LocalStartDate -and [double]$_.DesignCapacity -gt 0 -and [double]$_.FullChargeCapacity -gt 0 })
    $lastChange = 0
    for ($i = 1; $i -lt $entries.Count; $i++) {
        $prev = $entries[$i - 1]; $cur = $entries[$i]
        if ([double]$cur.DesignCapacity -ne [double]$prev.DesignCapacity -or ([double]$cur.FullChargeCapacity - [double]$prev.FullChargeCapacity) / [double]$cur.DesignCapacity -gt 0.10) { $lastChange = $i }
    }
    if ($lastChange -gt 0) { $entries = @($entries | Select-Object -Skip $lastChange) }
    $history = @($entries | Where-Object { [double]$_.DesignCapacity -gt 0 -and [double]$_.FullChargeCapacity -gt 0 } | ForEach-Object {
        [pscustomobject]@{ Date = [datetime]$_.LocalStartDate; Health = [math]::Round([double]$_.FullChargeCapacity * 100 / [double]$_.DesignCapacity, 1) }
    })

    # Швидкість зносу, % на рік: середнє перших і останніх вимірів (по ~10%, щонайменше 2). Ємність
    # «гуляє» від калібрування, а найбільше падіння часто на початку — пряма МНК його недооцінює вдвічі.
    # Потрібно ≥ 60 днів історії
    $wear = $null; $forecast = $null
    if ($history.Count -ge 4 -and ($history[-1].Date - $history[0].Date).TotalDays -ge 60) {
        $n = [math]::Max(2, [int][math]::Floor($history.Count / 10))
        $first = @($history | Select-Object -First $n); $last = @($history | Select-Object -Last $n)
        $years = (($last[-1].Date.Ticks + $last[0].Date.Ticks) / 2 - ($first[-1].Date.Ticks + $first[0].Date.Ticks) / 2) / [TimeSpan]::TicksPerDay / 365.25
        if ($years -gt 0.1) { $wear = [math]::Round((($first.Health | Measure-Object -Average).Average - ($last.Health | Measure-Object -Average).Average) / $years, 1) }
    }
    $health = [math]::Round($full * 100 / $design)
    if ($wear -gt 0.5 -and $health -gt 60) { $forecast = $Now.AddDays(($health - 60) / $wear * 365.25) }

    # Частка часу від мережі за останні 90 днів (активна робота + сучасний режим очікування)
    $ac = [TimeSpan]::Zero; $dc = [TimeSpan]::Zero
    foreach ($e in @($entries | Where-Object { [datetime]$_.LocalStartDate -ge $Now.AddDays(-90) })) {
        foreach ($n in 'ActiveAcTime', 'CsAcTime') { $v = ConvertFrom-D9IsoDuration $e.$n; if ($v) { $ac += $v } }
        foreach ($n in 'ActiveDcTime', 'CsDcTime') { $v = ConvertFrom-D9IsoDuration $e.$n; if ($v) { $dc += $v } }
    }
    $acShare = if (($ac + $dc).TotalHours -ge 24) { [math]::Round($ac.TotalHours / ($ac + $dc).TotalHours, 2) } else { $null }

    $est = $r.RuntimeEstimates
    [pscustomobject]@{
        Design        = $design
        Full          = $full
        Health        = $health
        Cycles        = $(if ([int]$b.CycleCount -gt 0) { [int]$b.CycleCount } else { $null })
        Chemistry     = [string]$b.Chemistry
        History       = $history
        WearPerYear   = $wear
        Forecast60    = $forecast
        AcShare       = $acShare
        RuntimeNow    = ConvertFrom-D9IsoDuration $est.FullChargeCapacity.ActiveRuntime
        RuntimeDesign = ConvertFrom-D9IsoDuration $est.DesignCapacity.ActiveRuntime
    }
}

# Звіт для цього ПК; $null — батареї немає або Windows не віддає даних
function Get-D9BatteryHealth {
    $xml = Join-Path ([IO.Path]::GetTempPath()) ("d9battery-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.xml')
    try {
        & powercfg.exe /batteryreport /xml /output $xml 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $xml)) { return $null }
        ConvertFrom-D9BatteryReport ([xml](Get-Content -LiteralPath $xml -Raw -Encoding UTF8))
    } catch { $null }
    finally { if (Test-Path -LiteralPath $xml) { [IO.File]::Delete($xml) } }
}

# Де ввімкнути обмеження заряду на ноутбуці цього виробника (config/battery-charge-limit.json)
# Платформа ноутбука (ODM) за ID пристроїв: бренди на кшталт Dream Machines чи XMG продають і Clevo, і Uniwill,
# а утиліти й налаштування заряду в них різні. $null — не визначено.
function Get-D9LaptopPlatform {
    param([string[]]$DeviceIds)
    if (-not $script:D9ChargeLimit) { $script:D9ChargeLimit = ConvertFrom-Json (Get-D9ConfigText 'battery-charge-limit.json') }
    if ($null -eq $DeviceIds) {
        # Запит до WMI займає кілька секунд, а залізо за сеанс не змінюється
        if ($script:D9LaptopPlatformCache) { return $script:D9LaptopPlatformCache.Value }
        $script:D9LaptopPlatformCache = @{ Value = (Get-D9LaptopPlatform -DeviceIds @(try { Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE 'ACPI\\%'" -ErrorAction Stop | ForEach-Object { $_.PNPDeviceID } } catch { })) }
        return $script:D9LaptopPlatformCache.Value
    }
    foreach ($p in @($script:D9ChargeLimit.platforms)) {
        if (@($DeviceIds | Where-Object { $_ -match $p.pnp }).Count) { return $p }
    }
    $null
}

function Get-D9ChargeLimitTip {
    param([string]$Manufacturer, [string[]]$DeviceIds)
    if (-not $script:D9ChargeLimit) { $script:D9ChargeLimit = ConvertFrom-Json (Get-D9ConfigText 'battery-charge-limit.json') }
    $platform = if ($PSBoundParameters.ContainsKey('DeviceIds')) { Get-D9LaptopPlatform $DeviceIds } else { Get-D9LaptopPlatform }
    if ($platform) { return (Get-D9Text $platform.tip) }
    $rule = @($script:D9ChargeLimit.rules) | Where-Object { $Manufacturer -match $_.match } | Select-Object -First 1
    Get-D9Text $(if ($rule) { $rule.tip } else { $script:D9ChargeLimit.default })
}

# Рівень: ok (≥ 80%) | fair | warn | bad
function Get-D9BatteryLevel {
    param([Parameter(Mandatory)]$Battery, [int]$WarningPercent = 60, [int]$CriticalPercent = 40)
    if ($Battery.Health -lt $CriticalPercent) { 'bad' } elseif ($Battery.Health -lt $WarningPercent) { 'warn' } elseif ($Battery.Health -lt 80) { 'fair' } else { 'ok' }
}

# Батарея старіє швидко, бо майже весь час на зарядці (100%)
function Test-D9BatteryAlwaysPlugged {
    param([Parameter(Mandatory)]$Battery, [double]$MinAcShare = 0.85, [double]$MinWearPerYear = 5)
    [bool]($Battery.AcShare -ge $MinAcShare -and ($Battery.WearPerYear -ge $MinWearPerYear -or $Battery.Health -lt 85))
}

function Format-D9Duration {
    param($Span)
    if (-not $Span) { return $null }
    if ($Span.TotalHours -ge 1) { T-D9 '{0} год {1} хв' ([int][math]::Floor($Span.TotalHours)) $Span.Minutes } else { T-D9 '{0} хв' ([int]$Span.TotalMinutes) }
}

# Округлена тривалість для оцінки «минулого разу ≈ …»: до 10 хв — з точністю до хвилини, до години — до 5 хв,
# далі — до 10 хв (63 хв → «60 хв», 95 хв → «1 год 40 хв»)
function Format-D9ApproxDuration {
    param([Parameter(Mandatory)][TimeSpan]$Span)
    $m = $Span.TotalMinutes
    if ($m -lt 1) { return (T-D9 'менше хвилини') }
    $r = if ($m -lt 10) { [math]::Round($m) } elseif ($m -lt 60) { [math]::Round($m / 5) * 5 } else { [math]::Round($m / 10) * 10 }
    if ($r -le 60) { return (T-D9 '{0} хв' ([int]$r)) }
    $h = [math]::Floor($r / 60); $rest = $r % 60
    if ($rest) { T-D9 '{0} год {1} хв' ([int]$h) ([int]$rest) } else { T-D9 '{0} год' ([int]$h) }
}

# «Ємність 34,2 з 46,7 Вт·год (73%); знос ≈ 10% на рік; …»
function Format-D9BatteryDetails {
    param([Parameter(Mandatory)]$Battery)
    $p = @(T-D9 'ємність {0} з {1} Вт·год ({2}%)' ([math]::Round($Battery.Full / 1000, 1)) ([math]::Round($Battery.Design / 1000, 1)) $Battery.Health)
    if ($Battery.History.Count -ge 2) { $p += T-D9 'було {0}% у {1}' $Battery.History[0].Health $Battery.History[0].Date.ToString('MM.yyyy') }
    if ($null -ne $Battery.WearPerYear) { $p += T-D9 'знос ≈ {0}% на рік' $Battery.WearPerYear }
    if ($Battery.Forecast60) { $p += T-D9 '60% — орієнтовно {0}' $Battery.Forecast60.ToString('MM.yyyy') }
    if ($Battery.Cycles) { $p += T-D9 'циклів заряду: {0}' $Battery.Cycles }
    if ($null -ne $Battery.AcShare) { $p += T-D9 'від мережі {0}% часу' ([int]($Battery.AcShare * 100)) }
    if ($Battery.RuntimeNow) {
        $p += (T-D9 'від батареї ≈ {0}' (Format-D9Duration $Battery.RuntimeNow)) + $(if ($Battery.RuntimeDesign) { ' ' + (T-D9 '(нова — {0})' (Format-D9Duration $Battery.RuntimeDesign)) })
    }
    $s = $p -join '; '
    $s.Substring(0, 1).ToUpper() + $s.Substring(1)
}

# Нижня межа шкали для лінії історії: на 10% нижче мінімуму, кратно 10 (щоб падіння 95 → 73% було видно)
function Get-D9SparkMin {
    param([object[]]$Points)
    $min = (@($Points) | Measure-Object Health -Minimum).Minimum
    [math]::Max(0, [math]::Floor(($min - 10) / 10) * 10)
}

# Поради: заміна при сильному зносі, обмеження заряду при постійній роботі від мережі
function Get-D9BatteryAdvice {
    param([Parameter(Mandatory)]$Battery, [string]$Manufacturer)
    $a = @()
    $level = Get-D9BatteryLevel $Battery
    if ($level -in 'warn', 'bad') { $a += T-D9 'Батарею варто замінити в сервісі: час роботи від неї помітно скоротився.' }
    if (Test-D9BatteryAlwaysPlugged $Battery) {
        $a += (T-D9 'Ноутбук майже весь час на зарядці, і батарея тримається на 100% — це головна причина швидкого зносу. Обмежте заряд до 80%:') + ' ' + (Get-D9ChargeLimitTip $Manufacturer)
    }
    $a
}

$script:D9BatteryLevelText = @{ ok = 'Добрий стан'; fair = 'Помірний знос'; warn = 'Зношена'; bad = 'Потребує заміни' }

function Get-D9BatteryLevelText {
    param([string]$Level)
    $t = $script:D9BatteryLevelText[$Level]
    if ($t) { T-D9 $t } else { $Level }
}

# Лінія історії ємності для вікна: геометрія Path у прямокутнику $Width × $Height (вісь Y — від $Min до 100%)
function Get-D9SparkGeometry {
    param([object[]]$Points, [double]$Width, [double]$Height, [double]$Min = 40)
    if (@($Points).Count -lt 2) { return $null }
    $t0 = $Points[0].Date.Ticks; $span = [double]($Points[-1].Date.Ticks - $t0); if ($span -le 0) { $span = 1 }
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $coords = foreach ($p in $Points) {
        $x = ($p.Date.Ticks - $t0) / $span * $Width
        $y = $Height - ([math]::Max($Min, [math]::Min(100, $p.Health)) - $Min) / (100 - $Min) * $Height
        '{0},{1}' -f $x.ToString('0.#', $ci), $y.ToString('0.#', $ci)
    }
    [Windows.Media.Geometry]::Parse('M ' + ($coords -join ' L '))
}

# Текстовий звіт (CLI і діагностика)
function Format-D9BatteryReport {
    param($Battery = (Get-D9BatteryHealth), [string]$Manufacturer)
    if (-not $Battery) { return (T-D9 'Батареї немає або Windows не віддає її даних.') }
    $level = Get-D9BatteryLevel $Battery
    "[$(Get-D9BatteryLevelText $level)] " + (Format-D9BatteryDetails $Battery)
    foreach ($a in @(Get-D9BatteryAdvice $Battery $Manufacturer)) { "    $a" }
    if ($Battery.History.Count -ge 2) {
        '    ' + (T-D9 'Історія ємності:') + ' ' + ((@($Battery.History | Group-Object { $_.Date.ToString('yyyy-MM') } | ForEach-Object { "$($_.Name) $([math]::Round(($_.Group.Health | Measure-Object -Average).Average))%" })) -join ', ')
    }
}
