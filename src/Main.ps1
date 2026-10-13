<#
.SYNOPSIS
    Debora — оптимізація та деблоат Windows 10/11 з точним відкатом.

.DESCRIPTION
    Етап 1: режим командного рядка. Графічний інтерфейс з'явиться на етапі 2.

.EXAMPLE
    .\Debora.ps1                              # відомості про систему й рекомендований профіль
.EXAMPLE
    .\Debora.ps1 -ListTweaks                  # каталог із поточним станом
.EXAMPLE
    .\Debora.ps1 -Preset Recommended -WhatIf  # що зміниться, без змін
.EXAMPLE
    .\Debora.ps1 -Preset WeakPC -Yes          # застосувати профіль
.EXAMPLE
    .\Debora.ps1 -Tweak ui.explorer,perf.game-dvr -Yes
.EXAMPLE
    .\Debora.ps1 -ListSessions
.EXAMPLE
    .\Debora.ps1 -Undo 2026-10-10T14-32-05-a1b2 -Yes
.EXAMPLE
    .\Debora.ps1 -Scan                        # сканування стану, оцінка й чекліст
.EXAMPLE
    .\Debora.ps1 -Scan -Deep -Report C:\report.html
.EXAMPLE
    .\Debora.ps1 -Checklist                   # чекліст з автоматичними галочками
.EXAMPLE
    .\Debora.ps1 -Checklist -Run All -Yes     # виконати всі автоматичні кроки
.EXAMPLE
    .\Debora.ps1 -Checklist -Done 3           # позначити ручний крок 3 виконаним
.EXAMPLE
    .\Debora.ps1 -Drivers                     # які драйвери потрібні і де їх взяти
.EXAMPLE
    .\Debora.ps1 -Drivers -DeviceView hardware -Csv .\devices.csv   # усі пристрої з драйверами + CSV
.EXAMPLE
    .\Debora.ps1 -DriverInstall D:\Драйвери   # встановити підходящі драйвери з папки
.EXAMPLE
    .\Debora.ps1 -DriverUpdate -WhatIf        # які новіші драйвери є в каталозі Microsoft
.EXAMPLE
    .\Debora.ps1 -DriverUpdate -Yes           # знайти, завантажити й встановити (з відкатом)
.EXAMPLE
    .\Debora.ps1 -ExportDrivers D:\Драйвери-ПК       # зберегти всі драйвери цього ПК
.EXAMPLE
    .\Debora.ps1 -PrepareUsb E: -UserName Оля       # флешка з Windows → встановлення без запитань + драйвери
.EXAMPLE
    .\Debora.ps1 -Schedule Sunday -At 12:00     # щотижневе автоматичне обслуговування
.EXAMPLE
    .\Debora.ps1 -Maintain                      # обслуговування зараз (його ж запускає розклад)
.EXAMPLE
    .\Debora.ps1 -Apps                        # каталог програм і що вже встановлено
.EXAMPLE
    .\Debora.ps1 -InstallApp Google.Chrome,7zip.7zip -Yes
.EXAMPLE
    .\Debora.ps1 -UpgradeApps -Yes            # оновити всі програми (winget upgrade --all)
.EXAMPLE
    .\Debora.ps1 -Disks                       # стан дисків: температура, знос, помилки (SMART)
.EXAMPLE
    .\Debora.ps1 -Debloat -WhatIf             # що прибере рекомендований деблоат (без змін); без -WhatIf — виконати
    .\Debora.ps1 -Setup -WhatIf               # налаштування з нуля за збереженим профілем (-ProfilePath файл.json — інший профіль)
.EXAMPLE
    .\Debora.ps1 -Battery                    # стан батареї: знос, історія ємності, прогноз, поради
.EXAMPLE
    .\Debora.ps1 -Diagnostics                 # зібрати zip для розбору проблеми (у папку «Звіти»)
#>
[CmdletBinding(DefaultParameterSetName = 'Info')]
param(
    [Parameter(ParameterSetName = 'Gui', Mandatory)]
    [switch]$Gui,

    # Побудувати вікно без показу й вийти: перевірка, що інтерфейс відкриється на цьому ПК
    [Parameter(ParameterSetName = 'Gui')]
    [switch]$SelfTest,

    # Тема вікна: auto — як у Windows (Параметри → Персоналізація → Кольори)
    [Parameter(ParameterSetName = 'Gui')]
    [ValidateSet('auto', 'light', 'dark')]
    [string]$Theme = 'auto',

    # Стиль вікна: focus (основний) | swiss; auto — збережений вибір (кнопка «Стиль» у вікні)
    [Parameter(ParameterSetName = 'Gui')]
    [ValidateSet('auto', 'focus', 'swiss')]

    [Parameter(ParameterSetName = 'Menu', Mandatory)]
    [switch]$Menu,

    [Parameter(ParameterSetName = 'Drivers', Mandatory)]
    [switch]$Drivers,

    # Повний перелік пристроїв з драйверами: обладнання | усі | драйвери виробників | старші за 3 роки | з проблемами
    [Parameter(ParameterSetName = 'Drivers')]
    [ValidateSet('hardware', 'all', 'thirdparty', 'old', 'problems')]
    [string]$DeviceView,

    # Зберегти всі пристрої й драйвери у CSV (для Excel)
    [Parameter(ParameterSetName = 'Drivers')]
    [string]$Csv,

    [Parameter(ParameterSetName = 'DriverInstall', Mandatory)]
    [string]$DriverInstall,

    # Знайти новіші драйвери й драйвери для невпізнаних пристроїв в інтернеті (Microsoft Update Catalog + Windows Update), завантажити й встановити
    [Parameter(ParameterSetName = 'DriverUpdate', Mandatory)]
    [switch]$DriverUpdate,

    # Разом із необов'язковими: заміна робочих драйверів Windows на системних пристроях
    [Parameter(ParameterSetName = 'DriverUpdate')]
    [switch]$IncludeOptional,

    # Автоматичне обслуговування зараз: точка відновлення, очищення, бази Захисника, програми, драйвери (кроки — з налаштувань розкладу)
    [Parameter(ParameterSetName = 'Maintain', Mandatory)]
    [switch]$Maintain,

    # Щотижневий розклад обслуговування (день тижня) або Off — вимкнути
    [Parameter(ParameterSetName = 'Schedule', Mandatory)]
    [ValidateSet('Off', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string]$Schedule,

    [Parameter(ParameterSetName = 'Schedule')]
    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$At = '12:00',

    # Видалити встановлені програми за назвою (можна з *): -Uninstall "McAfee*","WildTangent*"
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [string[]]$Uninstall,

    [Parameter(ParameterSetName = 'ExportDrivers', Mandatory)]
    [string]$ExportDrivers,

    # Флешка з файлами встановлення Windows (Media Creation Tool / Rufus)
    [Parameter(ParameterSetName = 'PrepareUsb', Mandatory)]
    [string]$PrepareUsb,

    [Parameter(ParameterSetName = 'PrepareUsb')]
    [string]$UserName = 'User',

    # Пароль локального облікового запису (зберігається у файлі на флешці відкритим текстом); порожній — без пароля
    [Parameter(ParameterSetName = 'PrepareUsb')]
    [string]$AccountPassword = '',

    [Parameter(ParameterSetName = 'PrepareUsb')]
    [ValidateSet('', 'Home', 'Pro')]
    [string]$Edition = '',

    # Не обходити вимоги Windows 11 (TPM, Secure Boot, процесор, пам'ять)
    [Parameter(ParameterSetName = 'PrepareUsb')]
    [switch]$KeepRequirements,

    # Не копіювати драйвери цього ПК на флешку
    [Parameter(ParameterSetName = 'PrepareUsb')]
    [switch]$NoDrivers,

    [Parameter(ParameterSetName = 'Apps', Mandatory)]
    [switch]$Apps,

    # ID з каталогу (config/apps.json) або назви: Google.Chrome, "7-Zip"
    [Parameter(ParameterSetName = 'InstallApp', Mandatory)]
    [string[]]$InstallApp,

    [Parameter(ParameterSetName = 'UpgradeApps', Mandatory)]
    [switch]$UpgradeApps,

    [Parameter(ParameterSetName = 'Diagnostics', Mandatory)]
    [switch]$Diagnostics,

    [Parameter(ParameterSetName = 'Disks', Mandatory)]
    [switch]$Disks,

    [Parameter(ParameterSetName = 'Battery', Mandatory)]
    [switch]$Battery,

    # Рекомендований деблоат: нав'язані вбудовані застосунки + реклама, Copilot, Recall, телеметрія
    [Parameter(ParameterSetName = 'Debloat', Mandatory)]
    [switch]$Debloat,

    [Parameter(ParameterSetName = 'Setup', Mandatory)]
    [switch]$Setup,

    [Parameter(ParameterSetName = 'Setup')]
    [Parameter(ParameterSetName = 'PrepareUsb')]
    [string]$ProfilePath,

    [Parameter(ParameterSetName = 'ExportProfile', Mandatory)]
    [string]$ExportProfile,

    # Куди покласти zip діагностики (типово — папка «Звіти» поруч із програмою)
    [Parameter(ParameterSetName = 'Diagnostics')]
    [string]$OutDir,

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
    [Parameter(ParameterSetName = 'PrepareUsb')]
    [ValidateSet('Recommended', 'Minimal', 'Standard', 'WeakPC', 'Gaming', 'Maximum')]
    [string]$Preset,

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$Tweak,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'DriverUpdate')]
    [Parameter(ParameterSetName = 'Debloat')]
    [Parameter(ParameterSetName = 'Setup')]
    [switch]$WhatIf,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'DriverInstall')]
    [Parameter(ParameterSetName = 'DriverUpdate')]
    [Parameter(ParameterSetName = 'Setup')]
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
    [Parameter(ParameterSetName = 'InstallApp')]
    [Parameter(ParameterSetName = 'UpgradeApps')]
    [Parameter(ParameterSetName = 'DriverUpdate')]
    [Parameter(ParameterSetName = 'Uninstall')]
    [Parameter(ParameterSetName = 'Debloat')]
    [Parameter(ParameterSetName = 'Setup')]
    [switch]$Yes,

    [ValidateSet('auto', 'uk', 'en')]
    [string]$Language = 'auto',

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
Add-D9BootMark 'modules'
if ($PSCmdlet.ParameterSetName -eq 'Gui') { Start-D9GuiWarmup; Add-D9BootMark 'warmup' }   # паралельно з рештою підготовки

