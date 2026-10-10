BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
    function New-Row([string]$Title, [string]$Products, [string]$Version = '1.0.0.1', [string]$Class = 'Drivers (Networking)') {
        [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Title = $Title; Products = $Products; Classification = $Class; Date = [datetime]'2026-04-12'; Version = $Version; Size = 1000 }
    }
    $script:win11 = New-TestSystemInfo -OsFamily win11; $win11.Build = 22631
    $script:win10 = New-TestSystemInfo -OsFamily win10
}
AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Розбір Microsoft Update Catalog' {
    It 'таблиця результатів → записи з ID, версією, датою, розміром' {
        $html = @'
<table><tr id="headerRow"><td>x</td></tr>
<tr id="a23117b0-fedb-4a87-ba99-78895f4297c4_R1"><td class="resultsbottomBorder"><input/></td>
<td><a onclick='goToDetails("a23117b0");'>Intel net Driver Update (24.40.0.4)</a></td>
<td>Windows 11 Client, version 22H2 and later, Servicing Drivers</td><td>Drivers (Networking)</td><td>4/12/2026</td><td>24.40.0.4</td>
<td><span>23.3 MB</span> <span style="display:none">24467933</span></td><td><input/></td></tr>
<tr id="b0000000-0000-0000-0000-000000000001_R2"><td></td><td>Intel(R) Corporation - System - 1.41.1134.0</td><td>Windows 10 and later drivers</td><td>Drivers (Other Hardware)</td><td>3/15/2021</td><td>n/a</td><td>1 MB 1048576</td><td></td></tr>
</table>
'@
        $rows = @(ConvertFrom-D9CatalogHtml $html)
        $rows.Count | Should -Be 2
        $rows[0].Id | Should -Be 'a23117b0-fedb-4a87-ba99-78895f4297c4'
        $rows[0].Title | Should -Be 'Intel net Driver Update (24.40.0.4)'
        $rows[0].Version | Should -Be '24.40.0.4'
        $rows[0].Date | Should -Be ([datetime]'2026-04-12')
        $rows[0].Size | Should -Be 24467933
        $rows[1].Version | Should -Be '1.41.1134.0' -Because 'версія «n/a» береться з назви'
    }
    It 'запис підходить цій Windows: <case>' -TestCases @(
        @{ case = 'Win11 23H2 ← «22H2 and later»';  os = 'win11'; products = 'Windows 11 Client, version 22H2 and later, Servicing Drivers'; expected = $true }
        @{ case = 'Win11 23H2 ← «24H2 and later»';  os = 'win11'; products = 'Windows 11 Client, version 24H2 and later, Servicing Drivers'; expected = $false }
        @{ case = 'Win11 ← драйвер Windows 10';      os = 'win11'; products = 'Windows 10, Vibranium and later, Servicing Drivers'; expected = $true }
        @{ case = 'Win10 ← лише Windows 11';         os = 'win10'; products = 'Windows 11 Client, version 22H2 and later, Servicing Drivers'; expected = $false }
        @{ case = 'Win10 ← Windows 10 and later';    os = 'win10'; products = 'Windows 10 and later drivers'; expected = $true }
    ) {
        $sys = if ($os -eq 'win11') { $win11 } else { $win10 }
        Test-D9CatalogRowFits (New-Row 'Intel net Driver Update (24.40.0.4)' $products) $sys | Should -Be $expected
    }
    It 'ARM64 і не-драйвери відкидаються' {
        Test-D9CatalogRowFits (New-Row 'Qualcomm ARM64 driver' 'Windows 11 Client, version 22H2 and later') $win11 | Should -BeFalse
        Test-D9CatalogRowFits (New-Row 'Some update' 'Windows 10' -Class 'Updates') $win10 | Should -BeFalse
    }
}

