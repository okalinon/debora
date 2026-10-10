BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
    $script:testRoot = "HKCU:\Software\Debloater9Test\$([guid]::NewGuid().ToString('N'))"
}
AfterAll {
    Remove-Item 'HKCU:\Software\Debloater9Test' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue
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
