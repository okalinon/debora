# Сканер: запуск проб, оцінка, збереження результатів.

$script:D9SeverityPenalty = @{ critical = 30; warning = 10; suggestion = 3; info = 0 }

function Import-D9ScanConfig {
    [pscustomobject]@{
        Checks     = ConvertFrom-Json (Get-D9ConfigText 'checks.json')
        Lifecycle  = ConvertFrom-Json (Get-D9ConfigText 'lifecycle.json')
        KnownBloat = ConvertFrom-Json (Get-D9ConfigText 'known-bloat.json')
    }
}

function New-D9ScanContext {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo, $ScanConfig, [switch]$Deep, [datetime]$Now = (Get-Date))
    if (-not $ScanConfig) { $ScanConfig = Import-D9ScanConfig }
    [pscustomobject]@{
        System         = $SystemInfo
        Catalog        = $Catalog
        Recommendation = Get-D9RecommendedPreset $SystemInfo
        Deep           = [bool]$Deep
        IsAdmin        = Test-D9IsAdmin
        Now            = $Now
        Lifecycle      = $ScanConfig.Lifecycle
        KnownBloat     = $ScanConfig.KnownBloat
        Config         = $ScanConfig.Checks
    }
}

# Оцінка: кожна категорія 100 мінус штрафи; загальна — зважене середнє;
# будь-яка критична знахідка обмежує загальну оцінку 59 балами.
function Get-D9ScanScore {
    param([Parameter(Mandatory)]$Categories, [object[]]$Findings, [string[]]$CheckedCategories)
    $scores = [ordered]@{}
    $sum = 0.0; $weights = 0.0
    foreach ($c in $Categories) {
        if ($CheckedCategories -notcontains $c.id) { continue }
        $penalty = (@($Findings | Where-Object { $_.category -eq $c.id -and $script:D9SeverityPenalty.ContainsKey($_.severity) }) |
            ForEach-Object { $script:D9SeverityPenalty[$_.severity] } | Measure-Object -Sum).Sum
        $score = [math]::Max(0, 100 - [int]$penalty)
        $scores[$c.id] = $score
        $sum += $score * $c.weight; $weights += $c.weight
    }
    $overall = if ($weights) { [int][math]::Round($sum / $weights) } else { 100 }
    if (@($Findings | Where-Object severity -eq 'critical').Count) { $overall = [math]::Min($overall, 59) }
    $verdict = if ($overall -ge 85) { 'good' } elseif ($overall -ge 60) { 'attention' } else { 'serious' }
    [pscustomobject]@{ overall = $overall; verdict = $verdict; categories = $scores }
}

# Скільки балів знахідка знімає з оцінки своєї категорії
function Get-D9FindingPenalty {
    param($Finding)
    $p = $script:D9SeverityPenalty[[string]$Finding.severity]
    if ($p) { [int]$p } else { 0 }
}

# Пояснення оцінки категорії: «100 − 50 = 50: критичних 1 × 30, попереджень 2 × 10.»
function Format-D9CategoryScoreExplain {
    param([object[]]$Findings, [Parameter(Mandatory)][string]$CategoryId)
    $f = @($Findings | Where-Object category -eq $CategoryId)
    $parts = @()
    foreach ($s in @(@('critical', 'критичних: {0} × {1}'), @('warning', 'попереджень: {0} × {1}'), @('suggestion', 'порад: {0} × {1}'))) {
        $n = @($f | Where-Object severity -eq $s[0]).Count
        if ($n) { $parts += T-D9 $s[1] $n $script:D9SeverityPenalty[$s[0]] }
    }
    $penalty = [int](($f | ForEach-Object { Get-D9FindingPenalty $_ } | Measure-Object -Sum).Sum)
    $text = if (-not $penalty) { T-D9 'Проблем, що знижують оцінку, не знайдено — 100 балів.' }
            else { T-D9 '100 − {0} = {1}: {2}.' $penalty ([math]::Max(0, 100 - $penalty)) ($parts -join ', ') }
    if ($penalty -gt 100) { $text += ' ' + (T-D9 'Оцінка не буває нижчою за 0.') }
    if (@($f | Where-Object severity -eq 'info').Count) { $text += ' ' + (T-D9 'Знахідки без числа праворуч — лише відомості, на оцінку не впливають.') }
    $text
}