Describe 'Порівняння драйверів і запити' {
    It '<case>' -TestCases @(
        @{ case = 'новіша версія того ж ряду';            nv = '24.40.0.4'; nd = '2026-04-12'; ov = '23.150.0.4'; od = '2025-12-06'; expected = $true }
        @{ case = 'та сама версія';                       nv = '24.40.0.4'; nd = '2026-04-12'; ov = '24.40.0.4'; od = '2026-04-12'; expected = $false }
        @{ case = 'інший ряд версій — за датою';          nv = '1125.29.50.202'; nd = '2026-02-01'; ov = '10.54.1111.2021'; od = '2021-11-11'; expected = $true }
        @{ case = 'вбудований драйвер з датою 2006 — не новіший за датою'; nv = '1.41.1134.0'; nd = '2021-03-15'; ov = '10.0.26100.8972'; od = '2006-06-21'; expected = $false }
        @{ case = 'драйвера немає — будь-який новіший';   nv = '1.0'; nd = '2020-01-01'; ov = ''; od = $null; expected = $true }
    ) {
        Test-D9DriverNewer $nv $nd $ov $od | Should -Be $expected
    }
    It 'запити: точний ID без REV і коротший VEN&DEV; загальні ID не шукаємо' {
        Get-D9DeviceQueries @('PCI\VEN_8086&DEV_51F0&SUBSYS_00748086&REV_01', 'PCI\VEN_8086&DEV_51F0&SUBSYS_00748086') | Should -Be @('PCI\VEN_8086&DEV_51F0&SUBSYS_00748086', 'PCI\VEN_8086&DEV_51F0')
        Get-D9DeviceQueries @('USB\VID_8087&PID_0026&REV_0002') | Should -Be @('USB\VID_8087&PID_0026')
        @(Get-D9DeviceQueries @('ACPI\PNP0A08')).Count | Should -Be 0
    }
}

Describe 'Пошук оновлень (з підміною мережі)' {
    BeforeAll {
        Mock Get-D9UpdatableDevices {
            [pscustomobject]@{ InstanceId = 'PCI\WIFI'; Name = 'Wi-Fi'; Class = 'Net'; Problem = $false; HardwareIds = @('PCI\VEN_8086&DEV_51F0'); Queries = @('PCI\VEN_8086&DEV_51F0'); Version = '23.150.0.4'; Date = [datetime]'2025-12-06'; Provider = 'Intel' }
            [pscustomobject]@{ InstanceId = 'ACPI\X'; Name = 'Невідомий пристрій'; Class = ''; Problem = $true; HardwareIds = @('ACPI\ENEE3000'); Queries = @('ACPI\ENEE3000'); Version = ''; Date = $null; Provider = '' }
            [pscustomobject]@{ InstanceId = 'PCI\SYS'; Name = 'PCI controller'; Class = 'System'; Problem = $false; HardwareIds = @('PCI\VEN_8086&DEV_1111'); Queries = @('PCI\VEN_8086&DEV_1111'); Version = '10.0.1.1'; Date = [datetime]'2006-06-21'; Provider = 'Microsoft' }
            [pscustomobject]@{ InstanceId = 'PCI\NEW'; Name = 'Актуальний'; Class = 'Media'; Problem = $false; HardwareIds = @('PCI\VEN_10EC&DEV_0001'); Queries = @('PCI\VEN_10EC&DEV_0001'); Version = '6.0.9999.1'; Date = [datetime]'2026-09-01'; Provider = 'Realtek' }
        }
        Mock Search-D9DriverCatalog {
            @{
                'PCI\VEN_8086&DEV_51F0' = @((New-Row 'Intel net (24.40.0.4)' 'Windows 11 Client, version 22H2 and later' '24.40.0.4'), (New-Row 'Intel net (24.50.0.1) ARM64' 'Windows 11 Client, version 22H2 and later' '24.50.0.1'))
                'ACPI\ENEE3000'         = @(New-Row 'ENE driver' 'Windows 10 and later drivers' '1.0.0.5')
                'PCI\VEN_8086&DEV_1111' = @(New-Row 'Intel system (10.1.2.3)' 'Windows 10 and later drivers' '10.1.2.3' 'Drivers (System)')
                'PCI\VEN_10EC&DEV_0001' = @(New-Row 'Realtek audio (6.0.9000.1)' 'Windows 10 and later drivers' '6.0.9000.1')
            }
        }
        $script:found = @(Find-D9DriverUpdates -SystemInfo $win11)
    }
    It 'знаходить новішу версію, пропускаючи ARM64' {
        $wifi = $found | Where-Object { $_.Device.Name -eq 'Wi-Fi' }
        $wifi.Row.Version | Should -Be '24.40.0.4'
        $wifi.Status | Should -Be 'newer'
        $wifi.Optional | Should -BeFalse
    }
    It 'невпізнаний пристрій без драйвера отримує драйвер' {
        ($found | Where-Object { $_.Device.Name -eq 'Невідомий пристрій' }).Status | Should -Be 'missing'
    }
    It 'заміна вбудованого драйвера Microsoft на системному пристрої — необов''язкова' {
        ($found | Where-Object { $_.Device.Name -eq 'PCI controller' }).Optional | Should -BeTrue
    }
    It 'старіша версія в каталозі не пропонується' {
        $found | Where-Object { $_.Device.Name -eq 'Актуальний' } | Should -BeNullOrEmpty
    }
}

