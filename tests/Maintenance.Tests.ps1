BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
    $script:testRoot = "HKCU:\Software\DeboraTest\$([guid]::NewGuid().ToString('N'))"
}
AfterAll {
    Remove-Item 'HKCU:\Software\DeboraTest' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue
}

Describe 'Залишки Debora' {
    BeforeAll { $script:realRoot = $env:SystemRoot }
    AfterAll { $env:SystemRoot = $realRoot }
    It 'знаходить завантажені драйвери й кеші оновлень, старші за тиждень, і видаляє їх' {
        $win = Join-Path $TestDrive 'win'
        $env:SystemRoot = $win
        $old = (Get-Date).AddDays(-10).ToString('yyyyMMdd')
        $new = (Get-Date).AddDays(-2).ToString('yyyyMMdd')
        New-Item -ItemType Directory "$win\SoftwareDistribution.d9-$old-010120\Download", "$win\System32\catroot2.d9-$old-010120", "$win\SoftwareDistribution.d9-$new-010120" -Force | Out-Null
        New-Item -ItemType Directory (Join-Path $env:D9_DATA_ROOT 'driver-downloads\NVIDIA (1.0) a10da5a1') -Force | Out-Null
        Set-Content (Join-Path $env:D9_DATA_ROOT 'driver-downloads\NVIDIA (1.0) a10da5a1\x.cab') 'abc'
        $found = @(Get-D9DeboraLeftovers)
        $found.Count | Should -Be 3
        $found | Where-Object { $_ -like "*$new*" } | Should -BeNullOrEmpty
        Clear-D9DeboraLeftovers | Should -BeGreaterThan 0
        @(Get-D9DeboraLeftovers).Count | Should -Be 0
        Test-Path "$win\SoftwareDistribution.d9-$new-010120" | Should -BeTrue
    }
}

Describe 'Розбір команди автозапуску' {
    It '<cmd> → <exe>' -TestCases @(
        @{ cmd = '"C:\Program Files\App\app.exe" --minimized'; exe = 'C:\Program Files\App\app.exe' }
        @{ cmd = 'C:\Tools\tool.exe /background'; exe = 'C:\Tools\tool.exe' }
        @{ cmd = 'C:\Program Files\Steam\steam.exe -silent'; exe = 'C:\Program Files\Steam\steam.exe' }
        @{ cmd = 'rundll32.exe shell32.dll,Control_RunDLL'; exe = 'rundll32.exe' }
    ) {
        param($cmd, $exe)
        Get-D9CommandExe $cmd | Should -Be $exe
    }
    It 'розгортає змінні середовища' {
        Get-D9CommandExe '"%SystemRoot%\system32\notepad.exe"' | Should -Be "$env:SystemRoot\system32\notepad.exe"
    }
}

Describe 'Автозавантаження' {
    It 'список читається на цьому ПК' {
        $items = @(Get-D9StartupItems)
        foreach ($i in $items) {
            $i.Name | Should -Not -BeNullOrEmpty
            $i.Kind | Should -BeIn @('reg', 'task')
            if ($i.Kind -eq 'reg') { $i.ApprovedPath | Should -Match 'StartupApproved' }
        }
    }
    It 'вимкнення запису реєстру — як у Диспетчері завдань (03…)' {
        $a = New-D9StartupAction ([pscustomobject]@{ Kind = 'reg'; ApprovedPath = 'HKCU:\X\StartupApproved\Run'; ValueName = 'App' }) $false
        $a.type | Should -Be 'registry'
        $a.kind | Should -Be 'Binary'
        $a.value[0] | Should -Be 3
        $a.value.Count | Should -Be 12
    }
    It 'вимкнення завдання — дія scheduledTask' {
        $a = New-D9StartupAction ([pscustomobject]@{ Kind = 'task'; ValueName = '\Vendor\Updater' }) $false
        $a.type | Should -Be 'scheduledTask'
        $a.state | Should -Be 'Disabled'
    }
    It 'вимкнення через рушій журналюється й повністю відкочується' {
        $item = [pscustomobject]@{ Kind = 'reg'; Name = 'TestApp'; Command = 'test.exe'; ApprovedPath = "$testRoot\StartupApproved\Run"; ValueName = 'TestApp' }
        $cat = New-D9StartupCatalog -Changes @(@{ Item = $item; Enable = $false })
        $plan = New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo (New-TestSystemInfo)
        $session = Invoke-D9Plan -Plan $plan -SystemInfo (New-TestSystemInfo) -NoRestorePoint
        $session.entries[0].result | Should -Be 'ok'
        ([byte[]](Get-ItemProperty "$testRoot\StartupApproved\Run").TestApp)[0] | Should -Be 3
        Undo-D9Session -Id $session.id | Out-Null
        Test-Path "$testRoot\StartupApproved" | Should -BeFalse
    }
}

