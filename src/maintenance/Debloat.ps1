# Деблоат Windows: вбудовані застосунки поштучно і деблоат-налаштування з каталогу (config/debloat.json).
# Усе виконується рушієм (точка відновлення, журнал, відкат): кожен застосунок — окремий «твік» з дією appx,
# тож у «Журналі змін» його можна повернути окремо.

$script:D9DebloatConfig = $null

function Get-D9DebloatConfig {
    if (-not $script:D9DebloatConfig) { $script:D9DebloatConfig = ConvertFrom-Json (Get-D9ConfigText 'debloat.json') }
    $script:D9DebloatConfig
}

# Рівні деблоату: накопичуються («Рекомендовано» містить усе з «Обережно»). Поле level у debloat.json;
# loses — що перестане працювати (показується в рядку й перед застосуванням).
$script:D9DebloatLevels = [ordered]@{ safe = 1; recommended = 2; max = 3 }
$script:D9DebloatLevelNames = @{ safe = 'Обережно'; recommended = 'Рекомендовано'; max = 'Максимально' }

function Get-D9DebloatLevel {
    param($Entry)
    $l = [string]$Entry.level
    if ($script:D9DebloatLevels.Contains($l)) { return $l }
    if ($Entry.recommended) { 'recommended' } else { 'max' }   # старий формат (до 0.41.0)
}

function Get-D9DebloatLevelName {
    param([string]$Level)
    $n = $script:D9DebloatLevelNames[$Level]
    if ($n) { T-D9 $n } else { $Level }
}

# Чи входить пункт рівня $Level у вибраний рівень $Target
function Test-D9DebloatInLevel {
    param([string]$Level, [string]$Target)
    $a = $script:D9DebloatLevels[$Level]; $b = $script:D9DebloatLevels[$Target]
    [bool]($a -and $b -and $a -le $b)
}

function Get-D9DebloatLoses {
    param($Entry)
    if ($Entry.loses) { Get-D9Text $Entry.loses } else { '' }
}

function Get-D9DebloatGroupName {
    param([string]$Id)
    $g = @((Get-D9DebloatConfig).groups) | Where-Object id -eq $Id | Select-Object -First 1
    if ($g) { Get-D9Text $g.name } else { $Id }
}

# Застосунки з конфігу, що є на цьому ПК (для поточного користувача, а від адміністратора — і для інших
# та для нових користувачів). Present: $true — встановлено; Found — справжні імена пакетів.
function Get-D9DebloatApps {
    param([switch]$IncludeAbsent)
    $order = @{}; $i = 0; foreach ($g in @((Get-D9DebloatConfig).groups)) { $order[[string]$g.id] = $i++ }
    foreach ($a in @((Get-D9DebloatConfig).apps)) {
        $state = Get-D9AppxState ([pscustomobject]@{ type = 'appx'; package = $a.package })
        $present = [bool](@($state.installed).Count -or @($state.provisioned).Count)
        if (-not $present -and -not $IncludeAbsent) { continue }
        [pscustomobject]@{
            Package     = [string]$a.package
            Name        = Get-D9Text $a.name
            Group       = [string]$a.group
            GroupName   = Get-D9DebloatGroupName $a.group
            GroupOrder  = $order[[string]$a.group]
            Level       = (Get-D9DebloatLevel $a)
            Loses       = (Get-D9DebloatLoses $a)
            Recommended = (Test-D9DebloatInLevel (Get-D9DebloatLevel $a) 'recommended')
            Present     = $present
            Found       = @(@($state.installed) + @($state.provisioned) | ForEach-Object { ($_ -split '_')[0] } | Sort-Object -Unique)
        }
    }
}

# Розділи вкладки (порядок — як у конфігу)
function Get-D9DebloatSection {
    param([string]$Id)
    $i = 0
    foreach ($s in @((Get-D9DebloatConfig).sections)) {
        if ($s.id -eq $Id) { return [pscustomobject]@{ Id = $Id; Name = (Get-D9Text $s.name); Order = $i } }
        $i++
    }
    [pscustomobject]@{ Id = $Id; Name = $Id; Order = 99 }
}

