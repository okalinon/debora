BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $script:catalog = Import-D9Catalog
}

Describe 'Каталог твіків' {
    It 'не містить помилок перевірки' {
        $errors = Test-D9Catalog $catalog
        $errors -join "`n" | Should -BeNullOrEmpty
    }

    It 'містить щонайменше 30 твіків' {
        @($catalog.Tweaks).Count | Should -BeGreaterOrEqual 30
    }

    It 'має всі п''ять профілів' {
        @($catalog.Presets.id) | Should -Be @('Minimal', 'Standard', 'WeakPC', 'Gaming', 'Maximum')
    }

    It 'не дає SysMain і індексацію в профілях для SSD' {
        foreach ($id in 'Minimal', 'Standard', 'Gaming') {
            (Get-D9Preset $catalog $id).tweaks | Should -Not -Contain 'perf.disable-sysmain'
            (Get-D9Preset $catalog $id).tweaks | Should -Not -Contain 'perf.disable-search-index'
        }
    }
}

Describe 'Test-D9Catalog ловить помилки' {
    BeforeAll {
        function New-Catalog($tweak, $presetTweaks = @()) {
            [pscustomobject]@{ Tweaks = @($tweak); Presets = @([pscustomobject]@{ id = 'P'; tweaks = $presetTweaks }) }
        }
        function New-Tweak([hashtable]$Override) {
            $t = [ordered]@{
                id = 'ui.test'; category = 'ui'; risk = 'safe'
                name = [pscustomobject]@{ uk = 'а'; en = 'a' }; description = [pscustomobject]@{ uk = 'а'; en = 'a' }
                actions = @([pscustomobject]@{ type = 'registry'; path = 'HKCU:\Software\X'; name = 'V'; value = 1; kind = 'DWord' })
            }
            foreach ($k in $Override.Keys) { $t[$k] = $Override[$k] }
            [pscustomobject]$t
        }
    }

    It 'коректний твік проходить' {
        Test-D9Catalog (New-Catalog (New-Tweak @{})) | Should -BeNullOrEmpty
    }
    It 'невідомий тип дії' {
        Test-D9Catalog (New-Catalog (New-Tweak @{ actions = @([pscustomobject]@{ type = 'magic' }) })) | Should -Match 'невідомий тип дії'
    }
    It 'command без undoRun у звичайному твіку' {
        Test-D9Catalog (New-Catalog (New-Tweak @{ actions = @([pscustomobject]@{ type = 'command'; run = 'x' }) })) | Should -Match 'undoRun'
    }
    It 'command без undoRun дозволено в irreversible' {
        Test-D9Catalog (New-Catalog (New-Tweak @{ irreversible = $true; actions = @([pscustomobject]@{ type = 'command'; run = 'x' }) })) | Should -BeNullOrEmpty
    }
    It 'некоректний kind реєстру' {
        Test-D9Catalog (New-Catalog (New-Tweak @{ actions = @([pscustomobject]@{ type = 'registry'; path = 'HKCU:\X'; name = 'V'; value = 1; kind = 'Dword32' }) })) | Should -Match 'kind'
    }
    It 'експертний твік у профілі' {
        Test-D9Catalog (New-Catalog (New-Tweak @{ risk = 'expert' }) @('ui.test')) | Should -Match 'експертний'
    }
    It 'немає англійського перекладу' {
        Test-D9Catalog (New-Catalog (New-Tweak @{ name = [pscustomobject]@{ uk = 'а' } })) | Should -Match 'uk і en'
    }
}
