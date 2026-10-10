# Графічний інтерфейс (WPF). Розмітка — MainWindow.xaml; уся робота виконується тими самими
# функціями ядра у фоновому runspace, щоб вікно не зависало.

$script:D9UiDir = $null

function Get-D9UiText {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:D9Embedded -and $script:D9Embedded.ContainsKey($Name)) { return $script:D9Embedded[$Name] }
    return [IO.File]::ReadAllText((Join-Path $script:D9UiDir $Name), [Text.Encoding]::UTF8)
}

function Initialize-D9GuiTypes {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    if ('D9Row' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System.ComponentModel;
public class D9Link { public string Label { get; set; } public string Url { get; set; } }
// Універсальний рядок для списків і таблиць інтерфейсу
public class D9Row : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void On(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    bool selected; bool enabled; string status; string note; string kind; string color;
    public bool Selected { get { return selected; } set { selected = value; On("Selected"); } }
    public bool Enabled { get { return enabled; } set { enabled = value; On("Enabled"); } }
    public int Number { get; set; }
    public string Id { get; set; }
    public string Title { get; set; }
    public string Detail { get; set; }
    public string Badge { get; set; }
    public string Group { get; set; }
    public string Status { get { return status; } set { status = value; On("Status"); } }
    public string Note { get { return note; } set { note = value; On("Note"); } }
    public string Kind { get { return kind; } set { kind = value; On("Kind"); } }
    public string Color { get { return color; } set { color = value; On("Color"); } }
    public object Links { get; set; }
    public object Tag { get; set; }
}
'@
}

function New-D9Row {
    param([hashtable]$Props)
    $row = New-Object D9Row
    $row.Enabled = $true
    foreach ($k in $Props.Keys) { $row.$k = $Props[$k] }
    return $row
}

# Списки для WPF — лише самі об'єкти, без обгорток PSObject: інакше прив'язка не бачить INotifyPropertyChanged
# і програмні зміни (галочки «Зняти все», статуси) не з'являються на екрані.
function Set-D9Items {
    param($Control, $Items)
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($i in @($Items)) { if ($null -ne $i) { $list.Add($i.psobject.BaseObject) } }
    $Control.ItemsSource = $list
}

function ConvertTo-D9UiLinks {
    param([object[]]$Links)
    $list = New-Object 'System.Collections.Generic.List[D9Link]'
    foreach ($l in @($Links | Where-Object { $_ -and $_.url })) { $list.Add((New-Object D9Link -Property @{ Label = $l.label; Url = $l.url })) }
    return , $list
}

$script:D9SevUi = @{
    critical   = @{ Badge = '✖'; Color = '#C62828'; Name = 'критично' }
    warning    = @{ Badge = '!'; Color = '#B26A00'; Name = 'варто виправити' }
    suggestion = @{ Badge = '•'; Color = '#1565C0'; Name = 'порада' }
    info       = @{ Badge = 'i'; Color = '#5D6675'; Name = 'відомості' }
}

# Вікно з текстом і кнопками «Так/Ні» (для попереднього перегляду змін)
function Show-D9TextDialog {
    param($Owner, [string]$Title, [string]$Header, [string]$Text, [string]$OkText = 'Застосувати', [switch]$InfoOnly)
    $w = New-Object Windows.Window
    $w.Title = $Title; $w.Width = 820; $w.Height = 600; $w.Owner = $Owner
    $w.WindowStartupLocation = 'CenterOwner'; $w.FontFamily = 'Segoe UI'; $w.FontSize = 13
    $dock = New-Object Windows.Controls.DockPanel; $dock.Margin = '16'
    $h = New-Object Windows.Controls.TextBlock; $h.Text = $Header; $h.TextWrapping = 'Wrap'; $h.FontWeight = 'SemiBold'; $h.Margin = '0,0,0,10'
    [Windows.Controls.DockPanel]::SetDock($h, 'Top'); [void]$dock.Children.Add($h)
    $buttons = New-Object Windows.Controls.StackPanel; $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'; $buttons.Margin = '0,10,0,0'
    [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom'); [void]$dock.Children.Add($buttons)
    $box = New-Object Windows.Controls.TextBox; $box.Text = $Text; $box.IsReadOnly = $true; $box.FontFamily = 'Consolas'; $box.FontSize = 12
    $box.VerticalScrollBarVisibility = 'Auto'; $box.HorizontalScrollBarVisibility = 'Auto'
    [void]$dock.Children.Add($box)
    $ok = New-Object Windows.Controls.Button; $ok.Content = $(if ($InfoOnly) { 'Закрити' } else { $OkText }); $ok.Padding = '16,6'; $ok.Margin = '0,0,8,0'; $ok.IsDefault = $true
    $ok.Add_Click({ $w.DialogResult = $true })
    [void]$buttons.Children.Add($ok)
    if (-not $InfoOnly) {
        $cancel = New-Object Windows.Controls.Button; $cancel.Content = 'Скасувати'; $cancel.Padding = '16,6'; $cancel.IsCancel = $true
        [void]$buttons.Children.Add($cancel)
    }
    $w.Content = $dock
    return [bool]$w.ShowDialog()
}

function Show-D9Gui {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$SystemInfo,
        [Parameter(Mandatory)]$Recommendation,
        [Parameter(Mandatory)][string]$ReportDir,
        [Parameter(Mandatory)][string]$DriverDir,
        # Для тестів: виконується всередині функції замість показу вікна (доступ до $ui, $state, $fill…)
        [scriptblock]$TestAction
    )
    Initialize-D9GuiTypes
    $win = [Windows.Markup.XamlReader]::Parse((Get-D9UiText 'MainWindow.xaml'))
    $ui = @{}
    foreach ($n in 'TitleText', 'SystemLine', 'AdminBadge', 'StatusText', 'Progress', 'LogBox', 'LogExpander', 'Tabs',
                   'BtnScan', 'BtnDeepScan', 'BtnOpenReport', 'ScoreText', 'VerdictText', 'CountsText', 'CategoryList', 'FindingsList',
                   'BtnRunAuto', 'BtnMarkDone', 'BtnRecheck', 'BtnReboot', 'ChecklistSummary', 'ChecklistList',
                   'PresetBox', 'BtnSelectPreset', 'BtnSelectNone', 'BtnPreview', 'BtnApply', 'TweaksSummary', 'TweakGrid',
                   'BtnDriverScan', 'BtnOemPage', 'OemText', 'DriverProblemsList', 'DriverFolder', 'BtnBrowse', 'BtnFindDrivers',
                   'DriverPackageGrid', 'BtnInstallDrivers', 'DriverInstalledGrid', 'BtnDriverOnline', 'BtnDriverOnlineInstall', 'DriverOnlineGrid', 'BtnOemTool',
                   'BtnUndo', 'BtnRefreshSessions', 'BtnSystemRestore', 'BtnDiagnostics', 'SessionGrid',
                   'AppSearch', 'BtnAppsInstall', 'BtnAppsRefresh', 'BtnAppsUpgrade', 'AppsSummary', 'BtnWingetStore', 'AppGrid',
                   'BtnStartupApply', 'BtnStartupRefresh', 'StartupSummary', 'StartupGrid',
                   'BtnRestorePoint', 'BtnCleanNow', 'BtnRepair', 'BtnNetReset', 'BtnWuReset', 'PauseDays', 'BtnPause', 'BtnResume', 'PauseState', 'BtnWuDrivers', 'WuDriversState') {
        $ui[$n] = $win.FindName($n)
        if (-not $ui[$n]) { throw "У розмітці немає елемента $n" }
    }
    $isAdmin = Test-D9IsAdmin
    $state = @{ Job = $null; Scan = $null; Checklist = $null; ReportPath = $null; Categories = $null; Oem = $null; Packages = $null; TweakRows = $null }
    $actionButtons = @('BtnScan', 'BtnDeepScan', 'BtnRunAuto', 'BtnMarkDone', 'BtnRecheck', 'BtnApply', 'BtnPreview', 'BtnDriverScan', 'BtnFindDrivers', 'BtnInstallDrivers', 'BtnUndo',
                       'BtnStartupApply', 'BtnStartupRefresh', 'BtnRestorePoint', 'BtnCleanNow', 'BtnRepair', 'BtnNetReset', 'BtnWuReset', 'BtnPause', 'BtnResume', 'BtnWuDrivers', 'BtnDiagnostics',
                       'BtnAppsInstall', 'BtnAppsRefresh', 'BtnAppsUpgrade', 'BtnDriverOnline', 'BtnDriverOnlineInstall', 'BtnOemTool')

    # ---------- шапка ----------
    $s = $SystemInfo
    $disk = @{ hdd = 'HDD'; ssd = 'SSD'; nvme = 'NVMe SSD'; unknown = 'диск не визначено' }[[string]$s.SystemDisk]
    $ui.TitleText.Text = "Debloater9 $script:D9Version"
    $ui.SystemLine.Text = "$($s.Manufacturer) $($s.Model) · $($s.OsName) $($s.DisplayVersion) · $($s.Cpu) · $($s.RamGB) ГБ · $disk · профіль: $($Recommendation.Preset)"
    if ($isAdmin) { $ui.AdminBadge.Text = 'Адміністратор'; $ui.AdminBadge.Foreground = '#2E7D32' }
    else { $ui.AdminBadge.Text = 'Без прав адміністратора — лише перегляд'; $ui.AdminBadge.Foreground = '#B26A00' }
    $ui.DriverFolder.Text = $DriverDir

    # ---------- фонове виконання ----------
    $sync = [hashtable]::Synchronized(@{ Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Progress = $null })
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in (Get-ChildItem function: | Where-Object { $_.Name -like '*-D9*' })) {
        $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry $f.Name, $f.Definition))
    }
    foreach ($v in (Get-Variable -Scope Script -Name 'D9*' -ErrorAction SilentlyContinue)) {
        $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry $v.Name, $v.Value, ''))
    }
    $prelude = @'
