# Автоматичні виправлення для чекліста, які не є перемиканням налаштувань (тому без відкату через журнал):
# Захисник, оновлення Windows, перевірка диска, захист системи. Кожна функція повертає
# [pscustomobject]@{ Done; RebootRecommended } і пише хід роботи в журнал виконання.

# Дії обслуговування, на які посилаються знахідки (fix.type = maintenance): група в чеклісті, назва кроку, функція.
# restorePoint і reboot чекліст обробляє окремо.
$script:D9MaintenanceActions = [ordered]@{
    chkdskScan     = @{ Group = 12; Fn = 'Invoke-D9DiskCheck';          Title = 'Перевірити файлову систему диска' }
    enableRestore  = @{ Group = 19; Fn = 'Enable-D9SystemRestore';      Title = 'Увімкнути захист системи (точки відновлення)' }
    driverUpdate   = @{ Group = 29; Fn = 'Invoke-D9DriverUpdateStep';   Title = 'Знайти й встановити драйвери з інтернету (Microsoft Update Catalog)' }
    defenderUpdate = @{ Group = 43; Fn = 'Invoke-D9DefenderRepair';     Title = 'Увімкнути Захисник Windows і оновити антивірусні бази' }
    defenderScan   = @{ Group = 44; Fn = 'Invoke-D9DefenderScan';       Title = 'Перевірити комп''ютер Захисником Windows' }
    wuReset        = @{ Group = 48; Fn = 'Invoke-D9WindowsUpdateReset'; Title = 'Скинути Windows Update' }
    windowsUpdate  = @{ Group = 49; Fn = 'Install-D9WindowsUpdates';    Title = 'Встановити оновлення Windows' }
    browserCache   = @{ Group = 51; Fn = 'Clear-D9BrowserCache';        Title = 'Очистити кеш браузерів' }
    orphanEntries  = @{ Group = 52; Fn = 'Clear-D9OrphanEntries';       Title = 'Прибрати з реєстру записи від уже видалених програм' }
    wingetUpgrade  = @{ Group = 70; Fn = 'Invoke-D9AppUpgradeAll';      Title = 'Оновити програми' }
    repairSystem   = @{ Group = 75; Fn = 'Invoke-D9RepairSystem';       Title = 'Відновити системні файли Windows' }
    defragHdd      = @{ Group = 13; Fn = 'Invoke-D9DefragHdd';          Title = 'Дефрагментувати жорсткий диск' }
    networkReset   = @{ Group = 47; Fn = 'Invoke-D9NetworkReset';       Title = 'Скинути мережеві налаштування' }
    vcRedist       = @{ Group = 69; Fn = 'Repair-D9VcRedist';           Title = 'Перевстановити бібліотеки Visual C++' }
    searchReset    = @{ Group = 73; Fn = 'Reset-D9SearchIndex';         Title = 'Перебудувати пошуковий індекс Windows' }
    memoryTest     = @{ Group = 85; Fn = 'Invoke-D9MemoryTestOnReboot'; Title = 'Перевірити оперативну пам''ять під час перезавантаження' }
    cbsLogs        = @{ Group = 53; Fn = 'Clear-D9CbsLogs';             Title = 'Видалити старі журнали обслуговування Windows (CBS)' }
    # OnRequest — лише кнопкою «Виправити» в знахідці, не в «Сканувати й виправити все»
    iconCache      = @{ Group = 53; Fn = 'Reset-D9IconCache';           Title = 'Скинути кеш значків і ескізів'; OnRequest = $true }
    windowsOld     = @{ Group = 54; Fn = 'Remove-D9WindowsOld';         Title = 'Видалити попередню версію Windows (Windows.old)'; OnRequest = $true }
}

# Назва кроку обслуговування поточною мовою (Title у таблиці — український шаблон для T-D9)
function Get-D9MaintenanceTitle {
    param([Parameter(Mandatory)][string]$Name)
    $m = $script:D9MaintenanceActions[$Name]
    if ($m) { T-D9 $m.Title } else { $Name }
}

# Крок чекліста: драйвери для пристроїв без драйвера й новіші версії для решти (без необов'язкових замін).
# Точку відновлення вже створив чекліст; після вдалого встановлення завантажені пакети видаляються.
function Invoke-D9DriverUpdateStep {
    $r = Invoke-D9DriverAutoUpdate -SystemInfo (Get-D9SystemInfo) -Folder (Join-Path (Get-D9DataRoot) 'driver-downloads') -NoRestorePoint -UseOemTool -CleanupDownloads
    [pscustomobject]@{ Done = $true; RebootRecommended = [bool]$r.Session }
}

