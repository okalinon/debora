# Проби мережі: швидкість з'єднання, Wi-Fi, DNS.

function Test-D9LinkSpeed {
    param($Check, $Ctx)
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' })
    foreach ($a in $adapters) {
        $mbps = [math]::Round($a.ReceiveLinkSpeed / 1MB)
        $gigabit = $a.InterfaceDescription -match 'Gigabit|GbE|2\.5G|5G|10G|Killer|I2[12]\d|RTL81(11|25|68)|E[23]\d\d0'
        if ($gigabit -and $a.ReceiveLinkSpeed -le 100000000) {
            New-D9Finding $Check warning "Кабельне з'єднання працює на $mbps Мбіт/с замість 1000" "Адаптер «$($a.InterfaceDescription)» гігабітний, але узгодив лише 100 Мбіт/с. Найчастіше винен кабель (пошкоджений або 4-жильний), роз'єм чи порт роутера." @{ type = 'manual' } -Key "$($Check.id):$($a.Name)"
        }
    }
}

function Test-D9Wifi {
    param($Check, $Ctx)
    if (-not (Get-Service WlanSvc -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running')) { return }
    $iface = (netsh wlan show interfaces) -join "`n"
    if ($iface -notmatch '802\.11') { return }   # не під'єднано
    $values = @{}
    foreach ($line in ($iface -split "`n")) {
        if ($line -match '^\s*([^:]+?)\s*:\s*(.+?)\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
    $channel = [int]($values.GetEnumerator() | Where-Object { $_.Key -match '^(Channel|Канал|Kanal)$' } | Select-Object -First 1).Value
    $signal  = [int](($values.GetEnumerator() | Where-Object { $_.Value -match '^\d+%$' } | Select-Object -First 1).Value -replace '%')
    $radio   = ($values.GetEnumerator() | Where-Object { $_.Value -match '^802\.11' } | Select-Object -First 1).Value
    $drivers = (netsh wlan show drivers) -join ' '
    $supports5 = $drivers -match '802\.11(a|ac|ax|be)\b'
    $link = New-D9Link 'Wi-Fi' 'ms-settings:network-wifi'
    if ($channel -ge 1 -and $channel -le 14 -and $supports5) {
        New-D9Finding $Check suggestion "Wi-Fi підключено на 2,4 ГГц (канал $channel), хоча адаптер підтримує 5 ГГц" 'Якщо роутер має мережу 5 ГГц, підключіться до неї: швидкість у кілька разів вища, менше перешкод від сусідів. На 2,4 ГГц краще лише далеко від роутера.' @{ type = 'manual' } @($link) -Key "$($Check.id):band"
    }
    if ($signal -and $signal -lt $Check.thresholds.signalPercent) {
        New-D9Finding $Check suggestion "Слабкий сигнал Wi-Fi: $signal% ($radio)" 'Звідси нестабільна швидкість і обриви. Перемістіть роутер ближче / вище, приберіть перешкоди, або використайте ретранслятор чи кабель.' @{ type = 'manual' } @($link) -Key "$($Check.id):signal"
    }
}

function Test-D9DnsLatency {
    param($Check, $Ctx)
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { return New-D9Skip $Check 'Resolve-DnsName недоступний' }
    $times = foreach ($name in 'www.microsoft.com', 'www.google.com', 'www.wikipedia.org') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { Resolve-DnsName $name -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Out-Null; $sw.ElapsedMilliseconds } catch { }
    }
    $times = @($times)
    if (-not $times) { return New-D9Skip $Check 'немає інтернету або DNS не відповідає' }
    $avg = ($times | Measure-Object -Average).Average
    if ($avg -ge $Check.thresholds.ms) {
        $servers = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object ServerAddresses | Select-Object -First 1).ServerAddresses -join ', '
        New-D9Finding $Check suggestion ("DNS відповідає повільно: {0:N0} мс у середньому" -f $avg) "Кожен новий сайт відкривається із затримкою. Поточні DNS: $servers. Спробуйте 1.1.1.1 (Cloudflare), 8.8.8.8 (Google) або 9.9.9.9 (Quad9) у властивостях мережі." @{ type = 'manual' } @((New-D9Link 'Параметри мережі' 'ms-settings:network-status'))
    }
}
