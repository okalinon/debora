# Глибокий аналіз сканера: сині екрани, збої програм, повільне завантаження, служби, нові дії обслуговування.
BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    function New-FakeEvent {
        param([int]$Id = 1001, [object[]]$Values = @(), [datetime]$Time = (Get-Date), [hashtable]$Data = @{})
        $e = [pscustomobject]@{ Id = $Id; TimeCreated = $Time; Properties = @($Values | ForEach-Object { [pscustomobject]@{ Value = $_ } }) }
        $xml = '<Event><EventData>' + (($Data.Keys | ForEach-Object { "<Data Name=`"$_`">$($Data[$_])</Data>" }) -join '') + '</EventData></Event>'
        $e | Add-Member -MemberType NoteProperty -Name Xml -Value $xml
        $e | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }
        $e
    }
    $script:checks = (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).checks
    function Get-TestCheck([string]$Id) { $checks | Where-Object id -eq $Id }
}

Describe 'Коди синіх екранів' {
    It '<text> → <key>' -TestCases @(
        @{ text = '0x000000d1 (0xffffc001c15c5010, 0x5, 0x0, 0xfffff8027b1e72fb)'; key = 'D1' }
        @{ text = '0x0000000a (0x0, 0x2, 0x0, 0x0)'; key = 'A' }
        @{ text = '0xc000021a (0x0)'; key = 'C000021A' }
        @{ text = '0x00000124 (0x0)'; key = '124' }
    ) {
        param($text, $key)
        ConvertTo-D9BugcheckKey $text | Should -Be $key
    }
    It 'кожен код має відому групу, кожна група — дію, яка існує' {
        $cat = Get-D9BugcheckCatalog
        foreach ($p in $cat.codes.PSObject.Properties) { $cat.classes.($p.Value.class) | Should -Not -BeNullOrEmpty -Because $p.Name }
        foreach ($c in $cat.classes.PSObject.Properties) {
            if ($c.Value.fix -ne 'manual') { $script:D9MaintenanceActions.Contains($c.Value.fix) | Should -BeTrue -Because $c.Name }
        }
    }
    It 'невідомий код — як драйвер, з назвою-кодом' {
        $i = Get-D9BugcheckInfo 'ABCDE'
        $i.Class | Should -Be 'driver'
        $i.Name | Should -Be '0xABCDE'
    }
    It 'один код → пояснення й виправлення за групою' {
        Mock Get-D9EventCount { param($Filter) if ($Filter.Id -eq 1001) { @(1..2 | ForEach-Object { New-FakeEvent 1001 @('0x00000116 (0x0)') }) } else { @() } }
        $f = Test-D9Crashes (Get-TestCheck 'stab.crashes') @{ Now = Get-Date }
        $f.title | Should -Match 'VIDEO_TDR_FAILURE ×2'
        $f.fix.action | Should -Be 'driverUpdate'
        $f.details | Should -Match 'відеодрайвера'
    }
    It 'різні коди з різних груп → перевірка пам''яті' {
        Mock Get-D9EventCount { param($Filter) if ($Filter.Id -eq 1001) { @('0x1a (0)', '0xd1 (0)', '0x7a (0)') | ForEach-Object { New-FakeEvent 1001 @($_) } } else { @() } }
        $f = Test-D9Crashes (Get-TestCheck 'stab.crashes') @{ Now = Get-Date }
        $f.severity | Should -Be 'critical'
        $f.fix.action | Should -Be 'memoryTest'
    }
}

Describe 'Збої програм' {
    It '<module> → <class>' -TestCases @(
        @{ module = 'nvwgf2umx.dll'; class = 'gpu' }
        @{ module = 'atiumd64.dll'; class = 'gpu' }
        @{ module = 'igd12umd64.dll'; class = 'gpu' }
        @{ module = 'MSVCP140.dll'; class = 'vcrt' }
        @{ module = 'VCRUNTIME140_1.dll'; class = 'vcrt' }
        @{ module = 'coreclr.dll'; class = 'dotnet' }
        @{ module = 'KERNELBASE.dll'; class = $null }
    ) {
        param($module, $class)
        Get-D9CrashModuleClass $module | Should -Be $class
    }
    It 'падіння у відеодрайвері → оновлення драйвера, у Visual C++ → перевстановлення' {
        Mock Get-D9Events {
            @(1..3 | ForEach-Object { New-FakeEvent 1000 @('game.exe', '1.0', '0', 'nvwgf2umx.dll', '1', '0', 'c0000005') }) +
            @(1..3 | ForEach-Object { New-FakeEvent 1000 @('app.exe', '1.0', '0', 'MSVCP140.dll', '1', '0', 'c0000409') })
        }
        $f = @(Test-D9AppCrashes (Get-TestCheck 'stab.app-crashes') @{ Now = Get-Date })
        ($f | Where-Object key -like '*:gpu').fix.action | Should -Be 'driverUpdate'
        ($f | Where-Object key -like '*:vcrt').fix.action | Should -Be 'vcRedist'
        @($f | Where-Object key -like '*:memory').Count | Should -Be 0
    }
    It 'багато різних програм з порушенням доступу → перевірка пам''яті' {
        Mock Get-D9Events { @(1..6 | ForEach-Object { New-FakeEvent 1000 @("app$_.exe", '1.0', '0', "app$_.dll", '1', '0', 'c0000005') }) }
        $f = @(Test-D9AppCrashes (Get-TestCheck 'stab.app-crashes') @{ Now = Get-Date })
        ($f | Where-Object key -like '*:memory').fix.action | Should -Be 'memoryTest'
    }
}

Describe 'Повільне завантаження' {
    It 'сумує затримки за назвою й сортує за часом' {
        $events = @(
            (New-FakeEvent 101 -Data @{ FriendlyName = 'Steam'; DegradationTime = '4000' })
            (New-FakeEvent 101 -Data @{ FriendlyName = 'Steam'; DegradationTime = '6000' })
            (New-FakeEvent 102 -Data @{ FriendlyName = 'Realtek Audio'; DegradationTime = '2500' })
        )
        $c = @(Get-D9BootCulprits $events)
        $c[0].Name | Should -Be 'Steam'
        $c[0].Seconds | Should -Be 5
        $c[0].Kind | Should -Be 'програма'
        $c[1].Kind | Should -Be 'драйвер'
    }
    It 'довгий запуск через автозапуск — порада про «Автозавантаження»' {
        Mock Get-D9Events { @(1..3 | ForEach-Object { New-FakeEvent 100 -Data @{ BootTime = '90000'; MainPathBootTime = '25000'; BootPostBootTime = '65000' } }) }
        Mock Get-D9EventCount { @(New-FakeEvent 101 -Data @{ FriendlyName = 'Teams'; DegradationTime = '8000' }) }
        $f = Test-D9BootTime (Get-TestCheck 'perf.boot-time') @{ Now = Get-Date; System = (New-TestSystemInfo -SystemDisk 'ssd') }
        $f.title | Should -Match '90 с'
        $f.details | Should -Match 'Teams \(програма, \+8 с\)'
        $f.details | Should -Match 'Автозавантаження'
    }
}

Describe 'Незахищені шляхи служб' {
    It '<path> → <fixed>' -TestCases @(
        @{ path = 'C:\Program Files\Vendor App\svc.exe'; fixed = '"C:\Program Files\Vendor App\svc.exe"' }
        @{ path = 'C:\Program Files\Vendor\svc.exe -k run'; fixed = '"C:\Program Files\Vendor\svc.exe" -k run' }
        @{ path = '"C:\Program Files\Vendor\svc.exe"'; fixed = $null }
        @{ path = 'C:\Tools\svc.exe -k x y'; fixed = $null }
        @{ path = '%SystemRoot%\system32\svchost.exe -k netsvcs'; fixed = $null }
        @{ path = 'System32\drivers\acpi.sys'; fixed = $null }
    ) {
        param($path, $fixed)
        Get-D9UnquotedServicePath $path | Should -Be $fixed
    }
}

Describe 'Нові перевірки й дії' {
    It 'кожна дія обслуговування, на яку посилаються проби, існує' {
        $src = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\scan'
        $names = @(Get-ChildItem $src -Filter '*.ps1' | ForEach-Object { [regex]::Matches((Get-Content $_.FullName -Raw), "type = 'maintenance'; action = '(\w+)'") } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $names.Count | Should -BeGreaterThan 5
        foreach ($n in $names | Where-Object { $_ -notin 'restorePoint', 'reboot' }) {
            $script:D9MaintenanceActions.Contains($n) | Should -BeTrue -Because $n
            Get-Command $script:D9MaintenanceActions[$n].Fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $n
        }
    }
    It 'кожна проба з checks.json існує як функція' {
        foreach ($c in $checks) { Get-Command $c.probe -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $c.id }
    }
    It 'нові проби не падають на цьому ПК' {
        $ctx = @{ Now = Get-Date; IsAdmin = (Test-D9IsAdmin); System = (New-TestSystemInfo) }
        foreach ($id in 'stab.reliability-index', 'net.health', 'sec.unquoted-paths', 'sec.tpm', 'perf.search-index', 'perf.hdd-fragmentation', 'stab.crashes', 'stab.app-crashes', 'perf.boot-time') {
            $c = Get-TestCheck $id
            { & $c.probe $c $ctx } | Should -Not -Throw -Because $id
        }
    }
}
