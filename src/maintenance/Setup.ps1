# Майстер «Налаштування з нуля»: один прохід після чистої Windows — драйвери з інтернету, деблоат, профіль
# налаштувань, програми, оновлення Windows, сканування з виправленням. Що саме робити, описує профіль майстра
# (JSON): його можна зберегти у файл і перенести на інший ПК або на флешку перевстановлення (виконається після
# першого входу). Кожен крок — окремо: збій одного не зупиняє решту; усі зміни йдуть через рушій (журнал, відкат).

$script:D9SetupSteps = [ordered]@{
    drivers       = 'Драйвери з інтернету (каталог Microsoft і Windows Update)'
    debloat       = 'Деблоат Windows: нав''язані застосунки, реклама, Copilot, телеметрія'
    tweaks        = 'Профіль налаштувань: швидкодія, Провідник, захист'
    apps          = 'Програми: набори й окремі з каталогу'
    windowsUpdate = 'Оновлення Windows'
    scanFix       = 'Сканування й автоматичне виправлення знайденого'
}

function Get-D9SetupStepName { param([string]$Step) $t = $script:D9SetupSteps[$Step]; if ($t) { T-D9 $t } else { $Step } }

function Get-D9SetupProfilePath { Join-Path (Get-D9DataRoot) 'setup-profile.json' }

# Типовий профіль: усе увімкнено, рекомендований профіль налаштувань, базовий набір програм
function New-D9SetupProfile {
    [pscustomobject]@{
        schema  = 1
        name    = (T-D9 'Мій профіль')
        created = (Get-Date).ToString('s')
        steps   = @($script:D9SetupSteps.Keys)
        preset  = 'Recommended'
        bundles = @('basic')
        apps    = @()
        reboot  = $true
    }
}

# Приводить будь-який об'єкт (з JSON чи інтерфейсу) до профілю: невідомі кроки й порожні ID відкидаються
function ConvertTo-D9SetupProfile {
    param($Raw)
    $p = New-D9SetupProfile
    if (-not $Raw) { return $p }
    if ($Raw.name) { $p.name = [string]$Raw.name }
    if ($Raw.created) { $p.created = [string]$Raw.created }
    if ($null -ne $Raw.steps) { $p.steps = @($Raw.steps | ForEach-Object { [string]$_ } | Where-Object { $script:D9SetupSteps.Contains($_) } | Select-Object -Unique) }
    if ($null -ne $Raw.preset) { $p.preset = [string]$Raw.preset }
    if ($null -ne $Raw.bundles) { $p.bundles = @($Raw.bundles | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique) }
    if ($null -ne $Raw.apps) { $p.apps = @($Raw.apps | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique) }
    if ($null -ne $Raw.reboot) { $p.reboot = [bool]$Raw.reboot }
    $p
}

function Import-D9SetupProfile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw (T-D9 'Файл профілю не знайдено: {0}' $Path) }
    $raw = ConvertFrom-Json ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
    if ($raw.schema -and [int]$raw.schema -gt 1) { throw (T-D9 'Профіль створено новішою версією Debora ({0}) — оновіть програму.' "$($raw.schema)") }
    ConvertTo-D9SetupProfile $raw
}

function Export-D9SetupProfile {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json (ConvertTo-D9SetupProfile $Profile) -Depth 4), (New-Object Text.UTF8Encoding $false))
    $Path
}

# Збережений профіль цього ПК (або типовий, якщо ще не зберігали)
function Get-D9SetupProfile {
    $path = Get-D9SetupProfilePath
    if (Test-Path -LiteralPath $path) { try { return (Import-D9SetupProfile $path) } catch { Write-D9Log (T-D9 'Збережений профіль майстра пошкоджено — беру типовий: {0}' $_.Exception.Message) Warn } }
    New-D9SetupProfile
}

function Save-D9SetupProfile { param([Parameter(Mandatory)]$Profile) Export-D9SetupProfile -Profile $Profile -Path (Get-D9SetupProfilePath) }

