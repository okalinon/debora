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
    if (-not (Test-Path $path)) { throw (T-D9 'Сесію ''{0}'' не знайдено' $Id) }
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

# Людська назва сесії (старі сесії мали службовий префікс «checklist: »)
function Format-D9SessionSelection {
    param([string]$Selection)
    if ($Selection -like 'checklist: *') { return (T-D9 'Виправлення: {0}' $Selection.Substring(11)) }
    $Selection
}

# Що саме змінила сесія: рядок на кожну дію (✓ / ✗ з причиною / пропущено). Для «Журналу змін».
function Get-D9SessionDetails {
    param([Parameter(Mandatory)][string]$Id, $Catalog)
    $file = Get-ChildItem (Get-D9SessionDir) -Filter '*.json' | Where-Object { $_.BaseName -eq $Id -or $_.Name -like "$Id*" } | Select-Object -First 1
    if (-not $file) { return @() }
    $s = ConvertFrom-Json ([IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8))
    foreach ($e in @($s.entries | Where-Object { $_ })) {
        $tw = if ($Catalog -and $e.tweak) { Get-D9Tweak $Catalog ([string]$e.tweak) } else { $null }
        $name = if ($tw) { Get-D9Text $tw.name } elseif ("$($e.tweak)" -like 'fix:*') { "$($e.tweak)".Substring(4) } else { [string]$e.tweak }
        $a = $e.action
        $what = if ($a.label) { Get-D9Text $a.label } else {
            switch ([string]$a.type) {
                'registry'      { "$($a.path)\$($a.name) = $($a.value)" }
                'service'       { T-D9 'служба {0}: {1}' $a.name $(if ($a.startup) { $a.startup } else { 'stop' }) }
                'appx'          { T-D9 'застосунок {0}' $a.package }
                'scheduledTask' { T-D9 'завдання {0}' $a.path }
                default         { [string]$a.type }
            }
        }
        $mark = switch ([string]$e.result) { 'ok' { '✓' } 'error' { '✗' } default { '·' } }
        $line = "$mark $name — $what"
        if ($e.result -eq 'error' -and $e.message) { $line += '  ' + (T-D9 '(помилка: {0})' $e.message) }
        elseif ($e.result -notin 'ok', 'error' -and $e.result) { $line += '  ' + (T-D9 '({0})' $e.result) }
        $line
    }
}

# ---------- Історія тривалості операцій (оцінка «минулого разу ≈ …» на панелі «Зараз виконується») ----------
# durations.json: ключ операції → останні 5 тривалостей у секундах. Оцінка — медіана.
function Get-D9DurationsPath { Join-Path (Get-D9DataRoot) 'durations.json' }

function Get-D9Durations {
    $h = @{}
    $p = Get-D9DurationsPath
    if (Test-Path $p) {
        try { $j = ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)); foreach ($x in $j.PSObject.Properties) { $h[$x.Name] = @($x.Value | ForEach-Object { [double]$_ }) } } catch { }
    }
    $h
}

function Add-D9Duration {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][double]$Seconds)
    if ($Seconds -lt 3) { return }      # миттєві операції оцінки не потребують
    $h = Get-D9Durations
    $h[$Key] = @(@($h[$Key]) + [math]::Round($Seconds) | Where-Object { $_ } | Select-Object -Last 5)
    $p = Get-D9DurationsPath
    try {
        $dir = Split-Path $p; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($p, (ConvertTo-Json ([pscustomobject]$h) -Depth 3), (New-Object Text.UTF8Encoding $false))
    } catch { }
}

function Get-D9DurationEstimate {
    param([string]$Key, [hashtable]$Durations)
    if (-not $Key) { return $null }
    if (-not $Durations) { $Durations = Get-D9Durations }
    $v = @($Durations[$Key] | Where-Object { $_ } | Sort-Object)
    if (-not $v.Count) { return $null }
    [double]$v[[math]::Floor(($v.Count - 1) / 2)]
}

# Текст оцінки під шкалою. Правило: якщо операція вже виконувалась — фактична тривалість минулого разу, округлена
# («минулого разу ≈ 60 хв · лишилось ≈ 35 хв»); якщо ні — верхня межа ($Typical, напр. «до 20 хв»), без вигаданих точних цифр.
function Format-D9EtaText {
    param([double]$ElapsedSec, [double]$EstimateSec, [string]$Typical)
    if ($EstimateSec -gt 0) {
        $t = T-D9 'минулого разу ≈ {0}' (Format-D9ApproxDuration ([TimeSpan]::FromSeconds($EstimateSec)))
        $left = $EstimateSec - $ElapsedSec
        if ($left -ge 120) { return ($t + ' · ' + (T-D9 'лишилось ≈ {0}' (Format-D9ApproxDuration ([TimeSpan]::FromSeconds($left))))) }
        if ($ElapsedSec -gt $EstimateSec * 1.15 + 30) { return ($t + ' · ' + (T-D9 'цього разу довше')) }
        return ($t + ' · ' + (T-D9 'майже готово'))
    }
    if ($Typical) { return (T-D9 'зазвичай {0}' $Typical) }
    ''
}
