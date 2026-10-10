# Встановлення й оновлення програм через winget (каталог config/apps.json).
# Програми не є твіками: відкату немає (видалити можна звичайним способом), тому лише журнал виконання.

function Import-D9AppCatalog { ConvertFrom-Json (Get-D9ConfigText 'apps.json') }

function Get-D9WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    # Від адміністратора WindowsApps текущого користувача часто не в PATH — шукаємо сам пакет
    $pkg = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    return $null
}

# Єдина точка виклику winget (у тестах підміняється через Mock)
function Invoke-D9Winget {
    param([string[]]$Arguments)
    $exe = Get-D9WingetPath
    if (-not $exe) { throw 'winget не знайдено. Встановіть «Інсталятор застосунків» (App Installer) з Microsoft Store.' }
    $prev = [Console]::OutputEncoding
    try {
        try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
        $out = & $exe @Arguments 2>&1 | ForEach-Object { [string]$_ }
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = @($out) }
    } finally { try { [Console]::OutputEncoding = $prev } catch { } }
}

# Рядки виводу без індикаторів прогресу (█▒, спінер) — для журналу
function Select-D9WingetLines {
    param([string[]]$Lines, [int]$Last = 4)
    @($Lines | ForEach-Object { ($_ -split "`r")[-1].Trim() } |
        Where-Object { $_ -and $_ -notmatch '[█▒]' -and $_ -notmatch '^[-\\|/]$' -and $_ -notmatch '^\d+(\.\d+)? ?[KMG]?B / ' } |
        Select-Object -Last $Last)
}

# Коди завершення winget, які варто розпізнавати (APPINSTALLER_CLI_ERROR_*)
$script:D9WingetCodes = @{
    0           = 'installed'
    -1978335189 = 'upToDate'        # 0x8A15002B UPDATE_NOT_APPLICABLE
    -1978335135 = 'already'         # 0x8A150061 PACKAGE_ALREADY_INSTALLED
    -1978335212 = 'notFound'        # 0x8A150014 NO_APPLICATIONS_FOUND
    -1978334967 = 'reboot'          # 0x8A150109 INSTALL_REBOOT_REQUIRED_TO_FINISH
    -1978334966 = 'reboot'          # 0x8A15010A INSTALL_REBOOT_REQUIRED_FOR_INSTALL
}

function ConvertFrom-D9WingetCode {
    param([int]$Code)
    if ($script:D9WingetCodes.ContainsKey($Code)) { return $script:D9WingetCodes[$Code] }
    return 'failed'
}

# Встановлені пакети: winget export віддає точні ID (і winget, і msstore). Повертає HashSet ідентифікаторів.
function Get-D9InstalledAppIds {
    $file = Join-Path ([IO.Path]::GetTempPath()) ("d9apps-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        [void](Invoke-D9Winget @('export', '-o', $file, '--accept-source-agreements', '--disable-interactivity'))
        if (Test-Path -LiteralPath $file) {
            $json = ConvertFrom-Json ([IO.File]::ReadAllText($file))
            foreach ($s in @($json.Sources)) { foreach ($p in @($s.Packages)) { if ($p.PackageIdentifier) { [void]$set.Add($p.PackageIdentifier) } } }
        }
    } finally { if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) } }
    return , $set
}

