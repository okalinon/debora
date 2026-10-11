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
    It 'розділи відомі; кожен пункт проходить перевірку каталогу (дії, шляхи, тексти uk/en)' {
        $cfg = Get-D9DebloatConfig
        $secs = @($cfg.sections.id)
        @($secs | Sort-Object -Unique).Count | Should -Be $secs.Count
        foreach ($f in $cfg.features) { $secs | Should -Contain $f.section -Because $f.id }
        foreach ($i in $cfg.items) { $secs | Should -Contain $i.section -Because $i.id }
        @($cfg.items.id | Sort-Object -Unique).Count | Should -Be @($cfg.items).Count -Because 'id пунктів не повторюються'
        $tweaks = @($cfg.items | ForEach-Object { ConvertTo-D9DebloatTweak $_ })
        @(Test-D9Catalog ([pscustomobject]@{ Tweaks = $tweaks; Presets = @() })) | Should -BeNullOrEmpty
        @($cfg.items).Count | Should -BeGreaterOrEqual 45
    }
    It 'Xbox і «корисні» не рекомендовані (за замовчуванням не видаляються)' {
        @((Get-D9DebloatConfig).apps | Where-Object { $_.group -in 'xbox', 'optional' -and $_.recommended }).Count | Should -Be 0
    }
}

Describe 'Застосунки й рекомендації' {
    BeforeAll {
        # На «ПК» встановлено Clipchamp, Xbox Game Bar і Будильники; Spotify — лише для нових користувачів
        Mock Get-D9AppxState {
            switch ($Action.package) {
                'Clipchamp.Clipchamp'           { [ordered]@{ installed = @('Clipchamp.Clipchamp_yxz26nhyzhsrt'); provisioned = @() } }
                'Microsoft.XboxGamingOverlay'   { [ordered]@{ installed = @('Microsoft.XboxGamingOverlay_8wekyb3d8bbwe'); provisioned = @() } }
                'Microsoft.WindowsAlarms'       { [ordered]@{ installed = @('Microsoft.WindowsAlarms_8wekyb3d8bbwe'); provisioned = @() } }
                '*Spotify*'                     { [ordered]@{ installed = @(); provisioned = @('SpotifyAB.SpotifyMusic_1.0.0.0_neutral_~_zpdnekdrzrea0') } }
                default                         { [ordered]@{ installed = @(); provisioned = @() } }
            }
        }
        $script:apps = @(Get-D9DebloatApps)
    }
    It 'показує лише наявні застосунки з групою й реальним іменем пакета' {
        @($apps.Package) | Should -Be @('*Spotify*', 'Clipchamp.Clipchamp', 'Microsoft.XboxGamingOverlay', 'Microsoft.WindowsAlarms')
        ($apps | Where-Object Package -eq '*Spotify*').Found | Should -Be @('SpotifyAB.SpotifyMusic')
        ($apps | Where-Object Package -eq 'Clipchamp.Clipchamp').GroupName | Should -Match 'Microsoft'
        @(Get-D9DebloatApps -IncludeAbsent).Count | Should -Be @((Get-D9DebloatConfig).apps).Count
    }
    It 'рекомендоване: Spotify і Clipchamp, без Xbox і Будильників; лише незастосовані налаштування' {
        $features = @(
            [pscustomobject]@{ Id = 'privacy.ads-tips'; Recommended = $true; State = 'notApplied' }
            [pscustomobject]@{ Id = 'privacy.telemetry'; Recommended = $true; State = 'applied' }
            [pscustomobject]@{ Id = 'apps.remove-onedrive'; Recommended = $false; State = 'notApplied' }
        )
        $r = Get-D9DebloatRecommended $catalog $sys $apps $features
        $r.Packages | Should -Be @('*Spotify*', 'Clipchamp.Clipchamp')
        $r.TweakIds | Should -Be @('privacy.ads-tips')
    }
}