param($sync, $work, $arg)
$global:D9Sync = $sync
$global:D9OnLog = { param($Message, $Level) $global:D9Sync.Log.Enqueue("$Level|$Message") }
$global:D9OnProgress = { param($n, $total, $name) $global:D9Sync.Progress = @($n, $total, $name) }
try { $r = & ([scriptblock]::Create($work)) $arg; , @{ ok = $true; result = $r } }
catch { , @{ ok = $false; error = $_.Exception.Message } }
'@
    $setBusy = {
        param([bool]$busy, [string]$text)
        foreach ($b in $actionButtons) { $ui[$b].IsEnabled = -not $busy }
        $ui.Progress.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
        $ui.Progress.IsIndeterminate = $true
        $ui.StatusText.Text = if ($text) { $text } elseif ($busy) { 'Виконується…' } else { 'Готово' }
        if (-not $busy) {
            $ui.BtnInstallDrivers.IsEnabled = [bool]$state.Packages
            $ui.BtnDriverOnlineInstall.IsEnabled = [bool]$state.OnlineCands
            $ui.BtnOpenReport.IsEnabled = [bool]$state.ReportPath
        }
    }
    # $Done викликається з таймера, коли обробник кнопки вже завершився: блоки коду PowerShell не є замиканнями,
    # тож локальні змінні обробника там недоступні. Усе потрібне передавайте через $Context — він приходить
    # у $Done другим параметром.
    $startJob = {
        param([string]$Title, [scriptblock]$Work, $Arg, [scriptblock]$Done, $Context)
        if ($state.Job) { return }
        & $setBusy $true $Title
        $sync.Progress = $null
        $rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($prelude).AddArgument($sync).AddArgument($Work.ToString()).AddArgument($Arg)
        $state.Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Done = $Done; Title = $Title; Context = $Context }
    }
    $log = { param([string]$text) $ui.LogBox.AppendText("$text`r`n"); $ui.LogBox.ScrollToEnd() }
    $needAdmin = {
        if ($isAdmin) { return $true }
        [void][Windows.MessageBox]::Show($win, 'Для змін потрібні права адміністратора. Закрийте програму й запустіть її через run.bat.', 'Debloater9', 'OK', 'Warning')
        return $false
    }

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $onTick = {
        $line = $null
        while ($sync.Log.TryDequeue([ref]$line)) {
            $level, $msg = $line -split '\|', 2
            & $log $msg
            if ($level -in 'Error', 'Warn') { $ui.LogExpander.IsExpanded = $true }
        }
        if ($sync.Progress) {
            $n, $total, $name = $sync.Progress
            $ui.Progress.IsIndeterminate = $false; $ui.Progress.Maximum = $total; $ui.Progress.Value = $n
            $ui.StatusText.Text = "$($state.Job.Title) $n / ${total}: $name"
        }
        $job = $state.Job
        if ($job -and $job.Handle.IsCompleted) {
            $out = $null
            try { $out = $job.PS.EndInvoke($job.Handle) } catch { $out = @(@{ ok = $false; error = $_.Exception.Message }) }
            $job.PS.Dispose(); $job.RS.Dispose()
            $state.Job = $null
            & $setBusy $false $null
            $res = @($out)[0]
            if (-not $res.ok) {
                & $log "ПОМИЛКА: $($res.error)"
                $ui.LogExpander.IsExpanded = $true
                [void][Windows.MessageBox]::Show($win, "Не вдалося виконати: $($res.error)", 'Debloater9', 'OK', 'Error')
            } elseif ($job.Done) {
                try { & $job.Done $res.result $job.Context } catch { & $log "ПОМИЛКА інтерфейсу: $($_.Exception.Message)" }
            }
        }
    }
    $timer.Add_Tick($onTick)

    # Клік по будь-якому посиланню в списках
    $win.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($sender, $e)
        $b = $e.OriginalSource
        if ($b -is [Windows.Controls.Button] -and $b.Tag -is [string] -and $b.Tag) {
            try { Start-Process $b.Tag } catch { & $log "Не вдалося відкрити $($b.Tag): $($_.Exception.Message)" }
        }
    })

    # ---------- заповнення вкладок ----------
    $fillOverview = {
        param($scan, $categories)
        $color = @{ good = '#2E7D32'; attention = '#B26A00'; serious = '#C62828' }[$scan.score.verdict]
        $ui.ScoreText.Text = "$($scan.score.overall)"; $ui.ScoreText.Foreground = $color
        $ui.VerdictText.Text = @{ good = 'Добрий стан'; attention = 'Потребує уваги'; serious = 'Є серйозні проблеми' }[$scan.score.verdict]
        $ui.VerdictText.Foreground = $color
        $counts = foreach ($k in 'critical', 'warning', 'suggestion') { $n = @($scan.findings | Where-Object severity -eq $k).Count; if ($n) { "$n $($script:D9SevUi[$k].Name)" } }
        $ui.CountsText.Text = "$(($counts) -join ' · ')`nПеревірок: $(@($scan.checks).Count), $($scan.durationSec) с, $(([datetime]$scan.time).ToString('dd.MM.yyyy HH:mm'))"
        $cats = foreach ($c in $categories) {
            $v = $scan.score.categories.($c.id)
            if ($null -eq $v) { continue }
            New-D9Row @{ Title = (Get-D9Text $c.name); Number = [int]$v; Status = "$v"; Color = $(if ($v -ge 85) { '#2E7D32' } elseif ($v -ge 60) { '#E0A100' } else { '#C62828' }) }
        }
        Set-D9Items $ui.CategoryList @($cats)
        Set-D9Items $ui.FindingsList @(foreach ($f in $scan.findings) {
            $st = $script:D9SevUi[[string]$f.severity]
            New-D9Row @{ Badge = $st.Badge; Color = $st.Color; Title = $f.title; Detail = $f.details; Links = (ConvertTo-D9UiLinks $f.links) }
        })
    }
    $fillChecklist = {
        param($list)
        $state.Checklist = $list
        $items = @($list.items)
        if (-not $items) { $ui.ChecklistSummary.Text = 'Чекліст порожній — нічого робити не потрібно.'; $ui.ChecklistList.ItemsSource = $null; return }
        $done = @($items | Where-Object status -eq 'done').Count
        $autoLeft = @($items | Where-Object { $_.auto -and $_.status -ne 'done' }).Count
        $ui.ChecklistSummary.Text = "Виконано $done з $($items.Count). Автоматичних кроків залишилось: $autoLeft. Ручні кроки описані з посиланнями; виконавши такий крок, позначте його або натисніть «Перевірити ще раз»."
        Set-D9Items $ui.ChecklistList @(foreach ($i in $items) {
            $deps = @($i.dependsOn | ForEach-Object { $id = $_; ($items | Where-Object id -eq $id).number } | Where-Object { $_ } | Sort-Object)
            $detail = "$($i.why)"
            if ($deps -and $i.status -ne 'done') { $detail += "  (після кроку $($deps -join ', '))" }
            $kind = if ($i.status -eq 'done') { 'виконано' } elseif ($i.auto) { 'автоматично' } else { 'вручну' }
            New-D9Row @{ Selected = ($i.status -eq 'done'); Title = "$($i.number). $($i.title)"; Detail = $detail; Kind = $kind
                         Color = $(if ($i.status -eq 'done') { '#2E7D32' } elseif ($i.auto) { '#2563EB' } else { '#B26A00' })
                         Note = $(if ($i.note) { "$($i.note)" } else { '' }); Links = (ConvertTo-D9UiLinks $i.links); Tag = $i }
        })
    }
    $catNames = @{ privacy = 'Конфіденційність'; apps = 'Застосунки'; ui = 'Інтерфейс'; performance = 'Швидкодія'; gaming = 'Ігри'; cleanup = 'Очищення'; updates = 'Оновлення'; safety = 'Безпека' }
    $riskUi = @{ safe = @('безпечно', '#2E7D32'); moderate = @('помірно', '#B26A00'); expert = @('експертний', '#C62828') }
    $stateNames = @{ applied = 'застосовано'; partial = 'частково'; notApplied = 'ні'; notApplicable = 'не підходить'; unknown = '—' }
    $fillTweaks = {
        param($states)
        $preset = Get-D9Preset $Catalog $Recommendation.Preset
        $rows = foreach ($t in $Catalog.Tweaks) {
            $st = $states | Where-Object Id -eq $t.id | Select-Object -First 1
            $applicable = $st.State -ne 'notApplicable'
            $note = @()
            if ($st.Reason) { $note += $st.Reason }
            if ($t.irreversible) { $note += 'не відкочується' }
            if ($t.rebootRequired) { $note += 'потрібне перезавантаження' }
            New-D9Row @{ Id = $t.id; Title = (Get-D9Text $t.name); Detail = (Get-D9Text $t.description); Group = $catNames[[string]$t.category]
                         Kind = $riskUi[[string]$t.risk][0]; Color = $riskUi[[string]$t.risk][1]; Status = $stateNames[[string]$st.State]
                         Note = ($note -join '; '); Enabled = $applicable
                         Selected = ($applicable -and @($preset.tweaks) -contains $t.id -and $st.State -ne 'applied') }
        }
        $state.TweakRows = @($rows)
        Set-D9Items $ui.TweakGrid $state.TweakRows
        $applied = @($states | Where-Object State -eq 'applied').Count
        $ui.TweaksSummary.Text = "Налаштувань: $(@($Catalog.Tweaks).Count), застосовано: $applied. Галочками відмічено незастосоване з профілю «$(Get-D9Text $preset.name)». Наведіть мишку на назву, щоб побачити пояснення."
    }
    $loadTweakStates = {
        & $startJob 'Перевірка стану налаштувань' {
            param($a)
            foreach ($t in $a.Catalog.Tweaks) {
                [pscustomobject]@{ Id = $t.id; State = (Get-D9TweakState $t $a.Sys); Reason = (Test-D9Applicable $t.requires $a.Sys).Reason }
            }
        } @{ Catalog = $Catalog; Sys = $SystemInfo } { param($r) & $fillTweaks @($r) }
    }
    $fillSessions = {
        Set-D9Items $ui.SessionGrid @(Get-D9SessionList | ForEach-Object {
            $when = try { ([datetime]$_.Started).ToString('dd.MM.yyyy HH:mm') } catch { $_.Started }
            $status = if ($_.Undone) { 'відкочено' } elseif ($_.Errors) { "помилок: $($_.Errors)" } else { 'застосовано' }
            New-D9Row @{ Id = $_.Id; Title = $when; Detail = $_.Selection; Number = [int]$_.Changed; Status = $status }
        })
    }
    $fillDrivers = {
        param($rep)
        $state.Oem = $rep.Oem
        if ($rep.Oem) {
            $ui.BtnOemPage.IsEnabled = $true
            $ui.BtnOemPage.Content = "Сторінка драйверів $($rep.Oem.Name) для цієї моделі"
            $ui.OemText.Text = "Найкраще джерело драйверів — сайт виробника ПК: $($rep.Oem.Url)" + $(if ($rep.Oem.Note) { "`n$($rep.Oem.Note)" } else { '' }) + $(if ($rep.Oem.Serial) { "`nСерійний номер: $($rep.Oem.Serial)" } else { '' })
        } else {
            $ui.OemText.Text = 'Виробника ПК не знайдено в базі — користуйтеся посиланнями біля пристроїв (сайт виробника чипа, каталог Microsoft).'
        }
        $problems = @($rep.Problems | Sort-Object { if ($_.Class -eq 'Net') { 0 } else { 1 } } | ForEach-Object {
            $detail = "$($_.Reason). ID: $($_.Info.HardwareId)"
            if ($_.Windows -and $_.Windows -ne $_.Name) { $detail += ". Windows називає: $($_.Windows)" }
            New-D9Row @{ Badge = '!'; Color = '#B26A00'; Title = $_.Name; Detail = $detail; Links = (ConvertTo-D9UiLinks $_.Links) }
        })
        if (-not $problems) { $problems = @(New-D9Row @{ Badge = '✓'; Color = '#2E7D32'; Title = 'Усі пристрої мають драйвери'; Detail = 'Перевірте лише вік драйверів у таблиці нижче.' }) }
        Set-D9Items $ui.DriverProblemsList $problems
        Set-D9Items $ui.DriverInstalledGrid @($rep.Important | ForEach-Object { New-D9Row @{ Group = $_.Group; Title = $_.Name; Status = $_.Version; Detail = $_.Date; Note = $_.Provider } })
    }
    $statusUi = @{ missing = @('встановити', '#C62828'); newer = @('оновити', '#2563EB'); current = @('вже актуальний', '#5D6675') }
    $fillPackages = {
        param($found)
        $state.Packages = @($found.Packages)
        Set-D9Items $ui.DriverPackageGrid @($found.Packages | ForEach-Object {
            $cur = @($_.Current | ForEach-Object { $_.version } | Where-Object { $_ } | Sort-Object -Unique) -join ', '
            $date = if ($_.Package.Inf.Date) { $_.Package.Inf.Date.ToString('dd.MM.yyyy') } else { '?' }
            New-D9Row @{ Title = $_.Name; Kind = $statusUi[$_.Status][0]; Color = $statusUi[$_.Status][1]
                         Detail = "$(if ($cur) { $cur } else { 'немає' }) → $($_.Package.Inf.Version) ($date)"; Note = (Split-Path $_.Package.Inf.Path -Leaf)
                         Selected = ($_.Status -ne 'current'); Tag = $_ }
        })
        $ui.BtnInstallDrivers.IsEnabled = [bool]$state.Packages
        $msg = "INF-файлів у папці: $($found.Infs), підходять до цього ПК: $(@($found.Packages).Count)."
        & $log $msg
        if ($found.Installers) {
            $msg += " Пакетів лише з інсталятором: $(@($found.Installers).Count) — див. журнал виконання."
            & $log 'Пакети лише з інсталятором (.exe/.msi) — запустіть вручну, якщо цей пристрій є в ПК:'
            foreach ($i in $found.Installers) { & $log "  • $($i.Package): $($i.Path)" }
            $ui.LogExpander.IsExpanded = $true
        }
        $ui.StatusText.Text = $msg
    }

    $scanWork = {
        param($a)
        $ctx = New-D9ScanContext -Catalog $a.Catalog -SystemInfo $a.Sys -Deep:$a.Deep
        $scan = Invoke-D9Scan -Context $ctx
        [void](Save-D9Scan $scan)
        $list = Merge-D9ChecklistState -New (New-D9Checklist -Scan $scan -Catalog $a.Catalog) -Old (Get-D9Checklist)
        Save-D9Checklist $list
        if (-not (Test-Path $a.ReportDir)) { New-Item -ItemType Directory -Path $a.ReportDir | Out-Null }
        $path = Join-Path $a.ReportDir ("Звіт {0:yyyy-MM-dd HH-mm}.html" -f (Get-Date))
        [IO.File]::WriteAllText($path, (ConvertTo-D9ScanHtml -Scan $scan -Checklist $list -Categories $ctx.Config.categories), (New-Object Text.UTF8Encoding $false))
        @{ Scan = $scan; Checklist = $list; Categories = $ctx.Config.categories; Report = $path }
    }
    $onScanned = {
        param($r)
        $state.Scan = $r.Scan; $state.ReportPath = $r.Report; $state.Categories = $r.Categories
        & $fillOverview $r.Scan $r.Categories
        & $fillChecklist $r.Checklist
        $ui.BtnOpenReport.IsEnabled = $true
        & $log "Сканування завершено: $($r.Scan.score.overall)/100. Звіт: $($r.Report)"
    }

    # ---------- кнопки: Огляд ----------
    $ui.BtnScan.Add_Click({ & $startJob 'Сканування' $scanWork @{ Catalog = $Catalog; Sys = $SystemInfo; Deep = $false; ReportDir = $ReportDir } $onScanned })
    $ui.BtnDeepScan.Add_Click({ & $startJob 'Глибоке сканування' $scanWork @{ Catalog = $Catalog; Sys = $SystemInfo; Deep = $true; ReportDir = $ReportDir } $onScanned })
    $ui.BtnOpenReport.Add_Click({ if ($state.ReportPath) { Start-Process $state.ReportPath } })

    # ---------- кнопки: Чекліст ----------
    $ui.BtnRunAuto.Add_Click({
        if (-not $state.Checklist) { [void][Windows.MessageBox]::Show($win, 'Спочатку проскануйте комп''ютер.', 'Debloater9'); return }
        if (-not (& $needAdmin)) { return }
        $todo = @($state.Checklist.items | Where-Object { $_.auto -and $_.status -ne 'done' -and $_.action.action -ne 'reboot' })
        if (-not $todo) { [void][Windows.MessageBox]::Show($win, 'Автоматичних кроків не залишилось.', 'Debloater9'); return }
        $text = ($todo | ForEach-Object { "$($_.number). $($_.title)" }) -join "`r`n"
        if (-not (Show-D9TextDialog $win 'Автоматичні кроки' "Буде виконано $($todo.Count) кроків. Перед змінами створюється точка відновлення; усе можна відкотити на вкладці «Журнал змін»." $text 'Виконати')) { return }
        & $startJob 'Виконання кроків чекліста' {
            param($a)
            $list = Get-D9Checklist
            $ctx = New-D9ScanContext -Catalog $a.Catalog -SystemInfo $a.Sys
            foreach ($item in @($list.items | Where-Object { $_.auto -and $_.status -ne 'done' -and $_.action.action -ne 'reboot' } | Sort-Object number)) {
                if (-not (Test-D9ChecklistReady $list $item)) { Write-D9Log "Крок $($item.number) пропущено: спершу виконайте попередні" Warn; continue }
                try { [void](Invoke-D9ChecklistStep -Checklist $list -Item $item -Context $ctx) } catch { Write-D9Log "  Помилка: $($_.Exception.Message)" Error }
            }
            Write-D9Log 'Перевірка результату...'
            $list = Update-D9ChecklistStatus -Checklist $list -Context $ctx
            Save-D9Checklist $list
            $list
        } @{ Catalog = $Catalog; Sys = $SystemInfo } {
            param($list)
            & $fillChecklist $list
            & $fillSessions
            & $loadTweakStates
            $answer = [Windows.MessageBox]::Show($win, 'Готово. Перезавантажити комп''ютер зараз, щоб усі зміни запрацювали?', 'Debloater9', 'YesNo', 'Question')
            if ($answer -eq 'Yes') { Restart-Computer -Force }
        }
    })
    $ui.BtnMarkDone.Add_Click({
        $row = $ui.ChecklistList.SelectedItem
        if (-not $row) { [void][Windows.MessageBox]::Show($win, 'Виберіть крок у списку.', 'Debloater9'); return }
        $item = $state.Checklist.items | Where-Object id -eq $row.Tag.id | Select-Object -First 1
        $item.status = 'done'; $item.doneAt = (Get-Date).ToString('s'); $item.note = 'позначено вручну'
        Save-D9Checklist $state.Checklist
        & $fillChecklist $state.Checklist
    })
    $ui.BtnRecheck.Add_Click({
        if (-not $state.Checklist) { return }
        & $startJob 'Перевірка виконаних кроків' {
            param($a)
            $ctx = New-D9ScanContext -Catalog $a.Catalog -SystemInfo $a.Sys
            $list = Update-D9ChecklistStatus -Checklist (Get-D9Checklist) -Context $ctx
            Save-D9Checklist $list
            $list
        } @{ Catalog = $Catalog; Sys = $SystemInfo } { param($list) & $fillChecklist $list }
    })
    $ui.BtnReboot.Add_Click({
        if ([Windows.MessageBox]::Show($win, 'Перезавантажити комп''ютер зараз? Збережіть відкриті документи.', 'Debloater9', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force }
    })

    # ---------- кнопки: Налаштування ----------
    foreach ($p in $Catalog.Presets) { [void]$ui.PresetBox.Items.Add((Get-D9Text $p.name)) }
    $ui.PresetBox.SelectedIndex = [array]::IndexOf(@($Catalog.Presets.id), $Recommendation.Preset)
    $ui.BtnSelectPreset.Add_Click({
        $preset = @($Catalog.Presets)[$ui.PresetBox.SelectedIndex]
        foreach ($r in $state.TweakRows) { $r.Selected = ($r.Enabled -and @($preset.tweaks) -contains $r.Id -and $r.Status -ne 'застосовано') }
    })
    $ui.BtnSelectNone.Add_Click({ foreach ($r in $state.TweakRows) { $r.Selected = $false } })
    $previewWork = {
        param($a)
        $plan = New-D9Plan -Catalog $a.Catalog -TweakIds $a.Ids -SystemInfo $a.Sys
        $lines = foreach ($group in (Get-D9Preview -Plan $plan -SystemInfo $a.Sys | Group-Object Tweak)) {
            $t = Get-D9Tweak $a.Catalog $group.Name
            $pending = @($group.Group | Where-Object Pending)
            $title = if ($t) { Get-D9Text $t.name } else { $group.Name }
            if (-not $pending -and -not ($group.Group | Where-Object { $_.Change -like 'пропущено*' })) { "✓ $title — уже застосовано"; continue }
            "■ $title"
            foreach ($p in $group.Group) { if ($p.Pending -or $p.Change -like 'пропущено*') { "    $($p.Change)" } }
        }
        @{ Text = ($lines -join "`r`n"); Count = @(Get-D9Preview -Plan $plan -SystemInfo $a.Sys | Where-Object Pending).Count }
    }
    $selectedIds = { @($state.TweakRows | Where-Object Selected | ForEach-Object Id) }
    $ui.BtnPreview.Add_Click({
        $ids = & $selectedIds
        if (-not $ids) { [void][Windows.MessageBox]::Show($win, 'Нічого не вибрано.', 'Debloater9'); return }
        & $startJob 'Підготовка попереднього перегляду' $previewWork @{ Catalog = $Catalog; Sys = $SystemInfo; Ids = $ids } {
            param($r) [void](Show-D9TextDialog $win 'Що зміниться' "Змін до застосування: $($r.Count)" $r.Text -InfoOnly)
        }
    })
    $ui.BtnApply.Add_Click({
        $ids = & $selectedIds
        if (-not $ids) { [void][Windows.MessageBox]::Show($win, 'Нічого не вибрано.', 'Debloater9'); return }
        if (-not (& $needAdmin)) { return }
        & $startJob 'Підготовка попереднього перегляду' $previewWork @{ Catalog = $Catalog; Sys = $SystemInfo; Ids = $ids } {
            param($r, $c)
            if (-not $r.Count) { [void][Windows.MessageBox]::Show($win, 'Усе вибране вже застосовано.', 'Debloater9'); return }
            if (-not (Show-D9TextDialog $win 'Застосувати налаштування' "Змін до застосування: $($r.Count). Перед змінами створюється точка відновлення." $r.Text)) { return }
            & $startJob 'Застосування налаштувань' {
                param($a)
                $plan = New-D9Plan -Catalog $a.Catalog -TweakIds $a.Ids -SystemInfo $a.Sys
                Invoke-D9Plan -Plan $plan -SystemInfo $a.Sys -Selection 'вибрані налаштування (вікно)'
            } @{ Catalog = $Catalog; Sys = $SystemInfo; Ids = $c.Ids } {
                param($session)
                $ok = @($session.entries | Where-Object result -eq 'ok').Count
                $err = @($session.entries | Where-Object result -eq 'error').Count
                & $fillSessions
                & $loadTweakStates
                [void][Windows.MessageBox]::Show($win, "Готово. Змінено: $ok, помилок: $err.`nЧастина змін запрацює після перезавантаження. Відкат — на вкладці «Журнал змін».", 'Debloater9', 'OK', $(if ($err) { 'Warning' } else { 'Information' }))
            }
        } @{ Ids = $ids }
    })

    # ---------- кнопки: Драйвери ----------
    $driverReport = { & $startJob 'Перевірка драйверів' { param($a) Get-D9DriverReport $a.Sys } @{ Sys = $SystemInfo } { param($r) & $fillDrivers $r } }
    $ui.BtnDriverScan.Add_Click($driverReport)
    $ui.BtnOemPage.Add_Click({ if ($state.Oem) { Start-Process $state.Oem.Url } })
    $ui.BtnBrowse.Add_Click({
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Папка із завантаженими драйверами'
        if (Test-Path $ui.DriverFolder.Text) { $dlg.SelectedPath = $ui.DriverFolder.Text }
        if ($dlg.ShowDialog() -eq 'OK') { $ui.DriverFolder.Text = $dlg.SelectedPath }
    })
    $ui.BtnFindDrivers.Add_Click({
        $folder = $ui.DriverFolder.Text
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        if (-not (Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue)) {
            [void][Windows.MessageBox]::Show($win, "Папка порожня. Завантажте драйвери з сайту виробника (кнопка вгорі) і покладіть файли сюди як є — .zip теж можна:`n$folder", 'Debloater9')
            Start-Process explorer.exe $folder
            return
        }
        & $startJob 'Пошук драйверів у папці' { param($a) Find-D9DriverPackages -Folder $a.Folder } @{ Folder = $folder } { param($r) & $fillPackages $r }
    })
    $ui.BtnInstallDrivers.Add_Click({
        $chosen = @($ui.DriverPackageGrid.ItemsSource | Where-Object Selected | ForEach-Object Tag)
        if (-not $chosen) { [void][Windows.MessageBox]::Show($win, 'Нічого не вибрано.', 'Debloater9'); return }
        if (-not (& $needAdmin)) { return }
        $text = ($chosen | Sort-Object Order, Name | ForEach-Object { "$($_.Name) — $($_.Package.Inf.Version) ($(Split-Path $_.Package.Inf.Path -Leaf))" }) -join "`r`n"
        if (-not (Show-D9TextDialog $win 'Встановлення драйверів' "Буде встановлено $($chosen.Count) драйвер(ів) у такому порядку. Попередні драйвери буде збережено для відкату." $text 'Встановити')) { return }
        & $startJob 'Встановлення драйверів' {
            param($a)
            $cat = New-D9DriverCatalog -Packages $a.Packages
            $plan = New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo $a.Sys
            Invoke-D9Plan -Plan $plan -SystemInfo $a.Sys -Selection "драйвери з $($a.Folder)"
        } @{ Packages = @($chosen | Sort-Object Order, Name); Sys = $SystemInfo; Folder = $ui.DriverFolder.Text } {
            param($session)
            $ok = @($session.entries | Where-Object result -eq 'ok').Count
            $err = @($session.entries | Where-Object result -eq 'error')
            & $fillSessions
            $msg = "Встановлено: $ok, помилок: $($err.Count)."
            if ($err) { $msg += "`n" + (($err | ForEach-Object { "• $($_.action.name): $($_.message)" }) -join "`n") }
            $msg += "`n`nПерезавантажити комп'ютер зараз, щоб драйвери запрацювали?"
            if ([Windows.MessageBox]::Show($win, $msg, 'Debloater9', 'YesNo', $(if ($err) { 'Warning' } else { 'Question' })) -eq 'Yes') { Restart-Computer -Force }
            & $driverReport
        }
    })

    # ---------- Драйвери з інтернету (Microsoft Update Catalog + Windows Update) ----------
    $fillOnline = {
        param($cands)
        $state.OnlineCands = @($cands | Where-Object { $_ })
        Set-D9Items $ui.DriverOnlineGrid @($state.OnlineCands | ForEach-Object {
            $kind = if ($_.Status -eq 'missing') { @('встановити', '#C62828') } elseif ($_.Optional) { @('необов''язково', '#5D6675') } else { @('оновити', '#2563EB') }
            $cur = if ($_.Device.Version) { "$($_.Device.Version)$(if ($_.Device.Date -and ([datetime]$_.Device.Date).Year -ge 2010) { ' (' + ([datetime]$_.Device.Date).ToString('dd.MM.yyyy') + ')' })" } else { 'немає драйвера' }
            $new = "$($_.Row.Version)$(if ($_.Row.Date) { ' (' + ([datetime]$_.Row.Date).ToString('dd.MM.yyyy') + ')' })"
            New-D9Row @{ Title = $_.Device.Name; Id = $_.Row.Title; Kind = $kind[0]; Color = $kind[1]; Detail = "$cur → $new"
                         Note = "$(Format-D9Size $_.Row.Size)$(if ($_.Recommended) { ' · рекомендує Windows Update' } else { ' · каталог Microsoft' })"
                         Selected = -not $_.Optional; Tag = $_ }
        })
        $ui.BtnDriverOnlineInstall.IsEnabled = [bool]$state.OnlineCands
        $main = @($state.OnlineCands | Where-Object { -not $_.Optional }).Count
        $ui.StatusText.Text = if ($state.OnlineCands) { "Знайдено драйверів: $(@($state.OnlineCands).Count), з них рекомендовано встановити: $main. Необов'язкові замінюють робочі драйвери Windows на системних пристроях." } else { 'Новіших драйверів не знайдено — встановлені актуальні.' }
    }
    $oemTool = Get-D9OemTool $SystemInfo
    if ($oemTool) { $ui.BtnOemTool.Content = "Оновити через $($oemTool.Name)"; $ui.BtnOemTool.Visibility = 'Visible' }
    $ui.BtnOemTool.Add_Click({
        if (-not (& $needAdmin)) { return }
        $t = Get-D9OemTool $SystemInfo
        if ([Windows.MessageBox]::Show($win, "Встановити (за потреби) і запустити $($t.Name)?`nЦе фірмова утиліта $($t.Vendor): вона сама поставить драйвери, прошивки й BIOS для вашої моделі. Триває 10–30 хвилин; не вимикайте ПК, ноутбук — від мережі.", 'Debloater9', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob "Запуск $($t.Name)" { param($a) Invoke-D9OemDriverTool -SystemInfo $a.Sys } @{ Sys = $SystemInfo } {
            param($r)
            $msg = if ($r.Done) { "$($r.Tool) завершила роботу." } else { "$($r.Tool) завершилась з кодом $($r.Code) — подробиці в журналі виконання." }
            if ($r.RebootRecommended) { if ([Windows.MessageBox]::Show($win, "$msg`n`nПерезавантажити комп'ютер зараз?", 'Debloater9', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force } }
            else { [void][Windows.MessageBox]::Show($win, $msg, 'Debloater9') }
            & $driverReport
        }
    })
    $ui.BtnDriverOnline.Add_Click({
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Пошук драйверів онлайн' { param($a) @(Find-D9DriverUpdates -SystemInfo $a.Sys -IncludeWindowsUpdate) } @{ Sys = $SystemInfo } {
            param($r)
            & $fillOnline @($r)
            if (-not $state.OnlineCands) { [void][Windows.MessageBox]::Show($win, 'Новіших драйверів у каталозі Microsoft не знайдено — встановлені драйвери актуальні.', 'Debloater9') }
        }
    })
    $ui.BtnDriverOnlineInstall.Add_Click({
        $chosen = @($ui.DriverOnlineGrid.ItemsSource | Where-Object Selected | ForEach-Object Tag)
        if (-not $chosen) { [void][Windows.MessageBox]::Show($win, 'Позначте драйвери галочками.', 'Debloater9'); return }
        if (-not (& $needAdmin)) { return }
        $mb = [long](($chosen | ForEach-Object { $_.Row.Size } | Measure-Object -Sum).Sum)
        $text = ($chosen | ForEach-Object { "$($_.Device.Name): $($_.Row.Version) — $($_.Row.Title)" }) -join "`r`n"
        if (-not (Show-D9TextDialog $win 'Драйвери з інтернету' "Буде завантажено $($chosen.Count) пакет(ів), разом $(Format-D9Size $mb), і встановлено ті, що точно підходять до пристроїв. Перед встановленням створюється точка відновлення, попередні драйвери зберігаються." $text 'Завантажити й встановити')) { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Завантаження й встановлення драйверів' {
            param($a)
            $found = Save-D9DriverUpdates -Candidates $a.Cands -Folder $a.Folder
            $todo = @($found.Packages | Where-Object Status -ne 'current')
            if (-not $todo) { return @{ Session = $null; Count = 0 } }
            $cat = New-D9DriverCatalog -Packages $todo
            $plan = New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo $a.Sys
            @{ Session = (Invoke-D9Plan -Plan $plan -SystemInfo $a.Sys -Selection 'драйвери з Microsoft Update Catalog'); Count = $todo.Count }
        } @{ Cands = $chosen; Folder = (Join-Path $DriverDir 'Завантажені'); Sys = $SystemInfo } {
            param($r)
            & $fillSessions
            if (-not $r.Session) { [void][Windows.MessageBox]::Show($win, 'Після перевірки пакетів встановлювати нічого: поточні драйвери не старші.', 'Debloater9'); return }
            $ok = @($r.Session.entries | Where-Object result -eq 'ok').Count
            $err = @($r.Session.entries | Where-Object result -eq 'error')
            $msg = "Встановлено: $ok з $($r.Count), помилок: $($err.Count)."
            if ($err) { $msg += "`n" + (($err | Select-Object -First 6 | ForEach-Object { "• $($_.action.name): $($_.message)" }) -join "`n") }
            $msg += "`nЗавантажені пакети лежать у папці «Драйвери\Завантажені» — їх можна використати на такому самому ПК без інтернету."
            $msg += "`n`nПерезавантажити комп'ютер зараз, щоб драйвери запрацювали?"
            if ([Windows.MessageBox]::Show($win, $msg, 'Debloater9', 'YesNo', $(if ($err) { 'Warning' } else { 'Question' })) -eq 'Yes') { Restart-Computer -Force }
            & $driverReport
        }
    })

    # Застосувати «каталог» (твіки, автозапуск, пауза) через рушій: точка відновлення, журнал, відкат
    $applyCatalog = {
        param($cat, [string]$title, [string]$selection, [scriptblock]$after, [switch]$NoRestorePoint)
        & $startJob $title {
            param($a)
            $plan = New-D9Plan -Catalog $a.Catalog -TweakIds @($a.Catalog.Tweaks.id) -SystemInfo $a.Sys
            Invoke-D9Plan -Plan $plan -SystemInfo $a.Sys -Selection $a.Selection -NoRestorePoint:$a.NoRp
        } @{ Catalog = $cat; Sys = $SystemInfo; Selection = $selection; NoRp = [bool]$NoRestorePoint } {
            param($session, $c)
            $err = @($session.entries | Where-Object result -eq 'error')
            & $fillSessions
            if ($err) {
                [void][Windows.MessageBox]::Show($win, "Частина змін не застосувалась:`n" + (($err | Select-Object -First 8 | ForEach-Object { "• $($_.message)" }) -join "`n"), 'Debloater9', 'OK', 'Warning')
            }
            if ($c.After) { & $c.After $session }
        } @{ After = $after }
    }

    # ---------- кнопки: Автозавантаження ----------
    $fillStartup = {
        param($items)
        $state.StartupRows = @(foreach ($i in $items) {
            $note = @()
            if ($i.Missing) { $note += 'файл відсутній — запис можна вимкнути' }
            if (-not $i.Publisher) { $note += 'видавець невідомий' }
            New-D9Row @{ Selected = [bool]$i.Enabled; Title = $i.Name; Detail = $i.Command; Group = $(if ($i.Publisher) { $i.Publisher } else { '—' })
                         Note = $i.Where; Status = ($note -join '; '); Color = $(if ($i.Missing) { '#C62828' } else { '#5D6675' }); Tag = $i }
        })
        Set-D9Items $ui.StartupGrid $state.StartupRows
        $on = @($items | Where-Object Enabled).Count
        $ui.StartupSummary.Text = "Програм в автозавантаженні: $(@($items).Count), запускаються: $on. Зніміть галочку з тих, яким не потрібно стартувати разом із Windows, і натисніть «Застосувати зміни». Програми не видаляються; усе відкочується в «Журналі змін»."
    }
    $loadStartup = { & $startJob 'Читання автозавантаження' { Get-D9StartupItems } $null { param($r) & $fillStartup @($r) } }
    $ui.BtnStartupRefresh.Add_Click($loadStartup)
    $ui.BtnStartupApply.Add_Click({
        $changes = @($state.StartupRows | Where-Object { $_.Selected -ne [bool]$_.Tag.Enabled } | ForEach-Object { @{ Item = $_.Tag; Enable = $_.Selected } })
        if (-not $changes) { [void][Windows.MessageBox]::Show($win, 'Змін немає: поставте або зніміть галочки.', 'Debloater9'); return }
        if (-not (& $needAdmin)) { return }
        $text = ($changes | ForEach-Object { "$(if ($_.Enable) { 'Увімкнути' } else { 'Вимкнути' }): $($_.Item.Name)" }) -join "`r`n"
        if (-not (Show-D9TextDialog $win 'Автозавантаження' "Змін: $($changes.Count). Подіють після наступного входу в Windows." $text)) { return }
        & $applyCatalog (New-D9StartupCatalog -Changes $changes) 'Зміна автозавантаження' 'автозавантаження' { & $loadStartup } -NoRestorePoint
    })

    # ---------- кнопки: Обслуговування ----------
    $refreshMaintenance = {
        $ux = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue
        $until = $null
        if ($ux.PauseUpdatesExpiryTime) { try { $until = [datetime]::Parse($ux.PauseUpdatesExpiryTime, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
        $ui.PauseState.Text = if ($until -and $until -gt (Get-Date)) { "Оновлення призупинено до $($until.ToString('dd.MM.yyyy')). На цей час не приходять і виправлення безпеки." }
                              else { 'Оновлення не призупинено. Пауза знадобиться, наприклад, перед важливою роботою або на мобільному інтернеті.' }
        $t = Get-D9Tweak $Catalog 'updates.no-wu-drivers'
        $applied = (Get-D9TweakState $t $SystemInfo) -eq 'applied'
        $ui.WuDriversState.Text = if ($applied) { 'Вимкнено: Windows не встановлює драйвери сама. Драйвери ставите ви — з сайту виробника або на вкладці «Драйвери». Скасувати можна в «Журналі змін».' }
                                  else { 'Увімкнено: Windows Update сама ставить і підмінює драйвери (часто загальними або старшими версіями). Вимкніть, якщо ставите драйвери самі.' }
        $ui.BtnWuDrivers.IsEnabled = -not $applied -and -not $state.Job
    }
    $maintenanceJob = {
        param([string]$title, [string]$confirm, [string]$function)
        if (-not (& $needAdmin)) { return }
        if ([Windows.MessageBox]::Show($win, $confirm, 'Debloater9', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob $title { param($a) & $a.Fn } @{ Fn = $function } {
            param($r)
            $msg = 'Готово. Подробиці — у журналі виконання внизу.'
            if ($r.RebootRecommended) {
                if ([Windows.MessageBox]::Show($win, "$msg`n`nПерезавантажити комп'ютер зараз?", 'Debloater9', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force }
            } else { [void][Windows.MessageBox]::Show($win, $msg, 'Debloater9') }
        }
    }
    $ui.BtnRepair.Add_Click({ & $maintenanceJob 'Відновлення системних файлів' "Перевірити й відновити системні файли Windows?`nЦе триває 10–40 хвилин; комп'ютером можна користуватися." 'Invoke-D9RepairSystem' })
    $ui.BtnNetReset.Add_Click({ & $maintenanceJob 'Скидання мережі' "Скинути мережеві налаштування?`nWi-Fi-мережі й паролі збережуться; після перезавантаження з'єднання налаштується заново." 'Invoke-D9NetworkReset' })
    $ui.BtnWuReset.Add_Click({ & $maintenanceJob 'Скидання Windows Update' "Скинути Windows Update?`nСлужби буде перезапущено, кеш оновлень створиться заново." 'Invoke-D9WindowsUpdateReset' })
    $ui.BtnRestorePoint.Add_Click({
        if (-not (& $needAdmin)) { return }
        & $startJob 'Створення точки відновлення' { New-D9RestorePoint } $null {
            param($name)
            if ($name) { [void][Windows.MessageBox]::Show($win, "Точку відновлення створено: $name", 'Debloater9') }
            else { [void][Windows.MessageBox]::Show($win, 'Не вдалося створити точку відновлення. Можливо, вимкнено захист системи (кнопка «Відновлення системи Windows» → Налаштувати).', 'Debloater9', 'OK', 'Warning') }
        }
    })
    $ui.BtnCleanNow.Add_Click({
        if (-not (& $needAdmin)) { return }
        if ([Windows.MessageBox]::Show($win, "Видалити тимчасові файли, кеш оновлень Windows, дампи збоїв і залишки інсталяторів?`nЦе не можна відкотити, але ці файли не потрібні.", 'Debloater9', 'YesNo', 'Question') -ne 'Yes') { return }
        $ids = 'cleanup.temp', 'cleanup.update-cache', 'cleanup.leftovers', 'cleanup.do-cache'
        $cat = [pscustomobject]@{ Tweaks = @($Catalog.Tweaks | Where-Object { $ids -contains $_.id }); Presets = @() }
        $state.FreeBefore = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'").FreeSpace
        & $applyCatalog $cat 'Очищення диска' 'очищення диска' {
            $after = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'").FreeSpace
            [void][Windows.MessageBox]::Show($win, "Звільнено: $(Format-D9Size ([math]::Max(0, $after - $state.FreeBefore)))", 'Debloater9')
        } -NoRestorePoint
    })
    $ui.BtnPause.Add_Click({
        if (-not (& $needAdmin)) { return }
        $days = @(7, 14, 21, 35)[$ui.PauseDays.SelectedIndex]
        & $applyCatalog (New-D9PauseUpdatesCatalog -Days $days) 'Пауза оновлень' "пауза оновлень на $days дн." { & $refreshMaintenance } -NoRestorePoint
    })
    $ui.BtnResume.Add_Click({
        if (-not (& $needAdmin)) { return }
        & $applyCatalog (New-D9ResumeUpdatesCatalog) 'Відновлення оновлень' 'відновлення оновлень' { & $refreshMaintenance } -NoRestorePoint
    })
    $ui.BtnWuDrivers.Add_Click({
        if (-not (& $needAdmin)) { return }
        $t = Get-D9Tweak $Catalog 'updates.no-wu-drivers'
        if ([Windows.MessageBox]::Show($win, "$(Get-D9Text $t.description)`n`nВимкнути встановлення драйверів через Windows Update?", 'Debloater9', 'YesNo', 'Question') -ne 'Yes') { return }
        & $applyCatalog ([pscustomobject]@{ Tweaks = @($t); Presets = @() }) 'Драйвери з Windows Update' (Get-D9Text $t.name) { & $refreshMaintenance; & $loadTweakStates }
    })

    # ---------- кнопки: Журнал ----------
    $ui.BtnRefreshSessions.Add_Click({ & $fillSessions })
    $ui.BtnSystemRestore.Add_Click({ Start-Process rstrui.exe })
    $ui.BtnDiagnostics.Add_Click({
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Збір діагностики' { param($a) New-D9DiagnosticsBundle -SystemInfo $a.Sys -OutDir $a.Dir -ReportDir $a.Dir } @{ Sys = $SystemInfo; Dir = $ReportDir } {
            param($zip)
            $zip = @($zip) | Where-Object { $_ -is [string] -and $_ -like '*.zip' } | Select-Object -Last 1
            if ($zip) { Start-Process explorer.exe "/select,`"$zip`"" }
        }
    })
    $ui.BtnUndo.Add_Click({
        $row = $ui.SessionGrid.SelectedItem
        if (-not $row) { [void][Windows.MessageBox]::Show($win, 'Виберіть сесію в таблиці.', 'Debloater9'); return }
        if (-not (& $needAdmin)) { return }
        if ([Windows.MessageBox]::Show($win, "Відкотити зміни сесії «$($row.Detail)» ($($row.Title))?", 'Debloater9', 'YesNo', 'Question') -ne 'Yes') { return }
        & $startJob 'Відкат змін' { param($a) Undo-D9Session -Id $a.Id } @{ Id = $row.Id } {
            param($report)
            $report = @($report)
            $restored = @($report | Where-Object result -eq 'restored').Count
            $other = @($report | Where-Object { $_.result -ne 'restored' })
            $msg = "Відновлено: $restored."
            if ($other) { $msg += "`nПотребує уваги ($($other.Count)):`n" + (($other | Select-Object -First 10 | ForEach-Object { "• $($_.tweak): $($_.message)" }) -join "`n") }
            & $fillSessions
            & $loadTweakStates
            [void][Windows.MessageBox]::Show($win, "$msg`n`nДеякі зміни повернуться після перезавантаження.", 'Debloater9')
        }
    })

    # ---------- Програми (winget) ----------
    $appCatalog = Import-D9AppCatalog
    $appCats = @{}
    foreach ($c in $appCatalog.categories) { $appCats[[string]$c.id] = Get-D9Text $c.name }
    $state.AppRows = @($appCatalog.apps | ForEach-Object {
        New-D9Row @{ Id = $_.id; Title = $_.name; Group = $appCats[[string]$_.category]; Note = (Get-D9Text $_.description); Status = ''; Color = '#5D6675'; Tag = $_ }
    })
    $showApps = {
        $q = $ui.AppSearch.Text.Trim()
        $shown = if ($q) { @($state.AppRows | Where-Object { $_.Title -like "*$q*" -or $_.Group -like "*$q*" -or $_.Note -like "*$q*" -or $_.Id -like "*$q*" }) } else { $state.AppRows }
        Set-D9Items $ui.AppGrid $shown
    }
    & $showApps
    $ui.AppSearch.Add_TextChanged({ & $showApps })
    $hasWinget = [bool](Get-D9WingetPath)
    if (-not $hasWinget) {
        $ui.AppsSummary.Text = 'winget не знайдено — без нього програми не встановлюються. Встановіть «Інсталятор застосунків» з Microsoft Store і перезапустіть Debloater9.'
        $ui.BtnWingetStore.Visibility = 'Visible'
    }
    $ui.BtnWingetStore.Add_Click({ Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' })
    $noWinget = { [void][Windows.MessageBox]::Show($win, 'winget не знайдено. Встановіть «Інсталятор застосунків» з Microsoft Store (посилання на вкладці).', 'Debloater9', 'OK', 'Warning') }
    $markApp = {
        param($row, [bool]$installed)
        if ($installed) { $row.Status = 'встановлено'; $row.Color = '#2E7D32'; $row.Selected = $false; $row.Enabled = $false }
        else { $row.Status = 'не встановлено'; $row.Color = '#5D6675'; $row.Enabled = $true }
    }
    $loadApps = {
        if (-not $hasWinget) { return }
        & $startJob 'Перевірка встановлених програм' { $s = Get-D9InstalledAppIds; [string[]]@($s) } $null {
            param($ids)
            $ids = @($ids)
            foreach ($r in $state.AppRows) { & $markApp $r ($ids -contains $r.Id) }
            $state.AppsLoaded = $true
            $n = @($state.AppRows | Where-Object { $_.Status -eq 'встановлено' }).Count
            $ui.AppsSummary.Text = "Програм у каталозі: $(@($state.AppRows).Count), з них уже встановлено: $n. Позначте потрібні й натисніть «Встановити вибрані» — офіційні інсталятори через winget, без реклами й «довантажувачів»."
        }
    }
    $ui.BtnAppsRefresh.Add_Click({ if ($hasWinget) { & $loadApps } else { & $noWinget } })
    $ui.BtnAppsInstall.Add_Click({
        if (-not $hasWinget) { & $noWinget; return }
        $sel = @($state.AppRows | Where-Object Selected)
        if (-not $sel) { [void][Windows.MessageBox]::Show($win, 'Позначте програми галочками.', 'Debloater9'); return }
        $names = ($sel | ForEach-Object { "• $($_.Title)" }) -join "`n"
        if ([Windows.MessageBox]::Show($win, "Встановити програми ($($sel.Count))?`n`n$names`n`nВстановлення йде у фоні; деякі інсталятори можуть показати власне вікно.", 'Debloater9', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Встановлення програм' { param($a) Install-D9Apps -Apps $a.Apps } @{ Apps = @($sel | ForEach-Object Tag) } {
            param($res)
            $res = @($res | Where-Object { $_ })
            foreach ($r in $res) {
                $row = $state.AppRows | Where-Object Id -eq $r.id | Select-Object -First 1
                if (-not $row) { continue }
                if ($r.result -in 'failed', 'notFound') { $row.Status = 'помилка'; $row.Color = '#C62828' } else { & $markApp $row $true }
            }
            $bad = @($res | Where-Object { $_.result -in 'failed', 'notFound' })
            $msg = "Встановлено: $($res.Count - $bad.Count) з $($res.Count)."
            if ($bad) { $msg += "`nНе вдалося: $(($bad | ForEach-Object name) -join ', '). Подробиці — у журналі виконання внизу." }
            if (@($res | Where-Object result -eq 'reboot')) { $msg += "`nДеякі програми запрацюють після перезавантаження." }
            [void][Windows.MessageBox]::Show($win, $msg, 'Debloater9', 'OK', $(if ($bad) { 'Warning' } else { 'Information' }))
        }
    })
    $ui.BtnAppsUpgrade.Add_Click({
        if (-not $hasWinget) { & $noWinget; return }
        & $startJob 'Пошук оновлень програм' { @(Get-D9AppUpgrades) } $null {
            param($up)
            $up = @($up | Where-Object { $_ })
            if (-not $up) { [void][Windows.MessageBox]::Show($win, 'Усі програми актуальні.', 'Debloater9'); return }
            $text = ($up | ForEach-Object { "$($_.Name)    $($_.Version) → $($_.Available)" }) -join "`r`n"
            if (-not (Show-D9TextDialog $win 'Оновити програми' "Оновлення є для $($up.Count) програм. Відкриті програми краще закрити — їх не вдасться оновити." $text)) { return }
            $ui.LogExpander.IsExpanded = $true
            & $startJob 'Оновлення програм' { Invoke-D9AppUpgradeAll } $null {
                param($r)
                $ok = $r.Result -in 'installed', 'upToDate'
                [void][Windows.MessageBox]::Show($win, $(if ($ok) { 'Програми оновлено.' } else { 'Оновлення завершено, але частину програм (наприклад, відкритих зараз) оновити не вдалося. Подробиці — у журналі виконання внизу.' }), 'Debloater9', 'OK', $(if ($ok) { 'Information' } else { 'Warning' }))
            }
        }
    })

    # ---------- старт ----------
    $win.Add_Loaded({
        $timer.Start()
        & $fillSessions
        $prev = Get-D9Checklist
        if ($prev) { & $fillChecklist $prev }
        $lastScan = Get-ChildItem (Get-D9ScanDir) -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($lastScan) {
            try {
                $scan = ConvertFrom-Json ([IO.File]::ReadAllText($lastScan.FullName, [Text.Encoding]::UTF8))
                $state.Categories = (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).categories
                & $fillOverview $scan $state.Categories
                $ui.CountsText.Text += "`n(результат попереднього сканування — натисніть «Сканувати», щоб оновити)"
            } catch { }
        }
        & $refreshMaintenance
        & $loadTweakStates
    })
    # Список автозавантаження читаємо при першому відкритті вкладки (щоб не займати фоновий потік на старті)
    $ui.Tabs.Add_SelectionChanged({
        param($sender, $e)
        if ($e.OriginalSource -ne $ui.Tabs) { return }
        if ($ui.Tabs.SelectedItem.Header -eq 'Автозавантаження' -and -not $state.StartupRows -and -not $state.Job) { & $loadStartup }
        if ($ui.Tabs.SelectedItem.Header -eq 'Програми' -and -not $state.AppsLoaded -and -not $state.Job) { & $loadApps }
    })
    $win.Add_Closing({ param($sender, $e)
        if ($state.Job) {
            if ([Windows.MessageBox]::Show($win, 'Зараз виконується операція. Закрити програму все одно?', 'Debloater9', 'YesNo', 'Warning') -ne 'Yes') { $e.Cancel = $true }
        }
    })
    $win.Add_Closed({ $timer.Stop() })
    if ($TestAction) { return (. $TestAction) }
    [void]$win.ShowDialog()
}
