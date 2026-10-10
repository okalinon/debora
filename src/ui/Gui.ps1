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
    // Темна тема: статусні кольори замінюються світлішими відтінками (заповнює Show-D9Gui)
    public static System.Collections.Generic.Dictionary<string, string> ColorMap = new System.Collections.Generic.Dictionary<string, string>(System.StringComparer.OrdinalIgnoreCase);
    public string Color { get { return color; } set { string m; color = (value != null && ColorMap.TryGetValue(value, out m)) ? m : value; On("Color"); } }
    public object Links { get; set; }
    public object Icon { get; set; }
    public string Initial { get; set; }
    public object Tag { get; set; }
}
'@
}

# base64 PNG → заморожене зображення WPF (для іконок програм)
function ConvertTo-D9Image {
    param([string]$Base64)
    if (-not $Base64) { return $null }
    try {
        $img = New-Object Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.StreamSource = New-Object IO.MemoryStream (, [Convert]::FromBase64String($Base64))
        $img.CacheOption = 'OnLoad'
        $img.EndInit(); $img.Freeze()
        return $img
    } catch { return $null }
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
    critical   = @{ Badge = '✖'; Color = '#D70015'; Name = 'критично' }
    warning    = @{ Badge = '!'; Color = '#B25000'; Name = 'варто виправити' }
    suggestion = @{ Badge = '•'; Color = '#007AFF'; Name = 'порада' }
    info       = @{ Badge = 'i'; Color = '#6E6E73'; Name = 'відомості' }
}

