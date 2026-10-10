BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
    $script:scanConfig = Import-D9ScanConfig
    $script:categories = $scanConfig.Checks.categories
    $script:catalog = Import-D9Catalog

    function New-TestFinding([string]$CheckId, [string]$Category, [string]$Severity, $Fix, [string]$Key, $Data) {
        if ($Data -and -not $Key) { $Key = $CheckId }
        $check = [pscustomobject]@{ id = $CheckId; category = $Category }
        New-D9Finding -Check $check -Severity $Severity -Title "t-$CheckId" -Details 'd' -Fix $Fix -Key $Key -Data $Data
    }
    function New-TestScan([object[]]$Findings) {
        [pscustomobject]@{
            id = 'test'; time = (Get-Date).ToString('s'); durationSec = 1; deep = $false; admin = $false
            system = (New-TestSystemInfo); recommendation = [pscustomobject]@{ Preset = 'Standard'; Reasons = @() }
            score = (Get-D9ScanScore -Categories $categories -Findings $Findings -CheckedCategories @($categories.id))
            findings = $Findings; checks = @()
        }
    }
}

AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Конфігурація сканера' {
    It 'кожна перевірка має функцію-пробу і відому категорію' {
        foreach ($c in $scanConfig.Checks.checks) {
            Get-Command $c.probe -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $c.id
            $categories.id | Should -Contain $c.category
        }
    }
    It 'id перевірок унікальні' {
        $ids = @($scanConfig.Checks.checks.id)
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }
    It 'твіки, на які посилаються проби й правила, існують у каталозі' {
        $ids = @('perf.enable-trim', 'perf.disable-sysmain', 'perf.disable-search-index', 'perf.power-high', 'cleanup.temp', 'cleanup.update-cache',
                 'cleanup.recycle-bin', 'cleanup.leftovers', 'cleanup.do-cache', 'perf.reduced-hiberfile', 'safety.disable-guest')
        $ids += @($scanConfig.Checks.checks | ForEach-Object { $_.params.fix.ids } | Where-Object { $_ })
        foreach ($id in ($ids | Sort-Object -Unique)) { Get-D9Tweak $catalog $id | Should -Not -BeNullOrEmpty -Because $id }
    }
    It 'щонайменше 100 перевірок' {
        @($scanConfig.Checks.checks).Count | Should -BeGreaterOrEqual 100
    }
    It 'правила мають обов''язкові параметри' {
        foreach ($c in $scanConfig.Checks.checks | Where-Object probe -in 'Test-D9RegistryRule', 'Test-D9ServiceRule', 'Test-D9EventRule') {
            $c.params.severity | Should -BeIn @('critical', 'warning', 'suggestion', 'info') -Because $c.id
            $c.params.title.uk | Should -Not -BeNullOrEmpty -Because $c.id
            switch ($c.probe) {
                'Test-D9RegistryRule' { $c.params.path | Should -Match '^(HKLM|HKCU):\\' -Because $c.id; $c.params.bad.op | Should -Not -BeNullOrEmpty -Because $c.id }
                'Test-D9ServiceRule'  { $c.params.name | Should -Not -BeNullOrEmpty -Because $c.id }
                'Test-D9EventRule'    { $c.params.log | Should -Not -BeNullOrEmpty -Because $c.id; [int]$c.params.days | Should -BeGreaterThan 0 -Because $c.id }
            }
        }
    }
}

