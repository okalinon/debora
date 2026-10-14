BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
    $script:catalog = Import-D9Catalog
    $script:sys = New-TestSystemInfo
}
AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Профіль майстра «Налаштування з нуля»' {
    It 'типовий: усі кроки, рекомендований профіль, базовий набір, перезавантаження' {
        $p = New-D9SetupProfile
        $p.steps | Should -Be @('drivers', 'debloat', 'tweaks', 'apps', 'windowsUpdate', 'scanFix')
        $p.preset | Should -Be 'Recommended'
        $p.bundles | Should -Be @('basic')
        $p.reboot | Should -BeTrue
    }
    It 'невідомі кроки й порожні ID відкидаються, повтори зникають' {
        $p = ConvertTo-D9SetupProfile ([pscustomobject]@{ steps = @('apps', 'hack', 'apps'); apps = @(' Google.Chrome ', '', 'Google.Chrome'); bundles = @('games', $null); reboot = 0 })
        $p.steps | Should -Be @('apps')
        $p.apps | Should -Be @('Google.Chrome')
        $p.bundles | Should -Be @('games')
        $p.reboot | Should -BeFalse
    }
    It 'зберігається у файл і читається назад; збережений профіль ПК — окремо' {
        $p = ConvertTo-D9SetupProfile ([pscustomobject]@{ name = 'Офіс'; steps = @('tweaks', 'apps'); preset = 'Minimal'; bundles = @('work'); apps = @('7zip.7zip') })
        $file = Join-Path $TestDrive 'office.json'
        Export-D9SetupProfile -Profile $p -Path $file | Should -Be $file
        $back = Import-D9SetupProfile $file
        $back.name | Should -Be 'Офіс'; $back.steps | Should -Be @('tweaks', 'apps'); $back.preset | Should -Be 'Minimal'; $back.apps | Should -Be @('7zip.7zip')
        (Get-D9SetupProfile).name | Should -Not -Be 'Офіс'
        Save-D9SetupProfile $back | Out-Null
        (Get-D9SetupProfile).name | Should -Be 'Офіс'
        Test-Path (Get-D9SetupProfilePath) | Should -BeTrue
    }
    It 'рівень деблоату: типовий «Рекомендовано», зберігається; невідомий або відсутній (старий профіль) — типовий' {
        (New-D9SetupProfile).debloatLevel | Should -Be 'recommended'
        (ConvertTo-D9SetupProfile ([pscustomobject]@{ debloatLevel = 'max' })).debloatLevel | Should -Be 'max'
        (ConvertTo-D9SetupProfile ([pscustomobject]@{ debloatLevel = 'everything' })).debloatLevel | Should -Be 'recommended'
        (ConvertTo-D9SetupProfile ([pscustomobject]@{ name = 'старий' })).debloatLevel | Should -Be 'recommended'
        $f = Join-Path $TestDrive 'lvl.json'
        $p = New-D9SetupProfile; $p.debloatLevel = 'safe'
        Export-D9SetupProfile $p $f
        (Import-D9SetupProfile $f).debloatLevel | Should -Be 'safe'
    }
    It 'відсутній файл і новіша схема — зрозумілі помилки' {
        { Import-D9SetupProfile (Join-Path $TestDrive 'немає.json') } | Should -Throw
        $f = Join-Path $TestDrive 'new.json'; [IO.File]::WriteAllText($f, '{"schema":9,"steps":["apps"]}')
        { Import-D9SetupProfile $f } | Should -Throw '*новішою*'
    }
}

Describe 'План і програми майстра' {
    It 'набори й окремі ID зливаються без повторів, невідомі — окремо' {
        $p = ConvertTo-D9SetupProfile ([pscustomobject]@{ bundles = @('basic', 'games'); apps = @('7zip.7zip', 'No.Such.App') })
        $r = Resolve-D9SetupApps $p
        @($r.Apps | Where-Object id -eq '7zip.7zip').Count | Should -Be 1
        @($r.Apps | Where-Object id -eq 'Valve.Steam').Count | Should -Be 1
        $r.Unknown | Should -Be @('No.Such.App')
    }
    It 'профіль налаштувань: Recommended → рекомендований для ПК, інакше за id; невідомий — помилка' {
        (Resolve-D9SetupPreset (New-D9SetupProfile) $catalog $sys).id | Should -Be (Get-D9RecommendedPreset $sys).Preset
        (Resolve-D9SetupPreset (ConvertTo-D9SetupProfile ([pscustomobject]@{ preset = 'WeakPC' })) $catalog $sys).id | Should -Be 'WeakPC'
        { Resolve-D9SetupPreset (ConvertTo-D9SetupProfile ([pscustomobject]@{ preset = 'Nope' })) $catalog $sys } | Should -Throw
    }
    It 'план: рядок на кожен крок у порядку профілю, з назвою й поясненням' {
        $p = ConvertTo-D9SetupProfile ([pscustomobject]@{ steps = @('apps', 'tweaks', 'scanFix'); preset = 'Minimal'; bundles = @('basic'); apps = @('No.Such.App') })
        $plan = @(Get-D9SetupPlan -Profile $p -Catalog $catalog -SystemInfo $sys -Quick)
        $plan.step | Should -Be @('apps', 'tweaks', 'scanFix')
        $plan[0].detail | Should -Match 'No\.Such\.App'
        $plan[1].detail | Should -Match 'твіків'
        $plan | ForEach-Object { $_.title | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Виконання майстра' {
    BeforeAll {
        Mock New-D9RestorePoint { 'rp' }
        Mock Invoke-D9SetupStep {
            switch ($Step) {
                'drivers' { [pscustomobject]@{ Text = 'встановлено драйверів: 1 (потрібне перезавантаження)'; Reboot = $true } }
                'apps'    { throw 'winget зламався' }
                'tweaks'  { '«Мінімальний»: змін 5, помилок 0' }
            }
        }
        $script:p = ConvertTo-D9SetupProfile ([pscustomobject]@{ name = 'T'; steps = @('drivers', 'apps', 'tweaks') })
        $script:s = Invoke-D9Setup -Profile $p -Catalog $catalog -SystemInfo $sys
    }
    It 'збій одного кроку не зупиняє решту; підсумок і прапорець перезавантаження' {
        $s.results.step | Should -Be @('drivers', 'apps', 'tweaks')
        $s.results.ok | Should -Be @($true, $false, $true)
        $s.reboot | Should -BeTrue
        $s.restorePoint | Should -BeTrue
        $s.profile | Should -Be 'T'
    }
    It 'підсумок зберігається і форматується' {
        (Get-D9SetupLast).profile | Should -Be 'T'
        $text = Format-D9SetupSummary $s
        $text | Should -Match 'помилка — winget'
        $text | Should -Match 'змін 5'
    }
    It '-NoRestorePoint не створює точку' {
        $s2 = Invoke-D9Setup -Profile $p -Catalog $catalog -SystemInfo $sys -NoRestorePoint
        $s2.restorePoint | Should -BeFalse
    }
}
