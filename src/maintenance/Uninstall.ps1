# Видалення встановлених програм (класичних, з розділу Uninstall реєстру).
# Спосіб — від найтихішого: QuietUninstallString → MSI (msiexec /x /qn) → Inno Setup (/VERYSILENT) →
# NSIS (/S) → звичайний деінсталятор з вікном. Після запуску перевіряємо, що запис справді зник.
# Відкату немає (повернути — встановити знову, наприклад з вкладки «Програми»), тому перед видаленням — точка відновлення.

$script:D9UninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
# Компоненти, від яких залежать інші програми — видаляти не радимо
$script:D9KeepPatterns = @('Microsoft Visual C++*', 'Microsoft .NET*', 'Microsoft Windows Desktop Runtime*', 'Microsoft ASP.NET*', 'Microsoft Edge WebView2*',
    'Microsoft Edge', 'Microsoft Update Health Tools', 'Windows SDK*', 'Windows Software Development Kit*', '*Driver*', '*Chipset*', 'Intel(R) Management Engine*',
    'Realtek*Audio*', 'NVIDIA Graphics Driver*', 'AMD Software*', 'Microsoft GameInput', 'DirectX*')

# Розбір командного рядка деінсталятора: шлях до exe (у лапках або з пробілами до «.exe») і аргументи
function Split-D9CommandLine {
    param([string]$CommandLine)
    $c = ([string]$CommandLine).Trim()
    if (-not $c) { return $null }
    if ($c -match '^"([^"]+)"\s*(.*)$') { return [pscustomobject]@{ File = $Matches[1]; Args = $Matches[2].Trim() } }
    if ($c -match '^(.+?\.exe)(\s+.*)?$') { return [pscustomobject]@{ File = $Matches[1]; Args = ([string]$Matches[2]).Trim() } }
    $parts = $c -split '\s+', 2
    [pscustomobject]@{ File = $parts[0]; Args = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
}

function Get-D9UninstallList {
    param($KnownBloat)
    if (-not $KnownBloat) { $KnownBloat = ConvertFrom-Json (Get-D9ConfigText 'known-bloat.json') }
    $seen = @{}
    foreach ($root in $script:D9UninstallRoots) {
        foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DisplayName -or $p.SystemComponent -eq 1 -or $p.ParentKeyName -or $p.ReleaseType -in 'Update', 'Hotfix', 'Security Update') { continue }
            if (-not $p.UninstallString -and -not $p.QuietUninstallString) { continue }
            $id = "$($p.DisplayName)|$($p.DisplayVersion)"
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $bloat = $KnownBloat.programs | Where-Object { $p.DisplayName -like $_.pattern } | Select-Object -First 1
            $keep = [bool]($script:D9KeepPatterns | Where-Object { $p.DisplayName -like $_ })
            $date = $null
            if ($p.InstallDate -match '^\d{8}$') { $date = try { [datetime]::ParseExact($p.InstallDate, 'yyyyMMdd', $null) } catch { $null } }
            [pscustomobject]@{
                Name = [string]$p.DisplayName; Version = [string]$p.DisplayVersion; Publisher = [string]$p.Publisher
                Size = $(if ($p.EstimatedSize) { [long]$p.EstimatedSize * 1KB } else { 0 }); InstallDate = $date
                Key = $k.PSPath; KeyName = $k.PSChildName
                UninstallString = [string]$p.UninstallString; QuietUninstallString = [string]$p.QuietUninstallString
                IsMsi = ($p.WindowsInstaller -eq 1 -and $k.PSChildName -match '^\{[0-9A-F-]{36}\}$')
                Bloat = $(if ($bloat) { Get-D9Text $bloat.reason } else { $null }); Keep = $keep
                Folder = (Get-D9ProgramFolder $p); SizeEstimated = $false
            }
        }
    }
}

