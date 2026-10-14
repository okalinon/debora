# Стеження після оновлень Windows: те, що людина застосувала через Debora й не відкотила, має лишатися.
# Великі й накопичувальні оновлення Windows часто повертають Copilot, рекламу, застосунки, політики й служби —
# Debora знаходить такі зміни за журналом (src/core/Journal.ps1) і повертає їх тим самим рушієм (з журналом і відкатом).
#
# Що вважається «бажаним станом»: дії із записів журналу з результатом ok / alreadyApplied, у хронологічному
# порядку; відкат (будь-який запис undo) знімає дію з нагляду. Разові дії (command — очищення, driver — драйвери)
# не відстежуються; для служб — лише тип запуску (запуск/зупинка — разова подія, служби зупиняються самі).
# Зміни, які людина вирішила не повертати, — у guard-ignore.json; стан останньої перевірки — у guard.json.

$script:D9GuardSkipTypes = @('command', 'driver')

# Ключ дії: однакова дія з різних сесій — один запис нагляду
function Get-D9GuardActionKey {
    param([Parameter(Mandatory)]$Action)
    ConvertTo-Json -InputObject $Action -Compress -Depth 6
}

# Дія для перевірки й повернення: у служби — лише тип запуску
function ConvertTo-D9GuardAction {
    param([Parameter(Mandatory)]$Action)
    if ([string]$Action.type -ne 'service') { return $Action }
    $copy = [ordered]@{}
    foreach ($p in $Action.PSObject.Properties) { if ($p.Name -notin 'start', 'stop') { $copy[$p.Name] = $p.Value } }
    [pscustomobject]$copy
}

function Get-D9GuardIgnorePath { Join-Path (Get-D9DataRoot) 'guard-ignore.json' }

function Get-D9GuardIgnore {
    $path = Get-D9GuardIgnorePath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { @(ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) | Where-Object { $_.key }) } catch { @() }
}

# «Більше не повертати»: зміни, які людина свідомо лишає такими, як їх зробила Windows
function Add-D9GuardIgnore {
    param([Parameter(Mandatory)][object[]]$Items)
    $list = New-Object System.Collections.ArrayList
    foreach ($i in @(Get-D9GuardIgnore)) { [void]$list.Add($i) }
    $known = @($list | ForEach-Object { [string]$_.key })
    foreach ($i in $Items) {
        if ($known -contains [string]$i.Key) { continue }
        [void]$list.Add([pscustomobject]@{ key = [string]$i.Key; tweak = [string]$i.Tweak; what = [string]$i.Text; at = (Get-Date).ToString('s') })
    }
    $root = Get-D9DataRoot
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    [IO.File]::WriteAllText((Get-D9GuardIgnorePath), (ConvertTo-Json -InputObject @($list) -Depth 4), (New-Object Text.UTF8Encoding $false))
}

function Clear-D9GuardIgnore {
    $path = Get-D9GuardIgnorePath
    if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
}

# Бажаний стан за журналом: { Key; Tweak; Action (для перевірки); Original (як у журналі); Session; Time }
function Get-D9GuardDesired {
    $events = New-Object System.Collections.ArrayList
    foreach ($f in Get-ChildItem (Get-D9SessionDir) -Filter '*.json' -ErrorAction SilentlyContinue) {
        $s = try { ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)) } catch { $null }
        if (-not $s) { continue }
        foreach ($e in @($s.entries | Where-Object { $_ })) {
            if ([string]$e.result -notin 'ok', 'alreadyApplied' -or $e.partial -or -not $e.action) { continue }
            if ($script:D9GuardSkipTypes -contains [string]$e.action.type) { continue }
            $time = if ($e.time) { [string]$e.time } else { [string]$s.started }
            [void]$events.Add([pscustomobject]@{ Kind = 'apply'; Time = $time; Tweak = [string]$e.tweak; Action = $e.action; Session = [string]$s.id })
        }
        foreach ($u in @($s.undo | Where-Object { $_ -and $_.action })) {
            [void]$events.Add([pscustomobject]@{ Kind = 'undo'; Time = $(if ($u.time) { [string]$u.time } else { [string]$s.started }); Tweak = [string]$u.tweak; Action = $u.action; Session = [string]$s.id })
        }
    }
    $desired = [ordered]@{}
    foreach ($ev in @($events | Sort-Object Time, @{ Expression = { if ($_.Kind -eq 'apply') { 0 } else { 1 } } })) {
        $key = Get-D9GuardActionKey $ev.Action
        if ($ev.Kind -eq 'undo') { $desired.Remove($key); continue }
        $desired[$key] = [pscustomobject]@{ Key = $key; Tweak = $ev.Tweak; Action = (ConvertTo-D9GuardAction $ev.Action); Original = $ev.Action; Session = $ev.Session; Time = $ev.Time }
    }
    $ignored = @(Get-D9GuardIgnore | ForEach-Object { [string]$_.key })
    @($desired.Values | Where-Object { $ignored -notcontains $_.Key })
}

# Людська назва зміни: назва твіка з каталогу, інакше — опис самої дії
function Get-D9GuardItemName {
    param([string]$Tweak, $Catalog)
    if ($Tweak -like 'fix:*') { return $Tweak.Substring(4) }
    if ($Tweak -like 'startup.*') { return (T-D9 'Автозавантаження') }
    if ($Catalog -and $Tweak) { $t = try { Get-D9Tweak $Catalog $Tweak } catch { $null }; if ($t -and $t.name) { return (Get-D9Text $t.name) } }
    return $null
}

