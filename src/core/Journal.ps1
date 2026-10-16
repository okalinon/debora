# Журнал сесій: знімки стану до/після кожної дії. З нього працює відкат.
# Розташування: %ProgramData%\Debora\sessions (перевизначається змінною D9_DATA_ROOT — для тестів).
# До 1.0.2 дані лежали в старій папці %ProgramData%\Debloater9: перший запуск від адміністратора переносить їх
# (Move-D9LegacyDataRoot), без прав адміністратора програма працює зі старою папкою, доки її не перенесено.

$script:D9LegacyDataName = 'Debloater9'

function Get-D9DataRoot {
    if ($env:D9_DATA_ROOT) { return $env:D9_DATA_ROOT }
    if (-not $script:D9DataRootPath) { $script:D9DataRootPath = Resolve-D9DataRoot -ProgramData $env:ProgramData -IsAdmin (Test-D9IsAdmin) }
    return $script:D9DataRootPath
}

function Resolve-D9DataRoot {
    param([Parameter(Mandatory)][string]$ProgramData, [bool]$IsAdmin)
    $new = Join-Path $ProgramData 'Debora'
    $old = Join-Path $ProgramData $script:D9LegacyDataName
    if (-not (Test-Path -LiteralPath $old)) { return $new }
    if ($IsAdmin) {
        try { if (Move-D9LegacyDataRoot -Old $old -New $new) { return $new } } catch { }
    }
    if (Test-Path -LiteralPath $new) {
        # Обидві папки: перенесення не завершилось — працюємо там, де журнал сесій
        if (Test-Path -LiteralPath (Join-Path $old 'sessions')) { return $old }
        return $new
    }
    return $old
}

# Переносить стару папку даних у нову й виправляє в ній абсолютні шляхи (журнал відкату посилається на
# резервні копії драйверів і реєстру), а також у завданні розкладу й RunOnce майстра. Якщо завдання не вдалось
# оновити — на старому місці лишається з'єднання (junction), щоб воно й далі працювало. $true — дані в новій папці.
function Move-D9LegacyDataRoot {
    param([Parameter(Mandatory)][string]$Old, [Parameter(Mandatory)][string]$New,
          [string]$TaskName = 'Debora Maintenance', [string]$RunOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
          [string]$PowerKey = 'HKLM:\SOFTWARE\Debloater9', [string]$PowerNewKey = 'HKLM:\SOFTWARE\Debora')
    $item = Get-Item -LiteralPath $Old -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return (Test-Path -LiteralPath $New) }
    if (Test-Path -LiteralPath $New) {
        Merge-D9Folder -Source $Old -Destination $New   # збій переміщення — виняток, стара папка лишається
        [IO.Directory]::Delete($Old, $true)
    } else {
        [IO.Directory]::Move($Old, $New)
    }
    $count = Update-D9LegacyPaths -Root $New
    $linked = $false
    if (-not (Update-D9LegacyTaskPath -TaskName $TaskName -New $New)) {
        try { New-Item -ItemType Junction -Path $Old -Target $New -ErrorAction Stop | Out-Null; $linked = $true } catch { }
    }
    # Копія для розкладу — стара версія, що знову створила б стару папку: замінюємо поточною (лише зібраною)
    $app = Join-Path $New 'app\Debora.ps1'
    if ((Test-Path -LiteralPath $app) -and "$script:D9ScriptPath" -like '*\Debora.ps1' -and (Get-Command Install-D9AppCopy -ErrorAction SilentlyContinue)) {
        try { [void](Install-D9AppCopy -SourceScript $script:D9ScriptPath) } catch { }
    }
    Update-D9LegacyRunOnce -Key $RunOnceKey
    Move-D9LegacyPowerKey -OldKey $PowerKey -NewKey $PowerNewKey
    try { Write-D9LogFileLine "Дані перенесено: $Old → $New (файлів із виправленими шляхами: $count$(if ($linked) { ', залишено зʼєднання' }))" 'Info' } catch { }
    return $true
}