# Папки кешу браузерів (лише кеш: паролі, історія, вкладки й розширення не зачіпаються)
function Get-D9BrowserCacheDirs {
    $local = $env:LOCALAPPDATA
    $browsers = @(
        @{ Name = 'Chrome';  Process = 'chrome';  Root = "$local\Google\Chrome\User Data" }
        @{ Name = 'Edge';    Process = 'msedge';  Root = "$local\Microsoft\Edge\User Data" }
        @{ Name = 'Brave';   Process = 'brave';   Root = "$local\BraveSoftware\Brave-Browser\User Data" }
        @{ Name = 'Opera';   Process = 'opera';   Root = "$env:APPDATA\Opera Software\Opera Stable" }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path $b.Root)) { continue }
        $dirs = @(Get-ChildItem $b.Root -Directory -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)\Cache", "$($_.FullName)\Code Cache", "$($_.FullName)\Service Worker\CacheStorage" })
        $dirs += "$($b.Root)\Cache", "$($b.Root)\Code Cache"
        [pscustomobject]@{ Name = $b.Name; Process = $b.Process; Dirs = @($dirs | Where-Object { Test-Path -LiteralPath $_ }) }
    }
    $ff = @(Get-ChildItem "$local\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)\cache2" } | Where-Object { Test-Path -LiteralPath $_ })
    if ($ff) { [pscustomobject]@{ Name = 'Firefox'; Process = 'firefox'; Dirs = $ff } }
}