# Що Windows повернула: дії з бажаного стану, перевірка яких тепер дає «не застосовано».
# Стан «невідомо» ($null: служби чи застосунку немає, бракує прав) поверненням не вважаємо.
function Find-D9GuardDrift {
    param($Catalog, [object[]]$Desired)
    if ($null -eq $Desired) { $Desired = @(Get-D9GuardDesired) }
    foreach ($d in $Desired) {
        $ok = try { Invoke-D9ActionVerb Test $d.Action } catch { $null }
        if ($ok -ne $false) { continue }
        $current = try { Invoke-D9ActionVerb State $d.Action } catch { $null }
        $what = try { Invoke-D9ActionVerb Describe $d.Action -State $current } catch { [string]$d.Action.type }
        $what = $what -replace '-S-1-5-21-[\d-]+', ''   # ідентифікатор користувача в назвах завдань («OneDrive Startup Task-S-1-5-21-…»)
        $name = Get-D9GuardItemName $d.Tweak $Catalog
        [pscustomobject]@{
            Key = $d.Key; Tweak = $d.Tweak; Action = $d.Action; Session = $d.Session; Name = $name; What = $what
            Text = $(if ($name) { "$name — $what" } else { $what })
        }
    }
}

# Повернути вибране: окремою сесією журналу (її можна відкотити, як і будь-яку іншу)
function Restore-D9GuardDrift {
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)]$SystemInfo, [switch]$NoRestorePoint)
    $plan = foreach ($g in @($Items | Group-Object Tweak)) {
        $first = $g.Group[0]
        $tw = [pscustomobject]@{ id = [string]$g.Name; name = $(if ($first.Name) { $first.Name } else { [string]$g.Name }); actions = @($g.Group | ForEach-Object { $_.Action }) }
        [pscustomobject]@{ Id = [string]$g.Name; Tweak = $tw; Run = $true; Reason = $null }
    }
    $session = Invoke-D9Plan -Plan @($plan) -SystemInfo $SystemInfo -Selection (T-D9 'Повернення змін, скасованих Windows ({0})' @($Items).Count) -NoRestorePoint:$NoRestorePoint
    $fixed = @($session.entries | Where-Object { $_.result -in 'ok', 'alreadyApplied' }).Count
    $failed = @($session.entries | Where-Object { $_.result -eq 'error' }).Count
    Save-D9GuardStatus -SystemInfo $SystemInfo -Drift ([math]::Max(0, @($Items).Count - $fixed))
    [pscustomobject]@{ Session = $session; Fixed = $fixed; Failed = $failed }
}

# ---------- Коли перевіряти ----------
function Get-D9GuardStatusPath { Join-Path (Get-D9DataRoot) 'guard.json' }

function Get-D9GuardStatus {
    $path = Get-D9GuardStatusPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) } catch { $null }
}

function Save-D9GuardStatus {
    param([Parameter(Mandatory)]$SystemInfo, [int]$Drift)
    $root = Get-D9DataRoot
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $s = [ordered]@{ build = [string]$SystemInfo.Build; version = [string]$SystemInfo.DisplayVersion; checked = (Get-Date).ToString('s'); drift = $Drift }
    [IO.File]::WriteAllText((Get-D9GuardStatusPath), (ConvertTo-Json $s), (New-Object Text.UTF8Encoding $false))
}

# Перевірка потрібна: змінилась збірка Windows (було оновлення) або минуло понад $Hours годин
function Test-D9GuardDue {
    param([Parameter(Mandatory)]$SystemInfo, [int]$Hours = 20, [datetime]$Now = (Get-Date))
    $s = Get-D9GuardStatus
    if (-not $s) { return $true }
    if ([string]$s.build -ne [string]$SystemInfo.Build) { return $true }
    $at = try { [datetime]$s.checked } catch { [datetime]::MinValue }
    return ($Now - $at).TotalHours -ge $Hours
}

# Крок обслуговування й «Виправити» у знахідці сканера: повернути все, що Windows скасувала (крім «не повертати»)
function Invoke-D9GuardRestoreStep {
    $sys = Get-D9SystemInfo -UseCache
    $items = @(Find-D9GuardDrift -Catalog (Import-D9Catalog))
    if (-not $items) {
        Save-D9GuardStatus -SystemInfo $sys -Drift 0
        Write-D9Log (T-D9 'Усі ваші зміни на місці — Windows нічого не повернула.') Ok
        return [pscustomobject]@{ Done = $true; RebootRecommended = $false; Fixed = 0 }
    }
    Write-D9Log (T-D9 'Windows скасувала змін: {0}. Повертаю...' $items.Count)
    foreach ($i in $items) { Write-D9Log "  $($i.Text)" Detail }
    $r = Restore-D9GuardDrift -Items $items -SystemInfo $sys -NoRestorePoint
    Write-D9Log (T-D9 'Повернуто: {0} з {1}.' $r.Fixed $items.Count) $(if ($r.Failed) { 'Warn' } else { 'Ok' })
    [pscustomobject]@{ Done = ($r.Failed -eq 0); RebootRecommended = $false; Fixed = $r.Fixed }
}
