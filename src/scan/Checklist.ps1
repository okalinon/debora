# Чекліст «що робити» з результатів сканування: порядок, посилання, дії, автоматичні галочки.
#
# Групи (порядок виконання):
#   10 резервна копія · 12 перевірка диска · 19 захист системи · 20 точка відновлення · 30-33 драйвери
#   40 безпека (вручну) · 41 посилити захист (твіки) · 42 виправити безпеку (дії) · 43-44 Захисник
#   45 оновлення Windows (вручну) · 46 відновити оновлення (дії) · 48-49 скидання й встановлення оновлень
#   50 очищення · 55 небажані програми · 60-62 налаштування (твіки) · 63 виправити систему (дії)
#   70 оновлення програм · 75 відновлення системних файлів · 80-85 ручні кроки й поради · 90 перезавантаження
#
# Типи дій кроку: tweaks (твіки з каталогу), actions (готові дії зі знахідок — реєстр, служба, команда…;
# через рушій, тож з журналом і відкатом), maintenance (див. $D9MaintenanceActions), restorePoint, manual.

function New-D9ChecklistItem {
    param([int]$Group, [string]$Key, [string]$Title, [string]$Why, [object[]]$Links, $Action, $Verify, [string[]]$DependsOn)
    [pscustomobject]@{
        id         = "$Group|$Key"
        group      = $Group
        number     = 0
        title      = $Title
        why        = $Why
        links      = @($Links | Where-Object { $_ })
        action     = $Action
        auto       = ($Action.type -ne 'manual')
        verify     = $Verify
        dependsOn  = @($DependsOn | Where-Object { $_ })
        status     = 'pending'
        executedAt = $null
        doneAt     = $null
        note       = $null
    }
}

