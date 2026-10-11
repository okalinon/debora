# Деблоат Windows: вбудовані застосунки поштучно і деблоат-налаштування з каталогу (config/debloat.json).
# Усе виконується рушієм (точка відновлення, журнал, відкат): кожен застосунок — окремий «твік» з дією appx,
# тож у «Журналі змін» його можна повернути окремо.

$script:D9DebloatConfig = $null

function Get-D9DebloatConfig {
    if (-not $script:D9DebloatConfig) { $script:D9DebloatConfig = ConvertFrom-Json (Get-D9ConfigText 'debloat.json') }
    $script:D9DebloatConfig
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
            Recommended = [bool]$a.recommended
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

# Деблоат-налаштування: твіки з каталогу (features) і точкові пункти (items), з розділом і станом
# (applied | partial | notApplied | notApplicable | needsAdmin). Пунктів, яких на ПК немає (служба, завдання,
# компонент відсутні — стан unknown), не показуємо; компоненти без прав адміністратора — needsAdmin.
function Get-D9DebloatFeatures {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo)
    $admin = Test-D9IsAdmin
    $sources = @(
        @((Get-D9DebloatConfig).features) | ForEach-Object { [pscustomobject]@{ Tweak = (Get-D9Tweak $Catalog $_.id); Section = $_.section; Recommended = [bool]$_.recommended; Kind = 'tweak' } }
        @((Get-D9DebloatConfig).items) | ForEach-Object { [pscustomobject]@{ Tweak = (ConvertTo-D9DebloatTweak $_); Section = $_.section; Recommended = [bool]$_.recommended; Kind = 'item' } }
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
            Recommended  = $src.Recommended
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
    $tweaks += @($TweakIds | Where-Object { $_ } | ForEach-Object { $x = Get-D9Tweak $Catalog $_; if (-not $x) { $x = Get-D9DebloatItemTweak $_ }; $x } | Where-Object { $_ })
    [pscustomobject]@{ Tweaks = $tweaks; Presets = @() }
}
# Рекомендований деблоат: рекомендовані застосунки, що є на ПК, і рекомендовані ще не застосовані налаштування
function Get-D9DebloatRecommended {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo, [object[]]$Apps, [object[]]$Features)
    if ($null -eq $Apps) { $Apps = @(Get-D9DebloatApps) }
    if ($null -eq $Features) { $Features = @(Get-D9DebloatFeatures $Catalog $SystemInfo) }
    [pscustomobject]@{
        Packages = @($Apps | Where-Object { $_.Recommended -and $_.Present } | ForEach-Object Package)
        TweakIds = @($Features | Where-Object { $_.Recommended -and $_.State -in 'notApplied', 'partial' } | ForEach-Object Id)
    }
}

function Invoke-D9Debloat {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo, [string[]]$Packages, [string[]]$TweakIds, [switch]$NoRestorePoint)
    $cat = New-D9DebloatCatalog -Catalog $Catalog -Packages $Packages -TweakIds $TweakIds
    if (-not @($cat.Tweaks).Count) { return $null }
    $plan = New-D9Plan -Catalog $cat -TweakIds @($cat.Tweaks.id) -SystemInfo $SystemInfo
    Invoke-D9Plan -Plan $plan -SystemInfo $SystemInfo -Selection (T-D9 'деблоат Windows') -NoRestorePoint:$NoRestorePoint
}
