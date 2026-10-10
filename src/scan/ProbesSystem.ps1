# Проби швидкодії, чистоти диска та стабільності, яким потрібен код.

# ======================= Чистота: що займає місце =======================

function New-D9SpaceFinding {
    param($Check, [long]$Bytes, [string]$Title, [string]$Details, $Fix, [object[]]$Links)
    $t = $Check.thresholds
    $warn = if ($t.warningGB) { $t.warningGB } else { 2 }
    $sugg = if ($t.suggestionGB) { $t.suggestionGB } else { 0.3 }
    if ($Bytes -lt $sugg * 1GB) { return }
    $severity = if ($Bytes -ge $warn * 1GB) { 'warning' } else { 'suggestion' }
    New-D9Finding $Check $severity (Format-D9Template $Title @{ size = (Format-D9Size $Bytes) }) $Details $Fix $Links -Data ([pscustomobject]@{ bytes = $Bytes })
}

function Get-D9FilesSize {
    param([string[]]$Paths)
    [long](($Paths | ForEach-Object { Get-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue } | Where-Object { -not $_.PSIsContainer } | Measure-Object Length -Sum).Sum)
}

function Test-D9CleanTemp {
    param($Check, $Ctx)
    $b = (Get-D9FolderSize $env:TEMP 5000) + (Get-D9FolderSize "$env:SystemRoot\Temp")
    New-D9SpaceFinding $Check $b (T-D9 'Тимчасові файли займають {size}') (T-D9 'Залишки інсталяторів і програм у папках TEMP. Безпечно видаляються (зайняті файли пропускаються).') @{ type = 'tweaks'; ids = @('cleanup.temp') }
}

function Test-D9CleanUpdateCache {
    param($Check, $Ctx)
    $b = Get-D9FolderSize "$env:SystemRoot\SoftwareDistribution\Download"
    New-D9SpaceFinding $Check $b (T-D9 'Кеш завантажених оновлень Windows: {size}') (T-D9 'Уже встановлені оновлення. Windows за потреби завантажить їх знову.') @{ type = 'tweaks'; ids = @('cleanup.update-cache') }
}

