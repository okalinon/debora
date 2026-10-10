# Рушій: стан твіків, план, попередній перегляд, виконання з журналом і відкат.

# Викликає функцію модуля дії: Get-D9<Type>State, Test-D9<Type>, Invoke-D9<Type>, Restore-D9<Type>, Get-D9<Type>Description
function Invoke-D9ActionVerb {
    param(
        [Parameter(Mandatory)][ValidateSet('State', 'Test', 'Invoke', 'Restore', 'Describe')][string]$Verb,
        [Parameter(Mandatory)]$Action,
        $Before,
        $State
    )
    $type = $script:D9ActionTypes[[string]$Action.type]
    if (-not $type) { throw "Невідомий тип дії: $($Action.type)" }
    switch ($Verb) {
        'State'    { & "Get-D9${type}State" -Action $Action }
        'Test'     { & "Test-D9$type" -Action $Action }
        'Invoke'   { & "Invoke-D9$type" -Action $Action }
        'Restore'  { & "Restore-D9$type" -Action $Action -Before $Before }
        'Describe' { & "Get-D9${type}Description" -Action $Action -State $State }
    }
}

# Дії твіка, придатні для цієї системи (у дії може бути власне поле requires)
function Get-D9ApplicableActions {
    param([Parameter(Mandatory)]$Tweak, [Parameter(Mandatory)]$SystemInfo)
    @($Tweak.actions | Where-Object { (Test-D9Applicable $_.requires $SystemInfo).Applicable })
}

# applied | partial | notApplied | notApplicable | unknown
function Get-D9TweakState {
    param([Parameter(Mandatory)]$Tweak, [Parameter(Mandatory)]$SystemInfo)
    if (-not (Test-D9Applicable $Tweak.requires $SystemInfo).Applicable) { return 'notApplicable' }
    $results = foreach ($a in (Get-D9ApplicableActions $Tweak $SystemInfo)) {
        try { Invoke-D9ActionVerb Test $a } catch { $null }
    }
    $known = @($results | Where-Object { $null -ne $_ })
    if ($known.Count -eq 0) { return 'unknown' }
    $applied = @($known | Where-Object { $_ -eq $true }).Count
    if ($applied -eq $known.Count) { return 'applied' }
    if ($applied -eq 0) { return 'notApplied' }
    return 'partial'
}

# План: які твіки буде виконано, а які пропущено і чому
function New-D9Plan {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string[]]$TweakIds, [Parameter(Mandatory)]$SystemInfo)
    $accepted = @()
    $items = foreach ($id in ($TweakIds | Select-Object -Unique)) {
        $tweak = Get-D9Tweak $Catalog $id
        if (-not $tweak) {
            [pscustomobject]@{ Id = $id; Tweak = $null; Run = $false; Reason = 'невідомий твік' }
            continue
        }
        $check = Test-D9Applicable $tweak.requires $SystemInfo
        $clash = @($tweak.conflicts) | Where-Object { $accepted -contains $_ } | Select-Object -First 1
        if ($check.Applicable -and $clash) {
            [pscustomobject]@{ Id = $id; Tweak = $tweak; Run = $false; Reason = "конфліктує з $clash" }
            continue
        }
        if ($check.Applicable) { $accepted += $id }
        [pscustomobject]@{ Id = $id; Tweak = $tweak; Run = $check.Applicable; Reason = $check.Reason }
    }
    return @($items)
}

function Get-D9Preview {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$SystemInfo)
    foreach ($item in $Plan) {
        if (-not $item.Run) {
            [pscustomobject]@{ Tweak = $item.Id; Change = "пропущено: $($item.Reason)"; Pending = $false }
            continue
        }
        foreach ($a in (Get-D9ApplicableActions $item.Tweak $SystemInfo)) {
            $state = try { Invoke-D9ActionVerb State $a } catch { $null }
            $done  = try { Invoke-D9ActionVerb Test $a } catch { $null }
            [pscustomobject]@{
                Tweak   = $item.Id
                Change  = (Invoke-D9ActionVerb Describe $a -State $state)
                Pending = ($done -ne $true)
            }
        }
    }
}

function New-D9RestorePoint {
    param([string]$Description = "Debloater9 $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = (Get-ItemProperty $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    try {
        # Windows за замовчуванням дозволяє одну точку на 24 години — тимчасово знімаємо обмеження
        Set-ItemProperty $key -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        return $Description
    } catch {
        return $null
    } finally {
        if ($null -eq $old) { Remove-ItemProperty $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $key -Name SystemRestorePointCreationFrequency -Value $old -Type DWord }
    }
}

