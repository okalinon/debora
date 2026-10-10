# Видалення встановлених програм (класичних, з розділу Uninstall реєстру).
# Спосіб — від найтихішого: QuietUninstallString → MSI (msiexec /x /qn) → Inno Setup (/VERYSILENT) →
# NSIS (/S) → звичайний деінсталятор з вікном. Після запуску перевіряємо, що запис справді зник.
# Відкату немає (повернути — встановити знову, наприклад з вкладки «Програми»), тому перед видаленням — точка відновлення.

$script:D9UninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
# Компоненти, від яких залежать інші програми — видаляти не радимо
$script:D9KeepPatterns = @('Microsoft Visual C++*', 'Microsoft .NET*', 'Microsoft Windows Desktop Runtime*', 'Microsoft ASP.NET*', 'Microsoft Edge WebView2*',
    'Microsoft Edge', 'Microsoft Update Health Tools', 'Windows SDK*', 'Windows Software Development Kit*', '*Driver*', '*Chipset*', 'Intel(R) Management Engine*',
    'Realtek*Audio*', 'NVIDIA Graphics Driver*', 'AMD Software*', 'Microsoft GameInput', 'DirectX*')

# Розбір командного рядка деінсталятора: шлях до exe (у лапках або з пробілами до «.exe») і аргументи
function Split-D9CommandLine {
    param([string]$CommandLine)
    $c = ([string]$CommandLine).Trim()
    if (-not $c) { return $null }
    if ($c -match '^"([^"]+)"\s*(.*)$') { return [pscustomobject]@{ File = $Matches[1]; Args = $Matches[2].Trim() } }
    if ($c -match '^(.+?\.exe)(\s+.*)?$') { return [pscustomobject]@{ File = $Matches[1]; Args = ([string]$Matches[2]).Trim() } }
    $parts = $c -split '\s+', 2
    [pscustomobject]@{ File = $parts[0]; Args = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
}

function Get-D9UninstallList {
    param($KnownBloat)
    if (-not $KnownBloat) { $KnownBloat = ConvertFrom-Json (Get-D9ConfigText 'known-bloat.json') }
    $seen = @{}
    foreach ($root in $script:D9UninstallRoots) {
        foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DisplayName -or $p.SystemComponent -eq 1 -or $p.ParentKeyName -or $p.ReleaseType -in 'Update', 'Hotfix', 'Security Update') { continue }
            if (-not $p.UninstallString -and -not $p.QuietUninstallString) { continue }
            $id = "$($p.DisplayName)|$($p.DisplayVersion)"
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $bloat = $KnownBloat.programs | Where-Object { $p.DisplayName -like $_.pattern } | Select-Object -First 1
            $keep = [bool]($script:D9KeepPatterns | Where-Object { $p.DisplayName -like $_ })
            $date = $null
            if ($p.InstallDate -match '^\d{8}$') { $date = try { [datetime]::ParseExact($p.InstallDate, 'yyyyMMdd', $null) } catch { $null } }
            [pscustomobject]@{
                Name = [string]$p.DisplayName; Version = [string]$p.DisplayVersion; Publisher = [string]$p.Publisher
                Size = $(if ($p.EstimatedSize) { [long]$p.EstimatedSize * 1KB } else { 0 }); InstallDate = $date
                Key = $k.PSPath; KeyName = $k.PSChildName
                UninstallString = [string]$p.UninstallString; QuietUninstallString = [string]$p.QuietUninstallString
                IsMsi = ($p.WindowsInstaller -eq 1 -and $k.PSChildName -match '^\{[0-9A-F-]{36}\}$')
                Bloat = $(if ($bloat) { Get-D9Text $bloat.reason } else { $null }); Keep = $keep
            }
        }
    }
}

# Як видалити: File, Args, Silent (чи без вікон)
function Get-D9UninstallCommand {
    param([Parameter(Mandatory)]$Program)
    if ($Program.QuietUninstallString) {
        $c = Split-D9CommandLine $Program.QuietUninstallString
        return [pscustomobject]@{ File = $c.File; Args = $c.Args; Silent = $true; Method = 'quiet' }
    }
    $guid = if ($Program.IsMsi) { $Program.KeyName } elseif ($Program.UninstallString -match '(?i)msiexec(\.exe)?\s+/[IX]\s*(\{[0-9A-F-]{36}\})') { $Matches[2] } else { $null }
    if ($guid) { return [pscustomobject]@{ File = 'msiexec.exe'; Args = "/x $guid /qn /norestart"; Silent = $true; Method = 'msi' } }
    $c = Split-D9CommandLine $Program.UninstallString
    if (-not $c) { return $null }
    $leaf = Split-Path $c.File -Leaf
    if ($leaf -match '(?i)^unins\d{3}\.exe$') { return [pscustomobject]@{ File = $c.File; Args = "$($c.Args) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART".Trim(); Silent = $true; Method = 'inno' } }
    if ($leaf -match '(?i)^(uninst|uninstall)[^\\]*\.exe$' -and $c.Args -notmatch '(?i)(^|\s)/S(\s|$)') { return [pscustomobject]@{ File = $c.File; Args = "$($c.Args) /S".Trim(); Silent = $true; Method = 'nsis' } }
    [pscustomobject]@{ File = $c.File; Args = $c.Args; Silent = $false; Method = 'interactive' }
}

# Видаляє по черзі. Результат: name, result (removed|reboot|stillPresent|failed), message
function Uninstall-D9Programs {
    param([Parameter(Mandatory)][object[]]$Programs, [int]$TimeoutMinutes = 15)
    $n = 0
    foreach ($prog in $Programs) {
        $n++
        if ($script:D9OnProgress) { & $script:D9OnProgress $n $Programs.Count $prog.Name }
        $cmd = Get-D9UninstallCommand $prog
        if (-not $cmd) { [pscustomobject]@{ name = $prog.Name; result = 'failed'; message = 'немає команди видалення' }; continue }
        Write-D9Log "[$n/$($Programs.Count)] Видалення $($prog.Name)$(if (-not $cmd.Silent) { ' — відкриється вікно деінсталятора, пройдіть його' })..."
        $code = $null; $msg = $null
        try {
            $p = Start-Process -FilePath $cmd.File -ArgumentList $cmd.Args -PassThru -ErrorAction Stop -WindowStyle $(if ($cmd.Silent) { 'Hidden' } else { 'Normal' })
            if (-not $p.WaitForExit($TimeoutMinutes * 60000)) { $msg = "не завершилось за $TimeoutMinutes хв" }
            else { $code = $p.ExitCode }
        } catch { $msg = $_.Exception.Message }
        Start-Sleep -Milliseconds 800   # деякі деінсталятори дочищають реєстр уже після виходу
        $gone = -not (Test-Path -LiteralPath $prog.Key)
        $result = if ($gone -and $code -eq 3010) { 'reboot' } elseif ($gone) { 'removed' } elseif ($msg) { 'failed' } else { 'stillPresent' }
        $text = @{ removed = 'видалено'; reboot = 'видалено, потрібне перезавантаження'; stillPresent = "не видалено (код $code; можливо, скасовано у вікні деінсталятора)"; failed = "помилка: $msg" }[$result]
        Write-D9Log "  $($prog.Name): $text" $(if ($result -in 'removed', 'reboot') { 'Ok' } else { 'Warn' })
        [pscustomobject]@{ name = $prog.Name; result = $result; message = $text }
    }
}