function Test-D9CleanRecycleBin {
    param($Check, $Ctx)
    $b = [long]0
    try { $b = [long](@((New-Object -ComObject Shell.Application).NameSpace(10).Items()) | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum } catch { }
    New-D9SpaceFinding $Check $b (T-D9 'У кошику {size}') (T-D9 'Перегляньте кошик і очистіть його, якщо нічого не потрібно.') @{ type = 'tweaks'; ids = @('cleanup.recycle-bin') }
}

function Test-D9CleanWindowsOld {
    param($Check, $Ctx)
    $b = (Get-D9FolderSize "$env:SystemDrive\Windows.old" 4000) + (Get-D9FolderSize "$env:SystemDrive\`$WINDOWS.~BT" 2000) + (Get-D9FolderSize "$env:SystemDrive\`$Windows.~WS" 2000)
    New-D9SpaceFinding $Check $b (T-D9 'Попередня версія Windows займає {size}') (T-D9 'Windows.old потрібна лише для відкату на попередню версію (10 днів після оновлення). Видалення: Параметри → Система → Сховище → Тимчасові файли → «Попередня інсталяція Windows».') @{ type = 'manual' } @((New-D9Link (T-D9 'Тимчасові файли') 'ms-settings:storagepolicies'))
}

function Test-D9CleanDumps {
    param($Check, $Ctx)
    $win = $env:SystemRoot
    $b = (Get-D9FilesSize @("$win\MEMORY.DMP")) + (Get-D9FolderSize "$win\Minidump") + (Get-D9FolderSize "$win\LiveKernelReports") +
         (Get-D9FolderSize "$env:LOCALAPPDATA\CrashDumps") + (Get-D9FolderSize "$env:ProgramData\Microsoft\Windows\WER\ReportArchive") + (Get-D9FolderSize "$env:ProgramData\Microsoft\Windows\WER\ReportQueue")
    New-D9SpaceFinding $Check $b (T-D9 'Дампи збоїв і звіти про помилки: {size}') (T-D9 'Файли для діагностики старих збоїв. Якщо їх ніхто не аналізує — можна видалити.') @{ type = 'tweaks'; ids = @('cleanup.leftovers') }
}

function Test-D9CleanInstallerLeftovers {
    param($Check, $Ctx)
    $b = (Get-D9FolderSize "$env:SystemDrive\NVIDIA") + (Get-D9FolderSize "$env:SystemDrive\AMD")
    New-D9SpaceFinding $Check $b (T-D9 'Розпаковані інсталятори драйверів NVIDIA/AMD: {size}') (T-D9 'Папки C:\NVIDIA і C:\AMD лишаються після встановлення відеодрайвера й більше не потрібні.') @{ type = 'tweaks'; ids = @('cleanup.leftovers') }
}

function Test-D9CleanBrowserCache {
    param($Check, $Ctx)
    $dirs = @(Get-D9BrowserCacheDirs | ForEach-Object { $_.Dirs })
    $b = [long](($dirs | ForEach-Object { Get-D9FolderSize $_ 1500 } | Measure-Object -Sum).Sum)
    New-D9SpaceFinding $Check $b (T-D9 'Кеш браузерів: {size}') (T-D9 'Браузери самі обмежують кеш, але на маленькому диску його варто почистити. Debora очистить кеш закритих браузерів; паролі, історію й вкладки не зачіпає.') @{ type = 'maintenance'; action = 'browserCache' }
}

function Test-D9CleanOldDownloads {
    param($Check, $Ctx)
    $downloads = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
    if (-not $downloads) { $downloads = Join-Path $env:USERPROFILE 'Downloads' }
    $cutoff = $Ctx.Now.AddDays(-$Check.thresholds.days)
    $files = @(Get-ChildItem $downloads -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.msi', '.iso', '.zip', '.rar', '.7z', '.img' -and $_.LastWriteTime -lt $cutoff })
    $b = [long]($files | Measure-Object Length -Sum).Sum
    New-D9SpaceFinding $Check $b (T-D9 'Старі інсталятори й архіви в «Завантаженнях»: {{size}} ({0} файлів)' $files.Count) (T-D9 'Файли .exe, .msi, .iso, .zip старші за {0} днів. Перегляньте й видаліть непотрібні: {1}' $Check.thresholds.days $downloads) @{ type = 'manual' }
}

function Test-D9CleanThumbnails {
    param($Check, $Ctx)
    $b = [long](Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    New-D9SpaceFinding $Check $b (T-D9 'Кеш мініатюр займає {size}') (T-D9 'Видалити: «Очищення диска» → «Ескізи». Мініатюри відновляться самі.') @{ type = 'manual' } @((New-D9Link (T-D9 'Очищення диска') 'cleanmgr.exe'))
}

function Test-D9CleanDoCache {
    param($Check, $Ctx)
    $b = Get-D9FolderSize "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
    New-D9SpaceFinding $Check $b (T-D9 'Кеш оптимізації доставки оновлень: {size}') (T-D9 'Копії оновлень для роздачі іншим ПК. Безпечно видаляються.') @{ type = 'tweaks'; ids = @('cleanup.do-cache') }
}

function Test-D9CleanCbsLogs {
    param($Check, $Ctx)
    $b = Get-D9FolderSize "$env:SystemRoot\Logs\CBS"
    New-D9SpaceFinding $Check $b (T-D9 'Журнали обслуговування Windows (CBS): {size}') (T-D9 'Великий розмір — ознака проблем з оновленнями. Видаляються через «Очищення диска» → «Очистити системні файли» → «Файли журналу Windows Update».') @{ type = 'manual' } @((New-D9Link (T-D9 'Очищення диска') 'cleanmgr.exe'))
}

function Test-D9Hiberfile {
    param($Check, $Ctx)
    $file = Get-ChildItem "$env:SystemDrive\" -Force -Filter 'hiberfil.sys' -ErrorAction SilentlyContinue
    if (-not $file) { return }
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'"
    $freePercent = $c.FreeSpace * 100 / $c.Size
    if ($file.Length -ge $Check.thresholds.minGB * 1GB -and $freePercent -lt 25) {
        New-D9Finding $Check suggestion (T-D9 'Файл гібернації займає {0}' (Format-D9Size $file.Length)) (T-D9 'Можна зменшити приблизно вдвічі (режим «reduced»): швидкий запуск лишиться, зникне лише повна гібернація.') @{ type = 'tweaks'; ids = @('perf.reduced-hiberfile') } -Data ([pscustomobject]@{ bytes = [long]($file.Length / 2) })
    }
}

function Test-D9OldProfiles {
    param($Check, $Ctx)
    $cutoff = $Ctx.Now.AddDays(-$Check.thresholds.days)
    $profiles = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath -and -not $_.Loaded -and $_.LastUseTime -and $_.LastUseTime -lt $cutoff }
    $old = @($profiles | ForEach-Object { Split-Path $_.LocalPath -Leaf })
    if ($old) {
        New-D9Finding $Check info (T-D9 'Профілі, якими не користувались понад {0} днів: {1}' $Check.thresholds.days ($old -join ', ')) (T-D9 'Якщо ці облікові записи більше не потрібні — збережіть файли й видаліть їх (sysdm.cpl → Додатково → Профілі користувачів).') @{ type = 'manual' }
    }
}

function Test-D9OldDrivers {
    param($Check, $Ctx)
    $drivers = try { @(Get-WindowsDriver -Online -ErrorAction Stop) } catch { return New-D9Skip $Check (T-D9 'потрібні права адміністратора') }
    $dups = @($drivers | Group-Object OriginalFileName | Where-Object Count -gt 1)
    $oldCount = ($dups | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum).Sum
    if ($oldCount -ge $Check.thresholds.min) {
        $b = [long]($dups | ForEach-Object { $_.Group | Sort-Object Date -Descending | Select-Object -Skip 1 } | ForEach-Object { Get-D9FolderSize (Split-Path $_.OriginalFileName) 1000 } | Measure-Object -Sum).Sum
        New-D9Finding $Check suggestion (T-D9 'Старі версії драйверів у сховищі: {0} (≈ {1})' $oldCount (Format-D9Size $b)) (T-D9 'Після оновлень драйверів старі копії лишаються в DriverStore. Їх можна видалити утилітою pnputil /delete-driver (від адміністратора) — після цього відкат цих драйверів буде неможливий.') @{ type = 'manual' } -Data ([pscustomobject]@{ bytes = $b })
    }
}

# ======================= Швидкодія =======================

function Test-D9Pagefile {
    param($Check, $Ctx)
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { return }
    $files = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
    $link = New-D9Link (T-D9 'Параметри швидкодії → Віртуальна пам''ять') 'SystemPropertiesPerformance.exe'
    if (-not $files) {
        $severity = if ($Ctx.System.RamGB -le 16) { 'warning' } else { 'suggestion' }
        return New-D9Finding $Check $severity (T-D9 'Файл підкачки вимкнено') (T-D9 'З {0} ГБ пам''яті програми можуть аварійно закриватися при її нестачі, а Windows не збереже дамп збою. Debora поверне «Автоматично вибирати розмір файлу підкачки» (після перезавантаження).' $Ctx.System.RamGB) (New-D9ActionsFix @(@{ type = 'registry'; path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; name = 'PagingFiles'; value = @('?:\pagefile.sys'); kind = 'MultiString' }) -Reboot) @($link)
    }
    $maxMB = ($files | Measure-Object MaximumSize -Sum).Sum
    if ($maxMB -gt 0 -and $maxMB -lt $Ctx.System.RamGB * 1024 / 2 -and $Ctx.System.RamGB -le 8) {
        New-D9Finding $Check warning (T-D9 'Файл підкачки обмежено до {0} МБ' $maxMB) (T-D9 'Для ПК з малим обсягом пам''яті це замало. Debora поверне автоматичний розмір (після перезавантаження).') (New-D9ActionsFix @(@{ type = 'registry'; path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; name = 'PagingFiles'; value = @('?:\pagefile.sys'); kind = 'MultiString' }) -Reboot) @($link)
    }
}

function Test-D9Commit {
    param($Check, $Ctx)
    $os = Get-CimInstance Win32_OperatingSystem
    $used = 100 - $os.FreeVirtualMemory * 100 / $os.TotalVirtualMemorySize
    if ($used -ge $Check.thresholds.percent) {
        New-D9Finding $Check warning (T-D9 'Виділено {0:N0}% віртуальної пам''яті' $used) (T-D9 'Ще трохи — і програми почнуть падати з помилкою «недостатньо пам''яті». Закрийте важкі програми, збільште файл підкачки або додайте оперативну пам''ять.') @{ type = 'manual' }
    }
}

# Хто навантажує процесор у фоні: два заміри з інтервалом
function Test-D9CpuHogs {
    param($Check, $Ctx)
    $ms = $Check.thresholds.sampleMs
    $first = @{}; Get-Process | ForEach-Object { try { $first[$_.Id] = $_.TotalProcessorTime.TotalMilliseconds } catch { } }
    Start-Sleep -Milliseconds $ms
    $cores = [Environment]::ProcessorCount
    $hogs = Get-Process | Where-Object { $_.Id -ne $PID -and $first.ContainsKey($_.Id) } | ForEach-Object {
        try { [pscustomobject]@{ Name = $_.ProcessName; Percent = ($_.TotalProcessorTime.TotalMilliseconds - $first[$_.Id]) * 100 / $ms / $cores } } catch { }
    } | Group-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Percent = ($_.Group | Measure-Object Percent -Sum).Sum } } |
        Where-Object { $_.Percent -ge $Check.thresholds.percent -and $_.Name -notin 'Idle', 'System', 'powershell', 'pwsh' } | Sort-Object Percent -Descending
    if ($hogs) {
        $list = ($hogs | Select-Object -First 5 | ForEach-Object { "{0} {1:N0}%" -f $_.Name, $_.Percent }) -join ', '
        New-D9Finding $Check warning (T-D9 'Процеси навантажують процесор у фоні: {0}' $list) (T-D9 'Якщо це не ваша активна програма — перевірте, що вона робить (Диспетчер завдань). Частий випадок: індексація, оновлення, антивірусна перевірка, майнер.') @{ type = 'manual' }
    }
}

