# Онлайн-оновлення драйверів: пошук новіших драйверів для пристроїв цього ПК у Microsoft Update Catalog
# (офіційний каталог Microsoft, підписані пакети від виробників) і рекомендацій Windows Update Agent,
# завантаження з перевіркою SHA-256, розпаковування — далі звичайний конвеєр Find-D9DriverPackages
# (точний збіг INF з пристроєм) → New-D9DriverCatalog → рушій (експорт попереднього драйвера, журнал, відкат).

$script:D9CatalogBase = 'https://www.catalog.update.microsoft.com'

# Класи пристроїв, для яких шукаємо оновлення (плюс будь-який пристрій із помилкою)
$script:D9UpdateClasses = @('Display', 'Net', 'Media', 'Bluetooth', 'System', 'HIDClass', 'Camera', 'Image', 'SCSIAdapter', 'HDC', 'Biometric', 'SDHost', 'USB', 'Sensor', 'SoftwareComponent', 'Extension')

function Initialize-D9Web {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not ('System.Net.Http.HttpClient' -as [type])) { Add-Type -AssemblyName System.Net.Http }
    if (-not $script:D9Http) {
        $script:D9Http = New-Object System.Net.Http.HttpClient
        $script:D9Http.Timeout = [TimeSpan]::FromSeconds(60)
        $script:D9Http.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) Debora')
    }
    return $script:D9Http
}

# ---------- Microsoft Update Catalog ----------