function Clear-D9BrowserCache {
    Write-D9Log (T-D9 'Очищення кешу браузерів (паролі, історія й вкладки не зачіпаються)...')
    $freed = 0L; $skipped = @()
    foreach ($b in @(Get-D9BrowserCacheDirs | Where-Object { $_.Dirs })) {
        if (Get-Process -Name $b.Process -ErrorAction SilentlyContinue) { $skipped += $b.Name; continue }
        $before = [long](($b.Dirs | ForEach-Object { Get-D9FolderSize $_ } | Measure-Object -Sum).Sum)
        foreach ($d in $b.Dirs) { Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        $after = [long](($b.Dirs | ForEach-Object { Get-D9FolderSize $_ } | Measure-Object -Sum).Sum)
        $freed += [math]::Max(0, $before - $after)
        Write-D9Log "  $($b.Name): $(T-D9 'звільнено {0}' (Format-D9Size ([math]::Max(0, $before - $after))))" Detail
    }
    if ($skipped) { Write-D9Log ('  ' + (T-D9 'Пропущено, бо відкриті: {0}. Закрийте їх і повторіть.' ($skipped -join ', '))) Warn }
    Write-D9Log (T-D9 'Звільнено: {0}.' (Format-D9Size $freed)) Ok
    [pscustomobject]@{ Done = $true; RebootRecommended = $false; Freed = $freed }
}

function Invoke-D9DefenderRepair {
    Write-D9Log (T-D9 'Захисник Windows: увімкнення захисту й оновлення баз...')
    if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) { Write-D9Log ('  ' + (T-D9 'Захисника в цій системі немає.')) Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Write-D9Log ('  ' + (T-D9 'Захист у реальному часі увімкнено.')) Ok
    } catch { Write-D9Log ('  ' + (T-D9 'Не вдалося увімкнути захист: {0}. Можливо, працює інший антивірус або увімкнено захист від втручання — увімкніть вручну в «Безпека Windows».' $_.Exception.Message)) Warn }
    try {
        Update-MpSignature -ErrorAction Stop
        Write-D9Log ('  ' + (T-D9 'Антивірусні бази оновлено (версія {0}).' (Get-MpComputerStatus).AntivirusSignatureVersion)) Ok
    } catch { Write-D9Log ('  ' + (T-D9 'Бази не оновлено: {0}. Потрібен інтернет.' $_.Exception.Message)) Warn }
    [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

function Invoke-D9DefenderScan {
    Write-D9Log (T-D9 'Швидка перевірка Захисником Windows (зазвичай 5–15 хвилин)...')
    $since = Get-Date
    # Start-MpScan іноді не повертається (перевірка застрягла або чекає іншої) — чекаємо не довше 30 хвилин
    try {
        $job = Start-MpScan -ScanType QuickScan -AsJob -ErrorAction Stop
        if (-not (Wait-Job $job -Timeout 1800)) {
            Write-D9Log ('  ' + (T-D9 'Перевірка триває понад 30 хвилин — не чекаємо, Захисник завершить її сам.')) Warn
            return [pscustomobject]@{ Done = $true; RebootRecommended = $false }
        }
        Receive-Job $job -ErrorAction Stop | Out-Null
    }
    catch { Write-D9Log ('  ' + (T-D9 'Перевірку не запущено: {0}' $_.Exception.Message)) Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    $found = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $since })
    if ($found) {
        Write-D9Log ('  ' + (T-D9 'Знайдено загроз: {0}. Захисник обробив їх автоматично; подробиці — Безпека Windows → Журнал захисту.' $found.Count)) Warn
    } else { Write-D9Log ('  ' + (T-D9 'Загроз не знайдено.')) Ok }
    [pscustomobject]@{ Done = $true; RebootRecommended = [bool]$found }
}

# Встановлення оновлень Windows через Windows Update Agent (як кнопка «Перевірити наявність оновлень»).
# Лише програмні оновлення: драйвери ставимо самі (вкладка «Драйвери»).
function Install-D9WindowsUpdates {
    Write-D9Log (T-D9 'Пошук оновлень Windows (може тривати кілька хвилин)...')
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Debora'
    $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    $list = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $result.Updates) {
        if ($u.InstallationBehavior.CanRequestUserInput) { Write-D9Log ('  ' + (T-D9 'Пропущено (потребує вашої участі): {0}' $u.Title)) Detail; continue }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$list.Add($u)
        Write-D9Log "  $($u.Title)" Detail
    }
    if ($list.Count -eq 0) { Write-D9Log (T-D9 'Нових оновлень немає.') Ok; return [pscustomobject]@{ Done = $true; Installed = 0; RebootRecommended = $false } }
    Write-D9Log (T-D9 'Завантаження оновлень: {0}...' $list.Count)
    $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $list
    [void]$downloader.Download()
    Write-D9Log (T-D9 'Встановлення...')
    $installer = $session.CreateUpdateInstaller(); $installer.Updates = $list
    $r = $installer.Install()
    $ok = 0
    for ($i = 0; $i -lt $list.Count; $i++) {
        $code = $r.GetUpdateResult($i).ResultCode   # 2 — успішно, 3 — успішно з помилками
        if ($code -in 2, 3) { $ok++ } else { Write-D9Log ('  ' + (T-D9 'Не встановлено: {0} (код {1})' $list.Item($i).Title $code)) Warn }
    }
    Write-D9Log (T-D9 'Встановлено оновлень: {0} з {1}.' $ok $list.Count) $(if ($ok -eq $list.Count) { 'Ok' } else { 'Warn' })
    if ($r.RebootRequired) { Write-D9Log (T-D9 'Для завершення потрібне перезавантаження.') Warn }
    [pscustomobject]@{ Done = $true; Installed = $ok; RebootRecommended = [bool]$r.RebootRequired }
}

# chkdsk /scan працює без перезавантаження; якщо знайдено помилки — позначаємо том, і Windows
# виправить їх під час наступного запуску (autochk), як після «Перевірити» у властивостях диска.
function Invoke-D9DiskCheck {
    $drive = $env:SystemDrive
    Write-D9Log (T-D9 'Перевірка файлової системи {0} (chkdsk /scan, 1–10 хвилин)...' $drive)
    $code = Invoke-D9Native 'chkdsk.exe' @($drive, '/scan')
    if ($code -eq 0) {
        Write-D9Log (T-D9 'Помилок файлової системи не знайдено.') Ok
        return [pscustomobject]@{ Done = $true; RebootRecommended = $false }
    }
    [void](Invoke-D9Native 'fsutil.exe' @('dirty', 'set', $drive))
    Write-D9Log (T-D9 'Знайдено помилки — їх буде виправлено під час наступного перезавантаження (перевірка диска перед входом у Windows).') Warn
    [pscustomobject]@{ Done = $true; RebootRecommended = $true }
}

