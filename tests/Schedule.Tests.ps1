BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
    $script:catalog = Import-D9Catalog
}
AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Налаштування автообслуговування' {
    It 'типові: очищення, Захисник, програми, драйвери; неділя 12:00' {
        $c = Get-D9MaintenanceConfig
        $c.Steps | Should -Be @('guard', 'cleanup', 'defender', 'apps', 'drivers')
        $c.Day | Should -Be 'Sunday'
        $c.Time | Should -Be '12:00'
    }
    It 'зберігаються й відкидають невідомі кроки' {
        Save-D9MaintenanceConfig ([pscustomobject]@{ Steps = @('apps', 'hack'); Day = 'Friday'; Time = '9:30' })
        $c = Get-D9MaintenanceConfig
        $c.Steps | Should -Be @('apps')
        $c.Day | Should -Be 'Friday'
        $c.Time | Should -Be '9:30'
    }
    It 'команда завдання: прихований запуск зібраного скрипта з -Maintain' {
        $cmd = Get-D9MaintenanceTaskCommand 'C:\ProgramData\Debloater9\app\Debora.ps1'
        $cmd.Execute | Should -Be 'powershell.exe'
        $cmd.Argument | Should -Match '-WindowStyle Hidden -File "C:\\ProgramData\\Debloater9\\app\\Debora\.ps1" -Maintain$'
    }
}

Describe 'Виконання обслуговування' {
    BeforeAll {
        Mock New-D9RestorePoint { 'rp' }
        Mock Invoke-D9MaintenanceStep {
            switch ($Step) { 'cleanup' { 'звільнено 1,5 ГБ' } 'apps' { throw 'winget зламався' } 'drivers' { 'встановлено драйверів: 2 (потрібне перезавантаження)' } }
        }
        $script:s = Invoke-D9Maintenance -Catalog $catalog -SystemInfo (New-TestSystemInfo) -Steps @('cleanup', 'apps', 'drivers') -NoScan
    }
    It 'збій одного кроку не зупиняє решту' {
        $s.results.step | Should -Be @('cleanup', 'apps', 'drivers')
        $s.results.ok | Should -Be @($true, $false, $true)
    }
    It 'спершу точка відновлення; перезавантаження розпізнається' {
        Should -Invoke New-D9RestorePoint -Times 1 -Exactly -Scope Describe
        $s.restorePoint | Should -BeTrue
        $s.reboot | Should -BeTrue
    }
    It 'підсумок зберігається й читається' {
        @((Get-D9MaintenanceLast).results).Count | Should -Be 3
    }
    It 'текст сповіщення' {
        $text = Format-D9MaintenanceSummary $s
        $text | Should -Match 'звільнено 1,5 ГБ'
        $text | Should -Match 'apps: помилка'
        $text | Should -Match 'Перезавантажте ПК'
    }
}
