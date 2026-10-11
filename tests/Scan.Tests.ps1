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

Describe 'Перелік файлів у знахідках про місце' {
    BeforeAll {
        $script:dir = Join-Path $TestDrive 'space'
        New-Item -ItemType Directory -Path (Join-Path $dir 'sub') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $dir 'big.iso'), (New-Object byte[] 3000))
        [IO.File]::WriteAllBytes((Join-Path $dir 'small.zip'), (New-Object byte[] 100))
        [IO.File]::WriteAllBytes((Join-Path $dir 'sub\inner.bin'), (New-Object byte[] 500))
    }
    It 'файл і папка стають елементами з розміром, датою й типом' {
        $f = Get-D9FileItem (Get-Item (Join-Path $dir 'big.iso'))
        $f.bytes | Should -Be 3000; $f.kind | Should -Be 'file'; ([datetime]$f.date).Year | Should -BeGreaterThan 2000
        $d = Get-D9FolderItem (Join-Path $dir 'sub')
        $d.bytes | Should -Be 500; $d.kind | Should -Be 'folder'; $d.path | Should -Be (Join-Path $dir 'sub')
        Get-D9FolderItem (Join-Path $dir 'немає') | Should -BeNullOrEmpty
    }
    It 'знахідка сортує елементи за розміром і зберігає їх у data.items' {
        $check = [pscustomobject]@{ id = 'clean.x'; category = 'cleanliness'; thresholds = @{ warningGB = 1; suggestionGB = 0.000001 } }
        $items = @(Get-D9FileItem (Get-ChildItem $dir -File)) + @(Get-D9FolderItem (Join-Path $dir 'sub'))
        $fi = New-D9SpaceFinding $check 3600 'Місце: {size}' 'd' @{ type = 'manual' } -Items $items
        $fi.severity | Should -Be 'suggestion'
        @($fi.data.items).Count | Should -Be 3
        $fi.data.items[0].path | Should -BeLike '*big.iso'
        $fi.data.items[2].path | Should -BeLike '*small.zip'
    }
    It 'без елементів — порожній перелік, а не помилка' {
        $check = [pscustomobject]@{ id = 'clean.x'; category = 'cleanliness'; thresholds = @{ warningGB = 1; suggestionGB = 0.000001 } }
        $fi = New-D9SpaceFinding $check 3600 'Місце: {size}' 'd' @{ type = 'manual' }
        @($fi.data.items).Count | Should -Be 0
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

Describe 'Пояснення оцінки категорії' {
    It 'розклад штрафів, відомості без штрафу, нуль як межа' {
        $fs = @(
            [pscustomobject]@{ category = 'stability'; severity = 'warning' }, [pscustomobject]@{ category = 'stability'; severity = 'warning' },
            [pscustomobject]@{ category = 'stability'; severity = 'suggestion' }, [pscustomobject]@{ category = 'stability'; severity = 'info' },
            [pscustomobject]@{ category = 'disk'; severity = 'critical' }
        )
        Get-D9FindingPenalty $fs[0] | Should -Be 10
        Get-D9FindingPenalty $fs[3] | Should -Be 0
        $t = Format-D9CategoryScoreExplain $fs 'stability'
        $t | Should -Match '^100 − 23 = 77: попереджень: 2 × 10, порад: 1 × 3\.'
        $t | Should -Match 'лише відомості'
        Format-D9CategoryScoreExplain $fs 'privacy' | Should -Match '100 балів'
        $many = @(1..4 | ForEach-Object { [pscustomobject]@{ category = 'disk'; severity = 'critical' } })
        Format-D9CategoryScoreExplain $many 'disk' | Should -Match '100 − 120 = 0.*нижчою за 0'
        (Get-D9ScanScore -Categories @([pscustomobject]@{ id = 'stability'; weight = 1 }) -Findings $fs -CheckedCategories 'stability').categories.stability | Should -Be 77
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

Describe 'Автоматичні виправлення' {
    BeforeAll {
        $script:fixKey = "HKCU:\Software\Debloater9Test\fix-$([guid]::NewGuid().ToString('N'))"
        New-Item $fixKey -Force | Out-Null
        Set-ItemProperty $fixKey -Name Remote -Value 1 -Type DWord
        $regFix = @{ type = 'actions'; actions = @([pscustomobject]@{ type = 'registry'; path = $fixKey; name = 'Remote'; value = 0; kind = 'DWord' }) }
        $script:fixFindings = @(
            (New-TestFinding 'sec.remote-assistance' 'security' 'suggestion' $regFix)
            (New-TestFinding 'perf.print-spooler' 'performance' 'suggestion' @{ type = 'actions'; actions = @([pscustomobject]@{ type = 'service'; name = 'Spooler'; startup = 'Manual'; stop = $true }) })
            (New-TestFinding 'sec.defender-detections' 'security' 'warning' @{ type = 'maintenance'; action = 'defenderScan' })
            (New-TestFinding 'upd.failures' 'updates' 'warning' @{ type = 'maintenance'; action = 'wuReset' })
            (New-TestFinding 'upd.last-update' 'updates' 'warning' @{ type = 'maintenance'; action = 'windowsUpdate' })
            (New-TestFinding 'stab.disk-errors' 'disk' 'critical' @{ type = 'maintenance'; action = 'chkdskScan' })
            (New-TestFinding 'sec.risky-software' 'security' 'warning' @{ type = 'apps'; ids = @('7zip.7zip') } 'sec.risky-software:7-Zip')
            (New-TestFinding 'sec.risky-software' 'security' 'warning' @{ type = 'apps'; ids = @('VideoLAN.VLC') } 'sec.risky-software:VLC')
            (New-TestFinding 'clean.browser-cache' 'cleanliness' 'suggestion' @{ type = 'maintenance'; action = 'browserCache' })
        )
        $script:fixList = New-D9Checklist -Scan (New-TestScan $fixFindings) -Catalog $catalog
    }
    AfterAll { Remove-Item 'HKCU:\Software\Debloater9Test' -Recurse -Force -ErrorAction SilentlyContinue }

    It 'дії в checks.json мають правильний формат, дії обслуговування існують' {
        $types = @('registry', 'service', 'appx', 'scheduledTask', 'powercfg', 'command', 'driver')
        foreach ($c in $scanConfig.Checks.checks | Where-Object { $_.params.fix }) {
            $fix = $c.params.fix
            switch ($fix.type) {
                'maintenance' { $script:D9MaintenanceActions.Keys + 'restorePoint', 'reboot' | Should -Contain $fix.action -Because $c.id }
                'actions' {
                    @($fix.actions).Count | Should -BeGreaterThan 0 -Because $c.id
                    foreach ($a in $fix.actions) {
                        $a.type | Should -BeIn $types -Because $c.id
                        if ($a.type -eq 'registry') {
                            $a.path | Should -Match '^(HKLM|HKCU):\\' -Because $c.id
                            ($a.delete -or ($null -ne $a.value -and $a.kind)) | Should -BeTrue -Because "$($c.id): значення або delete"
                        }
                        if ($a.type -eq 'service') { $a.startup | Should -BeIn @('Disabled', 'Manual', 'Automatic', 'AutomaticDelayed') -Because $c.id }
                    }
                }
                'tweaks' { }
                default { throw "$($c.id): невідомий тип виправлення $($fix.type)" }
            }
        }
    }
    It 'правил із готовим автоматичним виправленням — щонайменше 70' {
        @($scanConfig.Checks.checks | Where-Object { $_.params.fix.type -in 'actions', 'maintenance' }).Count | Should -BeGreaterOrEqual 70
    }
    It 'знахідки з діями стають автоматичними кроками за змістом' {
        $sec = $fixList.items | Where-Object { $_.id -eq '42|fix-security' }
        $sec.auto | Should -BeTrue
        @($sec.action.fixes).Count | Should -Be 1
        $sec.verify.type | Should -Be 'checks'
        ($fixList.items | Where-Object { $_.id -eq '63|fix-system' }).title | Should -Match '\(1\)'
    }
    It 'обслуговування: окремий автоматичний крок на кожну дію, у правильному порядку' {
        $apps = $fixList.items | Where-Object { $_.id -eq '71|apps' }
        $apps.action.ids | Should -Be @('7zip.7zip', 'VideoLAN.VLC')
        @($apps.verify.items).Count | Should -Be 2
        foreach ($pair in @(@('44', 'defenderScan'), @('48', 'wuReset'), @('49', 'windowsUpdate'), @('12', 'chkdskScan'), @('51', 'browserCache'))) {
            $item = $fixList.items | Where-Object { $_.id -eq "$($pair[0])|$($pair[1])" }
            $item | Should -Not -BeNullOrEmpty -Because $pair[1]
            $item.auto | Should -BeTrue
        }
        @($fixList.items | Where-Object { -not $_.auto -and $_.group -in 40, 45 }).Count | Should -Be 0 -Because 'автоматично виправне не дублюється ручним кроком'
    }
    It 'кроки після виконаної точки відновлення готові в тому ж запуску; перевірка диска від неї не залежить' {
        $list = New-D9Checklist -Scan (New-TestScan $fixFindings) -Catalog $catalog
        $rp = $list.items | Where-Object { $_.action.type -eq 'restorePoint' }
        $chk = $list.items | Where-Object { $_.id -eq '12|chkdskScan' }
        $chk.dependsOn | Should -Not -Contain $rp.id
        Test-D9ChecklistReady $list $chk | Should -BeTrue
        $later = @($list.items | Where-Object { $_.dependsOn -contains $rp.id -and $_.action.action -ne 'reboot' })
        $later.Count | Should -BeGreaterThan 0
        foreach ($i in $later) { Test-D9ChecklistReady $list $i | Should -BeFalse -Because $i.title }
        $rp.executedAt = (Get-Date).ToString('s')   # статус ще 'pending' — його ставить перевірка наприкінці
        foreach ($i in $later) { Test-D9ChecklistReady $list $i | Should -BeTrue -Because $i.title }
    }
    It 'при помилках диска — і резервна копія, і перевірка диска; потрібне перезавантаження' {
        ($fixList.items | Where-Object { $_.id -eq '10|backup' }) | Should -Not -BeNullOrEmpty
        ($fixList.items | Where-Object { $_.id -eq '90|reboot' }) | Should -Not -BeNullOrEmpty
    }
    It 'виконання кроку з діями змінює систему через рушій, і зміну можна відкотити' {
        $list = New-D9Checklist -Scan (New-TestScan @($fixFindings[0])) -Catalog $catalog
        foreach ($i in $list.items | Where-Object { $_.action.type -eq 'restorePoint' }) { $i.status = 'done' }
        $item = $list.items | Where-Object { $_.action.type -eq 'actions' }
        $ctx = [pscustomobject]@{ Catalog = $catalog; System = (New-TestSystemInfo) }
        Invoke-D9ChecklistStep -Checklist $list -Item $item -Context $ctx | Should -BeTrue
        (Get-ItemProperty $fixKey).Remote | Should -Be 0
        $item.note -match 'сесія (\S+?)(,|$)' | Should -BeTrue -Because $item.note
        $sessionId = $Matches[1]
        $report = @(Undo-D9Session -Id $sessionId)
        $report.result | Should -Be @('restored')
        (Get-ItemProperty $fixKey).Remote | Should -Be 1
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

Describe 'Універсальні правила' {
    BeforeAll {
        $script:ruleKey = "HKCU:\Software\Debloater9Test\rules-$([guid]::NewGuid().ToString('N'))"
        New-Item $ruleKey -Force | Out-Null
        function New-RuleCheck([string]$Probe, [hashtable]$Params) {
            $base = @{ severity = 'warning'; title = @{ uk = 'знайдено {value}' }; details = @{ uk = 'd' } }
            foreach ($k in $Params.Keys) { $base[$k] = $Params[$k] }
            ConvertFrom-Json (ConvertTo-Json @{ id = 'test.rule'; category = 'security'; probe = $Probe; params = $base } -Depth 6)
        }
        $script:ruleCtx = [pscustomobject]@{ Now = Get-Date }
    }
    AfterAll { Remove-Item 'HKCU:\Software\Debloater9Test' -Recurse -Force -ErrorAction SilentlyContinue }

    It 'реєстр: ne "" спрацьовує лише на непорожній рядок, відсутнє значення — норма' {
        $c = New-RuleCheck 'Test-D9RegistryRule' @{ path = $ruleKey; name = 'Pwd'; bad = @{ op = 'ne'; value = '' } }
        Test-D9RegistryRule $c $ruleCtx | Should -BeNullOrEmpty
        Set-ItemProperty $ruleKey -Name Pwd -Value ''
        Test-D9RegistryRule $c $ruleCtx | Should -BeNullOrEmpty
        Set-ItemProperty $ruleKey -Name Pwd -Value 'secret'
        (Test-D9RegistryRule $c $ruleCtx).title | Should -Be 'знайдено secret'
    }
    It 'реєстр: in і exists' {
        Set-ItemProperty $ruleKey -Name Comp -Value 255 -Type DWord
        $in = New-RuleCheck 'Test-D9RegistryRule' @{ path = $ruleKey; name = 'Comp'; bad = @{ op = 'in'; value = @(255, 4294967295) } }
        Test-D9RegistryRule $in $ruleCtx | Should -Not -BeNullOrEmpty
        $ex = New-RuleCheck 'Test-D9RegistryRule' @{ path = $ruleKey; name = 'Missing'; bad = @{ op = 'exists' } }
        Test-D9RegistryRule $ex $ruleCtx | Should -BeNullOrEmpty
    }
    It 'журнал: відсутній у системі провайдер — «подій немає», а не «журнал недоступний»' {
        $events = Get-D9Events @{ LogName = 'System'; ProviderName = 'Debora-NoSuchProvider'; Id = 1 }
        $null -eq $events | Should -BeFalse
        @($events).Count | Should -Be 0
        $c = New-RuleCheck 'Test-D9EventRule' @{ log = 'System'; providers = @('Debora-NoSuchProvider'); ids = @(1); days = 30; min = 1 }
        Test-D9EventRule $c $ruleCtx | Should -BeNullOrEmpty
    }
    It 'журнал: відсутні провайдери у списку не ламають пошук за наявними' {
        $f = @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = (Get-Date).AddDays(-30) }
        $plain = Get-D9Events $f
        $f.ProviderName = @('Service Control Manager', 'Debora-NoSuchProvider')
        @(Get-D9Events $f).Count | Should -Be @($plain).Count
    }
}

Describe 'Помилки NTFS: системний том чи флешка' {
    BeforeAll {
        function New-NtfsEvent([string]$Drive, [string]$Device = '\Device\HarddiskVolume3') {
            $xml = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><EventData><Data Name='DriveName'>$Drive</Data><Data Name='DeviceName'>$Device</Data></EventData></Event>"
            $e = [pscustomobject]@{ ProviderName = 'Ntfs'; Id = 55 }
            $e | Add-Member ScriptMethod ToXml ([scriptblock]::Create("'$($xml -replace "'", "''")'")) -PassThru
        }
        $script:vols = @{ 'C:' = $true; 'G:' = $false; '\\?\Volume{1111}' = $true; '\\?\Volume{2222}' = $false; 'FLASH' = $false }
    }
    It '<drive> → <expected>' -TestCases @(
        @{ drive = 'C:'; expected = $true }
        @{ drive = 'G:'; expected = $false }
        @{ drive = '\\?\Volume{1111}\'; expected = $true }
        @{ drive = '\\?\Volume{2222}'; expected = $false }
        @{ drive = 'FLASH'; expected = $false }
        @{ drive = 'H:'; expected = $false }          # витягнута флешка
        @{ drive = ''; expected = $true }             # невідомо — краще попередити
    ) {
        Test-D9NtfsEventOnSystem (New-NtfsEvent $drive) $vols | Should -Be $expected
    }
    It 'тіньові копії не вважаються диском' {
        Test-D9NtfsEventOnSystem (New-NtfsEvent 'C:' '\Device\HarddiskVolumeShadowCopy20') $vols | Should -BeFalse
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