# Виконання однієї проби: @{ ok; out; error; ms }
$script:D9ProbeRunner = {
    param($check, $ctx)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { @{ ok = $true; out = @(& $check.probe -Check $check -Ctx $ctx | Where-Object { $_ }); ms = [int]$sw.ElapsedMilliseconds } }
    catch { @{ ok = $false; error = $_.Exception.Message; ms = [int]$sw.ElapsedMilliseconds } }
}

# Проби переважно чекають на WMI, журнали подій і диск — паралельно в пулі runspace сканування в рази швидше.
# Кожен runspace отримує ті самі функції й дані D9*, як фонові завдання вікна. Повертає @{ id = результат }.
function Invoke-D9ProbesParallel {
    param([Parameter(Mandatory)][object[]]$Checks, [Parameter(Mandatory)]$Context, [int]$Threads = [math]::Max(3, [math]::Min(6, [Environment]::ProcessorCount)))
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in (Get-ChildItem function: | Where-Object { $_.Name -like '*-D9*' })) {
        $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry $f.Name, $f.Definition))
    }
    foreach ($v in (Get-Variable -Scope Script -Name 'D9*' -ErrorAction SilentlyContinue)) {
        if ($v.Name -in 'D9OnProgress', 'D9OnLog') { continue }   # колбеки вікна працюють лише у своєму потоці
        $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry $v.Name, $v.Value, ''))
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, $Threads, $iss, $Host)
    $pool.Open()
    $results = @{}
    try {
        $jobs = foreach ($c in $Checks) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($script:D9ProbeRunner.ToString()).AddArgument($c).AddArgument($Context)
            [pscustomobject]@{ Check = $c; PS = $ps; Handle = $ps.BeginInvoke() }
        }
        $done = 0
        while ($done -lt $jobs.Count) {
            foreach ($j in $jobs) {
                if ($results.ContainsKey($j.Check.id) -or -not $j.Handle.IsCompleted) { continue }
                $r = try { @($j.PS.EndInvoke($j.Handle))[0] } catch { @{ ok = $false; error = $_.Exception.Message; ms = 0 } }
                if (-not $r) { $r = @{ ok = $true; out = @(); ms = 0 } }
                $results[$j.Check.id] = $r
                $j.PS.Dispose()
                $done++
                Write-Progress -Activity (T-D9 'Debora: сканування') -Status "$done / $($jobs.Count): $(Get-D9Text $j.Check.name)" -PercentComplete ($done * 100 / $jobs.Count)
                if ($script:D9OnProgress) { & $script:D9OnProgress $done $jobs.Count (Get-D9Text $j.Check.name) }
            }
            if ($done -lt $jobs.Count) { Start-Sleep -Milliseconds 50 }
        }
    } finally { $pool.Close(); $pool.Dispose() }
    return $results
}