# Програми профілю: набори + окремі ID → записи каталогу (без повторів; невідомі ID — у Unknown)
function Resolve-D9SetupApps {
    param([Parameter(Mandatory)]$Profile, $AppCatalog)
    if (-not $AppCatalog) { $AppCatalog = Import-D9AppCatalog }
    $ids = New-Object Collections.Generic.List[string]
    foreach ($b in @($Profile.bundles)) {
        $bundle = $AppCatalog.bundles | Where-Object id -eq $b | Select-Object -First 1
        foreach ($id in @($bundle.apps)) { if ($id -and $ids -notcontains $id) { $ids.Add([string]$id) } }
    }
    foreach ($id in @($Profile.apps)) { if ($id -and $ids -notcontains $id) { $ids.Add([string]$id) } }
    $apps = @(); $unknown = @()
    foreach ($id in $ids) {
        $a = $AppCatalog.apps | Where-Object id -eq $id | Select-Object -First 1
        if ($a) { $apps += $a } else { $unknown += $id }
    }
    [pscustomobject]@{ Apps = @($apps); Unknown = @($unknown) }
}

function Resolve-D9SetupPreset {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo)
    $id = if (-not $Profile.preset -or $Profile.preset -eq 'Recommended') { (Get-D9RecommendedPreset $SystemInfo).Preset } else { $Profile.preset }
    $preset = Get-D9Preset $Catalog $id
    if (-not $preset) { throw (T-D9 'Невідомий профіль налаштувань: {0}' $id) }
    $preset
}

# Твіки кроку «Профіль налаштувань». Якщо в майстрі є крок «Деблоат», те, що належить вкладці «Деблоат»
# (застосунки, реклама, телеметрія…), робить саме він — профіль цього не дублює.
function Get-D9SetupTweakIds {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Preset)
    $ids = @($Preset.tweaks)
    if (@($Profile.steps) -contains 'debloat') { $ids = @($ids | Where-Object { (Get-D9TweakOwner $_) -ne 'debloat' }) }
    $ids
}

# Що буде зроблено (для підтвердження й -WhatIf): рядок на кожен крок
function Get-D9SetupPlan {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo, [switch]$Quick)
    foreach ($s in @($Profile.steps)) {
        $title = Get-D9SetupStepName $s
        $detail = switch ($s) {
            'drivers'       { T-D9 'пошук за ID пристроїв, встановлюються лише ті, що точно підходять; попередні драйвери зберігаються' }
            'debloat'       {
                if ($Quick) { T-D9 'рекомендовані застосунки й налаштування з вкладки «Деблоат»' }
                else { $rec = Get-D9DebloatRecommended $Catalog $SystemInfo; T-D9 'застосунків: {0}, налаштувань: {1}' $rec.Packages.Count $rec.TweakIds.Count }
            }
            'tweaks'        { $p = Resolve-D9SetupPreset $Profile $Catalog $SystemInfo; T-D9 '«{0}»: {1} твіків' (Get-D9Text $p.name) @(Get-D9SetupTweakIds $Profile $p).Count }
            'apps'          {
                $r = Resolve-D9SetupApps $Profile
                $names = @($r.Apps | ForEach-Object { $_.name })
                $t = if ($names) { $names -join ', ' } else { T-D9 'нічого не вибрано' }
                if ($r.Unknown) { $t += '. ' + (T-D9 'Немає в каталозі (пропускаються): {0}' ($r.Unknown -join ', ')) }
                $t
            }
            'windowsUpdate' { T-D9 'пошук і встановлення через Windows Update Agent; може тривати довго' }
            'scanFix'       { T-D9 'усі автоматичні кроки чекліста, потім повторне сканування' }
        }
        [pscustomobject]@{ step = $s; title = $title; detail = [string]$detail }
    }
}

