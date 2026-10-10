# Менеджер автозавантаження: програми з Run-ключів, папок «Автозавантаження» і завдань при вході.
# Вмикання/вимикання — так само, як у Диспетчері завдань (значення StartupApproved), тож Windows
# і Диспетчер завдань бачать той самий стан. Зміни йдуть через рушій: журнал і точний відкат.

$script:D9StartupApproved = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

# Розташування автозапуску: звідки читати і де Windows зберігає ознаку «вимкнено»
$script:D9StartupSources = @(
    @{ Kind = 'reg'; Hive = 'HKCU'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'Run'; Where = 'Реєстр (користувач)' }
    @{ Kind = 'reg'; Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'Run'; Where = 'Реєстр (усі користувачі)' }
    @{ Kind = 'reg'; Hive = 'HKLM'; Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'Run32'; Where = 'Реєстр (32-біт)' }
    @{ Kind = 'folder'; Hive = 'HKCU'; Folder = 'Startup'; Approved = 'StartupFolder'; Where = 'Папка автозавантаження' }
    @{ Kind = 'folder'; Hive = 'HKLM'; Folder = 'CommonStartup'; Approved = 'StartupFolder'; Where = 'Папка автозавантаження (усі)' }
)

# Шлях до exe з командного рядка (лапки, аргументи, змінні середовища)
function Get-D9CommandExe {
    param([string]$Command)
    if (-not $Command) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($c -match '^"([^"]+)"') { return $Matches[1] }
    if ($c -match '^(.+?\.(exe|cmd|bat|com|lnk|vbs|js|ps1))(\s|$)') { return $Matches[1] }
    return ($c -split '\s+')[0]
}

function Get-D9Publisher {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($v.CompanyName) { return $v.CompanyName.Trim() }
    } catch { }
    return $null
}

function Test-D9ApprovedDisabled {
    param($Bytes)
    return ($Bytes -is [byte[]] -and $Bytes.Length -and ($Bytes[0] -band 1))
}

# Порада для запису автозапуску з config/startup-known.json: Verdict (disable|optional|keep) і Reason
function Get-D9StartupAdvice {
    param([Parameter(Mandatory)]$Item, $Rules)
    if (-not $Rules) {
        if (-not $script:D9StartupRules) { $script:D9StartupRules = @((ConvertFrom-Json (Get-D9ConfigText 'startup-known.json')).rules) }
        $Rules = $script:D9StartupRules
    }
    $leaf = if ($Item.Exe) { Split-Path ([string]$Item.Exe) -Leaf } else { '' }
    foreach ($r in $Rules) {
        if (-not $r.name -and -not $r.exe) { continue }
        if ($r.name -and $Item.Name -notlike $r.name) { continue }
        if ($r.exe -and $leaf -notlike $r.exe -and [string]$Item.Exe -notlike $r.exe) { continue }
        return [pscustomobject]@{ Verdict = [string]$r.verdict; Reason = (Get-D9Text $r.reason) }
    }
    return $null
}

