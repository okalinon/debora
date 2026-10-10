BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
}
AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Розпізнавання пристроїв' {
    It 'PCI: Wi-Fi Qualcomm Atheros QCA9377 (Acer ES1-522)' {
        $d = Resolve-D9Device @('PCI\VEN_168C&DEV_0042&SUBSYS_0806105B&REV_31')
        $d.Vendor | Should -Match 'Atheros'
        $d.Name | Should -Match 'QCA9377'
        Get-D9DeviceDisplayName $d 'Мережевий контролер' | Should -Match 'QCA9377'
    }
    It 'HDAUDIO: кодек Realtek ALC255' {
        (Resolve-D9Device @('HDAUDIO\FUNC_01&VEN_10EC&DEV_0255&SUBSYS_1025109A')).Name | Should -Be 'Realtek ALC255 (аудіокодек)'
    }
    It 'USB: Intel Bluetooth' {
        $d = Resolve-D9Device @('USB\VID_8087&PID_0A2B&REV_0010')
        $d.Vendor | Should -Match 'Intel'
        $d.Name | Should -Not -BeNullOrEmpty
    }
    It 'ACPI: тачпад ELAN' {
        (Resolve-D9Device @('ACPI\ELAN0501')).Vendor | Should -Match 'ELAN'
    }
    It 'невідомий формат — без помилки, з назвою від Windows' {
        $d = Resolve-D9Device @('ROOT\SOMETHING\0000')
        Get-D9DeviceDisplayName $d 'Пристрій X' | Should -Be 'Пристрій X'
        Get-D9DeviceDisplayName $d $null | Should -Be 'Невідомий пристрій'
    }
}

Describe 'Де взяти драйвер' {
    It 'Acer: сторінка драйверів саме цієї моделі' {
        $sys = New-TestSystemInfo; $sys.Manufacturer = 'Acer'; $sys.Model = 'Aspire ES1-522'
        $oem = Get-D9OemSupport $sys
        $oem.Name | Should -Be 'Acer'
        $oem.Url | Should -Be 'https://www.acer.com/ua-uk/support/product-support/Aspire_ES1-522/downloads'
    }
    It 'невідомий виробник — без сторінки' {
        $sys = New-TestSystemInfo; $sys.Manufacturer = 'NoName Corp'
        Get-D9OemSupport $sys | Should -BeNullOrEmpty
    }
    It 'посилання: виробник ПК першим, потім виробник чипа, потім Microsoft Update Catalog' {
        $oem = [pscustomobject]@{ Name = 'Acer'; Url = 'https://acer.example/page'; Note = $null }
        $links = @(Get-D9DriverLinks (Resolve-D9Device @('PCI\VEN_8086&DEV_9D3A&SUBSYS_00000000')) $oem)
        $links[0].url | Should -Be 'https://acer.example/page'
        $links[1].label | Should -Match 'Intel'
        $links[-1].url | Should -Match 'catalog\.update\.microsoft\.com.+VEN_8086%26DEV_9D3A$'
    }
    It 'для Realtek/Atheros — без загального сайту чипа (краще драйвер виробника ПК)' {
        $links = @(Get-D9DriverLinks (Resolve-D9Device @('PCI\VEN_168C&DEV_0042')) $null)
        @($links | Where-Object { $_.label -like 'Сайт*' }).Count | Should -Be 0
    }
}