Describe 'Оцінка' {
    It 'без знахідок — 100 і добрий стан' {
        $s = Get-D9ScanScore -Categories $categories -Findings @() -CheckedCategories @($categories.id)
        $s.overall | Should -Be 100
        $s.verdict | Should -Be 'good'
    }
    It 'штрафи за рівнями' {
        $f = @((New-TestFinding 'a' 'disk' 'warning'), (New-TestFinding 'b' 'disk' 'suggestion'))
        $s = Get-D9ScanScore -Categories $categories -Findings $f -CheckedCategories @('disk')
        $s.categories.disk | Should -Be 87
    }
    It 'критична знахідка обмежує загальну оцінку 59' {
        $f = @(New-TestFinding 'a' 'battery' 'critical')
        $s = Get-D9ScanScore -Categories $categories -Findings $f -CheckedCategories @($categories.id)
        $s.overall | Should -BeLessOrEqual 59
        $s.verdict | Should -Be 'serious'
    }
    It 'неперевірені категорії не враховуються' {
        $s = Get-D9ScanScore -Categories $categories -Findings @() -CheckedCategories @('disk')
        @($s.categories.Keys) | Should -Be @('disk')
    }
}

Describe 'Підтримка версії Windows' {
    BeforeAll {
        $script:check = $scanConfig.Checks.checks | Where-Object id -eq 'sec.windows-support'
        function Get-Ctx($Build, $Now) {
            $sys = New-TestSystemInfo; $sys.Build = $Build; $sys.OsName = 'Windows'
            [pscustomobject]@{ System = $sys; Now = [datetime]$Now; Lifecycle = $scanConfig.Lifecycle }
        }
    }
    It 'Windows 10 22H2 після 14.10.2025 — критично' {
        (Test-D9WindowsSupport $check (Get-Ctx 19045 '2026-10-10')).severity | Should -Be 'critical'
    }
    It 'Windows 11 24H2 за 42 дні до кінця — попередження' {
        (Test-D9WindowsSupport $check (Get-Ctx 26100 '2026-09-01')).severity | Should -Be 'warning'
    }
    It 'Windows 11 25H2 у 2026 — без знахідок' {
        Test-D9WindowsSupport $check (Get-Ctx 26200 '2026-10-10') | Should -BeNullOrEmpty
    }
    It 'невідома збірка — пропуск, а не помилка' {
        (Test-D9WindowsSupport $check (Get-Ctx 12345 '2026-10-10')).severity | Should -Be 'skipped'
    }
}

