# Дія "appx": видалення вбудованого застосунку для всіх користувачів
# і заборона його встановлення для нових користувачів.
#   { "type": "appx", "package": "Microsoft.BingNews" }      # підтримує * у назві
# Повернути видалений застосунок можна лише якщо його файли ще є на диску;
# інакше — через Microsoft Store (відкат повідомляє про це).

# Get-AppxPackage повільний (~0,3 с на виклик), а в каталозі десятки пакетів —
# тому читаємо повні списки один раз і скидаємо кеш після кожної зміни.
$script:D9AppxCache = $null

function Clear-D9AppxCache { $script:D9AppxCache = $null }

function Get-D9AppxCache {
    if (-not $script:D9AppxCache) {
        $admin = Test-D9IsAdmin
        $script:D9AppxCache = [pscustomobject]@{
            Installed   = if ($admin) { @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) } else { @(Get-AppxPackage -ErrorAction SilentlyContinue) }
            Provisioned = if ($admin) { @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) } else { @() }
        }
    }
    return $script:D9AppxCache
}

function Get-D9AppxInstalled {
    param([string]$Package)
    @((Get-D9AppxCache).Installed | Where-Object Name -like $Package)
}

function Get-D9AppxProvisioned {
    param([string]$Package)
    @((Get-D9AppxCache).Provisioned | Where-Object DisplayName -like $Package)
}

function Get-D9AppxState {
    param([Parameter(Mandatory)]$Action)
    $installed   = Get-D9AppxInstalled $Action.package
    $provisioned = Get-D9AppxProvisioned $Action.package
    return [ordered]@{
        installed   = @($installed | ForEach-Object { $_.PackageFamilyName } | Sort-Object -Unique)
        provisioned = @($provisioned | ForEach-Object { $_.PackageName } | Sort-Object -Unique)
    }
}

function Test-D9Appx {
    param([Parameter(Mandatory)]$Action)
    $state = Get-D9AppxState $Action
    return ($state.installed.Count -eq 0 -and $state.provisioned.Count -eq 0)
}

function Invoke-D9Appx {
    param([Parameter(Mandatory)]$Action)
    $installed   = Get-D9AppxInstalled $Action.package
    $provisioned = Get-D9AppxProvisioned $Action.package
    try {
        foreach ($p in $installed) {
            if (Test-D9IsAdmin) { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
            else { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
        }
        foreach ($p in $provisioned) {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
        }
    } finally { Clear-D9AppxCache }
}

# Повертає рядок-примітку, якщо щось повернути автоматично не вдалося
function Restore-D9Appx {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Before)
    $manual = @()
    foreach ($family in @($Before.installed)) {
        $name = $family.Split('_')[0]
        if (Get-AppxPackage -Name $name -ErrorAction SilentlyContinue) { continue }
        $staged = Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        $manifest = if ($staged) { Join-Path $staged.InstallLocation 'AppxManifest.xml' }
        if ($manifest -and (Test-Path $manifest)) {
            try { Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction Stop; continue } catch { }
        }
        $manual += $name
    }
    Clear-D9AppxCache
    if ($manual) { return "Встановіть вручну з Microsoft Store: $($manual -join ', ')" }
}

function Get-D9AppxDescription {
    param([Parameter(Mandatory)]$Action, $State)
    if ($State -and $State.installed.Count -eq 0 -and $State.provisioned.Count -eq 0) {
        return "Застосунок $($Action.package): не встановлено"
    }
    return "Видалити застосунок $($Action.package)"
}