# Список програм з доповненими даними: якщо в реєстрі немає розміру чи дати — рахуємо за папкою програми
# (лише коли папка належить одній програмі, щоб не приписати спільну папку виробника кільком записам).
function Get-D9UninstallListDetailed {
    param($KnownBloat)
    $list = @(Get-D9UninstallList -KnownBloat $KnownBloat)
    $byFolder = @{}
    foreach ($p in $list | Where-Object Folder) { $byFolder[$p.Folder] = 1 + [int]$byFolder[$p.Folder] }
    $cache = Get-D9ProgramSizeCache
    foreach ($p in $list) {
        if (-not $p.Folder -or $byFolder[$p.Folder] -gt 1) { continue }
        if (-not $p.Size) {
            $key = "$($p.Name)|$($p.Version)|$($p.Folder)"
            $hit = $cache.items.$key
            if ($hit -and ([datetime]$hit.time) -gt (Get-Date).AddDays(-14)) { $p.Size = [long]$hit.size }
            else {
                $p.Size = [long](Get-D9FolderSize $p.Folder 3000)
                $cache.items | Add-Member -NotePropertyName $key -NotePropertyValue ([pscustomobject]@{ size = $p.Size; time = (Get-Date).ToString('s') }) -Force
            }
            $p.SizeEstimated = $true
        }
        if (-not $p.InstallDate) { $p.InstallDate = try { (Get-Item -LiteralPath $p.Folder -ErrorAction Stop).CreationTime } catch { $null } }
    }
    Save-D9ProgramSizeCache $cache
    $list
}

function Get-D9ProgramSizeCachePath { Join-Path (Join-Path (Get-D9DataRoot) 'cache') 'program-sizes.json' }
function Get-D9ProgramSizeCache {
    $path = Get-D9ProgramSizeCachePath
    $c = try { ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) } catch { $null }
    if (-not $c -or -not $c.items) { $c = [pscustomobject]@{ items = [pscustomobject]@{} } }
    $c
}
function Save-D9ProgramSizeCache {
    param($Cache)
    try {
        $path = Get-D9ProgramSizeCachePath
        $dir = Split-Path $path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($path, (ConvertTo-Json $Cache -Depth 5 -Compress), (New-Object Text.UTF8Encoding $false))
    } catch { }   # кеш необов'язковий (наприклад, без прав на запис)
}

