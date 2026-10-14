# Перевірка вікна без показу на екрані: розмітка, заповнення вкладок, фонові завдання.
BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
    $script:catalog = Import-D9Catalog
    $script:sys = New-TestSystemInfo
    $script:rec = [pscustomobject]@{ Preset = 'Standard'; Reasons = @('test') }
    function Invoke-InGui([scriptblock]$Action) {
        Show-D9Gui -Catalog $catalog -SystemInfo $sys -Recommendation $rec -ReportDir (Join-Path $TestDrive 'r') -DriverDir (Join-Path $TestDrive 'd') -TestAction $Action
    }
}
AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Тема й параметри' {
    AfterAll { $script:D9Theme = 'auto' }
    It 'тема <theme>: вікно будується, усі елементи на місці, оцінка показується' -TestCases @(@{ theme = 'light' }, @{ theme = 'dark' }) {
        $script:D9Theme = $theme
        $r = Invoke-InGui {
            $check = [pscustomobject]@{ id = 'perf.memory'; category = 'performance' }
            $f = @((New-D9Finding $check warning 'Пам''ять' 'деталі' @{ type = 'manual' }))
            $cats = (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).categories
            & $fillOverview ([pscustomobject]@{ score = (Get-D9ScanScore -Categories $cats -Findings $f -CheckedCategories @('performance')); findings = $f; checks = @(1); durationSec = 1; time = (Get-Date).ToString('s') }) $cats
            @{ Tabs = $ui.Tabs.Items.Count; Score = $ui.ScoreText.Text; Ring = [string]$ui.ScoreRing.Visibility }
        }
        $r.Tabs | Should -Be 12
        $r.Score | Should -Be '90'
        $r.Ring | Should -Be 'Collapsed'
    }
    It '«Параметри»: мова, тема, сповіщення, приховане й дані заповнюються' {
        $r = Invoke-InGui {
            & $fillPrefs
            @{ Lang = $ui.PrefLanguage.Items.Count; LangSel = $ui.PrefLanguage.SelectedIndex; Theme = $ui.PrefTheme.Items.Count; About = $ui.PrefAbout.Text; Hidden = $ui.PrefHiddenText.Text; Ready = $state.PrefsReady }
        }
        $r.Lang | Should -Be 3
        $r.LangSel | Should -BeGreaterOrEqual 0
        $r.Theme | Should -Be 3
        $r.About | Should -Match 'Debora'
        $r.Hidden | Should -Not -BeNullOrEmpty
        $r.Ready | Should -BeTrue
    }
    It 'Resolve-D9Theme: явний вибір має перевагу' {
        Resolve-D9Theme 'dark' | Should -Be 'dark'
        Resolve-D9Theme 'light' | Should -Be 'light'
        Resolve-D9Theme 'auto' | Should -BeIn @('auto', 'light', 'dark')
    }
}

