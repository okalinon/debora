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

function Invoke-D9Scan {
    param([Parameter(Mandatory)]$Context, [string[]]$OnlyChecks)
    $results = New-Object System.Collections.ArrayList
    $findings = New-Object System.Collections.ArrayList
    $total = [Diagnostics.Stopwatch]::StartNew()

    $list = @($Context.Config.checks | Where-Object { -not $OnlyChecks -or $OnlyChecks -contains $_.id })
    $n = 0
    foreach ($check in $list) {
        $n++
        Write-Progress -Activity 'Debloater9: сканування' -Status "$n / $($list.Count): $(Get-D9Text $check.name)" -PercentComplete ($n * 100 / $list.Count)
        if ($script:D9OnProgress) { & $script:D9OnProgress $n $list.Count (Get-D9Text $check.name) }
        $status = 'ok'; $note = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $fit = if ($check.requires) { Test-D9Applicable $check.requires $Context.System } else { $null }
        if ($fit -and -not $fit.Applicable) { $status = 'notApplicable'; $note = $fit.Reason }
        elseif ($check.deep -and -not $Context.Deep) { $status = 'notRun'; $note = 'лише в глибокому скануванні' }
        elseif ($check.adminOnly -and -not $Context.IsAdmin) { $status = 'skipped'; $note = 'потрібні права адміністратора' }
        else {
            try {
                $out = @(& $check.probe -Check $check -Ctx $Context | Where-Object { $_ })
                $skips = @($out | Where-Object severity -eq 'skipped')
                $real  = @($out | Where-Object severity -ne 'skipped')
                if ($skips -and -not $real) { $status = 'skipped'; $note = $skips[0].title }
                elseif ($real) { $status = 'found'; foreach ($f in $real) { [void]$findings.Add($f) } }
            } catch {
                $status = 'error'; $note = $_.Exception.Message
            }
        }
        [void]$results.Add([pscustomobject]@{
            id = $check.id; category = $check.category; name = Get-D9Text $check.name
            status = $status; note = $note; ms = [int]$sw.ElapsedMilliseconds
        })
    }

    Write-Progress -Activity 'Debloater9: сканування' -Completed
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
