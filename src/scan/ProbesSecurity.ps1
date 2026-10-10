# Проби безпеки й резервних копій, яким потрібен код (не лише одне значення реєстру).

function Test-D9GuestAccount {
    param($Check, $Ctx)
    $guest = Get-CimInstance Win32_UserAccount -Filter "LocalAccount = True" -ErrorAction SilentlyContinue | Where-Object { $_.SID -like '*-501' }
    if ($guest -and -not $guest.Disabled) {
        New-D9Finding $Check warning "Обліковий запис «Гість» ($($guest.Name)) увімкнено" 'Будь-хто може увійти без пароля й отримати доступ до мережі та частини файлів.' @{ type = 'tweaks'; ids = @('safety.disable-guest') }
    }
}

function Test-D9ProxyHosts {
    param($Check, $Ctx)
    $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
        New-D9Finding $Check warning "Увімкнено проксі-сервер: $($inet.ProxyServer)" 'Весь трафік браузерів іде через цей сервер. Якщо ви (або робота) його не налаштовували — це ознака шкідливої програми. Debloater9 вимкне проксі (відкочується в «Журналі змін»).' (New-D9ActionsFix @(@{ type = 'registry'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; name = 'ProxyEnable'; value = 0; kind = 'DWord' })) @((New-D9Link 'Параметри проксі' 'ms-settings:network-proxy')) -Key "$($Check.id):proxy"
    }
    if ($inet.AutoConfigURL) {
        New-D9Finding $Check warning "Задано сценарій автоналаштування проксі: $($inet.AutoConfigURL)" 'Якщо ви його не налаштовували — це може перенаправляти трафік. Debloater9 прибере сценарій (відкочується в «Журналі змін»).' (New-D9ActionsFix @(@{ type = 'registry'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; name = 'AutoConfigURL'; delete = $true })) @((New-D9Link 'Параметри проксі' 'ms-settings:network-proxy')) -Key "$($Check.id):pac"
    }
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    $lines = @(Get-Content $hosts -ErrorAction SilentlyContinue | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
    $entries = @($lines | ForEach-Object { $parts = $_ -split '\s+'; if ($parts.Count -ge 2) { [pscustomobject]@{ Ip = $parts[0]; Host = $parts[1] } } })
    $sensitive = 'google|microsoft|windowsupdate|apple|facebook|bank|paypal|privat24|monobank|binance|steam'
    $redirects = @($entries | Where-Object { $_.Ip -notin '0.0.0.0', '127.0.0.1', '::1', '::' -and $_.Host -match $sensitive })
    if ($redirects) {
        # Копія hosts поруч — з неї відкат; прибираємо лише рядки з підозрілими перенаправленнями
        $backup = "$hosts.d9-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
        $names = ($redirects.Host | Sort-Object -Unique | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ','
        $run = "Copy-Item -LiteralPath '$hosts' -Destination '$backup' -Force; `$bad = @($names); " +
               "`$keep = Get-Content -LiteralPath '$hosts' | Where-Object { `$p = ((`$_ -replace '#.*$', '').Trim() -split '\s+'); -not (`$p.Count -ge 2 -and `$bad -contains `$p[1]) }; " +
               "Set-Content -LiteralPath '$hosts' -Value `$keep -Encoding Default; & ipconfig.exe /flushdns | Out-Null"
        $hostsFix = New-D9ActionsFix @(@{ type = 'command'; run = $run; undoRun = "Copy-Item -LiteralPath '$backup' -Destination '$hosts' -Force"; label = @{ uk = 'Прибрати підозрілі перенаправлення з hosts (копія поруч)'; en = 'Remove suspicious hosts redirects' } })
        New-D9Finding $Check critical "Файл hosts перенаправляє важливі сайти: $(($redirects | Select-Object -First 3 | ForEach-Object { "$($_.Host) → $($_.Ip)" }) -join ', ')" 'Типовий прийом шкідливих програм для крадіжки паролів. Debloater9 прибере ці рядки (копія файлу зберігається поруч); після цього перевірте ПК антивірусом.' $hostsFix -Key "$($Check.id):hosts"
    } elseif ($entries.Count -gt 50) {
        New-D9Finding $Check info "У файлі hosts $($entries.Count) записів" 'Зазвичай це блокувальник реклами чи телеметрії. Якщо ви нічого такого не встановлювали — перевірте файл.' -Key "$($Check.id):hosts-many"
    }
}

# Автозапуск із тимчасових папок або через закодовані команди — типові сліди шкідливих програм
function Test-D9SuspiciousAutostart {
    param($Check, $Ctx)
    $badPath = '\\(Temp|Downloads)\\|\\AppData\\Local\\Temp\\|^%temp%'
    $badCmd  = '-enc(odedcommand)?\s|FromBase64String|mshta(\.exe)?\s+(http|javascript|vbscript)|regsvr32.+/i:http|rundll32.+javascript:|powershell.+(iwr|irm|Invoke-WebRequest|DownloadString).+(iex|Invoke-Expression)'
    $found = @()
    foreach ($key in 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce') {
        $values = Get-ItemProperty $key -ErrorAction SilentlyContinue
        foreach ($p in @($values.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
            if ("$($p.Value)" -match $badPath -or "$($p.Value)" -match $badCmd) { $found += "Автозапуск «$($p.Name)»: $($p.Value)" }
        }
    }
    try {
        $svc = Get-D9TaskService
        $stack = New-Object System.Collections.Stack; $stack.Push($svc.GetFolder('\'))
        while ($stack.Count) {
            $folder = $stack.Pop()
            if ($folder.Path -like '\Microsoft*') { continue }
            foreach ($sub in $folder.GetFolders(0)) { $stack.Push($sub) }
            foreach ($t in $folder.GetTasks(1)) {
                try { $xml = [xml]$t.Xml } catch { continue }
                foreach ($exec in @($xml.Task.Actions.Exec)) {
                    $cmd = "$($exec.Command) $($exec.Arguments)"
                    if ($cmd -match $badPath -or $cmd -match $badCmd) { $found += "Завдання «$($t.Path)»: $cmd" }
                }
            }
        }
    } catch { }
    if ($found) {
        New-D9Finding $Check warning "Підозрілий автозапуск: $($found.Count)" (($found | Select-Object -First 5) -join ' | ') @{ type = 'manual' } @((New-D9Link 'Microsoft Safety Scanner (перевірка на віруси)' 'https://learn.microsoft.com/defender-endpoint/safety-scanner-download')) -Data ([pscustomobject]@{ items = $found })
    }
}

function Get-D9InstalledPrograms {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 }
}

function ConvertTo-D9Version {
    param([string]$Text)
    if ($Text -notmatch '(\d+)(\.(\d+))?(\.(\d+))?') { return $null }
    [version]("{0}.{1}.{2}" -f $Matches[1], $(if ($Matches[3]) { $Matches[3] } else { 0 }), $(if ($Matches[5]) { $Matches[5] } else { 0 }))
}

# Програми з відомими вразливостями або без підтримки (config/software-risks.json)
function Test-D9RiskySoftware {
    param($Check, $Ctx)
    $rules = (ConvertFrom-Json (Get-D9ConfigText 'software-risks.json')).programs
    $installed = @(Get-D9InstalledPrograms)
    foreach ($rule in $rules) {
        foreach ($app in ($installed | Where-Object DisplayName -like $rule.pattern | Sort-Object DisplayName -Unique)) {
            $reason = Get-D9Text $rule.reason
            if ($rule.eol) {
                $ended = [datetime]::ParseExact($rule.eol, 'yyyy-MM-dd', $null)
                if ($Ctx.Now -ge $ended) {
                    New-D9Finding $Check warning "$($app.DisplayName) більше не отримує оновлень безпеки (з $($ended.ToString('dd.MM.yyyy')))" "$reason Оновіть до підтримуваної версії або замініть." @{ type = 'manual' } -Key "$($Check.id):$($app.DisplayName)"
                } elseif (($ended - $Ctx.Now).TotalDays -le 90) {
                    New-D9Finding $Check suggestion "$($app.DisplayName): підтримка закінчується $($ended.ToString('dd.MM.yyyy'))" $reason @{ type = 'manual' } -Key "$($Check.id):$($app.DisplayName)"
                }
                continue
            }
            $have = ConvertTo-D9Version "$($app.DisplayVersion) $($app.DisplayName)"
            $need = [version]$rule.minVersion
            if ($have -and $have -lt $need) {
                $severity = if ($rule.exploited) { 'critical' } else { 'warning' }
                $fix = if ($rule.winget) { @{ type = 'apps'; ids = @($rule.winget) } } else { @{ type = 'manual' } }
                $how = if ($rule.winget) { "Debloater9 оновить її через winget до актуальної версії." } else { "Оновіть щонайменше до $($rule.minVersion)." }
                New-D9Finding $Check $severity "$($app.DisplayName) $($app.DisplayVersion) має відомі вразливості" "$reason $how" $fix @($rule.url | Where-Object { $_ } | ForEach-Object { New-D9Link 'Офіційний сайт' $_ }) -Key "$($Check.id):$($app.DisplayName)"
            }
        }
    }
}

function Test-D9UnsignedDrivers {
    param($Check, $Ctx)
    $bad = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceName -and $_.IsSigned -eq $false })
    if ($bad) {
        New-D9Finding $Check warning "Драйвери без цифрового підпису: $($bad.Count)" ("Непідписані драйвери можуть бути підробленими або нестабільними: " + (($bad | Select-Object -First 5 | ForEach-Object { "$($_.DeviceName) ($($_.DriverProviderName))" }) -join ', ')) @{ type = 'drivers' }
    }
}

function Test-D9UpdatesPaused {
    param($Check, $Ctx)
    $ux = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue
    if ($ux.PauseUpdatesExpiryTime) {
        $until = [datetime]::Parse($ux.PauseUpdatesExpiryTime, [Globalization.CultureInfo]::InvariantCulture)
        if ($until -gt $Ctx.Now) {
            $days = [int]($until - $Ctx.Now).TotalDays
            New-D9Finding $Check suggestion "Оновлення Windows призупинено ще на $days дн. (до $($until.ToString('dd.MM.yyyy')))" 'На час паузи не приходять і виправлення безпеки. Відновіть, коли зможете: Параметри → Windows Update.' @{ type = 'manual' } @((New-D9Link 'Windows Update' 'ms-settings:windowsupdate'))
        }
    }
}

function Test-D9DefenderConfig {
    param($Check, $Ctx)
    $status = try { Get-MpComputerStatus -ErrorAction Stop } catch { $null }
    if (-not $status -or -not $status.AntivirusEnabled) { return }   # Захисник не основний антивірус — не перевіряємо
    $link = New-D9Link 'Безпека Windows' 'windowsdefender:'
    if ($status.IsTamperProtected -eq $false) {
        New-D9Finding $Check suggestion 'Захист від втручання (Tamper Protection) вимкнено' 'Шкідливі програми можуть непомітно вимкнути Захисник. Увімкніть: Безпека Windows → Захист від вірусів → Керування параметрами → Захист від втручання.' @{ type = 'manual' } @($link) -Key "$($Check.id):tamper"
    }
    $pref = try { Get-MpPreference -ErrorAction Stop } catch { $null }
    if ($pref) {
        if ($pref.PUAProtection -eq 0) {
            New-D9Finding $Check suggestion 'Блокування потенційно небажаних програм вимкнено' 'Захисник не блокує рекламні «довантажувачі», тулбари й майнери. Debloater9 увімкне блокування.' (New-D9ActionsFix @(@{ type = 'command'; run = 'Set-MpPreference -PUAProtection Enabled'; undoRun = 'Set-MpPreference -PUAProtection Disabled'; test = '(Get-MpPreference).PUAProtection -eq 1'; label = @{ uk = 'Увімкнути блокування небажаних програм'; en = 'Enable PUA protection' } })) @($link) -Key "$($Check.id):pua"
        }
        $wide = @($pref.ExclusionPath | Where-Object { $_ -and $_ -notmatch '^N/A' -and ($_ -match '^[A-Za-z]:\\?$' -or $_ -match '\\(Users|Temp|AppData|Downloads|Windows)\\?$') })
        if ($wide) {
            # Навмисно вручну: автоматична зміна винятків Захисника (і її відкат) виглядає для антивірусів як шкідлива дія
            New-D9Finding $Check warning "Захисник не перевіряє цілі папки: $($wide -join ', ')" 'Такі винятки часто додають шкідливі програми, щоб сховатися. Якщо ви їх не додавали — видаліть у Безпека Windows → Захист від вірусів → Керування параметрами → Винятки.' @{ type = 'manual' } @($link) -Key "$($Check.id):exclusions"
        }
    }
}

function Test-D9DiskEncryption {
    param($Check, $Ctx)
    if (-not $Ctx.System.HasBattery) { return }   # для ноутбуків: ризик крадіжки
    $vol = try { Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter = '$env:SystemDrive'" -ErrorAction Stop } catch { return New-D9Skip $Check 'потрібні права адміністратора' }
    if ($vol -and $vol.ProtectionStatus -eq 0) {
        New-D9Finding $Check suggestion 'Диск ноутбука не зашифровано' 'Якщо ноутбук вкрадуть, файли можна прочитати, просто вийнявши диск. Увімкніть BitLocker або «Шифрування пристрою» (Параметри → Конфіденційність і захист). Обов''язково збережіть ключ відновлення!' @{ type = 'manual' } @((New-D9Link 'Шифрування пристрою' 'ms-settings:deviceencryption'))
    }
}

function Test-D9RestorePoints {
    param($Check, $Ctx)
    $points = try { @(Get-ComputerRestorePoint -ErrorAction Stop) } catch { return New-D9Skip $Check 'потрібні права адміністратора' }
    $disabled = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -ErrorAction SilentlyContinue).DisableSR -eq 1
    if ($disabled -or -not $points) {
        return New-D9Finding $Check warning 'Немає жодної точки відновлення системи' 'Якщо після оновлення чи драйвера Windows перестане працювати, відкотитися не буде куди. Debloater9 увімкне захист системи для диска C: і створить першу точку.' @{ type = 'maintenance'; action = 'enableRestore' } @((New-D9Link 'Захист системи' 'SystemPropertiesProtection.exe'))
    }
    $last = ($points | ForEach-Object { [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) } | Sort-Object -Descending | Select-Object -First 1)
    $days = [int]($Ctx.Now - $last).TotalDays
    if ($days -gt $Check.thresholds.days) {
        New-D9Finding $Check suggestion "Остання точка відновлення — $days дн. тому" 'Створіть свіжу точку перед змінами в системі.' @{ type = 'maintenance'; action = 'restorePoint' }
    }
}

function Test-D9UserBackup {
    param($Check, $Ctx)
    $fileHistory = Test-Path "$env:LOCALAPPDATA\Microsoft\Windows\FileHistory\Configuration\Config1.xml"
    $shell = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    $kfm = @($shell.Desktop, $shell.Personal) | Where-Object { $_ -match 'OneDrive' }
    if (-not $fileHistory -and -not $kfm) {
        New-D9Finding $Check suggestion 'Ваші документи й фото ніде не резервуються' 'Якщо диск відмовить, файли зникнуть. Найпростіше: увімкнути резервне копіювання папок в OneDrive / Google Drive або «Журнал файлів» на зовнішній диск.' @{ type = 'manual' } @((New-D9Link 'Резервне копіювання Windows' 'ms-settings:backup'))
    }
}
