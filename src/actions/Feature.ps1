# Дія "feature": компонент Windows (Turn Windows features on or off) — вимкнути або ввімкнути.
#   { "type": "feature", "name": "WorkFolders-Client", "state": "Disabled" }
# Дія "capability": можливість Windows (Додаткові компоненти: Steps Recorder, Math Recognizer…) — видалити.
#   { "type": "capability", "name": "App.StepsRecorder", "state": "NotPresent" }   # name — початок імені без ~~~~версії
# Обидві потребують прав адміністратора: без них стан невідомий (Test → $null), дія не виконується.
# Повернення можливості завантажує її з Windows Update — без інтернету відкат повідомить, що зробити вручну.

$script:D9FeatureCache = $null
$script:D9CapabilityCache = $null

function Clear-D9FeatureCache { $script:D9FeatureCache = $null; $script:D9CapabilityCache = $null }

# Список читається кілька секунд — один раз на всі пункти
function Get-D9FeatureList {
    if ($null -eq $script:D9FeatureCache) {
        $script:D9FeatureCache = @{}
        if (Test-D9IsAdmin) {
            try { foreach ($f in @(Get-WindowsOptionalFeature -Online -ErrorAction Stop)) { $script:D9FeatureCache[[string]$f.FeatureName] = [string]$f.State } } catch { }
        }
    }
    $script:D9FeatureCache
}

function Get-D9CapabilityList {
    if ($null -eq $script:D9CapabilityCache) {
        $script:D9CapabilityCache = @{}
        if (Test-D9IsAdmin) {
            try { foreach ($c in @(Get-WindowsCapability -Online -ErrorAction Stop)) { $script:D9CapabilityCache[[string]$c.Name] = [string]$c.State } } catch { }
        }
    }
    $script:D9CapabilityCache
}

# ---------- feature ----------
function Get-D9FeatureState {
    param([Parameter(Mandatory)]$Action)
    if (-not (Test-D9IsAdmin)) { return [ordered]@{ exists = $false; needsAdmin = $true } }
    $list = Get-D9FeatureList
    if (-not $list.ContainsKey([string]$Action.name)) { return [ordered]@{ exists = $false } }
    # Disabled, DisabledWithPayloadRemoved, Enabled, EnablePending, DisablePending
    $s = $list[[string]$Action.name]
    [ordered]@{ exists = $true; state = $(if ($s -like 'Enable*') { 'Enabled' } else { 'Disabled' }) }
}

function Test-D9Feature {
    param([Parameter(Mandatory)]$Action)
    $st = Get-D9FeatureState $Action
    if (-not $st.exists) { return $null }
    return $st.state -eq $Action.state
}

function Set-D9FeatureState {
    param([string]$Name, [string]$State)
    if ($State -eq 'Enabled') { Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart -ErrorAction Stop | Out-Null }
    else { Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop | Out-Null }
}

function Invoke-D9Feature {
    param([Parameter(Mandatory)]$Action)
    if (-not (Get-D9FeatureState $Action).exists) { return }
    try { Set-D9FeatureState $Action.name $Action.state } finally { Clear-D9FeatureCache }
}

function Restore-D9Feature {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Before)
    if (-not $Before.exists) { return }
    try { Set-D9FeatureState $Action.name $Before.state } finally { Clear-D9FeatureCache }
}

function Get-D9FeatureDescription {
    param([Parameter(Mandatory)]$Action, $State)
    $old = if ($State.needsAdmin) { T-D9 'невідомо без прав адміністратора' } elseif (-not $State.exists) { T-D9 'немає в системі' } else { $State.state }
    T-D9 'Компонент Windows {0}: {1} -> {2}' "$($Action.name)" $old "$($Action.state)"
}

# ---------- capability ----------
function Get-D9CapabilityFullName {
    param([string]$Name)
    @((Get-D9CapabilityList).Keys | Where-Object { $_ -eq $Name -or $_ -like "$Name~*" }) | Select-Object -First 1
}

function Get-D9CapabilityState {
    param([Parameter(Mandatory)]$Action)
    if (-not (Test-D9IsAdmin)) { return [ordered]@{ exists = $false; needsAdmin = $true } }
    $full = Get-D9CapabilityFullName $Action.name
    if (-not $full) { return [ordered]@{ exists = $false } }
    [ordered]@{ exists = $true; name = $full; state = $(if ((Get-D9CapabilityList)[$full] -eq 'Installed') { 'Installed' } else { 'NotPresent' }) }
}

function Test-D9Capability {
    param([Parameter(Mandatory)]$Action)
    $st = Get-D9CapabilityState $Action
    if (-not $st.exists) { return $null }
    return $st.state -eq $Action.state
}

function Invoke-D9Capability {
    param([Parameter(Mandatory)]$Action)
    $st = Get-D9CapabilityState $Action
    if (-not $st.exists) { return }
    try {
        if ($Action.state -eq 'NotPresent') { Remove-WindowsCapability -Online -Name $st.name -ErrorAction Stop | Out-Null }
        else { Add-WindowsCapability -Online -Name $st.name -ErrorAction Stop | Out-Null }
    } finally { Clear-D9FeatureCache }
}

# Повертає примітку, якщо повернути автоматично не вдалося
function Restore-D9Capability {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Before)
    if (-not $Before.exists -or $Before.state -ne 'Installed') { return }
    try { Add-WindowsCapability -Online -Name $Before.name -ErrorAction Stop | Out-Null }
    catch { return (T-D9 'Не вдалося повернути {0} (потрібен інтернет): Параметри → Система → Додаткові компоненти → Додати компонент.' "$($Before.name)") }
    finally { Clear-D9FeatureCache }
}

function Get-D9CapabilityDescription {
    param([Parameter(Mandatory)]$Action, $State)
    $old = if ($State.needsAdmin) { T-D9 'невідомо без прав адміністратора' } elseif (-not $State.exists) { T-D9 'немає в системі' } else { $State.state }
    T-D9 'Можливість Windows {0}: {1} -> {2}' "$($Action.name)" $old "$($Action.state)"
}