Describe 'Налаштування деблоату' {
    It 'без адміністратора: компоненти — needsAdmin, відсутні служби й завдання сховано, є розділи' {
        Mock Test-D9IsAdmin { $false }
        Mock Get-D9ServiceState { [ordered]@{ exists = $false } }
        Mock Get-D9ScheduledTaskState { [ordered]@{ exists = $false } }
        $f = @(Get-D9DebloatFeatures $catalog $sys)
        ($f | Where-Object Id -eq 'debloat.comp-powershell2').State | Should -Be 'needsAdmin'
        $f | Where-Object Id -eq 'debloat.svc-fax' | Should -BeNullOrEmpty
        $f | Where-Object Id -eq 'debloat.task-sqm' | Should -BeNullOrEmpty
        ($f | Where-Object Id -eq 'debloat.ai-paint').SectionName | Should -Match 'Copilot'
        ($f | Where-Object Id -eq 'privacy.telemetry').Section | Should -Be 'privacy'
        $orders = @($f | Sort-Object SectionOrder | ForEach-Object SectionOrder)
        $orders[0] | Should -BeLessOrEqual $orders[-1]
    }
    It 'компонент Windows: відсутній — не застосовно; вимкнений — застосовано' {
        Mock Test-D9IsAdmin { $true }
        $script:D9FeatureCache = @{ 'WorkFolders-Client' = 'Disabled'; 'Printing-XPSServices-Features' = 'Enabled' }
        Test-D9Feature ([pscustomobject]@{ type = 'feature'; name = 'WorkFolders-Client'; state = 'Disabled' }) | Should -BeTrue
        Test-D9Feature ([pscustomobject]@{ type = 'feature'; name = 'Printing-XPSServices-Features'; state = 'Disabled' }) | Should -BeFalse
        Test-D9Feature ([pscustomobject]@{ type = 'feature'; name = 'Recall'; state = 'Disabled' }) | Should -BeNullOrEmpty
        $script:D9CapabilityCache = @{ 'App.StepsRecorder~~~~0.0.1.0' = 'Installed' }
        (Get-D9CapabilityState ([pscustomobject]@{ type = 'capability'; name = 'App.StepsRecorder'; state = 'NotPresent' })).name | Should -Be 'App.StepsRecorder~~~~0.0.1.0'
        Test-D9Capability ([pscustomobject]@{ type = 'capability'; name = 'App.StepsRecorder'; state = 'NotPresent' }) | Should -BeFalse
        Clear-D9FeatureCache
    }
    It 'вибраний пункт потрапляє в каталог для рушія' {
        $cat = New-D9DebloatCatalog -Catalog $catalog -TweakIds 'debloat.ai-paint', 'privacy.ads-tips'
        @($cat.Tweaks.id) | Should -Be @('debloat.ai-paint', 'privacy.ads-tips')
        @($cat.Tweaks[0].actions).Count | Should -Be 3
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

Describe 'Без дублів між вкладками' {
    BeforeAll {
        # Що саме змінює дія; -WithValue — з цільовим значенням (для правил сканера, які можуть повертати протилежне)
        $script:sigOf = {
            param($a, [switch]$WithValue)
            $v = if ($WithValue) { "=$($a.value)$($a.startup)$($a.state)" } else { '' }
            switch ($a.type) {
                'registry'      { "reg:$(([string]$a.path).ToLower())\$($a.name)$v" }
                'service'       { "svc:$($a.name)$v" }
                'scheduledTask' { "task:$($a.path)$v" }
                'appx'          { "appx:$($a.package)" }
                'feature'       { "feat:$($a.name)" }
                'capability'    { "cap:$($a.name)" }
                default         { $null }
            }
        }
        # Рядки, які бачить користувач: «Налаштування», «Деблоат» (налаштування, пункти, застосунки), «Обслуговування»
        $cfg = Get-D9DebloatConfig
        $script:visible = @(
            @(Get-D9SettingsTweaks $catalog)
            @($cfg.features | ForEach-Object { Get-D9Tweak $catalog $_.id })
            @($cfg.items | ForEach-Object { ConvertTo-D9DebloatTweak $_ })
            @($catalog.Tweaks | Where-Object { (Get-D9TweakOwner $_.id) -eq 'maintenance' })
            @($cfg.apps | ForEach-Object { [pscustomobject]@{ id = "app:$($_.package)"; actions = @([pscustomobject]@{ type = 'appx'; package = $_.package }) } })
        )
    }
    It 'кожна зміна (значення реєстру, служба, завдання, пакет, компонент) — лише в одному рядку інтерфейсу' {
        $owners = @{}
        foreach ($t in $visible) {
            foreach ($a in @($t.actions)) {
                $s = & $sigOf $a
                if (-not $s) { continue }
                if (-not $owners[$s]) { $owners[$s] = @() }
                if ($owners[$s] -notcontains $t.id) { $owners[$s] += $t.id }
            }
        }
        @($owners.Keys | Where-Object { $owners[$_].Count -gt 1 } | ForEach-Object { "$_ => $($owners[$_] -join ', ')" }) | Should -BeNullOrEmpty
    }
    It 'кожен твік каталогу показує рівно одна вкладка; набори bundles розкладені в «Деблоаті» поштучно' {
        foreach ($t in $catalog.Tweaks) { (Get-D9TweakOwner $t.id) | Should -BeIn 'settings', 'debloat', 'maintenance' }
        $shown = @{}
        foreach ($t in $visible) { foreach ($a in @($t.actions)) { $s = & $sigOf $a; if ($s) { $shown[$s] = $true } } }
        foreach ($id in (Get-D9DebloatConfig).bundles.ids) {
            $b = Get-D9Tweak $catalog $id
            $b | Should -Not -BeNullOrEmpty -Because $id
            foreach ($a in @($b.actions)) { $shown[(& $sigOf $a)] | Should -BeTrue -Because "$id → $(& $sigOf $a) має бути окремим рядком «Деблоату»" }
        }
    }
    It 'правила сканера не копіюють дії твіків — посилаються на твік (fix.type = tweaks)' {
        $tweakSigs = @{}
        foreach ($t in @($catalog.Tweaks) + @((Get-D9DebloatConfig).items | ForEach-Object { ConvertTo-D9DebloatTweak $_ })) {
            foreach ($a in @($t.actions)) { $s = & $sigOf $a -WithValue; if ($s) { $tweakSigs[$s] = $t.id } }
        }
        $bad = foreach ($c in (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).checks) {
            $fix = if ($c.params.fix) { $c.params.fix } else { $c.fix }
            if ($fix.type -ne 'actions') { continue }
            foreach ($a in @($fix.actions)) { $s = & $sigOf $a -WithValue; if ($s -and $tweakSigs[$s]) { "$($c.id) → $($tweakSigs[$s])" } }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It 'правила, що посилаються на твіки, знаходять їх (і пункти «Деблоату» debloat.<id>)' {
        foreach ($c in (ConvertFrom-Json (Get-D9ConfigText 'checks.json')).checks) {
            $fix = if ($c.params.fix) { $c.params.fix } else { $c.fix }
            if ($fix.type -ne 'tweaks') { continue }
            foreach ($id in @($fix.ids)) { Get-D9Tweak $catalog $id | Should -Not -BeNullOrEmpty -Because "$($c.id) → $id" }
        }
    }
    It 'майстер: якщо є крок «Деблоат», профіль налаштувань не повторює його твіків' {
        $preset = Get-D9Preset $catalog 'Maximum'
        $with = @(Get-D9SetupTweakIds ([pscustomobject]@{ steps = @('debloat', 'tweaks') }) $preset)
        $without = @(Get-D9SetupTweakIds ([pscustomobject]@{ steps = @('tweaks') }) $preset)
        $with | Should -Not -Contain 'privacy.telemetry'
        $with | Should -Not -Contain 'apps.remove-bloat'
        $with | Should -Contain 'perf.power-high'
        $without | Should -Contain 'privacy.telemetry'
    }
}
