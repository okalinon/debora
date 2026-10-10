# Універсальні проби, що працюють з даних checks.json (без окремого коду для кожної перевірки):
#   Test-D9RegistryRule — значення реєстру;  Test-D9ServiceRule — служба;  Test-D9EventRule — події журналу.
# Спільні поля params: severity, title {uk,en}, details {uk,en}, fix, links [{label,url}].
# У title/details можна вживати {value}, {count}, {days}, {name}.

function Format-D9Template {
    param([string]$Text, [hashtable]$Vars)
    foreach ($k in $Vars.Keys) { $Text = $Text.Replace("{$k}", [string]$Vars[$k]) }
    return $Text
}

function ConvertTo-D9Fix {
    param($Fix)
    if (-not $Fix) { return @{ type = 'manual' } }
    $h = @{}; foreach ($p in $Fix.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function New-D9RuleFinding {
    param($Check, [hashtable]$Vars)
    $p = $Check.params
    $links = @($p.links | Where-Object { $_ } | ForEach-Object { New-D9Link (Get-D9Text $_.label) $_.url })
    New-D9Finding $Check $p.severity (Format-D9Template (Get-D9Text $p.title) $Vars) (Format-D9Template (Get-D9Text $p.details) $Vars) (ConvertTo-D9Fix $p.fix) $links
}

# Умова «погано»: { op: eq|ne|lt|gt|match|in, value, missing: bad|ok }
function Test-D9BadValue {
    param([bool]$Exists, $Actual, $Cond)
    if (-not $Exists) { return $Cond.missing -eq 'bad' }
    switch ($Cond.op) {
        'eq'    { return [string]$Actual -eq [string]$Cond.value }
        'ne'    { return [string]$Actual -ne [string]$Cond.value }
        'lt'    { return [double]$Actual -lt [double]$Cond.value }
        'gt'    { return [double]$Actual -gt [double]$Cond.value }
        'match' { return [string]$Actual -match [string]$Cond.value }
        'in'    { return @($Cond.value | ForEach-Object { [string]$_ }) -contains [string]$Actual }
        'exists'{ return $true }
        default { throw "Невідомий оператор умови: $($Cond.op)" }
    }
}

function Get-D9RegValue {
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [pscustomobject]@{ Exists = $false; Value = $null } }
    [pscustomobject]@{ Exists = $true; Value = $item.$Name }
}

# params: path, name, bad {op,value,missing}, onlyIf {path,name,op,value,missing} — перевіряти лише якщо умова виконується
function Test-D9RegistryRule {
    param($Check, $Ctx)
    $p = $Check.params
    if ($p.onlyIf) {
        $c = Get-D9RegValue $p.onlyIf.path $p.onlyIf.name
        if (-not (Test-D9BadValue $c.Exists $c.Value $p.onlyIf)) { return }
    }
    $v = Get-D9RegValue $p.path $p.name
    if (Test-D9BadValue $v.Exists $v.Value $p.bad) {
        New-D9RuleFinding $Check @{ value = $v.Value; name = $p.name }
    }
}

# params: name, badStartup [..], badStatus [..]
function Test-D9ServiceRule {
    param($Check, $Ctx)
    $p = $Check.params
    $state = Get-D9ServiceState ([pscustomobject]@{ name = $p.name })
    if (-not $state.exists) { return }
    $bad = (@($p.badStartup) -contains $state.startup) -or (@($p.badStatus) -contains $state.status)
    if ($bad) { New-D9RuleFinding $Check @{ name = $p.name; value = "$($state.startup), $($state.status)" } }
}

# Події журналу. $null — журнал недоступний (немає прав), @() — подій немає.
function Get-D9Events {
    param([hashtable]$Filter)
    try { @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop) }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return ,@() }
        return $null
    }
}

# params: log, providers [..], ids [..], levels [..], days, min, criticalMin (необов'язково)
function Test-D9EventRule {
    param($Check, $Ctx)
    $p = $Check.params
    $filter = @{ LogName = $p.log; StartTime = $Ctx.Now.AddDays(-[int]$p.days) }
    if ($p.providers) { $filter.ProviderName = @($p.providers) }
    if ($p.ids)       { $filter.Id = @($p.ids | ForEach-Object { [int]$_ }) }
    if ($p.levels)    { $filter.Level = @($p.levels | ForEach-Object { [int]$_ }) }
    $events = Get-D9Events $filter
    if ($null -eq $events) { return New-D9Skip $Check "Журнал $($p.log) недоступний (потрібні права адміністратора?)" }
    $count = @($events).Count
    if ($count -lt [int]$p.min) { return }
    $finding = New-D9RuleFinding $Check @{ count = $count; days = $p.days }
    if ($p.criticalMin -and $count -ge [int]$p.criticalMin) { $finding.severity = 'critical' }
    $finding
}