# Папки, які ніколи не вважаємо «папкою програми» (системні й загальні)
function Test-D9GenericFolder {
    param([string]$Path)
    $p = $Path.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { return $true }
    $generic = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA, $env:USERPROFILE, $env:PUBLIC,
                 (Join-Path $env:LOCALAPPDATA 'Programs'), (Join-Path $env:ProgramFiles 'Common Files'), (Join-Path $env:ProgramFiles 'WindowsApps')) | Where-Object { $_ }
    foreach ($g in $generic) { if ($p -ieq $g.TrimEnd('\')) { return $true } }
    if ($env:SystemRoot -and $p -like "$($env:SystemRoot.TrimEnd('\'))\*") { return $true }
    if ($p -match '(?i)\\(Package Cache|Installer|Temp|WindowsApps)(\\|$)') { return $true }
    return $false
}

# Папка програми: InstallLocation → папка значка → папка деінсталятора (без системних і загальних папок)
function Get-D9ProgramFolder {
    param([Parameter(Mandatory)]$Entry)
    $candidates = @()
    if ($Entry.InstallLocation) { $candidates += [string]$Entry.InstallLocation }
    if ($Entry.DisplayIcon) { $candidates += Split-Path ((([string]$Entry.DisplayIcon) -replace ',\s*-?\d+$', '').Trim('"', ' ')) -ErrorAction SilentlyContinue }
    $u = Split-D9CommandLine ([string]$Entry.UninstallString)
    if ($u -and $u.File -notmatch '(?i)msiexec') { $candidates += Split-Path $u.File -ErrorAction SilentlyContinue }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $path = [Environment]::ExpandEnvironmentVariables($c.Trim('"', ' ')).TrimEnd('\')
        # Значок і деінсталятор часто лежать у вкладеній папці (obs-studio\bin\64bit) — піднімаємось до кореня програми
        while ((Split-Path $path -Leaf) -match '^(?i)(bin|bin32|bin64|32bit|64bit|x64|x86|amd64|win32|win64|app|program|resources|uninstall|uninst)$' -and
               -not (Test-D9GenericFolder (Split-Path $path))) { $path = Split-Path $path }
        if ($path -notmatch '^[A-Za-z]:\\' -or (Test-D9GenericFolder $path)) { continue }
        if (Test-Path -LiteralPath $path -PathType Container) { return $path }
    }
    return $null
}

# Назва без версії й розрядності: «Notepad++ (64-bit x64)» → «Notepad++», «NVIDIA PhysX 9.23.1019» → «NVIDIA PhysX»
function Get-D9CleanProgramName {
    param([string]$Name)
    $n = $Name -replace '\s*\((x64|x86|64-bit|32-bit|64-bit x64|[^)]*bit[^)]*)\)', '' -replace '\s+v?\d+(\.\d+)+.*$', '' -replace '\s+(x64|x86|64-bit|32-bit)$', ''
    $n.Trim()
}

# Залишки після видалення: точні збіги назви програми (або «Видавець\Назва») у папках даних і розділах Software реєстру,
# а також папка програми, якщо деінсталятор її лишив. Повертає Type (folder|registry), Path, Size.
function Find-D9UninstallLeftovers {
    param([Parameter(Mandatory)]$Program, [object[]]$Remaining = @())
    $name = Get-D9CleanProgramName $Program.Name
    if ($name.Length -lt 3) { return }
    $publisher = (([string]$Program.Publisher) -replace '(?i),?\s*(Inc|LLC|Ltd|GmbH|Corp|Corporation|Co)\.?$', '').Trim()
    # Не чіпаємо те, що належить іншим встановленим програмам з тією ж назвою
    $taken = @{}
    foreach ($r in $Remaining) { $taken[(Get-D9CleanProgramName $r.Name).ToLower()] = $true; if ($r.Folder) { $taken[$r.Folder.ToLower()] = $true } }
    if ($taken.ContainsKey($name.ToLower())) { return }
    $rel = @($name); if ($publisher -and $publisher -ine $name) { $rel += "$publisher\$name" }
    $folders = @()
    if ($Program.Folder -and -not $taken.ContainsKey($Program.Folder.ToLower())) { $folders += $Program.Folder }
    foreach ($base in $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
        if ($base) { foreach ($r in $rel) { $folders += Join-Path $base $r } }
    }
    $otherFolders = @($Remaining | Where-Object Folder | ForEach-Object { $_.Folder.TrimEnd('\') + '\' })
    foreach ($f in $folders | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $f -PathType Container) -or (Test-D9GenericFolder $f)) { continue }
        # Усередині стоїть інша програма (наприклад, ігри в папці Steam) — не чіпаємо
        if (@($otherFolders | Where-Object { $_ -like "$($f.TrimEnd('\'))\*" }).Count) { Write-D9Log "  Пропущено $f — усередині інші встановлені програми" Detail; continue }
        $size = Get-D9FolderSize $f 3000
        if ($size -ge 2GB) { Write-D9Log "  Пропущено $f ($(Format-D9Size $size)) — завелика для автоматичного прибирання, перегляньте вручну" Detail; continue }
        [pscustomobject]@{ Type = 'folder'; Path = $f; Size = $size }
    }
    foreach ($hive in 'HKCU:\SOFTWARE', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node') {
        foreach ($r in $rel) {
            $k = "$hive\$r"
            if (Test-Path -LiteralPath $k) { [pscustomobject]@{ Type = 'registry'; Path = $k; Size = 0 } }
        }
    }
}

# Записи в реєстрі від уже видалених програм — лише те, що перевіряється напевно:
#   uninstall — запис у «Програмах і засобах», від якого не лишилось ні деінсталятора, ні папки програми;
#   apppath   — реєстрація exe в App Paths (запуск через Win+R за назвою), коли файлу вже немає.
function Get-D9OrphanRegistryEntries {
    foreach ($p in @(Get-D9UninstallList)) {
        $c = Get-D9UninstallCommand $p
        if ($c -and $c.Method -eq 'orphan') {
            [pscustomobject]@{ Kind = 'uninstall'; Name = $p.Name; Path = (ConvertTo-D9RegDrivePath $p.Key); Target = $c.File }
        }
    }
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths') {
        foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $v = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).'(default)'
            if (-not $v) { continue }
            $file = [Environment]::ExpandEnvironmentVariables(([string]$v).Trim().Trim('"'))
            if ($file -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $file)) {
                [pscustomobject]@{ Kind = 'apppath'; Name = $k.PSChildName; Path = "$root\$($k.PSChildName)"; Target = $file }
            }
        }
    }
}