# Пункт з конфігу (items) як «твік» для рушія: id «debloat.<id>»
function ConvertTo-D9DebloatTweak {
    param([Parameter(Mandatory)]$Item)
    [pscustomobject]@{
        id = "debloat.$($Item.id)"; category = 'apps'; risk = [string]$Item.risk
        name = $Item.name; description = $Item.description; actions = @($Item.actions)
    }
}

function Get-D9DebloatItemTweak {
    param([string]$Id)
    $item = @((Get-D9DebloatConfig).items) | Where-Object { "debloat.$($_.id)" -eq $Id } | Select-Object -First 1
    if ($item) { ConvertTo-D9DebloatTweak $item }
}

# Кожну функцію показує одна вкладка. Твіки каталогу, які показує «Деблоат» (features і набори bundles, розкладені там
# поштучно) чи «Обслуговування» (очищення диска, драйвери з Windows Update), на вкладці «Налаштування» не дублюються.
$script:D9MaintenanceTweakIds = @('cleanup.temp', 'cleanup.update-cache', 'cleanup.leftovers', 'cleanup.do-cache', 'updates.no-wu-drivers')

function Get-D9TweakOwner {
    param([Parameter(Mandatory)][string]$Id)
    $cfg = Get-D9DebloatConfig
    if ($Id -like 'debloat.*' -or @($cfg.features.id) -contains $Id -or @($cfg.bundles.ids) -contains $Id) { return 'debloat' }
    if ($script:D9MaintenanceTweakIds -contains $Id) { return 'maintenance' }
    'settings'
}

# Твіки для вкладки «Налаштування» (без тих, що мають власну вкладку)
function Get-D9SettingsTweaks {
    param([Parameter(Mandatory)]$Catalog)
    @($Catalog.Tweaks | Where-Object { (Get-D9TweakOwner $_.id) -eq 'settings' })
}

# Деблоат-налаштування: твіки з каталогу (features) і точкові пункти (items), з розділом і станом
# (applied | partial | notApplied | notApplicable | needsAdmin). Пунктів, яких на ПК немає (служба, завдання,
# компонент відсутні — стан unknown), не показуємо; компоненти без прав адміністратора — needsAdmin.
function Get-D9DebloatFeatures {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo)
    $admin = Test-D9IsAdmin
    $sources = @(
        @((Get-D9DebloatConfig).features) | ForEach-Object { [pscustomobject]@{ Tweak = (Get-D9Tweak $Catalog $_.id); Section = $_.section; Level = (Get-D9DebloatLevel $_); Loses = (Get-D9DebloatLoses $_); Kind = 'tweak' } }
        @((Get-D9DebloatConfig).items) | ForEach-Object { [pscustomobject]@{ Tweak = (ConvertTo-D9DebloatTweak $_); Section = $_.section; Level = (Get-D9DebloatLevel $_); Loses = (Get-D9DebloatLoses $_); Kind = 'item' } }
    )
    foreach ($src in $sources) {
        $t = $src.Tweak
        if (-not $t) { continue }
        $state = Get-D9TweakState $t $SystemInfo
        $adminOnly = [bool](@($t.actions | Where-Object { $_.type -in 'feature', 'capability' }).Count)
        if ($adminOnly -and -not $admin) { $state = 'needsAdmin' }
        elseif ($state -eq 'unknown' -and $src.Kind -eq 'item') { continue }
        $sec = Get-D9DebloatSection $src.Section
        [pscustomobject]@{
            Id           = [string]$t.id
            Kind         = $src.Kind
            Section      = $sec.Id
            SectionName  = $sec.Name
            SectionOrder = $sec.Order
            Name         = Get-D9Text $t.name
            Description  = Get-D9Text $t.description
            Risk         = [string]$t.risk
            State        = $state
            Reason       = (Test-D9Applicable $t.requires $SystemInfo).Reason
            Level        = $src.Level
            Loses        = $src.Loses
            Recommended  = (Test-D9DebloatInLevel $src.Level 'recommended')
        }
    }
}