Describe 'Пауза оновлень' {
    It 'шість значень з датою кінця через N днів' {
        $now = [datetime]'2026-10-10T12:00:00'
        $cat = New-D9PauseUpdatesCatalog -Days 14 -Now $now
        $actions = $cat.Tweaks[0].actions
        @($actions).Count | Should -Be 6
        ($actions | Where-Object name -eq 'PauseUpdatesExpiryTime').value | Should -Be $now.AddDays(14).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        Test-D9Catalog $cat | Should -BeNullOrEmpty
    }
    It 'більше 35 днів не дозволено' {
        { New-D9PauseUpdatesCatalog -Days 60 } | Should -Throw
    }
    It 'відновлення видаляє ті самі значення' {
        $r = (New-D9ResumeUpdatesCatalog).Tweaks[0].actions
        @($r | Where-Object delete).Count | Should -Be 6
    }
}

Describe 'Драйвери без Windows Update' {
    It 'твік є в каталозі й лише в профілі «Максимальний»' {
        $cat = Import-D9Catalog
        Get-D9Tweak $cat 'updates.no-wu-drivers' | Should -Not -BeNullOrEmpty
        $with = @($cat.Presets | Where-Object { $_.tweaks -contains 'updates.no-wu-drivers' }).id
        $with | Should -Be @('Maximum')
    }
}

Describe 'Пакет діагностики' {
    BeforeAll {
        $sessions = Join-Path $env:D9_DATA_ROOT 'sessions'
        New-Item -ItemType Directory -Path $sessions -Force | Out-Null
        Set-Content (Join-Path $sessions 'test-session.json') '{"id":"test"}'
        $script:diagOut = Join-Path $TestDrive 'diag'
        $script:zip = New-D9DiagnosticsBundle -SystemInfo (New-TestSystemInfo) -OutDir $diagOut
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        $script:entries = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
        $archive.Dispose()
    }
    It 'створює один zip у вказаній папці' {
        @(Get-ChildItem $diagOut -Filter '*.zip').Count | Should -Be 1
        $zip | Should -BeLike '*.zip'
    }
    It 'містить основні розділи і файли програми' {
        foreach ($name in 'system.txt', 'disks.txt', 'devices.txt', 'drivers.txt', 'events-system.txt', 'README.txt', 'sessions/test-session.json') {
            $entries | Should -Contain $name
        }
    }
    It 'не лишає тимчасової папки' {
        @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'd9diag-*' | Where-Object LastWriteTime -gt (Get-Date).AddMinutes(-5)).Count | Should -Be 0
    }
}