function New-D9Checklist {
    param([Parameter(Mandatory)]$Scan, [Parameter(Mandatory)]$Catalog)
    $items = New-Object System.Collections.ArrayList
    $used  = @{}
    $f = @($Scan.findings | Where-Object { $_.severity -ne 'info' })   # відомості в чекліст не потрапляють
    $free = { @($f | Where-Object { -not $used[$_.key] }) }
    $use  = { param($list) foreach ($x in @($list)) { $used[$x.key] = $true } }
    $add  = { param($item) [void]$items.Add($item); $item }
    $checkVerify = { param($finding) @{ type = 'check'; checkId = $finding.checkId; key = $finding.key } }
    $manual = { param([int]$group, $x) [void]$items.Add((New-D9ChecklistItem $group $x.key $x.title $x.details $x.links @{ type = 'manual' } (& $checkVerify $x))); $used[$x.key] = $true }
    $isCleanup = { param($x) $x.fix.type -eq 'tweaks' -and @($x.fix.ids).Count -and -not @($x.fix.ids | Where-Object { $_ -notlike 'cleanup.*' }) }

    # 10 — резервна копія, якщо диск під загрозою
    $diskDanger = @($f | Where-Object { $_.checkId -in 'disk.health', 'stab.disk-errors', 'disk.smart-predict' -and $_.severity -in 'critical', 'warning' })
    if ($diskDanger) {
        $why = ($diskDanger | ForEach-Object { "$($_.title). $($_.details)" }) -join ' '
        & $add (New-D9ChecklistItem 10 'backup' (T-D9 'Скопіювати важливі файли на інший диск або в хмару') $why @() @{ type = 'manual' } $null) | Out-Null
        & $use @($diskDanger | Where-Object { $_.fix.type -ne 'maintenance' })   # перевірка диска (chkdsk) — окремим автоматичним кроком
    }

    # 30-32 — пристрої без драйвера: мережа першою, щоб з'явився інтернет
    $netIds = @()
    $devices = @($f | Where-Object checkId -eq 'upd.problem-devices')
    $rank = { param($d) if ($d.data.class -eq 'Net') { 30 } elseif ($d.data.class -eq 'System' -or "$($d.data.hwid)" -like 'ACPI\*') { 31 } else { 32 } }
    # 29 — спершу автоматичний пошук драйверів в інтернеті; ручні кроки нижче лишаються запасним варіантом
    if ($devices) {
        & $add (New-D9ChecklistItem 29 'driverUpdate' (Get-D9MaintenanceTitle 'driverUpdate') (T-D9 'Пристроїв без драйвера: {0}. Debora знайде драйвери в каталозі Microsoft і Windows Update, завантажить і встановить (з відкатом).' $devices.Count) @() @{ type = 'maintenance'; action = 'driverUpdate' } @{ type = 'executed' }) | Out-Null
    }
    foreach ($d in ($devices | Sort-Object { & $rank $_ })) {
        $group = & $rank $d
        $why = "$($d.title). $($d.details)"
        if ($group -eq 30) { $why += (T-D9 '. Ставте першим — після нього з''явиться інтернет для решти.') }
        $item = & $add (New-D9ChecklistItem $group $d.key (T-D9 'Встановити драйвер: {0}' $d.data.name) $why $d.links @{ type = 'manual' } (& $checkVerify $d) $(if ($group -ne 30) { $netIds }))
        if ($group -eq 30) { $netIds += $item.id }
        $used[$d.key] = $true
    }
    # 33 — інші проблеми з драйверами (відео, непідписані, збої відеодрайвера)
    foreach ($x in (& $free | Where-Object { $_.fix.type -eq 'drivers' })) { & $manual 33 $x }

    # 40 — безпека й резервні копії (ручні кроки), 45 — оновлення Windows
    foreach ($x in (& $free | Where-Object { $_.category -in 'security', 'backup' -and $_.fix.type -notin 'tweaks', 'actions', 'maintenance', 'apps' -and $_.severity -in 'critical', 'warning' } | Sort-Object { if ($_.severity -eq 'critical') { 0 } else { 1 } })) { & $manual 40 $x }
    foreach ($x in (& $free | Where-Object { $_.category -eq 'updates' -and $_.fix.type -notin 'tweaks', 'actions', 'maintenance' -and $_.severity -in 'critical', 'warning' })) { & $manual 45 $x }

    # 50 — очищення диска: одна автоматична дія з усіх знахідок, що виправляються твіками cleanup.*
    $space = @(& $free | Where-Object { (& $isCleanup $_) -or $_.checkId -eq 'disk.free-space' })
    if ($space) {
        $ids = @($space | ForEach-Object { $_.fix.ids } | Where-Object { $_ } | Sort-Object -Unique)
        $bytes = [long](($space | ForEach-Object { $_.data.bytes } | Where-Object { $_ } | Measure-Object -Sum).Sum)
        $title = if ($bytes) { T-D9 'Очистити диск: звільнити {0}' (Format-D9Size $bytes) } else { T-D9 'Очистити диск' }
        $why = ($space | ForEach-Object { $_.title }) -join '; '
        & $add (New-D9ChecklistItem 50 'cleanup' $title $why @() @{ type = 'tweaks'; ids = $ids } @{ type = 'executed' }) | Out-Null
        & $use $space
    }
    # 52 — очищення вручну (Windows.old, кеш браузерів, «Завантаження»...)
    foreach ($x in (& $free | Where-Object { $_.category -eq 'cleanliness' -and $_.fix.type -in 'manual', 'files' })) { & $manual 52 $x }
    # 55 — небажані сторонні програми: видалення деінсталяторами (тихо, де можливо)
    foreach ($x in (& $free | Where-Object checkId -eq 'perf.known-bloat')) {
        if ($x.fix.type -eq 'uninstall') {
            & $add (New-D9ChecklistItem 55 'uninstall' (T-D9 'Видалити небажані програми ({0})' @($x.fix.names).Count) $x.details $x.links @{ type = 'uninstall'; names = @($x.fix.names) } (& $checkVerify $x)) | Out-Null
            $used[$x.key] = $true
        } else { & $manual 55 $x }
    }

    # 41, 60-63 — автоматичні налаштування з каталогу твіків, згруповані за змістом
    $tweakGroups = @(
        @{ g = 41; key = 'security'; title = (T-D9 'Посилити захист');                          match = { param($x) $x.category -in 'security', 'backup' } }
        @{ g = 60; key = 'apps';     title = (T-D9 'Прибрати рекламні та непотрібні застосунки'); match = { param($x) $x.checkId -eq 'clean.bloat-apps' } }
        @{ g = 61; key = 'privacy';  title = (T-D9 'Вимкнути телеметрію та рекламу');             match = { param($x) $x.category -eq 'privacy' } }
        @{ g = 62; key = 'perf';     title = (T-D9 'Налаштувати швидкодію під це залізо');        match = { param($x) $true } }
    )
    foreach ($tg in $tweakGroups) {
        $fs = @(& $free | Where-Object { $_.fix.type -eq 'tweaks' } | Where-Object { & $tg.match $_ })
        if (-not $fs) { continue }
        $ids = @($fs | ForEach-Object { $_.fix.ids } | Sort-Object -Unique)
        $why = ($fs | ForEach-Object { if ($_.details) { "$($_.title): $($_.details)" } else { $_.title } }) -join ' · '
        & $add (New-D9ChecklistItem $tg.g $tg.key "$($tg.title) ($($ids.Count))" $why @() @{ type = 'tweaks'; ids = $ids } @{ type = 'tweaks'; ids = $ids }) | Out-Null
        & $use $fs
    }

    # 42, 46, 63 — готові дії зі знахідок (реєстр, служби, команди), згруповані за змістом
    $actionGroups = @(
        @{ g = 42; key = 'fix-security'; title = (T-D9 'Виправити налаштування безпеки');    match = { param($x) $x.category -in 'security', 'backup' } }
        @{ g = 46; key = 'fix-updates';  title = (T-D9 'Відновити роботу оновлень Windows'); match = { param($x) $x.category -eq 'updates' } }
        @{ g = 63; key = 'fix-system';   title = (T-D9 'Виправити налаштування системи');    match = { param($x) $true } }
    )
    foreach ($ag in $actionGroups) {
        $fs = @(& $free | Where-Object { $_.fix.type -eq 'actions' -and @($_.fix.actions).Count } | Where-Object { & $ag.match $_ })
        if (-not $fs) { continue }
        $fixes = @($fs | ForEach-Object { [pscustomobject]@{ key = $_.key; title = $_.title; actions = @($_.fix.actions) } })
        $why = ($fs | ForEach-Object { $_.title }) -join ' · '
        $verify = @{ type = 'checks'; items = @($fs | ForEach-Object { @{ checkId = $_.checkId; key = $_.key } }) }
        $reboot = [bool](@($fs | Where-Object { $_.fix.reboot }))
        & $add (New-D9ChecklistItem $ag.g $ag.key "$($ag.title) ($($fs.Count))" $why @() @{ type = 'actions'; fixes = $fixes; reboot = $reboot } $verify) | Out-Null
        & $use $fs
    }

    # 71 — оновити конкретні програми (вразливі версії) через winget
    $appFs = @(& $free | Where-Object { $_.fix.type -eq 'apps' -and @($_.fix.ids).Count })
    if ($appFs) {
        $ids = @($appFs | ForEach-Object { $_.fix.ids } | Sort-Object -Unique)
        $verify = @{ type = 'checks'; items = @($appFs | ForEach-Object { @{ checkId = $_.checkId; key = $_.key } }) }
        & $add (New-D9ChecklistItem 71 'apps' (T-D9 'Оновити вразливі програми ({0})' $ids.Count) (($appFs | ForEach-Object { $_.title }) -join ' · ') @() @{ type = 'apps'; ids = $ids } $verify) | Out-Null
        & $use $appFs
    }

    # 12-75 — обслуговування: один крок на кожну дію, навіть якщо до неї ведуть кілька знахідок
    foreach ($name in $script:D9MaintenanceActions.Keys) {
        if ($script:D9MaintenanceActions[$name].OnRequest) { continue }   # лише кнопкою «Виправити» в знахідці
        $fs = @(& $free | Where-Object { $_.fix.type -eq 'maintenance' -and $_.fix.action -eq $name })
        if (-not $fs) { continue }
        $existing = $items | Where-Object { $_.action.type -eq 'maintenance' -and $_.action.action -eq $name } | Select-Object -First 1
        if ($existing) { $existing.why += ' · ' + (($fs | ForEach-Object { $_.title }) -join ' · '); & $use $fs; continue }
        $m = $script:D9MaintenanceActions[$name]
        $title = if ($fs.Count -eq 1 -and $name -in 'wingetUpgrade', 'repairSystem') { $fs[0].title } else { Get-D9MaintenanceTitle $name }
        $why = if ($fs.Count -eq 1) { "$($fs[0].title). $($fs[0].details)" } else { ($fs | ForEach-Object { $_.title }) -join ' · ' }
        & $add (New-D9ChecklistItem $m.Group $name $title $why @($fs | ForEach-Object { $_.links }) @{ type = 'maintenance'; action = $name } @{ type = 'executed' }) | Out-Null
        & $use $fs
    }

    # 20 — точка відновлення перед першою автоматичною зміною. Кроки до неї (перевірка диска, увімкнення
    # захисту системи — без нього точку не створити) від неї не залежать, інакше їх ніколи не виконати
    $autoChanges = @($items | Where-Object { $_.action.type -in 'tweaks', 'maintenance', 'actions', 'uninstall' -and $_.group -gt 20 })
    $rpFindings = @(& $free | Where-Object { $_.fix.type -eq 'maintenance' -and $_.fix.action -eq 'restorePoint' })
    if ($autoChanges -or $rpFindings) {
        $why = if ($rpFindings) { ($rpFindings.title) -join '; ' } else { T-D9 'Щоб будь-яку зміну можна було скасувати.' }
        $rp = New-D9ChecklistItem 20 'restore-point' (T-D9 'Створити точку відновлення') $why @() @{ type = 'restorePoint' } @{ type = 'executed' }
        [void]$items.Add($rp)
        foreach ($i in $autoChanges) { $i.dependsOn = @($i.dependsOn) + $rp.id }
        & $use $rpFindings
    }

    # 90 — одне перезавантаження наприкінці
    $rebootFindings = @(& $free | Where-Object { $_.fix.type -eq 'maintenance' -and $_.fix.action -eq 'reboot' })
    $needsReboot = $rebootFindings -or @($items | Where-Object { $_.group -in 12, 30, 31, 32, 49, 75 -or $_.action.reboot }) -or
        @($items | Where-Object { $_.action.type -eq 'tweaks' } | ForEach-Object { $_.action.ids } | ForEach-Object { Get-D9Tweak $Catalog $_ } | Where-Object rebootRequired)
    if ($needsReboot) {
        $why = if ($rebootFindings) { ($rebootFindings.title) -join '; ' } else { T-D9 'Щоб драйвери й налаштування запрацювали повністю.' }
        [void]$items.Add((New-D9ChecklistItem 90 'reboot' (T-D9 'Перезавантажити комп''ютер') $why @() @{ type = 'maintenance'; action = 'reboot' } @{ type = 'reboot' } @($items | Where-Object auto | ForEach-Object id)))
        & $use $rebootFindings
    }

    # 80 — інші ручні кроки з помітним впливом, 85 — поради
    foreach ($x in (& $free | Where-Object { $_.severity -in 'critical', 'warning' })) { & $manual 80 $x }
    foreach ($x in (& $free)) { & $manual 85 $x }

    $sorted = @($items | Sort-Object group, @{ Expression = { $items.IndexOf($_) } })
    for ($i = 0; $i -lt $sorted.Count; $i++) { $sorted[$i].number = $i + 1 }
    [pscustomobject]@{
        created  = (Get-Date).ToString('s')
        scanId   = $Scan.id
        machine  = $env:COMPUTERNAME
        model    = "$($Scan.system.Manufacturer) $($Scan.system.Model)".Trim()
        os       = "$($Scan.system.OsName) $($Scan.system.DisplayVersion)"
        preset   = $Scan.recommendation.Preset
        items    = $sorted
    }
}
# Переносить статуси з попереднього чекліста (той самий id = той самий крок)
function Merge-D9ChecklistState {
    param([Parameter(Mandatory)]$New, $Old)
    if (-not $Old) { return $New }
    foreach ($item in $New.items) {
        $prev = $Old.items | Where-Object id -eq $item.id | Select-Object -First 1
        if ($prev) { $item.status = $prev.status; $item.executedAt = $prev.executedAt; $item.doneAt = $prev.doneAt; $item.note = $prev.note }
    }
    return $New
}

