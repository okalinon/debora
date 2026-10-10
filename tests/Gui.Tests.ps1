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

Describe 'Вікно' {
    It 'розмітка завантажується, усі елементи знайдено, шапка заповнена' {
        $r = Invoke-InGui { @{ Title = $ui.TitleText.Text; Line = $ui.SystemLine.Text; Presets = $ui.PresetBox.Items.Count; Preset = $ui.PresetBox.SelectedItem } }
        $r.Title | Should -Match '^Debloater9'
        $r.Line | Should -Match 'Test'
        $r.Presets | Should -Be @($catalog.Presets).Count
        $r.Preset | Should -Be 'Стандартний'
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
        $r.Tabs | Should -Be 7
        $r.Rows[0].Selected | Should -BeTrue
        $r.Rows[0].Status | Should -Match 'файл відсутній'
        $r.Pause | Should -Not -BeNullOrEmpty
        $r.Drivers | Should -Match 'Windows'
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