function Test-D9ThirdPartyServices {
    param($Check, $Ctx)
    $services = @(Get-CimInstance Win32_Service -Filter "StartMode = 'Auto'" -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -and $_.PathName -notmatch '\\Windows\\(System32|SysWOW64|Microsoft\.NET)\\|\\Windows Defender\\|\\Microsoft\\' })
    $updaters = @($services | Where-Object { $_.Name -match 'update|updater|gupdate|edgeupdate|AdobeARM|Maintenance' -or $_.DisplayName -match 'Update' })
    if ($services.Count -ge $Check.thresholds.count) {
        New-D9Finding $Check suggestion (T-D9 'Сторонніх служб із автозапуском: {0}' $services.Count) (T-D9 'Кожна стартує разом із Windows. Перегляньте непотрібні (services.msc): {0}' (($services | Select-Object -First 12).DisplayName -join ', ')) @{ type = 'manual' } @((New-D9Link (T-D9 'Служби') 'services.msc')) -Key "$($Check.id):count"
    }
    if ($updaters.Count -ge 3) {
        New-D9Finding $Check suggestion (T-D9 'Служб-оновлювачів сторонніх програм: {0}' $updaters.Count) (T-D9 'Debora переведе їх на «Вручну» — програми оновлюватимуться, коли ви їх запускаєте: {0}' ($updaters.DisplayName -join ', ')) (New-D9ActionsFix @($updaters | ForEach-Object { @{ type = 'service'; name = $_.Name; startup = 'Manual' } })) @((New-D9Link (T-D9 'Служби') 'services.msc')) -Key "$($Check.id):updaters"
    }
}