# Один крок. Повертає рядок підсумку або @{ Text; Reboot }
function Invoke-D9SetupStep {
    param([Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo)
    switch ($Step) {
        'drivers' {
            $r = Invoke-D9DriverAutoUpdate -SystemInfo $SystemInfo -Folder (Join-Path (Get-D9DataRoot) 'driver-downloads') -NoRestorePoint -CleanupDownloads
            $ok = if ($r.Session) { @($r.Session.entries | Where-Object result -eq 'ok').Count } else { 0 }
            return $(if ($ok) { [pscustomobject]@{ Text = (T-D9 'встановлено драйверів: {0} (потрібне перезавантаження)' $ok); Reboot = $true } } else { T-D9 'драйвери актуальні' })
        }
        'debloat' {
            $rec = Get-D9DebloatRecommended $Catalog $SystemInfo
            if (-not $rec.Packages -and -not $rec.TweakIds) { return (T-D9 'уже виконано') }
            $session = Invoke-D9Debloat -Catalog $Catalog -SystemInfo $SystemInfo -Packages $rec.Packages -TweakIds $rec.TweakIds -NoRestorePoint
            $ok = @($session.entries | Where-Object result -eq 'ok').Count; $err = @($session.entries | Where-Object result -eq 'error').Count
            return (T-D9 'застосунків: {0}, налаштувань: {1}; змін: {2}, помилок: {3}' $rec.Packages.Count $rec.TweakIds.Count $ok $err)
        }
        'tweaks' {
            $preset = Resolve-D9SetupPreset $Profile $Catalog $SystemInfo
            $plan = New-D9Plan -Catalog $Catalog -TweakIds @(Get-D9SetupTweakIds $Profile $preset) -SystemInfo $SystemInfo
            $session = Invoke-D9Plan -Plan $plan -SystemInfo $SystemInfo -Selection (T-D9 'майстер: профіль «{0}»' (Get-D9Text $preset.name)) -NoRestorePoint
            $ok = @($session.entries | Where-Object result -eq 'ok').Count; $err = @($session.entries | Where-Object result -eq 'error').Count
            return (T-D9 '«{0}»: змін {1}, помилок {2}' (Get-D9Text $preset.name) $ok $err)
        }
        'apps' {
            $r = Resolve-D9SetupApps $Profile
            if (-not $r.Apps) { return (T-D9 'нічого не вибрано') }
            $hasWinget = [bool](Get-D9WingetPath)
            $installed = @(Get-D9InstalledAppIds)
            $todo = @($r.Apps | Where-Object { $installed -notcontains $_.id })
            if (-not $todo) { return (T-D9 'усі {0} вже встановлені' $r.Apps.Count) }
            if (-not $hasWinget) { $todo = @($todo | Where-Object { $_.source -eq 'github' }); if (-not $todo) { throw (T-D9 'winget не встановлено — програми з його каталогу поставити неможливо') } }
            $res = @(Install-D9Apps -Apps $todo)
            $bad = @($res | Where-Object { $_.result -in 'failed', 'notFound' })
            $text = T-D9 'встановлено {0} з {1}' ($res.Count - $bad.Count) $todo.Count
            if ($bad) { $text += ' ' + (T-D9 '(не вдалося: {0})' (($bad | ForEach-Object name) -join ', ')) }
            return [pscustomobject]@{ Text = $text; Reboot = [bool]@($res | Where-Object result -eq 'reboot') }
        }
        'windowsUpdate' {
            $r = Install-D9WindowsUpdates
            return [pscustomobject]@{ Text = (T-D9 'встановлено оновлень: {0}' "$($r.Installed)") + $(if ($r.RebootRecommended) { ' ' + (T-D9 '(потрібне перезавантаження)') }); Reboot = [bool]$r.RebootRecommended }
        }
        'scanFix' {
            $ctx = New-D9ScanContext -Catalog $Catalog -SystemInfo $SystemInfo
            $scan = Invoke-D9Scan -Context $ctx
            [void](Save-D9Scan $scan)
            $before = $scan.score.overall
            $list = Merge-D9ChecklistState -New (New-D9Checklist -Scan $scan -Catalog $Catalog) -Old (Get-D9Checklist)
            $done = 0; $reboot = $false
            foreach ($item in @($list.items | Where-Object { $_.auto -and $_.status -ne 'done' } | Sort-Object number)) {
                if ($item.action.type -eq 'maintenance' -and $item.action.action -eq 'reboot') { $reboot = $true; continue }
                if (-not (Test-D9ChecklistReady $list $item)) { continue }
                try { [void](Invoke-D9ChecklistStep -Checklist $list -Item $item -Context $ctx); $done++ } catch { Write-D9Log ('  ' + (T-D9 'Помилка: {0}' $_.Exception.Message)) Error }
            }
            $list = Update-D9ChecklistStatus -Checklist $list -Context $ctx
            Save-D9Checklist $list
            $after = $null
            try { $scan2 = Invoke-D9Scan -Context $ctx; [void](Save-D9Scan $scan2); $after = $scan2.score.overall } catch { }
            $text = T-D9 'оцінка {0} → {1}/100, кроків виконано: {2}' "$before" $(if ($null -ne $after) { "$after" } else { '?' }) $done
            return [pscustomobject]@{ Text = $text; Reboot = $reboot; Before = $before; After = $after }
        }
        default { throw (T-D9 'Невідомий крок майстра: {0}' $Step) }
    }
}

# Повний прохід. Підсумок — setup-last.json у папці даних; повертає @{ results; reboot; scoreBefore; scoreAfter }
function Invoke-D9Setup {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)]$SystemInfo, [switch]$NoRestorePoint)
    $Profile = ConvertTo-D9SetupProfile $Profile
    $started = Get-Date
    Write-D9Log (T-D9 'Налаштування з нуля, профіль «{0}»: {1}' $Profile.name ($Profile.steps -join ', '))
    $rp = if ($NoRestorePoint) { $null } else { New-D9RestorePoint }
    $n = 0; $total = @($Profile.steps).Count
    $results = foreach ($s in @($Profile.steps)) {
        if (Test-D9CancelRequested) { Write-D9Log (T-D9 'Зупинено на вашу вимогу — решту пропущено.') Warn; break }
        $n++
        if ($script:D9OnProgress) { & $script:D9OnProgress $n $total (Get-D9SetupStepName $s) }
        Set-D9Stage -Name (Get-D9SetupStepName $s) -Step $n -Of $total -Key "setup:$s"
        Write-D9Log "— [$n/$total] $(Get-D9SetupStepName $s)"
        try {
            $out = Invoke-D9SetupStep -Step $s -Profile $Profile -Catalog $Catalog -SystemInfo $SystemInfo
            if ($out -is [string] -or $null -eq $out.Text) { $text = [string]$out; $reboot = $false } else { $text = [string]$out.Text; $reboot = [bool]$out.Reboot }
            Write-D9Log "  $text" Ok
            [pscustomobject]@{ step = $s; ok = $true; text = $text; reboot = $reboot; before = $(if ($out.PSObject.Properties['Before']) { $out.Before }); after = $(if ($out.PSObject.Properties['After']) { $out.After }) }
        }
        catch { Write-D9Log ('  ' + (T-D9 'Помилка: {0}' $_.Exception.Message)) Error; [pscustomobject]@{ step = $s; ok = $false; text = $_.Exception.Message; reboot = $false } }
    }
    $scanRow = @($results | Where-Object step -eq 'scanFix') | Select-Object -First 1
    $summary = [pscustomobject]@{
        profile = $Profile.name; started = $started.ToString('s'); finished = (Get-Date).ToString('s'); restorePoint = [bool]$rp
        results = @($results); reboot = [bool](@($results | Where-Object { $_.reboot }))
        scoreBefore = $(if ($scanRow) { $scanRow.before }); scoreAfter = $(if ($scanRow) { $scanRow.after })
    }
    $root = Get-D9DataRoot
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path $root 'setup-last.json'), (ConvertTo-Json $summary -Depth 5), (New-Object Text.UTF8Encoding $false))
    Write-D9Log (T-D9 'Налаштування завершено: {0}' (Format-D9SetupSummary $summary)) Ok
    $summary
}

function Get-D9SetupLast {
    $path = Join-Path (Get-D9DataRoot) 'setup-last.json'
    if (Test-Path -LiteralPath $path) { try { return (ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))) } catch { } }
    $null
}

function Format-D9SetupSummary {
    param([Parameter(Mandatory)]$Summary)
    $parts = foreach ($r in @($Summary.results)) {
        $name = ((Get-D9SetupStepName $r.step) -split ':')[0]
        if ($r.ok) { "${name}: $($r.text)" } else { "${name}: " + (T-D9 'помилка — {0}' $r.text) }
    }
    $parts -join '; '
}
