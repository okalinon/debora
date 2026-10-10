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
    # Захист мережі: «Authentication / Автентифікація» і «Cipher / Шифр» (назви полів локалізовані — шукаємо за значеннями)
    $auth = ($values.GetEnumerator() | Where-Object { $_.Key -match '^(Authentication|Автентифікація|Проверка подлинности|Authentifizierung)$' } | Select-Object -First 1).Value
    $cipher = ($values.GetEnumerator() | Where-Object { $_.Key -match '^(Cipher|Шифр|Шифрование|Verschlüsselung)$' } | Select-Object -First 1).Value
    $ssid = ($values.GetEnumerator() | Where-Object { $_.Key -eq 'SSID' } | Select-Object -First 1).Value
    if ($auth -match '^(Open|Відкрит|Открыт|Offen)' -or $auth -match 'WEP') {
        $wep = $auth -match 'WEP' -or $cipher -match 'WEP'
        $text = if ($wep) { 'Мережа захищена застарілим WEP, який зламується за хвилини.' } else { 'Мережа без пароля: усе, що передається не через HTTPS, можуть бачити сусіди й будь-хто поблизу.' }
        $text += ' Якщо це ваш роутер — увімкніть у його налаштуваннях WPA2 або WPA3 з паролем. У чужих відкритих мережах (кафе, вокзал) користуйтеся VPN.'
        New-D9Finding $Check warning "Wi-Fi «$ssid» $(if ($wep) { 'захищено застарілим WEP' } else { 'без пароля й шифрування' })" $text @{ type = 'manual' } @($link) -Key "$($Check.id):security"
        # У відкритій мережі ПК не має бути «видимим» для інших (профіль «Приватна»)
        $wlan = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.PhysicalMediaType -match '802\.11' -or $_.MediaType -match '802\.11|Native 802') } | Select-Object -First 1
        $netProfile = if ($wlan) { Get-NetConnectionProfile -InterfaceIndex $wlan.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($netProfile -and [string]$netProfile.NetworkCategory -eq 'Private') {
            New-D9Finding $Check warning "Відкрита Wi-Fi-мережа «$ssid» позначена як приватна" 'У приватній мережі ПК видно іншим пристроям, доступні спільні папки й принтери. Debora позначить мережу як загальнодоступну (відкат — у «Журналі змін»).' (New-D9ActionsFix @(@{ type = 'command'; run = "Set-NetConnectionProfile -InterfaceIndex $($wlan.ifIndex) -NetworkCategory Public"; undoRun = "Set-NetConnectionProfile -InterfaceIndex $($wlan.ifIndex) -NetworkCategory Private"; test = "[string](Get-NetConnectionProfile -InterfaceIndex $($wlan.ifIndex)).NetworkCategory -eq 'Public'"; label = @{ uk = "Позначити мережу «$ssid» як загальнодоступну"; en = 'Set network to Public' } })) @($link) -Key "$($Check.id):profile"
        }
    } elseif ($auth -match '^WPA-' -or $cipher -match 'TKIP') {
        New-D9Finding $Check suggestion "Wi-Fi «$ssid» захищено застарілим WPA/TKIP" 'Застарілий режим захисту ще й обмежує швидкість до 54 Мбіт/с. У налаштуваннях роутера оберіть WPA2-AES або WPA3.' @{ type = 'manual' } @($link) -Key "$($Check.id):security"
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