function Get-D9ChecklistPath { Join-Path (Get-D9DataRoot) 'checklists\current.json' }

function Save-D9Checklist {
    param([Parameter(Mandatory)]$Checklist)
    $path = Get-D9ChecklistPath
    $dir = Split-Path $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Файл, створений від адміністратора, звичайний користувач перезаписати не може — не падаємо, а попереджаємо
    try { [IO.File]::WriteAllText($path, (ConvertTo-Json $Checklist -Depth 10), (New-Object Text.UTF8Encoding $false)) }
    catch [UnauthorizedAccessException] { Write-D9Log (T-D9 'Чекліст не збережено: немає прав на запис у папку даних (запустіть від адміністратора).') Warn }
}

function Get-D9Checklist {
    $path = Get-D9ChecklistPath
    if (-not (Test-Path $path)) { return $null }
    $c = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
    $c.items = @($c.items)
    return $c
}

# Автоматичні галочки: перевіряє фактичний стан кожного невиконаного кроку
function Update-D9ChecklistStatus {
    param([Parameter(Mandatory)]$Checklist, [Parameter(Mandatory)]$Context)
    $pending = @($Checklist.items | Where-Object status -ne 'done')
    $checkIds = @($pending | ForEach-Object { if ($_.verify.type -eq 'check') { $_.verify.checkId } elseif ($_.verify.type -eq 'checks') { $_.verify.items.checkId } } | Where-Object { $_ } | Sort-Object -Unique)
    $fresh = if ($checkIds) { (Invoke-D9Scan -Context $Context -OnlyChecks $checkIds).findings } else { @() }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    foreach ($item in $pending) {
        $done = switch ($item.verify.type) {
            'check'    { -not ($fresh | Where-Object key -eq $item.verify.key) }
            'tweaks'   { -not (@($item.verify.ids | ForEach-Object { Get-D9Tweak $Context.Catalog $_ } | Where-Object { (Get-D9TweakState $_ $Context.System) -in 'notApplied', 'partial' })) }
            'checks'   { -not @($item.verify.items | Where-Object { $k = $_.key; $fresh | Where-Object key -eq $k }) }
            'executed' { [bool]$item.executedAt }
            'reboot'   { $boot -gt [datetime]$Checklist.created }
            default    { $false }
        }
        if ($done) { $item.status = 'done'; $item.doneAt = (Get-Date).ToString('s') }
    }
    return $Checklist
}

