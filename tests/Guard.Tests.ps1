# Стеження після оновлень Windows: бажаний стан за журналом, що скасовано, повернення, «не повертати»
BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $script:sys = New-TestSystemInfo
    $script:key = 'HKCU:\Software\DeboraGuardTest'
    function New-RegTweak([string]$Id, [string]$Name, [int]$Value) {
        [pscustomobject]@{ id = $Id; name = $Id; actions = @([pscustomobject]@{ type = 'registry'; path = $key; name = $Name; value = $Value; kind = 'DWord' }) }
    }
    function Invoke-Tweaks([object[]]$Tweaks) {
        $plan = @($Tweaks | ForEach-Object { [pscustomobject]@{ Id = $_.id; Tweak = $_; Run = $true; Reason = $null } })
        Invoke-D9Plan -Plan $plan -SystemInfo $sys -Selection 'test' -NoRestorePoint
    }
}
AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Зміни, які скасувала Windows' {
    BeforeEach {
        $env:D9_DATA_ROOT = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\DeboraGuardTest', $false)
    }
    AfterEach { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\DeboraGuardTest', $false) }

    It 'застосоване й не відкочене — під наглядом; поки стан не змінився, повернень немає' {
        [void](Invoke-Tweaks @((New-RegTweak 'test.a' 'A' 1), (New-RegTweak 'test.b' 'B' 0)))
        @(Get-D9GuardDesired).Count | Should -Be 2
        @(Find-D9GuardDrift).Count | Should -Be 0
    }
    It 'Windows змінила значення — це знаходиться й повертається окремою сесією, яку можна відкотити' {
        [void](Invoke-Tweaks @((New-RegTweak 'test.a' 'A' 1), (New-RegTweak 'test.b' 'B' 0)))
        Set-ItemProperty $key -Name A -Value 0   # «оновлення Windows»
        $drift = @(Find-D9GuardDrift)
        $drift.Count | Should -Be 1
        $drift[0].Tweak | Should -Be 'test.a'
        $drift[0].Text | Should -Not -BeNullOrEmpty
        $r = Restore-D9GuardDrift -Items $drift -SystemInfo $sys -NoRestorePoint
        $r.Fixed | Should -Be 1
        (Get-ItemProperty $key).A | Should -Be 1
        @(Find-D9GuardDrift).Count | Should -Be 0
        (Get-D9GuardStatus).drift | Should -Be 0
        # Сесія повернення — звичайна сесія журналу: її відкат повертає стан «як зробила Windows»
        [void](Undo-D9Session -Id $r.Session.id)
        (Get-ItemProperty $key).A | Should -Be 0
    }
    It 'відкат сесії знімає зміни з нагляду; повторне застосування пізніше — знову під наглядом' {
        $s = Invoke-Tweaks @((New-RegTweak 'test.a' 'A' 1))
        Start-Sleep -Milliseconds 1100   # час записів журналу — з точністю до секунди
        [void](Undo-D9Session -Id $s.id)
        @(Get-D9GuardDesired).Count | Should -Be 0
        Start-Sleep -Milliseconds 1100
        [void](Invoke-Tweaks @((New-RegTweak 'test.a' 'A' 1)))
        @(Get-D9GuardDesired).Count | Should -Be 1
    }
    It '«Не повертати»: знята галочка — зміна більше не пропонується' {
        [void](Invoke-Tweaks @((New-RegTweak 'test.a' 'A' 1)))
        Set-ItemProperty $key -Name A -Value 0
        $drift = @(Find-D9GuardDrift)
        Add-D9GuardIgnore -Items $drift
        @(Find-D9GuardDrift).Count | Should -Be 0
        @(Get-D9GuardIgnore).Count | Should -Be 1
        Clear-D9GuardIgnore
        @(Find-D9GuardDrift).Count | Should -Be 1
    }
    It 'разові дії (очищення, драйвери) не відстежуються; у служби — лише тип запуску' {
        $dir = Get-D9SessionDir
        $s = [pscustomobject]@{ id = '2026-01-01T00-00-00-test'; started = '2026-01-01T00:00:00'; selection = 'x'; undo = @()
            entries = @(
                [pscustomobject]@{ tweak = 'c'; result = 'ok'; time = '2026-01-01T00:00:01'; action = [pscustomobject]@{ type = 'command'; run = 'cleanmgr' } }
                [pscustomobject]@{ tweak = 'd'; result = 'ok'; time = '2026-01-01T00:00:02'; action = [pscustomobject]@{ type = 'driver'; inf = 'x.inf' } }
                [pscustomobject]@{ tweak = 's'; result = 'ok'; time = '2026-01-01T00:00:03'; action = [pscustomobject]@{ type = 'service'; name = 'W32Time'; startup = 'Manual'; start = $true } }
                [pscustomobject]@{ tweak = 'e'; result = 'error'; time = '2026-01-01T00:00:04'; action = [pscustomobject]@{ type = 'registry'; path = $key; name = 'E'; value = 1 } }
            ) }
        [IO.File]::WriteAllText((Join-Path $dir "$($s.id).json"), (ConvertTo-Json $s -Depth 6))
        $d = @(Get-D9GuardDesired)
        $d.Count | Should -Be 1
        $d[0].Action.type | Should -Be 'service'
        $d[0].Action.PSObject.Properties['start'] | Should -BeNullOrEmpty   # служба, що сама зупинилась, — не «повернення»
    }
    It 'коли перевіряти: нова збірка Windows, минула доба, або ще не перевіряли' {
        Test-D9GuardDue $sys | Should -BeTrue
        Save-D9GuardStatus -SystemInfo $sys -Drift 0
        Test-D9GuardDue $sys | Should -BeFalse
        Test-D9GuardDue $sys -Now (Get-Date).AddHours(21) | Should -BeTrue
        $newer = $sys.PSObject.Copy(); $newer.Build = $sys.Build + 1
        Test-D9GuardDue $newer | Should -BeTrue
    }
}
