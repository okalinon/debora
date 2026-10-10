# Автоматичне обслуговування за розкладом: завдання Планувальника запускає Debloater9 -Maintain
# раз на тиждень (точка відновлення → очищення → бази Захисника → програми → драйвери → [оновлення Windows]
# → швидке сканування → сповіщення з підсумком). Копія програми лежить у %ProgramData%\Debloater9\app,
# доступ на запис — лише SYSTEM і адміністраторам (завдання працює з правами адміністратора).

$script:D9TaskName = 'Debloater9 Maintenance'
$script:D9MaintenanceSteps = [ordered]@{
    cleanup       = 'Очищення диска (тимчасові файли, кеш оновлень, залишки інсталяторів)'
    defender      = 'Антивірусні бази Захисника'
    apps          = 'Оновлення програм (winget)'
    drivers       = 'Новіші драйвери (каталог Microsoft, лише рекомендовані)'
    windowsUpdate = 'Оновлення Windows'
}

function Get-D9MaintenanceConfigPath { Join-Path (Get-D9DataRoot) 'maintenance.json' }

function Get-D9MaintenanceConfig {
    $cfg = [ordered]@{ Steps = @('cleanup', 'defender', 'apps', 'drivers'); Day = 'Sunday'; Time = '12:00' }
    $path = Get-D9MaintenanceConfigPath
    if (Test-Path $path) {
        try {
            $saved = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
            if ($null -ne $saved.Steps) { $cfg.Steps = @($saved.Steps | Where-Object { $script:D9MaintenanceSteps.Contains([string]$_) }) }
            if ($saved.Day) { $cfg.Day = [string]$saved.Day }
            if ($saved.Time -match '^\d{1,2}:\d{2}$') { $cfg.Time = [string]$saved.Time }
        } catch { }
    }
    [pscustomobject]$cfg
}

function Save-D9MaintenanceConfig {
    param([Parameter(Mandatory)]$Config)
    $dir = Split-Path (Get-D9MaintenanceConfigPath)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText((Get-D9MaintenanceConfigPath), (ConvertTo-Json $Config), (New-Object Text.UTF8Encoding $false))
}

# ---------- Виконання ----------

function Invoke-D9MaintenanceStep {
    param([Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo)
    switch ($Step) {
        'cleanup' {
            $before = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'").FreeSpace
            $ids = 'cleanup.temp', 'cleanup.update-cache', 'cleanup.leftovers', 'cleanup.do-cache'
            $cat = [pscustomobject]@{ Tweaks = @($Catalog.Tweaks | Where-Object { $ids -contains $_.id }); Presets = @() }
            [void](Invoke-D9Plan -Plan (New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo $SystemInfo) -SystemInfo $SystemInfo -Selection 'автообслуговування: очищення' -NoRestorePoint)
            $freed = [math]::Max(0, (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'").FreeSpace - $before)
            return "звільнено $(Format-D9Size $freed)"
        }
        'defender' { [void](Invoke-D9DefenderRepair); return 'бази оновлено' }
        'apps' {
            if (-not (Get-D9WingetPath)) { return 'winget не встановлено — пропущено' }
            $up = @(Get-D9AppUpgrades)
            if (-not $up) { return 'усі програми актуальні' }
            $r = Invoke-D9AppUpgradeAll
            return "оновлено програм: $($up.Count)$(if ($r.Result -notin 'installed', 'upToDate') { ' (частину — ні)' })"
        }
        'drivers' {
            $r = Invoke-D9DriverAutoUpdate -SystemInfo $SystemInfo -Folder (Join-Path (Get-D9DataRoot) 'driver-downloads') -NoRestorePoint
            $ok = if ($r.Session) { @($r.Session.entries | Where-Object result -eq 'ok').Count } else { 0 }
            return $(if ($ok) { "встановлено драйверів: $ok (потрібне перезавантаження)" } else { 'драйвери актуальні' })
        }
        'windowsUpdate' {
            $r = Install-D9WindowsUpdates
            return "встановлено оновлень: $($r.Installed)$(if ($r.RebootRecommended) { ' (потрібне перезавантаження)' })"
        }
        default { throw "Невідомий крок обслуговування: $Step" }
    }
}

# Повний прогін. Кожен крок окремо: збій одного не зупиняє решту. Підсумок — у maintenance-last.json.
function Invoke-D9Maintenance {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo, [string[]]$Steps, [switch]$NoScan)
    if (-not $Steps) { $Steps = @((Get-D9MaintenanceConfig).Steps) }
    $started = Get-Date
    Write-D9Log "Автоматичне обслуговування: $($Steps -join ', ')"
    $rp = New-D9RestorePoint
    $results = foreach ($s in $Steps) {
        Write-D9Log "— $($script:D9MaintenanceSteps[$s])"
        try { $text = Invoke-D9MaintenanceStep -Step $s -Catalog $Catalog -SystemInfo $SystemInfo; [pscustomobject]@{ step = $s; ok = $true; text = [string]$text } }
        catch { Write-D9Log "  Помилка: $($_.Exception.Message)" Error; [pscustomobject]@{ step = $s; ok = $false; text = $_.Exception.Message } }
    }
    $score = $null; $critical = 0
    if (-not $NoScan) {
        try {
            $scan = Invoke-D9Scan -Context (New-D9ScanContext -Catalog $Catalog -SystemInfo $SystemInfo)
            [void](Save-D9Scan $scan)
            $score = $scan.score.overall; $critical = @($scan.findings | Where-Object severity -eq 'critical').Count
        } catch { Write-D9Log "Сканування не вдалося: $($_.Exception.Message)" Warn }
    }
    $summary = [pscustomobject]@{
        started = $started.ToString('s'); finished = (Get-Date).ToString('s'); restorePoint = [bool]$rp
        results = @($results); score = $score; critical = $critical
        reboot = [bool](@($results | Where-Object { $_.text -match 'перезавантаж' }))
    }
    $root = Get-D9DataRoot
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path $root 'maintenance-last.json'), (ConvertTo-Json $summary -Depth 5), (New-Object Text.UTF8Encoding $false))
    Write-D9Log "Обслуговування завершено: $((@($results | ForEach-Object { "$($script:D9MaintenanceSteps[$_.step].Split(' ')[0]): $($_.text)" })) -join '; ')" Ok
    return $summary
}

