BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    # Звіт powercfg /batteryreport /xml: щотижневі записи історії з ємністю й часом від мережі/батареї
    function New-BatteryXml {
        param([double]$Design = 46740, [double[]]$Fulls, [datetime]$Start = [datetime]'2024-07-15', [int[]]$Changed = @(), [double[]]$Designs,
              [string]$Ac = 'P6DT20H', [string]$Dc = 'PT4H', [string]$Now = 'PT1H39M18S', [string]$New = 'PT2H15M42S')
        $h = for ($i = 0; $i -lt $Fulls.Count; $i++) {
            $d = if ($Designs) { $Designs[$i] } else { $Design }
            $flag = if ($Changed -contains $i) { 1 } else { 0 }
            "<HistoryEntry LocalStartDate='$($Start.AddDays(7 * $i).ToString('s'))' DesignCapacity='$d' FullChargeCapacity='$($Fulls[$i])' CycleCount='0' BatteryChanged='$flag' ActiveAcTime='$Ac' ActiveDcTime='$Dc' CsAcTime='PT0S' CsDcTime='PT0S'/>"
        }
        $last = $Fulls[-1]
        [xml]@"
<BatteryReport>
  <Batteries><Battery Id='x' Chemistry='LiON' DesignCapacity='$Design' FullChargeCapacity='$last' CycleCount='0'/></Batteries>
  <RuntimeEstimates>
    <FullChargeCapacity Capacity='$last' ActiveRuntime='$Now'/>
    <DesignCapacity Capacity='$Design' ActiveRuntime='$New'/>
  </RuntimeEstimates>
  <History>$($h -join '')</History>
</BatteryReport>
"@
    }
    # 2 роки щотижня: від 95% до 73% паспортної ємності
    $script:weeks = 115
    $script:fulls = @(0..($weeks - 1) | ForEach-Object { [math]::Round(46740 * (0.95 - 0.22 * $_ / ($weeks - 1))) })
    $script:now = ([datetime]'2024-07-15').AddDays(7 * ($weeks - 1)).AddDays(3)
}

Describe 'Розбір звіту батареї' {
    It 'ємність, знос на рік, прогноз, частка від мережі, час роботи' {
        $b = ConvertFrom-D9BatteryReport (New-BatteryXml -Fulls $fulls) -Now $now
        $b.Health | Should -Be 73
        $b.WearPerYear | Should -BeGreaterThan 9
        $b.WearPerYear | Should -BeLessThan 11.5
        $b.Forecast60 | Should -BeGreaterThan $now
        $b.Forecast60 | Should -BeLessThan $now.AddYears(2)
        $b.AcShare | Should -Be ([math]::Round(164 / 168, 2))
        $b.RuntimeNow.TotalMinutes | Should -BeGreaterThan 99
        $b.RuntimeDesign.TotalMinutes | Should -BeGreaterThan 135
        $b.Cycles | Should -BeNullOrEmpty
        Get-D9BatteryLevel $b | Should -Be 'fair'
    }
    It 'прапорець BatteryChanged без зміни ємності не обрізає історію' {
        $b = ConvertFrom-D9BatteryReport (New-BatteryXml -Fulls $fulls -Changed @(3, 40, 90)) -Now $now
        $b.History.Count | Should -Be $weeks
    }
    It 'справжня заміна батареї (стрибок ємності) починає історію заново' {
        $f = @($fulls[0..59]) + @(1..20 | ForEach-Object { 46000 })
        $b = ConvertFrom-D9BatteryReport (New-BatteryXml -Fulls $f) -Now ([datetime]'2026-01-01')
        $b.History.Count | Should -Be 20
        $b.History[0].Health | Should -BeGreaterThan 98
    }
    It 'інша паспортна ємність теж означає заміну' {
        $designs = @(1..10 | ForEach-Object { 46740 }) + @(1..6 | ForEach-Object { 50000 })
        $b = ConvertFrom-D9BatteryReport (New-BatteryXml -Fulls @(1..16 | ForEach-Object { 40000 }) -Designs $designs) -Now ([datetime]'2024-11-15')
        $b.History.Count | Should -Be 6
    }
    It 'коротка історія — без швидкості зносу й прогнозу' {
        $b = ConvertFrom-D9BatteryReport (New-BatteryXml -Fulls @(40000, 39900, 39800)) -Now ([datetime]'2024-08-10')
        $b.WearPerYear | Should -BeNullOrEmpty
        $b.Forecast60 | Should -BeNullOrEmpty
    }
    It 'батареї немає — $null' {
        ConvertFrom-D9BatteryReport ([xml]'<BatteryReport><Batteries/></BatteryReport>') | Should -BeNullOrEmpty
    }
}

Describe 'Поради щодо батареї' {
    It 'постійно на зарядці → порада обмежити заряд з утилітою виробника' {
        $b = ConvertFrom-D9BatteryReport (New-BatteryXml -Fulls $fulls) -Now $now
        Test-D9BatteryAlwaysPlugged $b | Should -BeTrue
        $a = @(Get-D9BatteryAdvice $b 'Dream Machines')
        $a.Count | Should -Be 1
        $a[0] | Should -Match 'Flexicharger'
        (Get-D9ChargeLimitTip 'LENOVO') | Should -Match 'Vantage'
        (Get-D9ChargeLimitTip 'Невідомий виробник') | Should -Match '80%'
    }
    It 'переважно від батареї — без поради про обмеження' {
        $b = ConvertFrom-D9BatteryReport (New-BatteryXml -Fulls $fulls -Ac 'PT10H' -Dc 'P2D') -Now $now
        Test-D9BatteryAlwaysPlugged $b | Should -BeFalse
    }
    It 'сильний знос → заміна; текстовий звіт і рівень' {
        $f = @(0..30 | ForEach-Object { 46740 * (0.6 - 0.25 * $_ / 30) })
        $b = ConvertFrom-D9BatteryReport (New-BatteryXml -Fulls $f -Ac 'PT1H' -Dc 'P1D') -Now ([datetime]'2025-03-01')
        Get-D9BatteryLevel $b | Should -Be 'bad'
        @(Get-D9BatteryAdvice $b 'ASUS')[0] | Should -Match 'замінити'
        (Format-D9BatteryReport $b 'ASUS')[0] | Should -Match '^\[Потребує заміни\] ємність'
    }
    It 'перевірки сканера: знос лише нижче порогу, звички — з порадою' {
        $b = ConvertFrom-D9BatteryReport (New-BatteryXml -Fulls $fulls) -Now $now
        $sys = New-TestSystemInfo -HasBattery $true; $sys.Manufacturer = 'Dream Machines'
        $ctx = [pscustomobject]@{ System = $sys; IsAdmin = $false; Battery = $b }
        $wear = [pscustomobject]@{ id = 'bat.wear'; category = 'battery'; thresholds = [pscustomobject]@{ warningPercent = 60; criticalPercent = 40 } }
        Test-D9BatteryWear $wear $ctx | Should -BeNullOrEmpty
        $habits = [pscustomobject]@{ id = 'bat.charge-habits'; category = 'battery'; thresholds = [pscustomobject]@{ acShare = 0.85; wearPerYear = 5 } }
        $f = Test-D9BatteryHabits $habits $ctx
        $f.severity | Should -Be 'suggestion'
        $f.title | Should -Match '98%'
        $f.details | Should -Match 'Flexicharger'
    }
}
