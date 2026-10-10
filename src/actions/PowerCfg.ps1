# Дія "powercfg": схема живлення або гібернація (одне з двох в одній дії).
#   { "type": "powercfg", "scheme": "high" }      # high | balanced | ultimate | saver | GUID
#   { "type": "powercfg", "hibernate": false }
# Якщо схема прихована (часто на Windows 11), створюємо її копію й запам'ятовуємо
# GUID копії в HKLM:\SOFTWARE\Debloater9\PowerSchemes, щоб потім розпізнати.

$script:D9PowerSchemes = @{
    high     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    saver    = 'a1841308-3541-4fab-bc81-f71556f20b4a'
}
$script:D9PowerMarkerKey = 'HKLM:\SOFTWARE\Debloater9\PowerSchemes'

function Resolve-D9PowerScheme {
    param([string]$Scheme)
    if ($script:D9PowerSchemes.ContainsKey($Scheme)) { return $script:D9PowerSchemes[$Scheme] }
    if ($Scheme -match '^[0-9a-fA-F-]{36}$') { return $Scheme.ToLower() }
    throw (T-D9 'Невідома схема живлення: {0}' "$Scheme")
}

function Get-D9ActivePowerScheme {
    $output = powercfg /getactivescheme
    if ("$output" -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { return $Matches[1].ToLower() }
    return $null
}

function Get-D9PowerSchemeCopy {
    param([string]$Guid)
    (Get-ItemProperty -Path $script:D9PowerMarkerKey -Name $Guid -ErrorAction SilentlyContinue).$Guid
}

function Get-D9PowerCfgState {
    param([Parameter(Mandatory)]$Action)
    if ($null -ne $Action.hibernate) {
        $enabled = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
        return [ordered]@{ hibernate = ($enabled -eq 1) }
    }
    return [ordered]@{ activeScheme = (Get-D9ActivePowerScheme) }
}

function Test-D9PowerCfg {
    param([Parameter(Mandatory)]$Action)
    $state = Get-D9PowerCfgState $Action
    if ($null -ne $Action.hibernate) { return $state.hibernate -eq [bool]$Action.hibernate }
    $target = Resolve-D9PowerScheme $Action.scheme
    return ($state.activeScheme -eq $target -or $state.activeScheme -eq (Get-D9PowerSchemeCopy $target))
}

function Invoke-D9PowerCfg {
    param([Parameter(Mandatory)]$Action)
    if ($null -ne $Action.hibernate) {
        $mode = if ($Action.hibernate) { 'on' } else { 'off' }
        powercfg /hibernate $mode | Out-Null
        if ($LASTEXITCODE -ne 0) { throw (T-D9 'powercfg /hibernate {0} завершився з кодом {1}' $mode "$LASTEXITCODE") }
        return
    }
    $target = Resolve-D9PowerScheme $Action.scheme
    $copy = Get-D9PowerSchemeCopy $target
    if ($copy) { powercfg /setactive $copy 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return } }
    powercfg /setactive $target 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return }
    $output = powercfg /duplicatescheme $target
    if ("$output" -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { throw (T-D9 'Не вдалося створити схему живлення {0}: {1}' "$($Action.scheme)" "$output") }
    $newGuid = $Matches[1].ToLower()
    powercfg /setactive $newGuid | Out-Null
    if (-not (Test-Path $script:D9PowerMarkerKey)) { New-Item -Path $script:D9PowerMarkerKey -Force | Out-Null }
    Set-ItemProperty -Path $script:D9PowerMarkerKey -Name $target -Value $newGuid
}

function Restore-D9PowerCfg {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Before)
    if ($null -ne $Action.hibernate) {
        $mode = if ($Before.hibernate) { 'on' } else { 'off' }
        powercfg /hibernate $mode | Out-Null
        return
    }
    if ($Before.activeScheme) { powercfg /setactive $Before.activeScheme | Out-Null }
}

function Get-D9PowerCfgDescription {
    param([Parameter(Mandatory)]$Action, $State)
    if ($null -ne $Action.hibernate) {
        $old = if ($State) { if ($State.hibernate) { (T-D9 'увімкнено') } else { (T-D9 'вимкнено') } } else { '?' }
        $new = if ($Action.hibernate) { (T-D9 'увімкнено') } else { (T-D9 'вимкнено') }
        return (T-D9 'Гібернація: {0} -> {1}' $old $new)
    }
    $old = if ($State) { $State.activeScheme } else { '?' }
    return (T-D9 'Схема живлення: {0} -> {1}' "$old" "$($Action.scheme)")
}
