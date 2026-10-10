# Тести, що читають (але не змінюють) реальну систему.
# Тести, що змінюють служби й завдання, запускаються лише від адміністратора
# і лише коли встановлено $env:D9_INTEGRATION = '1' (на тестовій ВМ).

BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $script:isAdmin = Test-D9IsAdmin
    $script:integration = $env:D9_INTEGRATION -eq '1'
}

Describe 'Відомості про систему' {
    It 'повертає ОС, пам''ять і тип диска' {
        $s = Get-D9SystemInfo
        $s.OsFamily | Should -BeIn @('win10', 'win11')
        $s.RamGB | Should -BeGreaterThan 0
        $s.SystemDisk | Should -BeIn @('hdd', 'ssd', 'nvme', 'unknown')
    }
    It 'тип диска не залежить від того, чи завантажено модуль Storage' {
        $before = Get-D9SystemDisk
        [void](Get-PhysicalDisk -ErrorAction SilentlyContinue)   # модуль Storage підміняє числа текстом
        $after = Get-D9SystemDisk
        $after.Type | Should -Be $before.Type
        $after.PartitionStyle | Should -Be $before.PartitionStyle
    }
}

Describe 'Читання стану реальних об''єктів' {
    It 'служба: стан і тип запуску' {
        $state = Get-D9ServiceState ([pscustomobject]@{ name = 'Winmgmt' })
        $state.exists | Should -BeTrue
        $state.startup | Should -BeIn @('Automatic', 'AutomaticDelayed', 'Manual', 'Disabled')
    }
    It 'служба, якої немає' {
        $a = [pscustomobject]@{ name = 'D9NoSuchService'; startup = 'Disabled' }
        (Get-D9ServiceState $a).exists | Should -BeFalse
        Test-D9Service $a | Should -BeNullOrEmpty
    }
    It 'заплановане завдання, якого немає' {
        Test-D9ScheduledTask ([pscustomobject]@{ path = '\D9\NoSuchTask'; state = 'Disabled' }) | Should -BeNullOrEmpty
    }
    It 'схема живлення читається' {
        (Get-D9PowerCfgState ([pscustomobject]@{ scheme = 'high' })).activeScheme | Should -Match '^[0-9a-f-]{36}$'
    }
    It 'стан усіх твіків каталогу обчислюється без помилок' {
        $sys = Get-D9SystemInfo
        foreach ($t in (Import-D9Catalog).Tweaks) {
            Get-D9TweakState $t $sys | Should -BeIn @('applied', 'partial', 'notApplied', 'notApplicable', 'unknown')
        }
    }
}

Describe 'Зміна служб і завдань (інтеграційні)' -Skip:(-not ($isAdmin -and $integration)) {
    It 'service: Disabled і відкат до попереднього типу запуску' {
        $a = [pscustomobject]@{ type = 'service'; name = 'Fax'; startup = 'Disabled'; stop = $true }
        $before = ConvertFrom-Json (ConvertTo-Json (Get-D9ServiceState $a))
        Invoke-D9Service $a
        Test-D9Service $a | Should -BeTrue
        Restore-D9Service $a $before
        (Get-D9ServiceState $a).startup | Should -Be $before.startup
    }
    It 'scheduledTask: вимкнення і відкат' {
        $a = [pscustomobject]@{ type = 'scheduledTask'; path = '\Microsoft\Windows\Autochk\Proxy'; state = 'Disabled' }
        $before = ConvertFrom-Json (ConvertTo-Json (Get-D9ScheduledTaskState $a))
        Invoke-D9ScheduledTask $a
        Test-D9ScheduledTask $a | Should -BeTrue
        Restore-D9ScheduledTask $a $before
        (Get-D9ScheduledTaskState $a).state | Should -Be $before.state
    }
}