function Get-D9MaintenanceLast {
    $path = Join-Path (Get-D9DataRoot) 'maintenance-last.json'
    if (-not (Test-Path $path)) { return $null }
    try { ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) } catch { $null }
}

# Коротке сповіщення Windows (у центрі сповіщень). Тихо пропускається, якщо недоступне.
function Show-D9Toast {
    param([string]$Title, [string]$Text)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$([Security.SecurityElement]::Escape($Title))</text><text>$([Security.SecurityElement]::Escape($Text))</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
    } catch { }
}

function Format-D9MaintenanceSummary {
    param([Parameter(Mandatory)]$Summary)
    $parts = @($Summary.results | ForEach-Object { if ($_.ok) { $_.text } else { "$($_.step): помилка" } })
    $text = $parts -join '; '
    if ($null -ne $Summary.score) { $text += ". Оцінка: $($Summary.score)/100" }
    if ($Summary.critical) { $text += ", критичних проблем: $($Summary.critical) — відкрийте Debloater9" }
    if ($Summary.reboot) { $text += '. Перезавантажте ПК' }
    return $text
}

# ---------- Розклад ----------

# Копія програми в захищену папку: інакше звичайний користувач міг би підмінити скрипт, який запускається з правами адміністратора
function Install-D9AppCopy {
    param([Parameter(Mandatory)][string]$SourceScript)
    $dir = Join-Path (Get-D9DataRoot) 'app'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $dst = Join-Path $dir 'Debloater9.ps1'
    Copy-Item -LiteralPath $SourceScript -Destination $dst -Force
    # Спершу копія, потім замок: SYSTEM і адміністратори — повний доступ, користувачі — лише читання (успадковується файлом)
    $out = & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Не вдалося захистити папку програми: $out" }
    return $dst
}

function Get-D9MaintenanceTaskCommand {
    param([Parameter(Mandatory)][string]$Script)
    @{ Execute = 'powershell.exe'; Argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`" -Maintain" }
}

# Реєструє (або оновлює) щотижневе завдання від імені поточного користувача з найвищими правами.
function Register-D9MaintenanceTask {
    param([Parameter(Mandatory)][string]$SourceScript, [Parameter(Mandatory)]$Config)
    Save-D9MaintenanceConfig $Config
    $script = Install-D9AppCopy -SourceScript $SourceScript
    $cmd = Get-D9MaintenanceTaskCommand $script
    $action = New-ScheduledTaskAction -Execute $cmd.Execute -Argument $cmd.Argument
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Config.Day -At ([datetime]::ParseExact($Config.Time, 'H:mm', $null))
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Debloater9: щотижневе обслуговування (очищення, оновлення програм, драйверів і баз Захисника). Вимкнути — у Debloater9 → Обслуговування.'
    [void](Register-ScheduledTask -TaskName $script:D9TaskName -InputObject $task -Force)
    Write-D9Log "Розклад: щотижня, $($Config.Day) о $($Config.Time). Кроки: $($Config.Steps -join ', ')" Ok
}

function Unregister-D9MaintenanceTask {
    if (Get-ScheduledTask -TaskName $script:D9TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:D9TaskName -Confirm:$false
        Write-D9Log 'Автоматичне обслуговування вимкнено.' Ok
    }
}

function Get-D9MaintenanceTask {
    $t = Get-ScheduledTask -TaskName $script:D9TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $info = Get-ScheduledTaskInfo -TaskName $script:D9TaskName -ErrorAction SilentlyContinue
    [pscustomobject]@{
        State   = [string]$t.State
        LastRun = $(if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime } else { $null })
        NextRun = $info.NextRunTime
        Result  = $info.LastTaskResult
    }
}