Describe 'Чекліст' {
    BeforeAll {
        $script:findings = @(
            (New-TestFinding 'perf.memory' 'performance' 'warning' @{ type = 'manual' })
            (New-TestFinding 'upd.problem-devices' 'updates' 'warning' @{ type = 'drivers' } 'dev:touch' ([pscustomobject]@{ name = 'Тачпад'; class = 'HIDClass'; hwid = 'HID\X' }))
            (New-TestFinding 'upd.problem-devices' 'updates' 'warning' @{ type = 'drivers' } 'dev:wifi' ([pscustomobject]@{ name = 'Wi-Fi'; class = 'Net'; hwid = 'PCI\VEN_168C&DEV_0042' }))
            (New-TestFinding 'upd.problem-devices' 'updates' 'warning' @{ type = 'drivers' } 'dev:serial' ([pscustomobject]@{ name = 'Serial IO'; class = 'System'; hwid = 'ACPI\ENEE3000' }))
            (New-TestFinding 'clean.temp' 'cleanliness' 'warning' @{ type = 'tweaks'; ids = @('cleanup.temp') } -Data ([pscustomobject]@{ bytes = 3GB }))
            (New-TestFinding 'clean.update-cache' 'cleanliness' 'suggestion' @{ type = 'tweaks'; ids = @('cleanup.update-cache') } -Data ([pscustomobject]@{ bytes = 1GB }))
            (New-TestFinding 'sec.smb1-client' 'security' 'warning' @{ type = 'tweaks'; ids = @('safety.disable-smb1') })
            (New-TestFinding 'clean.windows-old' 'cleanliness' 'suggestion' @{ type = 'manual' })
            (New-TestFinding 'privacy.profile-tweaks' 'privacy' 'suggestion' @{ type = 'tweaks'; ids = @('privacy.telemetry', 'privacy.ads-tips') })
            (New-TestFinding 'upd.pending-reboot' 'updates' 'warning' @{ type = 'maintenance'; action = 'reboot' })
            (New-TestFinding 'disk.health' 'disk' 'critical' @{ type = 'manual' })
            (New-TestFinding 'bat.wear' 'battery' 'warning' @{ type = 'manual' })
        )
        $script:list = New-D9Checklist -Scan (New-TestScan $findings) -Catalog $catalog
        function Get-Step($Pattern) { $list.items | Where-Object title -like $Pattern | Select-Object -First 1 }
    }

    It 'резервна копія — перший крок при проблемах з диском' {
        $list.items[0].title | Should -BeLike '*Скопіювати важливі файли*'
    }
    It 'точка відновлення раніше за автоматичні зміни' {
        (Get-Step 'Створити точку*').number | Should -BeLessThan (Get-Step 'Вимкнути телеметрію*').number
    }
    It 'драйвер мережі — перед іншими драйверами, а решта залежить від нього' {
        $wifi = Get-Step '*Wi-Fi'; $serial = Get-Step '*Serial IO'; $touch = Get-Step '*Тачпад'
        $wifi.number | Should -BeLessThan $serial.number
        $serial.number | Should -BeLessThan $touch.number
        $touch.dependsOn | Should -Contain $wifi.id
    }
    It 'автоматичні кроки залежать від точки відновлення' {
        (Get-Step 'Вимкнути телеметрію*').dependsOn | Should -Contain (Get-Step 'Створити точку*').id
    }
    It 'одне перезавантаження, після всіх автоматичних кроків' {
        @($list.items | Where-Object { $_.action.action -eq 'reboot' }).Count | Should -Be 1
        $reboot = Get-Step 'Перезавантажити*'
        @($list.items | Where-Object { $_.auto -and $_.number -gt $reboot.number }).Count | Should -Be 0
    }
    It 'ручні кроки без автоматичної дії йдуть після автоматичних налаштувань' {
        (Get-Step 't-bat.wear').group | Should -Be 80
        (Get-Step 't-bat.wear').auto | Should -BeFalse
    }
    It 'очищення — один автоматичний крок із сумою місця' {
        $c = Get-Step 'Очистити диск*'
        $c.title | Should -Match '4,0 ГБ'
        @($c.action.ids) | Should -Be @('cleanup.temp', 'cleanup.update-cache')
    }
    It 'ручне очищення — окремий крок' {
        (Get-Step 't-clean.windows-old').group | Should -Be 52
    }
    It 'твіки безпеки — окремий автоматичний крок' {
        (Get-Step 'Посилити захист*').action.ids | Should -Contain 'safety.disable-smb1'
    }
    It 'номери кроків ідуть підряд' {
        @($list.items.number) | Should -Be @(1..@($list.items).Count)
    }
    It 'статус переноситься в новий чекліст за id кроку' {
        $old = New-D9Checklist -Scan (New-TestScan $findings) -Catalog $catalog
        ($old.items | Where-Object { $_.title -like '*Wi-Fi' }).status = 'done'
        $merged = Merge-D9ChecklistState -New (New-D9Checklist -Scan (New-TestScan $findings) -Catalog $catalog) -Old $old
        ($merged.items | Where-Object { $_.title -like '*Wi-Fi' }).status | Should -Be 'done'
    }
    It 'зберігається і читається з диска' {
        Save-D9Checklist $list
        (Get-D9Checklist).items.Count | Should -Be @($list.items).Count
    }
}

