<#
.SYNOPSIS
    Debloater9 — оптимізація та деблоат Windows 10/11 з точним відкатом.

.DESCRIPTION
    Етап 1: режим командного рядка. Графічний інтерфейс з'явиться на етапі 2.

.EXAMPLE
    .\Debloater9.ps1                              # відомості про систему й рекомендований профіль
.EXAMPLE
    .\Debloater9.ps1 -ListTweaks                  # каталог із поточним станом
.EXAMPLE
    .\Debloater9.ps1 -Preset Recommended -WhatIf  # що зміниться, без змін
.EXAMPLE
    .\Debloater9.ps1 -Preset WeakPC -Yes          # застосувати профіль
.EXAMPLE
    .\Debloater9.ps1 -Tweak ui.explorer,perf.game-dvr -Yes
.EXAMPLE
    .\Debloater9.ps1 -ListSessions
.EXAMPLE
    .\Debloater9.ps1 -Undo 2026-10-10T14-32-05-a1b2 -Yes
.EXAMPLE
    .\Debloater9.ps1 -Scan                        # сканування стану, оцінка й чекліст
.EXAMPLE
    .\Debloater9.ps1 -Scan -Deep -Report C:\report.html
.EXAMPLE
    .\Debloater9.ps1 -Checklist                   # чекліст з автоматичними галочками
.EXAMPLE
    .\Debloater9.ps1 -Checklist -Run All -Yes     # виконати всі автоматичні кроки
.EXAMPLE
    .\Debloater9.ps1 -Checklist -Done 3           # позначити ручний крок 3 виконаним
.EXAMPLE
    .\Debloater9.ps1 -Drivers                     # які драйвери потрібні і де їх взяти
.EXAMPLE
    .\Debloater9.ps1 -DriverInstall D:\Драйвери   # встановити підходящі драйвери з папки
#>
[CmdletBinding(DefaultParameterSetName = 'Info')]
param(
    [Parameter(ParameterSetName = 'Gui', Mandatory)]
    [switch]$Gui,

    # Побудувати вікно без показу й вийти: перевірка, що інтерфейс відкриється на цьому ПК
    [Parameter(ParameterSetName = 'Gui')]
    [switch]$SelfTest,

    [Parameter(ParameterSetName = 'Menu', Mandatory)]
    [switch]$Menu,

    [Parameter(ParameterSetName = 'Drivers', Mandatory)]
    [switch]$Drivers,

    [Parameter(ParameterSetName = 'DriverInstall', Mandatory)]
    [string]$DriverInstall,

    [Parameter(ParameterSetName = 'Scan', Mandatory)]
    [switch]$Scan,

    [Parameter(ParameterSetName = 'Scan')]
    [switch]$Deep,

    [Parameter(ParameterSetName = 'Scan')]
    [Parameter(ParameterSetName = 'Checklist')]
    [string]$Report,

    [Parameter(ParameterSetName = 'Checklist', Mandatory)]
    [switch]$Checklist,

    [Parameter(ParameterSetName = 'Checklist')]
    [string]$Run,

    [Parameter(ParameterSetName = 'Checklist')]
    [int[]]$Done,

    [Parameter(ParameterSetName = 'Checklist')]
    [switch]$AllowReboot,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateSet('Recommended', 'Minimal', 'Standard', 'WeakPC', 'Gaming', 'Maximum')]
    [string]$Preset,

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$Tweak,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$WhatIf,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'DriverInstall')]
    [switch]$NoRestorePoint,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListTweaks,

    [Parameter(ParameterSetName = 'Sessions')]
    [switch]$ListSessions,

    [Parameter(ParameterSetName = 'Undo')]
    [string]$Undo,

    [Parameter(ParameterSetName = 'Undo')]
    [string[]]$UndoTweak,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Undo')]
    [Parameter(ParameterSetName = 'Checklist')]
    [Parameter(ParameterSetName = 'DriverInstall')]
    [switch]$Yes,

    [ValidateSet('uk', 'en')]
    [string]$Language = 'uk',

    [string]$LogPath
)