Describe 'Розбір INF' {
    BeforeAll {
        $script:infText = @"
[Version]
Signature="`$WINDOWS NT`$"
Class=Net
Provider=%Qualcomm%
DriverVer=02/07/2018,10.0.0.326

[Manufacturer]
%Qualcomm% = Atheros, NTamd64

[Atheros.NTamd64]
%ATHR.DeviceDesc.9377% = ATHR_DEV_OS61, PCI\VEN_168C&DEV_0042&SUBSYS_0806105B
%ATHR.DeviceDesc.9377% = ATHR_DEV_OS61, PCI\VEN_168C&DEV_0042

[Strings]
Qualcomm = "Qualcomm Atheros"
"@
    }
    It 'ANSI INF: клас, версія, дата, ID, 64-біт' {
        $p = Join-Path $TestDrive 'a.inf'; [IO.File]::WriteAllText($p, $infText, [Text.Encoding]::ASCII)
        $i = Get-D9InfInfo $p
        $i.Class | Should -Be 'Net'
        $i.Version | Should -Be '10.0.0.326'
        $i.Date | Should -Be ([datetime]'2018-02-07')
        $i.Ids | Should -Contain 'PCI\VEN_168C&DEV_0042'
        $i.Is64 | Should -BeTrue
    }
    It 'UTF-16 INF теж читається' {
        $p = Join-Path $TestDrive 'u.inf'; [IO.File]::WriteAllText($p, $infText, [Text.Encoding]::Unicode)
        (Get-D9InfInfo $p).Ids | Should -Contain 'PCI\VEN_168C&DEV_0042&SUBSYS_0806105B'
    }
}

Describe 'Підбір драйверів з папки' {
    BeforeAll {
        # Справжній пристрій цього ПК і «драйвер» для нього з дуже старою датою
        $script:dev = Get-CimInstance Win32_PnPEntity | Where-Object { @($_.HardwareID)[0] -like 'PCI\VEN_*' -and $_.ConfigManagerErrorCode -eq 0 } | Select-Object -First 1
        $script:drvDir = Join-Path $TestDrive 'Драйвери'
        New-Item -ItemType Directory -Path "$drvDir\old" -Force | Out-Null
        $id = @($dev.HardwareID)[0]
        $inf = "[Version]`r`nClass=System`r`nDriverVer=01/01/2001,1.0.0.0`r`n[Manufacturer]`r`n%M%=Models,NTamd64`r`n[Models.NTamd64]`r`n%D%=Install, $id`r`n"
        [IO.File]::WriteAllText("$drvDir\old\test.inf", $inf, [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText("$drvDir\old\other.inf", $inf.Replace($id, 'PCI\VEN_FFFF&DEV_FFFF'), [Text.Encoding]::ASCII)
        Compress-Archive -Path "$drvDir\old\test.inf" -DestinationPath "$drvDir\pack.zip"
        $script:found = Find-D9DriverPackages -Folder $drvDir
    }
    It 'розпаковує .zip і знаходить усі INF' {
        Test-Path "$drvDir\_розпаковано\pack\test.inf" | Should -BeTrue
        $found.Infs | Should -Be 3
    }
    It 'бере лише драйвери для пристроїв цього ПК' {
        @($found.Packages).Count | Should -Be 1
        $found.Packages[0].Package.Inf.Path | Should -Not -Match 'other\.inf'
    }
    It 'старий драйвер позначається як «вже актуальний»' {
        $found.Packages[0].Status | Should -Be 'current'
    }
    It 'з пакетів будується план із дією driver' {
        $cat = New-D9DriverCatalog -Packages $found.Packages
        $cat.Tweaks[0].actions[0].type | Should -Be 'driver'
        $plan = New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo (New-TestSystemInfo)
        $plan[0].Run | Should -BeTrue
        (Get-D9Preview -Plan $plan -SystemInfo (New-TestSystemInfo))[0].Change | Should -Match '1\.0\.0\.0'
    }
    It 'стан дії driver читає поточний драйвер пристрою' {
        $state = Get-D9DriverState ([pscustomobject]@{ type = 'driver'; hwids = @(@($dev.HardwareID)[0]) })
        @($state.devices).Count | Should -BeGreaterOrEqual 1
        $state.devices[0].id | Should -Not -BeNullOrEmpty
    }
}

Describe 'Звіт про драйвери' {
    It 'будується на цьому ПК' {
        $rep = Get-D9DriverReport (Get-D9SystemInfo)
        $rep | Should -Not -BeNullOrEmpty
        @($rep.Important).Count | Should -BeGreaterThan 0
    }
}
