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
        $where = if ($t.id) { $t.id } else { (T-D9 '<без id>') }
        if ($t.id -notmatch '^[a-z]+\.[a-z0-9-]+$') { $errors.Add((T-D9 '{0}: id має бути виду ''категорія.назва''' $where)) }
        if ($ids.ContainsKey($t.id)) { $errors.Add((T-D9 '{0}: id повторюється' $where)) } else { $ids[$t.id] = $t }
        if ($script:D9Categories -notcontains $t.category) { $errors.Add((T-D9 '{0}: невідома категорія ''{1}''' $where $t.category)) }
        if ($script:D9Risks -notcontains $t.risk) { $errors.Add((T-D9 '{0}: невідомий ризик ''{1}''' $where $t.risk)) }
        foreach ($field in 'name', 'description') {
            if (-not $t.$field.uk -or -not $t.$field.en) { $errors.Add((T-D9 '{0}: {1} має містити uk і en' $where $field)) }
        }
        if (@($t.actions).Count -eq 0) { $errors.Add((T-D9 '{0}: немає дій' $where)) }
        foreach ($a in @($t.actions)) {
            if (-not $script:D9ActionTypes.Contains([string]$a.type)) { $errors.Add((T-D9 '{0}: невідомий тип дії ''{1}''' $where $a.type)); continue }
            switch ($a.type) {
                'registry' {
                    if ($a.path -notmatch '^(HKLM|HKCU|HKCR|HKU):\\') { $errors.Add((T-D9 '{0}: некоректний шлях реєстру ''{1}''' $where $a.path)) }
                    if ($null -eq $a.name) { $errors.Add((T-D9 '{0}: registry без name' $where)) }
                    if (-not $a.delete -and $script:D9RegKinds -notcontains $a.kind) { $errors.Add((T-D9 '{0}: некоректний kind ''{1}''' $where $a.kind)) }
                }
                'service' {
                    if (-not $a.name) { $errors.Add((T-D9 '{0}: service без name' $where)) }
                    if (-not $script:D9ServiceStartup.ContainsKey([string]$a.startup)) { $errors.Add((T-D9 '{0}: некоректний startup ''{1}''' $where $a.startup)) }
                }
                'appx'          { if (-not $a.package) { $errors.Add((T-D9 '{0}: appx без package' $where)) } }
                'scheduledTask' {
                    if ($a.path -notmatch '^\\') { $errors.Add((T-D9 '{0}: шлях завдання має починатися з \' $where)) }
                    if (@('Disabled', 'Enabled') -notcontains $a.state) { $errors.Add((T-D9 '{0}: state має бути Disabled або Enabled' $where)) }
                }
                'powercfg' {
                    if (-not $a.scheme -and $null -eq $a.hibernate) { $errors.Add((T-D9 '{0}: powercfg потребує scheme або hibernate' $where)) }
                }
                'command' {
                    if (-not $a.run) { $errors.Add((T-D9 '{0}: command без run' $where)) }
                    if (-not $a.undoRun -and -not $t.irreversible) { $errors.Add((T-D9 '{0}: command без undoRun (або позначте твік irreversible)' $where)) }
                }
            }
        }
    }
    foreach ($t in $Catalog.Tweaks) {
        foreach ($c in @($t.conflicts | Where-Object { $_ })) {
            if (-not $ids.ContainsKey($c)) { $errors.Add((T-D9 '{0}: конфлікт з невідомим твіком ''{1}''' $t.id $c)) }
        }
    }
    foreach ($p in $Catalog.Presets) {
        foreach ($id in @($p.tweaks)) {
            if (-not $ids.ContainsKey($id)) { $errors.Add((T-D9 'Профіль {0}: невідомий твік ''{1}''' $p.id $id)); continue }
            if ($ids[$id].risk -eq 'expert') { $errors.Add((T-D9 'Профіль {0}: експертний твік ''{1}'' не може входити в профіль' $p.id $id)) }
            foreach ($c in @($ids[$id].conflicts | Where-Object { $_ })) {
                if (@($p.tweaks) -contains $c) { $errors.Add((T-D9 'Профіль {0}: ''{1}'' конфліктує з ''{2}''' $p.id $id $c)) }
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