$script:D9Version  = '0.39.0-dev'
$script:D9Language = Resolve-D9Language $Language
$script:D9ScriptPath = $PSCommandPath
if ($PSCmdlet.ParameterSetName -ne 'Gui') { Initialize-D9Console }   # у вікні консоль прихована — шрифт не потрібен
Initialize-D9LogFile -Path $LogPath -Mode $PSCmdlet.ParameterSetName
Add-D9BootMark 'log'

$ExitCodes = @{ Ok = 0; Partial = 1; BadArgs = 2; NotAdmin = 3; Cancelled = 4; Reboot = 10 }

function Write-D9SystemSummary {
    param($Sys, $Recommendation)
    $disk = @{ hdd = 'HDD'; ssd = 'SSD'; nvme = 'NVMe SSD'; unknown = (T-D9 'не визначено') }[$Sys.SystemDisk]
    Write-Host ""
    Write-Host "Debora $script:D9Version" -ForegroundColor Cyan
    Write-Host (T-D9 '  Система   {0} {1} ({2})' $Sys.OsName $Sys.DisplayVersion $Sys.Build)
    Write-Host (T-D9 '  ПК        {0} {1}' $Sys.Manufacturer $Sys.Model)
    Write-Host (T-D9 '  Процесор  {0}, ядер: {1}' $Sys.Cpu $Sys.Cores)
    Write-Host (T-D9 '  Пам''ять   {0} ГБ' $Sys.RamGB)
    Write-Host (T-D9 '  Диск C:   {0}' $disk)
    Write-Host (T-D9 '  Батарея   {0}' $(if ($Sys.HasBattery) { (T-D9 'так') } else { (T-D9 'ні') }))
    Write-Host (T-D9 '  Завантаж. {0} / {1}' $Sys.Firmware $Sys.PartitionStyle)
    Write-Host ""
    Write-Host (T-D9 'Рекомендований профіль: {0}' $Recommendation.Preset) -ForegroundColor Green
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
    critical   = @{ Icon = 'X'; Name = (T-D9 'Критично');        Color = 'Red' }
    warning    = @{ Icon = '!'; Name = (T-D9 'Варто виправити'); Color = 'Yellow' }
    suggestion = @{ Icon = '*'; Name = (T-D9 'Поради');          Color = 'Cyan' }
    info       = @{ Icon = 'i'; Name = (T-D9 'Відомості');       Color = 'Gray' }
}

function Write-D9ScanResult {
    param($ScanResult, $Categories)
    $color = @{ good = 'Green'; attention = 'Yellow'; serious = 'Red' }[$ScanResult.score.verdict]
    $text  = @{ good = (T-D9 'Добрий стан'); attention = (T-D9 'Потребує уваги'); serious = (T-D9 'Є серйозні проблеми') }[$ScanResult.score.verdict]
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
        Write-Host (T-D9 'Не перевірено: ') -NoNewline -ForegroundColor DarkGray
        Write-Host (($notChecked | ForEach-Object { "$($_.name) ($($_.note))" }) -join '; ') -ForegroundColor DarkGray
    }
}

function Write-D9Checklist {
    param($List)
    $items = @($List.items)
    if (-not $items) { Write-Host ""; Write-Host (T-D9 'Чекліст порожній — нічого робити не потрібно.') -ForegroundColor Green; return }
    $doneCount = @($items | Where-Object status -eq 'done').Count
    Write-Host ""
    Write-Host (T-D9 'Чекліст: {0} — виконано {1} з {2}' $List.model $doneCount $items.Count) -ForegroundColor Cyan
    foreach ($i in $items) {
        $box  = if ($i.status -eq 'done') { '[x]' } else { '[ ]' }
        $kind = if ($i.auto) { (T-D9 'авто') } else { (T-D9 'вручну') }
        $c    = if ($i.status -eq 'done') { 'DarkGray' } elseif ($i.auto) { 'White' } else { 'Yellow' }
        Write-Host (" {0} {1,2}. {2}  ({3})" -f $box, $i.number, $i.title, $kind) -ForegroundColor $c
        if ($i.status -eq 'done') { continue }
        if ($i.why) { Write-Host "        $($i.why)" -ForegroundColor DarkGray }
        foreach ($l in @($i.links)) { Write-Host "        -> $($l.label): $($l.url)" -ForegroundColor DarkCyan }
        $deps = @($i.dependsOn | ForEach-Object { $id = $_; ($items | Where-Object id -eq $id).number } | Where-Object { $_ } | Sort-Object)
        if ($deps) { Write-Host (T-D9 '        після кроку {0}' ($deps -join ', ')) -ForegroundColor DarkGray }
    }
    $autoLeft = @($items | Where-Object { $_.auto -and $_.status -ne 'done' }).Count
    Write-Host ""
    if ($autoLeft) { Write-Host (T-D9 'Автоматичних кроків: {0}. Виконати: -Checklist -Run All   (ручний крок позначити: -Checklist -Done <номер>)' "$autoLeft") }
}