function Test-D9LogonTasks {
    param($Check, $Ctx)
    $tasks = @()
    try {
        $stack = New-Object System.Collections.Stack; $stack.Push((Get-D9TaskService).GetFolder('\'))
        while ($stack.Count) {
            $folder = $stack.Pop()
            if ($folder.Path -like '\Microsoft*') { continue }
            foreach ($sub in $folder.GetFolders(0)) { $stack.Push($sub) }
            foreach ($t in $folder.GetTasks(0)) {
                if (-not $t.Enabled) { continue }
                try { $xml = [xml]$t.Xml } catch { continue }
                if ($xml.Task.Triggers.LogonTrigger -or $xml.Task.Triggers.BootTrigger) { $tasks += $t.Name }
            }
        }
    } catch { return New-D9Skip $Check (T-D9 'Планувальник завдань недоступний') }
    if ($tasks.Count -ge $Check.thresholds.count) {
        New-D9Finding $Check suggestion (T-D9 'Завдань, що запускаються при вході в систему: {0}' $tasks.Count) (T-D9 'Приховане автозавантаження через Планувальник: {0}' (($tasks | Select-Object -First 10) -join ', ')) @{ type = 'manual' } @((New-D9Link (T-D9 'Планувальник завдань') 'taskschd.msc'))
    }
}

function Test-D9ShellExtensions {
    param($Check, $Ctx)
    $keys = 'Registry::HKEY_CLASSES_ROOT\*\shellex\ContextMenuHandlers', 'Registry::HKEY_CLASSES_ROOT\Directory\shellex\ContextMenuHandlers', 'Registry::HKEY_CLASSES_ROOT\Folder\shellex\ContextMenuHandlers', 'Registry::HKEY_CLASSES_ROOT\Directory\Background\shellex\ContextMenuHandlers'
    $handlers = @($keys | ForEach-Object { Get-ChildItem -LiteralPath $_ -ErrorAction SilentlyContinue } | ForEach-Object {
        $clsid = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).'(default)'
        if (-not $clsid) { $clsid = $_.PSChildName }
        $dll = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\InprocServer32" -ErrorAction SilentlyContinue).'(default)'
        if ($dll -and $dll -notmatch '\\Windows\\') { $_.PSChildName }
    } | Sort-Object -Unique)
    if ($handlers.Count -ge $Check.thresholds.count) {
        New-D9Finding $Check suggestion (T-D9 'Сторонніх пунктів у контекстному меню: {0}' $handlers.Count) (T-D9 'Кожен сповільнює відкриття меню правої кнопки: {0}. Вимкніть непотрібні в налаштуваннях відповідних програм або видаліть програми.' ($handlers -join ', ')) @{ type = 'manual' }
    }
}

function Test-D9Fonts {
    param($Check, $Ctx)
    $count = @(Get-ChildItem "$env:SystemRoot\Fonts" -File -ErrorAction SilentlyContinue).Count + @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -File -ErrorAction SilentlyContinue).Count
    if ($count -ge $Check.thresholds.count) {
        New-D9Finding $Check suggestion (T-D9 'Встановлено {0} шрифтів' $count) (T-D9 'Тисячі шрифтів сповільнюють запуск програм (Office, Photoshop, браузери). Видаліть непотрібні колекції.') @{ type = 'manual' } @((New-D9Link (T-D9 'Шрифти') 'ms-settings:fonts'))
    }
}