function Merge-D9Folder {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    foreach ($child in Get-ChildItem -LiteralPath $Source -Force) {
        $target = Join-Path $Destination $child.Name
        if (-not (Test-Path -LiteralPath $target)) {
            if ($child.PSIsContainer) { [IO.Directory]::Move($child.FullName, $target) } else { [IO.File]::Move($child.FullName, $target) }
        } elseif ($child.PSIsContainer) {
            Merge-D9Folder -Source $child.FullName -Destination $target
        } elseif ($child.LastWriteTimeUtc -gt (Get-Item -LiteralPath $target -Force).LastWriteTimeUtc) {
            [IO.File]::Copy($child.FullName, $target, $true)   # файл є в обох місцях — лишається новіший
        }
    }
}

function ConvertTo-D9NewDataPath {
    param([string]$Text)
    # І звичайний шлях, і екранований у JSON (\\)
    return [regex]::Replace($Text, '(?i)(ProgramData\\{1,2})' + [regex]::Escape($script:D9LegacyDataName) + '(?=\\|"|\s|$)', '${1}Debora')
}

function Update-D9LegacyPaths {
    param([Parameter(Mandatory)][string]$Root)
    $count = 0
    foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue) {
        try {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            $text = [Text.Encoding]::UTF8.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
            $fixed = ConvertTo-D9NewDataPath $text
            if ($fixed -ne $text) {
                [IO.File]::WriteAllText($f.FullName, $fixed, (New-Object Text.UTF8Encoding $bom))
                $count++
            }
        } catch { }
    }
    return $count
}

# Завдання «Debora Maintenance» запускає копію програми з папки даних: шлях у дії — на нове місце.
# $true — завдання немає або оновлено.
function Update-D9LegacyTaskPath {
    param([string]$TaskName, [string]$New)
    try {
        $folder = (New-Object -ComObject Schedule.Service)
        $folder.Connect()
        $root = $folder.GetFolder('\')
        $task = try { $root.GetTask($TaskName) } catch { $null }
        if (-not $task) { return $true }
        $def = $task.Definition
        $changed = $false
        foreach ($a in @($def.Actions)) {
            if ($a.Type -ne 0) { continue }
            $args2 = ConvertTo-D9NewDataPath $a.Arguments
            if ($args2 -ne $a.Arguments) { $a.Arguments = $args2; $changed = $true }
        }
        if (-not $changed) { return $true }
        # 6 = створити або оновити; 3 = від імені користувача з інтерактивним маркером (як і реєструє розклад)
        [void]$root.RegisterTaskDefinition($TaskName, $def, 6, $null, $null, 3)
        return $true
    } catch { return $false }
}

function Update-D9LegacyRunOnce {
    param([string]$Key)
    try {
        $props = Get-ItemProperty -Path $Key -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*' -or $p.Value -isnot [string]) { continue }
            $v = ConvertTo-D9NewDataPath $p.Value
            if ($v -ne $p.Value) { Set-ItemProperty -Path $Key -Name $p.Name -Value $v }
        }
    } catch { }
}

# Позначки копій схем живлення (PowerCfg.ps1): стара гілка HKLM:\SOFTWARE\Debloater9 → HKLM:\SOFTWARE\Debora
function Move-D9LegacyPowerKey {
    param([string]$OldKey, [string]$NewKey = 'HKLM:\SOFTWARE\Debora')
    try {
        $src = Join-Path $OldKey 'PowerSchemes'
        if (Test-Path $src) {
            $dst = Join-Path $NewKey 'PowerSchemes'
            if (-not (Test-Path $dst)) { New-Item -Path $dst -Force -ErrorAction Stop | Out-Null }
            $props = Get-ItemProperty -Path $src
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                if ($null -eq (Get-ItemProperty -Path $dst -Name $p.Name -ErrorAction SilentlyContinue)) { Set-ItemProperty -Path $dst -Name $p.Name -Value $p.Value -ErrorAction Stop }
            }
        }
        if (Test-Path $OldKey) { & reg.exe delete ($OldKey -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU') /f 2>$null | Out-Null }
    } catch { }
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
