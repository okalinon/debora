BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $script:testRoot = "HKCU:\Software\Debloater9Test\$([guid]::NewGuid().ToString('N'))"
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'

    function New-RegTweak([string]$Id, [string]$Name, $Value, $Requires) {
        $t = [ordered]@{
            id = $Id; category = 'ui'; risk = 'safe'
            name = [pscustomobject]@{ uk = $Id; en = $Id }; description = [pscustomobject]@{ uk = 'т'; en = 't' }
            actions = @([pscustomobject]@{ type = 'registry'; path = $testRoot; name = $Name; value = $Value; kind = 'DWord' })
        }
        if ($Requires) { $t.requires = $Requires }
        [pscustomobject]$t
    }
    $script:sys = New-TestSystemInfo
    $script:catalog = [pscustomobject]@{
        Tweaks = @(
            (New-RegTweak 'ui.one' 'One' 1),
            (New-RegTweak 'ui.two' 'Two' 2),
            (New-RegTweak 'ui.hdd-only' 'Hdd' 1 ([pscustomobject]@{ hardware = [pscustomobject]@{ systemDisk = @('hdd') } }))
        )
        Presets = @()
    }
}

AfterAll {
    Remove-Item 'HKCU:\Software\Debloater9Test' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue
}

Describe 'Придатність твіків' {
    It 'HDD-твік недоступний на SSD з причиною' {
        $r = Test-D9Applicable ([pscustomobject]@{ hardware = [pscustomobject]@{ systemDisk = @('hdd') } }) (New-TestSystemInfo -SystemDisk ssd)
        $r.Applicable | Should -BeFalse
        $r.Reason | Should -Match 'HDD'
    }
    It 'твік лише для Windows 11 недоступний на Windows 10' {
        (Test-D9Applicable ([pscustomobject]@{ os = @('win11') }) (New-TestSystemInfo -OsFamily win10)).Applicable | Should -BeFalse
    }
    It 'твік без вимог доступний' {
        (Test-D9Applicable $null $sys).Applicable | Should -BeTrue
    }
    It 'конфліктний твік у плані пропускається' {
        $a = New-RegTweak 'perf.a' 'A' 1; $a | Add-Member conflicts @('perf.b')
        $b = New-RegTweak 'perf.b' 'B' 1; $b | Add-Member conflicts @('perf.a')
        $plan = New-D9Plan -Catalog ([pscustomobject]@{ Tweaks = @($a, $b); Presets = @() }) -TweakIds 'perf.a', 'perf.b' -SystemInfo $sys
        ($plan | Where-Object Id -eq 'perf.b').Run | Should -BeFalse
        ($plan | Where-Object Id -eq 'perf.b').Reason | Should -Match 'конфліктує'
    }
}

Describe 'Рекомендації' {
    It 'HDD + 4 ГБ -> Слабкий ПК' {
        (Get-D9RecommendedPreset (New-TestSystemInfo -SystemDisk hdd -RamGB 3.9 -Cores 2)).Preset | Should -Be 'WeakPC'
    }
    It 'SSD + 16 ГБ -> Стандартний' {
        (Get-D9RecommendedPreset (New-TestSystemInfo -SystemDisk nvme -RamGB 16)).Preset | Should -Be 'Standard'
    }
    It 'невідомий диск -> Мінімальний' {
        (Get-D9RecommendedPreset (New-TestSystemInfo -SystemDisk unknown -RamGB 8 -Cores 4)).Preset | Should -Be 'Minimal'
    }
}