function Test-D9DesktopItems {
    param($Check, $Ctx)
    $desktop = [Environment]::GetFolderPath('Desktop')
    $count = @(Get-ChildItem $desktop -Force -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini').Count
    if ($count -ge $Check.thresholds.count) {
        New-D9Finding $Check suggestion (T-D9 'На робочому столі {0} файлів і папок' $count) (T-D9 'Захаращений робочий стіл повільніше відмальовується й частіше потрапляє під синхронізацію. Розкладіть файли по папках «Документи» / «Завантаження».') @{ type = 'manual' }
    }
}

function Test-D9BrowserExtensions {
    param($Check, $Ctx)
    $local = $env:LOCALAPPDATA
    $found = foreach ($b in @(@('Chrome', "$local\Google\Chrome\User Data"), @('Edge', "$local\Microsoft\Edge\User Data"), @('Brave', "$local\BraveSoftware\Brave-Browser\User Data"))) {
        if (-not (Test-Path $b[1])) { continue }
        $n = @(Get-ChildItem $b[1] -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
            ForEach-Object { Get-ChildItem "$($_.FullName)\Extensions" -Directory -ErrorAction SilentlyContinue }).Count
        if ($n -ge $Check.thresholds.count) { "$($b[0]): $n" }
    }
    if ($found) {
        New-D9Finding $Check suggestion (T-D9 'Багато розширень у браузері ({0})' ($found -join ', ')) (T-D9 'Кожне розширення забирає пам''ять і може читати сторінки, які ви відкриваєте. Видаліть ті, якими не користуєтесь.') @{ type = 'manual' }
    }
}

function Test-D9PrintSpooler {
    param($Check, $Ctx)
    $svc = Get-D9ServiceState ([pscustomobject]@{ name = 'Spooler' })
    if (-not $svc.exists -or $svc.status -ne 'Running') { return }
    $real = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -notmatch '^(PORTPROMPT:|nul:|SHRFAX:|FILE:)' -and $_.Name -notmatch 'PDF|XPS|OneNote|Fax' })
    if (-not $real) {
        New-D9Finding $Check suggestion (T-D9 'Служба друку працює, хоча принтерів немає') (T-D9 'Debora переведе «Диспетчер черги друку» на «Вручну»: менше фонових процесів і закриті вразливості на кшталт PrintNightmare. Якщо підключите принтер — відкотіть у «Журналі змін».') (New-D9ActionsFix @(@{ type = 'service'; name = 'Spooler'; startup = 'Manual'; stop = $true })) @((New-D9Link (T-D9 'Служби') 'services.msc'))
    }
}