#region D9-LOAD
# У режимі розробки підвантажуємо модулі з src/ і конфігурацію з config/.
# Compile.ps1 замінює цей блок на вбудований код і JSON.
$script:D9SrcRoot = $PSScriptRoot
foreach ($file in @('core\Common.ps1', 'core\Catalog.ps1', 'core\SystemInfo.ps1', 'core\Recommender.ps1', 'core\Journal.ps1', 'core\Engine.ps1')) {
    . (Join-Path $script:D9SrcRoot $file)
}
foreach ($d9ModuleDir in 'actions', 'scan', 'drivers', 'maintenance', 'ui') {
    Get-ChildItem (Join-Path $script:D9SrcRoot $d9ModuleDir) -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
}
$script:D9ConfigDir    = Join-Path (Split-Path $script:D9SrcRoot -Parent) 'config'
$script:D9KnowledgeDir = Join-Path (Split-Path $script:D9SrcRoot -Parent) 'knowledge'
$script:D9UiDir        = Join-Path $script:D9SrcRoot 'ui'
#endregion D9-LOAD

$script:D9Version  = '0.6.1-dev'
$script:D9Language = $Language
$script:D9LogPath  = $LogPath
Initialize-D9Console

$ExitCodes = @{ Ok = 0; Partial = 1; BadArgs = 2; NotAdmin = 3; Cancelled = 4; Reboot = 10 }

function Write-D9SystemSummary {
    param($Sys, $Recommendation)
    $disk = @{ hdd = 'HDD'; ssd = 'SSD'; nvme = 'NVMe SSD'; unknown = 'не визначено' }[$Sys.SystemDisk]
    Write-Host ""
    Write-Host "Debloater9 $script:D9Version" -ForegroundColor Cyan
    Write-Host ("  Система   {0} {1} ({2})" -f $Sys.OsName, $Sys.DisplayVersion, $Sys.Build)
    Write-Host ("  ПК        {0} {1}" -f $Sys.Manufacturer, $Sys.Model)
    Write-Host ("  Процесор  {0}, ядер: {1}" -f $Sys.Cpu, $Sys.Cores)
    Write-Host ("  Пам'ять   {0} ГБ" -f $Sys.RamGB)
    Write-Host ("  Диск C:   {0}" -f $disk)
    Write-Host ("  Батарея   {0}" -f $(if ($Sys.HasBattery) { 'так' } else { 'ні' }))
    Write-Host ("  Завантаж. {0} / {1}" -f $Sys.Firmware, $Sys.PartitionStyle)
    Write-Host ""
    Write-Host ("Рекомендований профіль: {0}" -f $Recommendation.Preset) -ForegroundColor Green
    foreach ($r in $Recommendation.Reasons) { Write-Host "  - $r" }
    Write-Host ""
}

function Confirm-D9 {
    param([string]$Question)
    if ($Yes) { return $true }
    if (-not [Environment]::UserInteractive) { return $false }
    $answer = Read-Host "$Question [y/N]"
    return $answer -match '^(y|yes|т|так)$'
}

$script:D9SevStyle = @{
    critical   = @{ Icon = 'X'; Name = 'Критично';        Color = 'Red' }
    warning    = @{ Icon = '!'; Name = 'Варто виправити'; Color = 'Yellow' }
    suggestion = @{ Icon = '*'; Name = 'Поради';          Color = 'Cyan' }
    info       = @{ Icon = 'i'; Name = 'Відомості';       Color = 'Gray' }
}

function Write-D9ScanResult {
    param($ScanResult, $Categories)
    $color = @{ good = 'Green'; attention = 'Yellow'; serious = 'Red' }[$ScanResult.score.verdict]
    $text  = @{ good = 'Добрий стан'; attention = 'Потребує уваги'; serious = 'Є серйозні проблеми' }[$ScanResult.score.verdict]
    Write-Host ""
    Write-Host ("  {0} / 100   {1}" -f $ScanResult.score.overall, $text) -ForegroundColor $color
    $cats = foreach ($c in $Categories) {
        $v = $ScanResult.score.categories.($c.id)
        if ($null -ne $v) { "{0} {1}" -f (Get-D9Text $c.name), $v }
    }
    Write-Host ("  " + ($cats -join ' · ')) -ForegroundColor DarkGray
    foreach ($sev in 'critical', 'warning', 'suggestion', 'info') {
        $group = @($ScanResult.findings | Where-Object severity -eq $sev)
        if (-not $group) { continue }
        $st = $script:D9SevStyle[$sev]
        Write-Host ""
        Write-Host "$($st.Name) ($($group.Count))" -ForegroundColor $st.Color
        foreach ($f in $group) {
            Write-Host "  [$($st.Icon)] $($f.title)" -ForegroundColor $st.Color
            if ($f.details) { Write-Host "      $($f.details)" -ForegroundColor DarkGray }
        }
    }
    $notChecked = @($ScanResult.checks | Where-Object { $_.status -in 'skipped', 'error' })
    if ($notChecked) {
        Write-Host ""
        Write-Host "Не перевірено: " -NoNewline -ForegroundColor DarkGray
        Write-Host (($notChecked | ForEach-Object { "$($_.name) ($($_.note))" }) -join '; ') -ForegroundColor DarkGray
    }
}

