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
    wingetUpgrade  = @{ Group = 70; Fn = 'Invoke-D9AppUpgradeAll';      Title = 'Оновити програми' }
    repairSystem   = @{ Group = 75; Fn = 'Invoke-D9RepairSystem';       Title = 'Відновити системні файли Windows' }
    defragHdd      = @{ Group = 13; Fn = 'Invoke-D9DefragHdd';          Title = 'Дефрагментувати жорсткий диск' }
    networkReset   = @{ Group = 47; Fn = 'Invoke-D9NetworkReset';       Title = 'Скинути мережеві налаштування' }
    vcRedist       = @{ Group = 69; Fn = 'Repair-D9VcRedist';           Title = 'Перевстановити бібліотеки Visual C++' }
    searchReset    = @{ Group = 73; Fn = 'Reset-D9SearchIndex';         Title = 'Перебудувати пошуковий індекс Windows' }
    memoryTest     = @{ Group = 85; Fn = 'Invoke-D9MemoryTestOnReboot'; Title = 'Перевірити оперативну пам''ять під час перезавантаження' }
}

# Крок чекліста: драйвери для пристроїв без драйвера й новіші версії для решти (без необов'язкових замін).
# Точку відновлення вже створив чекліст; завантажені пакети лишаються в папці даних для повторного використання.
function Invoke-D9DriverUpdateStep {
    $r = Invoke-D9DriverAutoUpdate -SystemInfo (Get-D9SystemInfo) -Folder (Join-Path (Get-D9DataRoot) 'driver-downloads') -NoRestorePoint -UseOemTool
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
    Write-D9Log 'Очищення кешу браузерів (паролі, історія й вкладки не зачіпаються)...'
    $freed = 0L; $skipped = @()
    foreach ($b in @(Get-D9BrowserCacheDirs | Where-Object { $_.Dirs })) {
        if (Get-Process -Name $b.Process -ErrorAction SilentlyContinue) { $skipped += $b.Name; continue }
        $before = [long](($b.Dirs | ForEach-Object { Get-D9FolderSize $_ } | Measure-Object -Sum).Sum)
        foreach ($d in $b.Dirs) { Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        $after = [long](($b.Dirs | ForEach-Object { Get-D9FolderSize $_ } | Measure-Object -Sum).Sum)
        $freed += [math]::Max(0, $before - $after)
        Write-D9Log "  $($b.Name): звільнено $(Format-D9Size ([math]::Max(0, $before - $after)))" Detail
    }
    if ($skipped) { Write-D9Log "  Пропущено, бо відкриті: $($skipped -join ', '). Закрийте їх і повторіть." Warn }
    Write-D9Log "Звільнено: $(Format-D9Size $freed)." Ok
    [pscustomobject]@{ Done = $true; RebootRecommended = $false; Freed = $freed }
}

function Invoke-D9DefenderRepair {
    Write-D9Log 'Захисник Windows: увімкнення захисту й оновлення баз...'
    if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) { Write-D9Log '  Захисника в цій системі немає.' Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Write-D9Log '  Захист у реальному часі увімкнено.' Ok
    } catch { Write-D9Log "  Не вдалося увімкнути захист: $($_.Exception.Message). Можливо, працює інший антивірус або увімкнено захист від втручання — увімкніть вручну в «Безпека Windows»." Warn }
    try {
        Update-MpSignature -ErrorAction Stop
        Write-D9Log "  Антивірусні бази оновлено (версія $((Get-MpComputerStatus).AntivirusSignatureVersion))." Ok
    } catch { Write-D9Log "  Бази не оновлено: $($_.Exception.Message). Потрібен інтернет." Warn }
    [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

function Invoke-D9DefenderScan {
    Write-D9Log 'Швидка перевірка Захисником Windows (зазвичай 5–15 хвилин)...'
    $since = Get-Date
    try { Start-MpScan -ScanType QuickScan -ErrorAction Stop }
    catch { Write-D9Log "  Перевірку не запущено: $($_.Exception.Message)" Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    $found = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $since })
    if ($found) {
        Write-D9Log "  Знайдено загроз: $($found.Count). Захисник обробив їх автоматично; подробиці — Безпека Windows → Журнал захисту." Warn
    } else { Write-D9Log '  Загроз не знайдено.' Ok }
    [pscustomobject]@{ Done = $true; RebootRecommended = [bool]$found }
}

# Встановлення оновлень Windows через Windows Update Agent (як кнопка «Перевірити наявність оновлень»).
# Лише програмні оновлення: драйвери ставимо самі (вкладка «Драйвери»).
function Install-D9WindowsUpdates {
    Write-D9Log 'Пошук оновлень Windows (може тривати кілька хвилин)...'
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Debloater9'
    $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    $list = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $result.Updates) {
        if ($u.InstallationBehavior.CanRequestUserInput) { Write-D9Log "  Пропущено (потребує вашої участі): $($u.Title)" Detail; continue }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$list.Add($u)
        Write-D9Log "  $($u.Title)" Detail
    }
    if ($list.Count -eq 0) { Write-D9Log 'Нових оновлень немає.' Ok; return [pscustomobject]@{ Done = $true; Installed = 0; RebootRecommended = $false } }
    Write-D9Log "Завантаження оновлень: $($list.Count)..."
    $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $list
    [void]$downloader.Download()
    Write-D9Log 'Встановлення...'
    $installer = $session.CreateUpdateInstaller(); $installer.Updates = $list
    $r = $installer.Install()
    $ok = 0
    for ($i = 0; $i -lt $list.Count; $i++) {
        $code = $r.GetUpdateResult($i).ResultCode   # 2 — успішно, 3 — успішно з помилками
        if ($code -in 2, 3) { $ok++ } else { Write-D9Log "  Не встановлено: $($list.Item($i).Title) (код $code)" Warn }
    }
    Write-D9Log "Встановлено оновлень: $ok з $($list.Count)." $(if ($ok -eq $list.Count) { 'Ok' } else { 'Warn' })
    if ($r.RebootRequired) { Write-D9Log 'Для завершення потрібне перезавантаження.' Warn }
    [pscustomobject]@{ Done = $true; Installed = $ok; RebootRecommended = [bool]$r.RebootRequired }
}