# Крок обслуговування: прибрати такі записи (кожен — після резервної копії .reg)
function Clear-D9OrphanEntries {
    $items = @(Get-D9OrphanRegistryEntries)
    if (-not $items) { Write-D9Log 'Записів від видалених програм не знайдено.' Ok; return [pscustomobject]@{ Done = $true; RebootRecommended = $false } }
    Write-D9Log "Прибирання записів від видалених програм: $($items.Count)..."
    foreach ($i in $items) { Write-D9Log "  $($i.Name) → $($i.Target)" Detail }
    [void](Remove-D9UninstallLeftovers -Items @($items | ForEach-Object { [pscustomobject]@{ Type = 'registry'; Path = $_.Path; Size = 0 } }))
    [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

# Шлях провайдера реєстру (Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\...) → HKCU:\...
function ConvertTo-D9RegDrivePath {
    param([string]$Path)
    $p = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
    $p -replace '^HKEY_CURRENT_USER', 'HKCU:' -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
}

# Прибирає залишки: папки — у Кошик (можна відновити), розділи реєстру — після експорту в .reg (резервна копія в папці даних)
function Remove-D9UninstallLeftovers {
    param([Parameter(Mandatory)][object[]]$Items)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $backup = Join-Path (Join-Path (Get-D9DataRoot) 'uninstall-backup') (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    $done = 0; $i = 0
    foreach ($it in $Items) {
        try {
            if ($it.Type -eq 'folder') {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($it.Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
                Write-D9Log "  У Кошик: $($it.Path)" Detail
            } else {
                if (-not (Test-Path $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }
                $i++
                $regPath = $it.Path -replace '^HKCU:', 'HKEY_CURRENT_USER' -replace '^HKLM:', 'HKEY_LOCAL_MACHINE'
                $null = & reg.exe export $regPath (Join-Path $backup "$i.reg") /y 2>&1
                if ($LASTEXITCODE -ne 0) { throw 'не вдалося зберегти резервну копію — розділ не видалено' }
                $hive = if ($it.Path -like 'HKCU:*') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
                $hive.DeleteSubKeyTree(($it.Path -replace '^HK(CU|LM):\\', ''), $false)
                Write-D9Log "  Реєстр: $($it.Path) (копія: $backup)" Detail
            }
            $done++
        } catch { Write-D9Log "  Не вдалося прибрати $($it.Path): $($_.Exception.Message)" Warn }
    }
    Write-D9Log "Прибрано залишків: $done з $($Items.Count). Папки — у Кошику; розділи реєстру можна повернути з .reg у $backup" Ok
    [pscustomobject]@{ Removed = $done; Backup = $backup }
}

# Як видалити: File, Args, Silent (чи без вікон)
function Get-D9UninstallCommand {
    param([Parameter(Mandatory)]$Program)
    if ($Program.QuietUninstallString) {
        $c = Split-D9CommandLine $Program.QuietUninstallString
        return [pscustomobject]@{ File = $c.File; Args = $c.Args; Silent = $true; Method = 'quiet' }
    }
    $guid = if ($Program.IsMsi) { $Program.KeyName } elseif ($Program.UninstallString -match '(?i)msiexec(\.exe)?\s+/[IX]\s*(\{[0-9A-F-]{36}\})') { $Matches[2] } else { $null }
    if ($guid) { return [pscustomobject]@{ File = 'msiexec.exe'; Args = "/x $guid /qn /norestart"; Silent = $true; Method = 'msi' } }
    $c = Split-D9CommandLine $Program.UninstallString
    if (-not $c) { return $null }
    # Деінсталятора вже немає (програму видалили вручну, лишився запис) — прибираємо лише запис
    $file = [Environment]::ExpandEnvironmentVariables($c.File)
    if ($file -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $file)) {
        # Осиротілий — лише якщо зникла й папка (деінсталятора чи вказана InstallLocation); інакше програма ще на диску
        $dirs = @((Split-Path $file), [string]$Program.Folder) | Where-Object { $_ }
        $present = @($dirs | Where-Object { Test-Path -LiteralPath $_ })
        $method = if ($present) { 'missing' } else { 'orphan' }
        return [pscustomobject]@{ File = $file; Args = ''; Silent = $true; Method = $method }
    }
    $leaf = Split-Path $c.File -Leaf
    if ($leaf -match '(?i)^unins\d{3}\.exe$') { return [pscustomobject]@{ File = $c.File; Args = "$($c.Args) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART".Trim(); Silent = $true; Method = 'inno' } }
    if ($leaf -match '(?i)^(uninst|uninstall)[^\\]*\.exe$' -and $c.Args -notmatch '(?i)(^|\s)/S(\s|$)') { return [pscustomobject]@{ File = $c.File; Args = "$($c.Args) /S".Trim(); Silent = $true; Method = 'nsis' } }
    [pscustomobject]@{ File = $c.File; Args = $c.Args; Silent = $false; Method = 'interactive' }
}

# Видаляє по черзі. Результат: name, result (removed|reboot|stillPresent|failed), message
function Uninstall-D9Programs {
    param([Parameter(Mandatory)][object[]]$Programs, [int]$TimeoutMinutes = 15)
    $n = 0
    foreach ($prog in $Programs) {
        $n++
        if ($script:D9OnProgress) { & $script:D9OnProgress $n $Programs.Count $prog.Name }
        $cmd = Get-D9UninstallCommand $prog
        if (-not $cmd) { [pscustomobject]@{ name = $prog.Name; result = 'failed'; message = 'немає команди видалення' }; continue }
        Write-D9Log "[$n/$($Programs.Count)] Видалення $($prog.Name)$(if (-not $cmd.Silent) { ' — відкриється вікно деінсталятора, пройдіть його' })..."
        if ($cmd.Method -eq 'missing') {
            $text = 'деінсталятора немає, хоча файли програми на диску — видаліть її через лаунчер (Steam, EA, Ubisoft…) або її власним способом'
            Write-D9Log "  $($prog.Name): $text" Warn
            [pscustomobject]@{ name = $prog.Name; result = 'failed'; message = $text; leftovers = @() }
            continue
        }
        if ($cmd.Method -eq 'orphan') {
            Write-D9Log "  Деінсталятора $($cmd.File) уже немає — програму видалено раніше, прибираю лише її запис" Detail
            $r = Remove-D9UninstallLeftovers -Items @([pscustomobject]@{ Type = 'registry'; Path = (ConvertTo-D9RegDrivePath $prog.Key); Size = 0 })
            $gone = -not (Test-Path -LiteralPath $prog.Key)
            $text = if ($gone) { "прибрано запис (копія: $($r.Backup))" } else { 'не вдалося прибрати запис' }
            Write-D9Log "  $($prog.Name): $text" $(if ($gone) { 'Ok' } else { 'Warn' })
            [pscustomobject]@{ name = $prog.Name; result = $(if ($gone) { 'removed' } else { 'failed' }); message = $text; leftovers = @() }
            continue
        }
        $code = $null; $msg = $null
        try {
            # Порожній -ArgumentList Start-Process не приймає — передаємо аргументи лише коли вони є
            $sp = @{ FilePath = $cmd.File; PassThru = $true; ErrorAction = 'Stop'; WindowStyle = $(if ($cmd.Silent) { 'Hidden' } else { 'Normal' }) }
            if ($cmd.Args) { $sp.ArgumentList = $cmd.Args }
            $p = Start-Process @sp
            if (-not $p.WaitForExit($TimeoutMinutes * 60000)) { $msg = "не завершилось за $TimeoutMinutes хв" }
            else { $code = $p.ExitCode }
        } catch { $msg = $_.Exception.Message }
        Start-Sleep -Milliseconds 800   # деякі деінсталятори дочищають реєстр уже після виходу
        $gone = -not (Test-Path -LiteralPath $prog.Key)
        $result = if ($gone -and $code -eq 3010) { 'reboot' } elseif ($gone) { 'removed' } elseif ($msg) { 'failed' } else { 'stillPresent' }
        $text = @{ removed = 'видалено'; reboot = 'видалено, потрібне перезавантаження'; stillPresent = "не видалено (код $code; можливо, скасовано у вікні деінсталятора)"; failed = "помилка: $msg" }[$result]
        Write-D9Log "  $($prog.Name): $text" $(if ($result -in 'removed', 'reboot') { 'Ok' } else { 'Warn' })
        $left = @()
        if ($result -in 'removed', 'reboot') {
            $left = @(Find-D9UninstallLeftovers -Program $prog -Remaining @(Get-D9UninstallList))
            if ($left) { Write-D9Log "  Залишки після видалення: $($left.Count) (папки й розділи реєстру)" Detail }
        }
        [pscustomobject]@{ name = $prog.Name; result = $result; message = $text; leftovers = $left }
    }
}