Describe 'Вікно' {
    It 'розмітка завантажується, усі елементи знайдено, шапка заповнена' {
        $r = Invoke-InGui { @{ Title = $ui.TitleText.Text; Line = $ui.SystemLine.Text; Presets = $ui.PresetBox.Items.Count; Preset = $ui.PresetBox.SelectedItem } }
        $r.Title | Should -Match '^Debora'
        $r.Line | Should -Match 'Test'
        $r.Presets | Should -Be @($catalog.Presets).Count
        $r.Preset | Should -Be 'Стандартний'
    }

    It 'вкладка «Програми»: категорії, пошук, набори, лічильник, оновлення' {
        $r = Invoke-InGui {
            & $buildApps   # картки будуються при першому відкритті вкладки
            $popular = @($ui.AppCards.ItemsSource).Count
            $state.AppFilter = 'all'; & $showApps
            $all = @($ui.AppCards.ItemsSource).Count
            $ui.AppSearch.Text = 'pdf'
            $found = @($ui.AppCards.ItemsSource | ForEach-Object Title)
            $hint = [string]$ui.AppSearchHint.Visibility
            $ui.AppSearch.Text = ''
            # набір «Базовий» вибирає свої програми й показує «Вибрані»
            $basic = @($ui.AppBundles.Children)[0]
            $basic.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
            $selected = @($ui.AppCards.ItemsSource).Count
            $selText = $ui.AppSelectedText.Text
            # встановлена програма з оновленням лишається доступною для вибору
            $chrome = $state.AppRows | Where-Object Id -eq 'Google.Chrome'
            $state.AppUpgrades['Google.Chrome'] = [pscustomobject]@{ Version = '1.0'; Available = '2.0' }
            & $markApp $chrome $true
            $vlc = $state.AppRows | Where-Object Id -eq 'VideoLAN.VLC'
            & $markApp $vlc $true
            @{ Popular = $popular; All = $all; Found = $found; Hint = $hint; Selected = $selected; SelText = $selText; Chrome = $chrome.Status; ChromeOn = $chrome.Enabled; Vlc = $vlc.Status; VlcOn = $vlc.Enabled; Cats = @($ui.AppCategoryList.ItemsSource).Count }
        }
        $cat = Import-D9AppCatalog
        $r.All | Should -Be @($cat.apps).Count
        $r.Popular | Should -Be @($cat.apps | Where-Object popular).Count
        $r.Found | Should -Contain 'SumatraPDF'
        $r.Hint | Should -Be 'Collapsed'
        $r.Selected | Should -Be @($cat.bundles[0].apps).Count
        $r.SelText | Should -Match "Вибрано: $(@($cat.bundles[0].apps).Count)"
        $r.Chrome | Should -Be 'є оновлення: 1.0 → 2.0'
        $r.ChromeOn | Should -BeTrue
        $r.Vlc | Should -Be '✓ встановлено'
        $r.VlcOn | Should -BeFalse
        $r.Cats | Should -Be (5 + @($cat.categories).Count)
    }

    It 'вкладка «Огляд» показує оцінку, категорії й знахідки' {
        $r = Invoke-InGui {
            $state.ShowAllFindings = $true   # усі знахідки, а не лише важливе
            $check = [pscustomobject]@{ id = 'perf.memory'; category = 'performance' }
            $items = @([pscustomobject]@{ path = 'C:\x\a.exe'; bytes = 5MB; date = '2026-01-01T00:00:00'; kind = 'file' }, [pscustomobject]@{ path = 'C:\x\y'; bytes = 2MB; date = '2026-01-01T00:00:00'; kind = 'folder' })
            $f = @((New-D9Finding $check warning 'Багато пам''яті' 'деталі' @{ type = 'manual' } @((New-D9Link 'Сайт' 'https://example.com')) -Data ([pscustomobject]@{ bytes = 7MB; items = $items }))
                   (New-D9Finding ([pscustomobject]@{ id = 'clean.temp'; category = 'cleanliness' }) suggestion 'Тимчасові файли' '' @{ type = 'tweaks'; ids = @('cleanup.temp') }))
            $cats = (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).categories
            $scan = [pscustomobject]@{ score = (Get-D9ScanScore -Categories $cats -Findings $f -CheckedCategories @('performance', 'security', 'cleanliness')); findings = $f; checks = @(1, 2); durationSec = 5; time = (Get-Date).ToString('s') }
            & $fillOverview $scan $cats
            @{ Score = $ui.ScoreText.Text; Verdict = $ui.VerdictText.Text; Cats = @($ui.CategoryList.ItemsSource).Count; Findings = @($ui.FindingsList.ItemsSource); }
        }
        [int]$r.Score | Should -BeGreaterThan 80
        $r.Cats | Should -Be 3
        $r.Findings.Count | Should -Be 2
        # Кнопка дії: ручна знахідка — «Як виправити», з твіком — «Виправити»; знахідка — у Tag
        $r.Findings[0].FixLabel | Should -BeNullOrEmpty
        $r.Findings[0].GuideLabel | Should -Be 'Як виправити'
        $r.Findings[1].FixLabel | Should -Be 'Виправити'
        $r.Findings[1].Tag.checkId | Should -Be 'clean.temp'
        # Типово — лише важливе; поради й відомості за кнопкою
        $r2 = Invoke-InGui {
            $cats = (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).categories
            $f = @((New-D9Finding ([pscustomobject]@{ id = 'sec.tpm'; category = 'security' }) warning 'a' '' @{ type = 'manual' }), (New-D9Finding ([pscustomobject]@{ id = 'perf.uptime'; category = 'performance' }) suggestion 'b' '' @{ type = 'manual' }))
            & $fillOverview ([pscustomobject]@{ score = (Get-D9ScanScore -Categories $cats -Findings $f -CheckedCategories @('security', 'performance')); findings = $f; checks = @(1); durationSec = 1; time = (Get-Date).ToString('s') }) $cats
            @{ N = @($ui.FindingsList.ItemsSource).Count; More = [string]$ui.BtnMoreFindings.Content }
        }
        $r2.N | Should -Be 1
        $r2.More | Should -Match '1'
        $r.Findings[0].Links[0].Url | Should -Be 'https://example.com'
        $r.Findings[0].Items.Count | Should -Be 2
        $r.Findings[0].Items[0].Title | Should -Be 'a.exe'
        $r.Findings[0].Items[0].Tag | Should -Be 'select:C:\x\a.exe'
        $r.Findings[0].Items[1].Title | Should -Be 'C:\x\y'
        $r.Findings[0].Hint | Should -Match '^2 '
    }

    It 'вікна «Як виправити» і вибору файлів: кнопки працюють після показу (обробники без локальних змінних)' {
        # Регресія: «Закрити» в «Як виправити» падало з «property DialogResult cannot be found» —
        # обробник кліку посилався на змінну функції, якої вже не було
        $r = Invoke-InGui {
            function Find-Default($dep) { foreach ($c in [Windows.LogicalTreeHelper]::GetChildren($dep)) { if ($c -is [Windows.Controls.Button] -and $c.IsDefault) { return $c }; if ($c -is [Windows.DependencyObject]) { $x = Find-Default $c; if ($x) { return $x } } } }
            $click = {
                param($w)
                $w.Left = -10000; $w.ShowActivated = $false
                $w.Add_ContentRendered({ param($s) $b = Find-Default $s; $b.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))) })
                $t = New-Object Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromSeconds(5); $t.Tag = $w
                $t.Add_Tick({ param($s) $s.Stop(); $s.Tag.Close() }); $t.Start()
                $res = $w.ShowDialog(); $t.Stop(); $res
            }
            $guide = & $click (New-D9GuideWindow $win 'Заголовок' 'опис' @('крок 1', 'крок 2') @())
            $items = @([pscustomobject]@{ path = 'C:\x\a.exe'; bytes = 3MB; date = '2026-01-01T00:00:00' }, [pscustomobject]@{ path = 'C:\x\b.zip'; bytes = 1MB; date = '2026-01-01T00:00:00' })
            $fw = New-D9FilesWindow $win 'Файли' $items
            $sumBefore = $fw.Tag.Sum.Text
            $fw.Tag.Boxes[1].IsChecked = $false
            $fw.Tag.Boxes[1].RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            $sumAfter = $fw.Tag.Sum.Text
            $files = & $click $fw
            @{ Guide = $guide; Files = $files; Before = $sumBefore; After = $sumAfter; Selected = @($fw.Tag.Boxes | Where-Object IsChecked | ForEach-Object Tag) }
        }
        $r.Guide | Should -BeTrue
        $r.Files | Should -BeTrue
        $r.Before | Should -Match 'Вибрано: 2'
        $r.After | Should -Match 'Вибрано: 1'
        $r.Selected | Should -Be @('C:\x\a.exe')
    }

    It 'вкладка «Налаштування»: галочки за профілем, непридатні вимкнено' {
        $r = Invoke-InGui {
            $states = foreach ($t in $catalog.Tweaks) { [pscustomobject]@{ Id = $t.id; State = $(if ($t.id -eq 'perf.disable-sysmain') { 'notApplicable' } else { 'notApplied' }); Reason = $null } }
            & $fillTweaks @($states)
            @{ Rows = $state.TweakRows }
        }
        $r.Rows.Count | Should -Be @(Get-D9SettingsTweaks $catalog).Count
        # Деблоат і очищення мають власні вкладки — тут їх немає
        @($r.Rows.Id) | Should -Not -Contain 'privacy.telemetry'
        @($r.Rows.Id) | Should -Not -Contain 'apps.remove-bloat'
        @($r.Rows.Id) | Should -Not -Contain 'cleanup.temp'
        ($r.Rows | Where-Object Id -eq 'safety.disable-autorun').Selected | Should -BeTrue
        ($r.Rows | Where-Object Id -eq 'perf.disable-sysmain').Enabled | Should -BeFalse
        ($r.Rows | Where-Object Id -eq 'perf.disable-memory-integrity').Selected | Should -BeFalse
    }

    It 'сканування з вікна: фон → «Огляд», внутрішній чекліст → HTML-звіт' {
        $script:sys = Get-D9SystemInfo
        $r = Invoke-InGui {
            & $startJob 'Сканування' $scanWork @{ Catalog = $catalog; Sys = $SystemInfo; Deep = $false; ReportDir = $ReportDir } $onScanned
            $job = $state.Job
            [void]$job.Handle.AsyncWaitHandle.WaitOne(180000)
            $out = @($job.PS.EndInvoke($job.Handle))[0]
            $job.PS.Dispose(); $job.RS.Dispose(); $state.Job = $null
            if ($out.ok) { & $onScanned $out.result }
            @{ Ok = $out.ok; Error = $out.error; Score = $ui.ScoreText.Text; Findings = @($ui.FindingsList.ItemsSource).Count
               Steps = @($state.Checklist.items).Count; Fixable = @(@($ui.FindingsList.ItemsSource) | Where-Object { $_.FixLabel }).Count; Report = $state.ReportPath; Progress = $sync.Progress }
        }
        $r.Ok | Should -BeTrue -Because $r.Error
        [int]$r.Score | Should -BeGreaterThan 0
        $r.Steps | Should -BeGreaterThan 0
        if ($r.Findings) { $r.Fixable | Should -BeGreaterThan 0 }
        Test-Path $r.Report | Should -BeTrue
        $r.Progress[1] | Should -BeGreaterOrEqual 100   # прогрес приходив із фону
    }

    It 'вкладки «Автозавантаження» й «Обслуговування»' {
        $r = Invoke-InGui {
            $items = @([pscustomobject]@{ Name = 'App'; Command = 'C:\app.exe'; Exe = 'C:\app.exe'; Publisher = $null; Enabled = $true; Where = 'Реєстр'; Kind = 'reg'; ApprovedPath = 'HKCU:\x'; ValueName = 'App'; Missing = $true })
            & $fillStartup $items
            & $refreshMaintenance
            @{ Tabs = $ui.Tabs.Items.Count; Rows = $state.StartupRows; Pause = $ui.PauseState.Text; Drivers = $ui.WuDriversState.Text }
        }
        $r.Tabs | Should -Be 12
        $r.Rows[0].Selected | Should -BeTrue
        $r.Rows[0].Status | Should -Match 'файл відсутній'
        $r.Pause | Should -Not -BeNullOrEmpty
        $r.Drivers | Should -Match 'Windows'
    }

    It 'вкладка «З нуля»: профіль заповнює елементи й читається назад' {
        $r = Invoke-InGui {
            $p = ConvertTo-D9SetupProfile ([pscustomobject]@{ name = 'Тест'; steps = @('drivers', 'apps', 'hack'); preset = 'WeakPC'; bundles = @('games'); apps = @('Google.Chrome'); reboot = $false })
            & $fillSetup $p
            $back = & $readSetup
            @{ Drivers = $ui.ChkSuDrivers.IsChecked; Debloat = $ui.ChkSuDebloat.IsChecked; Preset = $ui.SuPresetBox.SelectedIndex; Bundles = @($ui.SuBundles.ItemsSource).Count
               Back = $back; Items = @($ui.SuPresetBox.Items).Count }
        }
        $r.Drivers | Should -BeTrue
        $r.Debloat | Should -BeFalse
        $r.Preset | Should -BeGreaterThan 0
        $r.Bundles | Should -BeGreaterThan 3
        $r.Items | Should -BeGreaterThan 3
        $r.Back.steps | Should -Be @('drivers', 'apps')
        $r.Back.preset | Should -Be 'WeakPC'
        $r.Back.bundles | Should -Be @('games')
        $r.Back.apps | Should -Be @('Google.Chrome')
        $r.Back.reboot | Should -BeFalse
        $r.Back.name | Should -Be 'Тест'
    }

    It 'темна тема: розмітка будується, кольори фону й статусів темні/світлі' {
        $script:D9Theme = 'dark'
        try {
            $r = Invoke-InGui {
                $row = New-D9Row @{ Color = '#D70015' }
                @{ Bg = $win.Background.ToString(); Fg = $win.Foreground.ToString(); Row = $row.Color; Tabs = $ui.Tabs.Items.Count }
            }
        } finally { $script:D9Theme = 'light' }
        $r.Bg | Should -Be '#FF1C1C1E'
        $r.Fg | Should -Be '#FFF5F5F7'
        $r.Row | Should -Be '#FF453A'
        $r.Tabs | Should -BeGreaterThan 5
        (Invoke-InGui { (New-D9Row @{ Color = '#D70015' }).Color }) | Should -Be '#D70015' -Because 'у світлій темі кольори не змінюються'
    }

    It 'програмна зміна галочок видна на екрані («Зняти все», «Вибрати профіль»)' {
        # Регресія: рядки в обгортці PSObject — WPF не бачив змін, галочки на екрані лишались
        $r = Invoke-InGui {
            function Pump { $f = New-Object Windows.Threading.DispatcherFrame; [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Action]{ $f.Continue = $false }, [Windows.Threading.DispatcherPriority]::Background); [Windows.Threading.Dispatcher]::PushFrame($f) }
            function Get-Boxes($dep) { $out = @(); for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($dep); $i++) { $c = [Windows.Media.VisualTreeHelper]::GetChild($dep, $i); if ($c -is [Windows.Controls.CheckBox]) { $out += $c }; $out += Get-Boxes $c }; $out }
            $win.ShowActivated = $false; $win.Left = -10000; $win.Show()
            # Loaded запускає таймер (стартові кроки в тестах вимкнено) — зупиняємо, щоб задачі не перезаповнили таблицю й не тримали Close()
            $timer.Stop()
            if ($state.Job) { try { $state.Job.PS.Stop() } catch { }; $state.Job.PS.Dispose(); $state.Job.RS.Dispose(); $state.Job = $null }
            $ui.Tabs.SelectedItem = @($ui.Tabs.Items | Where-Object Uid -eq 'settings')[0]; Pump
            & $fillTweaks @($Catalog.Tweaks | ForEach-Object { [pscustomobject]@{ Id = $_.id; State = 'notApplied'; Reason = $null } }); Pump
            $before = @(Get-Boxes $ui.TweakGrid | Where-Object IsChecked).Count
            $ui.BtnSelectNone.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))); Pump
            $after = @(Get-Boxes $ui.TweakGrid | Where-Object IsChecked).Count
            $win.Close()
            @{ Before = $before; After = $after }
        }
        $r.Before | Should -BeGreaterThan 0
        $r.After | Should -Be 0
    }

    It 'черга: друга задача під час першої не губиться, дублі не додаються, порядок можна змінити' {
        $r = Invoke-InGui {
            $script:order = @()
            $runTicks = { for ($i = 0; $i -lt 600 -and ($state.Job -or $state.Queue.Count); $i++) { if ($state.Job) { [void]$state.Job.Handle.AsyncWaitHandle.WaitOne(100) }; & $onTick } }
            & $startJob 'A' { Start-Sleep -Milliseconds 300; 'a' } $null { param($x) $script:order += $x }
            & $startJob 'B' { 'b' } $null { param($x) $script:order += $x }
            & $startJob 'C' { 'c' } $null { param($x) $script:order += $x }
            & $startJob 'B' { 'b2' } $null { param($x) $script:order += $x }      # дубль — не додається
            $queued = @($state.Queue | ForEach-Object Title)
            $panel = [string]$ui.TaskPanel.Visibility
            $toggle = [string]$ui.BtnQueueToggle.Content
            # «Вище» для C
            $state.Queue.RemoveAt(1); $state.Queue.Insert(0, @{ Id = 'c'; Title = 'C'; Work = { 'c' }; Done = { param($x) $script:order += $x }; Kind = 'C' })
            & $runTicks
            @{ Queued = $queued; Order = $script:order; Panel = $panel; Toggle = $toggle; After = [string]$ui.TaskPanel.Visibility }
        }
        $r.Queued | Should -Be @('B', 'C')
        $r.Panel | Should -Be 'Visible'
        $r.Toggle | Should -Match '2'
        $r.Order | Should -Be @('a', 'c', 'b')
        $r.After | Should -Be 'Collapsed'
    }

    It 'панель: крок N з M і назва етапу з фону, таймер іде, «Зупинити» перериває між кроками' {
        $r = Invoke-InGui {
            & $startJob 'Довга задача' {
                $n = 0
                for ($i = 1; $i -le 30; $i++) {
                    if (Test-D9CancelRequested) { break }
                    Set-D9Stage -Name "етап $i" -Step $i -Of 30
                    Start-Sleep -Milliseconds 100; $n++
                }
                $n
            } $null { param($x) $script:done = $x } -CanCancel
            Start-Sleep -Milliseconds 650
            & $onTick
            $stage = $ui.TaskStage.Text; $stop = [string]$ui.BtnTaskStop.Visibility; $timerText = $ui.TaskTimer.Text; $bar = $ui.TaskBar.Maximum
            $ui.BtnTaskStop.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent)))
            for ($i = 0; $i -lt 100 -and $state.Job; $i++) { [void]$state.Job.Handle.AsyncWaitHandle.WaitOne(100); & $onTick }
            @{ Stage = $stage; Stop = $stop; Timer = $timerText; Bar = $bar; Done = $script:done }
        }
        $r.Stage | Should -Match '^Крок \d+ з 30: етап \d+$'
        $r.Stop | Should -Be 'Visible'
        $r.Timer | Should -Match '^0:0\d$'
        $r.Bar | Should -Be 30
        $r.Done | Should -BeLessThan 30
    }

    It '«Приховати» прибирає знахідку й оцінку не знижує; «Приховані: N» показує її з «Показати знову»' {
        $r = Invoke-InGui {
            $p = Get-D9HiddenPath; if (Test-Path $p) { [IO.File]::WriteAllText($p, '{}') }
            $cats = (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).categories
            $f = @((New-D9Finding ([pscustomobject]@{ id = 'sec.tpm'; category = 'security' }) warning 'TPM вимкнено' 'd' @{ type = 'manual' }))
            $state.Categories = $cats
            & $fillOverview ([pscustomobject]@{ id = 'test-hide'; score = (Get-D9ScanScore -Categories $cats -Findings $f -CheckedCategories @('security')); findings = $f; checks = @(1); durationSec = 1; time = (Get-Date).ToString('s') }) $cats
            $before = [int]$ui.ScoreText.Text
            $row = @($ui.FindingsList.ItemsSource)[0]
            $label = $row.HideLabel
            & $hideFinding $row
            $after = [int]$ui.ScoreText.Text; $left = @($ui.FindingsList.ItemsSource).Count; $link = [string]$ui.BtnHiddenFindings.Content
            & $showHidden
            $hiddenRow = @($ui.FindingsList.ItemsSource)[0]
            @{ Before = $before; After = $after; Left = $left; Label = $label; Link = $link; HiddenTitle = $hiddenRow.Title; HiddenLabel = $hiddenRow.HideLabel }
        }
        $r.Label | Should -Be 'Приховати'
        $r.After | Should -BeGreaterThan $r.Before
        $r.Left | Should -Be 0
        $r.Link | Should -Match '1'
        $r.HiddenTitle | Should -Be 'TPM вимкнено'
        $r.HiddenLabel | Should -Be 'Показати знову'
    }

    It '«Деблоат»: пошук фільтрує рядки' {
        $r = Invoke-InGui {
            Set-D9Items $ui.DebloatGrid @((New-D9Row @{ Title = 'Copilot'; Detail = 'ШІ'; Badge = 'a' }), (New-D9Row @{ Title = 'Xbox'; Detail = 'ігри'; Badge = 'b' }))
            $ui.DebloatSearch.Text = 'copi'
            $v = [Windows.Data.CollectionViewSource]::GetDefaultView($ui.DebloatGrid.ItemsSource)
            @{ N = @($v | ForEach-Object { $_ }).Count }
        }
        $r.N | Should -Be 1
    }

    It '«Деблоат»: кнопки рівнів відмічають свій рівень і нижчі; лічильник показує, що щось перестане працювати' {
        $r = Invoke-InGui {
            $rows = @(
                (New-D9Row @{ Title = 'Candy Crush'; Badge = 'a'; Enabled = $true; Tag = [pscustomobject]@{ Level = 'safe' } })
                (New-D9Row @{ Title = 'Teams'; Badge = 'a'; Enabled = $true; Hint = 'чат'; Tag = [pscustomobject]@{ Level = 'recommended' } })
                (New-D9Row @{ Title = 'Xbox'; Badge = 'a'; Enabled = $true; Hint = 'ігри'; Tag = [pscustomobject]@{ Level = 'max' } })
                (New-D9Row @{ Title = 'Зроблено'; Badge = 'a'; Enabled = $false; Tag = [pscustomobject]@{ Level = 'safe' } })
            )
            Set-D9Items $ui.DebloatGrid $rows
            $sel = { @($ui.DebloatGrid.ItemsSource | Where-Object Selected | ForEach-Object Title) -join ',' }
            & $selectDebloatLevel 'safe'; $a = & $sel
            & $selectDebloatLevel 'recommended'; $b = & $sel; $txt = $ui.DebloatSelText.Text
            $ui.BtnDebloatMax.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))); $c = & $sel
            @{ A = $a; B = $b; C = $c; Txt = $txt; Level = $state.DebloatLevel }
        }
        $r.A | Should -Be 'Candy Crush'
        $r.B | Should -Be 'Candy Crush,Teams'
        $r.C | Should -Be 'Candy Crush,Teams,Xbox'
        $r.Txt | Should -Match '2.*1'
        $r.Level | Should -Be 'max'
    }

    It 'загальний пошук: збіги за назвою, вибір повертає вкладку й запит' {
        $r = Invoke-InGui {
            $w = New-D9SearchWindow $win @([pscustomobject]@{ Text = 'Вимкнути телеметрію'; Sub = 'Деблоат'; Tab = 'debloat'; Query = 'телеметр' }, [pscustomobject]@{ Text = 'Google Chrome'; Sub = 'Програми'; Tab = 'apps'; Query = 'Chrome' })
            $w.Tag.Box.Text = 'телем'
            $n = @($w.Tag.List.ItemsSource).Count
            $first = $w.Tag.List.SelectedItem.Item.Tab
            $w.Tag.Box.Text = 'x'
            @{ N = $n; First = $first; Short = @($w.Tag.List.ItemsSource).Count }
        }
        $r.N | Should -Be 1
        $r.First | Should -Be 'debloat'
        $r.Short | Should -Be 0
    }

    It 'після змін з''являється смуга швидкого відкату' {
        $r = Invoke-InGui {
            & $startJob 'Тест змін' { [pscustomobject]@{ id = 'test-session'; entries = @([pscustomobject]@{ result = 'ok' }, [pscustomobject]@{ result = 'ok' }) } } $null $null
            for ($i = 0; $i -lt 100 -and $state.Job; $i++) { [void]$state.Job.Handle.AsyncWaitHandle.WaitOne(100); & $onTick }
            & $onTick
            @{ Vis = [string]$ui.UndoBar.Visibility; Text = $ui.UndoText.Text; Id = $state.UndoId }
        }
        $r.Vis | Should -Be 'Visible'
        $r.Text | Should -Match '2'
        $r.Id | Should -Be 'test-session'
    }

    It 'ланцюжок завдань через таймер: контекст доходить до $Done і до наступного завдання' {
        # Регресія: «Застосувати вибране» запускало друге завдання з $Done, де локальна $ids була порожня
        $r = Invoke-InGui {
            $script:chainResult = $null
            $runTicks = {
                for ($i = 0; $i -lt 600 -and $state.Job; $i++) {
                    [void]$state.Job.Handle.AsyncWaitHandle.WaitOne(100)
                    & $onTick
                }
            }
            & {
                $ids = @('ui.explorer', 'perf.game-dvr')   # локальна змінна «обробника кнопки»
                & $startJob 'крок 1' { param($a) $a.Ids.Count } @{ Ids = $ids } {
                    param($count, $c)
                    & $startJob 'крок 2' { param($a) @($a.Ids) -join ',' } @{ Ids = $c.Ids } { param($joined, $c2) $script:chainResult = "$($c2.Count)|$joined" } @{ Count = $count }
                } @{ Ids = $ids }
            }
            & $runTicks; & $runTicks
            $script:chainResult
        }
        $r | Should -Be '2|ui.explorer,perf.game-dvr'
    }

    It 'фонове завдання має доступ до функцій і даних ядра та передає журнал' {
        $r = Invoke-InGui {
            & $startJob 'тест' {
                param($a)
                Write-D9Log 'привіт із фону'
                $t = Get-D9Tweak $a.Catalog 'ui.explorer'
                @{ State = (Get-D9TweakState $t $a.Sys); Types = $script:D9ActionTypes.Count }
            } @{ Catalog = $catalog; Sys = $sys } $null
            $job = $state.Job
            [void]$job.Handle.AsyncWaitHandle.WaitOne(60000)
            $out = @($job.PS.EndInvoke($job.Handle))[0]
            $job.PS.Dispose(); $job.RS.Dispose()
            $line = $null; [void]$sync.Log.TryDequeue([ref]$line)
            @{ Out = $out; Log = $line }
        }
        $r.Out.ok | Should -BeTrue -Because $r.Out.error
        $r.Out.result.State | Should -BeIn @('applied', 'partial', 'notApplied')
        $r.Out.result.Types | Should -BeGreaterOrEqual 7
        $r.Log | Should -Match 'привіт із фону'
    }
}