# Вікно з текстом і кнопками «Так/Ні» (для попереднього перегляду змін)
function Show-D9TextDialog {
    param($Owner, [string]$Title, [string]$Header, [string]$Text, [string]$OkText = 'Застосувати', [switch]$InfoOnly)
    $w = New-Object Windows.Window
    $w.Title = $Title; $w.Width = 820; $w.Height = 600; $w.Owner = $Owner
    $w.WindowStartupLocation = 'CenterOwner'; $w.FontFamily = 'Segoe UI Variable Text, Segoe UI'; $w.FontSize = 13
    if ($Owner) { $w.Resources = $Owner.Resources; $w.Background = $Owner.Background; $w.Foreground = $Owner.Foreground }
    $dock = New-Object Windows.Controls.DockPanel; $dock.Margin = '16'
    $h = New-Object Windows.Controls.TextBlock; $h.Text = $Header; $h.TextWrapping = 'Wrap'; $h.FontWeight = 'SemiBold'; $h.Margin = '0,0,0,10'
    [Windows.Controls.DockPanel]::SetDock($h, 'Top'); [void]$dock.Children.Add($h)
    $buttons = New-Object Windows.Controls.StackPanel; $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'; $buttons.Margin = '0,10,0,0'
    [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom'); [void]$dock.Children.Add($buttons)
    $box = New-Object Windows.Controls.TextBox; $box.Text = $Text; $box.IsReadOnly = $true; $box.FontFamily = 'Cascadia Mono, Consolas'; $box.FontSize = 12
    $box.VerticalScrollBarVisibility = 'Auto'; $box.HorizontalScrollBarVisibility = 'Auto'
    [void]$dock.Children.Add($box)
    $ok = New-Object Windows.Controls.Button; $ok.Content = $(if ($InfoOnly) { 'Закрити' } else { $OkText }); $ok.Margin = '0,0,8,0'; $ok.IsDefault = $true; if ($Owner) { $ok.Style = $Owner.FindResource('Primary') }
    $ok.Add_Click({ $w.DialogResult = $true })
    [void]$buttons.Children.Add($ok)
    if (-not $InfoOnly) {
        $cancel = New-Object Windows.Controls.Button; $cancel.Content = 'Скасувати'; $cancel.Margin = '0'; $cancel.IsCancel = $true
        [void]$buttons.Children.Add($cancel)
    }
    $w.Content = $dock
    return [bool]$w.ShowDialog()
}

# ---------- Тема ----------
# Світлі кольори розмітки й статусів → темні відповідники
$script:D9DarkColors = [ordered]@{
    '#F2F2F7' = '#1C1C1E'; '#E9E9EE' = '#232325'; '#DCDCE1' = '#3A3A3C'; '#1D1D1F' = '#F5F5F7'; '#6E6E73' = '#98989D'
    '#E3E3E8' = '#38383A'; '#E5E5EA' = '#3A3A3C'; '#D1D1D6' = '#48484A'; '#C7C7CC' = '#636366'; '#007AFF' = '#0A84FF'
    '#DCEBFF' = '#1C3A5E'; '#248A3D' = '#30D158'; '#B25000' = '#FF9F0A'; '#D70015' = '#FF453A'; '#FF9500' = '#FF9F0A'
}
$script:D9DarkCard = '#2C2C2E'
$script:D9Theme = 'auto'   # auto | light | dark

# Темна тема: явно або за налаштуванням Windows «Режим застосунків: темний»
function Test-D9DarkTheme {
    param([string]$Theme = $script:D9Theme)
    if ($Theme -eq 'dark') { return $true }
    if ($Theme -eq 'light') { return $false }
    (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0
}

# Колір для поточної теми (для прямих присвоєнь Foreground у коді)
function Get-D9UiColor {
    param([string]$Color)
    if ($script:D9IsDark -and $script:D9DarkColors.Contains($Color.ToUpper())) { return $script:D9DarkColors[$Color.ToUpper()] }
    return $Color
}

# Дуга кільця: від верхньої точки за годинниковою стрілкою, value — 0–100; size — розмір кільця, thickness — товщина
function Get-D9RingGeometry {
    param([double]$Value, [double]$Size, [double]$Thickness)
    $v = [math]::Max(0, [math]::Min(100, $Value))
    $r = ($Size - $Thickness) / 2; $c = $Size / 2
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($v -ge 99.95) { return [Windows.Media.Geometry]::Parse(("M {0},{1} A {2},{2} 0 1 1 {0},{3} A {2},{2} 0 1 1 {0},{1}" -f $c.ToString($inv), ($c - $r).ToString($inv), $r.ToString($inv), ($c + $r).ToString($inv))) }
    if ($v -le 0) { return $null }
    $a = $v / 100 * 2 * [math]::PI
    $x = $c + $r * [math]::Sin($a); $y = $c - $r * [math]::Cos($a)
    $large = if ($v -gt 50) { 1 } else { 0 }
    [Windows.Media.Geometry]::Parse(("M {0},{1} A {2},{2} 0 {3} 1 {4},{5}" -f $c.ToString($inv), ($c - $r).ToString($inv), $r.ToString($inv), $large, $x.ToString($inv), $y.ToString($inv)))
}

function Convert-D9XamlTheme {
    param([Parameter(Mandatory)][string]$Xaml)
    foreach ($k in $script:D9DarkColors.Keys) { $Xaml = [regex]::Replace($Xaml, [regex]::Escape($k), $script:D9DarkColors[$k], 'IgnoreCase') }
    $card = $script:D9DarkCard
    $Xaml = $Xaml.Replace('Property="Background" Value="White"', "Property=`"Background`" Value=`"$card`"").Replace('Background="White"', "Background=`"$card`"")
    # Системні пензлі (випадні списки, виділення, вимкнені елементи) і стандартні елементи без власних стилів
    $inject = @"
    <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="$card"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#F5F5F7"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#3A3A3C"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlTextBrushKey}" Color="#F5F5F7"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#0A84FF"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.GrayTextBrushKey}" Color="#8E8E93"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.InfoBrushKey}" Color="#3A3A3C"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.InfoTextBrushKey}" Color="#F5F5F7"/>
"@
    return $Xaml.Replace('<Window.Resources>', "<Window.Resources>`r`n$inject")
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
    $script:D9IsDark = Test-D9DarkTheme
    $xamlText = Get-D9UiText 'MainWindow.xaml'
    [D9Row]::ColorMap.Clear()
    if ($script:D9IsDark) {
        $xamlText = Convert-D9XamlTheme $xamlText
        foreach ($k in $script:D9DarkColors.Keys) { [D9Row]::ColorMap[$k] = $script:D9DarkColors[$k] }
    }
    $win = [Windows.Markup.XamlReader]::Parse($xamlText)
    $ui = @{}
    foreach ($n in 'TitleText', 'SystemLine', 'AdminBadge', 'ScoreRing', 'StatusText', 'Progress', 'LogBox', 'LogExpander', 'Tabs',
                   'BtnFixAll', 'BtnScan', 'BtnDeepScan', 'BtnOpenReport', 'ScoreText', 'VerdictText', 'CountsText', 'CategoryList', 'FindingsList',
                   'BtnRunAuto', 'BtnMarkDone', 'BtnRecheck', 'BtnReboot', 'ChecklistSummary', 'ChecklistList',
                   'PresetBox', 'BtnSelectPreset', 'BtnSelectNone', 'BtnPreview', 'BtnApply', 'TweaksSummary', 'TweakGrid',
                   'BtnDriverScan', 'BtnOemPage', 'OemText', 'DriverProblemsList', 'DriverFolder', 'BtnBrowse', 'BtnFindDrivers',
                   'DriverPackageGrid', 'BtnInstallDrivers', 'DriverInstalledGrid', 'BtnDriverOnline', 'BtnDriverOnlineInstall', 'DriverOnlineGrid', 'BtnOemTool',
                   'BtnUndo', 'BtnRefreshSessions', 'BtnSystemRestore', 'BtnDiagnostics', 'SessionGrid',
                   'AppSearch', 'AppSearchHint', 'AppBundles', 'AppCategoryList', 'AppCards', 'AppSelectedText', 'BtnAppsClear', 'UninstSearch', 'UninstSearchHint', 'ChkUninstBloat', 'UninstSummary', 'UninstGrid', 'BtnUninstRefresh', 'BtnUninstall', 'UninstSelectedText', 'BtnAppsInstall', 'BtnAppsRefresh', 'BtnAppsUpgrade', 'AppsSummary', 'BtnWingetStore',
                   'UsbBox', 'BtnUsbRefresh', 'UsbInfo', 'UserNameBox', 'AccountPasswordBox', 'EditionBox', 'ChkUsbDrivers', 'ChkUsbBypass', 'ChkUsbPost', 'BtnPrepareUsb', 'BtnExportDrivers',
                   'ChkMtCleanup', 'ChkMtDefender', 'ChkMtApps', 'ChkMtDrivers', 'ChkMtWindows', 'MtDay', 'MtTime', 'BtnScheduleOn', 'BtnScheduleOff', 'BtnMaintainNow', 'ScheduleState',
                   'BtnStartupApply', 'BtnStartupRefresh', 'BtnStartupRecommended', 'StartupSummary', 'StartupGrid',
                   'BtnRestorePoint', 'BtnCleanNow', 'BtnRepair', 'BtnNetReset', 'BtnWuReset', 'PauseDays', 'BtnPause', 'BtnResume', 'PauseState', 'BtnWuDrivers', 'WuDriversState',
                   'BtnDisksRefresh', 'DisksState', 'DisksList', 'BtnIconCache', 'BtnMemoryTest', 'BtnSearchReset') {
        $ui[$n] = $win.FindName($n)
        if (-not $ui[$n]) { throw "У розмітці немає елемента $n" }
    }
    $isAdmin = Test-D9IsAdmin
    $state = @{ Job = $null; Scan = $null; Checklist = $null; ReportPath = $null; Categories = $null; Oem = $null; Packages = $null; TweakRows = $null }
    $actionButtons = @('BtnFixAll', 'BtnScan', 'BtnDeepScan', 'BtnRunAuto', 'BtnMarkDone', 'BtnRecheck', 'BtnApply', 'BtnPreview', 'BtnDriverScan', 'BtnFindDrivers', 'BtnInstallDrivers', 'BtnUndo',
                       'BtnStartupApply', 'BtnStartupRefresh', 'BtnRestorePoint', 'BtnCleanNow', 'BtnRepair', 'BtnNetReset', 'BtnWuReset', 'BtnPause', 'BtnResume', 'BtnWuDrivers', 'BtnDiagnostics',
                       'BtnAppsInstall', 'BtnAppsRefresh', 'BtnAppsUpgrade', 'BtnDriverOnline', 'BtnDriverOnlineInstall', 'BtnOemTool', 'BtnPrepareUsb', 'BtnExportDrivers', 'BtnScheduleOn', 'BtnScheduleOff', 'BtnMaintainNow', 'BtnUninstRefresh', 'BtnUninstall',
                       'BtnDisksRefresh', 'BtnIconCache', 'BtnMemoryTest', 'BtnSearchReset')

    # ---------- шапка ----------
    $s = $SystemInfo
    $disk = @{ hdd = 'HDD'; ssd = 'SSD'; nvme = 'NVMe SSD'; unknown = 'диск не визначено' }[[string]$s.SystemDisk]
    $ui.TitleText.Text = "Debora $script:D9Version"
    $ui.SystemLine.Text = "$($s.Manufacturer) $($s.Model)`n$($s.OsName) $($s.DisplayVersion)`n$($s.RamGB) ГБ, $disk, профіль $($Recommendation.Preset)"
    if ($isAdmin) { $ui.AdminBadge.Text = 'Адміністратор'; $ui.AdminBadge.Foreground = (Get-D9UiColor '#248A3D') }
    else { $ui.AdminBadge.Text = 'Без прав адміністратора — лише перегляд'; $ui.AdminBadge.Foreground = (Get-D9UiColor '#B25000') }
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
            if ($updateAppSelection) { & $updateAppSelection }
            if ($updateUninstSel) { & $updateUninstSel }
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
        [void][Windows.MessageBox]::Show($win, 'Для змін потрібні права адміністратора. Закрийте програму й запустіть її через run.bat.', 'Debora', 'OK', 'Warning')
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
                [void][Windows.MessageBox]::Show($win, "Не вдалося виконати: $($res.error)", 'Debora', 'OK', 'Error')
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
        $color = Get-D9UiColor (@{ good = '#248A3D'; attention = '#B25000'; serious = '#D70015' }[$scan.score.verdict])
        $ui.ScoreText.Text = "$($scan.score.overall)"; $ui.ScoreText.Foreground = $color
        $ui.ScoreRing.Stroke = $color
        $ui.ScoreRing.Data = Get-D9RingGeometry ([double]$scan.score.overall) 156 14
        $ui.VerdictText.Text = @{ good = 'Добрий стан'; attention = 'Потребує уваги'; serious = 'Є серйозні проблеми' }[$scan.score.verdict]
        $ui.VerdictText.Foreground = $color
        $counts = foreach ($k in 'critical', 'warning', 'suggestion') { $n = @($scan.findings | Where-Object severity -eq $k).Count; if ($n) { "$n $($script:D9SevUi[$k].Name)" } }
        $ui.CountsText.Text = "$(($counts) -join ', ')`nПеревірок: $(@($scan.checks).Count), $($scan.durationSec) с, $(([datetime]$scan.time).ToString('dd.MM.yyyy HH:mm'))"
        $cats = foreach ($c in $categories) {
            $v = $scan.score.categories.($c.id)
            if ($null -eq $v) { continue }
            New-D9Row @{ Title = (Get-D9Text $c.name); Number = [int]$v; Status = "$v"; Color = $(if ($v -ge 85) { '#248A3D' } elseif ($v -ge 60) { '#FF9500' } else { '#D70015' }) }
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
                         Color = $(if ($i.status -eq 'done') { '#248A3D' } elseif ($i.auto) { '#007AFF' } else { '#B25000' })
                         Note = $(if ($i.note) { "$($i.note)" } else { '' }); Links = (ConvertTo-D9UiLinks $i.links); Tag = $i }
        })
    }
    $catNames = @{ privacy = 'Конфіденційність'; apps = 'Застосунки'; ui = 'Інтерфейс'; performance = 'Швидкодія'; gaming = 'Ігри'; cleanup = 'Очищення'; updates = 'Оновлення'; safety = 'Безпека' }
    $riskUi = @{ safe = @('безпечно', '#248A3D'); moderate = @('помірно', '#B25000'); expert = @('експертний', '#D70015') }
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
            New-D9Row @{ Badge = '!'; Color = '#B25000'; Title = $_.Name; Detail = $detail; Links = (ConvertTo-D9UiLinks $_.Links) }
        })
        if (-not $problems) { $problems = @(New-D9Row @{ Badge = '✓'; Color = '#248A3D'; Title = 'Усі пристрої мають драйвери'; Detail = 'Перевірте лише вік драйверів у таблиці нижче.' }) }
        Set-D9Items $ui.DriverProblemsList $problems
        Set-D9Items $ui.DriverInstalledGrid @($rep.Important | ForEach-Object { New-D9Row @{ Group = $_.Group; Title = $_.Name; Status = $_.Version; Detail = $_.Date; Note = $_.Provider } })
    }
    $statusUi = @{ missing = @('встановити', '#D70015'); newer = @('оновити', '#007AFF'); current = @('вже актуальний', '#6E6E73') }
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
    # Одна кнопка для всього: сканування → список автоматичних кроків → виконання → повторне сканування
    $runChecklistWork = {
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
    }
    $ui.BtnFixAll.Add_Click({
        if (-not (& $needAdmin)) { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Сканування' $scanWork @{ Catalog = $Catalog; Sys = $SystemInfo; Deep = $false; ReportDir = $ReportDir } {
            param($r)
            & $onScanned $r
            $before = $r.Scan.score.overall
            $todo = @($r.Checklist.items | Where-Object { $_.auto -and $_.status -ne 'done' -and $_.action.action -ne 'reboot' })
            if (-not $todo) { [void][Windows.MessageBox]::Show($win, "Оцінка: $before/100. Автоматично виправляти нічого — решта порад на вкладці «Чекліст».", 'Debora'); return }
            $text = ($todo | ForEach-Object { "$($_.number). $($_.title)" }) -join "`r`n"
            $manual = @($r.Checklist.items | Where-Object { -not $_.auto -and $_.status -ne 'done' }).Count
            if (-not (Show-D9TextDialog $win 'Виправити все' "Оцінка зараз: $before/100. Debora виконає $($todo.Count) кроків сам (спершу — точка відновлення; усе відкочується в «Журналі змін»)$(if ($manual) { ". Ще $manual порад потребують вашого рішення — вони лишаться на вкладці «Чекліст»" })." $text 'Виконати')) { return }
            & $startJob 'Виправлення' $runChecklistWork @{ Catalog = $Catalog; Sys = $SystemInfo } {
                param($list, $c)
                & $fillChecklist $list
                & $fillSessions
                & $loadTweakStates
                # Повторне сканування — щоб показати результат
                & $startJob 'Повторне сканування' $scanWork @{ Catalog = $Catalog; Sys = $SystemInfo; Deep = $false; ReportDir = $ReportDir } {
                    param($r2, $c2)
                    & $onScanned $r2
                    $left = @($r2.Checklist.items | Where-Object { $_.status -ne 'done' -and $_.action.action -ne 'reboot' }).Count
                    $msg = "Оцінка: $($c2.Before) → $($r2.Scan.score.overall)/100.$(if ($left) { "`nЛишилось порад: $left — вкладка «Чекліст»." })`n`nПерезавантажити комп'ютер зараз, щоб усі зміни запрацювали?"
                    if ([Windows.MessageBox]::Show($win, $msg, 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force }
                } @{ Before = $c.Before }
            } @{ Before = $before }
        }
    })
    $ui.BtnRunAuto.Add_Click({
        if (-not $state.Checklist) { [void][Windows.MessageBox]::Show($win, 'Спочатку проскануйте комп''ютер.', 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        $todo = @($state.Checklist.items | Where-Object { $_.auto -and $_.status -ne 'done' -and $_.action.action -ne 'reboot' })
        if (-not $todo) { [void][Windows.MessageBox]::Show($win, 'Автоматичних кроків не залишилось.', 'Debora'); return }
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
            $answer = [Windows.MessageBox]::Show($win, 'Готово. Перезавантажити комп''ютер зараз, щоб усі зміни запрацювали?', 'Debora', 'YesNo', 'Question')
            if ($answer -eq 'Yes') { Restart-Computer -Force }
        }
    })
    $ui.BtnMarkDone.Add_Click({
        $row = $ui.ChecklistList.SelectedItem
        if (-not $row) { [void][Windows.MessageBox]::Show($win, 'Виберіть крок у списку.', 'Debora'); return }
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
        if ([Windows.MessageBox]::Show($win, 'Перезавантажити комп''ютер зараз? Збережіть відкриті документи.', 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force }
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
        if (-not $ids) { [void][Windows.MessageBox]::Show($win, 'Нічого не вибрано.', 'Debora'); return }
        & $startJob 'Підготовка попереднього перегляду' $previewWork @{ Catalog = $Catalog; Sys = $SystemInfo; Ids = $ids } {
            param($r) [void](Show-D9TextDialog $win 'Що зміниться' "Змін до застосування: $($r.Count)" $r.Text -InfoOnly)
        }
    })
    $ui.BtnApply.Add_Click({
        $ids = & $selectedIds
        if (-not $ids) { [void][Windows.MessageBox]::Show($win, 'Нічого не вибрано.', 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        & $startJob 'Підготовка попереднього перегляду' $previewWork @{ Catalog = $Catalog; Sys = $SystemInfo; Ids = $ids } {
            param($r, $c)
            if (-not $r.Count) { [void][Windows.MessageBox]::Show($win, 'Усе вибране вже застосовано.', 'Debora'); return }
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
                [void][Windows.MessageBox]::Show($win, "Готово. Змінено: $ok, помилок: $err.`nЧастина змін запрацює після перезавантаження. Відкат — на вкладці «Журнал змін».", 'Debora', 'OK', $(if ($err) { 'Warning' } else { 'Information' }))
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
            [void][Windows.MessageBox]::Show($win, "Папка порожня. Завантажте драйвери з сайту виробника (кнопка вгорі) і покладіть файли сюди як є — .zip теж можна:`n$folder", 'Debora')
            Start-Process explorer.exe $folder
            return
        }
        & $startJob 'Пошук драйверів у папці' { param($a) Find-D9DriverPackages -Folder $a.Folder } @{ Folder = $folder } { param($r) & $fillPackages $r }
    })
    $ui.BtnInstallDrivers.Add_Click({
        $chosen = @($ui.DriverPackageGrid.ItemsSource | Where-Object Selected | ForEach-Object Tag)
        if (-not $chosen) { [void][Windows.MessageBox]::Show($win, 'Нічого не вибрано.', 'Debora'); return }
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
            if ([Windows.MessageBox]::Show($win, $msg, 'Debora', 'YesNo', $(if ($err) { 'Warning' } else { 'Question' })) -eq 'Yes') { Restart-Computer -Force }
            & $driverReport
        }
    })

    # ---------- Драйвери з інтернету (Microsoft Update Catalog + Windows Update) ----------
    $fillOnline = {
        param($cands)
        $state.OnlineCands = @($cands | Where-Object { $_ })
        Set-D9Items $ui.DriverOnlineGrid @($state.OnlineCands | ForEach-Object {
            $kind = if ($_.Status -eq 'missing') { @('встановити', '#D70015') } elseif ($_.Optional) { @('необов''язково', '#6E6E73') } else { @('оновити', '#007AFF') }
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
        if ([Windows.MessageBox]::Show($win, "Встановити (за потреби) і запустити $($t.Name)?`nЦе фірмова утиліта $($t.Vendor): вона сама поставить драйвери, прошивки й BIOS для вашої моделі. Триває 10–30 хвилин; не вимикайте ПК, ноутбук — від мережі.", 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob "Запуск $($t.Name)" { param($a) Invoke-D9OemDriverTool -SystemInfo $a.Sys } @{ Sys = $SystemInfo } {
            param($r)
            $msg = if ($r.Done) { "$($r.Tool) завершила роботу." } else { "$($r.Tool) завершилась з кодом $($r.Code) — подробиці в журналі виконання." }
            if ($r.RebootRecommended) { if ([Windows.MessageBox]::Show($win, "$msg`n`nПерезавантажити комп'ютер зараз?", 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force } }
            else { [void][Windows.MessageBox]::Show($win, $msg, 'Debora') }
            & $driverReport
        }
    })
    $ui.BtnDriverOnline.Add_Click({
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Пошук драйверів онлайн' { param($a) @(Find-D9DriverUpdates -SystemInfo $a.Sys -IncludeWindowsUpdate) } @{ Sys = $SystemInfo } {
            param($r)
            & $fillOnline @($r)
            if (-not $state.OnlineCands) { [void][Windows.MessageBox]::Show($win, 'Новіших драйверів у каталозі Microsoft не знайдено — встановлені драйвери актуальні.', 'Debora') }
        }
    })
    $ui.BtnDriverOnlineInstall.Add_Click({
        $chosen = @($ui.DriverOnlineGrid.ItemsSource | Where-Object Selected | ForEach-Object Tag)
        if (-not $chosen) { [void][Windows.MessageBox]::Show($win, 'Позначте драйвери галочками.', 'Debora'); return }
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
            if (-not $r.Session) { [void][Windows.MessageBox]::Show($win, 'Після перевірки пакетів встановлювати нічого: поточні драйвери не старші.', 'Debora'); return }
            $ok = @($r.Session.entries | Where-Object result -eq 'ok').Count
            $err = @($r.Session.entries | Where-Object result -eq 'error')
            $msg = "Встановлено: $ok з $($r.Count), помилок: $($err.Count)."
            if ($err) { $msg += "`n" + (($err | Select-Object -First 6 | ForEach-Object { "• $($_.action.name): $($_.message)" }) -join "`n") }
            $msg += "`nЗавантажені пакети лежать у папці «Драйвери\Завантажені» — їх можна використати на такому самому ПК без інтернету."
            $msg += "`n`nПерезавантажити комп'ютер зараз, щоб драйвери запрацювали?"
            if ([Windows.MessageBox]::Show($win, $msg, 'Debora', 'YesNo', $(if ($err) { 'Warning' } else { 'Question' })) -eq 'Yes') { Restart-Computer -Force }
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
                [void][Windows.MessageBox]::Show($win, "Частина змін не застосувалась:`n" + (($err | Select-Object -First 8 | ForEach-Object { "• $($_.message)" }) -join "`n"), 'Debora', 'OK', 'Warning')
            }
            if ($c.After) { & $c.After $session }
        } @{ After = $after }
    }

    # ---------- кнопки: Автозавантаження ----------
    $fillStartup = {
        param($items)
        $state.StartupRows = @(foreach ($i in $items) {
            $note = @(); $color = '#6E6E73'
            switch ($i.Verdict) {
                'disable'  { $note += "рекомендуємо вимкнути: $($i.Reason)"; $color = '#B25000' }
                'optional' { $note += "можна вимкнути: $($i.Reason)" }
                'keep'     { $note += "потрібне: $($i.Reason)"; $color = '#248A3D' }
            }
            if ($i.Missing) { $note += 'файл відсутній — запис можна вимкнути'; $color = '#D70015' }
            if (-not $i.Publisher -and -not $i.Verdict) { $note += 'видавець невідомий' }
            New-D9Row @{ Selected = [bool]$i.Enabled; Title = $i.Name; Detail = $i.Command; Group = $(if ($i.Publisher) { $i.Publisher } else { '—' })
                         Note = $i.Where; Status = ($note -join '; '); Color = $color; Tag = $i }
        })
        Set-D9Items $ui.StartupGrid $state.StartupRows
        $on = @($items | Where-Object Enabled).Count
        $rec = @($items | Where-Object { $_.Enabled -and ($_.Verdict -eq 'disable' -or $_.Missing) }).Count
        $ui.BtnStartupRecommended.IsEnabled = [bool]$rec
        $ui.BtnStartupRecommended.Content = if ($rec) { "Вимкнути рекомендовані ($rec)" } else { 'Вимкнути рекомендовані' }
        $ui.StartupSummary.Text = "Програм в автозавантаженні: $(@($items).Count), запускаються: $on$(if ($rec) { ", з них рекомендуємо вимкнути: $rec" }). Зніміть галочку з тих, яким не потрібно стартувати разом із Windows, і натисніть «Застосувати зміни» — або «Вимкнути рекомендовані». Програми не видаляються; усе відкочується в «Журналі змін»."
    }
    $loadStartup = { & $startJob 'Читання автозавантаження' { Get-D9StartupItems } $null { param($r) & $fillStartup @($r) } }
    $ui.BtnStartupRefresh.Add_Click($loadStartup)
    $ui.BtnStartupRecommended.Add_Click({
        foreach ($r in $state.StartupRows) { if ($r.Tag.Enabled -and ($r.Tag.Verdict -eq 'disable' -or $r.Tag.Missing)) { $r.Selected = $false } }
        $ui.BtnStartupApply.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
    })
    $ui.BtnStartupApply.Add_Click({
        $changes = @($state.StartupRows | Where-Object { $_.Selected -ne [bool]$_.Tag.Enabled } | ForEach-Object { @{ Item = $_.Tag; Enable = $_.Selected } })
        if (-not $changes) { [void][Windows.MessageBox]::Show($win, 'Змін немає: поставте або зніміть галочки.', 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        $text = ($changes | ForEach-Object { "$(if ($_.Enable) { 'Увімкнути' } else { 'Вимкнути' }): $($_.Item.Name)" }) -join "`r`n"
        if (-not (Show-D9TextDialog $win 'Автозавантаження' "Змін: $($changes.Count). Подіють після наступного входу в Windows." $text)) { return }
        & $applyCatalog (New-D9StartupCatalog -Changes $changes) 'Зміна автозавантаження' 'автозавантаження' { & $loadStartup } -NoRestorePoint
    })

    # ---------- кнопки: Обслуговування ----------
    $diskColors = @{ ok = '#248A3D'; warn = '#B25000'; bad = '#D70015'; unknown = '#6E6E73' }
    $loadDisks = {
        & $startJob 'Перевірка стану дисків' { @(Get-D9DiskHealth) } $null {
            param($r)
            $disks = @($r | Where-Object { $_ })
            $rows = foreach ($d in $disks) {
                $v = Get-D9DiskVerdict $d
                $row = New-Object D9Row
                $row.Title = Format-D9DiskTitle $d
                $row.Status = $script:D9DiskLevelText[$v.Level]
                $row.Color = $diskColors[$v.Level]
                $row.Note = if ($v.Problems) { ($v.Problems -join '; ') + $(if ($v.Level -eq 'bad') { '. Негайно скопіюйте важливі файли й замініть диск.' }) } else { '' }
                $row.Detail = Format-D9DiskDetails $d
                $row
            }
            $state.DisksLoaded = $true
            Set-D9Items $ui.DisksList @($rows)
            $bad = @($disks | Where-Object { -not $_.Removable -and (Get-D9DiskVerdict $_).Level -eq 'bad' })
            $ui.DisksState.Text = if ($bad) { "Несправних дисків: $($bad.Count). Збережіть дані на інший диск або в хмару." }
                                  elseif (-not $isAdmin) { 'Без прав адміністратора Windows показує лише загальний стан; температура, знос і помилки — після запуску через run.bat.' }
                                  else { "Перевірено $(Get-Date -Format 'HH:mm'). Температура, знос SSD, години роботи й помилки (SMART)." }
        }
    }
    $ui.BtnDisksRefresh.Add_Click($loadDisks)
    $ui.BtnIconCache.Add_Click({
        if ([Windows.MessageBox]::Show($win, "Скинути кеш значків і ескізів?`nПровідник перезапуститься: панель задач на мить зникне, відкриті вікна папок закриються. Файли не зачіпаються.", 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        & $startJob 'Скидання кешу значків' { Reset-D9IconCache } $null { param($r) [void][Windows.MessageBox]::Show($win, "Готово: видалено файлів кешу — $($r.Removed). Значки з'являться заново за хвилину.", 'Debora') }
    })
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
        if ([Windows.MessageBox]::Show($win, $confirm, 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob $title { param($a) & $a.Fn } @{ Fn = $function } {
            param($r)
            $msg = 'Готово. Подробиці — у журналі виконання внизу.'
            if ($r.RebootRecommended) {
                if ([Windows.MessageBox]::Show($win, "$msg`n`nПерезавантажити комп'ютер зараз?", 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force }
            } else { [void][Windows.MessageBox]::Show($win, $msg, 'Debora') }
        }
    }
    $ui.BtnRepair.Add_Click({ & $maintenanceJob 'Відновлення системних файлів' "Перевірити й відновити системні файли Windows?`nЦе триває 10–40 хвилин; комп'ютером можна користуватися." 'Invoke-D9RepairSystem' })
    $ui.BtnNetReset.Add_Click({ & $maintenanceJob 'Скидання мережі' "Скинути мережеві налаштування?`nWi-Fi-мережі й паролі збережуться; після перезавантаження з'єднання налаштується заново." 'Invoke-D9NetworkReset' })
    $ui.BtnWuReset.Add_Click({ & $maintenanceJob 'Скидання Windows Update' "Скинути Windows Update?`nСлужби буде перезапущено, кеш оновлень створиться заново." 'Invoke-D9WindowsUpdateReset' })
    $ui.BtnMemoryTest.Add_Click({ & $maintenanceJob 'Перевірка пам''яті' "Запланувати перевірку оперативної пам'яті?`nПід час наступного перезавантаження Windows 10–20 хвилин перевірятиме пам'ять, потім запуститься як звичайно." 'Invoke-D9MemoryTestOnReboot' })
    $ui.BtnSearchReset.Add_Click({ & $maintenanceJob 'Перебудова пошукового індексу' "Перебудувати пошуковий індекс Windows?`nСтарий індекс буде видалено; новий створиться у фоні, і кілька годин пошук знаходитиме не все." 'Reset-D9SearchIndex' })
    $ui.BtnRestorePoint.Add_Click({
        if (-not (& $needAdmin)) { return }
        & $startJob 'Створення точки відновлення' { New-D9RestorePoint } $null {
            param($name)
            if ($name) { [void][Windows.MessageBox]::Show($win, "Точку відновлення створено: $name", 'Debora') }
            else { [void][Windows.MessageBox]::Show($win, 'Не вдалося створити точку відновлення. Можливо, вимкнено захист системи (кнопка «Відновлення системи Windows» → Налаштувати).', 'Debora', 'OK', 'Warning') }
        }
    })
    $ui.BtnCleanNow.Add_Click({
        if (-not (& $needAdmin)) { return }
        if ([Windows.MessageBox]::Show($win, "Видалити тимчасові файли, кеш оновлень Windows, дампи збоїв і залишки інсталяторів?`nЦе не можна відкотити, але ці файли не потрібні.", 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        $ids = 'cleanup.temp', 'cleanup.update-cache', 'cleanup.leftovers', 'cleanup.do-cache'
        $cat = [pscustomobject]@{ Tweaks = @($Catalog.Tweaks | Where-Object { $ids -contains $_.id }); Presets = @() }
        $state.FreeBefore = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'").FreeSpace
        & $applyCatalog $cat 'Очищення диска' 'очищення диска' {
            $after = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'").FreeSpace
            [void][Windows.MessageBox]::Show($win, "Звільнено: $(Format-D9Size ([math]::Max(0, $after - $state.FreeBefore)))", 'Debora')
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
        if ([Windows.MessageBox]::Show($win, "$(Get-D9Text $t.description)`n`nВимкнути встановлення драйверів через Windows Update?", 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
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
        if (-not $row) { [void][Windows.MessageBox]::Show($win, 'Виберіть сесію в таблиці.', 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        if ([Windows.MessageBox]::Show($win, "Відкотити зміни сесії «$($row.Detail)» ($($row.Title))?", 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        & $startJob 'Відкат змін' { param($a) Undo-D9Session -Id $a.Id } @{ Id = $row.Id } {
            param($report)
            $report = @($report)
            $restored = @($report | Where-Object result -eq 'restored').Count
            $other = @($report | Where-Object { $_.result -ne 'restored' })
            $msg = "Відновлено: $restored."
            if ($other) { $msg += "`nПотребує уваги ($($other.Count)):`n" + (($other | Select-Object -First 10 | ForEach-Object { "• $($_.tweak): $($_.message)" }) -join "`n") }
            & $fillSessions
            & $loadTweakStates
            [void][Windows.MessageBox]::Show($win, "$msg`n`nДеякі зміни повернуться після перезавантаження.", 'Debora')
        }
    })

    # ---------- Програми (winget) ----------
    $hasWinget = [bool](Get-D9WingetPath)
    $appCatalog = Import-D9AppCatalog
    $appCats = [ordered]@{}
    foreach ($c in $appCatalog.categories) { $appCats[[string]$c.id] = Get-D9Text $c.name }
    $state.AppUpgrades = @{}
    $state.AppFilter = 'popular'
    $appIcons = Get-D9AppIconData
    $state.AppRows = @($appCatalog.apps | ForEach-Object {
        New-D9Row @{ Id = $_.id; Title = $_.name; Group = $appCats[[string]$_.category]; Note = (Get-D9Text $_.description); Status = ''; Color = '#6E6E73'; Tag = $_
                     Icon = (ConvertTo-D9Image $appIcons[$_.id]); Initial = ([string]$_.name).Substring(0, 1).ToUpper() }
    })
    # Картки програм заповнюють усю ширину: кількість колонок — за шириною області
    $ui.AppCards.Tag = 2
    $ui.AppCards.Parent.Add_SizeChanged({ param($sender, $e) $ui.AppCards.Tag = [math]::Max(1, [math]::Floor(($e.NewSize.Width - 14) / 290)) })
    $appStatus = { param($row) if ($row.Status -like 'є оновлення*') { 'update' } elseif ($row.Status -eq 'встановлено') { 'installed' } else { 'none' } }
    # Категорії ліворуч: службові + з каталогу, з кількістю
    $fillAppCategories = {
        $rows = $state.AppRows
        $list = @(
            @{ Id = 'popular'; Title = '★ Популярне'; N = @($rows | Where-Object { $_.Tag.popular }).Count }
            @{ Id = 'all'; Title = 'Усі програми'; N = $rows.Count }
            @{ Id = 'selected'; Title = '✓ Вибрані'; N = @($rows | Where-Object Selected).Count }
            @{ Id = 'installed'; Title = 'Встановлені'; N = @($rows | Where-Object { (& $appStatus $_) -ne 'none' }).Count }
            @{ Id = 'update'; Title = 'Є оновлення'; N = @($rows | Where-Object { (& $appStatus $_) -eq 'update' }).Count }
        ) + @($appCats.Keys | ForEach-Object { $id = $_; @{ Id = "cat:$id"; Title = $appCats[$id]; N = @($rows | Where-Object { $_.Tag.category -eq $id }).Count } })
        $state.AppCategoryRows = @($list | ForEach-Object { New-D9Row @{ Id = $_.Id; Title = $_.Title; Status = $(if ($_.N) { "$($_.N)" } else { '' }) } })
        $state.AppCategoryUpdating = $true
        Set-D9Items $ui.AppCategoryList $state.AppCategoryRows
        $ui.AppCategoryList.SelectedIndex = [math]::Max(0, [array]::IndexOf(@($state.AppCategoryRows.Id), $state.AppFilter))
        $state.AppCategoryUpdating = $false
    }
    $showApps = {
        $q = $ui.AppSearch.Text.Trim()
        $f = $state.AppFilter
        $shown = @($state.AppRows | Where-Object {
            $row = $_   # усередині switch $_ — це значення фільтра
            # Пошук — по всьому каталогу, незалежно від категорії
            if ($q) { return ($row.Title -like "*$q*" -or $row.Note -like "*$q*" -or $row.Group -like "*$q*" -or $row.Id -like "*$q*") }
            switch -Wildcard ($f) {
                'popular'   { [bool]$row.Tag.popular }
                'all'       { $true }
                'selected'  { [bool]$row.Selected }
                'installed' { (& $appStatus $row) -ne 'none' }
                'update'    { (& $appStatus $row) -eq 'update' }
                'cat:*'     { $row.Tag.category -eq $f.Substring(4) }
            }
        })
        Set-D9Items $ui.AppCards $shown
    }
    $updateAppSelection = {
        $sel = @($state.AppRows | Where-Object Selected)
        $upd = @($sel | Where-Object { (& $appStatus $_) -eq 'update' }).Count
        $ui.AppSelectedText.Text = if ($sel) { "Вибрано: $($sel.Count)$(if ($upd) { " (з них оновити: $upd)" }) — $(($sel | Select-Object -First 6 | ForEach-Object Title) -join ', ')$(if ($sel.Count -gt 6) { '…' })" } else { 'Нічого не вибрано. Клацніть по картці програми, щоб вибрати.' }
        $ui.BtnAppsInstall.Content = if ($sel) { "Встановити вибрані ($($sel.Count))" } else { 'Встановити вибрані' }
        $ui.BtnAppsInstall.IsEnabled = [bool]$sel -and $hasWinget -and -not $state.Job
        $c = $state.AppCategoryRows | Where-Object Id -eq 'selected' | Select-Object -First 1
        if ($c) { $c.Status = $(if ($sel) { "$($sel.Count)" } else { '' }) }
    }
    & $fillAppCategories
    & $showApps
    & $updateAppSelection
    $ui.AppCategoryList.Add_SelectionChanged({
        if ($state.AppCategoryUpdating -or -not $ui.AppCategoryList.SelectedItem) { return }
        $state.AppFilter = $ui.AppCategoryList.SelectedItem.Id
        if ($ui.AppSearch.Text) { $ui.AppSearch.Text = '' } else { & $showApps }
    })
    $ui.AppSearch.Add_TextChanged({
        $ui.AppSearchHint.Visibility = if ($ui.AppSearch.Text) { 'Collapsed' } else { 'Visible' }
        & $showApps
    })
    # Клік по галочці в будь-якій картці (подія Click спливає від CheckBox до списку)
    $ui.AppCards.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{ & $updateAppSelection })
    foreach ($b in @($appCatalog.bundles)) {
        $btn = New-Object Windows.Controls.Button
        $btn.Style = $win.FindResource('Chip')
        $btn.Content = Get-D9Text $b.name; $btn.ToolTip = Get-D9Text $b.description; $btn.Tag = @($b.apps)
        $btn.Add_Click({
            param($sender, $e)
            $ids = @($sender.Tag)
            foreach ($r in $state.AppRows) { if ($ids -contains $r.Id -and $r.Enabled) { $r.Selected = $true } }
            $state.AppFilter = 'selected'
            & $fillAppCategories; & $showApps; & $updateAppSelection
        })
        [void]$ui.AppBundles.Children.Add($btn)
    }
    $ui.BtnAppsClear.Add_Click({ foreach ($r in $state.AppRows) { $r.Selected = $false }; if ($state.AppFilter -eq 'selected') { & $showApps }; & $updateAppSelection })

    if (-not $hasWinget) {
        $ui.AppsSummary.Text = 'winget не знайдено — без нього програми не встановлюються. Встановіть «Інсталятор застосунків» з Microsoft Store і перезапустіть Debora.'
        $ui.BtnWingetStore.Visibility = 'Visible'
    }
    $ui.BtnWingetStore.Add_Click({ Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' })
    $noWinget = { [void][Windows.MessageBox]::Show($win, 'winget не знайдено. Встановіть «Інсталятор застосунків» з Microsoft Store (посилання на вкладці).', 'Debora', 'OK', 'Warning') }
    # Стан картки: встановлено / є оновлення (можна вибрати й оновити) / не встановлено
    $markApp = {
        param($row, [bool]$installed)
        $up = $state.AppUpgrades[[string]$row.Id]
        if ($installed -and $up) { $row.Status = "є оновлення: $($up.Version) → $($up.Available)"; $row.Color = '#007AFF'; $row.Enabled = $true }
        elseif ($installed) { $row.Status = 'встановлено'; $row.Color = '#248A3D'; $row.Selected = $false; $row.Enabled = $false }
        else { $row.Status = 'не встановлено'; $row.Color = '#6E6E73'; $row.Enabled = $true }
    }
    $loadApps = {
        if (-not $hasWinget) { return }
        & $startJob 'Перевірка встановлених програм' { $s = Get-D9InstalledAppIds; @{ Ids = [string[]]@($s); Up = @(Get-D9AppUpgrades) } } $null {
            param($r)
            $state.AppUpgrades = @{}
            foreach ($u in @($r.Up)) { if ($u.Id) { $state.AppUpgrades[[string]$u.Id] = $u } }
            $ids = @($r.Ids)
            foreach ($row in $state.AppRows) { & $markApp $row ($ids -contains $row.Id -or $state.AppUpgrades.ContainsKey([string]$row.Id)) }
            $state.AppsLoaded = $true
            & $fillAppCategories; & $showApps; & $updateAppSelection
            $inst = @($state.AppRows | Where-Object { (& $appStatus $_) -ne 'none' }).Count
            $ui.AppsSummary.Text = "У каталозі $(@($state.AppRows).Count) програм, з них у вас встановлено $inst, мають оновлення $(@($r.Up).Count) (усього на ПК). Клацніть по картці, щоб вибрати, або скористайтеся готовим набором."
        }
    }
    $ui.BtnAppsRefresh.Add_Click({ if ($hasWinget) { & $loadApps } else { & $noWinget } })
    $ui.BtnAppsInstall.Add_Click({
        if (-not $hasWinget) { & $noWinget; return }
        $sel = @($state.AppRows | Where-Object Selected)
        if (-not $sel) { return }
        $toUpdate = @($sel | Where-Object { (& $appStatus $_) -eq 'update' })
        $toInstall = @($sel | Where-Object { (& $appStatus $_) -ne 'update' })
        $text = @()
        if ($toInstall) { $text += "Встановити ($($toInstall.Count)):"; $text += @($toInstall | ForEach-Object { "  • $($_.Title)" }) }
        if ($toUpdate) { $text += "Оновити ($($toUpdate.Count)):"; $text += @($toUpdate | ForEach-Object { "  • $($_.Title)" }) }
        if (-not (Show-D9TextDialog $win 'Програми' "Встановлення йде у фоні; деякі інсталятори можуть показати власне вікно." ($text -join "`r`n") 'Встановити')) { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Встановлення програм' {
            param($a)
            @(if ($a.Install) { Install-D9Apps -Apps $a.Install }) + @(if ($a.Update) { Update-D9Apps -Ids $a.Update })
        } @{ Install = @($toInstall | ForEach-Object Tag); Update = @($toUpdate | ForEach-Object Id) } {
            param($res)
            $res = @($res | Where-Object { $_ })
            foreach ($r in $res) {
                $row = $state.AppRows | Where-Object Id -eq $r.id | Select-Object -First 1
                if (-not $row) { continue }
                if ($r.result -in 'failed', 'notFound') { $row.Status = 'помилка — див. журнал'; $row.Color = '#D70015' }
                else { $state.AppUpgrades.Remove([string]$row.Id); & $markApp $row $true }
            }
            & $fillAppCategories; & $showApps; & $updateAppSelection
            $bad = @($res | Where-Object { $_.result -in 'failed', 'notFound' })
            $names = @{}; foreach ($r in $state.AppRows) { $names[[string]$r.Id] = $r.Title }
            $msg = "Готово: $($res.Count - $bad.Count) з $($res.Count)."
            if ($bad) { $msg += "`nНе вдалося: $(($bad | ForEach-Object { $names[[string]$_.id] }) -join ', '). Подробиці — у журналі виконання внизу." }
            if (@($res | Where-Object result -eq 'reboot')) { $msg += "`nДеякі програми запрацюють після перезавантаження." }
            [void][Windows.MessageBox]::Show($win, $msg, 'Debora', 'OK', $(if ($bad) { 'Warning' } else { 'Information' }))
        }
    })
    $ui.BtnAppsUpgrade.Add_Click({
        if (-not $hasWinget) { & $noWinget; return }
        & $startJob 'Пошук оновлень програм' { @(Get-D9AppUpgrades) } $null {
            param($up)
            $up = @($up | Where-Object { $_ })
            if (-not $up) { [void][Windows.MessageBox]::Show($win, 'Усі програми актуальні.', 'Debora'); return }
            $text = ($up | ForEach-Object { "$($_.Name)    $($_.Version) → $($_.Available)" }) -join "`r`n"
            if (-not (Show-D9TextDialog $win 'Оновити програми' "Оновлення є для $($up.Count) програм (усі, не лише з каталогу). Відкриті програми краще закрити — їх не вдасться оновити." $text)) { return }
            $ui.LogExpander.IsExpanded = $true
            & $startJob 'Оновлення програм' { Invoke-D9AppUpgradeAll } $null {
                param($r)
                $ok = $r.Result -in 'installed', 'upToDate'
                [void][Windows.MessageBox]::Show($win, $(if ($ok) { 'Програми оновлено.' } else { 'Оновлення завершено, але частину програм (наприклад, відкритих зараз) оновити не вдалося. Подробиці — у журналі виконання внизу.' }), 'Debora', 'OK', $(if ($ok) { 'Information' } else { 'Warning' }))
                & $loadApps
            }
        }
    })
    # ---------- Видалення програм ----------
    $fillUninst = {
        param($list)
        $state.UninstRows = @(@($list | Where-Object { $_ }) | Sort-Object @{ Expression = { [bool]$_.Bloat }; Descending = $true }, Name | ForEach-Object {
            $cmd = Get-D9UninstallCommand $_
            $note = if ($_.Bloat) { @("Рекомендуємо видалити: $($_.Bloat)", '#D70015') }
                    elseif ($_.Keep) { @('Потрібна іншим програмам або обладнанню — краще не видаляти', '#B25000') }
                    elseif ($cmd -and -not $cmd.Silent) { @('відкриється вікно деінсталятора', '#6E6E73') }
                    else { @('', '#6E6E73') }
            New-D9Row @{ Title = $_.Name; Detail = "Версія: $($_.Version)$(if ($cmd) { '; видалення: ' + $(if ($cmd.Silent) { 'тихо' } else { 'з вікном деінсталятора' }) })"
                         Group = $_.Publisher; Note = $(if ($_.Size) { Format-D9Size $_.Size } else { '' }); Kind = $(if ($_.InstallDate) { ([datetime]$_.InstallDate).ToString('dd.MM.yyyy') } else { '' })
                         Status = $note[0]; Color = $note[1]; Tag = $_ }
        })
        & $showUninst
        $bloat = @($state.UninstRows | Where-Object { $_.Tag.Bloat }).Count
        $ui.UninstSummary.Text = "Встановлено програм: $(@($state.UninstRows).Count)$(if ($bloat) { ", з них рекомендуємо видалити: $bloat (вгорі списку)" }). Більшість видаляється тихо; для решти відкриється звичайний деінсталятор."
        & $updateUninstSel
    }
    $showUninst = {
        $q = $ui.UninstSearch.Text.Trim()
        $onlyBloat = [bool]$ui.ChkUninstBloat.IsChecked
        Set-D9Items $ui.UninstGrid @($state.UninstRows | Where-Object { (-not $onlyBloat -or $_.Tag.Bloat) -and (-not $q -or $_.Title -like "*$q*" -or $_.Group -like "*$q*") })
    }
    $updateUninstSel = {
        $sel = @($state.UninstRows | Where-Object Selected)
        $size = [long](($sel | ForEach-Object { $_.Tag.Size } | Measure-Object -Sum).Sum)
        $ui.UninstSelectedText.Text = if ($sel) { "Вибрано: $($sel.Count)$(if ($size) { ", звільниться ≈ $(Format-D9Size $size)" }). Після видалення Debora запропонує прибрати залишки." } else { 'Нічого не вибрано' }
        $ui.BtnUninstall.Content = if ($sel) { "Видалити вибрані ($($sel.Count))" } else { 'Видалити вибрані' }
        $ui.BtnUninstall.IsEnabled = [bool]$sel -and -not $state.Job
    }
    $loadUninst = { & $startJob 'Читання списку програм (розміри папок рахуються лише першого разу)' { @(Get-D9UninstallListDetailed) } $null { param($r) & $fillUninst @($r) } }
    $ui.UninstSearch.Add_TextChanged({ $ui.UninstSearchHint.Visibility = if ($ui.UninstSearch.Text) { 'Collapsed' } else { 'Visible' }; & $showUninst })
    $ui.ChkUninstBloat.Add_Click({ & $showUninst })
    $ui.UninstGrid.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{ & $updateUninstSel })
    $ui.BtnUninstRefresh.Add_Click($loadUninst)
    $ui.BtnUninstall.Add_Click({
        $sel = @($state.UninstRows | Where-Object Selected)
        if (-not $sel) { return }
        if (-not (& $needAdmin)) { return }
        $lines = @($sel | ForEach-Object {
            $c = Get-D9UninstallCommand $_.Tag
            "• $($_.Title)$(if ($c -and -not $c.Silent) { '  (відкриється вікно деінсталятора)' })$(if ($_.Tag.Keep) { '  ⚠ потрібна іншим програмам' })"
        })
        if (-not (Show-D9TextDialog $win 'Видалення програм' "Буде видалено $($sel.Count) програм(и). Перед цим створюється точка відновлення; повернути програму — встановити знову (вкладка «Програми»)." ($lines -join "`r`n") 'Видалити')) { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Видалення програм' {
            param($a)
            Write-D9Log 'Створення точки відновлення...'
            [void](New-D9RestorePoint)
            @(Uninstall-D9Programs -Programs $a.Programs)
        } @{ Programs = @($sel | ForEach-Object Tag) } {
            param($res)
            $res = @($res | Where-Object { $_ })
            $ok = @($res | Where-Object { $_.result -in 'removed', 'reboot' })
            $bad = @($res | Where-Object { $_.result -notin 'removed', 'reboot' })
            $msg = "Видалено: $($ok.Count) з $($res.Count)."
            if ($bad) { $msg += "`n" + (($bad | ForEach-Object { "• $($_.name): $($_.message)" }) -join "`n") }
            if (@($res | Where-Object result -eq 'reboot')) { $msg += "`nДля завершення потрібне перезавантаження." }
            [void][Windows.MessageBox]::Show($win, $msg, 'Debora', 'OK', $(if ($bad) { 'Warning' } else { 'Information' }))
            # Залишки: папки й розділи реєстру, які деінсталятори не прибрали
            $left = @($res | ForEach-Object { $_.leftovers } | Where-Object { $_ })
            if ($left) {
                $size = [long](($left | Measure-Object Size -Sum).Sum)
                $text = ($left | ForEach-Object { if ($_.Type -eq 'folder') { "Папка:  $($_.Path)$(if ($_.Size) { '  (' + (Format-D9Size $_.Size) + ')' })" } else { "Реєстр: $($_.Path)" } }) -join "`r`n"
                if (Show-D9TextDialog $win 'Залишки після видалення' "Деінсталятори лишили $($left.Count) папок і розділів реєстру$(if ($size) { ' (' + (Format-D9Size $size) + ')' }). Прибрати? Папки підуть у Кошик, розділи реєстру — з резервною копією .reg, тож усе можна повернути." $text 'Прибрати') {
                    & $startJob 'Прибирання залишків' { param($a) Remove-D9UninstallLeftovers -Items $a.Items } @{ Items = $left } {
                        param($r)
                        [void][Windows.MessageBox]::Show($win, "Прибрано: $($r.Removed). Папки — у Кошику; копія реєстру — $($r.Backup)", 'Debora')
                        & $loadUninst
                    }
                    return
                }
            }
            & $loadUninst
        }
    })

    # ---------- Автоматичне обслуговування ----------
    $dayNames = [ordered]@{ Monday = 'понеділок'; Tuesday = 'вівторок'; Wednesday = 'середа'; Thursday = 'четвер'; Friday = 'п''ятниця'; Saturday = 'субота'; Sunday = 'неділя' }
    foreach ($d in $dayNames.Values) { [void]$ui.MtDay.Items.Add($d) }
    $mtBoxes = [ordered]@{ cleanup = 'ChkMtCleanup'; defender = 'ChkMtDefender'; apps = 'ChkMtApps'; drivers = 'ChkMtDrivers'; windowsUpdate = 'ChkMtWindows' }
    $readSchedule = {
        [pscustomobject]@{
            Steps = @($mtBoxes.Keys | Where-Object { $ui[$mtBoxes[$_]].IsChecked })
            Day   = @($dayNames.Keys)[[math]::Max(0, $ui.MtDay.SelectedIndex)]
            Time  = $ui.MtTime.Text.Trim()
        }
    }
    $refreshSchedule = {
        $cfg = Get-D9MaintenanceConfig
        foreach ($k in $mtBoxes.Keys) { $ui[$mtBoxes[$k]].IsChecked = @($cfg.Steps) -contains $k }
        $ui.MtDay.SelectedIndex = [math]::Max(0, [array]::IndexOf(@($dayNames.Keys), [string]$cfg.Day))
        $ui.MtTime.Text = $cfg.Time
        $task = try { Get-D9MaintenanceTask } catch { $null }
        $last = Get-D9MaintenanceLast
        $lines = @()
        $lines += if ($task) { "Розклад увімкнено: щотижня, $($dayNames[[string]$cfg.Day]) о $($cfg.Time)$(if ($task.NextRun) { '; наступний запуск ' + ([datetime]$task.NextRun).ToString('dd.MM.yyyy HH:mm') })." } else { 'Розклад вимкнено.' }
        if ($last) { $lines += "Останнє обслуговування $(([datetime]$last.finished).ToString('dd.MM.yyyy HH:mm')): $(Format-D9MaintenanceSummary $last)." }
        $ui.ScheduleState.Text = $lines -join "`n"
        $ui.BtnScheduleOn.Content = if ($task) { 'Зберегти розклад' } else { 'Увімкнути розклад' }
    }
    $ui.BtnScheduleOn.Add_Click({
        if (-not (& $needAdmin)) { return }
        $src = Join-Path (Split-Path $DriverDir) 'Debora.ps1'
        if (-not $script:D9Embedded -or -not (Test-Path $src)) { [void][Windows.MessageBox]::Show($win, 'Розклад працює лише зі зібраним Debora.ps1 (запуск через run.bat).', 'Debora', 'OK', 'Warning'); return }
        $cfg = & $readSchedule
        if (-not $cfg.Steps) { [void][Windows.MessageBox]::Show($win, 'Позначте хоча б одну дію.', 'Debora'); return }
        if ($cfg.Time -notmatch '^\d{1,2}:\d{2}$') { [void][Windows.MessageBox]::Show($win, 'Час — у форматі 12:00.', 'Debora'); return }
        try { Register-D9MaintenanceTask -SourceScript $src -Config $cfg; & $refreshSchedule }
        catch { [void][Windows.MessageBox]::Show($win, "Не вдалося створити розклад: $($_.Exception.Message)", 'Debora', 'OK', 'Error') }
    })
    $ui.BtnScheduleOff.Add_Click({
        if (-not (& $needAdmin)) { return }
        try { Unregister-D9MaintenanceTask } catch { }
        & $refreshSchedule
    })
    $ui.BtnMaintainNow.Add_Click({
        if (-not (& $needAdmin)) { return }
        $cfg = & $readSchedule
        if (-not $cfg.Steps) { [void][Windows.MessageBox]::Show($win, 'Позначте хоча б одну дію.', 'Debora'); return }
        if ([Windows.MessageBox]::Show($win, "Виконати обслуговування зараз?`n$(($cfg.Steps | ForEach-Object { '• ' + $script:D9MaintenanceSteps[$_] }) -join "`n")`n`nСпершу буде створено точку відновлення. Може тривати від кількох хвилин до години.", 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        Save-D9MaintenanceConfig $cfg
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Автоматичне обслуговування' { param($a) Invoke-D9Maintenance -Catalog $a.Catalog -SystemInfo $a.Sys -Steps $a.Steps } @{ Catalog = $Catalog; Sys = $SystemInfo; Steps = $cfg.Steps } {
            param($s)
            & $refreshSchedule; & $fillSessions
            $msg = "Готово. $(Format-D9MaintenanceSummary $s)."
            if ($s.reboot) { if ([Windows.MessageBox]::Show($win, "$msg`n`nПерезавантажити комп'ютер зараз?", 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force } }
            else { [void][Windows.MessageBox]::Show($win, $msg, 'Debora') }
        }
    })

    # ---------- Перевстановлення Windows ----------
    $fillUsb = {
        $state.UsbMedia = @(Get-D9InstallMedia)
        $ui.UsbBox.Items.Clear()
        foreach ($m in $state.UsbMedia) {
            [void]$ui.UsbBox.Items.Add("$($m.Drive) $(if ($m.Label) { "«$($m.Label)» " })— файли встановлення Windows$(if ($m.Language) { " ($($m.Language))" }), вільно $(Format-D9Size $m.FreeBytes)")
        }
        if ($state.UsbMedia) {
            $ui.UsbBox.SelectedIndex = 0
            $ui.UsbInfo.Text = 'Буде додано autounattend.xml, папку Debora і (за бажанням) драйвери цього ПК. Решта вмісту флешки не змінюється.'
        } else {
            $ui.UsbInfo.Text = 'Флешку з Windows не знайдено. Створіть її через Media Creation Tool (microsoft.com/software-download) або Rufus, вставте й натисніть «Оновити список».'
        }
    }
    $ui.BtnUsbRefresh.Add_Click({ & $fillUsb })
    $ui.BtnPrepareUsb.Add_Click({
        if (-not $state.UsbMedia -or $ui.UsbBox.SelectedIndex -lt 0) { [void][Windows.MessageBox]::Show($win, 'Вставте флешку з файлами встановлення Windows і натисніть «Оновити список».', 'Debora'); return }
        $drivers = [bool]$ui.ChkUsbDrivers.IsChecked
        if ($drivers -and -not (& $needAdmin)) { return }
        $media = $state.UsbMedia[$ui.UsbBox.SelectedIndex]
        $opts = @{ UserName = $ui.UserNameBox.Text.Trim(); Password = $ui.AccountPasswordBox.Password; Edition = @('', 'Home', 'Pro')[$ui.EditionBox.SelectedIndex]
                   BypassRequirements = [bool]$ui.ChkUsbBypass.IsChecked; BypassNetwork = $true
                   PostInstall = $(if ($ui.ChkUsbPost.IsChecked) { 'Recommended' } else { '' }); DriverUpdate = [bool]$ui.ChkUsbPost.IsChecked }
        try { [void](New-D9AutounattendXml -Options $opts) } catch { [void][Windows.MessageBox]::Show($win, $_.Exception.Message, 'Debora', 'OK', 'Warning'); return }
        $warn = if ($opts.Password) { "`n`nПароль зберігається у файлі на флешці відкритим текстом — не залишайте її без нагляду." } else { '' }
        if ([Windows.MessageBox]::Show($win, "Підготувати флешку $($media.Drive)?`nОбліковий запис: $($opts.UserName)$(if ($drivers) { "`nДрайвери цього ПК буде скопійовано (кілька хвилин)." })$warn", 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Підготовка флешки' { param($a) Initialize-D9InstallUsb -Drive $a.Drive -Options $a.Opts -ProgramFolder $a.Prog -IncludeDrivers:$a.Drivers } @{ Drive = $media.Drive; Opts = $opts; Prog = (Split-Path $DriverDir); Drivers = $drivers } {
            param($r)
            [void][Windows.MessageBox]::Show($win, "Флешку $($r.Drive) підготовлено:`n• $($r.Done -join "`n• ")`n`nЗавантажтеся з неї (меню завантаження — зазвичай F12, F9, Esc або F2) і виберіть диск для Windows. Решта — автоматично.", 'Debora')
            & $fillUsb
        }
    })
    $ui.BtnExportDrivers.Add_Click({
        if (-not (& $needAdmin)) { return }
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Куди зберегти драйвери (краще — флешка або інший диск)'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $folder = Join-Path $dlg.SelectedPath ("Драйвери {0} {1:yyyy-MM-dd}" -f $env:COMPUTERNAME, (Get-Date))
        $ui.LogExpander.IsExpanded = $true
        & $startJob 'Збереження драйверів' { param($a) Export-D9Drivers -Folder $a.Folder } @{ Folder = $folder } {
            param($r)
            [void][Windows.MessageBox]::Show($win, "Збережено драйверів: $($r.Count) ($(Format-D9Size $r.Bytes))`n$($r.Folder)", 'Debora')
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
        & $refreshSchedule
        & $loadTweakStates
    })
    # Список автозавантаження читаємо при першому відкритті вкладки (щоб не займати фоновий потік на старті)
    $ui.Tabs.Add_SelectionChanged({
        param($sender, $e)
        if ($e.OriginalSource -ne $ui.Tabs) { return }
        if ($ui.Tabs.SelectedItem.Header -eq 'Автозавантаження' -and -not $state.StartupRows -and -not $state.Job) { & $loadStartup }
        if ($ui.Tabs.SelectedItem.Header -eq 'Програми' -and -not $state.AppsLoaded -and -not $state.Job) { & $loadApps }
        if ($ui.Tabs.SelectedItem.Header -eq 'Видалення' -and $null -eq $state.UninstRows -and -not $state.Job) { & $loadUninst }
        if ($ui.Tabs.SelectedItem.Header -eq 'Перевстановлення' -and $null -eq $state.UsbMedia) { & $fillUsb }
        if ($ui.Tabs.SelectedItem.Header -eq 'Обслуговування' -and -not $state.DisksLoaded -and -not $state.Job) { & $loadDisks }
    })
    $win.Add_Closing({ param($sender, $e)
        if ($state.Job) {
            if ([Windows.MessageBox]::Show($win, 'Зараз виконується операція. Закрити програму все одно?', 'Debora', 'YesNo', 'Warning') -ne 'Yes') { $e.Cancel = $true }
        }
    })
    $win.Add_Closed({ $timer.Stop() })
    if ($TestAction) { return (. $TestAction) }
    [void]$win.ShowDialog()
}
