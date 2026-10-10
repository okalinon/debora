# Дія "scheduledTask": вмикання / вимикання запланованого завдання.
#   { "type": "scheduledTask", "path": "\\Microsoft\\Windows\\Autochk\\Proxy", "state": "Disabled" }
# Через COM Schedule.Service: Get-ScheduledTask (CIM) витрачає ~1,3 с на кожне завдання.

$script:D9TaskService = $null

function Get-D9TaskService {
    if (-not $script:D9TaskService) {
        $script:D9TaskService = New-Object -ComObject Schedule.Service
        $script:D9TaskService.Connect()
    }
    return $script:D9TaskService
}

function Get-D9RegisteredTask {
    param([string]$Path)
    $index = $Path.LastIndexOf('\')
    $folderPath = if ($index -le 0) { '\' } else { $Path.Substring(0, $index) }
    try {
        $folder = (Get-D9TaskService).GetFolder($folderPath)
        return $folder.GetTask($Path.Substring($index + 1))
    } catch { return $null }
}

function Get-D9ScheduledTaskState {
    param([Parameter(Mandatory)]$Action)
    $task = Get-D9RegisteredTask $Action.path
    if (-not $task) { return [ordered]@{ exists = $false } }
    $state = if ($task.Enabled) { 'Enabled' } else { 'Disabled' }
    return [ordered]@{ exists = $true; state = $state }
}

function Test-D9ScheduledTask {
    param([Parameter(Mandatory)]$Action)
    $state = Get-D9ScheduledTaskState $Action
    if (-not $state.exists) { return $null }
    return $state.state -eq $Action.state
}

function Set-D9ScheduledTaskState {
    param([string]$Path, [string]$State)
    $task = Get-D9RegisteredTask $Path
    if (-not $task) { throw "Завдання не знайдено: $Path" }
    try { $task.Enabled = ($State -eq 'Enabled') }
    catch { throw "Не вдалося змінити завдання $Path (потрібні права адміністратора?): $($_.Exception.Message)" }
}

function Invoke-D9ScheduledTask {
    param([Parameter(Mandatory)]$Action)
    if (-not (Get-D9ScheduledTaskState $Action).exists) { return }
    Set-D9ScheduledTaskState $Action.path $Action.state
}

function Restore-D9ScheduledTask {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Before)
    if ($Before.exists) { Set-D9ScheduledTaskState $Action.path $Before.state }
}

function Get-D9ScheduledTaskDescription {
    param([Parameter(Mandatory)]$Action, $State)
    if ($State -and -not $State.exists) { return "Завдання $($Action.path): немає в системі" }
    $old = if ($State) { $State.state } else { '?' }
    return "Завдання $($Action.path): $old -> $($Action.state)"
}