function Invoke-D9Scan {
    param([Parameter(Mandatory)]$Context, [string[]]$OnlyChecks, [switch]$Sequential)
    $results = New-Object System.Collections.ArrayList
    $findings = New-Object System.Collections.ArrayList
    $total = [Diagnostics.Stopwatch]::StartNew()

    $list = @($Context.Config.checks | Where-Object { -not $OnlyChecks -or $OnlyChecks -contains $_.id })
    # Що запускати: придатність, глибоке сканування, права
    $pre = @{}
    foreach ($check in $list) {
        $fit = if ($check.requires) { Test-D9Applicable $check.requires $Context.System } else { $null }
        if ($fit -and -not $fit.Applicable) { $pre[$check.id] = @('notApplicable', $fit.Reason) }
        elseif ($check.deep -and -not $Context.Deep) { $pre[$check.id] = @('notRun', (T-D9 'лише в глибокому скануванні')) }
        elseif ($check.adminOnly -and -not $Context.IsAdmin) { $pre[$check.id] = @('skipped', (T-D9 'потрібні права адміністратора')) }
    }
    $run = @($list | Where-Object { -not $pre.ContainsKey($_.id) })
    $outputs = $null
    if (-not $Sequential -and $run.Count -ge 8) {
        try { $outputs = Invoke-D9ProbesParallel -Checks $run -Context $Context }
        catch { Write-D9Log (T-D9 'Паралельне сканування недоступне ({0}) — виконую послідовно.' $_.Exception.Message) Detail; $outputs = $null }
    }
    if (-not $outputs) {
        $outputs = @{}; $n = 0
        $runner = [scriptblock]::Create($script:D9ProbeRunner.ToString())   # прив'язка до поточного runspace (у вікні це фоновий потік)
        foreach ($check in $run) {
            $n++
            Write-Progress -Activity (T-D9 'Debora: сканування') -Status "$n / $($run.Count): $(Get-D9Text $check.name)" -PercentComplete ($n * 100 / $run.Count)
            if ($script:D9OnProgress) { & $script:D9OnProgress $n $run.Count (Get-D9Text $check.name) }
            $outputs[$check.id] = & $runner $check $Context
        }
    }

    foreach ($check in $list) {
        $status = 'ok'; $note = $null; $ms = 0
        if ($pre.ContainsKey($check.id)) { $status, $note = $pre[$check.id] }
        else {
            $r = $outputs[$check.id]; $ms = [int]$r.ms
            if (-not $r.ok) { $status = 'error'; $note = $r.error }
            else {
                $out = @($r.out | Where-Object { $_ })
                $skips = @($out | Where-Object severity -eq 'skipped')
                $real  = @($out | Where-Object severity -ne 'skipped')
                if ($skips -and -not $real) { $status = 'skipped'; $note = $skips[0].title }
                elseif ($real) { $status = 'found'; foreach ($f in $real) { [void]$findings.Add($f) } }
            }
        }
        [void]$results.Add([pscustomobject]@{
            id = $check.id; category = $check.category; name = Get-D9Text $check.name
            status = $status; note = $note; ms = $ms
        })
    }

    Write-Progress -Activity (T-D9 'Debora: сканування') -Completed
    $checked = @($results | Where-Object { $_.status -in 'ok', 'found' } | ForEach-Object category | Sort-Object -Unique)
    $order = @{ critical = 0; warning = 1; suggestion = 2; info = 3 }
    $sorted = @($findings | Sort-Object { $order[$_.severity] }, category)
    $score = Get-D9ScanScore -Categories $Context.Config.categories -Findings $sorted -CheckedCategories $checked

    [pscustomobject]@{
        id             = "{0:yyyy-MM-ddTHH-mm-ss}" -f $Context.Now
        time           = $Context.Now.ToString('s')
        durationSec    = [math]::Round($total.Elapsed.TotalSeconds, 1)
        deep           = $Context.Deep
        admin          = $Context.IsAdmin
        system         = $Context.System
        recommendation = $Context.Recommendation
        score          = $score
        findings       = $sorted
        checks         = @($results)
    }
}

function Get-D9ScanDir {
    $dir = Join-Path (Get-D9DataRoot) 'scans'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Save-D9Scan {
    param([Parameter(Mandatory)]$Scan, [string]$Path)
    if (-not $Path) { $Path = Join-Path (Get-D9ScanDir) "$($Scan.id).json" }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json $Scan -Depth 10), (New-Object Text.UTF8Encoding $false))
    return $Path
}
