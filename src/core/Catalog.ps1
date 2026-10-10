# Завантаження та перевірка каталогу твіків і профілів.
# У зібраному файлі JSON вбудовано в $script:D9Embedded; у режимі розробки читається з config/.

$script:D9Embedded  = $null
$script:D9ConfigDir = $null

$script:D9Categories  = @('privacy', 'apps', 'ui', 'performance', 'gaming', 'cleanup', 'updates', 'safety')
$script:D9Risks       = @('safe', 'moderate', 'expert')
$script:D9ActionTypes = [ordered]@{
    registry      = 'Registry'
    service       = 'Service'
    appx          = 'Appx'
    scheduledTask = 'ScheduledTask'
    powercfg      = 'PowerCfg'
    command       = 'Command'
    driver        = 'Driver'
}

function Get-D9ConfigText {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:D9Embedded -and $script:D9Embedded.ContainsKey($Name)) { return $script:D9Embedded[$Name] }
    $path = Join-Path $script:D9ConfigDir $Name
    return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
}

function Import-D9Catalog {
    $tweaks  = (ConvertFrom-Json (Get-D9ConfigText 'tweaks.json')).tweaks
    $presets = (ConvertFrom-Json (Get-D9ConfigText 'presets.json')).presets
    [pscustomobject]@{ Tweaks = @($tweaks); Presets = @($presets) }
}

# Повертає список помилок (порожній — каталог коректний)
function Test-D9Catalog {
    param([Parameter(Mandatory)]$Catalog)
    $errors = New-Object System.Collections.Generic.List[string]
    $ids = @{}
    foreach ($t in $Catalog.Tweaks) {
        $where = if ($t.id) { $t.id } else { '<без id>' }
        if ($t.id -notmatch '^[a-z]+\.[a-z0-9-]+$') { $errors.Add("${where}: id має бути виду 'категорія.назва'") }
        if ($ids.ContainsKey($t.id)) { $errors.Add("${where}: id повторюється") } else { $ids[$t.id] = $t }
        if ($script:D9Categories -notcontains $t.category) { $errors.Add("${where}: невідома категорія '$($t.category)'") }
        if ($script:D9Risks -notcontains $t.risk) { $errors.Add("${where}: невідомий ризик '$($t.risk)'") }
        foreach ($field in 'name', 'description') {
            if (-not $t.$field.uk -or -not $t.$field.en) { $errors.Add("${where}: $field має містити uk і en") }
        }
        if (@($t.actions).Count -eq 0) { $errors.Add("${where}: немає дій") }
        foreach ($a in @($t.actions)) {
            if (-not $script:D9ActionTypes.Contains([string]$a.type)) { $errors.Add("${where}: невідомий тип дії '$($a.type)'"); continue }
            switch ($a.type) {
                'registry' {
                    if ($a.path -notmatch '^(HKLM|HKCU|HKCR|HKU):\\') { $errors.Add("${where}: некоректний шлях реєстру '$($a.path)'") }
                    if ($null -eq $a.name) { $errors.Add("${where}: registry без name") }
                    if (-not $a.delete -and $script:D9RegKinds -notcontains $a.kind) { $errors.Add("${where}: некоректний kind '$($a.kind)'") }
                }
                'service' {
                    if (-not $a.name) { $errors.Add("${where}: service без name") }
                    if (-not $script:D9ServiceStartup.ContainsKey([string]$a.startup)) { $errors.Add("${where}: некоректний startup '$($a.startup)'") }
                }
                'appx'          { if (-not $a.package) { $errors.Add("${where}: appx без package") } }
                'scheduledTask' {
                    if ($a.path -notmatch '^\\') { $errors.Add("${where}: шлях завдання має починатися з \") }
                    if (@('Disabled', 'Enabled') -notcontains $a.state) { $errors.Add("${where}: state має бути Disabled або Enabled") }
                }
                'powercfg' {
                    if (-not $a.scheme -and $null -eq $a.hibernate) { $errors.Add("${where}: powercfg потребує scheme або hibernate") }
                }
                'command' {
                    if (-not $a.run) { $errors.Add("${where}: command без run") }
                    if (-not $a.undoRun -and -not $t.irreversible) { $errors.Add("${where}: command без undoRun (або позначте твік irreversible)") }
                }
            }
        }
    }
    foreach ($t in $Catalog.Tweaks) {
        foreach ($c in @($t.conflicts | Where-Object { $_ })) {
            if (-not $ids.ContainsKey($c)) { $errors.Add("$($t.id): конфлікт з невідомим твіком '$c'") }
        }
    }
    foreach ($p in $Catalog.Presets) {
        foreach ($id in @($p.tweaks)) {
            if (-not $ids.ContainsKey($id)) { $errors.Add("Профіль $($p.id): невідомий твік '$id'"); continue }
            if ($ids[$id].risk -eq 'expert') { $errors.Add("Профіль $($p.id): експертний твік '$id' не може входити в профіль") }
            foreach ($c in @($ids[$id].conflicts | Where-Object { $_ })) {
                if (@($p.tweaks) -contains $c) { $errors.Add("Профіль $($p.id): '$id' конфліктує з '$c'") }
            }
        }
    }
    return ,$errors
}

function Get-D9Tweak {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$Id)
    $Catalog.Tweaks | Where-Object id -eq $Id | Select-Object -First 1
}

function Get-D9Preset {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$Id)
    $Catalog.Presets | Where-Object id -eq $Id | Select-Object -First 1
}
