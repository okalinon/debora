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

Describe 'Стилі вікна' {
    AfterAll { $script:D9Style = 'focus'; $script:D9Theme = 'auto' }
    It 'стиль <style> (<theme>): вікно будується, усі елементи на місці, оцінка показується' -TestCases @(
        @{ style = 'focus'; theme = 'light' }, @{ style = 'swiss'; theme = 'light' }, @{ style = 'focus'; theme = 'dark' }, @{ style = 'swiss'; theme = 'dark' }
    ) {
        $script:D9Style = $style; $script:D9Theme = $theme
        $r = Invoke-InGui {
            $check = [pscustomobject]@{ id = 'perf.memory'; category = 'performance' }
            $f = @((New-D9Finding $check warning 'Пам''ять' 'деталі' @{ type = 'manual' }))
            $cats = (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).categories
            & $fillOverview ([pscustomobject]@{ score = (Get-D9ScanScore -Categories $cats -Findings $f -CheckedCategories @('performance')); findings = $f; checks = @(1); durationSec = 1; time = (Get-Date).ToString('s') }) $cats
            @{ Tabs = $ui.Tabs.Items.Count; Score = $ui.ScoreText.Text; StyleBtn = [string]$ui.BtnStyle.Content; Ring = [string]$ui.ScoreRing.Visibility }
        }
        $r.Tabs | Should -Be 11
        $r.Score | Should -Be '90'
        $r.Ring | Should -Be 'Collapsed'
        $r.StyleBtn | Should -Match $(if ($style -eq 'focus') { 'Фокус' } else { 'Швейцарський' })
    }
    It 'стиль <style>: клік по «Стиль» і «English» влучає в кнопку, а не в журнал виконання' -TestCases @(@{ style = 'focus' }, @{ style = 'swiss' }) {
        $script:D9Style = $style; $script:D9Theme = 'light'
        $r = Invoke-InGui {
            $root = $win.Content; $win.Content = $null; $host2 = New-Object Windows.Controls.Border; foreach ($k in $win.Resources.Keys) { $host2.Resources[$k] = $win.Resources[$k] }; $host2.Child = $root; $host2.Measure((New-Object Windows.Size 1340, 900)); $host2.Arrange((New-Object Windows.Rect 0, 0, 1340, 900)); $host2.UpdateLayout()
            foreach ($b in $ui.BtnStyle, $ui.BtnLanguage) {
                $pt = $b.TranslatePoint((New-Object Windows.Point ($b.ActualWidth / 2), ($b.ActualHeight / 2)), $host2)
                $hit = [Windows.Media.VisualTreeHelper]::HitTest($host2, $pt).VisualHit
                $ok = $false
                while ($hit) { if ($hit -eq $b) { $ok = $true; break }; $hit = [Windows.Media.VisualTreeHelper]::GetParent($hit) }
                $ok
            }
        }
        @($r) | Should -Be @($true, $true)
    }
    It 'Resolve-D9Style: явний вибір, інакше фокус; Фокус ↔ Швейцарський' {
        Resolve-D9Style 'swiss' | Should -Be 'swiss'
        Resolve-D9Style 'nonsense' | Should -BeIn @('focus', 'swiss')
        Resolve-D9Style 'classic' | Should -BeIn @('focus', 'swiss')
        Get-D9NextStyle 'focus' | Should -Be 'swiss'
        Get-D9NextStyle 'swiss' | Should -Be 'focus'
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
        $r.Vlc | Should -Be 'встановлено'
        $r.VlcOn | Should -BeFalse
        $r.Cats | Should -Be (5 + @($cat.categories).Count)
    }

    It 'вкладка «Огляд» показує оцінку, категорії й знахідки' {
        $r = Invoke-InGui {
            $check = [pscustomobject]@{ id = 'perf.memory'; category = 'performance' }
            $f = @((New-D9Finding $check warning 'Багато пам''яті' 'деталі' @{ type = 'manual' } @((New-D9Link 'Сайт' 'https://example.com'))))
            $cats = (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).categories
            $scan = [pscustomobject]@{ score = (Get-D9ScanScore -Categories $cats -Findings $f -CheckedCategories @('performance', 'security')); findings = $f; checks = @(1, 2); durationSec = 5; time = (Get-Date).ToString('s') }
            & $fillOverview $scan $cats
            @{ Score = $ui.ScoreText.Text; Verdict = $ui.VerdictText.Text; Cats = @($ui.CategoryList.ItemsSource).Count; Findings = @($ui.FindingsList.ItemsSource); }
        }
        [int]$r.Score | Should -BeGreaterThan 80
        $r.Cats | Should -Be 2
        $r.Findings.Count | Should -Be 1
        $r.Findings[0].Links[0].Url | Should -Be 'https://example.com'
    }

    It 'вкладка «Чекліст» показує кроки й позначки виконання' {
        $r = Invoke-InGui {
            $item = New-D9ChecklistItem 50 'c' 'Очистити диск' 'бо мало місця' @() @{ type = 'tweaks'; ids = @('cleanup.temp') } @{ type = 'executed' }
            $item.number = 1
            $done = New-D9ChecklistItem 10 'b' 'Резервна копія' '' @() @{ type = 'manual' } $null
            $done.number = 2; $done.status = 'done'
            & $fillChecklist ([pscustomobject]@{ items = @($item, $done) })
            @{ Rows = @($ui.ChecklistList.ItemsSource); Summary = $ui.ChecklistSummary.Text }
        }
        $r.Rows.Count | Should -Be 2
        $r.Rows[0].Kind | Should -Be 'автоматично'
        $r.Rows[1].Selected | Should -BeTrue
        $r.Summary | Should -Match 'Виконано 1 з 2'
    }

    It 'вкладка «Налаштування»: галочки за профілем, непридатні вимкнено' {
        $r = Invoke-InGui {
            $states = foreach ($t in $catalog.Tweaks) { [pscustomobject]@{ Id = $t.id; State = $(if ($t.id -eq 'perf.disable-sysmain') { 'notApplicable' } else { 'notApplied' }); Reason = $null } }
            & $fillTweaks @($states)
            @{ Rows = $state.TweakRows }
        }
        $r.Rows.Count | Should -Be @($catalog.Tweaks).Count
        ($r.Rows | Where-Object Id -eq 'privacy.telemetry').Selected | Should -BeTrue
        ($r.Rows | Where-Object Id -eq 'perf.disable-sysmain').Enabled | Should -BeFalse
        ($r.Rows | Where-Object Id -eq 'perf.disable-memory-integrity').Selected | Should -BeFalse
    }

    It 'сканування з вікна: фон → вкладки «Огляд» і «Чекліст» → HTML-звіт' {
        $script:sys = Get-D9SystemInfo
        $r = Invoke-InGui {
            & $startJob 'Сканування' $scanWork @{ Catalog = $catalog; Sys = $SystemInfo; Deep = $false; ReportDir = $ReportDir } $onScanned
            $job = $state.Job
            [void]$job.Handle.AsyncWaitHandle.WaitOne(180000)
            $out = @($job.PS.EndInvoke($job.Handle))[0]
            $job.PS.Dispose(); $job.RS.Dispose(); $state.Job = $null
            if ($out.ok) { & $onScanned $out.result }
            @{ Ok = $out.ok; Error = $out.error; Score = $ui.ScoreText.Text; Findings = @($ui.FindingsList.ItemsSource).Count
               Steps = @($ui.ChecklistList.ItemsSource).Count; Report = $state.ReportPath; Progress = $sync.Progress }
        }
        $r.Ok | Should -BeTrue -Because $r.Error
        [int]$r.Score | Should -BeGreaterThan 0
        $r.Steps | Should -BeGreaterThan 0
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
        $r.Tabs | Should -Be 11
        $r.Rows[0].Selected | Should -BeTrue
        $r.Rows[0].Status | Should -Match 'файл відсутній'
        $r.Pause | Should -Not -BeNullOrEmpty
        $r.Drivers | Should -Match 'Windows'
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
            # Loaded запускає фонову перевірку стану й таймер — зупиняємо, щоб вони не перезаповнили таблицю й не тримали Close()
            $timer.Stop()
            if ($state.Job) { try { $state.Job.PS.Stop() } catch { }; $state.Job.PS.Dispose(); $state.Job.RS.Dispose(); $state.Job = $null }
            $ui.Tabs.SelectedIndex = 2; Pump
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