# Виконує план. Кожна дія: знімок -> застосування -> перевірка -> запис у журнал.
function Invoke-D9Plan {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$SystemInfo,
        [string]$Selection = 'custom',
        [switch]$NoRestorePoint
    )
    $session = New-D9Session -Selection $Selection -SystemInfo $SystemInfo
    if (-not $NoRestorePoint) {
        Write-D9Log "Створення точки відновлення..."
        $session.restorePoint = New-D9RestorePoint
        if ($session.restorePoint) { Write-D9Log "  Точку відновлення створено" Ok }
        else { Write-D9Log "  Не вдалося створити точку відновлення (захист системи вимкнено?)" Warn }
        Save-D9Session $session
    }

    $runnable = @($Plan | Where-Object Run)
    $i = 0
    foreach ($item in $runnable) {
        $i++
        Write-D9Log ("[{0}/{1}] {2}" -f $i, $runnable.Count, (Get-D9Text $item.Tweak.name))
        foreach ($a in (Get-D9ApplicableActions $item.Tweak $SystemInfo)) {
            $entry = [ordered]@{ tweak = $item.Id; action = $a; before = $null; after = $null; result = $null; message = $null; time = (Get-Date).ToString('s') }
            try {
                $entry.before = Invoke-D9ActionVerb State $a
                $test = Invoke-D9ActionVerb Test $a
                if ($test -eq $true) {
                    $entry.result = 'alreadyApplied'
                } elseif (($a.type -in 'service', 'scheduledTask' -and -not $entry.before.exists) -or
                          ($a.type -eq 'registry' -and $a.ifKeyExists -and -not $entry.before.keyExists)) {
                    $entry.result = 'notPresent'
                } else {
                    Invoke-D9ActionVerb Invoke $a
                    $entry.after  = Invoke-D9ActionVerb State $a
                    $entry.result = 'ok'
                    Write-D9Log ("    " + (Invoke-D9ActionVerb Describe $a -State $entry.before)) Detail
                }
            } catch {
                $entry.result  = 'error'
                $entry.message = $_.Exception.Message
                Write-D9Log "    Помилка: $($_.Exception.Message)" Error
            }
            Add-D9JournalEntry $session ([pscustomobject]$entry)
        }
    }
    $session | Add-Member -NotePropertyName finished -NotePropertyValue (Get-Date).ToString('s') -Force
    Save-D9Session $session
    return $session
}

# Відкат сесії (або лише вказаних твіків) у зворотному порядку.
# Запис пропускається, якщо стан змінився після нас — щоб не затерти чужу зміну.
function Undo-D9Session {
    param([Parameter(Mandatory)][string]$Id, [string[]]$TweakIds)
    $session = Get-D9Session $Id
    $entries = @($session.entries | Where-Object { $_.result -eq 'ok' -and (-not $TweakIds -or $TweakIds -contains $_.tweak) })
    [array]::Reverse($entries)
    $report = foreach ($e in $entries) {
        $record = [ordered]@{ tweak = $e.tweak; action = $e.action; result = $null; message = $null; time = (Get-Date).ToString('s') }
        try {
            $current = Invoke-D9ActionVerb State $e.action
            if (-not (Test-D9StateEqual $current $e.after)) {
                $record.result  = 'conflict'
                $record.message = 'стан змінено після застосування — пропущено'
                Write-D9Log ("  Пропущено (змінено після нас): " + (Invoke-D9ActionVerb Describe $e.action -State $current)) Warn
            } else {
                $note = Invoke-D9ActionVerb Restore $e.action -Before $e.before
                $record.result  = if ($note) { 'manual' } else { 'restored' }
                $record.message = $note
                if ($note) { Write-D9Log "  $note" Warn } else { Write-D9Log ("  Відновлено: " + (Invoke-D9ActionVerb Describe $e.action -State $current)) Detail }
            }
        } catch {
            $record.result  = 'error'
            $record.message = $_.Exception.Message
            Write-D9Log "  Помилка відкату: $($_.Exception.Message)" Error
        }
        [void]$session.undo.Add([pscustomobject]$record)
        [pscustomobject]$record
    }
    Save-D9Session $session
    return @($report)
}