function Write-D9Checklist {
    param($List)
    $items = @($List.items)
    if (-not $items) { Write-Host ""; Write-Host "Чекліст порожній — нічого робити не потрібно." -ForegroundColor Green; return }
    $doneCount = @($items | Where-Object status -eq 'done').Count
    Write-Host ""
    Write-Host ("Чекліст: {0} — виконано {1} з {2}" -f $List.model, $doneCount, $items.Count) -ForegroundColor Cyan
    foreach ($i in $items) {
        $box  = if ($i.status -eq 'done') { '[x]' } else { '[ ]' }
        $kind = if ($i.auto) { 'авто' } else { 'вручну' }
        $c    = if ($i.status -eq 'done') { 'DarkGray' } elseif ($i.auto) { 'White' } else { 'Yellow' }
        Write-Host (" {0} {1,2}. {2}  ({3})" -f $box, $i.number, $i.title, $kind) -ForegroundColor $c
        if ($i.status -eq 'done') { continue }
        if ($i.why) { Write-Host "        $($i.why)" -ForegroundColor DarkGray }
        foreach ($l in @($i.links)) { Write-Host "        -> $($l.label): $($l.url)" -ForegroundColor DarkCyan }
        $deps = @($i.dependsOn | ForEach-Object { $id = $_; ($items | Where-Object id -eq $id).number } | Where-Object { $_ } | Sort-Object)
        if ($deps) { Write-Host "        після кроку $($deps -join ', ')" -ForegroundColor DarkGray }
    }
    $autoLeft = @($items | Where-Object { $_.auto -and $_.status -ne 'done' }).Count
    Write-Host ""
    if ($autoLeft) { Write-Host "Автоматичних кроків: $autoLeft. Виконати: -Checklist -Run All   (ручний крок позначити: -Checklist -Done <номер>)" }
}

function Save-D9HtmlReport {
    param($ScanResult, $List, $Categories, [string]$Path)
    $html = ConvertTo-D9ScanHtml -Scan $ScanResult -Checklist $List -Categories $Categories
    [IO.File]::WriteAllText($Path, $html, (New-Object Text.UTF8Encoding $false))
    Write-D9Log "Звіт збережено: $Path" Ok
}

# ---------------------------------------------------------------------
$catalog = Import-D9Catalog
$catalogErrors = Test-D9Catalog $catalog
if ($catalogErrors.Count) {
    Write-D9Log "Помилки в каталозі твіків:" Error
    $catalogErrors | ForEach-Object { Write-D9Log "  $_" Error }
    exit $ExitCodes.BadArgs
}

$sys = Get-D9SystemInfo
$recommendation = Get-D9RecommendedPreset $sys