Describe 'Драйвери в чеклісті' {
    It 'пристрої без драйвера → спершу автоматичний пошук в інтернеті; знахідка глибокого сканування не дублює крок' {
        $check = [pscustomobject]@{ id = 'upd.problem-devices'; category = 'updates' }
        $dev = New-D9Finding $check warning 'Невідомий пристрій — немає драйвера' 'd' @{ type = 'drivers' } -Key 'dev:1' -Data ([pscustomobject]@{ name = 'Невідомий'; class = 'System'; hwid = 'ACPI\ENEE3000' })
        $upd = New-D9Finding ([pscustomobject]@{ id = 'upd.driver-updates'; category = 'updates' }) suggestion 'Новіші драйвери: 3' 'd' @{ type = 'maintenance'; action = 'driverUpdate' }
        $scan = [pscustomobject]@{ id = 't'; findings = @($dev, $upd); system = (New-TestSystemInfo); recommendation = [pscustomobject]@{ Preset = 'Standard' } }
        $list = New-D9Checklist -Scan $scan -Catalog (Import-D9Catalog)
        $auto = @($list.items | Where-Object { $_.action.action -eq 'driverUpdate' })
        $auto.Count | Should -Be 1
        $auto[0].auto | Should -BeTrue
        $auto[0].why | Should -Match 'Новіші драйвери'
        ($list.items | Where-Object { $_.title -like 'Встановити драйвер:*' }) | Should -Not -BeNullOrEmpty -Because 'ручний крок лишається запасним'
    }
}

Describe 'Утиліти виробників' {
    It '<maker> → <tool>' -TestCases @(
        @{ maker = 'Dell Inc.'; tool = 'Dell.CommandUpdate' }
        @{ maker = 'LENOVO'; tool = 'Lenovo.SystemUpdate' }
        @{ maker = 'HP'; tool = 'HP.ImageAssistant' }
        @{ maker = 'Hewlett-Packard'; tool = 'HP.ImageAssistant' }
        @{ maker = 'Acer'; tool = $null }
    ) {
        $sys = New-TestSystemInfo; $sys.Manufacturer = $maker
        (Get-D9OemTool $sys).WingetId | Should -Be $tool
    }
    It 'непідтримуваний виробник — утиліта не запускається' {
        $sys = New-TestSystemInfo; $sys.Manufacturer = 'Acer'
        Invoke-D9OemDriverTool -SystemInfo $sys | Should -BeNullOrEmpty
    }
}