# Каталог для рушія: кожен вибраний застосунок — окремий твік «debloat.app:<пакет>», плюс вибрані налаштування
# (твіки каталогу або пункти «debloat.<id>»)
function New-D9DebloatCatalog {
    param([Parameter(Mandatory)]$Catalog, [string[]]$Packages, [string[]]$TweakIds)
    $names = @{}; foreach ($a in @((Get-D9DebloatConfig).apps)) { $names[[string]$a.package] = $a.name }
    $tweaks = @(foreach ($p in @($Packages | Where-Object { $_ })) {
        $n = if ($names[$p]) { $names[$p] } else { [pscustomobject]@{ uk = $p; en = $p } }
        [pscustomobject]@{
            id = "debloat.app:$p"; category = 'apps'; risk = 'safe'
            name = [pscustomobject]@{ uk = (T-D9 'Видалити застосунок «{0}»' (Get-D9Text $n)); en = (T-D9 'Видалити застосунок «{0}»' (Get-D9Text $n)) }
            description = [pscustomobject]@{ uk = $p; en = $p }
            actions = @([pscustomobject]@{ type = 'appx'; package = $p })
        }
    })
    $tweaks += @($TweakIds | Where-Object { $_ } | ForEach-Object { Get-D9Tweak $Catalog $_ } | Where-Object { $_ })
    [pscustomobject]@{ Tweaks = $tweaks; Presets = @() }
}
# Деблоат рівня $Level: застосунки цього й нижчих рівнів, що є на ПК, і ще не застосовані налаштування.
# Loses — що перестане працювати (без повторів), Level — сам рівень.
function Get-D9DebloatSelection {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo, [string]$Level = 'recommended', [object[]]$Apps, [object[]]$Features)
    $Level = "$Level".ToLower(); if (-not $script:D9DebloatLevels.Contains($Level)) { $Level = 'recommended' }   # старий профіль без рівня
    if ($null -eq $Apps) { $Apps = @(Get-D9DebloatApps) }
    if ($null -eq $Features) { $Features = @(Get-D9DebloatFeatures $Catalog $SystemInfo) }
    $a = @($Apps | Where-Object { $_.Present -and (Test-D9DebloatInLevel $_.Level $Level) })
    $f = @($Features | Where-Object { $_.State -in 'notApplied', 'partial' -and (Test-D9DebloatInLevel $_.Level $Level) })
    [pscustomobject]@{
        Level    = $Level
        Packages = @($a | ForEach-Object Package)
        TweakIds = @($f | ForEach-Object Id)
        Loses    = @(@($a) + @($f) | ForEach-Object { $_.Loses } | Where-Object { $_ } | Select-Object -Unique)
    }
}

# Рекомендований деблоат (рівень «Рекомендовано»)
function Get-D9DebloatRecommended {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo, [object[]]$Apps, [object[]]$Features)
    Get-D9DebloatSelection -Catalog $Catalog -SystemInfo $SystemInfo -Level recommended -Apps $Apps -Features $Features
}

function Invoke-D9Debloat {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo, [string[]]$Packages, [string[]]$TweakIds, [switch]$NoRestorePoint)
    $cat = New-D9DebloatCatalog -Catalog $Catalog -Packages $Packages -TweakIds $TweakIds
    if (-not @($cat.Tweaks).Count) { return $null }
    $plan = New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo $SystemInfo
    Invoke-D9Plan -Plan $plan -SystemInfo $SystemInfo -Selection (T-D9 'деблоат Windows') -NoRestorePoint:$NoRestorePoint
}