switch ($PSCmdlet.ParameterSetName) {

    'Gui' {
        $base = Split-Path $PSCommandPath
        if ($SelfTest) {
            try {
                $r = Show-D9Gui -Catalog $catalog -SystemInfo $sys -Recommendation $recommendation -ReportDir (Join-Path $base 'Звіти') -DriverDir (Join-Path $base 'Драйвери') -TestAction { "вікно побудовано: вкладок $($ui.Tabs.Items.Count)" }
                Write-D9Log "Самоперевірка інтерфейсу: $r" Ok
                exit $ExitCodes.Ok
            } catch { Write-D9Log "Самоперевірка інтерфейсу не пройшла: $($_.Exception.Message)" Error; exit $ExitCodes.Partial }
        }
        try {
            Show-D9Gui -Catalog $catalog -SystemInfo $sys -Recommendation $recommendation -ReportDir (Join-Path $base 'Звіти') -DriverDir (Join-Path $base 'Драйвери')
        } catch {
            # Якщо вікно не відкрилось (немає WPF, пошкоджені шрифти тощо) — показуємо текстове меню
            # run.bat запускає вікно з прихованою консоллю — меню відкриваємо в новому видимому вікні
            $err = $_.Exception.Message
            try { Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show("Не вдалося відкрити вікно програми:`n$err`n`nЗараз відкриється текстове меню.", 'Debloater9', 'OK', 'Warning') } catch { }
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Menu"
        }
        exit $ExitCodes.Ok
    }

    'Menu' {
        # Просте меню для людей: кожен пункт запускає цей самий скрипт з потрібними параметрами
        $self = $PSCommandPath
        $reports = Join-Path (Split-Path $self) 'Звіти'
        $runSelf = { param([string[]]$Arguments) & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $self @Arguments }
        $lastReport = { Get-ChildItem $reports -Filter '*.html' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
        if (-not (Test-D9IsAdmin)) { Write-D9Log "Увага: запущено без прав адміністратора — частина перевірок і всі зміни недоступні. Запускайте через run.bat." Warn }
        while ($true) {
            Write-Host ""
            Write-Host "Debloater9 $script:D9Version — $($sys.Manufacturer) $($sys.Model), $($sys.OsName) $($sys.DisplayVersion)" -ForegroundColor Cyan
            Write-Host "Рекомендований профіль: $($recommendation.Preset) ($($recommendation.Reasons -join '; '))" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  1. Перевірити комп'ютер (сканування й звіт)"
            Write-Host "  2. Показати чекліст «що робити»"
            Write-Host "  3. Виконати автоматичні кроки чекліста"
            Write-Host "  4. Застосувати рекомендований профіль налаштувань ($($recommendation.Preset))"
            Write-Host "  5. Відкотити останні зміни"
            Write-Host "  6. Відкрити останній звіт"
            Write-Host "  7. Драйвери: що потрібно і де взяти"
            Write-Host "  8. Встановити драйвери з папки «Драйвери»"
            Write-Host "  0. Вихід"
            $choice = Read-Host "Ваш вибір"
            switch ($choice) {
                '1' {
                    if (-not (Test-Path $reports)) { New-Item -ItemType Directory -Path $reports | Out-Null }
                    $file = Join-Path $reports ("Звіт {0:yyyy-MM-dd HH-mm}.html" -f (Get-Date))
                    & $runSelf @('-Scan', '-Report', $file)
                    if (Test-Path $file) { Start-Process $file }
                }
                '2' { & $runSelf @('-Checklist') }
                '3' {
                    & $runSelf @('-Checklist', '-Run', 'All')
                    $answer = Read-Host "Перезавантажити комп'ютер зараз, щоб зміни запрацювали? [y/N]"
                    if ($answer -match '^(y|т|так)$') { Restart-Computer -Force }
                }
                '4' {
                    & $runSelf @('-Preset', 'Recommended', '-WhatIf')
                    & $runSelf @('-Preset', 'Recommended')
                }
                '5' {
                    $last = Get-D9SessionList | Where-Object { -not $_.Undone -and $_.Changed -gt 0 } | Select-Object -First 1
                    if (-not $last) { Write-D9Log "Немає змін, які можна відкотити." Ok }
                    else {
                        Write-Host "Остання сесія: $($last.Started), $($last.Selection), змін: $($last.Changed)"
                        & $runSelf @('-Undo', $last.Id)
                    }
                }
                '6' {
                    $r = & $lastReport
                    if ($r) { Start-Process $r.FullName } else { Write-D9Log "Звітів ще немає — спочатку пункт 1." Warn }
                }
                '7' { & $runSelf @('-Drivers') }
                '8' {
                    $folder = Join-Path (Split-Path $self) 'Драйвери'
                    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
                    if (-not (Get-ChildItem $folder -Recurse -File -ErrorAction SilentlyContinue)) {
                        Write-Host ""
                        Write-Host "Папка «Драйвери» порожня: $folder" -ForegroundColor Yellow
                        Write-Host "Завантажте драйвери з сайту виробника (пункт 7 покаже посилання) і покладіть сюди файли як є — .zip теж можна."
                        Start-Process explorer.exe $folder
                    } else {
                        & $runSelf @('-DriverInstall', $folder)
                    }
                }
                '0' { exit $ExitCodes.Ok }
                default { Write-Host "Введіть номер пункту." -ForegroundColor Yellow }
            }
        }
    }

    'Drivers' {
        Write-Host ""
        Write-Host "Драйвери: $($sys.Manufacturer) $($sys.Model), $($sys.OsName) $($sys.DisplayVersion)" -ForegroundColor Cyan
        $rep = Get-D9DriverReport $sys
        if ($rep.Oem) {
            Write-Host ""
            Write-Host "Сторінка драйверів $($rep.Oem.Name) для цієї моделі (найкраще джерело):" -ForegroundColor Green
            Write-Host "  $($rep.Oem.Url)"
            if ($rep.Oem.Note) { Write-Host "  $($rep.Oem.Note)" -ForegroundColor DarkGray }
            if ($rep.Oem.Serial) { Write-Host "  Серійний номер: $($rep.Oem.Serial)" -ForegroundColor DarkGray }
        }
        Write-Host ""
        if ($rep.Problems) {
            Write-Host "Без драйвера або з помилкою ($($rep.Problems.Count)):" -ForegroundColor Yellow
            foreach ($p in ($rep.Problems | Sort-Object { if ($_.Class -eq 'Net') { 0 } else { 1 } })) {
                Write-Host "  [!] $($p.Name) — $($p.Reason)" -ForegroundColor Yellow
                if ($p.Windows -and $p.Windows -ne $p.Name) { Write-Host "      Windows називає: $($p.Windows)" -ForegroundColor DarkGray }
                Write-Host "      ID: $($p.Info.HardwareId)" -ForegroundColor DarkGray
                foreach ($l in $p.Links) { Write-Host "      -> $($l.label): $($l.url)" -ForegroundColor DarkCyan }
            }
        } else {
            Write-Host "Усі пристрої мають драйвери." -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "Важливі драйвери (версія, дата):" -ForegroundColor Cyan
        $rep.Important | Format-Table Group, Name, Version, Date, Provider -AutoSize | Out-String -Width 200 | Write-Host
        Write-Host "Як оновити: завантажте драйвери з сайту виробника в папку «Драйвери» поруч із програмою й виберіть у меню пункт 8." -ForegroundColor DarkGray
        Write-Host "Програма сама підбере, що підходить до цього ПК, і поставить у правильному порядку (з можливістю відкату)." -ForegroundColor DarkGray
        exit $ExitCodes.Ok
    }

    'DriverInstall' {
        if (-not (Test-Path -LiteralPath $DriverInstall)) { Write-D9Log "Папку не знайдено: $DriverInstall" Error; exit $ExitCodes.BadArgs }
        Write-D9Log "Аналіз драйверів у $DriverInstall ..."
        $found = Find-D9DriverPackages -Folder $DriverInstall
        Write-Host ""
        Write-Host "INF-файлів знайдено: $($found.Infs). Підходять до цього ПК: $($found.Packages.Count)." -ForegroundColor Cyan
        $statusText = @{ missing = 'немає драйвера — встановити'; newer = 'новіший — оновити'; current = 'вже актуальний' }
        $n = 0
        foreach ($p in $found.Packages) {
            $n++
            $cur = @($p.Current | ForEach-Object { $_.version } | Where-Object { $_ } | Sort-Object -Unique) -join ', '
            $color = @{ missing = 'Yellow'; newer = 'White'; current = 'DarkGray' }[$p.Status]
            Write-Host ("  {0,2}. {1} [{2}]" -f $n, $p.Name, $statusText[$p.Status]) -ForegroundColor $color
            $date = if ($p.Package.Inf.Date) { $p.Package.Inf.Date.ToString('dd.MM.yyyy') } else { '?' }
            Write-Host ("      зараз: {0}; у папці: {1} ({2}) — {3}" -f $(if ($cur) { $cur } else { 'немає' }), $p.Package.Inf.Version, $date, (Split-Path $p.Package.Inf.Path -Leaf)) -ForegroundColor DarkGray
        }
        if ($found.Installers) {
            Write-Host ""
            Write-Host "Пакети лише з інсталятором — запустіть вручну, якщо цей пристрій є в ПК ($(@($found.Installers).Count)):" -ForegroundColor Yellow
            foreach ($i in $found.Installers) { Write-Host "  - $($i.Package): $($i.Path)" -ForegroundColor DarkGray }
        }
        $todo = @($found.Packages | Where-Object Status -ne 'current')
        if (-not $todo) {
            Write-Host ""
            Write-D9Log "Нічого встановлювати: усе з папки вже стоїть або новіше." Ok
            exit $ExitCodes.Ok
        }
        if (-not (Test-D9IsAdmin)) { Write-D9Log "Для встановлення потрібні права адміністратора (запускайте через run.bat)." Error; exit $ExitCodes.NotAdmin }
        Write-Host ""
        if (-not (Confirm-D9 "Встановити $($todo.Count) драйвер(ів) у показаному порядку? Попередні буде збережено для відкату")) { exit $ExitCodes.Cancelled }
        $drvCatalog = New-D9DriverCatalog -Packages $todo
        $plan = New-D9Plan -Catalog $drvCatalog -TweakIds @($drvCatalog.Tweaks.id) -SystemInfo $sys
        $session = Invoke-D9Plan -Plan $plan -SystemInfo $sys -Selection "драйвери з $DriverInstall" -NoRestorePoint:$NoRestorePoint
        $ok = @($session.entries | Where-Object result -eq 'ok').Count
        $errors = @($session.entries | Where-Object result -eq 'error')
        Write-Host ""
        Write-D9Log ("Встановлено: {0}, помилок: {1}. Сесія: {2}" -f $ok, $errors.Count, $session.id) $(if ($errors) { 'Warn' } else { 'Ok' })
        Write-D9Log "Перезавантажте комп'ютер, щоб драйвери запрацювали. Відкат: меню → 5." Warn
        $left = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -notin 22, 45 })
        if ($left) { Write-Host "Ще без драйвера: $(($left | ForEach-Object { Get-D9DeviceDisplayName (Resolve-D9Device @($_.HardwareID)) $_.Name }) -join ', ')" -ForegroundColor Yellow }
        exit $(if ($errors) { $ExitCodes.Partial } else { $ExitCodes.Reboot })
    }

    'Scan' {
        $scanConfig = Import-D9ScanConfig
        $ctx = New-D9ScanContext -Catalog $catalog -SystemInfo $sys -ScanConfig $scanConfig -Deep:$Deep
        Write-Host ""
        Write-Host ("Debloater9 {0} — сканування{1}: {2} {3}" -f $script:D9Version, $(if ($Deep) { ' (глибоке)' } else { '' }), $sys.Manufacturer, $sys.Model) -ForegroundColor Cyan
        if (-not $ctx.IsAdmin) { Write-D9Log "Без прав адміністратора частину перевірок пропущено. Для повного сканування запустіть від адміністратора." Warn }
        $result = Invoke-D9Scan -Context $ctx
        $path = Save-D9Scan $result
        Write-D9ScanResult $result $scanConfig.Checks.categories

        $list = New-D9Checklist -Scan $result -Catalog $catalog
        $list = Merge-D9ChecklistState -New $list -Old (Get-D9Checklist)
        Save-D9Checklist $list
        Write-D9Checklist $list
        if ($Report) { Save-D9HtmlReport $result $list $scanConfig.Checks.categories $Report }
        Write-Host ""
        Write-Host ("Сканування: {0} с. Результат: {1}" -f $result.durationSec, $path) -ForegroundColor DarkGray
        exit $(switch ($result.score.verdict) { 'good' { 0 } 'attention' { 1 } default { 2 } })
    }

    'Checklist' {
        $list = Get-D9Checklist
        if (-not $list) { Write-D9Log "Чекліста ще немає. Спочатку запустіть: -Scan" Warn; exit $ExitCodes.BadArgs }
        $scanConfig = Import-D9ScanConfig
        $ctx = New-D9ScanContext -Catalog $catalog -SystemInfo $sys -ScanConfig $scanConfig

        foreach ($n in @($Done | Where-Object { $_ })) {
            $item = $list.items | Where-Object number -eq $n
            if (-not $item) { Write-D9Log "Кроку $n немає" Error; exit $ExitCodes.BadArgs }
            $item.status = 'done'; $item.doneAt = (Get-Date).ToString('s'); $item.note = 'позначено вручну'
        }

        if ($Run) {
            $targets = if ($Run -eq 'All') { @($list.items | Where-Object { $_.auto -and $_.status -ne 'done' }) }
                       else { @($list.items | Where-Object { $_.number -in @($Run -split ',' | ForEach-Object { [int]$_ }) }) }
            $targets = @($targets | Sort-Object number)
            if (-not $targets) { Write-D9Log "Немає кроків для виконання." Ok }
            else {
                if (-not (Test-D9IsAdmin)) { Write-D9Log "Потрібні права адміністратора." Error; exit $ExitCodes.NotAdmin }
                Write-Host ("Буде виконано кроки: " + (($targets | ForEach-Object { "$($_.number). $($_.title)" }) -join '; '))
                if (-not (Confirm-D9 "Продовжити?")) { exit $ExitCodes.Cancelled }
                foreach ($item in $targets) {
                    if ($item.action.type -eq 'maintenance' -and $item.action.action -eq 'reboot' -and $Run -eq 'All' -and -not $AllowReboot) { continue }
                    if (-not (Test-D9ChecklistReady $list $item)) { Write-D9Log "Крок $($item.number) пропущено: спершу виконайте попередні кроки" Warn; continue }
                    try { [void](Invoke-D9ChecklistStep -Checklist $list -Item $item -Context $ctx -AllowReboot:$AllowReboot) }
                    catch { Write-D9Log "  Помилка: $($_.Exception.Message)" Error }
                }
            }
        }

        Write-D9Log "Перевірка виконаних кроків..." Detail
        $list = Update-D9ChecklistStatus -Checklist $list -Context $ctx
        Save-D9Checklist $list
        Write-D9Checklist $list
        if ($Report) {
            $last = Get-ChildItem (Get-D9ScanDir) -Filter '*.json' | Sort-Object Name -Descending | Select-Object -First 1
            if ($last) { Save-D9HtmlReport (ConvertFrom-Json ([IO.File]::ReadAllText($last.FullName, [Text.Encoding]::UTF8))) $list $scanConfig.Checks.categories $Report }
        }
        exit $ExitCodes.Ok
    }

    'Info' {
        Write-D9SystemSummary $sys $recommendation
        Write-Host "Що далі:"
        Write-Host "  -Scan                           перевірити стан Windows і отримати чекліст"
        Write-Host "  -ListTweaks                     каталог твіків і їхній стан"
        Write-Host "  -Preset Recommended -WhatIf     що зміниться за рекомендованим профілем"
        Write-Host "  -Preset Recommended -Yes        застосувати"
        Write-Host "  Get-Help .\Debloater9.ps1 -Examples"
        exit $ExitCodes.Ok
    }

    'List' {
        $stateNames = @{ applied = 'застосовано'; partial = 'частково'; notApplied = '-'; notApplicable = 'н/д'; unknown = '?' }
        $riskNames  = @{ safe = 'безпечно'; moderate = 'помірно'; expert = 'експертний' }
        $catalog.Tweaks | ForEach-Object {
            $check = Test-D9Applicable $_.requires $sys
            [pscustomobject]@{
                Id    = $_.id
                Name  = Get-D9Text $_.name
                Risk  = $riskNames[$_.risk]
                State = $stateNames[(Get-D9TweakState $_ $sys)]
                Note  = $check.Reason
            }
        } | Format-Table -AutoSize -Wrap
        exit $ExitCodes.Ok
    }

    'Sessions' {
        $list = @(Get-D9SessionList)
        if (-not $list) { Write-Host "Сесій ще немає."; exit $ExitCodes.Ok }
        $list | Format-Table -AutoSize
        exit $ExitCodes.Ok
    }

    'Undo' {
        if (-not (Test-D9IsAdmin)) { Write-D9Log "Потрібні права адміністратора." Error; exit $ExitCodes.NotAdmin }
        $session = Get-D9Session $Undo
        $count = @($session.entries | Where-Object { $_.result -eq 'ok' -and (-not $UndoTweak -or $UndoTweak -contains $_.tweak) }).Count
        Write-Host "Сесія $($session.id) ($($session.selection)): змін для відкату — $count"
        if (-not (Confirm-D9 "Відкотити?")) { exit $ExitCodes.Cancelled }
        $report = Undo-D9Session -Id $Undo -TweakIds $UndoTweak
        $bad = @($report | Where-Object { $_.result -in 'error', 'conflict', 'manual' }).Count
        Write-D9Log ("Відкочено: {0}, потребує уваги: {1}" -f @($report | Where-Object result -eq 'restored').Count, $bad) $(if ($bad) { 'Warn' } else { 'Ok' })
        exit $(if ($bad) { $ExitCodes.Partial } else { $ExitCodes.Ok })
    }

    'Apply' {
        if (-not $Preset -and -not $Tweak) { Write-D9Log "Вкажіть -Preset або -Tweak." Error; exit $ExitCodes.BadArgs }
        $presetId = if ($Preset -eq 'Recommended') { $recommendation.Preset } else { $Preset }
        $ids = @()
        if ($presetId) { $ids += @((Get-D9Preset $catalog $presetId).tweaks) }
        if ($Tweak)    { $ids += $Tweak }
        $selection = (@($presetId) + @($Tweak) | Where-Object { $_ }) -join ', '

        $plan = New-D9Plan -Catalog $catalog -TweakIds $ids -SystemInfo $sys
        $unknown = @($plan | Where-Object { -not $_.Tweak })
        if ($unknown) { Write-D9Log ("Невідомі твіки: " + ($unknown.Id -join ', ')) Error; exit $ExitCodes.BadArgs }

        Write-D9SystemSummary $sys $recommendation
        Write-Host "План ($selection):" -ForegroundColor Cyan
        $preview = @(Get-D9Preview -Plan $plan -SystemInfo $sys)
        foreach ($group in ($preview | Group-Object Tweak)) {
            $pending = @($group.Group | Where-Object Pending)
            $mark = if ($pending) { '*' } else { ' ' }
            Write-Host " $mark $($group.Name)"
            foreach ($p in $group.Group) {
                if ($p.Pending -or $p.Change -like 'пропущено*') { Write-Host "      $($p.Change)" -ForegroundColor $(if ($p.Pending) { 'Gray' } else { 'DarkYellow' }) }
            }
        }
        $pendingCount = @($preview | Where-Object Pending).Count
        Write-Host ""
        Write-Host "Змін до застосування: $pendingCount (* — твік має незастосовані зміни)"
        if ($WhatIf) { exit $ExitCodes.Ok }
        if ($pendingCount -eq 0) { Write-D9Log "Усе вже застосовано." Ok; exit $ExitCodes.Ok }

        if (-not (Test-D9IsAdmin)) { Write-D9Log "Потрібні права адміністратора." Error; exit $ExitCodes.NotAdmin }
        if (-not (Confirm-D9 "Застосувати $pendingCount змін?")) { exit $ExitCodes.Cancelled }

        $session = Invoke-D9Plan -Plan $plan -SystemInfo $sys -Selection $selection -NoRestorePoint:$NoRestorePoint
        $entries = @($session.entries)
        $ok      = @($entries | Where-Object result -eq 'ok').Count
        $errors  = @($entries | Where-Object result -eq 'error').Count
        Write-Host ""
        Write-D9Log ("Готово. Змінено: {0}, помилок: {1}. Сесія: {2}" -f $ok, $errors, $session.id) $(if ($errors) { 'Warn' } else { 'Ok' })
        Write-D9Log "Відкат: .\Debloater9.ps1 -Undo $($session.id)"
        $reboot = @($plan | Where-Object { $_.Run -and $_.Tweak.rebootRequired }).Count -gt 0
        if ($reboot) { Write-D9Log "Деякі зміни запрацюють після перезавантаження." Warn }
        if ($errors) { exit $ExitCodes.Partial }
        if ($reboot) { exit $ExitCodes.Reboot }
        exit $ExitCodes.Ok
    }
}
