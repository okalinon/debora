# Журнал сесій: знімки стану до/після кожної дії. З нього працює відкат.
# Розташування: %ProgramData%\Debloater9\sessions (перевизначається змінною D9_DATA_ROOT — для тестів).

function Get-D9DataRoot {
    if ($env:D9_DATA_ROOT) { return $env:D9_DATA_ROOT }
    return (Join-Path $env:ProgramData 'Debloater9')
}

function Get-D9SessionDir {
    $dir = Join-Path (Get-D9DataRoot) 'sessions'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function New-D9Session {
    param([string]$Selection, $SystemInfo)
    $id = "{0:yyyy-MM-ddTHH-mm-ss}-{1}" -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $session = [pscustomobject]@{
        id           = $id
        started      = (Get-Date).ToString('s')
        machine      = $env:COMPUTERNAME
        os           = if ($SystemInfo) { "$($SystemInfo.OsName) $($SystemInfo.DisplayVersion) ($($SystemInfo.Build))" } else { $null }
        selection    = $Selection
        restorePoint = $null
        entries      = New-Object System.Collections.ArrayList
        undo         = New-Object System.Collections.ArrayList
    }
    Save-D9Session $session
    return $session
}

function Save-D9Session {
    param([Parameter(Mandatory)]$Session)
    $path = Join-Path (Get-D9SessionDir) "$($Session.id).json"
    $json = ConvertTo-Json -InputObject $Session -Depth 12
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
}

function Add-D9JournalEntry {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Entry)
    [void]$Session.entries.Add($Entry)
    Save-D9Session $Session   # після кожної дії — щоб журнал пережив збій чи вимкнення
}

function Get-D9Session {
    param([Parameter(Mandatory)][string]$Id)
    $path = Join-Path (Get-D9SessionDir) "$Id.json"
    if (-not (Test-Path $path)) { throw "Сесію '$Id' не знайдено" }
    $s = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
    # Повертаємо масиви як ArrayList, щоб до сесії можна було дописувати
    $s.entries = New-Object System.Collections.ArrayList (, @($s.entries | Where-Object { $_ }))
    $s.undo    = New-Object System.Collections.ArrayList (, @($s.undo | Where-Object { $_ }))
    return $s
}

function Get-D9SessionList {
    Get-ChildItem (Get-D9SessionDir) -Filter '*.json' | Sort-Object Name -Descending | ForEach-Object {
        $s = ConvertFrom-Json ([IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8))
        $entries = @($s.entries | Where-Object { $_ })
        [pscustomobject]@{
            Id        = $s.id
            Started   = $s.started
            Selection = $s.selection
            Changed   = @($entries | Where-Object result -eq 'ok').Count
            Errors    = @($entries | Where-Object result -eq 'error').Count
            Undone    = @($s.undo | Where-Object { $_ }).Count -gt 0
        }
    }
}