Describe 'Виконання, журнал і відкат' {
    BeforeEach {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item $testRoot -Force | Out-Null
        Set-ItemProperty $testRoot -Name One -Value 5 -Type DWord   # Two не існує
    }

    It 'застосовує план, пише журнал і повністю відкочує' {
        $plan = New-D9Plan -Catalog $catalog -TweakIds 'ui.one', 'ui.two', 'ui.hdd-only' -SystemInfo $sys
        Get-D9TweakState (Get-D9Tweak $catalog 'ui.one') $sys | Should -Be 'notApplied'

        $session = Invoke-D9Plan -Plan $plan -SystemInfo $sys -Selection 'test' -NoRestorePoint
        @($session.entries | Where-Object result -eq 'ok').Count | Should -Be 2
        (Get-ItemProperty $testRoot).One | Should -Be 1
        (Get-ItemProperty $testRoot).Two | Should -Be 2
        Get-D9TweakState (Get-D9Tweak $catalog 'ui.one') $sys | Should -Be 'applied'
        Get-D9TweakState (Get-D9Tweak $catalog 'ui.hdd-only') $sys | Should -Be 'notApplicable'

        (Get-D9SessionList | Select-Object -First 1).Id | Should -Be $session.id

        $report = Undo-D9Session -Id $session.id
        @($report | Where-Object result -eq 'restored').Count | Should -Be 2
        (Get-ItemProperty $testRoot).One | Should -Be 5
        (Get-ItemProperty $testRoot -Name Two -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }

    It 'не затирає значення, змінене після застосування (conflict)' {
        $plan = New-D9Plan -Catalog $catalog -TweakIds 'ui.one' -SystemInfo $sys
        $session = Invoke-D9Plan -Plan $plan -SystemInfo $sys -NoRestorePoint
        Set-ItemProperty $testRoot -Name One -Value 99 -Type DWord   # хтось змінив після нас
        $report = Undo-D9Session -Id $session.id
        $report[0].result | Should -Be 'conflict'
        (Get-ItemProperty $testRoot).One | Should -Be 99
    }

    It 'вже застосоване позначається alreadyApplied і не відкочується' {
        Set-ItemProperty $testRoot -Name One -Value 1 -Type DWord
        $session = Invoke-D9Plan -Plan (New-D9Plan -Catalog $catalog -TweakIds 'ui.one' -SystemInfo $sys) -SystemInfo $sys -NoRestorePoint
        $session.entries[0].result | Should -Be 'alreadyApplied'
        @(Undo-D9Session -Id $session.id).Count | Should -Be 0
    }

    It 'відкочує лише вибрані твіки' {
        $session = Invoke-D9Plan -Plan (New-D9Plan -Catalog $catalog -TweakIds 'ui.one', 'ui.two' -SystemInfo $sys) -SystemInfo $sys -NoRestorePoint
        Undo-D9Session -Id $session.id -TweakIds 'ui.two' | Out-Null
        (Get-ItemProperty $testRoot).One | Should -Be 1
        (Get-ItemProperty $testRoot -Name Two -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }

    It 'помилка однієї дії не зупиняє решту' {
        $bad = New-RegTweak 'ui.bad' 'Bad' 1
        $bad.actions = @([pscustomobject]@{ type = 'command'; run = 'throw "бум"'; undoRun = '' })
        $cat = [pscustomobject]@{ Tweaks = @($bad, (Get-D9Tweak $catalog 'ui.two')); Presets = @() }
        $session = Invoke-D9Plan -Plan (New-D9Plan -Catalog $cat -TweakIds 'ui.bad', 'ui.two' -SystemInfo $sys) -SystemInfo $sys -NoRestorePoint
        ($session.entries | Where-Object tweak -eq 'ui.bad').result | Should -Be 'error'
        ($session.entries | Where-Object tweak -eq 'ui.two').result | Should -Be 'ok'
    }

    It 'дія, що впала, але встигла змінити систему, відкочується (partial)' {
        Mock Invoke-D9Registry { Set-ItemProperty $testRoot -Name One -Value 1 -Type DWord; throw 'частково' }
        $session = Invoke-D9Plan -Plan (New-D9Plan -Catalog $catalog -TweakIds 'ui.one' -SystemInfo $sys) -SystemInfo $sys -NoRestorePoint
        $session.entries[0].result | Should -Be 'error'
        $session.entries[0].partial | Should -BeTrue
        $report = @(Undo-D9Session -Id $session.id)
        $report[0].result | Should -Be 'restored'
        (Get-ItemProperty $testRoot).One | Should -Be 5
    }
    It 'дія, що впала без змін, не відкочується' {
        Mock Invoke-D9Registry { throw 'нічого не змінено' }
        $session = Invoke-D9Plan -Plan (New-D9Plan -Catalog $catalog -TweakIds 'ui.one' -SystemInfo $sys) -SystemInfo $sys -NoRestorePoint
        $session.entries[0].partial | Should -BeNullOrEmpty
        @(Undo-D9Session -Id $session.id).Count | Should -Be 0
    }

    It 'попередній перегляд показує стару і нову величину' {
        $preview = @(Get-D9Preview -Plan (New-D9Plan -Catalog $catalog -TweakIds 'ui.one' -SystemInfo $sys) -SystemInfo $sys)
        $preview[0].Change | Should -Match '5 -> 1'
        $preview[0].Pending | Should -BeTrue
    }
}

Describe 'Дія service: відновлення не понижує тип запуску' {
    It 'Manual + start не чіпає службу з автоматичним запуском, але піднімає вимкнену' {
        $a = [pscustomobject]@{ type = 'service'; name = 'W32Time'; startup = 'Manual'; start = $true }
        Get-D9ServiceTargetStartup $a 'AutomaticDelayed' | Should -Be 'AutomaticDelayed'
        Get-D9ServiceTargetStartup $a 'Automatic' | Should -Be 'Automatic'
        Get-D9ServiceTargetStartup $a 'Disabled' | Should -Be 'Manual'
        $stop = [pscustomobject]@{ type = 'service'; name = 'Spooler'; startup = 'Manual'; stop = $true }
        Get-D9ServiceTargetStartup $stop 'Automatic' | Should -Be 'Manual'
    }
}

Describe 'Дія command' {
    It 'виконує run і undoRun' {
        $global:D9TestFlag = 0
        $a = [pscustomobject]@{ type = 'command'; run = '$global:D9TestFlag = 1'; undoRun = '$global:D9TestFlag = 0'; test = '$global:D9TestFlag -eq 1' }
        Test-D9Command $a | Should -BeFalse
        Invoke-D9Command $a
        Test-D9Command $a | Should -BeTrue
        Restore-D9Command $a ([ordered]@{}) | Should -BeNullOrEmpty
        $global:D9TestFlag | Should -Be 0
    }
    It 'без test стан невідомий' {
        Test-D9Command ([pscustomobject]@{ type = 'command'; run = '1' }) | Should -BeNullOrEmpty
    }
    It 'без undoRun повідомляє, що відкат неможливий' {
        Restore-D9Command ([pscustomobject]@{ type = 'command'; run = '1' }) ([ordered]@{}) | Should -Match 'не можна'
    }
}
