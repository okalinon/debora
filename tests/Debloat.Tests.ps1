BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
    $script:catalog = Import-D9Catalog
    $script:sys = New-TestSystemInfo
}
AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Конфіг деблоату' {
    It 'кожен застосунок має назву uk/en і відому групу; налаштування є в каталозі' {
        $cfg = Get-D9DebloatConfig
        $groups = @($cfg.groups.id)
        foreach ($a in $cfg.apps) {
            $a.package | Should -Not -BeNullOrEmpty
            $a.name.uk | Should -Not -BeNullOrEmpty -Because $a.package
            $a.name.en | Should -Not -BeNullOrEmpty -Because $a.package
            $groups | Should -Contain $a.group -Because $a.package
        }
        @($cfg.apps.package | Sort-Object -Unique).Count | Should -Be @($cfg.apps).Count -Because 'пакети не повторюються'
        foreach ($f in $cfg.features) { Get-D9Tweak $catalog $f.id | Should -Not -BeNullOrEmpty -Because $f.id }
    }
    It 'Xbox і «корисні» не рекомендовані (за замовчуванням не видаляються)' {
        @((Get-D9DebloatConfig).apps | Where-Object { $_.group -in 'xbox', 'optional' -and $_.recommended }).Count | Should -Be 0
    }
}

Describe 'Застосунки й рекомендації' {
    BeforeAll {
        # На «ПК» встановлено Clipchamp, Xbox Game Bar і Будильники; Copilot — лише для нових користувачів
        Mock Get-D9AppxState {
            switch ($Action.package) {
                'Clipchamp.Clipchamp'           { [ordered]@{ installed = @('Clipchamp.Clipchamp_yxz26nhyzhsrt'); provisioned = @() } }
                'Microsoft.XboxGamingOverlay'   { [ordered]@{ installed = @('Microsoft.XboxGamingOverlay_8wekyb3d8bbwe'); provisioned = @() } }
                'Microsoft.WindowsAlarms'       { [ordered]@{ installed = @('Microsoft.WindowsAlarms_8wekyb3d8bbwe'); provisioned = @() } }
                'Microsoft.Copilot'             { [ordered]@{ installed = @(); provisioned = @('Microsoft.Copilot_1.0.0.0_neutral_~_8wekyb3d8bbwe') } }
                default                         { [ordered]@{ installed = @(); provisioned = @() } }
            }
        }
        $script:apps = @(Get-D9DebloatApps)
    }
    It 'показує лише наявні застосунки з групою й реальним іменем пакета' {
        @($apps.Package) | Should -Be @('Clipchamp.Clipchamp', 'Microsoft.Copilot', 'Microsoft.XboxGamingOverlay', 'Microsoft.WindowsAlarms')
        ($apps | Where-Object Package -eq 'Microsoft.Copilot').Found | Should -Be @('Microsoft.Copilot')
        ($apps | Where-Object Package -eq 'Clipchamp.Clipchamp').GroupName | Should -Match 'Microsoft'
        @(Get-D9DebloatApps -IncludeAbsent).Count | Should -Be @((Get-D9DebloatConfig).apps).Count
    }
    It 'рекомендоване: Clipchamp і Copilot, без Xbox і Будильників; лише незастосовані налаштування' {
        $features = @(
            [pscustomobject]@{ Id = 'privacy.ads-tips'; Recommended = $true; State = 'notApplied' }
            [pscustomobject]@{ Id = 'privacy.telemetry'; Recommended = $true; State = 'applied' }
            [pscustomobject]@{ Id = 'apps.remove-onedrive'; Recommended = $false; State = 'notApplied' }
        )
        $r = Get-D9DebloatRecommended $catalog $sys $apps $features
        $r.Packages | Should -Be @('Clipchamp.Clipchamp', 'Microsoft.Copilot')
        $r.TweakIds | Should -Be @('privacy.ads-tips')
    }
}

Describe 'Виконання деблоату' {
    It 'кожен застосунок — окремий твік з дією appx, плюс твіки з каталогу; відкат через журнал' {
        $cat = New-D9DebloatCatalog -Catalog $catalog -Packages 'Clipchamp.Clipchamp', 'Microsoft.WindowsAlarms' -TweakIds 'privacy.ads-tips'
        @($cat.Tweaks.id) | Should -Be @('debloat.app:Clipchamp.Clipchamp', 'debloat.app:Microsoft.WindowsAlarms', 'privacy.ads-tips')
        $cat.Tweaks[0].actions[0].type | Should -Be 'appx'
        (Get-D9Text $cat.Tweaks[0].name) | Should -Match 'Clipchamp'
    }
    It 'Invoke-D9Debloat проводить зміни через рушій (сесія в журналі)' {
        $script:removed = @()
        Mock Get-D9AppxState { if ($Action.package -in $script:removed) { [ordered]@{ installed = @(); provisioned = @() } } else { [ordered]@{ installed = @("$($Action.package)_x"); provisioned = @() } } }
        Mock Test-D9Appx { $Action.package -in $script:removed }
        Mock Invoke-D9Appx { $script:removed += $Action.package }
        $s = Invoke-D9Debloat -Catalog $catalog -SystemInfo $sys -Packages 'Clipchamp.Clipchamp' -NoRestorePoint
        $s.entries[0].result | Should -Be 'ok'
        $script:removed | Should -Be @('Clipchamp.Clipchamp')
        (Get-D9SessionList | Select-Object -First 1).Id | Should -Be $s.id
        Invoke-D9Debloat -Catalog $catalog -SystemInfo $sys | Should -BeNullOrEmpty
    }
}