# chkdsk /scan працює без перезавантаження; якщо знайдено помилки — позначаємо том, і Windows
# виправить їх під час наступного запуску (autochk), як після «Перевірити» у властивостях диска.
function Invoke-D9DiskCheck {
    $drive = $env:SystemDrive
    Write-D9Log "Перевірка файлової системи $drive (chkdsk /scan, 1–10 хвилин)..."
    $code = Invoke-D9Native 'chkdsk.exe' @($drive, '/scan')
    if ($code -eq 0) {
        Write-D9Log 'Помилок файлової системи не знайдено.' Ok
        return [pscustomobject]@{ Done = $true; RebootRecommended = $false }
    }
    [void](Invoke-D9Native 'fsutil.exe' @('dirty', 'set', $drive))
    Write-D9Log "Знайдено помилки — їх буде виправлено під час наступного перезавантаження (перевірка диска перед входом у Windows)." Warn
    [pscustomobject]@{ Done = $true; RebootRecommended = $true }
}

function Enable-D9SystemRestore {
    $drive = "$env:SystemDrive\"
    Write-D9Log "Увімкнення захисту системи для $drive..."
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
    foreach ($n in 'DisableSR', 'DisableConfig') {
        if ((Get-ItemProperty $policy -ErrorAction SilentlyContinue).$n -eq 1) {
            Remove-ItemProperty -Path $policy -Name $n -ErrorAction SilentlyContinue
            Write-D9Log "  Прибрано заборону політикою ($n)." Detail
        }
    }
    try {
        Enable-ComputerRestore -Drive $drive -ErrorAction Stop
        Write-D9Log '  Захист системи увімкнено.' Ok
    } catch { Write-D9Log "  Не вдалося: $($_.Exception.Message)" Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    # Місце під точки відновлення: 5% диска (типово Windows інколи ставить 0 або 1–2%)
    [void](Invoke-D9Native 'vssadmin.exe' @('resize', 'shadowstorage', "/for=$env:SystemDrive", "/on=$env:SystemDrive", '/maxsize=5%'))
    $rp = New-D9RestorePoint
    if ($rp) { Write-D9Log '  Першу точку відновлення створено.' Ok }
    [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

# Дефрагментація HDD (SSD не чіпаємо: для них Windows робить TRIM). Звичайно 10–60 хвилин.
function Invoke-D9DefragHdd {
    $drive = $env:SystemDrive.TrimEnd(':')
    Write-D9Log "Дефрагментація диска ${drive}: (може тривати до години, комп'ютером можна користуватися)..."
    try {
        Optimize-Volume -DriveLetter $drive -Defrag -ErrorAction Stop
        Write-D9Log 'Дефрагментацію завершено.' Ok
    } catch { Write-D9Log "  Не вдалося: $($_.Exception.Message)" Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

# Перевстановлення Visual C++ 2015–2022 (x64 і x86) поверх наявних — лікує падіння програм у msvcp/vcruntime
function Repair-D9VcRedist {
    Write-D9Log 'Перевстановлення бібліотек Visual C++ 2015–2022...'
    $res = @(Update-D9Apps -Ids @('Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86'))
    $bad = @($res | Where-Object { $_.result -in 'failed', 'notFound' })
    [pscustomobject]@{ Done = -not $bad; RebootRecommended = [bool]($res | Where-Object result -eq 'reboot') }
}

# Пошуковий індекс розрісся або зламаний: зупинити службу, прибрати базу, Windows проіндексує заново (у фоні, кілька годин)
function Reset-D9SearchIndex {
    Write-D9Log 'Перебудова пошукового індексу Windows...'
    $dir = Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows'
    $before = [long]((Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
    Stop-Service WSearch -Force -ErrorAction SilentlyContinue
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -Value 0 -Type DWord -ErrorAction SilentlyContinue
    $failed = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        try { [IO.File]::Delete($f.FullName) } catch { $failed++ }
    }
    Start-Service WSearch -ErrorAction SilentlyContinue
    if ($failed) { Write-D9Log "  Не вдалося видалити файлів: $failed (зайняті)." Warn }
    Write-D9Log "Звільнено $(Format-D9Size $before). Індекс створюється заново у фоні; пошук запрацює повністю за кілька годин." Ok
    [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

# Засіб діагностики пам'яті Windows при наступному запуску (bcdedit /bootsequence — лише один раз).
# Результат Windows запише в журнал (MemoryDiagnostics-Results), його покаже наступне сканування.
function Invoke-D9MemoryTestOnReboot {
    Write-D9Log 'Планування перевірки пам''яті на наступне перезавантаження...'
    $code = Invoke-D9Native 'bcdedit.exe' @('/bootsequence', '{memdiag}')
    if ($code -ne 0) { Write-D9Log '  Не вдалося. Запустіть вручну: Win+R → mdsched.exe.' Warn; return [pscustomobject]@{ Done = $false; RebootRecommended = $false } }
    Write-D9Log 'Після перезавантаження Windows 10–20 хвилин перевірятиме пам''ять, потім запуститься як звичайно. Результат покаже наступне сканування.' Ok
    [pscustomobject]@{ Done = $true; RebootRecommended = $true }
}