# Крок готовий, коли попередні автоматичні кроки виконано. Статус «done» з'являється лише після
# перевірки наприкінці, тож у межах одного запуску достатньо, що крок уже виконувався (executedAt)
function Test-D9ChecklistReady {
    param($Checklist, $Item)
    foreach ($dep in @($Item.dependsOn)) {
        $d = $Checklist.items | Where-Object id -eq $dep | Select-Object -First 1
        if ($d -and $d.auto -and $d.status -ne 'done' -and -not $d.executedAt) { return $false }
    }
    return $true
}

# Виконує автоматичний крок. Повертає $true, якщо виконано.
function Invoke-D9ChecklistStep {
    param([Parameter(Mandatory)]$Checklist, [Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Context, [switch]$AllowReboot, [switch]$NoSave)
    Write-D9Log (T-D9 'Крок {0}. {1}' $Item.number $Item.title)
    switch ($Item.action.type) {
        'manual' { Write-D9Log (T-D9 '  Це ручний крок: {0}' $Item.why) Warn; return $false }
        'restorePoint' {
            $rp = New-D9RestorePoint
            if (-not $rp) { Write-D9Log (T-D9 '  Не вдалося створити точку відновлення (захист системи вимкнено?)') Warn; $Item.note = (T-D9 'не вдалося') }
        }
        'tweaks' {
            $restoreDone = [bool]($Checklist.items | Where-Object { $_.action.type -eq 'restorePoint' -and $_.status -eq 'done' })
            $plan = New-D9Plan -Catalog $Context.Catalog -TweakIds @($Item.action.ids) -SystemInfo $Context.System
            $session = Invoke-D9Plan -Plan $plan -SystemInfo $Context.System -Selection "checklist: $($Item.title)" -NoRestorePoint:$restoreDone
            $Item.note = (T-D9 'сесія {0}' $session.id)
        }
        'actions' {
            # Кожне виправлення — тимчасовий «твік»: рушій знімає стан до змін, пише журнал, і все відкочується
            $restoreDone = [bool]($Checklist.items | Where-Object { $_.action.type -eq 'restorePoint' -and $_.status -eq 'done' })
            $tweaks = @($Item.action.fixes | ForEach-Object { [pscustomobject]@{ id = "fix:$($_.key)"; name = [pscustomobject]@{ uk = $_.title }; actions = @($_.actions) } })
            $catalog = [pscustomobject]@{ Tweaks = $tweaks; Presets = @() }
            $plan = New-D9Plan -Catalog $catalog -TweakIds @($tweaks.id) -SystemInfo $Context.System
            $session = Invoke-D9Plan -Plan $plan -SystemInfo $Context.System -Selection "checklist: $($Item.title)" -NoRestorePoint:$restoreDone
            $err = @($session.entries | Where-Object result -eq 'error').Count
            $Item.note = if ($err) { T-D9 'сесія {0}, помилок: {1}' $session.id $err } else { T-D9 'сесія {0}' $session.id }
        }
        'uninstall' {
            $progs = @(Get-D9UninstallList | Where-Object { @($Item.action.names) -contains $_.Name })
            if (-not $progs) { Write-D9Log (T-D9 '  Ці програми вже видалено.') Ok }
            else {
                $res = @(Uninstall-D9Programs -Programs $progs)
                # Небажане ПЗ: залишки прибираємо одразу (папки — у Кошик, реєстр — з резервною копією .reg)
                $left = @($res | ForEach-Object { $_.leftovers } | Where-Object { $_ })
                if ($left) { [void](Remove-D9UninstallLeftovers -Items $left) }
                $bad = @($res | Where-Object { $_.result -notin 'removed', 'reboot' })
                if ($bad) { $Item.note = (T-D9 'не видалено: {0}' (($bad.name) -join ', ')) }
            }
        }
        'files' {
            $n = Move-D9FilesToRecycleBin -Paths @($Item.action.paths)
            $Item.note = (T-D9 'у Кошик: {0}' $n)
        }
        'apps' {
            $res = @(Update-D9Apps -Ids @($Item.action.ids))
            $bad = @($res | Where-Object { $_.result -in 'failed', 'notFound' })
            if ($bad) { $Item.note = (T-D9 'не вдалося: {0}' (($bad.id) -join ', ')) }
        }
        'maintenance' {
            if ($Item.action.action -eq 'reboot') {
                if (-not $AllowReboot) { Write-D9Log (T-D9 '  Перезавантажте комп''ютер вручну або запустіть з -AllowReboot') Warn; return $false }
                $Item.executedAt = (Get-Date).ToString('s'); if (-not $NoSave) { Save-D9Checklist $Checklist }
                Restart-Computer -Force
                return $true
            }
            $m = $script:D9MaintenanceActions[[string]$Item.action.action]
            if (-not $m) { Write-D9Log (T-D9 '  Невідома дія обслуговування: {0}' $Item.action.action) Warn; return $false }
            $r = & $m.Fn
            if ($r.RebootRecommended) { $Item.note = (T-D9 'потрібне перезавантаження') }
        }
    }
    $Item.executedAt = (Get-Date).ToString('s')
    if (-not $NoSave) { Save-D9Checklist $Checklist }
    return $true
}

# ---------- Дія в одній знахідці («Огляд» → «Виправити» / «Як виправити») ----------

# Крок лише для цієї знахідки: виконує тільки її виправлення, а не весь груповий крок чекліста
# (наприклад, з «Очистити диск» — лише цю очистку). $null — Debora не виправляє це сама (manual, drivers).
function New-D9ChecklistItemForFinding {
    param([Parameter(Mandatory)]$Finding)
    $f = $Finding; $fix = $f.fix
    $action = switch ([string]$fix.type) {
        'tweaks'      { if (@($fix.ids).Count) { @{ type = 'tweaks'; ids = @($fix.ids) } } }
        'actions'     { if (@($fix.actions).Count) { @{ type = 'actions'; fixes = @([pscustomobject]@{ key = $f.key; title = $f.title; actions = @($fix.actions) }); reboot = [bool]$fix.reboot } } }
        'maintenance' {
            if ($fix.action -eq 'restorePoint') { @{ type = 'restorePoint' } }
            elseif ($fix.action -and $fix.action -ne 'reboot' -and $script:D9MaintenanceActions.Contains([string]$fix.action)) { @{ type = 'maintenance'; action = [string]$fix.action } }
        }
        'apps'        { if (@($fix.ids).Count) { @{ type = 'apps'; ids = @($fix.ids) } } }
        'uninstall'   { if (@($fix.names).Count) { @{ type = 'uninstall'; names = @($fix.names) } } }
        'files'       { $p = @($f.data.items | Where-Object { $_.path } | ForEach-Object { [string]$_.path }); if ($p) { @{ type = 'files'; paths = $p } } }
    }
    # Пристрій без драйвера: Debora шукає драйвери в інтернеті сама (як крок 29 чекліста)
    if (-not $action -and $f.checkId -eq 'upd.problem-devices') { $action = @{ type = 'maintenance'; action = 'driverUpdate' } }
    if (-not $action) { return $null }
    $item = New-D9ChecklistItem 0 $f.key $f.title $f.details $f.links $action @{ type = 'check'; checkId = $f.checkId; key = $f.key }
    $item.number = 1
    $item
}

# Що зробить «Виправити» (текст для підтвердження): зміни твіків і дій — як «Що зміниться» в «Налаштуваннях»
function Get-D9FindingFixPreview {
    param([Parameter(Mandatory)]$Finding, [Parameter(Mandatory)]$Context)
    $item = New-D9ChecklistItemForFinding $Finding
    if (-not $item) { return '' }
    $a = $item.action
    switch ($a.type) {
        'tweaks' {
            $plan = New-D9Plan -Catalog $Context.Catalog -TweakIds @($a.ids) -SystemInfo $Context.System
            $lines = foreach ($p in @(Get-D9Preview -Plan $plan -SystemInfo $Context.System)) { "• $($p.Tweak): $($p.Change)" }
            $names = @($a.ids | ForEach-Object { Get-D9Tweak $Context.Catalog $_ } | Where-Object { $_ } | ForEach-Object { Get-D9Text $_.name })
            return (@($names) + '' + @($lines)) -join "`r`n"
        }
        'actions' {
            $tw = [pscustomobject]@{ id = "fix:$($Finding.key)"; name = [pscustomobject]@{ uk = $Finding.title }; actions = @($Finding.fix.actions) }
            $plan = New-D9Plan -Catalog ([pscustomobject]@{ Tweaks = @($tw); Presets = @() }) -TweakIds @($tw.id) -SystemInfo $Context.System
            return (@(Get-D9Preview -Plan $plan -SystemInfo $Context.System) | ForEach-Object { "• $($_.Change)" }) -join "`r`n"
        }
        'maintenance'  { return (Get-D9MaintenanceTitle $a.action) }
        'restorePoint' { return (T-D9 'Створити точку відновлення') }
        'apps'         { return (T-D9 'Оновити через winget: {0}' (@($a.ids) -join ', ')) }
        'uninstall'    { return (T-D9 'Видалити програми: {0}. Залишки (папки й записи реєстру) — у Кошик і резервну копію .reg.' (@($a.names) -join ', ')) }
        'files'        { return ((T-D9 'Перенести в Кошик ({0}):' @($a.paths).Count) + "`r`n" + (@($a.paths) -join "`r`n")) }
    }
}

# Чи потрібні права адміністратора: не потрібні лише для змін у реєстрі поточного користувача (HKCU)
function Test-D9FindingFixNeedsAdmin {
    param([Parameter(Mandatory)]$Finding, $Catalog)
    $item = New-D9ChecklistItemForFinding $Finding
    if (-not $item) { return $false }
    if ($item.action.type -eq 'files') { return [bool](@($item.action.paths | Where-Object { $_ -notlike "$env:USERPROFILE\*" }).Count) }
    $actions = switch ($item.action.type) {
        'actions' { @($Finding.fix.actions) }
        'tweaks'  { if ($Catalog) { @($item.action.ids | ForEach-Object { Get-D9Tweak $Catalog $_ } | Where-Object { $_ } | ForEach-Object { $_.actions }) } }
    }
    if (-not $actions) { return $true }
    [bool]@($actions | Where-Object { $_.type -ne 'registry' -or "$($_.path)" -notlike 'HKCU:*' }).Count
}

# Виконує виправлення однієї знахідки й повторно запускає лише її перевірку.
# Точка відновлення: перед твіками й діями її робить рушій, перед іншим — ця функція; -NoRestorePoint — уже є.
# Повертає { Done; Fixed; Fresh (нові знахідки цієї перевірки); Reboot; Note }
function Invoke-D9FindingFix {
    param([Parameter(Mandatory)]$Finding, [Parameter(Mandatory)]$Context, [switch]$NoRestorePoint, [string[]]$Paths)
    $item = New-D9ChecklistItemForFinding $Finding
    if ($item -and $item.action.type -eq 'files' -and $PSBoundParameters.ContainsKey('Paths')) { $item.action.paths = @($Paths) }
    if (-not $item) { return [pscustomobject]@{ Done = $false; Fixed = $false; Fresh = @($Finding); Reboot = $false; Note = (T-D9 'Це потрібно зробити вручну.') } }
    $list = [pscustomobject]@{ items = @($item) }
    $type = $item.action.type
    if (-not $NoRestorePoint -and $type -in 'maintenance', 'apps', 'uninstall') {
        if (-not (New-D9RestorePoint)) { Write-D9Log (T-D9 '  Не вдалося створити точку відновлення (захист системи вимкнено?)') Warn }
        $NoRestorePoint = $true
    }
    if ($NoRestorePoint -and $type -in 'tweaks', 'actions') {
        # Позначка «точку вже створено» для Invoke-D9ChecklistStep
        $list.items = @($item, [pscustomobject]@{ action = @{ type = 'restorePoint' }; status = 'done' })
    }
    $done = $false
    try { $done = Invoke-D9ChecklistStep -Checklist $list -Item $item -Context $Context -NoSave }
    catch { Write-D9Log (T-D9 '  Помилка: {0}' $_.Exception.Message) Error; $item.note = $_.Exception.Message }
    $fresh = @((Invoke-D9Scan -Context $Context -OnlyChecks @($Finding.checkId)).findings)
    $still = @($fresh | Where-Object key -eq $Finding.key)
    $reboot = [bool]$item.action.reboot -or ("$($item.note)" -eq (T-D9 'потрібне перезавантаження')) -or
        [bool](@($item.action.ids | Where-Object { $_ } | ForEach-Object { Get-D9Tweak $Context.Catalog $_ } | Where-Object rebootRequired).Count -and $type -eq 'tweaks')
    [pscustomobject]@{ Done = [bool]$done; Fixed = -not $still; Fresh = $fresh; Reboot = $reboot; Note = "$($item.note)" }
}

# «Як виправити»: нумеровані кроки з checks.json (поле guide { uk: [...], en: [...] }) для перевірки знахідки.
# Без гайда — порожньо (тоді показуємо details і посилання знахідки).
function Get-D9FindingGuide {
    param([Parameter(Mandatory)]$Finding, $Config)
    if (-not $Config) { $Config = ConvertFrom-Json (Get-D9ConfigText 'checks.json') }
    $check = @($Config.checks) | Where-Object id -eq $Finding.checkId | Select-Object -First 1
    if (-not $check -or -not $check.guide) { return @() }
    $steps = $check.guide.$script:D9Language
    if (-not $steps) { $steps = $check.guide.en }
    if (-not $steps) { $steps = $check.guide.uk }
    @($steps | ForEach-Object { [string]$_ })
}

# Кнопка в рядку знахідки: fix — «Виправити» (Debora зробить сама), guide — «Як виправити» (ручне),
# $null — без кнопки (відомості, для яких немає ні виправлення, ні інструкції)
function Get-D9FindingFixKind {
    param([Parameter(Mandatory)]$Finding, $Config)
    if (New-D9ChecklistItemForFinding $Finding) { return 'fix' }
    if ($Finding.severity -eq 'info' -and -not @(Get-D9FindingGuide $Finding $Config).Count) { return $null }
    'guide'
}
