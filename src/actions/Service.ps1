# Дія "service": тип запуску служби і (необов'язково) зупинка або запуск.
#   { "type": "service", "name": "SysMain", "startup": "Disabled", "stop": true }
#   { "type": "service", "name": "mpssvc", "startup": "Automatic", "start": true }   — відновлення вимкненої служби
# startup: Disabled | Manual | Automatic | AutomaticDelayed

$script:D9ServiceStartup = @{
    Disabled         = 'disabled'
    Manual           = 'demand'
    Automatic        = 'auto'
    AutomaticDelayed = 'delayed-auto'
}

function Get-D9ServiceStartup {
    param([string]$Name)
    $props = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -ErrorAction SilentlyContinue
    if (-not $props) { return $null }
    switch ([int]$props.Start) {
        2       { if ($props.DelayedAutostart -eq 1) { 'AutomaticDelayed' } else { 'Automatic' } }
        3       { 'Manual' }
        4       { 'Disabled' }
        default { "Boot$([int]$props.Start)" }   # драйвери 0/1 — ми їх не чіпаємо
    }
}

function Get-D9ServiceState {
    param([Parameter(Mandatory)]$Action)
    $svc = Get-Service -Name $Action.name -ErrorAction SilentlyContinue
    if (-not $svc) { return [ordered]@{ exists = $false } }
    return [ordered]@{ exists = $true; startup = (Get-D9ServiceStartup $Action.name); status = [string]$svc.Status }
}

# $null = служби немає в системі (не застосовно)
function Test-D9Service {
    param([Parameter(Mandatory)]$Action)
    $state = Get-D9ServiceState $Action
    if (-not $state.exists) { return $null }
    if ($Action.start -and $state.status -ne 'Running') { return $false }
    return $state.startup -eq $Action.startup
}

function Set-D9ServiceStartup {
    param([string]$Name, [string]$Startup)
    $mode = $script:D9ServiceStartup[$Startup]
    if (-not $mode) { throw (T-D9 'Невідомий тип запуску: {0}' "$Startup") }
    $output = & sc.exe config "$Name" start= $mode 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config $Name start= $mode : $output" }
}

function Invoke-D9Service {
    param([Parameter(Mandatory)]$Action)
    if (-not (Get-Service -Name $Action.name -ErrorAction SilentlyContinue)) { return }
    # Спочатку тип запуску, потім зупинка — щоб служба не піднялась знову
    Set-D9ServiceStartup $Action.name $Action.startup
    if ($Action.stop) { Stop-Service -Name $Action.name -Force -ErrorAction SilentlyContinue }
    if ($Action.start) { Start-Service -Name $Action.name -ErrorAction Stop }
}

function Restore-D9Service {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Before)
    if (-not $Before.exists) { return }
    if ($script:D9ServiceStartup.ContainsKey([string]$Before.startup)) {
        Set-D9ServiceStartup $Action.name $Before.startup
    }
    if ($Before.status -eq 'Running') { Start-Service -Name $Action.name -ErrorAction SilentlyContinue }
    elseif ($Action.start) { Stop-Service -Name $Action.name -Force -ErrorAction SilentlyContinue }   # ми її запустили — зупиняємо
}

function Get-D9ServiceDescription {
    param([Parameter(Mandatory)]$Action, $State)
    if ($State -and -not $State.exists) { return (T-D9 'Служба {0}: немає в системі' "$($Action.name)") }
    $old = if ($State) { $State.startup } else { '?' }
    $stop = if ($Action.stop) { (T-D9 ', зупинити') } elseif ($Action.start) { (T-D9 ', запустити') } else { '' }
    return (T-D9 'Служба {0}: {1} -> {2}{3}' "$($Action.name)" "$old" "$($Action.startup)" $stop)
}