function Get-D9AppArguments {
    param([Parameter(Mandatory)]$App)
    $source = if ($App.source) { $App.source } else { 'winget' }
    @('install', '--id', $App.id, '--exact', '--source', $source, '--silent',
      '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
}

# Встановлює програми по черзі. Повертає по рядку на програму: id, name, result (installed|already|reboot|notFound|failed), code.
function Install-D9Apps {
    param([Parameter(Mandatory)][object[]]$Apps)
    $n = 0
    foreach ($app in $Apps) {
        $n++
        if ($script:D9OnProgress) { & $script:D9OnProgress $n $Apps.Count $app.name }
        Write-D9Log "[$n/$($Apps.Count)] $($app.name) ($($app.id))..."
        $r = try { Invoke-D9Winget (Get-D9AppArguments $app) } catch { [pscustomobject]@{ Code = -1; Output = @($_.Exception.Message) } }
        $result = ConvertFrom-D9WingetCode $r.Code
        $level = switch ($result) { 'installed' { 'Ok' } 'already' { 'Ok' } 'upToDate' { 'Ok' } 'reboot' { 'Warn' } default { 'Error' } }
        $text = @{ installed = 'встановлено'; already = 'уже встановлено'; upToDate = 'уже встановлено'; reboot = 'встановлено, потрібне перезавантаження'; notFound = 'пакет не знайдено'; failed = "помилка (код $($r.Code))" }[$result]
        Write-D9Log "  $($app.name): $text" $level
        if ($level -eq 'Error') { foreach ($l in Select-D9WingetLines $r.Output) { Write-D9Log "    $l" Detail } }
        [pscustomobject]@{ id = $app.id; name = $app.name; result = $result; code = $r.Code }
    }
}

# Програми, для яких є оновлення (winget upgrade). Повертає @{ Name; Id; Version; Available }.
function Get-D9AppUpgrades {
    $r = Invoke-D9Winget @('upgrade', '--accept-source-agreements', '--disable-interactivity')
    ConvertFrom-D9WingetTable $r.Output
}

# Розбір таблиці winget: колонки за позиціями заголовка (назви колонок локалізовані, тому — за порядком)
function ConvertFrom-D9WingetTable {
    param([string[]]$Lines)
    $lines = @($Lines | ForEach-Object { ($_ -split "`r")[-1] })
    $sep = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match '^-{10,}' })
    if ($sep -lt 1) { return @() }
    $header = $lines[$sep - 1]
    $starts = @([regex]::Matches($header, '(?<=^|\s)\S') | ForEach-Object Index)
    if ($starts.Count -lt 4) { return @() }
    foreach ($line in $lines[($sep + 1)..($lines.Count - 1)]) {
        if ($line.Length -lt $starts[3] -or $line -match '^\d+ ') { continue }   # підсумковий рядок «N upgrades available»
        $cell = { param($i) $from = $starts[$i]; $to = if ($i + 1 -lt $starts.Count) { $starts[$i + 1] } else { $line.Length }
                  if ($from -ge $line.Length) { '' } else { $line.Substring($from, [math]::Min($to, $line.Length) - $from).Trim() } }
        $id = & $cell 1
        if (-not $id -or $id -match '\s') { continue }
        [pscustomobject]@{ Name = (& $cell 0); Id = $id; Version = (& $cell 2); Available = (& $cell 3) }
    }
}

# Оновлює конкретні програми (наприклад, вразливі версії зі сканування). Якщо winget не пов'язав
# встановлену програму з пакетом (ставили не через winget), встановлює пакет поверх — це і є оновлення.
function Update-D9Apps {
    param([Parameter(Mandatory)][string[]]$Ids)
    foreach ($id in $Ids) {
        Write-D9Log "Оновлення $id..."
        $common = @('--id', $id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        $r = try { Invoke-D9Winget (@('upgrade') + $common) } catch { [pscustomobject]@{ Code = -1; Output = @($_.Exception.Message) } }
        $result = ConvertFrom-D9WingetCode $r.Code
        if ($result -in 'notFound', 'failed') {
            Write-D9Log '  winget не знайшов її серед своїх пакетів — встановлюю актуальну версію поверх.' Detail
            $r = try { Invoke-D9Winget (@('install') + $common) } catch { [pscustomobject]@{ Code = -1; Output = @($_.Exception.Message) } }
            $result = ConvertFrom-D9WingetCode $r.Code
        }
        $ok = $result -in 'installed', 'upToDate', 'already', 'reboot'
        Write-D9Log "  ${id}: $(if ($ok) { 'оновлено' } else { "не вдалося (код $($r.Code))" })" $(if ($ok) { 'Ok' } else { 'Error' })
        if (-not $ok) { foreach ($l in Select-D9WingetLines $r.Output) { Write-D9Log "    $l" Detail } }
        [pscustomobject]@{ id = $id; result = $result; code = $r.Code }
    }
}

function Invoke-D9AppUpgradeAll {
    Write-D9Log 'Оновлення всіх програм через winget (може тривати довго)...'
    $r = Invoke-D9Winget @('upgrade', '--all', '--silent', '--include-unknown', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    foreach ($l in Select-D9WingetLines $r.Output 12) { Write-D9Log "  $l" Detail }
    $result = ConvertFrom-D9WingetCode $r.Code
    if ($result -in 'installed', 'upToDate') { Write-D9Log 'Оновлення програм завершено.' Ok }
    else { Write-D9Log "winget завершився з кодом $($r.Code): частина програм могла не оновитися (наприклад, відкриті зараз)." Warn }
    [pscustomobject]@{ Code = $r.Code; Result = $result }
}
