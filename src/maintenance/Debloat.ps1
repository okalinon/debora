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

# Деблоат-налаштування з каталогу: стан (applied | partial | notApplied | notApplicable) і чи рекомендоване
function Get-D9DebloatFeatures {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo)
    foreach ($f in @((Get-D9DebloatConfig).features)) {
        $t = Get-D9Tweak $Catalog $f.id
        if (-not $t) { continue }
        [pscustomobject]@{
            Id          = [string]$t.id
            Name        = Get-D9Text $t.name
            Description = Get-D9Text $t.description
            Risk        = [string]$t.risk
            State       = Get-D9TweakState $t $SystemInfo
            Reason      = (Test-D9Applicable $t.requires $SystemInfo).Reason
            Recommended = [bool]$f.recommended
        }
    }
}

# Каталог для рушія: кожен вибраний застосунок — окремий твік «debloat.app:<пакет>», плюс вибрані налаштування
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