Describe 'Стан дисків' {
    BeforeAll {
        function New-TestDisk {
            param([hashtable]$Set = @{})
            $d = [pscustomobject]@{
                Number = 0; Model = 'Test SSD'; Media = 'SSD'; Bus = 'NVMe'; Removable = $false; SizeBytes = 512GB; Letters = @('C:'); IsSystem = $true
                Firmware = '1.0'; HealthStatus = 0; HasCounters = $true; Temperature = 40; TemperatureMax = 70; Wear = 3; PowerOnHours = 8760
                ReadErrorsUncorrected = 0; WriteErrorsUncorrected = 0; StartStopCycles = 500; PredictFailure = $false; CountersAvailable = $true
            }
            foreach ($k in $Set.Keys) { $d.$k = $Set[$k] }
            $d
        }
    }
    It 'справний диск — ok без проблем' {
        $v = Get-D9DiskVerdict (New-TestDisk)
        $v.Level | Should -Be 'ok'
        $v.Problems.Count | Should -Be 0
    }
    It '<name> → <level>' -TestCases @(
        @{ name = 'Windows: несправний'; set = @{ HealthStatus = 2 }; level = 'bad' }
        @{ name = 'прогноз відмови SMART'; set = @{ PredictFailure = $true }; level = 'bad' }
        @{ name = 'невиправні помилки читання'; set = @{ ReadErrorsUncorrected = 3 }; level = 'bad' }
        @{ name = 'ресурс вичерпано'; set = @{ Wear = 100 }; level = 'bad' }
        @{ name = 'знос 85%'; set = @{ Wear = 85 }; level = 'warn' }
        @{ name = 'гарячий'; set = @{ Temperature = 65 }; level = 'warn' }
        @{ name = 'Windows: попередження'; set = @{ HealthStatus = 1 }; level = 'warn' }
        @{ name = 'без лічильників і стану'; set = @{ HealthStatus = 5; HasCounters = $false; Temperature = $null; Wear = $null }; level = 'unknown' }
    ) {
        param($name, $set, $level)
        (Get-D9DiskVerdict (New-TestDisk $set)).Level | Should -Be $level
    }
    It 'заголовок і подробиці читабельні' {
        $d = New-TestDisk
        Format-D9DiskTitle $d | Should -Be "Диск 0 · Test SSD · NVMe SSD · $(Format-D9Size 512GB) · C: (системний)"
        $t = Format-D9DiskDetails $d
        $t | Should -Match 'температура 40 °C \(макс. 70 °C\)'
        $t | Should -Match 'знос 3%'
        $t | Should -Match 'напрацювання 8760 год'
    }
    It 'без прав адміністратора підказує, як побачити SMART' {
        Format-D9DiskDetails (New-TestDisk @{ HasCounters = $false; CountersAvailable = $false; Temperature = $null; Wear = $null; PowerOnHours = $null }) | Should -Match 'від адміністратора'
    }
    It 'читає диски цього ПК' {
        $disks = @(Get-D9DiskHealth)
        $disks.Count | Should -BeGreaterThan 0
        @($disks | Where-Object IsSystem).Count | Should -Be 1
        foreach ($d in $disks) { (Get-D9DiskVerdict $d).Level | Should -BeIn 'ok', 'warn', 'bad', 'unknown' }
    }
    It 'сканер: несправний внутрішній диск — критично, флешку не оцінює' {
        Mock Get-D9DiskHealth { @(
            (New-TestDisk @{ HealthStatus = 2 })
            (New-TestDisk @{ Number = 1; Model = 'Flash'; Removable = $true; HealthStatus = 2; Letters = @('G:'); IsSystem = $false })
        ) }
        $check = [pscustomobject]@{ id = 'disk.health'; thresholds = [pscustomobject]@{ wearPercent = 80; tempC = 60 } }
        $f = @(Test-D9DiskHealth $check @{ IsAdmin = $true })
        $f.Count | Should -Be 1
        $f[0].severity | Should -Be 'critical'
        $f[0].title | Should -Match 'Test SSD'
    }
    It 'сканер: перегрів — попередження з порадою про охолодження' {
        Mock Get-D9DiskHealth { @(New-TestDisk @{ Temperature = 70 }) }
        $check = [pscustomobject]@{ id = 'disk.health'; thresholds = [pscustomobject]@{ wearPercent = 80; tempC = 60 } }
        $f = @(Test-D9DiskHealth $check @{ IsAdmin = $true })
        $f[0].severity | Should -Be 'warning'
        $f[0].details | Should -Match 'охолодження'
    }
}

Describe 'Кеш значків' {
    It 'знаходить лише файли кешу Провідника' {
        $root = Join-Path $TestDrive 'local'
        $exp = Join-Path $root 'Microsoft\Windows\Explorer'
        New-Item -ItemType Directory -Path $exp -Force | Out-Null
        foreach ($n in 'iconcache_32.db', 'thumbcache_256.db', 'ExplorerStartupLog.etl', 'other.db') { Set-Content (Join-Path $exp $n) 'x' }
        Set-Content (Join-Path $root 'IconCache.db') 'x'
        $names = @(Get-D9IconCacheFiles -LocalAppData $root | ForEach-Object Name | Sort-Object)
        $names | Should -Be @('IconCache.db', 'iconcache_32.db', 'thumbcache_256.db')
    }
}

Describe 'Оцінка тривалості за фактом минулого разу' {
    It 'округлення: хвилини, по 5, по 10, години' {
        Format-D9ApproxDuration ([TimeSpan]::FromSeconds(20)) | Should -Be 'менше хвилини'
        Format-D9ApproxDuration ([TimeSpan]::FromMinutes(7.4)) | Should -Be '7 хв'
        Format-D9ApproxDuration ([TimeSpan]::FromMinutes(13)) | Should -Be '15 хв'
        Format-D9ApproxDuration ([TimeSpan]::FromMinutes(63)) | Should -Be '60 хв'
        Format-D9ApproxDuration ([TimeSpan]::FromMinutes(95)) | Should -Be '1 год 40 хв'
        Format-D9ApproxDuration ([TimeSpan]::FromMinutes(118)) | Should -Be '2 год'
    }
    It 'Захисник: є минула перевірка — «минулого разу ≈ 60 хв» і довше очікування; немає — «до 20 хвилин»' {
        $script:lines = @()
        $script:D9OnLog = { param($Message, $Level) $script:lines += $Message }
        Mock Get-MpComputerStatus { [pscustomobject]@{ QuickScanStartTime = [datetime]'2026-10-10T23:58:14'; QuickScanEndTime = [datetime]'2026-10-11T01:01:19' } }
        Mock Start-MpScan { throw 'stop here' }
        [void](Invoke-D9DefenderScan)
        $script:lines[0] | Should -Match '≈ 60 хв'
        Mock Get-MpComputerStatus { throw 'no defender' }
        $script:lines = @()
        [void](Invoke-D9DefenderScan)
        $script:lines[0] | Should -Match 'до 20 хвилин'
        $script:D9OnLog = { param($Message, $Level) }
    }
}