Describe 'Автоматичні галочки' {
    BeforeAll {
        $script:testRoot = "HKCU:\Software\Debloater9Test\$([guid]::NewGuid().ToString('N'))"
        $script:tweak = [pscustomobject]@{
            id = 'ui.test-check'; category = 'ui'; risk = 'safe'
            name = [pscustomobject]@{ uk = 'т'; en = 't' }; description = [pscustomobject]@{ uk = 'т'; en = 't' }
            actions = @([pscustomobject]@{ type = 'registry'; path = $testRoot; name = 'V'; value = 1; kind = 'DWord' })
        }
        $script:ctx = [pscustomobject]@{ Catalog = [pscustomobject]@{ Tweaks = @($tweak); Presets = @() }; System = (New-TestSystemInfo) }
    }
    AfterAll { Remove-Item 'HKCU:\Software\Debloater9Test' -Recurse -Force -ErrorAction SilentlyContinue }

    It 'крок із твіками відмічається, коли твіки застосовано' {
        $list = [pscustomobject]@{ created = (Get-Date).ToString('s'); items = @(
            (New-D9ChecklistItem 60 'x' 'Твік' '' @() @{ type = 'tweaks'; ids = @('ui.test-check') } @{ type = 'tweaks'; ids = @('ui.test-check') })
        ) }
        (Update-D9ChecklistStatus $list $ctx).items[0].status | Should -Be 'pending'
        Invoke-D9Registry $tweak.actions[0]
        (Update-D9ChecklistStatus $list $ctx).items[0].status | Should -Be 'done'
    }
    It 'крок типу executed відмічається після виконання' {
        $item = New-D9ChecklistItem 50 'c' 'Очистити' '' @() @{ type = 'tweaks'; ids = @() } @{ type = 'executed' }
        $list = [pscustomobject]@{ created = (Get-Date).ToString('s'); items = @($item) }
        (Update-D9ChecklistStatus $list $ctx).items[0].status | Should -Be 'pending'
        $item.executedAt = (Get-Date).ToString('s')
        (Update-D9ChecklistStatus $list $ctx).items[0].status | Should -Be 'done'
    }
}

Describe 'HTML-звіт' {
    It 'містить оцінку, чекліст і екранує HTML' {
        $f = @(New-TestFinding 'perf.memory' 'performance' 'warning' @{ type = 'manual' })
        $f[0].title = 'Програма <script>alert(1)</script>'
        $scan = New-TestScan $f
        $html = ConvertTo-D9ScanHtml -Scan $scan -Checklist (New-D9Checklist -Scan $scan -Catalog $catalog) -Categories $categories
        $html | Should -Match '<!doctype html>'
        $html | Should -Match 'Чекліст'
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;'
    }
    It 'посилання http стають клікабельними, системні — підказкою' {
        (ConvertTo-D9LinkHtml ([pscustomobject]@{ label = 'Сайт'; url = 'https://example.com' })) | Should -Match '<a href="https://example.com"'
        (ConvertTo-D9LinkHtml ([pscustomobject]@{ label = 'Параметри'; url = 'ms-settings:startupapps' })) | Should -Not -Match '<a '
    }
}

Describe 'Сканування реальної системи' {
    BeforeAll {
        $script:sys = Get-D9SystemInfo
        $script:result = Invoke-D9Scan -Context (New-D9ScanContext -Catalog $catalog -SystemInfo $sys -ScanConfig $scanConfig)
    }
    It 'завершується без помилок проб' {
        $errors = @($result.checks | Where-Object status -eq 'error')
        ($errors | ForEach-Object { "$($_.id): $($_.note)" }) -join "`n" | Should -BeNullOrEmpty
    }
    It 'виконує всі звичайні перевірки' {
        @($result.checks | Where-Object { $_.status -in 'ok', 'found', 'skipped', 'notApplicable' }).Count | Should -BeGreaterOrEqual 90
    }
    It 'вкладається в 90 секунд' {
        $result.durationSec | Should -BeLessThan 90
    }
    It 'кожна знахідка має заголовок і відомий рівень' {
        foreach ($f in $result.findings) {
            $f.title | Should -Not -BeNullOrEmpty
            $f.severity | Should -BeIn @('critical', 'warning', 'suggestion', 'info')
        }
    }
    It 'з результату будується чекліст і HTML' {
        $list = New-D9Checklist -Scan $result -Catalog $catalog
        ConvertTo-D9ScanHtml -Scan $result -Checklist $list -Categories $categories | Should -Match '</html>'
    }
}