Describe 'Кільце оцінки' {
    It 'порожнє для 0, дуга для частини, повне коло для 100' {
        Add-Type -AssemblyName PresentationCore
        Get-D9RingGeometry 0 118 11 | Should -BeNullOrEmpty
        $half = Get-D9RingGeometry 50 118 11
        $half.Bounds.Width | Should -BeLessThan 60
        $full = Get-D9RingGeometry 100 118 11
        [math]::Round($full.Bounds.Width) | Should -Be 107
        [math]::Round((Get-D9RingGeometry 75 118 11).Bounds.Width) | Should -Be 107
    }
}

Describe 'Смуга «Windows скасувала ваші зміни»' {
    It 'з''являється з кількістю й прикладом, ховається, коли повертати нічого; розклад має галочку' {
        $r = Invoke-InGui {
            $state.GuardItems = @([pscustomobject]@{ Key = 'k1'; Tweak = 'a'; Text = 'Copilot — увімкнено' }, [pscustomobject]@{ Key = 'k2'; Tweak = 'b'; Text = 'реклама' })
            & $showGuardBar
            $shown = @{ Vis = [string]$ui.GuardBar.Visibility; Text = $ui.GuardText.Text }
            $state.GuardItems = @(); & $showGuardBar
            @{ Shown = $shown; After = [string]$ui.GuardBar.Visibility; Box = [bool]$ui.ChkMtGuard }
        }
        $r.Shown.Vis | Should -Be 'Visible'
        $r.Shown.Text | Should -Match '2'
        $r.Shown.Text | Should -Match 'Copilot'
        $r.After | Should -Be 'Collapsed'
        $r.Box | Should -BeTrue
    }
}