function Enable-D9SystemRestore {
    $drive = "$env:SystemDrive\"
    Write-D9Log (T-D9 'Увімкнення захисту системи для {0}...' $drive)
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
    foreach ($n in 'DisableSR', 'DisableConfig') {
        if ((Get-ItemProperty $policy -ErrorAction SilentlyContinue).$n -eq 1) {
            Remove-ItemProperty -Path $policy -Name $n -ErrorAction SilentlyContinue
            Write-D9Log ('  ' + (T-D9 'Прибрано заборону політикою ({0}).' $n)) Detail
        }
    }
    try {
        Enable-ComputerRestore -Drive $drive -ErrorAction Stop
        Write-D9Log ('  ' + (T-D9 'Захист системи увімкнено.')) Ok
    } catch { Write-D9Log ('  ' + (T-D9 'Не вдалося: {0}' $_.Exception.Message)) Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    # Місце під точки відновлення: 5% диска (типово Windows інколи ставить 0 або 1–2%)
    [void](Invoke-D9Native 'vssadmin.exe' @('resize', 'shadowstorage', "/for=$env:SystemDrive", "/on=$env:SystemDrive", '/maxsize=5%'))
    $rp = New-D9RestorePoint
    if ($rp) { Write-D9Log ('  ' + (T-D9 'Першу точку відновлення створено.')) Ok }
    [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

# Дефрагментація HDD (SSD не чіпаємо: для них Windows робить TRIM). Звичайно 10–60 хвилин.
function Invoke-D9DefragHdd {
    $drive = $env:SystemDrive.TrimEnd(':')
    Write-D9Log (T-D9 'Дефрагментація диска {0}: (може тривати до години, комп''ютером можна користуватися)...' $drive)
    try {
        Optimize-Volume -DriveLetter $drive -Defrag -ErrorAction Stop
        Write-D9Log (T-D9 'Дефрагментацію завершено.') Ok
    } catch { Write-D9Log ('  ' + (T-D9 'Не вдалося: {0}' $_.Exception.Message)) Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

# Перевстановлення Visual C++ 2015–2022 (x64 і x86) поверх наявних — лікує падіння програм у msvcp/vcruntime
function Repair-D9VcRedist {
    Write-D9Log (T-D9 'Перевстановлення бібліотек Visual C++ 2015–2022...')
    $res = @(Update-D9Apps -Ids @('Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86'))
    $bad = @($res | Where-Object { $_.result -in 'failed', 'notFound' })
    [pscustomobject]@{ Done = -not $bad; RebootRecommended = [bool]($res | Where-Object result -eq 'reboot') }
}

# Пошуковий індекс розрісся або зламаний: зупинити службу, прибрати базу, Windows проіндексує заново (у фоні, кілька годин)
function Reset-D9SearchIndex {
    Write-D9Log (T-D9 'Перебудова пошукового індексу Windows...')
    $dir = Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows'
    $before = [long]((Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
    Stop-Service WSearch -Force -ErrorAction SilentlyContinue
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -Value 0 -Type DWord -ErrorAction SilentlyContinue
    $failed = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        try { [IO.File]::Delete($f.FullName) } catch { $failed++ }
    }
    Start-Service WSearch -ErrorAction SilentlyContinue
    if ($failed) { Write-D9Log ('  ' + (T-D9 'Не вдалося видалити файлів: {0} (зайняті).' $failed)) Warn }
    Write-D9Log (T-D9 'Звільнено {0}. Індекс створюється заново у фоні; пошук запрацює повністю за кілька годин.' (Format-D9Size $before)) Ok
    [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

# Засіб діагностики пам'яті Windows при наступному запуску (bcdedit /bootsequence — лише один раз).
# Результат Windows запише в журнал (MemoryDiagnostics-Results), його покаже наступне сканування.
function Invoke-D9MemoryTestOnReboot {
    Write-D9Log (T-D9 'Планування перевірки пам''яті на наступне перезавантаження...')
    $code = Invoke-D9Native 'bcdedit.exe' @('/bootsequence', '{memdiag}')
    if ($code -ne 0) { Write-D9Log ('  ' + (T-D9 'Не вдалося. Запустіть вручну: Win+R → mdsched.exe.')) Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    Write-D9Log (T-D9 'Після перезавантаження Windows 10–20 хвилин перевірятиме пам''ять, потім запуститься як звичайно. Результат покаже наступне сканування.') Ok
    [pscustomobject]@{ Done = $true; RebootRecommended = $true }
}
