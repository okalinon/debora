# Дія "command": довільний PowerShell-код — лише коли типізовані дії не підходять.
#   { "type": "command", "run": "...", "undoRun": "...", "test": "...", "label": { "uk": "...", "en": "..." } }
# test — вираз, що повертає $true, якщо вже застосовано (необов'язково).
# Без undoRun дозволено лише у твіках з "irreversible": true.

function Invoke-D9Script {
    param([string]$Code)
    & ([scriptblock]::Create($Code))
}

function Get-D9CommandState {
    param([Parameter(Mandatory)]$Action)
    return [ordered]@{}
}

function Test-D9Command {
    param([Parameter(Mandatory)]$Action)
    if (-not $Action.test) { return $null }
    return [bool](Invoke-D9Script $Action.test)
}

function Invoke-D9Command {
    param([Parameter(Mandatory)]$Action)
    Invoke-D9Script $Action.run | Out-Null
}

function Restore-D9Command {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Before)
    if (-not $Action.undoRun) { return "Цю дію не можна відкотити" }
    Invoke-D9Script $Action.undoRun | Out-Null
}

function Get-D9CommandDescription {
    param([Parameter(Mandatory)]$Action, $State)
    $label = Get-D9Text $Action.label
    if ($label) { return "Команда: $label" }
    return "Команда PowerShell"
}