# Рядки таблиці результатів: Id (ID оновлення в каталозі), Title, Products, Classification, Date, Version, Size
function ConvertFrom-D9CatalogHtml {
    param([string]$Html)
    foreach ($m in [regex]::Matches($Html, '(?s)<tr id="([0-9a-f-]{36})_R\d+".*?</tr>')) {
        $cells = @([regex]::Matches($m.Value, '(?s)<td[^>]*>(.*?)</td>') | ForEach-Object {
            [Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim())
        })
        if ($cells.Count -lt 7) { continue }
        $date = try { [datetime]::ParseExact($cells[4], 'M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture) } catch { $null }
        $bytes = if ($cells[6] -match '(\d{4,})\s*$') { [long]$Matches[1] } else { 0 }
        $version = $cells[5]
        if (-not (ConvertTo-D9Version $version) -and $cells[1] -match '(\d+(\.\d+){2,})\)?\s*$') { $version = $Matches[1] }   # «n/a» — версія в назві
        [pscustomobject]@{ Id = $m.Groups[1].Value; Title = $cells[1]; Products = $cells[2]; Classification = $cells[3]; Date = $date; Version = $version; Size = $bytes }
    }
}

# Пошуки пакетами по $Parallel одночасно (каталог обмежує частоту), з одним повтором: @{ запит = рядки }
function Search-D9DriverCatalog {
    param([Parameter(Mandatory)][string[]]$Queries, [int]$Parallel = 6)
    $http = Initialize-D9Web
    [Net.ServicePointManager]::DefaultConnectionLimit = [math]::Max([Net.ServicePointManager]::DefaultConnectionLimit, $Parallel)
    $all = @($Queries | Where-Object { $_ } | Select-Object -Unique)
    $result = @{}
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $left = @($all | Where-Object { -not $result.ContainsKey($_) })
        for ($i = 0; $i -lt $left.Count; $i += $Parallel) {
            $batch = @($left[$i..([math]::Min($i + $Parallel, $left.Count) - 1)])
            $tasks = [ordered]@{}
            foreach ($q in $batch) { $tasks[$q] = $http.GetStringAsync("$script:D9CatalogBase/Search.aspx?q=$([uri]::EscapeDataString($q))") }
            foreach ($q in $tasks.Keys) {
                try { $result[$q] = @(ConvertFrom-D9CatalogHtml $tasks[$q].GetAwaiter().GetResult()) }
                catch {
                    $err = $_.Exception; while ($err.InnerException) { $err = $err.InnerException }
                    if ($attempt -eq 2) { Write-D9Log ('  ' + (T-D9 'Каталог не відповів на «{0}»: {1}' $q $err.Message)) Detail; $result[$q] = @() }
                }
            }
            if ($script:D9OnProgress) { & $script:D9OnProgress ([math]::Min($i + $Parallel, $left.Count)) $left.Count 'Microsoft Update Catalog' }
        }
        if ($attempt -eq 1 -and @($all | Where-Object { -not $result.ContainsKey($_) })) { Start-Sleep -Seconds 2 }
    }
    return $result
}

# Пряме посилання на файл і SHA-256 (base64) за ID оновлення каталогу
function Get-D9CatalogDownload {
    param([Parameter(Mandatory)][string]$UpdateId)
    $http = Initialize-D9Web
    $json = "[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$UpdateId`",`"updateID`":`"$UpdateId`"}]"
    $form = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $form.Add('updateIDs', $json)
    $content = New-Object System.Net.Http.FormUrlEncodedContent ($form)
    $html = $http.PostAsync("$script:D9CatalogBase/DownloadDialog.aspx", $content).GetAwaiter().GetResult().Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $url = [regex]::Match($html, "files\[0\]\.url\s*=\s*'([^']+)'").Groups[1].Value
    if (-not $url) { return $null }
    [pscustomobject]@{
        Url    = $url
        Sha256 = [regex]::Match($html, "files\[0\]\.sha256\s*=\s*'([^']+)'").Groups[1].Value
        Name   = [regex]::Match($html, "files\[0\]\.fileName\s*=\s*'([^']+)'").Groups[1].Value
    }
}

# Чи підходить запис каталогу цій Windows: Windows 11 бере і «Windows 10 … and later» драйвери, Windows 10 — лише свої
$script:D9Win11Releases = @{ '21H2' = 22000; '22H2' = 22621; '23H2' = 22631; '24H2' = 26100; '25H2' = 26200 }
function Test-D9CatalogRowFits {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$SystemInfo)
    if ($Row.Classification -notmatch 'Driver') { return $false }
    if ("$($Row.Title) $($Row.Products)" -match '(?i)arm64|\barm\b') { return $false }
    if (-not [Environment]::Is64BitOperatingSystem -and $Row.Title -match '(?i)x64') { return $false }
    $p = $Row.Products
    if ($SystemInfo.OsFamily -eq 'win11') {
        if ($p -match 'Windows 11') {
            # «version 24H2 and later» — лише якщо наша збірка не старша; без версії — будь-яка Windows 11
            $versions = @([regex]::Matches($p, 'version (\d{2}H\d) and later') | ForEach-Object { $_.Groups[1].Value })
            if (-not $versions) { return $true }
            foreach ($v in $versions) {
                $need = $script:D9Win11Releases[$v]
                if ($need -and [int]$SystemInfo.Build -ge $need) { return $true }
            }
        }
    }
    return $p -match 'Windows 10'
}

# ---------- Пристрої й порівняння версій ----------

# Найточніший «конкретний» ID для пошуку і запасний коротший (VEN&DEV без SUBSYS/REV)
function Get-D9DeviceQueries {
    param([string[]]$HardwareIds)
    $specific = @($HardwareIds | Where-Object { $_ -and (Test-D9SpecificId $_) })
    if (-not $specific) { return @() }
    $first = $specific[0] -replace '&REV_[0-9A-F]+$', ''
    $short = if ($first -match '^(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})') { $Matches[1] }
             elseif ($first -match '^(USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4})') { $Matches[1] }
             elseif ($first -match '^(HDAUDIO\\FUNC_\d+&VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})') { $Matches[1] }
             else { $null }
    @($first, $short | Where-Object { $_ } | Select-Object -Unique)
}

# Пристрої, для яких шукаємо оновлення, з поточним драйвером
function Get-D9UpdatableDevices {
    $signed = @{}
    foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)) { if ($d.DeviceID) { $signed[$d.DeviceID.ToUpper()] = $d } }
    foreach ($e in @(Get-D9PnpEntities | Where-Object { $_.Present -ne $false -and $_.HardwareID })) {
        $problem = [int]$e.ConfigManagerErrorCode -notin 0, 22, 45
        if (-not $problem -and [string]$e.PNPClass -notin $script:D9UpdateClasses) { continue }
        $queries = @(Get-D9DeviceQueries @($e.HardwareID))
        # Для пристрою без драйвера шукаємо ще й за конкретними сумісними ID (часто так знаходиться драйвер сімейства)
        if ($problem) { $queries = @($queries + @(Get-D9DeviceQueries @($e.CompatibleID)) | Select-Object -Unique) }
        if (-not $queries) { continue }
        $sd = $signed[[string]$e.PNPDeviceID.ToUpper()]
        $date = $null; if ($sd.DriverDate) { $date = [datetime]$sd.DriverDate }
        [pscustomobject]@{
            InstanceId = $e.PNPDeviceID; Name = $e.Name; Class = [string]$e.PNPClass; Problem = $problem
            HardwareIds = @($e.HardwareID); CompatibleIds = @($e.CompatibleID | Where-Object { $_ -and (Test-D9SpecificId $_) }); Queries = $queries
            Version = [string]$sd.DriverVersion; Date = $date; Provider = [string]$sd.DriverProviderName
        }
    }
}

# Класи, де загальний драйвер Microsoft варто замінити драйвером виробника (функції, швидкодія, енергоспоживання)
$script:D9VendorDriverClasses = @('Display', 'Net', 'Media', 'Bluetooth', 'Camera', 'Image', 'Biometric')

# Чи новіший запис каталогу за встановлений драйвер. Версії різних постачальників незрівнянні, тому
# порівнюємо версії лише за однакового першого числа, інакше — за датою.
function Test-D9DriverNewer {
    param([string]$NewVersion, $NewDate, [string]$OldVersion, $OldDate)
    if (-not $OldVersion) { return $true }
    # Вбудовані драйвери Windows мають умовну дату 21.06.2006 — за датою їх не порівнюємо
    if ($OldDate -and ([datetime]$OldDate).Year -lt 2010) { $OldDate = $null }
    $nv = ConvertTo-D9Version $NewVersion; $ov = ConvertTo-D9Version $OldVersion
    if ($nv -and $ov -and $nv.Major -eq $ov.Major) { return $nv -gt $ov }
    if ($NewDate -and $OldDate) { return ([datetime]$NewDate).Date -gt ([datetime]$OldDate).Date.AddDays(1) }
    return $false
}

# ---------- Пошук оновлень ----------

# Рекомендовані Windows Update драйвери для цього ПК (Windows сама зіставила їх із пристроями). Повертає
# Title, Version, Date, HardwareId. Помилки (немає служби, мережі) — порожньо.
function Get-D9WuaDriverUpdates {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'Debora'
        $r = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver'")
        foreach ($u in $r.Updates) {
            [pscustomobject]@{ Title = $u.Title; Version = $(if ($u.Title -match '\(([\d.]+)\)\s*$') { $Matches[1] }); Date = $u.DriverVerDate; HardwareId = [string]$u.DriverHardwareID }
        }
    } catch { Write-D9Log ('  ' + (T-D9 'Windows Update недоступний для пошуку драйверів: {0}' $_.Exception.Message)) Detail }
}

# Головний пошук: для кожного пристрою — найновіший підходящий запис каталогу, якщо він новіший за встановлений.
# Повертає кандидатів: Device, Row (запис каталогу), Status (missing|newer), Alternatives (наступні за якістю записи).
function Find-D9DriverUpdates {
    param([Parameter(Mandatory)]$SystemInfo, [switch]$IncludeWindowsUpdate)
    Write-D9Log (T-D9 'Пошук новіших драйверів у Microsoft Update Catalog...')
    $devices = @(Get-D9UpdatableDevices)
    Write-D9Log ('  ' + (T-D9 'Пристроїв для перевірки: {0}' "$($devices.Count)")) Detail
    $wua = if ($IncludeWindowsUpdate) { Write-D9Log ('  ' + (T-D9 'Запит до Windows Update (до хвилини)...')) Detail; @(Get-D9WuaDriverUpdates) } else { @() }
    $queries = @($devices | ForEach-Object { $_.Queries } | Sort-Object -Unique) + @($wua | ForEach-Object { $_.Title })
    $found = Search-D9DriverCatalog -Queries $queries
    foreach ($d in $devices) {
        $rows = @($d.Queries | ForEach-Object { $found[$_] } | Where-Object { $_ })
        # Рекомендація WUA для цього пристрою — шукаємо її запис у каталогі за назвою
        $hint = $wua | Where-Object { $h = $_.HardwareId; $h -and @($d.HardwareIds | Where-Object { $_ -like "$h*" }).Count } | Select-Object -First 1
        if ($hint) { $rows += @($found[$hint.Title] | Where-Object { $_ }) }
        $fit = @($rows | Where-Object { Test-D9CatalogRowFits $_ $SystemInfo } | Sort-Object Id -Unique |
            Sort-Object @{ Expression = { ConvertTo-D9Version $_.Version }; Descending = $true }, @{ Expression = { $_.Date }; Descending = $true })
        $newer = @($fit | Where-Object { $d.Problem -or (Test-D9DriverNewer $_.Version $_.Date $d.Version $d.Date) })
        if (-not $newer) { continue }
        # Пошук за назвою з WUA дає десяток однойменних пакетів для різних моделей пристрою — пробуємо кілька,
        # а запасним — найновіший пакет, знайдений за ID самого пристрою (він точно містить цей пристрій)
        $direct = @($d.Queries | ForEach-Object { $found[$_] } | Where-Object { $_ } | ForEach-Object Id)
        $alts = @($newer | Select-Object -Skip 1 -First 5)
        $sure = $newer | Where-Object { $direct -contains $_.Id } | Select-Object -First 1
        if ($sure -and $sure.Id -ne $newer[0].Id -and -not ($alts | Where-Object Id -eq $sure.Id)) { $alts += $sure }
        # Заміна робочого вбудованого драйвера Microsoft на системних пристроях — лише за бажанням
        $optional = -not $d.Problem -and -not $hint -and $d.Provider -eq 'Microsoft' -and $d.Class -notin $script:D9VendorDriverClasses
        [pscustomobject]@{
            Device = $d; Row = $newer[0]; Alternatives = $alts
            Status = $(if ($d.Problem) { 'missing' } else { 'newer' }); Recommended = [bool]$hint; Optional = $optional
        }
    }
}

# ---------- Завантаження ----------

function Save-D9CatalogFile {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$Folder)
    $dl = Get-D9CatalogDownload $Row.Id
    if (-not $dl) { throw (T-D9 'Каталог не дав посилання для {0}' $Row.Title) }
    # Однойменні пакети для різних моделей не мають змішуватись — до назви додаємо початок ID запису
    $safe = ($Row.Title -replace '[\\/:*?"<>|]', '_').Trim()
    $dir = Join-Path $Folder "$safe $(([string]$Row.Id).Substring(0, [Math]::Min(8, ([string]$Row.Id).Length)))".Trim()
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir $dl.Name
    if (-not (Test-Path -LiteralPath $file)) {
        $http = Initialize-D9Web
        $resp = $http.GetAsync($dl.Url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        [void]$resp.EnsureSuccessStatusCode()
        # Великі пакети (відеодрайвери ~1 ГБ) на повільному зв'язку йдуть хвилинами — показуємо хід кожні 100 МБ
        $total = $resp.Content.Headers.ContentLength
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $out = [IO.File]::Create($file)
        try {
            $buf = New-Object byte[] 1MB; $done = 0L; $next = 100MB
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $done += $n
                if ($done -ge $next) {
                    $next += 100MB
                    Write-D9Log ('  ' + $(if ($total) { T-D9 'Завантажено {0} з {1}' (Format-D9Size $done) (Format-D9Size $total) } else { T-D9 'Завантажено {0}' (Format-D9Size $done) })) Detail
                }
            }
        } catch { $out.Dispose(); [IO.File]::Delete($file); throw } finally { $out.Dispose(); $in.Dispose() }
    }
    if ($dl.Sha256) {
        $want = ([BitConverter]::ToString([Convert]::FromBase64String($dl.Sha256)) -replace '-', '')
        $have = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($want -ne $have) { [IO.File]::Delete($file); throw (T-D9 'Контрольна сума не збігається для {0} — файл видалено' $Row.Title) }
    }
    # .cab розпаковуємо поруч (expand.exe є в кожній Windows)
    if ($file -like '*.cab') {
        $x = Join-Path $dir 'files'
        New-Item -ItemType Directory -Path $x -Force | Out-Null
        $o = & expand.exe -F:* $file $x 2>&1
        if ($LASTEXITCODE -ne 0) { throw (T-D9 'Не вдалося розпакувати {0}: {1}' $dl.Name "$o") }
    }
    return [string]$dir
}

# Завантажує кандидатів у папку й повертає пакети, готові до встановлення (уже перевірені на збіг INF з пристроями).
# Якщо найкращий запис не підійшов за INF (пакет для іншої модифікації пристрою), пробує наступні.
function Save-D9DriverUpdates {
    param([Parameter(Mandatory)][object[]]$Candidates, [Parameter(Mandatory)][string]$Folder)
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $n = 0
    foreach ($c in $Candidates) {
        $n++
        if ($script:D9OnProgress) { & $script:D9OnProgress $n $Candidates.Count $c.Device.Name }
        foreach ($row in @($c.Row) + @($c.Alternatives)) {
            Write-D9Log "[$n/$($Candidates.Count)] $($c.Device.Name): $($row.Title) ($(Format-D9Size $row.Size))"
            try { $dir = [string](@(Save-D9CatalogFile $row $Folder) | Select-Object -Last 1) } catch { Write-D9Log "  $($_.Exception.Message)" Warn; continue }
            $infOk = @(Get-ChildItem -LiteralPath $dir -Filter '*.inf' -Recurse | Where-Object { -not $_.PSIsContainer } | ForEach-Object { Get-D9InfInfo $_.FullName } |
                Where-Object { $_.Ids | Where-Object { (Test-D9SpecificId $_) -and (@($c.Device.HardwareIds) + @($c.Device.CompatibleIds)) -contains $_ } })
            if ($infOk) { Write-D9Log ('  ' + (T-D9 'Завантажено, пакет підходить до пристрою.')) Ok; break }
            Write-D9Log ('  ' + (T-D9 'Пакет не містить драйвера саме для цього пристрою — пробую інший варіант.')) Detail
        }
    }
    Find-D9DriverPackages -Folder $Folder
}

# Повний цикл: знайти → завантажити → встановити (з точкою відновлення, журналом і відкатом).
# Повертає @{ Candidates; Packages; Session }.
function Invoke-D9DriverAutoUpdate {
    param([Parameter(Mandatory)]$SystemInfo, [Parameter(Mandatory)][string]$Folder, [switch]$WhatIf, [switch]$NoRestorePoint, [switch]$IncludeOptional, [switch]$UseOemTool)
    # Спершу утиліта виробника (Dell / Lenovo / HP): вона знає свої моделі найкраще, решту доповнить каталог Microsoft
    $oem = if ($UseOemTool -and -not $WhatIf) { Invoke-D9OemDriverTool -SystemInfo $SystemInfo } else { $null }
    if ($oem) { Clear-D9PnpCache }
    $all = @(Find-D9DriverUpdates -SystemInfo $SystemInfo -IncludeWindowsUpdate)
    $cands = @($all | Where-Object { $IncludeOptional -or -not $_.Optional })
    if ($all.Count -gt $cands.Count) { Write-D9Log ('  ' + (T-D9 'Необов''язкових (заміна робочих драйверів Windows на системних пристроях): {0} — пропущено; їх можна вибрати у вікні.' ($all.Count - $cands.Count))) Detail }
    if (-not $cands) { Write-D9Log (T-D9 'Новіших драйверів у каталозі Microsoft не знайдено — встановлені актуальні.') Ok; return [pscustomobject]@{ Candidates = @(); Packages = @(); Session = $null; RebootRecommended = [bool]$oem.RebootRecommended } }
    foreach ($c in $cands) { Write-D9Log ("  {0}: {1} → {2} ({3:dd.MM.yyyy})" -f $c.Device.Name, $(if ($c.Device.Version) { $c.Device.Version } else { T-D9 'немає драйвера' }), $c.Row.Version, $c.Row.Date) }
    if ($WhatIf) { return [pscustomobject]@{ Candidates = $cands; Packages = @(); Session = $null; RebootRecommended = $false } }
    $found = Save-D9DriverUpdates -Candidates $cands -Folder $Folder
    $todo = @($found.Packages | Where-Object Status -ne 'current')
    if (-not $todo) { Write-D9Log (T-D9 'Після перевірки пакетів встановлювати нічого (поточні драйвери не старші).') Ok; return [pscustomobject]@{ Candidates = $cands; Packages = @(); Session = $null; RebootRecommended = $false } }
    $cat = New-D9DriverCatalog -Packages $todo
    $plan = New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo $SystemInfo
    $session = Invoke-D9Plan -Plan $plan -SystemInfo $SystemInfo -Selection (T-D9 'драйвери з Microsoft Update Catalog') -NoRestorePoint:$NoRestorePoint
    [pscustomobject]@{ Candidates = $cands; Packages = $todo; Session = $session; RebootRecommended = $true }
}
