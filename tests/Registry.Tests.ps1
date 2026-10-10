BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $script:testRoot = "HKCU:\Software\Debloater9Test\$([guid]::NewGuid().ToString('N'))"
    function Get-RegAction([hashtable]$Props) {
        $base = @{ type = 'registry'; path = $testRoot; name = 'Value'; value = 0; kind = 'DWord' }
        foreach ($k in $Props.Keys) { $base[$k] = $Props[$k] }
        [pscustomobject]$base
    }
    # Застосувати -> перевірити -> відкотити через знімок, з повним JSON-кругом як у журналі
    function Invoke-RoundTrip($Action) {
        $before = ConvertFrom-Json (ConvertTo-Json (Get-D9RegistryState $Action) -Depth 8)
        Invoke-D9Registry $Action
        $applied = Test-D9Registry $Action
        Restore-D9Registry $Action $before
        [pscustomobject]@{ Applied = $applied; Before = $before; After = (Get-D9RegistryState $Action) }
    }
}

AfterAll {
    Remove-Item 'HKCU:\Software\Debloater9Test' -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Дія registry' {
    It 'створює відсутній ключ і після відкату прибирає його повністю' {
        $a = Get-RegAction @{ path = "$testRoot\New\Deep"; value = 1 }
        $r = Invoke-RoundTrip $a
        $r.Applied | Should -BeTrue
        Test-Path "$testRoot\New" | Should -BeFalse
    }

    It 'повертає попереднє значення DWORD' {
        New-Item $testRoot -Force | Out-Null
        Set-ItemProperty $testRoot -Name Value -Value 7 -Type DWord
        $r = Invoke-RoundTrip (Get-RegAction @{ value = 0 })
        $r.Applied | Should -BeTrue
        (Get-ItemProperty $testRoot).Value | Should -Be 7
    }

    It 'видаляє значення, якого не було, і лишає ключ, що існував' {
        New-Item $testRoot -Force | Out-Null
        Invoke-RoundTrip (Get-RegAction @{ name = 'Fresh'; value = 1 }) | Out-Null
        (Get-ItemProperty $testRoot -Name Fresh -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        Test-Path $testRoot | Should -BeTrue
    }

    It 'працює з DWORD 0xFFFFFFFF' {
        $a = Get-RegAction @{ name = 'Max'; value = 4294967295 }
        Invoke-D9Registry $a
        Test-D9Registry $a | Should -BeTrue
    }

    It 'працює з Binary і повертає старе Binary' {
        New-Item $testRoot -Force | Out-Null
        Set-ItemProperty $testRoot -Name Mask -Value ([byte[]](1, 2, 3)) -Type Binary
        $r = Invoke-RoundTrip (Get-RegAction @{ name = 'Mask'; value = @(144, 18, 3, 128); kind = 'Binary' })
        $r.Applied | Should -BeTrue
        [byte[]](Get-ItemProperty $testRoot).Mask | Should -Be @(1, 2, 3)
    }

    It 'працює з рядком і значенням за замовчуванням ключа' {
        $a = Get-RegAction @{ path = "$testRoot\Default\InprocServer32"; name = ''; value = ''; kind = 'String' }
        $r = Invoke-RoundTrip $a
        $r.Applied | Should -BeTrue
        Test-Path "$testRoot\Default" | Should -BeFalse
    }

    It 'змінює тип значення і повертає старий тип' {
        New-Item $testRoot -Force | Out-Null
        Set-ItemProperty $testRoot -Name Typed -Value '1' -Type String
        Invoke-RoundTrip (Get-RegAction @{ name = 'Typed'; value = 1; kind = 'DWord' }) | Out-Null
        (Get-Item $testRoot).GetValueKind('Typed') | Should -Be 'String'
    }

    It 'delete: видаляє значення і відкат повертає його' {
        New-Item $testRoot -Force | Out-Null
        Set-ItemProperty $testRoot -Name Gone -Value 5 -Type DWord
        $r = Invoke-RoundTrip ([pscustomobject]@{ type = 'registry'; path = $testRoot; name = 'Gone'; delete = $true })
        $r.Applied | Should -BeTrue
        (Get-ItemProperty $testRoot).Gone | Should -Be 5
    }

    It 'Test повертає false, коли значення інше' {
        New-Item $testRoot -Force | Out-Null
        Set-ItemProperty $testRoot -Name Other -Value 1 -Type DWord
        Test-D9Registry (Get-RegAction @{ name = 'Other'; value = 0 }) | Should -BeFalse
    }

    It 'Invoke ідемпотентний' {
        $a = Get-RegAction @{ name = 'Twice'; value = 3 }
        Invoke-D9Registry $a; Invoke-D9Registry $a
        Test-D9Registry $a | Should -BeTrue
    }
}