# ======================= Стабільність =======================

function Test-D9ServiceFailures {
    param($Check, $Ctx)
    $events = Get-D9Events @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = @(7000, 7009, 7023, 7031, 7034); StartTime = $Ctx.Now.AddDays(-$Check.thresholds.days) }
    if (-not $events) { return }
    # Вимкнені служби (зокрема вимкнені самим Debora) — не збій: Windows лише пише, що не змогла їх запустити
    $disabled = @{}
    foreach ($s in @(Get-CimInstance Win32_Service -Filter "StartMode = 'Disabled'" -ErrorAction SilentlyContinue)) { $disabled[$s.Name] = $true; $disabled[$s.DisplayName] = $true }
    $services = @($events | Where-Object { -not ($_.Id -eq 7000 -and [string]$_.Properties[1].Value -match '1058') } |
        ForEach-Object { [string]$_.Properties[0].Value } | Where-Object { -not $disabled.ContainsKey($_) } |
        Group-Object | Where-Object Count -ge $Check.thresholds.min | Sort-Object Count -Descending)
    if ($services) {
        New-D9Finding $Check suggestion (T-D9 'Служби, що регулярно падають або не запускаються: {0}' (($services | Select-Object -First 6 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', ')) (T-D9 'Зазвичай це залишки видалених програм або зламані драйвери. Перевстановіть відповідну програму або вимкніть службу.') @{ type = 'manual' } @((New-D9Link (T-D9 'Служби') 'services.msc'))
    }
}
