# Підготовка до перевстановлення Windows: збереження драйверів і «розумна» інсталяційна флешка.
# До звичайної флешки з Windows (Media Creation Tool / Rufus) додаємо:
#   autounattend.xml — без запитань (мова, EULA, акаунт Microsoft, мережа, приватність), локальний обліковий запис,
#                      за бажанням — обхід вимог Windows 11 (TPM, Secure Boot, пам'ять, процесор);
#   $WinpeDriver$\   — драйвери цього ПК: Windows Setup ставить їх сам під час встановлення;
#   Debloater9\      — після першого входу застосовує профіль налаштувань і доставляє драйвери з інтернету.
# Розбиття диска лишається ручним (вибір розділу) — автоматичне стирання диска надто небезпечне.

# Експорт усіх сторонніх драйверів (oemNN.inf) у папку. Потрібні права адміністратора.
function Export-D9Drivers {
    param([Parameter(Mandatory)][string]$Folder)
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    Write-D9Log "Збереження драйверів цього ПК у $Folder ..."
    $out = & pnputil.exe /export-driver * $Folder 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "pnputil /export-driver завершився з кодом ${LASTEXITCODE}: $($out.Trim() -split "`n" | Select-Object -Last 2)" }
    $count = @(Get-ChildItem $Folder -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue).Count
    $size = [long]((Get-ChildItem $Folder -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
    Write-D9Log "Збережено драйверів: $count ($(Format-D9Size $size))." Ok
    [pscustomobject]@{ Folder = $Folder; Count = $count; Bytes = $size }
}

# Флешки з файлами встановлення Windows (setup.exe + sources\install.wim/esd/swm)
function Get-D9InstallMedia {
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -in 2, 3 -and $_.DeviceID -ne $env:SystemDrive })) {
        $root = "$($d.DeviceID)\"
        $image = Get-ChildItem (Join-Path $root 'sources') -File -ErrorAction SilentlyContinue | Where-Object Name -match '^install\.(wim|esd|swm)$' | Select-Object -First 1
        if (-not (Test-Path (Join-Path $root 'setup.exe')) -or -not $image) { continue }
        $lang = $null
        $ini = Join-Path $root 'sources\lang.ini'
        if (Test-Path $ini) { $lang = ((Get-Content $ini -ErrorAction SilentlyContinue) -match '^\s*[a-z]{2}-[A-Z]{2}\s*=' | Select-Object -First 1) -replace '\s*=.*$', '' }
        [pscustomobject]@{ Drive = $d.DeviceID; Label = $d.VolumeName; Removable = ($d.DriveType -eq 2); FreeBytes = [long]$d.FreeSpace; Image = $image.Name; Language = $(if (([string]$lang).Trim() -match '^([a-z]{2})-([a-z]{2})$') { "$($Matches[1].ToLower())-$($Matches[2].ToUpper())" } else { ([string]$lang).Trim() }) }
    }
}

# Загальні (публічні) ключі встановлення Microsoft: лише вибирають редакцію, не активують.
# Windows з цифровою ліцензією активується сама після встановлення.
$script:D9EditionKeys = @{
    Home = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
    Pro  = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
}

function ConvertTo-D9XmlText { param([string]$Text) [Security.SecurityElement]::Escape([string]$Text) }

# Генерує autounattend.xml. Options: Language, Keyboard (uk-UA;en-US), TimeZone, UserName, Password, ComputerName,
# Edition (''|Home|Pro), BypassRequirements, BypassNetwork, PostInstall ('' або назва профілю), DriverUpdate
function New-D9AutounattendXml {
    param([Parameter(Mandatory)][hashtable]$Options)
    $o = @{ Language = 'uk-UA'; Keyboard = 'uk-UA;en-US'; TimeZone = 'FLE Standard Time'; UserName = 'User'; Password = ''
            ComputerName = '*'; Edition = ''; BypassRequirements = $true; BypassNetwork = $true; PostInstall = 'Recommended'; DriverUpdate = $true }
    foreach ($k in $Options.Keys) { $o[$k] = $Options[$k] }
    if ($o.UserName -notmatch '^[^\\/\[\]:;|=,+*?<>"@]{1,20}$') { throw "Недопустиме ім'я облікового запису: $($o.UserName)" }
    if ($o.ComputerName -ne '*' -and $o.ComputerName -notmatch '^[A-Za-z0-9-]{1,15}$') { throw "Ім'я комп'ютера: латиниця, цифри й дефіс, до 15 символів" }
    $c = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"'
    $lang = ConvertTo-D9XmlText $o.Language; $kbd = ConvertTo-D9XmlText $o.Keyboard
    $user = ConvertTo-D9XmlText $o.UserName; $pass = ConvertTo-D9XmlText $o.Password

    $pe = New-Object Collections.Generic.List[string]
    if ($o.BypassRequirements) {
        $i = 0
        foreach ($v in 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassCPUCheck', 'BypassStorageCheck') {
            $i++
            $pe.Add("<RunSynchronousCommand wcm:action=`"add`"><Order>$i</Order><Path>reg.exe add HKLM\SYSTEM\Setup\LabConfig /v $v /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>")
        }
    }
    $peRun = if ($pe.Count) { "<RunSynchronous>$($pe -join '')</RunSynchronous>" } else { '' }
    $key = if ($o.Edition -and $script:D9EditionKeys.ContainsKey($o.Edition)) { "<ProductKey><Key>$($script:D9EditionKeys[$o.Edition])</Key><WillShowUI>OnError</WillShowUI></ProductKey>" } else { '' }

    $spec = New-Object Collections.Generic.List[string]
    if ($o.BypassNetwork) { $spec.Add('<RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg.exe add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>') }
    $specRun = if ($spec.Count) { "<component name=`"Microsoft-Windows-Deployment`" $c><RunSynchronous>$($spec -join '')</RunSynchronous></component>" } else { '' }

    # Після першого входу: знайти Debloater9 на будь-якому диску й запустити профіль та онлайн-драйвери
    $first = New-Object Collections.Generic.List[string]
    $find = '$f = Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root ''Debloater9\Debloater9.ps1'' } | Where-Object { Test-Path $_ } | Select-Object -First 1'
    $n = 0
    if ($o.PostInstall) {
        $n++
        $cmd = "$find; if (`$f) { & `$f -Preset $($o.PostInstall) -Yes -NoRestorePoint -LogPath `$env:PUBLIC\Debloater9-firstlogon.log }"
        $first.Add("<SynchronousCommand wcm:action=`"add`"><Order>$n</Order><Description>Debloater9: профіль налаштувань</Description><CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command &quot;$(ConvertTo-D9XmlText $cmd)&quot;</CommandLine></SynchronousCommand>")
    }
    if ($o.DriverUpdate) {
        $n++
        $cmd = "$find; if (`$f) { & `$f -DriverUpdate -Yes -NoRestorePoint -LogPath `$env:PUBLIC\Debloater9-firstlogon.log }"
        $first.Add("<SynchronousCommand wcm:action=`"add`"><Order>$n</Order><Description>Debloater9: драйвери з інтернету</Description><CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command &quot;$(ConvertTo-D9XmlText $cmd)&quot;</CommandLine></SynchronousCommand>")
    }
    $firstXml = if ($first.Count) { "<FirstLogonCommands>$($first -join '')</FirstLogonCommands>" } else { '' }

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Створено Debloater9. Пароль облікового запису (якщо задано) зберігається тут відкритим текстом — не залишайте флешку без нагляду. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" $c>
      <SetupUILanguage><UILanguage>$lang</UILanguage></SetupUILanguage>
      <InputLocale>$kbd</InputLocale><SystemLocale>$lang</SystemLocale><UILanguage>$lang</UILanguage><UserLocale>$lang</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" $c>
      $peRun
      <UserData><AcceptEula>true</AcceptEula>$key</UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <ComputerName>$(ConvertTo-D9XmlText $o.ComputerName)</ComputerName>
      <TimeZone>$(ConvertTo-D9XmlText $o.TimeZone)</TimeZone>
    </component>
    $specRun
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $c>
      <InputLocale>$kbd</InputLocale><SystemLocale>$lang</SystemLocale><UILanguage>$lang</UILanguage><UserLocale>$lang</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <OOBE>
        <HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>false</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen><ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add">
        <Name>$user</Name><DisplayName>$user</DisplayName><Group>Administrators</Group>
        <Password><Value>$pass</Value><PlainText>true</PlainText></Password>
      </LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>$user</Username><Password><Value>$pass</Value><PlainText>true</PlainText></Password></AutoLogon>
      $firstXml
    </component>
  </settings>
</unattend>
"@
    [void]([xml]$xml)   # перевірка, що XML правильний
    return $xml
}

# Готує флешку: autounattend.xml, драйвери в $WinpeDriver$, копія Debloater9. Повертає опис зробленого.
function Initialize-D9InstallUsb {
    param([Parameter(Mandatory)][string]$Drive, [Parameter(Mandatory)][hashtable]$Options, [string]$ProgramFolder, [switch]$IncludeDrivers)
    $root = "$($Drive.TrimEnd('\', ':')):\"
    if (-not [IO.File]::Exists("${root}setup.exe")) { throw "На $root немає файлів встановлення Windows. Спершу створіть флешку через Media Creation Tool або Rufus." }
    $media = Get-D9InstallMedia | Where-Object { $_.Drive -eq $root.TrimEnd('\') } | Select-Object -First 1
    if ($media.Language -and -not $Options.ContainsKey('Language')) { $Options.Language = $media.Language }
    $done = @()
    $xmlPath = "${root}autounattend.xml"
    if (Test-Path $xmlPath) { Copy-Item $xmlPath "$xmlPath.d9-old" -Force; $done += 'попередній autounattend.xml збережено як autounattend.xml.d9-old' }
    [IO.File]::WriteAllText($xmlPath, (New-D9AutounattendXml -Options $Options), (New-Object Text.UTF8Encoding $false))
    Write-D9Log "autounattend.xml записано на $root" Ok
    $done += 'autounattend.xml'
    if ($IncludeDrivers) {
        $model = ("$((Get-CimInstance Win32_ComputerSystem).Model)" -replace '[\\/:*?"<>|]', '_').Trim()
        $r = Export-D9Drivers -Folder "${root}`$WinpeDriver`$\$model"
        $done += "драйвери цього ПК: $($r.Count) ($(Format-D9Size $r.Bytes))"
    }
    if ($ProgramFolder -and (Test-Path (Join-Path $ProgramFolder 'Debloater9.ps1'))) {
        $dst = "${root}Debloater9"
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Get-ChildItem $ProgramFolder -File | Where-Object Extension -in '.ps1', '.bat', '.txt', '' | Copy-Item -Destination $dst -Force
        Write-D9Log "Debloater9 скопійовано на флешку ($dst)" Ok
        $done += 'Debloater9 (запуститься після першого входу)'
    }
    [pscustomobject]@{ Drive = $root; Done = $done; Language = $Options.Language }
}