function Get-D9StartupItems {
    $items = New-Object System.Collections.ArrayList
    $shell = $null
    foreach ($s in $script:D9StartupSources) {
        $approved = Get-ItemProperty "$($s.Hive):\$script:D9StartupApproved\$($s.Approved)" -ErrorAction SilentlyContinue
        if ($s.Kind -eq 'reg') {
            $values = Get-ItemProperty "$($s.Hive):\$($s.Path)" -ErrorAction SilentlyContinue
            foreach ($p in @($values.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Value })) {
                $exe = Get-D9CommandExe "$($p.Value)"
                [void]$items.Add([pscustomobject]@{
                    Name = $p.Name; Command = "$($p.Value)"; Exe = $exe; Publisher = (Get-D9Publisher $exe)
                    Enabled = -not (Test-D9ApprovedDisabled $approved.($p.Name)); Where = (T-D9 $s.Where); Kind = 'reg'
                    ApprovedPath = "$($s.Hive):\$script:D9StartupApproved\$($s.Approved)"; ValueName = $p.Name; Missing = ($exe -and -not (Test-Path -LiteralPath $exe))
                })
            }
        } else {
            $dir = [Environment]::GetFolderPath($s.Folder)
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini')) {
                $target = $f.FullName
                if ($f.Extension -eq '.lnk') {
                    try { if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }; $target = $shell.CreateShortcut($f.FullName).TargetPath } catch { }
                }
                [void]$items.Add([pscustomobject]@{
                    Name = $f.BaseName; Command = $target; Exe = $target; Publisher = (Get-D9Publisher $target)
                    Enabled = -not (Test-D9ApprovedDisabled $approved.($f.Name)); Where = (T-D9 $s.Where); Kind = 'reg'
                    ApprovedPath = "$($s.Hive):\$script:D9StartupApproved\$($s.Approved)"; ValueName = $f.Name; Missing = ($target -and -not (Test-Path -LiteralPath $target))
                })
            }
        }
    }
    # Завдання Планувальника з тригером «при вході» або «при запуску» (крім Microsoft)
    try {
        $stack = New-Object System.Collections.Stack; $stack.Push((Get-D9TaskService).GetFolder('\'))
        while ($stack.Count) {
            $folder = $stack.Pop()
            if ($folder.Path -like '\Microsoft*') { continue }
            foreach ($sub in $folder.GetFolders(0)) { $stack.Push($sub) }
            foreach ($t in $folder.GetTasks(1)) {
                try { $xml = [xml]$t.Xml } catch { continue }
                if (-not ($xml.Task.Triggers.LogonTrigger -or $xml.Task.Triggers.BootTrigger)) { continue }
                $exec = @($xml.Task.Actions.Exec)[0]
                $exe = Get-D9CommandExe "$($exec.Command)"
                [void]$items.Add([pscustomobject]@{
                    Name = $t.Name; Command = "$($exec.Command) $($exec.Arguments)".Trim(); Exe = $exe; Publisher = (Get-D9Publisher $exe)
                    Enabled = [bool]$t.Enabled; Where = (T-D9 'Планувальник завдань'); Kind = 'task'
                    ApprovedPath = $null; ValueName = $t.Path; Missing = ($exe -and -not (Test-Path -LiteralPath $exe))
                })
            }
        }
    } catch { }
    foreach ($i in $items) {
        $a = Get-D9StartupAdvice $i
        $i | Add-Member -NotePropertyName Verdict -NotePropertyValue $(if ($a) { $a.Verdict } else { $null }) -Force
        $i | Add-Member -NotePropertyName Reason -NotePropertyValue $(if ($a) { $a.Reason } else { $null }) -Force
    }
    return @($items | Sort-Object @{ Expression = { -not $_.Enabled } }, Name)
}

# Дія для вмикання/вимикання пункту автозавантаження (виконується рушієм — з журналом і відкатом)
function New-D9StartupAction {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][bool]$Enable)
    if ($Item.Kind -eq 'task') {
        return [pscustomobject]@{ type = 'scheduledTask'; path = $Item.ValueName; state = $(if ($Enable) { 'Enabled' } else { 'Disabled' }) }
    }
    # 02… — увімкнено, 03… — вимкнено (як записує Диспетчер завдань)
    $first = if ($Enable) { 2 } else { 3 }
    [pscustomobject]@{ type = 'registry'; path = $Item.ApprovedPath; name = $Item.ValueName; kind = 'Binary'; value = @($first, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
}

function New-D9StartupCatalog {
    param([Parameter(Mandatory)][object[]]$Changes)   # @{ Item; Enable }
    $i = 0
    $tweaks = foreach ($c in $Changes) {
        $i++
        $verb = if ($c.Enable) { 'Увімкнути' } else { 'Вимкнути' }
        [pscustomobject]@{
            id = ('startup.{0:d2}' -f $i); category = 'performance'; risk = 'safe'
            name = [pscustomobject]@{ uk = "$verb автозапуск: $($c.Item.Name)"; en = "$(if ($c.Enable) { 'Enable' } else { 'Disable' }) startup: $($c.Item.Name)" }
            description = [pscustomobject]@{ uk = $c.Item.Command; en = $c.Item.Command }
            actions = @(New-D9StartupAction $c.Item $c.Enable)
        }
    }
    [pscustomobject]@{ Tweaks = @($tweaks); Presets = @() }
}
