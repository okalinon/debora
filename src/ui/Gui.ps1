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
    Add-D9CachedType 'D9Row' @'
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
    param($Owner, [string]$Title, [string]$Header, [string]$Text, [string]$OkText = (T-D9 'Застосувати'), [switch]$InfoOnly)
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
    $ok = New-Object Windows.Controls.Button; $ok.Content = $(if ($InfoOnly) { T-D9 'Закрити' } else { $OkText }); $ok.Margin = '0,0,8,0'; $ok.IsDefault = $true; if ($Owner) { $ok.Style = $Owner.FindResource('Primary') }
    $ok.Add_Click({ $w.DialogResult = $true })
    [void]$buttons.Children.Add($ok)
    if (-not $InfoOnly) {
        $cancel = New-Object Windows.Controls.Button; $cancel.Content = (T-D9 'Скасувати'); $cancel.Margin = '0'; $cancel.IsCancel = $true
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

# Переклад розмітки: тексти атрибутів (Text, Content, Header, ToolTip, Title) — за словником мови (ключ — український текст)
function Convert-D9XamlLanguage {
    param([Parameter(Mandatory)][string]$Xaml)
    if ($script:D9Language -eq 'uk') { return $Xaml }
    $table = Get-D9LangTable
    [regex]::Replace($Xaml, '(?<attr>\b(?:Text|Content|Header|ToolTip|Title))="(?<v>[^"]*[А-Яа-яІіЇїЄєҐґ][^"]*)"', {
        param($m)
        $key = [Net.WebUtility]::HtmlDecode($m.Groups['v'].Value)
        $tr = $null; [void]$table.TryGetValue($key, [ref]$tr)
        if (-not $tr) { return $m.Value }
        '{0}="{1}"' -f $m.Groups['attr'].Value, [Security.SecurityElement]::Escape($tr)
    })
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
    $xamlText = Convert-D9XamlLanguage (Convert-D9XamlStyle (Get-D9UiText 'MainWindow.xaml'))
    [D9Row]::ColorMap.Clear()
    if ($script:D9IsDark) {
        $xamlText = Convert-D9XamlTheme $xamlText
        foreach ($k in $script:D9DarkColors.Keys) { [D9Row]::ColorMap[$k] = $script:D9DarkColors[$k] }
    }
    $win = [Windows.Markup.XamlReader]::Parse($xamlText)
    $ui = @{}
    foreach ($n in 'TitleText', 'SystemLine', 'AdminBadge', 'ScoreRing', 'StatusText', 'Progress', 'LogBox', 'LogExpander', 'Tabs',
                   'BtnFixAll', 'BtnScan', 'BtnDeepScan', 'BtnOpenReport', 'ScoreText', 'VerdictText', 'CountsText', 'CategoryList', 'FindingsList', 'BtnAllFindings', 'FindingsTitle', 'ScoreExplain',
                   'BtnRunAuto', 'BtnMarkDone', 'BtnRecheck', 'BtnReboot', 'ChecklistSummary', 'ChecklistList',
                   'PresetBox', 'BtnSelectPreset', 'BtnSelectNone', 'BtnPreview', 'BtnApply', 'TweaksSummary', 'TweakGrid',
                   'BtnDriverScan', 'BtnOemPage', 'OemText', 'DriverProblemsList', 'DriverFolder', 'BtnBrowse', 'BtnFindDrivers',
                   'DebloatSummary', 'DebloatGrid', 'BtnDebloatRun', 'BtnDebloatRecommended', 'BtnDebloatNone', 'BtnDebloatRefresh',
                   'DriverPackageGrid', 'BtnInstallDrivers', 'DriverInstalledGrid', 'BtnDevicesExport', 'DeviceView', 'DeviceSearch', 'DeviceSearchHint', 'DevicesSummary', 'BtnDriverOnline', 'BtnDriverOnlineInstall', 'DriverOnlineGrid', 'BtnOemTool',
                   'BtnUndo', 'BtnRefreshSessions', 'BtnSystemRestore', 'BtnDiagnostics', 'SessionGrid',
                   'AppSearch', 'AppSearchHint', 'AppBundles', 'AppCategoryList', 'AppCards', 'AppSelectedText', 'BtnAppsClear', 'UninstSearch', 'UninstSearchHint', 'ChkUninstBloat', 'UninstSummary', 'UninstGrid', 'BtnUninstRefresh', 'BtnUninstall', 'UninstSelectedText', 'BtnAppsInstall', 'BtnAppsRefresh', 'BtnAppsUpgrade', 'AppsSummary', 'BtnWingetStore',
                   'UsbBox', 'BtnUsbRefresh', 'UsbInfo', 'UserNameBox', 'AccountPasswordBox', 'EditionBox', 'ChkUsbDrivers', 'ChkUsbBypass', 'ChkUsbPost', 'BtnPrepareUsb', 'BtnExportDrivers',
                   'ChkMtCleanup', 'ChkMtDefender', 'ChkMtApps', 'ChkMtDrivers', 'ChkMtWindows', 'MtDay', 'MtTime', 'BtnScheduleOn', 'BtnScheduleOff', 'BtnMaintainNow', 'ScheduleState',
                   'BtnStartupApply', 'BtnStartupRefresh', 'BtnStartupRecommended', 'StartupSummary', 'StartupGrid',
                   'BtnRestorePoint', 'BtnCleanNow', 'BtnRepair', 'BtnNetReset', 'BtnWuReset', 'PauseDays', 'BtnPause', 'BtnResume', 'PauseState', 'BtnWuDrivers', 'WuDriversState',
                   'BtnDisksRefresh', 'DisksState', 'DisksList', 'BtnStyle', 'BatterySep', 'BatteryPanel', 'BatteryStatus', 'BatteryDot', 'BatteryDetail', 'BatterySpark', 'BatterySparkNote', 'BatteryAdvice', 'BtnIconCache', 'BtnMemoryTest', 'BtnSearchReset', 'BtnLanguage') {
        $ui[$n] = $win.FindName($n)
        if (-not $ui[$n]) { throw "У розмітці немає елемента $n" }
    }
    $isAdmin = Test-D9IsAdmin
    $state = @{ Job = $null; Scan = $null; Checklist = $null; ReportPath = $null; Categories = $null; Oem = $null; Packages = $null; TweakRows = $null }
    $actionButtons = @('BtnFixAll', 'BtnScan', 'BtnDeepScan', 'BtnRunAuto', 'BtnMarkDone', 'BtnRecheck', 'BtnApply', 'BtnPreview', 'BtnDriverScan', 'BtnFindDrivers', 'BtnInstallDrivers', 'BtnUndo',
                       'BtnStartupApply', 'BtnStartupRefresh', 'BtnRestorePoint', 'BtnCleanNow', 'BtnRepair', 'BtnNetReset', 'BtnWuReset', 'BtnPause', 'BtnResume', 'BtnWuDrivers', 'BtnDiagnostics',
                       'BtnAppsInstall', 'BtnAppsRefresh', 'BtnAppsUpgrade', 'BtnDriverOnline', 'BtnDriverOnlineInstall', 'BtnOemTool', 'BtnPrepareUsb', 'BtnExportDrivers', 'BtnScheduleOn', 'BtnScheduleOff', 'BtnMaintainNow', 'BtnUninstRefresh', 'BtnUninstall',
                       'BtnDisksRefresh', 'BtnIconCache', 'BtnMemoryTest', 'BtnSearchReset', 'BtnDebloatRun', 'BtnDebloatRefresh')

    # ---------- шапка ----------
    $s = $SystemInfo
    $disk = @{ hdd = 'HDD'; ssd = 'SSD'; nvme = 'NVMe SSD'; unknown = (T-D9 'диск не визначено') }[[string]$s.SystemDisk]
    $ui.TitleText.Text = "Debora $script:D9Version"
    $ui.SystemLine.Text = "$($s.Manufacturer) $($s.Model)`n$($s.OsName) $($s.DisplayVersion)`n" + (T-D9 '{0} ГБ, {1}, профіль {2}' $s.RamGB $disk $Recommendation.Preset)
    if ($isAdmin) { $ui.AdminBadge.Text = (T-D9 'Адміністратор'); $ui.AdminBadge.Foreground = (Get-D9UiColor '#248A3D') }
    else { $ui.AdminBadge.Text = (T-D9 'Без прав адміністратора — лише перегляд'); $ui.AdminBadge.Foreground = (Get-D9UiColor '#B25000') }
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
        $ui.StatusText.Text = if ($text) { $text } elseif ($busy) { T-D9 'Виконується…' } else { T-D9 'Готово' }
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
        [void][Windows.MessageBox]::Show($win, (T-D9 'Для змін потрібні права адміністратора. Закрийте програму й запустіть її через run.bat.'), 'Debora', 'OK', 'Warning')
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
                & $log (T-D9 'ПОМИЛКА: {0}' "$($res.error)")
                $ui.LogExpander.IsExpanded = $true
                [void][Windows.MessageBox]::Show($win, (T-D9 'Не вдалося виконати: {0}' "$($res.error)"), 'Debora', 'OK', 'Error')
            } elseif ($job.Done) {
                try { & $job.Done $res.result $job.Context } catch { & $log (T-D9 'ПОМИЛКА інтерфейсу: {0}' $_.Exception.Message) }
            }
        }
    }
    $timer.Add_Tick($onTick)

    # Клік по будь-якому посиланню в списках
    $win.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($sender, $e)
        $b = $e.OriginalSource
        if ($b -is [Windows.Controls.Button] -and $b.Tag -is [string] -and $b.Tag) {
            try { Start-Process $b.Tag } catch { & $log (T-D9 'Не вдалося відкрити {0}: {1}' $b.Tag $_.Exception.Message) }
        }
    })

    # ---------- заповнення вкладок ----------
    $fillOverview = {
        param($scan, $categories)
        $color = Get-D9UiColor (@{ good = '#248A3D'; attention = '#B25000'; serious = '#D70015' }[$scan.score.verdict])
        $ui.ScoreText.Text = "$($scan.score.overall)"; $ui.ScoreText.Foreground = $color
        $ui.ScoreRing.Stroke = $color
        $ui.ScoreRing.Data = Get-D9RingGeometry ([double]$scan.score.overall) 156 14
        $ui.VerdictText.Text = @{ good = (T-D9 'Добрий стан'); attention = (T-D9 'Потребує уваги'); serious = (T-D9 'Є серйозні проблеми') }[$scan.score.verdict]
        $ui.VerdictText.Foreground = $color
        $counts = foreach ($k in 'critical', 'warning', 'suggestion') { $n = @($scan.findings | Where-Object severity -eq $k).Count; if ($n) { "$n $(T-D9 ($script:D9SevUi[$k].Name))" } }
        $ui.CountsText.Text = "$(($counts) -join ', ')`n" + (T-D9 'Перевірок: {0}, {1} с, {2}' (@($scan.checks).Count) $scan.durationSec (([datetime]$scan.time).ToString('dd.MM.yyyy HH:mm')))
        $cats = foreach ($c in $categories) {
            $v = $scan.score.categories.($c.id)
            if ($null -eq $v) { continue }
            New-D9Row @{ Id = $c.id; Title = (Get-D9Text $c.name); Number = [int]$v; Status = "$v"; Color = $(if ($v -ge 85) { '#248A3D' } elseif ($v -ge 60) { '#FF9500' } else { '#D70015' }) }
        }
        $state.Scan = $scan
        $state.CategoryNames = @{}; foreach ($c in $categories) { $state.CategoryNames[$c.id] = Get-D9Text $c.name }
        Set-D9Items $ui.CategoryList @($cats)
        & $showFindings $null
    }
    # Знахідки: усі або однієї категорії (клік по категорії) — з поясненням, з чого склалась оцінка
    $showFindings = {
        param([string]$categoryId)
        $scan = $state.Scan
        if (-not $scan) { return }
        $list = @($scan.findings | Where-Object { -not $categoryId -or $_.category -eq $categoryId })
        Set-D9Items $ui.FindingsList @(foreach ($f in $list) {
            $st = $script:D9SevUi[[string]$f.severity]
            $pen = Get-D9FindingPenalty $f
            New-D9Row @{ Badge = $st.Badge; Color = $st.Color; Title = $f.title; Detail = $f.details; Links = (ConvertTo-D9UiLinks $f.links)
                         Kind = $(if ($pen) { "−$pen" } else { '' }); Note = $(if ($categoryId) { T-D9 ($script:D9SevUi[[string]$f.severity].Name) } else { "$($state.CategoryNames[[string]$f.category]) · $(T-D9 ($script:D9SevUi[[string]$f.severity].Name))" }) }
        })
        $ui.ScoreExplain.Visibility = 'Visible'
        if ($categoryId) {
            $ui.FindingsTitle.Text = (T-D9 '{0}: {1} зі 100' $state.CategoryNames[$categoryId] $scan.score.categories.$categoryId)
            $ui.ScoreExplain.Text = Format-D9CategoryScoreExplain $scan.findings $categoryId
            $ui.BtnAllFindings.Visibility = 'Visible'
        } else {
            $ui.FindingsTitle.Text = (T-D9 'Що знайдено')
            $ui.ScoreExplain.Text = (T-D9 'Як рахується оцінка: кожна категорія починає зі 100 балів; критична проблема знімає 30, попередження — 10, порада — 3 (число праворуч від знахідки). Загальна оцінка — середнє категорій з урахуванням їхньої ваги; будь-яка критична проблема обмежує її 59 балами. Натисніть на категорію вгорі, щоб побачити лише її знахідки.')
            $ui.BtnAllFindings.Visibility = 'Collapsed'
            if ($ui.CategoryList.SelectedItem) { $state.CategoryReset = $true; $ui.CategoryList.SelectedItem = $null; $state.CategoryReset = $false }
        }
    }
    $ui.CategoryList.Add_SelectionChanged({
        if ($state.CategoryReset) { return }
        $row = $ui.CategoryList.SelectedItem
        & $showFindings $(if ($row) { [string]$row.Id } else { $null })
    })
    $ui.BtnAllFindings.Add_Click({ & $showFindings $null })
    $fillChecklist = {
        param($list)
        $state.Checklist = $list
        $items = @($list.items)
        if (-not $items) { $ui.ChecklistSummary.Text = (T-D9 'Чекліст порожній — нічого робити не потрібно.'); $ui.ChecklistList.ItemsSource = $null; return }
        $done = @($items | Where-Object status -eq 'done').Count
        $autoLeft = @($items | Where-Object { $_.auto -and $_.status -ne 'done' }).Count
        $ui.ChecklistSummary.Text = (T-D9 'Виконано {0} з {1}. Автоматичних кроків залишилось: {2}. Ручні кроки описані з посиланнями; виконавши такий крок, позначте його або натисніть «Перевірити ще раз».' $done $items.Count $autoLeft)
        Set-D9Items $ui.ChecklistList @(foreach ($i in $items) {
            $deps = @($i.dependsOn | ForEach-Object { $id = $_; ($items | Where-Object id -eq $id).number } | Where-Object { $_ } | Sort-Object)
            $detail = "$($i.why)"
            if ($deps -and $i.status -ne 'done') { $detail += (T-D9 '  (після кроку {0})' ($deps -join ', ')) }
            $kind = if ($i.status -eq 'done') { T-D9 'виконано' } elseif ($i.auto) { T-D9 'автоматично' } else { T-D9 'вручну' }
            New-D9Row @{ Selected = ($i.status -eq 'done'); Title = "$($i.number). $($i.title)"; Detail = $detail; Kind = $kind
                         Color = $(if ($i.status -eq 'done') { '#248A3D' } elseif ($i.auto) { '#007AFF' } else { '#B25000' })
                         Note = $(if ($i.note) { "$($i.note)" } else { '' }); Links = (ConvertTo-D9UiLinks $i.links); Tag = $i }
        })
    }
    $catNames = @{ privacy = (T-D9 'Конфіденційність'); apps = (T-D9 'Застосунки'); ui = (T-D9 'Інтерфейс'); performance = (T-D9 'Швидкодія'); gaming = (T-D9 'Ігри'); cleanup = (T-D9 'Очищення'); updates = (T-D9 'Оновлення'); safety = (T-D9 'Безпека') }
    $riskUi = @{ safe = @((T-D9 'безпечно'), '#248A3D'); moderate = @((T-D9 'помірно'), '#B25000'); expert = @((T-D9 'експертний'), '#D70015') }
    $stateNames = @{ applied = (T-D9 'застосовано'); partial = (T-D9 'частково'); notApplied = (T-D9 'ні'); notApplicable = (T-D9 'не підходить'); unknown = '—' }
    $fillTweaks = {
        param($states)
        $preset = Get-D9Preset $Catalog $Recommendation.Preset
        $rows = foreach ($t in $Catalog.Tweaks) {
            $st = $states | Where-Object Id -eq $t.id | Select-Object -First 1
            $applicable = $st.State -ne 'notApplicable'
            $note = @()
            if ($st.Reason) { $note += $st.Reason }
            if ($t.irreversible) { $note += (T-D9 'не відкочується') }
            if ($t.rebootRequired) { $note += (T-D9 'потрібне перезавантаження') }
            New-D9Row @{ Id = $t.id; Title = (Get-D9Text $t.name); Detail = (Get-D9Text $t.description); Group = $catNames[[string]$t.category]
                         Kind = $riskUi[[string]$t.risk][0]; Color = $riskUi[[string]$t.risk][1]; Status = $stateNames[[string]$st.State]
                         Note = ($note -join '; '); Enabled = $applicable
                         Selected = ($applicable -and @($preset.tweaks) -contains $t.id -and $st.State -ne 'applied') }
        }
        $state.TweakRows = @($rows)
        Set-D9Items $ui.TweakGrid $state.TweakRows
        $applied = @($states | Where-Object State -eq 'applied').Count
        $ui.TweaksSummary.Text = (T-D9 'Налаштувань: {0}, застосовано: {1}. Галочками відмічено незастосоване з профілю «{2}». Наведіть мишку на назву, щоб побачити пояснення.' (@($Catalog.Tweaks).Count) $applied (Get-D9Text $preset.name))
    }
    $loadTweakStates = {
        & $startJob (T-D9 'Перевірка стану налаштувань') {
            param($a)
            foreach ($t in $a.Catalog.Tweaks) {
                [pscustomobject]@{ Id = $t.id; State = (Get-D9TweakState $t $a.Sys); Reason = (Test-D9Applicable $t.requires $a.Sys).Reason }
            }
        } @{ Catalog = $Catalog; Sys = $SystemInfo } { param($r) & $fillTweaks @($r) }
    }
    $fillSessions = {
        Set-D9Items $ui.SessionGrid @(Get-D9SessionList | ForEach-Object {
            $when = try { ([datetime]$_.Started).ToString('dd.MM.yyyy HH:mm') } catch { $_.Started }
            $status = if ($_.Undone) { T-D9 'відкочено' } elseif ($_.Errors) { T-D9 'помилок: {0}' $_.Errors } else { T-D9 'застосовано' }
            New-D9Row @{ Id = $_.Id; Title = $when; Detail = $_.Selection; Number = [int]$_.Changed; Status = $status }
        })
    }
    # ---------- Деблоат ----------
    # Застосунки — поштучно (рекомендовані відмічені, Xbox і «корисні» — ні), налаштування — з каталогу твіків
    $fillDebloat = {
        param($r)
        $state.DebloatLoaded = $true
        $apps = @($r.Apps | Sort-Object GroupOrder, Name)
        $features = @($r.Features | Sort-Object SectionOrder)
        $secApps = (Get-D9DebloatSection 'apps').Name
        $rows = @(foreach ($a in $apps) {
            New-D9Row @{ Id = "app:$($a.Package)"; Badge = $secApps; Title = $a.Name; Group = $a.GroupName; Detail = ($a.Found -join ', '); Selected = $a.Recommended; Tag = $a
                         Kind = $(if ($a.Recommended) { T-D9 'видалити' } else { T-D9 'за бажанням' }); Color = $(if ($a.Recommended) { '#D70015' } else { '#6E6E73' }); Status = (T-D9 'встановлено') }
        }) + @(foreach ($f in $features) {
            $applicable = $f.State -notin 'notApplicable', 'needsAdmin'; $done = $f.State -eq 'applied'
            New-D9Row @{ Id = "tweak:$($f.Id)"; Badge = $f.SectionName; Title = $f.Name; Detail = $f.Description; Tag = $f; Enabled = ($applicable -and -not $done); Selected = ($f.Recommended -and $applicable -and -not $done)
                         Group = $f.Description; Kind = $riskUi[$f.Risk][0]; Color = $riskUi[$f.Risk][1]; Status = $(if ($f.State -eq 'needsAdmin') { T-D9 'потрібні права адміністратора' } else { $stateNames[[string]$f.State] }) + $(if ($f.Reason) { " ($($f.Reason))" }) }
        })
        Set-D9Items $ui.DebloatGrid $rows
        $view = [Windows.Data.CollectionViewSource]::GetDefaultView($ui.DebloatGrid.ItemsSource)
        if ($view -and $view.CanGroup) { $view.GroupDescriptions.Clear(); $view.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Badge')) }
        $rec = @($apps | Where-Object Recommended).Count
        $ui.DebloatSummary.Text = $(if ($apps) { T-D9 'Застосунків зі списку на цьому ПК: {0}, з них рекомендовано видалити: {1} (відмічені). Xbox і корисні застосунки не відмічені — позначте самі, якщо не потрібні.' $apps.Count $rec } else { T-D9 'Нав''язаних вбудованих застосунків на цьому ПК не знайдено.' }) +
            ' ' + (T-D9 'Деблоат-налаштувань: {0}, уже застосовано: {1}. Перед змінами створюється точка відновлення; усе повертається на вкладці «Журнал змін».' $features.Count @($features | Where-Object State -eq 'applied').Count)
        foreach ($b in 'BtnDebloatRun', 'BtnDebloatRecommended', 'BtnDebloatNone') { $ui[$b].IsEnabled = $true }
    }
    $loadDebloat = {
        & $startJob (T-D9 'Перевірка вбудованих застосунків') { param($a) @{ Apps = @(Get-D9DebloatApps); Features = @(Get-D9DebloatFeatures $a.Catalog $a.Sys) } } @{ Catalog = $Catalog; Sys = $SystemInfo } { param($r) & $fillDebloat $r }
    }
    $ui.BtnDebloatRefresh.Add_Click($loadDebloat)
    $ui.BtnDebloatRecommended.Add_Click({
        foreach ($row in @($ui.DebloatGrid.ItemsSource)) { if ($row) { $row.Selected = $row.Enabled -and [bool]$row.Tag.Recommended } }
    })
    $ui.BtnDebloatNone.Add_Click({
        foreach ($row in @($ui.DebloatGrid.ItemsSource)) { if ($row) { $row.Selected = $false } }
    })
    $ui.BtnDebloatRun.Add_Click({
        $apps = @($ui.DebloatGrid.ItemsSource | Where-Object { $_.Selected -and $_.Id -like 'app:*' })
        $feats = @($ui.DebloatGrid.ItemsSource | Where-Object { $_.Selected -and $_.Id -like 'tweak:*' })
        if (-not $apps -and -not $feats) { [void][Windows.MessageBox]::Show($win, (T-D9 'Позначте застосунки або налаштування галочками.'), 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        $text = (@($apps | ForEach-Object { (T-D9 'Видалити: {0}' $_.Title) }) + @($feats | ForEach-Object { $_.Title })) -join "`r`n"
        if (-not (Show-D9TextDialog $win (T-D9 'Деблоат Windows') (T-D9 'Буде видалено застосунків: {0}, застосовано налаштувань: {1}. Спершу створюється точка відновлення; усе можна повернути на вкладці «Журнал змін» (видалені застосунки — також з Microsoft Store).' $apps.Count $feats.Count) $text (T-D9 'Виконати'))) { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Деблоат Windows') { param($a) Invoke-D9Debloat -Catalog $a.Catalog -SystemInfo $a.Sys -Packages $a.Packages -TweakIds $a.TweakIds } @{
            Catalog = $Catalog; Sys = $SystemInfo; Packages = [string[]]@($apps | ForEach-Object { $_.Id.Substring(4) }); TweakIds = [string[]]@($feats | ForEach-Object { $_.Id.Substring(6) })
        } {
            param($session, $c)
            & $fillSessions
            $ok = @($session.entries | Where-Object result -eq 'ok').Count
            $err = @($session.entries | Where-Object result -eq 'error')
            $msg = (T-D9 'Деблоат виконано. Змін: {0}, помилок: {1}.' $ok $err.Count)
            if ($err) { $msg += "`n" + (($err | Select-Object -First 6 | ForEach-Object { "• $($_.message)" }) -join "`n") }
            # Контекстне меню, панель завдань і Провідник змінюються лише після перезапуску Провідника
            if ($c.Explorer -and $ok) {
                $msg += "`n`n" + (T-D9 'Щоб зміни меню, панелі завдань і Провідника з''явились, Провідник треба перезапустити (вікна папок закриються, файли не зачіпаються). Перезапустити зараз?')
                if ([Windows.MessageBox]::Show($win, $msg, 'Debora', 'YesNo', 'Question') -eq 'Yes') { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue }
            } else {
                [void][Windows.MessageBox]::Show($win, $msg, 'Debora', 'OK', $(if ($err) { 'Warning' } else { 'Information' }))
            }
            & $loadDebloat
        } @{ Explorer = [bool]@($feats | Where-Object { $_.Tag.Section -in 'context', 'shell', 'ads' }).Count }
    })

    # Перелік усіх пристроїв: фільтр (ComboBox Tag), пошук, однакові пристрої — одним рядком «×N»
    $deviceColors = @{ ok = '#248A3D'; disabled = '#6E6E73'; nodriver = '#D70015'; problem = '#D70015' }
    $fillDevices = {
        if (-not $state.Devices) { return }
        $view = [string]$ui.DeviceView.SelectedItem.Tag
        $list = @(Select-D9DeviceInventory $state.Devices $view $ui.DeviceSearch.Text)
        $rows = foreach ($d in @(Group-D9DeviceInventory $list)) {
            $old = $d.ThirdParty -and $d.AgeYears -ge 3
            $kind = if ($d.Status -ne 'ok') { $d.StatusText } elseif ($old) { T-D9 'старий ({0} р.)' ([int][math]::Floor($d.AgeYears)) } else { $d.StatusText }
            $tip = @("$($d.Name)")
            if ($d.Recognized -and $d.Recognized -ne $d.Name) { $tip += (T-D9 'Розпізнано: {0}' $d.Recognized) }
            if ($d.Manufacturer) { $tip += (T-D9 'Виробник: {0}' $d.Manufacturer) }
            if ($d.Inf) { $tip += "INF: $($d.Inf)" + $(if ($null -ne $d.Signed) { ', ' + $(if ($d.Signed) { T-D9 'підписаний' } else { T-D9 'НЕ підписаний' }) }) }
            if ($d.HardwareId) { $tip += "ID: $($d.HardwareId)" }
            $tip += $d.InstanceId
            New-D9Row @{ Group = $d.ClassName; Title = $(if ($d.Count -gt 1) { "$($d.Name)  ×$($d.Count)" } else { $d.Name })
                         Status = $d.Version; Detail = $d.DateText; Note = $d.Provider; Kind = $kind; Id = ($tip -join "`n")
                         Color = $(if ($old) { '#B25000' } else { $deviceColors[$d.Status] }) }
        }
        Set-D9Items $ui.DriverInstalledGrid @($rows)
        $ui.DevicesSummary.Text = (Get-D9DeviceInventorySummary $state.Devices) + ' ' + (T-D9 'Показано: {0}. Наведіть мишку на рядок — ID обладнання, INF-файл і виробник.' @($list).Count)
    }
    $ui.DeviceView.Add_SelectionChanged({ & $fillDevices })
    $ui.DeviceSearch.Add_TextChanged({
        $ui.DeviceSearchHint.Visibility = if ($ui.DeviceSearch.Text) { 'Collapsed' } else { 'Visible' }
        & $fillDevices
    })
    $ui.BtnDevicesExport.Add_Click({
        if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir | Out-Null }
        $path = Join-Path $ReportDir ("{0} {1:yyyy-MM-dd HH-mm}.csv" -f (T-D9 'Пристрої й драйвери'), (Get-Date))
        try {
            Export-D9DeviceInventoryCsv $state.Devices $path
            Start-Process explorer.exe "/select,`"$path`""
        } catch { [void][Windows.MessageBox]::Show($win, (T-D9 'Не вдалося зберегти: {0}' $_.Exception.Message), 'Debora', 'OK', 'Error') }
    })
    $fillDrivers = {
        param($rep)
        $state.Oem = $rep.Oem
        if ($rep.Oem) {
            $ui.BtnOemPage.IsEnabled = $true
            $ui.BtnOemPage.Content = (T-D9 'Сторінка драйверів {0} для цієї моделі' $rep.Oem.Name)
            $ui.OemText.Text = (T-D9 'Найкраще джерело драйверів — сайт виробника ПК: {0}' $rep.Oem.Url) + $(if ($rep.Oem.Note) { "`n$($rep.Oem.Note)" } else { '' }) + $(if ($rep.Oem.Serial) { "`n" + (T-D9 'Серійний номер: {0}' $rep.Oem.Serial) } else { '' })
        } else {
            $ui.OemText.Text = (T-D9 'Виробника ПК не знайдено в базі — користуйтеся посиланнями біля пристроїв (сайт виробника чипа, каталог Microsoft).')
        }
        $problems = @($rep.Problems | Sort-Object { if ($_.Class -eq 'Net') { 0 } else { 1 } } | ForEach-Object {
            $detail = "$($_.Reason). ID: $($_.Info.HardwareId)"
            if ($_.Windows -and $_.Windows -ne $_.Name) { $detail += (T-D9 '. Windows називає: {0}' $_.Windows) }
            New-D9Row @{ Badge = '!'; Color = '#B25000'; Title = $_.Name; Detail = $detail; Links = (ConvertTo-D9UiLinks $_.Links) }
        })
        if (-not $problems) { $problems = @(New-D9Row @{ Badge = '✓'; Color = '#248A3D'; Title = (T-D9 'Усі пристрої мають драйвери'); Detail = (T-D9 'Перевірте лише вік драйверів у таблиці нижче.') }) }
        Set-D9Items $ui.DriverProblemsList $problems
        $state.Devices = @($rep.Devices)
        $ui.BtnDevicesExport.IsEnabled = [bool]$state.Devices
        & $fillDevices
    }
    $statusUi = @{ missing = @((T-D9 'встановити'), '#D70015'); newer = @((T-D9 'оновити'), '#007AFF'); current = @((T-D9 'вже актуальний'), '#6E6E73') }
    $fillPackages = {
        param($found)
        $state.Packages = @($found.Packages)
        Set-D9Items $ui.DriverPackageGrid @($found.Packages | ForEach-Object {
            $cur = @($_.Current | ForEach-Object { $_.version } | Where-Object { $_ } | Sort-Object -Unique) -join ', '
            $date = if ($_.Package.Inf.Date) { $_.Package.Inf.Date.ToString('dd.MM.yyyy') } else { '?' }
            New-D9Row @{ Title = $_.Name; Kind = $statusUi[$_.Status][0]; Color = $statusUi[$_.Status][1]
                         Detail = "$(if ($cur) { $cur } else { T-D9 'немає' }) → $($_.Package.Inf.Version) ($date)"; Note = (Split-Path $_.Package.Inf.Path -Leaf)
                         Selected = ($_.Status -ne 'current'); Tag = $_ }
        })
        $ui.BtnInstallDrivers.IsEnabled = [bool]$state.Packages
        $msg = (T-D9 'INF-файлів у папці: {0}, підходять до цього ПК: {1}.' $found.Infs (@($found.Packages).Count))
        & $log $msg
        if ($found.Installers) {
            $msg += (T-D9 ' Пакетів лише з інсталятором: {0} — див. журнал виконання.' (@($found.Installers).Count))
            & $log (T-D9 'Пакети лише з інсталятором (.exe/.msi) — запустіть вручну, якщо цей пристрій є в ПК:')
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
        & $log (T-D9 'Сканування завершено: {0}/100. Звіт: {1}' $r.Scan.score.overall $r.Report)
    }

    # ---------- кнопки: Огляд ----------
    $ui.BtnScan.Add_Click({ & $startJob (T-D9 'Сканування') $scanWork @{ Catalog = $Catalog; Sys = $SystemInfo; Deep = $false; ReportDir = $ReportDir } $onScanned })
    $ui.BtnDeepScan.Add_Click({ & $startJob (T-D9 'Глибоке сканування') $scanWork @{ Catalog = $Catalog; Sys = $SystemInfo; Deep = $true; ReportDir = $ReportDir } $onScanned })
    $ui.BtnOpenReport.Add_Click({ if ($state.ReportPath) { Start-Process $state.ReportPath } })

    # ---------- кнопки: Чекліст ----------
    # Одна кнопка для всього: сканування → список автоматичних кроків → виконання → повторне сканування
    $runChecklistWork = {
        param($a)
        $list = Get-D9Checklist
        $ctx = New-D9ScanContext -Catalog $a.Catalog -SystemInfo $a.Sys
        foreach ($item in @($list.items | Where-Object { $_.auto -and $_.status -ne 'done' -and $_.action.action -ne 'reboot' } | Sort-Object number)) {
            if (-not (Test-D9ChecklistReady $list $item)) { Write-D9Log (T-D9 'Крок {0} пропущено: спершу виконайте попередні' $item.number) Warn; continue }
            try { [void](Invoke-D9ChecklistStep -Checklist $list -Item $item -Context $ctx) } catch { Write-D9Log (T-D9 '  Помилка: {0}' $_.Exception.Message) Error }
        }
        Write-D9Log (T-D9 'Перевірка результату...')
        $list = Update-D9ChecklistStatus -Checklist $list -Context $ctx
        Save-D9Checklist $list
        $list
    }
    $ui.BtnFixAll.Add_Click({
        if (-not (& $needAdmin)) { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Сканування') $scanWork @{ Catalog = $Catalog; Sys = $SystemInfo; Deep = $false; ReportDir = $ReportDir } {
            param($r)
            & $onScanned $r
            $before = $r.Scan.score.overall
            $todo = @($r.Checklist.items | Where-Object { $_.auto -and $_.status -ne 'done' -and $_.action.action -ne 'reboot' })
            if (-not $todo) { [void][Windows.MessageBox]::Show($win, (T-D9 'Оцінка: {0}/100. Автоматично виправляти нічого — решта порад на вкладці «Чекліст».' $before), 'Debora'); return }
            $text = ($todo | ForEach-Object { "$($_.number). $($_.title)" }) -join "`r`n"
            $manual = @($r.Checklist.items | Where-Object { -not $_.auto -and $_.status -ne 'done' }).Count
            if (-not (Show-D9TextDialog $win (T-D9 'Виправити все') ((T-D9 'Оцінка зараз: {0}/100. Debora виконає {1} кроків сама (спершу — точка відновлення; усе відкочується в «Журналі змін»)' $before $todo.Count) + $(if ($manual) { T-D9 '. Ще {0} порад потребують вашого рішення — вони лишаться на вкладці «Чекліст»' $manual }) + '.') $text (T-D9 'Виконати'))) { return }
            & $startJob (T-D9 'Виправлення') $runChecklistWork @{ Catalog = $Catalog; Sys = $SystemInfo } {
                param($list, $c)
                & $fillChecklist $list
                & $fillSessions
                # Повторне сканування — щоб показати результат. Стан твіків оновлюємо вже після нього:
                # одночасно йде лише одне фонове завдання, і друге $startJob мовчки пропустив би
                & $startJob (T-D9 'Повторне сканування') $scanWork @{ Catalog = $Catalog; Sys = $SystemInfo; Deep = $false; ReportDir = $ReportDir } {
                    param($r2, $c2)
                    & $onScanned $r2
                    & $loadTweakStates
                    $left = @($r2.Checklist.items | Where-Object { $_.status -ne 'done' -and $_.action.action -ne 'reboot' }).Count
                    $msg = (T-D9 'Оцінка: {0} → {1}/100.' $c2.Before $r2.Scan.score.overall) + $(if ($left) { "`n" + (T-D9 'Лишилось порад: {0} — вкладка «Чекліст».' $left) }) + "`n`n" + (T-D9 'Перезавантажити комп''ютер зараз, щоб усі зміни запрацювали?')
                    if ([Windows.MessageBox]::Show($win, $msg, 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force }
                } @{ Before = $c.Before }
            } @{ Before = $before }
        }
    })
    $ui.BtnRunAuto.Add_Click({
        if (-not $state.Checklist) { [void][Windows.MessageBox]::Show($win, (T-D9 'Спочатку проскануйте комп''ютер.'), 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        $todo = @($state.Checklist.items | Where-Object { $_.auto -and $_.status -ne 'done' -and $_.action.action -ne 'reboot' })
        if (-not $todo) { [void][Windows.MessageBox]::Show($win, (T-D9 'Автоматичних кроків не залишилось.'), 'Debora'); return }
        $text = ($todo | ForEach-Object { "$($_.number). $($_.title)" }) -join "`r`n"
        if (-not (Show-D9TextDialog $win (T-D9 'Автоматичні кроки') (T-D9 'Буде виконано {0} кроків. Перед змінами створюється точка відновлення; усе можна відкотити на вкладці «Журнал змін».' $todo.Count) $text (T-D9 'Виконати'))) { return }
        & $startJob (T-D9 'Виконання кроків чекліста') {
            param($a)
            $list = Get-D9Checklist
            $ctx = New-D9ScanContext -Catalog $a.Catalog -SystemInfo $a.Sys
            foreach ($item in @($list.items | Where-Object { $_.auto -and $_.status -ne 'done' -and $_.action.action -ne 'reboot' } | Sort-Object number)) {
                if (-not (Test-D9ChecklistReady $list $item)) { Write-D9Log (T-D9 'Крок {0} пропущено: спершу виконайте попередні' $item.number) Warn; continue }
                try { [void](Invoke-D9ChecklistStep -Checklist $list -Item $item -Context $ctx) } catch { Write-D9Log (T-D9 '  Помилка: {0}' $_.Exception.Message) Error }
            }
            Write-D9Log (T-D9 'Перевірка результату...')
            $list = Update-D9ChecklistStatus -Checklist $list -Context $ctx
            Save-D9Checklist $list
            $list
        } @{ Catalog = $Catalog; Sys = $SystemInfo } {
            param($list)
            & $fillChecklist $list
            & $fillSessions
            & $loadTweakStates
            $answer = [Windows.MessageBox]::Show($win, (T-D9 'Готово. Перезавантажити комп''ютер зараз, щоб усі зміни запрацювали?'), 'Debora', 'YesNo', 'Question')
            if ($answer -eq 'Yes') { Restart-Computer -Force }
        }
    })
    $ui.BtnMarkDone.Add_Click({
        $row = $ui.ChecklistList.SelectedItem
        if (-not $row) { [void][Windows.MessageBox]::Show($win, (T-D9 'Виберіть крок у списку.'), 'Debora'); return }
        $item = $state.Checklist.items | Where-Object id -eq $row.Tag.id | Select-Object -First 1
        $item.status = 'done'; $item.doneAt = (Get-Date).ToString('s'); $item.note = (T-D9 'позначено вручну')
        Save-D9Checklist $state.Checklist
        & $fillChecklist $state.Checklist
    })
    $ui.BtnRecheck.Add_Click({
        if (-not $state.Checklist) { return }
        & $startJob (T-D9 'Перевірка виконаних кроків') {
            param($a)
            $ctx = New-D9ScanContext -Catalog $a.Catalog -SystemInfo $a.Sys
            $list = Update-D9ChecklistStatus -Checklist (Get-D9Checklist) -Context $ctx
            Save-D9Checklist $list
            $list
        } @{ Catalog = $Catalog; Sys = $SystemInfo } { param($list) & $fillChecklist $list }
    })
    $ui.BtnReboot.Add_Click({
        if ([Windows.MessageBox]::Show($win, (T-D9 'Перезавантажити комп''ютер зараз? Збережіть відкриті документи.'), 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force }
    })

    # ---------- кнопки: Налаштування ----------
    foreach ($p in $Catalog.Presets) { [void]$ui.PresetBox.Items.Add((Get-D9Text $p.name)) }
    $ui.PresetBox.SelectedIndex = [array]::IndexOf(@($Catalog.Presets.id), $Recommendation.Preset)
    $ui.BtnSelectPreset.Add_Click({
        $preset = @($Catalog.Presets)[$ui.PresetBox.SelectedIndex]
        foreach ($r in $state.TweakRows) { $r.Selected = ($r.Enabled -and @($preset.tweaks) -contains $r.Id -and $r.Status -ne $stateNames.applied) }
    })
    $ui.BtnSelectNone.Add_Click({ foreach ($r in $state.TweakRows) { $r.Selected = $false } })
    $previewWork = {
        param($a)
        $plan = New-D9Plan -Catalog $a.Catalog -TweakIds $a.Ids -SystemInfo $a.Sys
        $lines = foreach ($group in (Get-D9Preview -Plan $plan -SystemInfo $a.Sys | Group-Object Tweak)) {
            $t = Get-D9Tweak $a.Catalog $group.Name
            $pending = @($group.Group | Where-Object Pending)
            $title = if ($t) { Get-D9Text $t.name } else { $group.Name }
            if (-not $pending -and -not ($group.Group | Where-Object Skipped)) { (T-D9 '✓ {0} — уже застосовано' $title); continue }
            "■ $title"
            foreach ($p in $group.Group) { if ($p.Pending -or $p.Skipped) { "    $($p.Change)" } }
        }
        @{ Text = ($lines -join "`r`n"); Count = @(Get-D9Preview -Plan $plan -SystemInfo $a.Sys | Where-Object Pending).Count }
    }
    $selectedIds = { @($state.TweakRows | Where-Object Selected | ForEach-Object Id) }
    $ui.BtnPreview.Add_Click({
        $ids = & $selectedIds
        if (-not $ids) { [void][Windows.MessageBox]::Show($win, (T-D9 'Нічого не вибрано.'), 'Debora'); return }
        & $startJob (T-D9 'Підготовка попереднього перегляду') $previewWork @{ Catalog = $Catalog; Sys = $SystemInfo; Ids = $ids } {
            param($r) [void](Show-D9TextDialog $win (T-D9 'Що зміниться') (T-D9 'Змін до застосування: {0}' "$($r.Count)") $r.Text -InfoOnly)
        }
    })
    $ui.BtnApply.Add_Click({
        $ids = & $selectedIds
        if (-not $ids) { [void][Windows.MessageBox]::Show($win, (T-D9 'Нічого не вибрано.'), 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        & $startJob (T-D9 'Підготовка попереднього перегляду') $previewWork @{ Catalog = $Catalog; Sys = $SystemInfo; Ids = $ids } {
            param($r, $c)
            if (-not $r.Count) { [void][Windows.MessageBox]::Show($win, (T-D9 'Усе вибране вже застосовано.'), 'Debora'); return }
            if (-not (Show-D9TextDialog $win (T-D9 'Застосувати налаштування') (T-D9 'Змін до застосування: {0}. Перед змінами створюється точка відновлення.' $r.Count) $r.Text)) { return }
            & $startJob (T-D9 'Застосування налаштувань') {
                param($a)
                $plan = New-D9Plan -Catalog $a.Catalog -TweakIds $a.Ids -SystemInfo $a.Sys
                Invoke-D9Plan -Plan $plan -SystemInfo $a.Sys -Selection (T-D9 'вибрані налаштування (вікно)')
            } @{ Catalog = $Catalog; Sys = $SystemInfo; Ids = $c.Ids } {
                param($session)
                $ok = @($session.entries | Where-Object result -eq 'ok').Count
                $err = @($session.entries | Where-Object result -eq 'error').Count
                & $fillSessions
                & $loadTweakStates
                [void][Windows.MessageBox]::Show($win, (T-D9 'Готово. Змінено: {0}, помилок: {1}.' $ok $err) + "`n" + (T-D9 'Частина змін запрацює після перезавантаження. Відкат — на вкладці «Журнал змін».'), 'Debora', 'OK', $(if ($err) { 'Warning' } else { 'Information' }))
            }
        } @{ Ids = $ids }
    })

    # ---------- кнопки: Драйвери ----------
    $driverReport = { & $startJob (T-D9 'Перевірка драйверів') { param($a) Get-D9DriverReport $a.Sys } @{ Sys = $SystemInfo } { param($r) & $fillDrivers $r } }
    $ui.BtnDriverScan.Add_Click($driverReport)
    $ui.BtnOemPage.Add_Click({ if ($state.Oem) { Start-Process $state.Oem.Url } })
    $ui.BtnBrowse.Add_Click({
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = (T-D9 'Папка із завантаженими драйверами')
        if (Test-Path $ui.DriverFolder.Text) { $dlg.SelectedPath = $ui.DriverFolder.Text }
        if ($dlg.ShowDialog() -eq 'OK') { $ui.DriverFolder.Text = $dlg.SelectedPath }
    })
    $ui.BtnFindDrivers.Add_Click({
        $folder = $ui.DriverFolder.Text
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        if (-not (Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue)) {
            [void][Windows.MessageBox]::Show($win, (T-D9 'Папка порожня. Завантажте драйвери з сайту виробника (кнопка вгорі) і покладіть файли сюди як є — .zip теж можна:') + "`n$folder", 'Debora')
            Start-Process explorer.exe $folder
            return
        }
        & $startJob (T-D9 'Пошук драйверів у папці') { param($a) Find-D9DriverPackages -Folder $a.Folder } @{ Folder = $folder } { param($r) & $fillPackages $r }
    })
    $ui.BtnInstallDrivers.Add_Click({
        $chosen = @($ui.DriverPackageGrid.ItemsSource | Where-Object Selected | ForEach-Object Tag)
        if (-not $chosen) { [void][Windows.MessageBox]::Show($win, (T-D9 'Нічого не вибрано.'), 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        $text = ($chosen | Sort-Object Order, Name | ForEach-Object { "$($_.Name) — $($_.Package.Inf.Version) ($(Split-Path $_.Package.Inf.Path -Leaf))" }) -join "`r`n"
        if (-not (Show-D9TextDialog $win (T-D9 'Встановлення драйверів') (T-D9 'Буде встановлено {0} драйвер(ів) у такому порядку. Попередні драйвери буде збережено для відкату.' $chosen.Count) $text (T-D9 'Встановити'))) { return }
        & $startJob (T-D9 'Встановлення драйверів') {
            param($a)
            $cat = New-D9DriverCatalog -Packages $a.Packages
            $plan = New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo $a.Sys
            Invoke-D9Plan -Plan $plan -SystemInfo $a.Sys -Selection (T-D9 'драйвери з {0}' $a.Folder)
        } @{ Packages = @($chosen | Sort-Object Order, Name); Sys = $SystemInfo; Folder = $ui.DriverFolder.Text } {
            param($session)
            $ok = @($session.entries | Where-Object result -eq 'ok').Count
            $err = @($session.entries | Where-Object result -eq 'error')
            & $fillSessions
            $msg = (T-D9 'Встановлено: {0}, помилок: {1}.' $ok $err.Count)
            if ($err) { $msg += "`n" + (($err | ForEach-Object { "• $($_.action.name): $($_.message)" }) -join "`n") }
            $msg += "`n`n" + (T-D9 'Перезавантажити комп''ютер зараз, щоб драйвери запрацювали?')
            if ([Windows.MessageBox]::Show($win, $msg, 'Debora', 'YesNo', $(if ($err) { 'Warning' } else { 'Question' })) -eq 'Yes') { Restart-Computer -Force }
            & $driverReport
        }
    })

    # ---------- Драйвери з інтернету (Microsoft Update Catalog + Windows Update) ----------
    $fillOnline = {
        param($cands)
        $state.OnlineCands = @($cands | Where-Object { $_ })
        Set-D9Items $ui.DriverOnlineGrid @($state.OnlineCands | ForEach-Object {
            $kind = if ($_.Status -eq 'missing') { @((T-D9 'встановити'), '#D70015') } elseif ($_.Optional) { @((T-D9 'необов''язково'), '#6E6E73') } else { @((T-D9 'оновити'), '#007AFF') }
            $cur = if ($_.Device.Version) { "$($_.Device.Version)$(if ($_.Device.Date -and ([datetime]$_.Device.Date).Year -ge 2010) { ' (' + ([datetime]$_.Device.Date).ToString('dd.MM.yyyy') + ')' })" } else { T-D9 'немає драйвера' }
            $new = "$($_.Row.Version)$(if ($_.Row.Date) { ' (' + ([datetime]$_.Row.Date).ToString('dd.MM.yyyy') + ')' })"
            New-D9Row @{ Title = $_.Device.Name; Id = $_.Row.Title; Kind = $kind[0]; Color = $kind[1]; Detail = "$cur → $new"
                         Note = "$(Format-D9Size $_.Row.Size)$(if ($_.Recommended) { T-D9 ' · рекомендує Windows Update' } else { T-D9 ' · каталог Microsoft' })"
                         Selected = -not $_.Optional; Tag = $_ }
        })
        $ui.BtnDriverOnlineInstall.IsEnabled = [bool]$state.OnlineCands
        $main = @($state.OnlineCands | Where-Object { -not $_.Optional }).Count
        $ui.StatusText.Text = if ($state.OnlineCands) { T-D9 'Знайдено драйверів: {0}, з них рекомендовано встановити: {1}. Необов''язкові замінюють робочі драйвери Windows на системних пристроях.' (@($state.OnlineCands).Count) $main } else { T-D9 'Новіших драйверів не знайдено — встановлені актуальні.' }
    }
    $oemTool = Get-D9OemTool $SystemInfo
    if ($oemTool) { $ui.BtnOemTool.Content = (T-D9 'Оновити через {0}' $oemTool.Name); $ui.BtnOemTool.Visibility = 'Visible' }
    $ui.BtnOemTool.Add_Click({
        if (-not (& $needAdmin)) { return }
        $t = Get-D9OemTool $SystemInfo
        if ([Windows.MessageBox]::Show($win, (T-D9 'Встановити (за потреби) і запустити {0}?' $t.Name) + "`n" + (T-D9 'Це фірмова утиліта {0}: вона сама поставить драйвери, прошивки й BIOS для вашої моделі. Триває 10–30 хвилин; не вимикайте ПК, ноутбук — від мережі.' $t.Vendor), 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Запуск {0}' $t.Name) { param($a) Invoke-D9OemDriverTool -SystemInfo $a.Sys } @{ Sys = $SystemInfo } {
            param($r)
            $msg = if ($r.Done) { T-D9 '{0} завершила роботу.' $r.Tool } else { T-D9 '{0} завершилась з кодом {1} — подробиці в журналі виконання.' $r.Tool $r.Code }
            if ($r.RebootRecommended) { if ([Windows.MessageBox]::Show($win, "$msg`n`n" + (T-D9 'Перезавантажити комп''ютер зараз?'), 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force } }
            else { [void][Windows.MessageBox]::Show($win, $msg, 'Debora') }
            & $driverReport
        }
    })
    $ui.BtnDriverOnline.Add_Click({
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Пошук драйверів онлайн') { param($a) @(Find-D9DriverUpdates -SystemInfo $a.Sys -IncludeWindowsUpdate) } @{ Sys = $SystemInfo } {
            param($r)
            & $fillOnline @($r)
            if (-not $state.OnlineCands) { [void][Windows.MessageBox]::Show($win, (T-D9 'Новіших драйверів у каталозі Microsoft не знайдено — встановлені драйвери актуальні.'), 'Debora') }
        }
    })
    $ui.BtnDriverOnlineInstall.Add_Click({
        $chosen = @($ui.DriverOnlineGrid.ItemsSource | Where-Object Selected | ForEach-Object Tag)
        if (-not $chosen) { [void][Windows.MessageBox]::Show($win, (T-D9 'Позначте драйвери галочками.'), 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        $mb = [long](($chosen | ForEach-Object { $_.Row.Size } | Measure-Object -Sum).Sum)
        $text = ($chosen | ForEach-Object { "$($_.Device.Name): $($_.Row.Version) — $($_.Row.Title)" }) -join "`r`n"
        if (-not (Show-D9TextDialog $win (T-D9 'Драйвери з інтернету') (T-D9 'Буде завантажено {0} пакет(ів), разом {1}, і встановлено ті, що точно підходять до пристроїв. Перед встановленням створюється точка відновлення, попередні драйвери зберігаються.' $chosen.Count (Format-D9Size $mb)) $text (T-D9 'Завантажити й встановити'))) { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Завантаження й встановлення драйверів') {
            param($a)
            $found = Save-D9DriverUpdates -Candidates $a.Cands -Folder $a.Folder
            $todo = @($found.Packages | Where-Object Status -ne 'current')
            if (-not $todo) { return @{ Session = $null; Count = 0 } }
            $cat = New-D9DriverCatalog -Packages $todo
            $plan = New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo $a.Sys
            @{ Session = (Invoke-D9Plan -Plan $plan -SystemInfo $a.Sys -Selection (T-D9 'драйвери з Microsoft Update Catalog')); Count = $todo.Count }
        } @{ Cands = $chosen; Folder = (Join-Path $DriverDir 'Завантажені'); Sys = $SystemInfo } {
            param($r)
            & $fillSessions
            if (-not $r.Session) { [void][Windows.MessageBox]::Show($win, (T-D9 'Після перевірки пакетів встановлювати нічого: поточні драйвери не старші.'), 'Debora'); return }
            $ok = @($r.Session.entries | Where-Object result -eq 'ok').Count
            $err = @($r.Session.entries | Where-Object result -eq 'error')
            $msg = (T-D9 'Встановлено: {0} з {1}, помилок: {2}.' $ok $r.Count $err.Count)
            if ($err) { $msg += "`n" + (($err | Select-Object -First 6 | ForEach-Object { "• $($_.action.name): $($_.message)" }) -join "`n") }
            $msg += "`n" + (T-D9 'Завантажені пакети лежать у папці «Драйвери\Завантажені» — їх можна використати на такому самому ПК без інтернету.')
            $msg += "`n`n" + (T-D9 'Перезавантажити комп''ютер зараз, щоб драйвери запрацювали?')
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
                [void][Windows.MessageBox]::Show($win, (T-D9 'Частина змін не застосувалась:') + "`n" + (($err | Select-Object -First 8 | ForEach-Object { "• $($_.message)" }) -join "`n"), 'Debora', 'OK', 'Warning')
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
                'disable'  { $note += (T-D9 'рекомендуємо вимкнути: {0}' "$($i.Reason)"); $color = '#B25000' }
                'optional' { $note += (T-D9 'можна вимкнути: {0}' "$($i.Reason)") }
                'keep'     { $note += (T-D9 'потрібне: {0}' "$($i.Reason)"); $color = '#248A3D' }
            }
            if ($i.Missing) { $note += (T-D9 'файл відсутній — запис можна вимкнути'); $color = '#D70015' }
            if (-not $i.Publisher -and -not $i.Verdict) { $note += (T-D9 'видавець невідомий') }
            New-D9Row @{ Selected = [bool]$i.Enabled; Title = $i.Name; Detail = $i.Command; Group = $(if ($i.Publisher) { $i.Publisher } else { '—' })
                         Note = $i.Where; Status = ($note -join '; '); Color = $color; Tag = $i }
        })
        Set-D9Items $ui.StartupGrid $state.StartupRows
        $on = @($items | Where-Object Enabled).Count
        $rec = @($items | Where-Object { $_.Enabled -and ($_.Verdict -eq 'disable' -or $_.Missing) }).Count
        $ui.BtnStartupRecommended.IsEnabled = [bool]$rec
        $ui.BtnStartupRecommended.Content = if ($rec) { T-D9 'Вимкнути рекомендовані ({0})' $rec } else { T-D9 'Вимкнути рекомендовані' }
        $ui.StartupSummary.Text = (T-D9 'Програм в автозавантаженні: {0}, запускаються: {1}' (@($items).Count) $on) + $(if ($rec) { T-D9 ', з них рекомендуємо вимкнути: {0}' $rec }) + (T-D9 '. Зніміть галочку з тих, яким не потрібно стартувати разом із Windows, і натисніть «Застосувати зміни» — або «Вимкнути рекомендовані». Програми не видаляються; усе відкочується в «Журналі змін».')
    }
    $loadStartup = { & $startJob (T-D9 'Читання автозавантаження') { Get-D9StartupItems } $null { param($r) & $fillStartup @($r) } }
    $ui.BtnStartupRefresh.Add_Click($loadStartup)
    $ui.BtnStartupRecommended.Add_Click({
        foreach ($r in $state.StartupRows) { if ($r.Tag.Enabled -and ($r.Tag.Verdict -eq 'disable' -or $r.Tag.Missing)) { $r.Selected = $false } }
        $ui.BtnStartupApply.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
    })
    $ui.BtnStartupApply.Add_Click({
        $changes = @($state.StartupRows | Where-Object { $_.Selected -ne [bool]$_.Tag.Enabled } | ForEach-Object { @{ Item = $_.Tag; Enable = $_.Selected } })
        if (-not $changes) { [void][Windows.MessageBox]::Show($win, (T-D9 'Змін немає: поставте або зніміть галочки.'), 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        $text = ($changes | ForEach-Object { "$(if ($_.Enable) { T-D9 'Увімкнути' } else { T-D9 'Вимкнути' }): $($_.Item.Name)" }) -join "`r`n"
        if (-not (Show-D9TextDialog $win (T-D9 'Автозавантаження') (T-D9 'Змін: {0}. Подіють після наступного входу в Windows.' $changes.Count) $text)) { return }
        & $applyCatalog (New-D9StartupCatalog -Changes $changes) (T-D9 'Зміна автозавантаження') (T-D9 'автозавантаження') { & $loadStartup } -NoRestorePoint
    })

    # ---------- мова інтерфейсу ----------
    $ui.BtnLanguage.Content = if ($script:D9Language -eq 'uk') { 'English' } else { 'Українська' }
    $ui.BtnLanguage.Add_Click({
        if ($state.Job) { return }
        Set-D9Language -Language $(if ($script:D9Language -eq 'uk') { 'en' } else { 'uk' }) -Save
        if ($script:D9ScriptPath) {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($script:D9ScriptPath)`" -Gui"
            $win.Close()
        }
    })

    # ---------- стиль вікна: класичний → фокус → швейцарський (вікно перевідкривається, як і при зміні мови) ----------
    $ui.BtnStyle.Content = T-D9 'Стиль: {0}' (Get-D9StyleName)
    $ui.BtnStyle.Add_Click({
        if ($state.Job) { return }
        $next = Get-D9NextStyle
        Save-D9Style $next
        if ($script:D9ScriptPath) {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($script:D9ScriptPath)`" -Gui -Style $next"
            $win.Close()
        }
    })

    # ---------- кнопки: Обслуговування ----------
    $diskColors = @{ ok = '#248A3D'; warn = '#B25000'; bad = '#D70015'; unknown = '#6E6E73' }
    $batteryColors = @{ ok = '#248A3D'; fair = '#B25000'; warn = '#B25000'; bad = '#D70015' }
    $fillBattery = {
        param($b)
        if (-not $b) { $ui.BatteryDetail.Text = (T-D9 'Windows не віддає даних батареї.'); return }
        $level = Get-D9BatteryLevel $b
        $color = Get-D9UiColor $batteryColors[$level]
        $ui.BatteryStatus.Text = Get-D9BatteryLevelText $level; $ui.BatteryStatus.Foreground = $color; $ui.BatteryDot.Fill = $color
        $ui.BatteryDetail.Text = Format-D9BatteryDetails $b
        $sparkMin = Get-D9SparkMin @($b.History)
        $ui.BatterySpark.Data = Get-D9SparkGeometry @($b.History) 320 48 $sparkMin
        $ui.BatterySparkNote.Text = if (@($b.History).Count -ge 2) { T-D9 'Ємність з {0} по {1} (шкала {2}–100%)' $b.History[0].Date.ToString('MM.yyyy') $b.History[-1].Date.ToString('MM.yyyy') $sparkMin } else { '' }
        $advice = @(Get-D9BatteryAdvice $b $SystemInfo.Manufacturer)
        $ui.BatteryAdvice.Text = $advice -join "`n"
        $ui.BatteryAdvice.Visibility = if ($advice) { 'Visible' } else { 'Collapsed' }
    }
    if ($SystemInfo.HasBattery) { $ui.BatterySep.Visibility = 'Visible'; $ui.BatteryPanel.Visibility = 'Visible' }
    $loadDisks = {
        & $startJob (T-D9 'Перевірка стану дисків') { param($a) @{ Disks = @(Get-D9DiskHealth); Battery = $(if ($a.Bat) { Get-D9BatteryHealth }) } } @{ Bat = [bool]$SystemInfo.HasBattery } {
            param($res)
            if ($SystemInfo.HasBattery) { & $fillBattery $res.Battery }
            $r = $res.Disks
            $disks = @($r | Where-Object { $_ })
            $rows = foreach ($d in $disks) {
                $v = Get-D9DiskVerdict $d
                $row = New-Object D9Row
                $row.Title = Format-D9DiskTitle $d
                $row.Status = T-D9 ([string]$script:D9DiskLevelText[$v.Level])
                $row.Color = $diskColors[$v.Level]
                $row.Note = if ($v.Problems) { ($v.Problems -join '; ') + $(if ($v.Level -eq 'bad') { T-D9 '. Негайно скопіюйте важливі файли й замініть диск.' }) } else { '' }
                $row.Detail = Format-D9DiskDetails $d
                $row
            }
            $state.DisksLoaded = $true
            Set-D9Items $ui.DisksList @($rows)
            $bad = @($disks | Where-Object { -not $_.Removable -and (Get-D9DiskVerdict $_).Level -eq 'bad' })
            $ui.DisksState.Text = if ($bad) { T-D9 'Несправних дисків: {0}. Збережіть дані на інший диск або в хмару.' $bad.Count }
                                  elseif (-not $isAdmin) { T-D9 'Без прав адміністратора Windows показує лише загальний стан; температура, знос і помилки — після запуску через run.bat.' }
                                  else { T-D9 'Перевірено {0}. Температура, знос SSD, години роботи й помилки (SMART).' (Get-Date -Format 'HH:mm') }
        }
    }
    $ui.BtnDisksRefresh.Add_Click($loadDisks)
    $ui.BtnIconCache.Add_Click({
        if ([Windows.MessageBox]::Show($win, (T-D9 'Скинути кеш значків і ескізів?') + "`n" + (T-D9 'Провідник перезапуститься: панель задач на мить зникне, відкриті вікна папок закриються. Файли не зачіпаються.'), 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        & $startJob (T-D9 'Скидання кешу значків') { Reset-D9IconCache } $null { param($r) [void][Windows.MessageBox]::Show($win, (T-D9 'Готово: видалено файлів кешу — {0}. Значки з''являться заново за хвилину.' "$($r.Removed)"), 'Debora') }
    })
    $refreshMaintenance = {
        $ux = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue
        $until = $null
        if ($ux.PauseUpdatesExpiryTime) { try { $until = [datetime]::Parse($ux.PauseUpdatesExpiryTime, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
        $ui.PauseState.Text = if ($until -and $until -gt (Get-Date)) { T-D9 'Оновлення призупинено до {0}. На цей час не приходять і виправлення безпеки.' $until.ToString('dd.MM.yyyy') }
                              else { T-D9 'Оновлення не призупинено. Пауза знадобиться, наприклад, перед важливою роботою або на мобільному інтернеті.' }
        $t = Get-D9Tweak $Catalog 'updates.no-wu-drivers'
        $applied = (Get-D9TweakState $t $SystemInfo) -eq 'applied'
        $ui.WuDriversState.Text = if ($applied) { T-D9 'Вимкнено: Windows не встановлює драйвери сама. Драйвери ставите ви — з сайту виробника або на вкладці «Драйвери». Скасувати можна в «Журналі змін».' }
                                  else { T-D9 'Увімкнено: Windows Update сама ставить і підмінює драйвери (часто загальними або старшими версіями). Вимкніть, якщо ставите драйвери самі.' }
        $ui.BtnWuDrivers.IsEnabled = -not $applied -and -not $state.Job
    }
    $maintenanceJob = {
        param([string]$title, [string]$confirm, [string]$function)
        if (-not (& $needAdmin)) { return }
        if ([Windows.MessageBox]::Show($win, $confirm, 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob $title { param($a) & $a.Fn } @{ Fn = $function } {
            param($r)
            $msg = T-D9 'Готово. Подробиці — у журналі виконання внизу.'
            if ($r.RebootRecommended) {
                if ([Windows.MessageBox]::Show($win, "$msg`n`n" + (T-D9 'Перезавантажити комп''ютер зараз?'), 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force }
            } else { [void][Windows.MessageBox]::Show($win, $msg, 'Debora') }
        }
    }
    $ui.BtnRepair.Add_Click({ & $maintenanceJob (T-D9 'Відновлення системних файлів') ((T-D9 'Перевірити й відновити системні файли Windows?') + "`n" + (T-D9 'Це триває 10–40 хвилин; комп''ютером можна користуватися.')) 'Invoke-D9RepairSystem' })
    $ui.BtnNetReset.Add_Click({ & $maintenanceJob (T-D9 'Скидання мережі') ((T-D9 'Скинути мережеві налаштування?') + "`n" + (T-D9 'Wi-Fi-мережі й паролі збережуться; після перезавантаження з''єднання налаштується заново.')) 'Invoke-D9NetworkReset' })
    $ui.BtnWuReset.Add_Click({ & $maintenanceJob (T-D9 'Скидання Windows Update') ((T-D9 'Скинути Windows Update?') + "`n" + (T-D9 'Служби буде перезапущено, кеш оновлень створиться заново.')) 'Invoke-D9WindowsUpdateReset' })
    $ui.BtnMemoryTest.Add_Click({ & $maintenanceJob (T-D9 'Перевірка пам''яті') ((T-D9 'Запланувати перевірку оперативної пам''яті?') + "`n" + (T-D9 'Під час наступного перезавантаження Windows 10–20 хвилин перевірятиме пам''ять, потім запуститься як звичайно.')) 'Invoke-D9MemoryTestOnReboot' })
    $ui.BtnSearchReset.Add_Click({ & $maintenanceJob (T-D9 'Перебудова пошукового індексу') ((T-D9 'Перебудувати пошуковий індекс Windows?') + "`n" + (T-D9 'Старий індекс буде видалено; новий створиться у фоні, і кілька годин пошук знаходитиме не все.')) 'Reset-D9SearchIndex' })
    $ui.BtnRestorePoint.Add_Click({
        if (-not (& $needAdmin)) { return }
        & $startJob (T-D9 'Створення точки відновлення') { New-D9RestorePoint } $null {
            param($name)
            if ($name) { [void][Windows.MessageBox]::Show($win, (T-D9 'Точку відновлення створено: {0}' "$name"), 'Debora') }
            else { [void][Windows.MessageBox]::Show($win, (T-D9 'Не вдалося створити точку відновлення. Можливо, вимкнено захист системи (кнопка «Відновлення системи Windows» → Налаштувати).'), 'Debora', 'OK', 'Warning') }
        }
    })
    $ui.BtnCleanNow.Add_Click({
        if (-not (& $needAdmin)) { return }
        if ([Windows.MessageBox]::Show($win, (T-D9 'Видалити тимчасові файли, кеш оновлень Windows, дампи збоїв і залишки інсталяторів?') + "`n" + (T-D9 'Це не можна відкотити, але ці файли не потрібні.'), 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        $ids = 'cleanup.temp', 'cleanup.update-cache', 'cleanup.leftovers', 'cleanup.do-cache'
        $cat = [pscustomobject]@{ Tweaks = @($Catalog.Tweaks | Where-Object { $ids -contains $_.id }); Presets = @() }
        $state.FreeBefore = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'").FreeSpace
        & $applyCatalog $cat (T-D9 'Очищення диска') (T-D9 'очищення диска') {
            $after = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$env:SystemDrive'").FreeSpace
            [void][Windows.MessageBox]::Show($win, (T-D9 'Звільнено: {0}' (Format-D9Size ([math]::Max(0, $after - $state.FreeBefore)))), 'Debora')
        } -NoRestorePoint
    })
    $ui.BtnPause.Add_Click({
        if (-not (& $needAdmin)) { return }
        $days = @(7, 14, 21, 35)[$ui.PauseDays.SelectedIndex]
        & $applyCatalog (New-D9PauseUpdatesCatalog -Days $days) (T-D9 'Пауза оновлень') (T-D9 'пауза оновлень на {0} дн.' $days) { & $refreshMaintenance } -NoRestorePoint
    })
    $ui.BtnResume.Add_Click({
        if (-not (& $needAdmin)) { return }
        & $applyCatalog (New-D9ResumeUpdatesCatalog) (T-D9 'Відновлення оновлень') (T-D9 'відновлення оновлень') { & $refreshMaintenance } -NoRestorePoint
    })
    $ui.BtnWuDrivers.Add_Click({
        if (-not (& $needAdmin)) { return }
        $t = Get-D9Tweak $Catalog 'updates.no-wu-drivers'
        if ([Windows.MessageBox]::Show($win, "$(Get-D9Text $t.description)`n`n" + (T-D9 'Вимкнути встановлення драйверів через Windows Update?'), 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        & $applyCatalog ([pscustomobject]@{ Tweaks = @($t); Presets = @() }) (T-D9 'Драйвери з Windows Update') (Get-D9Text $t.name) { & $refreshMaintenance; & $loadTweakStates }
    })

    # ---------- кнопки: Журнал ----------
    $ui.BtnRefreshSessions.Add_Click({ & $fillSessions })
    $ui.BtnSystemRestore.Add_Click({ Start-Process rstrui.exe })
    $ui.BtnDiagnostics.Add_Click({
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Збір діагностики') { param($a) New-D9DiagnosticsBundle -SystemInfo $a.Sys -OutDir $a.Dir -ReportDir $a.Dir } @{ Sys = $SystemInfo; Dir = $ReportDir } {
            param($zip)
            $zip = @($zip) | Where-Object { $_ -is [string] -and $_ -like '*.zip' } | Select-Object -Last 1
            if ($zip) { Start-Process explorer.exe "/select,`"$zip`"" }
        }
    })
    $ui.BtnUndo.Add_Click({
        $row = $ui.SessionGrid.SelectedItem
        if (-not $row) { [void][Windows.MessageBox]::Show($win, (T-D9 'Виберіть сесію в таблиці.'), 'Debora'); return }
        if (-not (& $needAdmin)) { return }
        if ([Windows.MessageBox]::Show($win, (T-D9 'Відкотити зміни сесії «{0}» ({1})?' $row.Detail $row.Title), 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        & $startJob (T-D9 'Відкат змін') { param($a) Undo-D9Session -Id $a.Id } @{ Id = $row.Id } {
            param($report)
            $report = @($report)
            $restored = @($report | Where-Object result -eq 'restored').Count
            $other = @($report | Where-Object { $_.result -ne 'restored' })
            $msg = (T-D9 'Відновлено: {0}.' "$restored")
            if ($other) { $msg += "`n" + (T-D9 'Потребує уваги ({0}):' "$($other.Count)") + "`n" + (($other | Select-Object -First 10 | ForEach-Object { "• $($_.tweak): $($_.message)" }) -join "`n") }
            & $fillSessions
            & $loadTweakStates
            [void][Windows.MessageBox]::Show($win, "$msg`n`n" + (T-D9 'Деякі зміни повернуться після перезавантаження.'), 'Debora')
        }
    })

    # ---------- Програми (winget) ----------
    $hasWinget = [bool](Get-D9WingetPath)
    $appCatalog = Import-D9AppCatalog
    $appCats = [ordered]@{}
    foreach ($c in $appCatalog.categories) { $appCats[[string]$c.id] = Get-D9Text $c.name }
    $state.AppUpgrades = @{}
    $state.AppFilter = 'popular'
    # Картки з іконками (567 програм) будуються при першому відкритті вкладки ($buildApps нижче),
    # а не під час запуску: це ~0,6 с, а вкладку відкривають не щоразу
    $state.AppRows = @()
    # Картки програм заповнюють усю ширину: кількість колонок — за шириною області
    $ui.AppCards.Tag = 2
    $ui.AppCards.Parent.Add_SizeChanged({ param($sender, $e) $ui.AppCards.Tag = [math]::Max(1, [math]::Floor(($e.NewSize.Width - 14) / 290)) })
    # Стан програми — у Kind (update / installed / none), не залежить від показаного тексту
    $appStatus = { param($row) if ($row.Kind -in 'update', 'installed') { $row.Kind } else { 'none' } }
    # Категорії ліворуч: службові + з каталогу, з кількістю
    $fillAppCategories = {
        $rows = $state.AppRows
        $list = @(
            @{ Id = 'popular'; Title = (T-D9 '★ Популярне'); N = @($rows | Where-Object { $_.Tag.popular }).Count }
            @{ Id = 'all'; Title = (T-D9 'Усі програми'); N = $rows.Count }
            @{ Id = 'selected'; Title = (T-D9 '✓ Вибрані'); N = @($rows | Where-Object Selected).Count }
            @{ Id = 'installed'; Title = (T-D9 'Встановлені'); N = @($rows | Where-Object { (& $appStatus $_) -ne 'none' }).Count }
            @{ Id = 'update'; Title = (T-D9 'Є оновлення'); N = @($rows | Where-Object { (& $appStatus $_) -eq 'update' }).Count }
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
        $ui.AppSelectedText.Text = if ($sel) { (T-D9 'Вибрано: {0}' $sel.Count) + $(if ($upd) { T-D9 ' (з них оновити: {0})' $upd }) + " — $(($sel | Select-Object -First 6 | ForEach-Object Title) -join ', ')$(if ($sel.Count -gt 6) { '…' })" } else { T-D9 'Нічого не вибрано. Клацніть по картці програми, щоб вибрати.' }
        $ui.AppSelectedText.ToolTip = if ($sel) { ($sel | ForEach-Object Title) -join "`n" } else { $null }
    $ui.BtnAppsInstall.Content = if ($sel) { T-D9 'Встановити вибрані ({0})' $sel.Count } else { T-D9 'Встановити вибрані' }
        $ui.BtnAppsInstall.IsEnabled = [bool]$sel -and $hasWinget -and -not $state.Job
        $c = $state.AppCategoryRows | Where-Object Id -eq 'selected' | Select-Object -First 1
        if ($c) { $c.Status = $(if ($sel) { "$($sel.Count)" } else { '' }) }
    }
    $buildApps = {
        if ($state.AppsBuilt) { return }
        $state.AppsBuilt = $true
        $appIcons = Get-D9AppIconData
        $state.AppRows = @($appCatalog.apps | ForEach-Object {
            New-D9Row @{ Id = $_.id; Title = $_.name; Group = $appCats[[string]$_.category]; Note = (Get-D9Text $_.description); Status = ''; Color = '#6E6E73'; Tag = $_
                         Icon = (ConvertTo-D9Image $appIcons[$_.id]); Initial = ([string]$_.name).Substring(0, 1).ToUpper() }
        })
        & $fillAppCategories
        & $showApps
        & $updateAppSelection
    }
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
        $ui.AppsSummary.Text = (T-D9 'winget не знайдено — без нього програми не встановлюються. Встановіть «Інсталятор застосунків» з Microsoft Store і перезапустіть Debora.')
        $ui.BtnWingetStore.Visibility = 'Visible'
    }
    $ui.BtnWingetStore.Add_Click({ Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' })
    $noWinget = { [void][Windows.MessageBox]::Show($win, (T-D9 'winget не знайдено. Встановіть «Інсталятор застосунків» з Microsoft Store (посилання на вкладці).'), 'Debora', 'OK', 'Warning') }
    # Стан картки: встановлено / є оновлення (можна вибрати й оновити) / не встановлено
    $markApp = {
        param($row, [bool]$installed)
        $up = $state.AppUpgrades[[string]$row.Id]
        if ($installed -and $up) { $row.Status = (T-D9 'є оновлення: {0} → {1}' $up.Version $up.Available); $row.Kind = 'update'; $row.Color = '#007AFF'; $row.Enabled = $true }
        elseif ($installed) { $row.Status = (T-D9 'встановлено'); $row.Kind = 'installed'; $row.Color = '#248A3D'; $row.Selected = $false; $row.Enabled = $false }
        else { $row.Status = (T-D9 'не встановлено'); $row.Kind = 'none'; $row.Color = '#6E6E73'; $row.Enabled = $true }
    }
    $loadApps = {
        if (-not $hasWinget) { return }
        & $startJob (T-D9 'Перевірка встановлених програм') { $s = Get-D9InstalledAppIds; @{ Ids = [string[]]@($s); Up = @(Get-D9AppUpgrades) } } $null {
            param($r)
            $state.AppUpgrades = @{}
            foreach ($u in @($r.Up)) { if ($u.Id) { $state.AppUpgrades[[string]$u.Id] = $u } }
            $ids = @($r.Ids)
            foreach ($row in $state.AppRows) { & $markApp $row ($ids -contains $row.Id -or $state.AppUpgrades.ContainsKey([string]$row.Id)) }
            $state.AppsLoaded = $true
            & $fillAppCategories; & $showApps; & $updateAppSelection
            $inst = @($state.AppRows | Where-Object { (& $appStatus $_) -ne 'none' }).Count
            $ui.AppsSummary.Text = (T-D9 'У каталозі {0} програм, з них у вас встановлено {1}, мають оновлення {2} (усього на ПК). Клацніть по картці, щоб вибрати, або скористайтеся готовим набором.' (@($state.AppRows).Count) $inst (@($r.Up).Count))
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
        if ($toInstall) { $text += (T-D9 'Встановити ({0}):' $toInstall.Count); $text += @($toInstall | ForEach-Object { "  • $($_.Title)" }) }
        if ($toUpdate) { $text += (T-D9 'Оновити ({0}):' $toUpdate.Count); $text += @($toUpdate | ForEach-Object { "  • $($_.Title)" }) }
        if (-not (Show-D9TextDialog $win (T-D9 'Програми') (T-D9 'Встановлення йде у фоні; деякі інсталятори можуть показати власне вікно.') ($text -join "`r`n") (T-D9 'Встановити'))) { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Встановлення програм') {
            param($a)
            @(if ($a.Install) { Install-D9Apps -Apps $a.Install }) + @(if ($a.Update) { Update-D9Apps -Ids $a.Update })
        } @{ Install = @($toInstall | ForEach-Object Tag); Update = @($toUpdate | ForEach-Object Id) } {
            param($res)
            $res = @($res | Where-Object { $_ })
            foreach ($r in $res) {
                $row = $state.AppRows | Where-Object Id -eq $r.id | Select-Object -First 1
                if (-not $row) { continue }
                if ($r.result -in 'failed', 'notFound') { $row.Status = (T-D9 'помилка — див. журнал'); $row.Kind = 'error'; $row.Color = '#D70015' }
                else { $state.AppUpgrades.Remove([string]$row.Id); & $markApp $row $true }
            }
            & $fillAppCategories; & $showApps; & $updateAppSelection
            $bad = @($res | Where-Object { $_.result -in 'failed', 'notFound' })
            $names = @{}; foreach ($r in $state.AppRows) { $names[[string]$r.Id] = $r.Title }
            $msg = (T-D9 'Готово: {0} з {1}.' ($res.Count - $bad.Count) $res.Count)
            if ($bad) { $msg += "`n" + (T-D9 'Не вдалося: {0}. Подробиці — у журналі виконання внизу.' (($bad | ForEach-Object { $names[[string]$_.id] }) -join ', ')) }
            if (@($res | Where-Object result -eq 'reboot')) { $msg += "`n" + (T-D9 'Деякі програми запрацюють після перезавантаження.') }
            [void][Windows.MessageBox]::Show($win, $msg, 'Debora', 'OK', $(if ($bad) { 'Warning' } else { 'Information' }))
        }
    })
    $ui.BtnAppsUpgrade.Add_Click({
        if (-not $hasWinget) { & $noWinget; return }
        & $startJob (T-D9 'Пошук оновлень програм') { @(Get-D9AppUpgrades) } $null {
            param($up)
            $up = @($up | Where-Object { $_ })
            if (-not $up) { [void][Windows.MessageBox]::Show($win, (T-D9 'Усі програми актуальні.'), 'Debora'); return }
            $text = ($up | ForEach-Object { "$($_.Name)    $($_.Version) → $($_.Available)" }) -join "`r`n"
            if (-not (Show-D9TextDialog $win (T-D9 'Оновити програми') (T-D9 'Оновлення є для {0} програм (усі, не лише з каталогу). Відкриті програми краще закрити — їх не вдасться оновити.' $up.Count) $text)) { return }
            $ui.LogExpander.IsExpanded = $true
            & $startJob (T-D9 'Оновлення програм') { Invoke-D9AppUpgradeAll } $null {
                param($r)
                $ok = $r.Result -in 'installed', 'upToDate'
                [void][Windows.MessageBox]::Show($win, $(if ($ok) { T-D9 'Програми оновлено.' } else { T-D9 'Оновлення завершено, але частину програм (наприклад, відкритих зараз) оновити не вдалося. Подробиці — у журналі виконання внизу.' }), 'Debora', 'OK', $(if ($ok) { 'Information' } else { 'Warning' }))
                & $loadApps
            }
        }
    })
    # ---------- Видалення програм ----------
    $fillUninst = {
        param($list)
        $state.UninstRows = @(@($list | Where-Object { $_ }) | Sort-Object @{ Expression = { [bool]$_.Bloat }; Descending = $true }, Name | ForEach-Object {
            $cmd = Get-D9UninstallCommand $_
            $note = if ($_.Bloat) { @((T-D9 'Рекомендуємо видалити: {0}' "$($_.Bloat)"), '#D70015') }
                    elseif ($cmd -and $cmd.Method -eq 'orphan') { @((T-D9 'Програму вже видалено, лишився лише запис у списку — Debora прибере його'), '#B25000') }
                    elseif ($cmd -and $cmd.Method -eq 'missing') { @((T-D9 'Деінсталятор відсутній — видаліть через лаунчер програми (Steam, EA, Ubisoft…)'), '#D70015') }
                    elseif ($_.Keep) { @((T-D9 'Потрібна іншим програмам або обладнанню — краще не видаляти'), '#B25000') }
                    elseif ($cmd -and -not $cmd.Silent) { @((T-D9 'відкриється вікно деінсталятора'), '#6E6E73') }
                    else { @('', '#6E6E73') }
            New-D9Row @{ Title = $_.Name; Detail = (T-D9 'Версія: {0}' "$($_.Version)") + $(if ($cmd) { T-D9 '; видалення: {0}' $(if ($cmd.Silent) { T-D9 'тихо' } else { T-D9 'з вікном деінсталятора' }) })
                         Group = $_.Publisher; Note = $(if ($_.Size) { Format-D9Size $_.Size } else { '' }); Kind = $(if ($_.InstallDate) { ([datetime]$_.InstallDate).ToString('dd.MM.yyyy') } else { '' })
                         Status = $note[0]; Color = $note[1]; Tag = $_ }
        })
        & $showUninst
        $bloat = @($state.UninstRows | Where-Object { $_.Tag.Bloat }).Count
        $orphans = @($state.UninstRows | Where-Object { (Get-D9UninstallCommand $_.Tag).Method -eq 'orphan' }).Count
        $ui.UninstSummary.Text = (T-D9 'Встановлено програм: {0}' "$(@($state.UninstRows).Count)") + $(if ($bloat) { T-D9 ', з них рекомендуємо видалити: {0} (вгорі списку)' $bloat }) + $(if ($orphans) { T-D9 '; записів від уже видалених програм: {0}' $orphans }) + (T-D9 '. Більшість видаляється тихо; для решти відкриється звичайний деінсталятор.')
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
        $ui.UninstSelectedText.Text = if ($sel) { (T-D9 'Вибрано: {0}' $sel.Count) + $(if ($size) { T-D9 ', звільниться ≈ {0}' (Format-D9Size $size) }) + (T-D9 '. Після видалення Debora запропонує прибрати залишки.') } else { T-D9 'Нічого не вибрано' }
        $ui.BtnUninstall.Content = if ($sel) { T-D9 'Видалити вибрані ({0})' $sel.Count } else { T-D9 'Видалити вибрані' }
        $ui.BtnUninstall.IsEnabled = [bool]$sel -and -not $state.Job
    }
    $loadUninst = { & $startJob (T-D9 'Читання списку програм (розміри папок рахуються лише першого разу)') { @(Get-D9UninstallListDetailed) } $null { param($r) & $fillUninst @($r) } }
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
            "• $($_.Title)$(if ($c -and $c.Method -eq 'orphan') { T-D9 '  (лише запис — програми вже немає)' })$(if ($c -and -not $c.Silent) { T-D9 '  (відкриється вікно деінсталятора)' })$(if ($_.Tag.Keep) { T-D9 '  ⚠ потрібна іншим програмам' })"
        })
        if (-not (Show-D9TextDialog $win (T-D9 'Видалення програм') (T-D9 'Буде видалено {0} програм(и). Перед цим створюється точка відновлення; повернути програму — встановити знову (вкладка «Програми»).' $sel.Count) ($lines -join "`r`n") (T-D9 'Видалити'))) { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Видалення програм') {
            param($a)
            Write-D9Log (T-D9 'Створення точки відновлення...')
            [void](New-D9RestorePoint)
            @(Uninstall-D9Programs -Programs $a.Programs)
        } @{ Programs = @($sel | ForEach-Object Tag) } {
            param($res)
            $res = @($res | Where-Object { $_ })
            $ok = @($res | Where-Object { $_.result -in 'removed', 'reboot' })
            $bad = @($res | Where-Object { $_.result -notin 'removed', 'reboot' })
            $msg = (T-D9 'Видалено: {0} з {1}.' $ok.Count $res.Count)
            if ($bad) { $msg += "`n" + (($bad | ForEach-Object { "• $($_.name): $($_.message)" }) -join "`n") }
            if (@($res | Where-Object result -eq 'reboot')) { $msg += "`n" + (T-D9 'Для завершення потрібне перезавантаження.') }
            [void][Windows.MessageBox]::Show($win, $msg, 'Debora', 'OK', $(if ($bad) { 'Warning' } else { 'Information' }))
            # Залишки: папки й розділи реєстру, які деінсталятори не прибрали
            $left = @($res | ForEach-Object { $_.leftovers } | Where-Object { $_ })
            if ($left) {
                $size = [long](($left | Measure-Object Size -Sum).Sum)
                $text = ($left | ForEach-Object { if ($_.Type -eq 'folder') { (T-D9 'Папка:  {0}' $_.Path) + $(if ($_.Size) { '  (' + (Format-D9Size $_.Size) + ')' }) } else { T-D9 'Реєстр: {0}' $_.Path } }) -join "`r`n"
                if (Show-D9TextDialog $win (T-D9 'Залишки після видалення') ((T-D9 'Деінсталятори лишили {0} папок і розділів реєстру' $left.Count) + $(if ($size) { ' (' + (Format-D9Size $size) + ')' }) + (T-D9 '. Прибрати? Папки підуть у Кошик, розділи реєстру — з резервною копією .reg, тож усе можна повернути.')) $text (T-D9 'Прибрати')) {
                    & $startJob (T-D9 'Прибирання залишків') { param($a) Remove-D9UninstallLeftovers -Items $a.Items } @{ Items = $left } {
                        param($r)
                        [void][Windows.MessageBox]::Show($win, (T-D9 'Прибрано: {0}. Папки — у Кошику; копія реєстру — {1}' $r.Removed $r.Backup), 'Debora')
                        & $loadUninst
                    }
                    return
                }
            }
            & $loadUninst
        }
    })

    # ---------- Автоматичне обслуговування ----------
    $dayNames = [ordered]@{ Monday = (T-D9 'понеділок'); Tuesday = (T-D9 'вівторок'); Wednesday = (T-D9 'середа'); Thursday = (T-D9 'четвер'); Friday = (T-D9 'п''ятниця'); Saturday = (T-D9 'субота'); Sunday = (T-D9 'неділя') }
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
        $lines += if ($task) { (T-D9 'Розклад увімкнено: щотижня, {0} о {1}' $dayNames[[string]$cfg.Day] $cfg.Time) + $(if ($task.NextRun) { T-D9 '; наступний запуск {0}' (([datetime]$task.NextRun).ToString('dd.MM.yyyy HH:mm')) }) + '.' } else { T-D9 'Розклад вимкнено.' }
        if ($last) { $lines += (T-D9 'Останнє обслуговування {0}: {1}.' (([datetime]$last.finished).ToString('dd.MM.yyyy HH:mm')) (Format-D9MaintenanceSummary $last)) }
        $ui.ScheduleState.Text = $lines -join "`n"
        $ui.BtnScheduleOn.Content = if ($task) { T-D9 'Зберегти розклад' } else { T-D9 'Увімкнути розклад' }
    }
    $ui.BtnScheduleOn.Add_Click({
        if (-not (& $needAdmin)) { return }
        $src = Join-Path (Split-Path $DriverDir) 'Debora.ps1'
        if (-not $script:D9Embedded -or -not (Test-Path $src)) { [void][Windows.MessageBox]::Show($win, (T-D9 'Розклад працює лише зі зібраним Debora.ps1 (запуск через run.bat).'), 'Debora', 'OK', 'Warning'); return }
        $cfg = & $readSchedule
        if (-not $cfg.Steps) { [void][Windows.MessageBox]::Show($win, (T-D9 'Позначте хоча б одну дію.'), 'Debora'); return }
        if ($cfg.Time -notmatch '^\d{1,2}:\d{2}$') { [void][Windows.MessageBox]::Show($win, (T-D9 'Час — у форматі 12:00.'), 'Debora'); return }
        try { Register-D9MaintenanceTask -SourceScript $src -Config $cfg; & $refreshSchedule }
        catch { [void][Windows.MessageBox]::Show($win, (T-D9 'Не вдалося створити розклад: {0}' $_.Exception.Message), 'Debora', 'OK', 'Error') }
    })
    $ui.BtnScheduleOff.Add_Click({
        if (-not (& $needAdmin)) { return }
        try { Unregister-D9MaintenanceTask } catch { }
        & $refreshSchedule
    })
    $ui.BtnMaintainNow.Add_Click({
        if (-not (& $needAdmin)) { return }
        $cfg = & $readSchedule
        if (-not $cfg.Steps) { [void][Windows.MessageBox]::Show($win, (T-D9 'Позначте хоча б одну дію.'), 'Debora'); return }
        if ([Windows.MessageBox]::Show($win, (T-D9 'Виконати обслуговування зараз?') + "`n$(($cfg.Steps | ForEach-Object { '• ' + (T-D9 ([string]$script:D9MaintenanceSteps[$_])) }) -join "`n")`n`n" + (T-D9 'Спершу буде створено точку відновлення. Може тривати від кількох хвилин до години.'), 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        Save-D9MaintenanceConfig $cfg
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Автоматичне обслуговування') { param($a) Invoke-D9Maintenance -Catalog $a.Catalog -SystemInfo $a.Sys -Steps $a.Steps } @{ Catalog = $Catalog; Sys = $SystemInfo; Steps = $cfg.Steps } {
            param($s)
            & $refreshSchedule; & $fillSessions
            $msg = (T-D9 'Готово. {0}.' "$(Format-D9MaintenanceSummary $s)")
            if ($s.reboot) { if ([Windows.MessageBox]::Show($win, "$msg`n`n" + (T-D9 'Перезавантажити комп''ютер зараз?'), 'Debora', 'YesNo', 'Question') -eq 'Yes') { Restart-Computer -Force } }
            else { [void][Windows.MessageBox]::Show($win, $msg, 'Debora') }
        }
    })

    # ---------- Перевстановлення Windows ----------
    $fillUsb = {
        $state.UsbMedia = @(Get-D9InstallMedia)
        $ui.UsbBox.Items.Clear()
        foreach ($m in $state.UsbMedia) {
            [void]$ui.UsbBox.Items.Add("$($m.Drive) $(if ($m.Label) { "«$($m.Label)» " })" + (T-D9 '— файли встановлення Windows') + "$(if ($m.Language) { " ($($m.Language))" })" + (T-D9 ', вільно {0}' (Format-D9Size $m.FreeBytes)))
        }
        if ($state.UsbMedia) {
            $ui.UsbBox.SelectedIndex = 0
            $ui.UsbInfo.Text = (T-D9 'Буде додано autounattend.xml, папку Debora і (за бажанням) драйвери цього ПК. Решта вмісту флешки не змінюється.')
        } else {
            $ui.UsbInfo.Text = (T-D9 'Флешку з Windows не знайдено. Створіть її через Media Creation Tool (microsoft.com/software-download) або Rufus, вставте й натисніть «Оновити список».')
        }
    }
    $ui.BtnUsbRefresh.Add_Click({ & $fillUsb })
    $ui.BtnPrepareUsb.Add_Click({
        if (-not $state.UsbMedia -or $ui.UsbBox.SelectedIndex -lt 0) { [void][Windows.MessageBox]::Show($win, (T-D9 'Вставте флешку з файлами встановлення Windows і натисніть «Оновити список».'), 'Debora'); return }
        $drivers = [bool]$ui.ChkUsbDrivers.IsChecked
        if ($drivers -and -not (& $needAdmin)) { return }
        $media = $state.UsbMedia[$ui.UsbBox.SelectedIndex]
        $opts = @{ UserName = $ui.UserNameBox.Text.Trim(); Password = $ui.AccountPasswordBox.Password; Edition = @('', 'Home', 'Pro')[$ui.EditionBox.SelectedIndex]
                   BypassRequirements = [bool]$ui.ChkUsbBypass.IsChecked; BypassNetwork = $true
                   PostInstall = $(if ($ui.ChkUsbPost.IsChecked) { 'Recommended' } else { '' }); DriverUpdate = [bool]$ui.ChkUsbPost.IsChecked }
        try { [void](New-D9AutounattendXml -Options $opts) } catch { [void][Windows.MessageBox]::Show($win, $_.Exception.Message, 'Debora', 'OK', 'Warning'); return }
        $warn = if ($opts.Password) { "`n`n" + (T-D9 'Пароль зберігається у файлі на флешці відкритим текстом — не залишайте її без нагляду.') } else { '' }
        if ([Windows.MessageBox]::Show($win, (T-D9 'Підготувати флешку {0}?' $media.Drive) + "`n" + (T-D9 'Обліковий запис: {0}' $opts.UserName) + $(if ($drivers) { "`n" + (T-D9 'Драйвери цього ПК буде скопійовано (кілька хвилин).') }) + $warn, 'Debora', 'YesNo', 'Question') -ne 'Yes') { return }
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Підготовка флешки') { param($a) Initialize-D9InstallUsb -Drive $a.Drive -Options $a.Opts -ProgramFolder $a.Prog -IncludeDrivers:$a.Drivers } @{ Drive = $media.Drive; Opts = $opts; Prog = (Split-Path $DriverDir); Drivers = $drivers } {
            param($r)
            [void][Windows.MessageBox]::Show($win, (T-D9 'Флешку {0} підготовлено:' $r.Drive) + "`n• $($r.Done -join "`n• ")`n`n" + (T-D9 'Завантажтеся з неї (меню завантаження — зазвичай F12, F9, Esc або F2) і виберіть диск для Windows. Решта — автоматично.'), 'Debora')
            & $fillUsb
        }
    })
    $ui.BtnExportDrivers.Add_Click({
        if (-not (& $needAdmin)) { return }
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = (T-D9 'Куди зберегти драйвери (краще — флешка або інший диск)')
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $folder = Join-Path $dlg.SelectedPath ("Драйвери {0} {1:yyyy-MM-dd}" -f $env:COMPUTERNAME, (Get-Date))
        $ui.LogExpander.IsExpanded = $true
        & $startJob (T-D9 'Збереження драйверів') { param($a) Export-D9Drivers -Folder $a.Folder } @{ Folder = $folder } {
            param($r)
            [void][Windows.MessageBox]::Show($win, (T-D9 'Збережено драйверів: {0} ({1})' $r.Count (Format-D9Size $r.Bytes)) + "`n$($r.Folder)", 'Debora')
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
                $ui.CountsText.Text += "`n" + (T-D9 '(результат попереднього сканування — натисніть «Сканувати», щоб оновити)')
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
        if ($ui.Tabs.SelectedItem.Uid -eq 'startup' -and -not $state.StartupRows -and -not $state.Job) { & $loadStartup }
        if ($ui.Tabs.SelectedItem.Uid -eq 'apps') { & $buildApps }
        if ($ui.Tabs.SelectedItem.Uid -eq 'apps' -and -not $state.AppsLoaded -and -not $state.Job) { & $loadApps }
        if ($ui.Tabs.SelectedItem.Uid -eq 'uninstall' -and $null -eq $state.UninstRows -and -not $state.Job) { & $loadUninst }
        if ($ui.Tabs.SelectedItem.Uid -eq 'reinstall' -and $null -eq $state.UsbMedia) { & $fillUsb }
        if ($ui.Tabs.SelectedItem.Uid -eq 'maintenance' -and -not $state.DisksLoaded -and -not $state.Job) { & $loadDisks }
        if ($ui.Tabs.SelectedItem.Uid -eq 'debloat' -and -not $state.DebloatLoaded -and -not $state.Job) { & $loadDebloat }
        if ($ui.Tabs.SelectedItem.Uid -eq 'drivers' -and $null -eq $state.Devices -and -not $state.Job) { & $driverReport }
    })
    $win.Add_Closing({ param($sender, $e)
        if ($state.Job) {
            if ([Windows.MessageBox]::Show($win, (T-D9 'Зараз виконується операція. Закрити програму все одно?'), 'Debora', 'YesNo', 'Warning') -ne 'Yes') { $e.Cancel = $true }
        }
    })
    $win.Add_Closed({ $timer.Stop() })
    if ($TestAction) { return (. $TestAction) }
    # Необроблена помилка в обробнику закривала вікно без сліду (ні в журналі, ні в подіях Windows) —
    # тепер її записуємо з місцем у коді, показуємо й продовжуємо роботу
    $win.Dispatcher.Add_UnhandledException({
        param($s, $e)
        $e.Handled = $true
        $ex = $e.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
        $where = if ($ex.ErrorRecord) { $ex.ErrorRecord.InvocationInfo.PositionMessage } else { $ex.StackTrace }
        Write-D9Log (T-D9 'Збій інтерфейсу: {0}' "$($ex.GetType().Name): $($ex.Message)`r`n$where") Error
        try { & $setBusy $false $null } catch { }
        [void][Windows.MessageBox]::Show($win, (T-D9 'Сталася помилка інтерфейсу: {0}. Подробиці — у журналі; програма продовжує роботу.' $ex.Message), 'Debora', 'OK', 'Error')
    })
    try { [void]$win.ShowDialog() }
    catch { Write-D9Log (T-D9 'Збій інтерфейсу: {0}' "$($_.Exception.Message)`r`n$($_.ScriptStackTrace)") Error; throw }
}