function Save-D9HtmlReport {
    param($ScanResult, $List, $Categories, [string]$Path)
    $html = ConvertTo-D9ScanHtml -Scan $ScanResult -Checklist $List -Categories $Categories
    [IO.File]::WriteAllText($Path, $html, (New-Object Text.UTF8Encoding $false))
    Write-D9Log (T-D9 'Звіт збережено: {0}' $Path) Ok
}

# ---------------------------------------------------------------------
$catalog = Import-D9Catalog
Add-D9BootMark 'catalog'
# Зібраний файл уже перевірено під час збірки (Compile.ps1, крок 1) — повторна перевірка лише сповільнює запуск
$catalogErrors = if ($script:D9Embedded) { @() } else { Test-D9Catalog $catalog }
if ($catalogErrors.Count) {
    Write-D9Log (T-D9 'Помилки в каталозі твіків:') Error
    $catalogErrors | ForEach-Object { Write-D9Log "  $_" Error }
    exit $ExitCodes.BadArgs
}

$sys = Get-D9SystemInfo -UseCache
Add-D9BootMark 'sysinfo'
$recommendation = Get-D9RecommendedPreset $sys
Add-D9BootMark 'preset'

switch ($PSCmdlet.ParameterSetName) {

    'Gui' {
        $base = Split-Path $PSCommandPath
        $script:D9Theme = Resolve-D9Theme $Theme
        if ($SelfTest) {
            try {
                $r = Show-D9Gui -Catalog $catalog -SystemInfo $sys -Recommendation $recommendation -ReportDir (Join-Path $base 'Звіти') -DriverDir (Join-Path $base 'Драйвери') -TestAction { T-D9 'вікно побудовано: вкладок {0}' "$($ui.Tabs.Items.Count)" }
                Write-D9Log (T-D9 'Самоперевірка інтерфейсу: {0}' "$r") Ok
                Write-Host (Get-D9BootReport)
                exit $ExitCodes.Ok
            } catch { Write-D9Log (T-D9 'Самоперевірка інтерфейсу не пройшла: {0}' $_.Exception.Message) Error; exit $ExitCodes.Partial }
        }
        try {
            Show-D9Gui -Catalog $catalog -SystemInfo $sys -Recommendation $recommendation -ReportDir (Join-Path $base 'Звіти') -DriverDir (Join-Path $base 'Драйвери')
        } catch {
            # Якщо вікно не відкрилось (немає WPF, пошкоджені шрифти тощо) — показуємо текстове меню
            # run.bat запускає вікно з прихованою консоллю — меню відкриваємо в новому видимому вікні
            $err = $_.Exception.Message
            try { Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show(((T-D9 'Не вдалося відкрити вікно програми:') + "`n$err`n`n" + (T-D9 'Зараз відкриється текстове меню.')), 'Debora', 'OK', 'Warning') } catch { }
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
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Увага: запущено без прав адміністратора — частина перевірок і всі зміни недоступні. Запускайте через run.bat.') Warn }
        while ($true) {
            Write-Host ""
            Write-Host "Debora $script:D9Version — $($sys.Manufacturer) $($sys.Model), $($sys.OsName) $($sys.DisplayVersion)" -ForegroundColor Cyan
            Write-Host (T-D9 'Рекомендований профіль: {0} ({1})' $recommendation.Preset ($recommendation.Reasons -join '; ')) -ForegroundColor DarkGray
            Write-Host ""
            Write-Host (T-D9 '  1. Перевірити комп''ютер (сканування й звіт)')
            Write-Host (T-D9 '  2. Показати чекліст «що робити»')
            Write-Host (T-D9 '  3. Виконати автоматичні кроки чекліста')
            Write-Host (T-D9 '  4. Застосувати рекомендований профіль налаштувань ({0})' $recommendation.Preset)
            Write-Host (T-D9 '  5. Відкотити останні зміни')
            Write-Host (T-D9 '  6. Відкрити останній звіт')
            Write-Host (T-D9 '  7. Драйвери: що потрібно і де взяти')
            Write-Host (T-D9 '  8. Встановити драйвери з папки «Драйвери»')
            Write-Host (T-D9 ' 11. Знайти й встановити нові драйвери з інтернету (автоматично)')
            Write-Host (T-D9 '  9. Зібрати діагностику (zip для розбору проблеми)')
            Write-Host (T-D9 ' 10. Оновити всі програми (winget)')
            Write-Host (T-D9 ' 12. Стан дисків (температура, знос, помилки)')
            if ($sys.HasBattery) { Write-Host (T-D9 ' 13. Стан батареї (знос, прогноз, поради)') }
            Write-Host (T-D9 ' 14. Деблоат Windows (нав''язані застосунки, реклама, Copilot)')
            Write-Host (T-D9 ' 15. Налаштування з нуля (після чистої Windows: драйвери, деблоат, програми, оновлення)')
            Write-Host (T-D9 '  0. Вихід')
            $choice = Read-Host (T-D9 'Ваш вибір')
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
                    $answer = Read-Host (T-D9 'Перезавантажити комп''ютер зараз, щоб зміни запрацювали? [y/N]')
                    if ($answer -match '^(y|yes|т|так)$') { Restart-Computer -Force }
                }
                '4' {
                    & $runSelf @('-Preset', 'Recommended', '-WhatIf')
                    & $runSelf @('-Preset', 'Recommended')
                }
                '5' {
                    $last = Get-D9SessionList | Where-Object { -not $_.Undone -and $_.Changed -gt 0 } | Select-Object -First 1
                    if (-not $last) { Write-D9Log (T-D9 'Немає змін, які можна відкотити.') Ok }
                    else {
                        Write-Host (T-D9 'Остання сесія: {0}, {1}, змін: {2}' $last.Started $last.Selection $last.Changed)
                        & $runSelf @('-Undo', $last.Id)
                    }
                }
                '6' {
                    $r = & $lastReport
                    if ($r) { Start-Process $r.FullName } else { Write-D9Log (T-D9 'Звітів ще немає — спочатку пункт 1.') Warn }
                }
                '7' { & $runSelf @('-Drivers') }
                '8' {
                    $folder = Join-Path (Split-Path $self) 'Драйвери'
                    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
                    if (-not (Get-ChildItem $folder -Recurse -File -ErrorAction SilentlyContinue)) {
                        Write-Host ""
                        Write-Host (T-D9 'Папка «Драйвери» порожня: {0}' $folder) -ForegroundColor Yellow
                        Write-Host (T-D9 'Завантажте драйвери з сайту виробника (пункт 7 покаже посилання) і покладіть сюди файли як є — .zip теж можна.')
                        Start-Process explorer.exe $folder
                    } else {
                        & $runSelf @('-DriverInstall', $folder)
                    }
                }
                '9' {
                    & $runSelf @('-Diagnostics')
                    $zip = Get-ChildItem $reports -Filter '*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($zip) { Start-Process explorer.exe "/select,`"$($zip.FullName)`"" }
                }
                '10' { & $runSelf @('-UpgradeApps') }
                '11' { & $runSelf @('-DriverUpdate') }
                '12' { & $runSelf @('-Disks') }
                '13' { & $runSelf @('-Battery') }
                '14' { & $runSelf @('-Debloat') }
                '15' { & $runSelf @('-Setup') }
                '0' { exit $ExitCodes.Ok }
                default { Write-Host (T-D9 'Введіть номер пункту.') -ForegroundColor Yellow }
            }
        }
    }

    'DriverUpdate' {
        $folder = Join-Path (Split-Path $PSCommandPath) 'Драйвери\Завантажені'
        Write-Host ""
        Write-Host (T-D9 'Онлайн-пошук драйверів: {0} {1}, {2} {3}' $sys.Manufacturer $sys.Model $sys.OsName $sys.DisplayVersion) -ForegroundColor Cyan
        $all = @(Find-D9DriverUpdates -SystemInfo $sys -IncludeWindowsUpdate)
        $cands = @($all | Where-Object { $IncludeOptional -or -not $_.Optional })
        if (-not $all) { Write-D9Log (T-D9 'Новіших драйверів не знайдено — встановлені актуальні.') Ok; exit $ExitCodes.Ok }
        Write-Host ""
        foreach ($c in $all) {
            $mark = if ($c.Status -eq 'missing') { (T-D9 'немає драйвера') } elseif ($c.Optional) { (T-D9 'необов''язково') } else { (T-D9 'новіший') }
            $color = if ($c.Status -eq 'missing') { 'Yellow' } elseif ($c.Optional) { 'DarkGray' } else { 'White' }
            Write-Host ("  [{0}] {1}{2}" -f $mark, $c.Device.Name, $(if ($c.Recommended) { (T-D9 ' (рекомендує Windows Update)') })) -ForegroundColor $color
            Write-Host (T-D9 '      {0} → {1} від {2:dd.MM.yyyy}, {3}' $(if ($c.Device.Version) { $c.Device.Version } else { (T-D9 'немає') }) $c.Row.Version $c.Row.Date (Format-D9Size $c.Row.Size)) -ForegroundColor DarkGray
        }
        if ($all.Count -gt $cands.Count) { Write-Host ("`n" + (T-D9 'Необов''язкові пропускаються; додайте -IncludeOptional, щоб встановити й їх.')) -ForegroundColor DarkGray }
        if ($WhatIf -or -not $cands) { exit $ExitCodes.Ok }
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Для встановлення потрібні права адміністратора (запускайте через run.bat).') Error; exit $ExitCodes.NotAdmin }
        if (-not (Confirm-D9 (T-D9 'Завантажити й встановити {0} драйвер(ів)? Попередні буде збережено для відкату' "$($cands.Count)"))) { exit $ExitCodes.Cancelled }
        $oemTool = Get-D9OemTool $sys
        if ($oemTool -and (Confirm-D9 (T-D9 'Також запустити {0} — утиліту {1} для драйверів і BIOS вашої моделі (встановиться автоматично)?' $oemTool.Name $oemTool.Vendor))) { [void](Invoke-D9OemDriverTool -SystemInfo $sys) }
        $found = Save-D9DriverUpdates -Candidates $cands -Folder $folder
        $todo = @($found.Packages | Where-Object Status -ne 'current')
        if (-not $todo) { Write-D9Log (T-D9 'Після перевірки пакетів встановлювати нічого.') Ok; exit $ExitCodes.Ok }
        $drvCatalog = New-D9DriverCatalog -Packages $todo
        $plan = New-D9Plan -Catalog $drvCatalog -TweakIds @($drvCatalog.Tweaks.id) -SystemInfo $sys
        $session = Invoke-D9Plan -Plan $plan -SystemInfo $sys -Selection (T-D9 'драйвери з Microsoft Update Catalog') -NoRestorePoint:$NoRestorePoint
        $errors = @($session.entries | Where-Object result -eq 'error')
        Write-D9Log (T-D9 'Встановлено: {0}, помилок: {1}. Пакети збережено в {2} — їх можна взяти на інший такий самий ПК.' @($session.entries | Where-Object result -eq 'ok').Count $errors.Count $folder) $(if ($errors) { 'Warn' } else { 'Ok' })
        Write-D9Log (T-D9 'Перезавантажте комп''ютер, щоб драйвери запрацювали. Відкат: меню → 5.') Warn
        exit $(if ($errors) { $ExitCodes.Partial } else { $ExitCodes.Reboot })
    }

    'Maintain' {
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Потрібні права адміністратора.') Error; exit $ExitCodes.NotAdmin }
        $summary = Invoke-D9Maintenance -Catalog $catalog -SystemInfo $sys
        Show-D9Toast (T-D9 'Debora: обслуговування завершено') (Format-D9MaintenanceSummary $summary)
        exit $(if (@($summary.results | Where-Object { -not $_.ok })) { $ExitCodes.Partial } elseif ($summary.reboot) { $ExitCodes.Reboot } else { $ExitCodes.Ok })
    }

    'Schedule' {
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Потрібні права адміністратора (запускайте через run.bat).') Error; exit $ExitCodes.NotAdmin }
        if ($Schedule -eq 'Off') { Unregister-D9MaintenanceTask; exit $ExitCodes.Ok }
        if (-not $script:D9Embedded) { Write-D9Log (T-D9 'Розклад працює лише зі зібраним Debora.ps1 (build\Compile.ps1).') Error; exit $ExitCodes.BadArgs }
        $cfg = Get-D9MaintenanceConfig
        $cfg.Day = $Schedule; $cfg.Time = $At
        try { Register-D9MaintenanceTask -SourceScript $PSCommandPath -Config $cfg; exit $ExitCodes.Ok }
        catch { Write-D9Log (T-D9 'Не вдалося створити розклад: {0}' $_.Exception.Message) Error; exit $ExitCodes.Partial }
    }

    'Uninstall' {
        $all = @(Get-D9UninstallList)
        $progs = @($all | Where-Object { $n = $_.Name; @($Uninstall | Where-Object { $n -like $_ }).Count })
        if (-not $progs) { Write-D9Log (T-D9 'Не знайдено встановлених програм за назвою: {0}' ($Uninstall -join ', ')) Warn; exit $ExitCodes.BadArgs }
        foreach ($pr in $progs) { $c = Get-D9UninstallCommand $pr; Write-Host ("  {0} {1}{2}" -f $pr.Name, $pr.Version, $(if ($c -and -not $c.Silent) { (T-D9 '  (з вікном деінсталятора)') })) }
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Потрібні права адміністратора (запускайте через run.bat).') Error; exit $ExitCodes.NotAdmin }
        if (-not (Confirm-D9 (T-D9 'Видалити {0} програм(и)?' "$($progs.Count)"))) { exit $ExitCodes.Cancelled }
        [void](New-D9RestorePoint)
        $res = @(Uninstall-D9Programs -Programs $progs)
        $left = @($res | ForEach-Object { $_.leftovers } | Where-Object { $_ })
        if ($left) {
            Write-Host (T-D9 'Залишки після видалення:') -ForegroundColor Cyan
            foreach ($l in $left) { Write-Host "  $(if ($l.Type -eq 'folder') { T-D9 'Папка ' } else { T-D9 'Реєстр' }) $($l.Path)" }
            if (Confirm-D9 (T-D9 'Прибрати {0} залишків? Папки — у Кошик, реєстр — з резервною копією .reg' "$($left.Count)")) { [void](Remove-D9UninstallLeftovers -Items $left) }
        }
        exit $(if (@($res | Where-Object { $_.result -notin 'removed', 'reboot' })) { $ExitCodes.Partial } else { $ExitCodes.Ok })
    }

    'ExportDrivers' {
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Потрібні права адміністратора (запускайте через run.bat).') Error; exit $ExitCodes.NotAdmin }
        try { $r = Export-D9Drivers -Folder $ExportDrivers; Write-D9Log (T-D9 'Щоб поставити їх на іншу (таку саму) систему: -DriverInstall "{0}"' $ExportDrivers) Detail; exit $ExitCodes.Ok }
        catch { Write-D9Log $_.Exception.Message Error; exit $ExitCodes.Partial }
    }

    'PrepareUsb' {
        if (-not $NoDrivers -and -not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Для збереження драйверів потрібні права адміністратора (або додайте -NoDrivers).') Error; exit $ExitCodes.NotAdmin }
        $opts = @{ UserName = $UserName; Password = $AccountPassword; Edition = $Edition; BypassRequirements = -not $KeepRequirements
                   PostInstall = $(if ($Preset) { $Preset } else { 'Recommended' }); DriverUpdate = $true
                   SetupProfile = $(if ($ProfilePath) { $ProfilePath } elseif (-not $Preset -and (Test-Path -LiteralPath (Get-D9SetupProfilePath))) { Get-D9SetupProfilePath } else { '' }) }
        Write-Host ""
        Write-Host (T-D9 'Флешка {0} буде доповнена: autounattend.xml{1}, Debora.' $PrepareUsb $(if (-not $NoDrivers) { T-D9 ', драйвери цього ПК' } else { '' })) -ForegroundColor Cyan
        Write-Host (T-D9 'Під час встановлення вручну лишиться тільки вибір диска. Усе на флешці, крім autounattend.xml, не змінюється.') -ForegroundColor DarkGray
        try {
            $r = Initialize-D9InstallUsb -Drive $PrepareUsb -Options $opts -ProgramFolder (Split-Path $PSCommandPath) -IncludeDrivers:(-not $NoDrivers)
            Write-D9Log (T-D9 'Готово ({0}): {1}.' $r.Language ($r.Done -join '; ')) Ok
            Write-D9Log (T-D9 'Завантажтеся з флешки й виберіть диск — решта автоматично. Після першого входу Debora застосує налаштування й доставить драйвери (потрібен інтернет).') Detail
            exit $ExitCodes.Ok
        } catch { Write-D9Log $_.Exception.Message Error; exit $ExitCodes.Partial }
    }

    'Apps' {
        if (-not (Get-D9WingetPath)) { Write-D9Log (T-D9 'winget не знайдено. Встановіть «Інсталятор застосунків» з Microsoft Store: {0}' 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1') Error; exit $ExitCodes.Partial }
        Write-D9Log (T-D9 'Перевіряю встановлені програми (winget export)...')
        $installed = Get-D9InstalledAppIds
        $appCatalog = Import-D9AppCatalog
        foreach ($c in $appCatalog.categories) {
            $items = @($appCatalog.apps | Where-Object category -eq $c.id)
            if (-not $items) { continue }
            Write-Host ""
            Write-Host (Get-D9Text $c.name) -ForegroundColor Cyan
            foreach ($a in $items) {
                $has = $installed.Contains($a.id)
                Write-Host ("  {0} {1,-34} {2}" -f $(if ($has) { '[v]' } else { '[ ]' }), $a.name, $a.id) -ForegroundColor $(if ($has) { 'DarkGray' } else { 'Gray' })
            }
        }
        Write-Host ""
        Write-Host (T-D9 'Встановити: -InstallApp <ID>[,<ID>...]   Оновити всі: -UpgradeApps') -ForegroundColor DarkGray
        exit $ExitCodes.Ok
    }

    'InstallApp' {
        if (-not (Get-D9WingetPath)) { Write-D9Log (T-D9 'winget не знайдено. Встановіть «Інсталятор застосунків» з Microsoft Store.') Error; exit $ExitCodes.Partial }
        $appCatalog = Import-D9AppCatalog
        $list = foreach ($want in $InstallApp) {
            $hit = @($appCatalog.apps | Where-Object { $_.id -eq $want -or $_.name -eq $want }) | Select-Object -First 1
            if ($hit) { $hit } else { [pscustomobject]@{ id = $want; name = $want; source = 'winget' } }   # будь-який пакет winget за точним ID
        }
        Write-Host (T-D9 'Буде встановлено: {0}' (($list | ForEach-Object name) -join ', '))
        if (-not (Confirm-D9 (T-D9 'Встановити?'))) { exit $ExitCodes.Cancelled }
        $res = @(Install-D9Apps -Apps @($list))
        $bad = @($res | Where-Object { $_.result -in 'failed', 'notFound' })
        if (@($res | Where-Object result -eq 'reboot')) { Write-D9Log (T-D9 'Деякі програми запрацюють після перезавантаження.') Warn }
        exit $(if ($bad) { $ExitCodes.Partial } else { $ExitCodes.Ok })
    }

    'UpgradeApps' {
        if (-not (Get-D9WingetPath)) { Write-D9Log (T-D9 'winget не знайдено.') Error; exit $ExitCodes.Partial }
        $up = @(Get-D9AppUpgrades)
        if (-not $up) { Write-D9Log (T-D9 'Усі програми актуальні.') Ok; exit $ExitCodes.Ok }
        Write-Host (T-D9 'Оновлення є для {0} програм:' "$($up.Count)")
        foreach ($u in $up) { Write-Host ("  {0,-40} {1} → {2}" -f $u.Name, $u.Version, $u.Available) }
        if (-not (Confirm-D9 (T-D9 'Оновити всі? Відкриті програми краще закрити.'))) { exit $ExitCodes.Cancelled }
        $r = Invoke-D9AppUpgradeAll
        exit $(if ($r.Result -in 'installed', 'upToDate') { $ExitCodes.Ok } else { $ExitCodes.Partial })
    }

    'Disks' {
        Write-Host ""
        Write-Host (T-D9 'Стан дисків: {0} {1}' $sys.Manufacturer $sys.Model) -ForegroundColor Cyan
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Без прав адміністратора Windows не віддає температуру, знос і лічильники помилок.') Warn }
        $all = @(Get-D9DiskHealth)
        foreach ($d in $all) {
            $v = Get-D9DiskVerdict $d
            $color = @{ ok = 'Green'; warn = 'Yellow'; bad = 'Red'; unknown = 'DarkGray' }[$v.Level]
            Write-Host ("  [{0}] {1}" -f (Get-D9DiskLevelText $v.Level), (Format-D9DiskTitle $d)) -ForegroundColor $color
            if ($v.Problems) { Write-Host (T-D9 '      Проблеми: {0}' ($v.Problems -join '; ')) -ForegroundColor $color }
            Write-Host "      $(Format-D9DiskDetails $d)" -ForegroundColor DarkGray
        }
        $worst = @($all | Where-Object { -not $_.Removable } | ForEach-Object { (Get-D9DiskVerdict $_).Level })
        if ($worst -contains 'bad') { Write-D9Log (T-D9 'Є несправний диск: негайно скопіюйте важливі файли й замініть диск.') Error; exit $ExitCodes.Partial }
        exit $ExitCodes.Ok
    }

    'Debloat' {
        Write-Host ""
        Write-Host (T-D9 'Деблоат Windows: {0} {1}' $sys.OsName $sys.DisplayVersion) -ForegroundColor Cyan
        $dbApps = @(Get-D9DebloatApps)
        $dbFeatures = @(Get-D9DebloatFeatures $catalog $sys)
        $rec = Get-D9DebloatRecommended $catalog $sys $dbApps $dbFeatures
        foreach ($a in ($dbApps | Sort-Object GroupOrder, Name)) {
            $mark = if ($rec.Packages -contains $a.Package) { '[x]' } else { '[ ]' }
            Write-Host ("  {0} {1}  ({2})" -f $mark, $a.Name, $a.GroupName) -ForegroundColor $(if ($mark -eq '[x]') { 'White' } else { 'DarkGray' })
        }
        foreach ($f in $dbFeatures) {
            $mark = if ($rec.TweakIds -contains $f.Id) { '[x]' } elseif ($f.State -eq 'applied') { '[=]' } else { '[ ]' }
            Write-Host ("  {0} {1}" -f $mark, $f.Name) -ForegroundColor $(if ($mark -eq '[x]') { 'White' } else { 'DarkGray' })
        }
        Write-Host (T-D9 '  [x] — буде зроблено, [=] — уже зроблено, [ ] — за бажанням (у вікні на вкладці «Деблоат»).') -ForegroundColor DarkGray
        if (-not $rec.Packages -and -not $rec.TweakIds) { Write-D9Log (T-D9 'Рекомендований деблоат уже виконано — робити нічого.') Ok; exit $ExitCodes.Ok }
        if ($WhatIf) { exit $ExitCodes.Ok }
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Потрібні права адміністратора (запускайте через run.bat).') Error; exit $ExitCodes.NotAdmin }
        if (-not (Confirm-D9 (T-D9 'Виконати деблоат ({0} застосунків, {1} налаштувань)?' $rec.Packages.Count $rec.TweakIds.Count))) { exit $ExitCodes.Cancelled }
        $session = Invoke-D9Debloat -Catalog $catalog -SystemInfo $sys -Packages $rec.Packages -TweakIds $rec.TweakIds
        $errors = @($session.entries | Where-Object result -eq 'error')
        Write-D9Log (T-D9 'Деблоат виконано. Змін: {0}, помилок: {1}. Відкат: -Undo {2}' @($session.entries | Where-Object result -eq 'ok').Count $errors.Count $session.id) $(if ($errors) { 'Warn' } else { 'Ok' })
        exit $(if ($errors) { $ExitCodes.Partial } else { $ExitCodes.Ok })
    }

    'Setup' {
        $setupProfile = if ($ProfilePath) { Import-D9SetupProfile $ProfilePath } else { Get-D9SetupProfile }
        Write-Host ""
        Write-Host (T-D9 'Налаштування з нуля — профіль «{0}»' $setupProfile.name) -ForegroundColor Cyan
        foreach ($row in @(Get-D9SetupPlan -Profile $setupProfile -Catalog $catalog -SystemInfo $sys -Quick)) {
            Write-Host "  [x] $($row.title)"
            Write-Host "      $($row.detail)" -ForegroundColor DarkGray
        }
        if (-not @($setupProfile.steps).Count) { Write-D9Log (T-D9 'У профілі не вибрано жодного кроку.') Error; exit $ExitCodes.BadArgs }
        if ($WhatIf) { exit $ExitCodes.Ok }
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Потрібні права адміністратора (запускайте через run.bat).') Error; exit $ExitCodes.NotAdmin }
        if (-not (Confirm-D9 (T-D9 'Виконати {0} кроків? Спершу — точка відновлення; усе відкочується через -Undo.' @($setupProfile.steps).Count))) { exit $ExitCodes.Cancelled }
        $summary = Invoke-D9Setup -Profile $setupProfile -Catalog $catalog -SystemInfo $sys -NoRestorePoint:$NoRestorePoint
        $bad = @($summary.results | Where-Object { -not $_.ok })
        Write-D9Log (T-D9 'Підсумок: {0}' (Format-D9SetupSummary $summary)) $(if ($bad) { 'Warn' } else { 'Ok' })
        if ($summary.reboot -and $setupProfile.reboot -and $Yes) { Write-D9Log (T-D9 'Перезавантаження через 60 секунд (shutdown /a — скасувати).') Warn; & shutdown.exe /r /t 60 }
        exit $(if ($bad) { $ExitCodes.Partial } elseif ($summary.reboot) { $ExitCodes.Reboot } else { $ExitCodes.Ok })
    }

    'ExportProfile' {
        $path = Export-D9SetupProfile -Profile (Get-D9SetupProfile) -Path $ExportProfile
        Write-D9Log (T-D9 'Профіль майстра збережено: {0}' $path) Ok
        exit $ExitCodes.Ok
    }

    'Battery' {
        Write-Host ""
        Write-Host (T-D9 'Стан батареї: {0} {1}' $sys.Manufacturer $sys.Model) -ForegroundColor Cyan
        $b = Get-D9BatteryHealth
        if (-not $b) { Write-D9Log (T-D9 'Батареї немає або Windows не віддає її даних.') Warn; exit $ExitCodes.Ok }
        $level = Get-D9BatteryLevel $b
        $color = @{ ok = 'Green'; fair = 'Yellow'; warn = 'Yellow'; bad = 'Red' }[$level]
        $lines = @(Format-D9BatteryReport $b $sys.Manufacturer)
        Write-Host "  $($lines[0])" -ForegroundColor $color
        foreach ($l in ($lines | Select-Object -Skip 1)) { Write-Host "  $l" -ForegroundColor Gray }
        exit $(if ($level -eq 'bad') { $ExitCodes.Partial } else { $ExitCodes.Ok })
    }

    'Diagnostics' {
        $target = if ($OutDir) { $OutDir } else { Join-Path (Split-Path $PSCommandPath) 'Звіти' }
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Без прав адміністратора частина журналів і відомостей про драйвери буде неповною.') Warn }
        try {
            [void](New-D9DiagnosticsBundle -SystemInfo $sys -OutDir $target -ReportDir (Join-Path (Split-Path $PSCommandPath) 'Звіти'))
            exit $ExitCodes.Ok
        } catch { Write-D9Log (T-D9 'Не вдалося зібрати діагностику: {0}' $_.Exception.Message) Error; exit $ExitCodes.Partial }
    }

    'Drivers' {
        Write-Host ""
        Write-Host (T-D9 'Драйвери: {0} {1}, {2} {3}' $sys.Manufacturer $sys.Model $sys.OsName $sys.DisplayVersion) -ForegroundColor Cyan
        $rep = Get-D9DriverReport $sys
        if ($rep.Oem) {
            Write-Host ""
            Write-Host (T-D9 'Сторінка драйверів {0} для цієї моделі (найкраще джерело):' "$($rep.Oem.Name)") -ForegroundColor Green
            Write-Host "  $($rep.Oem.Url)"
            if ($rep.Oem.Note) { Write-Host "  $($rep.Oem.Note)" -ForegroundColor DarkGray }
            if ($rep.Oem.Serial) { Write-Host (T-D9 '  Серійний номер: {0}' "$($rep.Oem.Serial)") -ForegroundColor DarkGray }
        }
        Write-Host ""
        if ($rep.Problems) {
            Write-Host (T-D9 'Без драйвера або з помилкою ({0}):' "$($rep.Problems.Count)") -ForegroundColor Yellow
            foreach ($p in ($rep.Problems | Sort-Object { if ($_.Class -eq 'Net') { 0 } else { 1 } })) {
                Write-Host "  [!] $($p.Name) — $($p.Reason)" -ForegroundColor Yellow
                if ($p.Windows -and $p.Windows -ne $p.Name) { Write-Host (T-D9 '      Windows називає: {0}' "$($p.Windows)") -ForegroundColor DarkGray }
                Write-Host "      ID: $($p.Info.HardwareId)" -ForegroundColor DarkGray
                foreach ($l in $p.Links) { Write-Host "      -> $($l.label): $($l.url)" -ForegroundColor DarkCyan }
            }
        } else {
            Write-Host (T-D9 'Усі пристрої мають драйвери.') -ForegroundColor Green
        }
        Write-Host ""
        Write-Host (T-D9 'Важливі драйвери (версія, дата):') -ForegroundColor Cyan
        $rep.Important | Format-Table Group, Name, Version, Date, Provider -AutoSize | Out-String -Width 200 | Write-Host
        Write-Host (Get-D9DeviceInventorySummary $rep.Devices) -ForegroundColor Cyan
        if ($DeviceView) {
            Write-Host ""
            $list = @(Group-D9DeviceInventory (Select-D9DeviceInventory $rep.Devices $DeviceView))
            $list | Format-Table @{ n = (T-D9 'Тип'); e = { $_.ClassName } }, @{ n = (T-D9 'Пристрій'); e = { if ($_.Count -gt 1) { "$($_.Name) ×$($_.Count)" } else { $_.Name } } },
                @{ n = (T-D9 'Версія'); e = { $_.Version } }, @{ n = (T-D9 'Дата'); e = { $_.DateText } }, @{ n = (T-D9 'Постачальник'); e = { $_.Provider } }, @{ n = (T-D9 'Стан'); e = { $_.StatusText } } -AutoSize |
                Out-String -Width 240 | Write-Host
        } else {
            Write-Host (T-D9 'Повний перелік пристроїв: -Drivers -DeviceView hardware (або all, thirdparty, old, problems); у файл: -Drivers -Csv <шлях>.csv') -ForegroundColor DarkGray
        }
        if ($Csv) { Export-D9DeviceInventoryCsv $rep.Devices $Csv; Write-D9Log (T-D9 'Перелік пристроїв збережено: {0}' $Csv) Ok }
        Write-Host (T-D9 'Як оновити: завантажте драйвери з сайту виробника в папку «Драйвери» поруч із програмою й виберіть у меню пункт 8.') -ForegroundColor DarkGray
        Write-Host (T-D9 'Програма сама підбере, що підходить до цього ПК, і поставить у правильному порядку (з можливістю відкату).') -ForegroundColor DarkGray
        exit $ExitCodes.Ok
    }

    'DriverInstall' {
        if (-not (Test-Path -LiteralPath $DriverInstall)) { Write-D9Log (T-D9 'Папку не знайдено: {0}' $DriverInstall) Error; exit $ExitCodes.BadArgs }
        Write-D9Log (T-D9 'Аналіз драйверів у {0} ...' $DriverInstall)
        $found = Find-D9DriverPackages -Folder $DriverInstall
        Write-Host ""
        Write-Host (T-D9 'INF-файлів знайдено: {0}. Підходять до цього ПК: {1}.' $found.Infs $found.Packages.Count) -ForegroundColor Cyan
        $statusText = @{ missing = (T-D9 'немає драйвера — встановити'); newer = (T-D9 'новіший — оновити'); current = (T-D9 'вже актуальний') }
        $n = 0
        foreach ($p in $found.Packages) {
            $n++
            $cur = @($p.Current | ForEach-Object { $_.version } | Where-Object { $_ } | Sort-Object -Unique) -join ', '
            $color = @{ missing = 'Yellow'; newer = 'White'; current = 'DarkGray' }[$p.Status]
            Write-Host ("  {0,2}. {1} [{2}]" -f $n, $p.Name, $statusText[$p.Status]) -ForegroundColor $color
            $date = if ($p.Package.Inf.Date) { $p.Package.Inf.Date.ToString('dd.MM.yyyy') } else { '?' }
            Write-Host (T-D9 '      зараз: {0}; у папці: {1} ({2}) — {3}' $(if ($cur) { $cur } else { (T-D9 'немає') }) $p.Package.Inf.Version $date (Split-Path $p.Package.Inf.Path -Leaf)) -ForegroundColor DarkGray
        }
        if ($found.Installers) {
            Write-Host ""
            Write-Host (T-D9 'Пакети лише з інсталятором — запустіть вручну, якщо цей пристрій є в ПК ({0}):' "$(@($found.Installers).Count)") -ForegroundColor Yellow
            foreach ($i in $found.Installers) { Write-Host "  - $($i.Package): $($i.Path)" -ForegroundColor DarkGray }
        }
        $todo = @($found.Packages | Where-Object Status -ne 'current')
        if (-not $todo) {
            Write-Host ""
            Write-D9Log (T-D9 'Нічого встановлювати: усе з папки вже стоїть або новіше.') Ok
            exit $ExitCodes.Ok
        }
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Для встановлення потрібні права адміністратора (запускайте через run.bat).') Error; exit $ExitCodes.NotAdmin }
        Write-Host ""
        if (-not (Confirm-D9 (T-D9 'Встановити {0} драйвер(ів) у показаному порядку? Попередні буде збережено для відкату' "$($todo.Count)"))) { exit $ExitCodes.Cancelled }
        $drvCatalog = New-D9DriverCatalog -Packages $todo
        $plan = New-D9Plan -Catalog $drvCatalog -TweakIds @($drvCatalog.Tweaks.id) -SystemInfo $sys
        $session = Invoke-D9Plan -Plan $plan -SystemInfo $sys -Selection (T-D9 'драйвери з {0}' $DriverInstall) -NoRestorePoint:$NoRestorePoint
        $ok = @($session.entries | Where-Object result -eq 'ok').Count
        $errors = @($session.entries | Where-Object result -eq 'error')
        Write-Host ""
        Write-D9Log (T-D9 'Встановлено: {0}, помилок: {1}. Сесія: {2}' $ok $errors.Count $session.id) $(if ($errors) { 'Warn' } else { 'Ok' })
        Write-D9Log (T-D9 'Перезавантажте комп''ютер, щоб драйвери запрацювали. Відкат: меню → 5.') Warn
        $left = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -notin 22, 45 })
        if ($left) { Write-Host (T-D9 'Ще без драйвера: {0}' (($left | ForEach-Object { Get-D9DeviceDisplayName (Resolve-D9Device @($_.HardwareID)) $_.Name }) -join ', ')) -ForegroundColor Yellow }
        exit $(if ($errors) { $ExitCodes.Partial } else { $ExitCodes.Reboot })
    }

    'Scan' {
        $scanConfig = Import-D9ScanConfig
        $ctx = New-D9ScanContext -Catalog $catalog -SystemInfo $sys -ScanConfig $scanConfig -Deep:$Deep
        Write-Host ""
        Write-Host (T-D9 'Debora {0} — сканування{1}: {2} {3}' $script:D9Version $(if ($Deep) { T-D9 ' (глибоке)' } else { '' }) $sys.Manufacturer $sys.Model) -ForegroundColor Cyan
        if (-not $ctx.IsAdmin) { Write-D9Log (T-D9 'Без прав адміністратора частину перевірок пропущено. Для повного сканування запустіть від адміністратора.') Warn }
        $result = Invoke-D9Scan -Context $ctx
        $path = Save-D9Scan $result
        Write-D9ScanResult $result $scanConfig.Checks.categories

        $list = New-D9Checklist -Scan $result -Catalog $catalog
        $list = Merge-D9ChecklistState -New $list -Old (Get-D9Checklist)
        Save-D9Checklist $list
        Write-D9Checklist $list
        if ($Report) { Save-D9HtmlReport $result $list $scanConfig.Checks.categories $Report }
        Write-Host ""
        Write-Host (T-D9 'Сканування: {0} с. Результат: {1}' $result.durationSec $path) -ForegroundColor DarkGray
        exit $(switch ($result.score.verdict) { 'good' { 0 } 'attention' { 1 } default { 2 } })
    }

    'Checklist' {
        $list = Get-D9Checklist
        if (-not $list) { Write-D9Log (T-D9 'Чекліста ще немає. Спочатку запустіть: -Scan') Warn; exit $ExitCodes.BadArgs }
        $scanConfig = Import-D9ScanConfig
        $ctx = New-D9ScanContext -Catalog $catalog -SystemInfo $sys -ScanConfig $scanConfig

        foreach ($n in @($Done | Where-Object { $_ })) {
            $item = $list.items | Where-Object number -eq $n
            if (-not $item) { Write-D9Log (T-D9 'Кроку {0} немає' "$n") Error; exit $ExitCodes.BadArgs }
            $item.status = 'done'; $item.doneAt = (Get-Date).ToString('s'); $item.note = (T-D9 'позначено вручну')
        }

        if ($Run) {
            $targets = if ($Run -eq 'All') { @($list.items | Where-Object { $_.auto -and $_.status -ne 'done' }) }
                       else { @($list.items | Where-Object { $_.number -in @($Run -split ',' | ForEach-Object { [int]$_ }) }) }
            $targets = @($targets | Sort-Object number)
            if (-not $targets) { Write-D9Log (T-D9 'Немає кроків для виконання.') Ok }
            else {
                if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Потрібні права адміністратора.') Error; exit $ExitCodes.NotAdmin }
                Write-Host (T-D9 'Буде виконано кроки: {0}' (($targets | ForEach-Object { "$($_.number). $($_.title)" }) -join '; '))
                if (-not (Confirm-D9 (T-D9 'Продовжити?'))) { exit $ExitCodes.Cancelled }
                foreach ($item in $targets) {
                    if ($item.action.type -eq 'maintenance' -and $item.action.action -eq 'reboot' -and $Run -eq 'All' -and -not $AllowReboot) { continue }
                    if (-not (Test-D9ChecklistReady $list $item)) { Write-D9Log (T-D9 'Крок {0} пропущено: спершу виконайте попередні кроки' "$($item.number)") Warn; continue }
                    try { [void](Invoke-D9ChecklistStep -Checklist $list -Item $item -Context $ctx -AllowReboot:$AllowReboot) }
                    catch { Write-D9Log (T-D9 '  Помилка: {0}' $_.Exception.Message) Error }
                }
            }
        }

        Write-D9Log (T-D9 'Перевірка виконаних кроків...') Detail
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
        Write-Host (T-D9 'Що далі:')
        Write-Host (T-D9 '  -Scan                           перевірити стан Windows і отримати чекліст')
        Write-Host (T-D9 '  -Diagnostics                    зібрати zip для розбору проблеми')
        Write-Host (T-D9 '  -Disks                          стан дисків: температура, знос, помилки (SMART)')
        if ($sys.HasBattery) { Write-Host (T-D9 '  -Battery                        стан батареї: знос, прогноз, поради') }
        Write-Host (T-D9 '  -Debloat [-WhatIf]              деблоат: нав''язані застосунки, реклама, Copilot, телеметрія')
        Write-Host (T-D9 '  -Setup [-ProfilePath f] [-WhatIf] налаштування з нуля: драйвери, деблоат, профіль, програми, оновлення, перевірка')
        Write-Host (T-D9 '  -Apps / -InstallApp / -UpgradeApps   програми через winget')
        Write-Host (T-D9 '  -DriverUpdate [-WhatIf]         нові драйвери з інтернету: знайти, завантажити, встановити')
        Write-Host (T-D9 '  -PrepareUsb E: -UserName Ім''я   флешка для перевстановлення Windows без запитань і з драйверами')
        Write-Host (T-D9 '  -Schedule Sunday -At 12:00      щотижневе автоматичне обслуговування (-Schedule Off — вимкнути)')
        Write-Host (T-D9 '  -ListTweaks                     каталог твіків і їхній стан')
        Write-Host (T-D9 '  -Preset Recommended -WhatIf     що зміниться за рекомендованим профілем')
        Write-Host (T-D9 '  -Preset Recommended -Yes        застосувати')
        Write-Host "  Get-Help .\Debora.ps1 -Examples"
        exit $ExitCodes.Ok
    }

    'List' {
        $stateNames = @{ applied = (T-D9 'застосовано'); partial = (T-D9 'частково'); notApplied = '-'; notApplicable = (T-D9 'н/д'); unknown = '?' }
        $riskNames  = @{ safe = (T-D9 'безпечно'); moderate = (T-D9 'помірно'); expert = (T-D9 'експертний') }
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
        if (-not $list) { Write-Host (T-D9 'Сесій ще немає.'); exit $ExitCodes.Ok }
        $list | Format-Table -AutoSize
        exit $ExitCodes.Ok
    }

    'Undo' {
        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Потрібні права адміністратора.') Error; exit $ExitCodes.NotAdmin }
        $session = Get-D9Session $Undo
        $count = @($session.entries | Where-Object { $_.result -eq 'ok' -and (-not $UndoTweak -or $UndoTweak -contains $_.tweak) }).Count
        Write-Host (T-D9 'Сесія {0} ({1}): змін для відкату — {2}' $session.id $session.selection $count)
        if (-not (Confirm-D9 (T-D9 'Відкотити?'))) { exit $ExitCodes.Cancelled }
        $report = Undo-D9Session -Id $Undo -TweakIds $UndoTweak
        $bad = @($report | Where-Object { $_.result -in 'error', 'conflict', 'manual' }).Count
        Write-D9Log (T-D9 'Відкочено: {0}, потребує уваги: {1}' @($report | Where-Object result -eq 'restored').Count $bad) $(if ($bad) { 'Warn' } else { 'Ok' })
        exit $(if ($bad) { $ExitCodes.Partial } else { $ExitCodes.Ok })
    }

    'Apply' {
        if (-not $Preset -and -not $Tweak) { Write-D9Log (T-D9 'Вкажіть -Preset або -Tweak.') Error; exit $ExitCodes.BadArgs }
        $presetId = if ($Preset -eq 'Recommended') { $recommendation.Preset } else { $Preset }
        $ids = @()
        if ($presetId) { $ids += @((Get-D9Preset $catalog $presetId).tweaks) }
        if ($Tweak)    { $ids += $Tweak }
        $selection = (@($presetId) + @($Tweak) | Where-Object { $_ }) -join ', '

        $plan = New-D9Plan -Catalog $catalog -TweakIds $ids -SystemInfo $sys
        $unknown = @($plan | Where-Object { -not $_.Tweak })
        if ($unknown) { Write-D9Log (T-D9 'Невідомі твіки: {0}' ($unknown.Id -join ', ')) Error; exit $ExitCodes.BadArgs }

        Write-D9SystemSummary $sys $recommendation
        Write-Host (T-D9 'План ({0}):' $selection) -ForegroundColor Cyan
        $preview = @(Get-D9Preview -Plan $plan -SystemInfo $sys)
        foreach ($group in ($preview | Group-Object Tweak)) {
            $pending = @($group.Group | Where-Object Pending)
            $mark = if ($pending) { '*' } else { ' ' }
            Write-Host " $mark $($group.Name)"
            foreach ($p in $group.Group) {
                if ($p.Pending -or $p.Skipped) { Write-Host "      $($p.Change)" -ForegroundColor $(if ($p.Pending) { 'Gray' } else { 'DarkYellow' }) }
            }
        }
        $pendingCount = @($preview | Where-Object Pending).Count
        Write-Host ""
        Write-Host (T-D9 'Змін до застосування: {0} (* — твік має незастосовані зміни)' "$pendingCount")
        if ($WhatIf) { exit $ExitCodes.Ok }
        if ($pendingCount -eq 0) { Write-D9Log (T-D9 'Усе вже застосовано.') Ok; exit $ExitCodes.Ok }

        if (-not (Test-D9IsAdmin)) { Write-D9Log (T-D9 'Потрібні права адміністратора.') Error; exit $ExitCodes.NotAdmin }
        if (-not (Confirm-D9 (T-D9 'Застосувати {0} змін?' "$pendingCount"))) { exit $ExitCodes.Cancelled }

        $session = Invoke-D9Plan -Plan $plan -SystemInfo $sys -Selection $selection -NoRestorePoint:$NoRestorePoint
        $entries = @($session.entries)
        $ok      = @($entries | Where-Object result -eq 'ok').Count
        $errors  = @($entries | Where-Object result -eq 'error').Count
        Write-Host ""
        Write-D9Log (T-D9 'Готово. Змінено: {0}, помилок: {1}. Сесія: {2}' $ok $errors $session.id) $(if ($errors) { 'Warn' } else { 'Ok' })
        Write-D9Log (T-D9 'Відкат: {0}' ".\Debora.ps1 -Undo $($session.id)")
        $reboot = @($plan | Where-Object { $_.Run -and $_.Tweak.rebootRequired }).Count -gt 0
        if ($reboot) { Write-D9Log (T-D9 'Деякі зміни запрацюють після перезавантаження.') Warn }
        if ($errors) { exit $ExitCodes.Partial }
        if ($reboot) { exit $ExitCodes.Reboot }
        exit $ExitCodes.Ok
    }
}
