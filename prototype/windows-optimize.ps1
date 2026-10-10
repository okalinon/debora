# =====================================================================
#  Оптимізація та деблоат Windows 10 / 11 — з вікном вибору
#  Запуск: подвійний клік по run.bat (сам попросить права адміністратора)
# =====================================================================

# Перезапуск з правами адміністратора, якщо їх немає
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'SilentlyContinue'

$Win11  = [Environment]::OSVersion.Version.Build -ge 22000
$OsName = if ($Win11) { "Windows 11" } else { "Windows 10" }

# ---------------------------------------------------------------------
#  Допоміжні функції
# ---------------------------------------------------------------------
function Log($text) {
    $script:LogBox.AppendText("$text`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Reg($Path, $Name, $Value, $Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Remove-Apps($names) {
    foreach ($app in $names) {
        foreach ($p in (Get-AppxPackage -AllUsers -Name $app)) {
            Log "    - $($p.Name)"
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers
        }
        Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $app |
            Remove-AppxProvisionedPackage -Online | Out-Null
    }
}

function Disable-Services($names) {
    foreach ($s in $names) {
        if (Get-Service $s) {
            Stop-Service $s -Force
            Set-Service $s -StartupType Disabled
            Log "    - $s"
        }
    }
}

$Adv = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

# ---------------------------------------------------------------------
#  Список дій. Default = чи вибрано в режимі "Рекомендовані"
#  (рекомендації підібрані для слабкого ПК: 4 ГБ RAM + HDD)
# ---------------------------------------------------------------------
$Tweaks = @(
    # ======================= Безпека =======================
    @{ Group = "Безпека"; Default = $true
       Name  = "Створити точку відновлення"
       Tip   = "Дозволяє відкотити всі зміни: Пуск -> 'Відновлення' -> Запуск відновлення системи."
       Action = {
           Enable-ComputerRestore -Drive "$env:SystemDrive\"
           Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" "SystemRestorePointCreationFrequency" 0
           Checkpoint-Computer -Description "Before windows-optimize" -RestorePointType MODIFY_SETTINGS
           if ($?) { Log "    Точку відновлення створено" } else { Log "    Не вдалося створити точку відновлення" }
       } }

    # ======================= Застосунки =======================
    @{ Group = "Застосунки"; Default = $true
       Name  = "Видалити непотрібні вбудовані застосунки"
       Tip   = "Новини, Погода, Пасьянс, Clipchamp, To Do, Power Automate, Поради, Office Hub, Feedback Hub, Карти, Кіно й ТБ, Зв'язок із телефоном, Family, Dev Home, Candy Crush, TikTok, Spotify тощо. Store, Калькулятор, Фото, Нотатки, Медіаплеєр лишаються."
       Action = {
           $apps = @(
               "Microsoft.BingNews","Microsoft.BingWeather","Microsoft.BingSearch","Microsoft.BingFinance","Microsoft.BingSports",
               "Clipchamp.Clipchamp","Microsoft.Todos","Microsoft.PowerAutomateDesktop","Microsoft.GetHelp","Microsoft.Getstarted",
               "Microsoft.MicrosoftOfficeHub","Microsoft.MicrosoftSolitaireCollection","Microsoft.WindowsFeedbackHub",
               "Microsoft.WindowsMaps","Microsoft.ZuneVideo","Microsoft.YourPhone","MicrosoftCorporationII.MicrosoftFamily",
               "Microsoft.Windows.DevHome","Microsoft.549981C3F5F10","Microsoft.3DBuilder","Microsoft.Microsoft3DViewer",
               "Microsoft.MixedReality.Portal","Microsoft.SkypeApp","Microsoft.People","Microsoft.Wallet","Microsoft.Messaging",
               "Microsoft.Print3D","Microsoft.OneConnect","Microsoft.Office.OneNote",
               "*CandyCrush*","*BubbleWitch*","*Disney*","*Spotify*","*Netflix*","*TikTok*","*Facebook*","*Instagram*",
               "*Twitter*","*king.com*","*LinkedIn*"
           )
           # У Windows 10 ZuneMusic = Groove (можна видаляти), у Windows 11 це новий Медіаплеєр — лишаємо
           if (-not $Win11) { $apps += "Microsoft.ZuneMusic" }
           Remove-Apps $apps
       } }

    @{ Group = "Застосунки"; Default = $true
       Name  = "Видалити Teams і новий Outlook"
       Tip   = "Безкоштовний Teams і 'новий Outlook', які ставляться разом із системою. Прибирає й іконку чату з панелі завдань."
       Action = {
           Remove-Apps @("MSTeams","MicrosoftTeams","Microsoft.OutlookForWindows")
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat" "ChatIcon" 3
           Set-Reg $Adv "TaskbarMn" 0
       } }

    @{ Group = "Застосунки"; Default = $true
       Name  = "Вимкнути та видалити Copilot"
       Tip   = "Прибирає Copilot і його кнопку. На слабкому ПК він лише забирає пам'ять."
       Action = {
           Remove-Apps @("Microsoft.Copilot","Microsoft.Windows.Ai.Copilot.Provider")
           Set-Reg "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
           Set-Reg $Adv "ShowCopilotButton" 0
       } }

    @{ Group = "Застосунки"; Default = $true
       Name  = "Видалити OneDrive"
       Tip   = "OneDrive запускається разом із системою і забирає пам'ять. Не вибирайте, якщо зберігаєте файли в OneDrive."
       Action = {
           Stop-Process -Name OneDrive -Force
           Start-Sleep -Seconds 2
           $setups = @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") +
                     @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\OneDrive\*\OneDriveSetup.exe" | ForEach-Object FullName)
           $setup = $setups | Where-Object { Test-Path $_ } | Select-Object -First 1
           if ($setup) { Start-Process $setup "/uninstall" -Wait; Log "    OneDrive видалено" }
           else { Log "    Інсталятор OneDrive не знайдено (можливо, його вже немає)" }
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" 1
       } }

    @{ Group = "Застосунки"; Default = $false
       Name  = "Видалити Xbox-застосунки та служби"
       Tip   = "Не вибирайте, якщо граєте через Xbox / Game Pass або користуєтеся Xbox Game Bar."
       Action = {
           Remove-Apps @("Microsoft.XboxApp","Microsoft.GamingApp","Microsoft.XboxGameOverlay","Microsoft.XboxGamingOverlay",
                         "Microsoft.XboxIdentityProvider","Microsoft.XboxSpeechToTextOverlay","Microsoft.Xbox.TCUI")
           Disable-Services @("XblAuthManager","XblGameSave","XboxNetApiSvc","XboxGipSvc")
       } }

    @{ Group = "Застосунки"; Default = $true
       Name  = "Заборонити автоустановку 'рекомендованих' застосунків"
       Tip   = "Windows сама встановлює ігри та програми-партнерів. Цей пункт це вимикає."
       Action = {
           $cdm = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
           foreach ($n in "ContentDeliveryAllowed","OemPreInstalledAppsEnabled","PreInstalledAppsEnabled",
                          "PreInstalledAppsEverEnabled","SilentInstalledAppsEnabled") { Set-Reg $cdm $n 0 }
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
       } }

    # ======================= Конфіденційність =======================
    @{ Group = "Конфіденційність"; Default = $true
       Name  = "Вимкнути телеметрію"
       Tip   = "Збір діагностичних даних, служба DiagTrack і заплановані завдання телеметрії."
       Action = {
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
           Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 0
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod" 0
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "AITEnable" 0
           Disable-Services @("DiagTrack","dmwappushservice")
           $tasks = @(
               "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"
               "\Microsoft\Windows\Application Experience\ProgramDataUpdater"
               "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator"
               "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"
               "\Microsoft\Windows\Autochk\Proxy"
               "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector"
               "\Microsoft\Windows\Feedback\Siuf\DmClient"
               "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload"
           )
           foreach ($t in $tasks) {
               Disable-ScheduledTask -TaskPath ((Split-Path $t -Parent) + "\") -TaskName (Split-Path $t -Leaf) | Out-Null
           }
       } }

    @{ Group = "Конфіденційність"; Default = $true
       Name  = "Вимкнути рекламу, поради та пропозиції"
       Tip   = "Рекламний ID, 'поради та підказки', пропозиції в меню Пуск і в Параметрах, реклама на екрані блокування."
       Action = {
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" 1
           $cdm = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
           foreach ($n in "SystemPaneSuggestionsEnabled","SubscribedContentEnabled","SoftLandingEnabled",
                          "RotatingLockScreenOverlayEnabled","SubscribedContent-338387Enabled","SubscribedContent-338388Enabled",
                          "SubscribedContent-338389Enabled","SubscribedContent-338393Enabled","SubscribedContent-353694Enabled",
                          "SubscribedContent-353696Enabled","SubscribedContent-353698Enabled") { Set-Reg $cdm $n 0 }
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableSoftLanding" 1
           Set-Reg $Adv "Start_IrisRecommendations" 0
           Set-Reg $Adv "ShowSyncProviderNotifications" 0
       } }

    @{ Group = "Конфіденційність"; Default = $true
       Name  = "Вимкнути журнал дій та Recall"
       Tip   = "Історія дій (Timeline) і функція Recall, яка робить знімки екрана для ШІ."
       Action = {
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
           Set-Reg "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
       } }

    @{ Group = "Конфіденційність"; Default = $false
       Name  = "Вимкнути службу геолокації"
       Tip   = "Застосунки не зможуть визначати місцезнаходження (погода, карти, автоматичний часовий пояс)."
       Action = { Disable-Services @("lfsvc") } }

    # ======================= Інтерфейс =======================
    @{ Group = "Інтерфейс"; Default = $true
       Name  = "Вимкнути віджети / 'Новини та інтереси'"
       Tip   = "Панель віджетів (Windows 11) або 'Новини та інтереси' (Windows 10) постійно працює у фоні."
       Action = {
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds" 0
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds" "ShellFeedsTaskbarViewMode" 2
       } }

    @{ Group = "Інтерфейс"; Default = $true
       Name  = "Пошук без Bing, Cortana та веб-результатів"
       Tip   = "Пошук у меню Пуск шукає лише на комп'ютері, а не в інтернеті. На панелі завдань — іконка замість довгого поля."
       Action = {
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" 1
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" 0
           Set-Reg "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 0
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "CortanaConsent" 0
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 1
           Set-Reg $Adv "ShowCortanaButton" 0
       } }

    @{ Group = "Інтерфейс"; Default = $true; Win11Only = $true
       Name  = "Класичне контекстне меню (правий клік)"
       Tip   = "Повертає повне меню правої кнопки миші без 'Показати додаткові параметри'. Відкривається швидше."
       Action = {
           $k = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
           New-Item -Path $k -Force | Out-Null
           Set-ItemProperty -Path $k -Name "(default)" -Value ""
       } }

    @{ Group = "Інтерфейс"; Default = $true; Win11Only = $true
       Name  = "Меню Пуск: більше закріплених, без 'Рекомендованих'"
       Tip   = "Прибирає рекомендовані файли та застосунки з меню Пуск, звільняючи місце під закріплені."
       Action = {
           Set-Reg $Adv "Start_Layout" 1
           Set-Reg $Adv "Start_IrisRecommendations" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "HideRecommendedSection" 1
       } }

    @{ Group = "Інтерфейс"; Default = $false; Win11Only = $true
       Name  = "Панель завдань ліворуч (як у Windows 10)"
       Tip   = "Кнопка Пуск і значки ліворуч замість центру."
       Action = { Set-Reg $Adv "TaskbarAl" 0 } }

    @{ Group = "Інтерфейс"; Default = $true
       Name  = "Провідник: показувати розширення, відкривати 'Цей ПК'"
       Tip   = "Видно розширення файлів (.exe, .pdf...), Провідник відкривається на 'Цей ПК'. Прибирає кнопку 'Подання завдань'."
       Action = {
           Set-Reg $Adv "HideFileExt" 0
           Set-Reg $Adv "LaunchTo" 1
           Set-Reg $Adv "ShowTaskViewButton" 0
           Set-Reg "$Adv\People" "PeopleBand" 0
       } }

    # ======================= Продуктивність =======================
    @{ Group = "Продуктивність"; Default = $true
       Name  = "Вимкнути фонові застосунки"
       Tip   = "Застосунки з Microsoft Store не працюватимуть у фоні, коли закриті."
       Action = {
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" "GlobalUserDisabled" 1
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "BackgroundAppGlobalToggle" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground" 2
       } }

    @{ Group = "Продуктивність"; Default = $true
       Name  = "Вимкнути анімації та прозорість"
       Tip   = "Режим 'найкраща швидкодія', але шрифти лишаються гладкими, а мініатюри — на місці."
       Action = {
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 3
           Set-Reg "HKCU:\Control Panel\Desktop" "UserPreferencesMask" ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) "Binary"
           Set-Reg "HKCU:\Control Panel\Desktop" "DragFullWindows" "0" "String"
           Set-Reg "HKCU:\Control Panel\Desktop" "MenuShowDelay" "100" "String"
           Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothing" "2" "String"
           Set-Reg "HKCU:\Control Panel\Desktop\WindowMetrics" "MinAnimate" "0" "String"
           Set-Reg $Adv "TaskbarAnimations" 0
           Set-Reg $Adv "ListviewAlphaSelect" 0
           Set-Reg $Adv "ListviewShadow" 0
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\DWM" "EnableAeroPeek" 0
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency" 0
       } }

    @{ Group = "Продуктивність"; Default = $true
       Name  = "Вимкнути Game DVR (фоновий запис ігор)"
       Tip   = "Фоновий запис знижує FPS. Ігровий режим лишається увімкненим."
       Action = {
           Set-Reg "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0
           Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0
           Set-Reg "HKCU:\SOFTWARE\Microsoft\GameBar" "AutoGameModeEnabled" 1
       } }

    @{ Group = "Продуктивність"; Default = $true
       Name  = "Edge не працює у фоні після закриття"
       Tip   = "Вимикає 'прискорення запуску' та фоновий режим Edge — економія пам'яті."
       Action = {
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupBoostEnabled" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "BackgroundModeEnabled" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\Main" "AllowPrelaunch" 0
           Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\TabPreloader" "AllowTabPreloading" 0
       } }

    @{ Group = "Продуктивність"; Default = $true
       Name  = "Схема живлення 'Висока продуктивність'"
       Tip   = "Процесор не скидає частоту. На ноутбуці від батареї він розряджатиметься швидше."
       Action = {
           $hp = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
           powercfg /setactive $hp 2>$null
           if ($LASTEXITCODE -ne 0) {
               $out = powercfg -duplicatescheme $hp
               if ("$out" -match '([0-9a-fA-F-]{36})') { powercfg /setactive $Matches[1] }
           }
           Log "    Активна схема: $((powercfg /getactivescheme) -replace '^.*\(|\)$','')"
       } }

    @{ Group = "Продуктивність"; Default = $true
       Name  = "Не затримувати запуск програм з автозавантаження"
       Tip   = "Windows за замовчуванням чекає кілька секунд, перш ніж запускати програми з автозавантаження."
       Action = { Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize" "StartupDelayInMSec" 0 } }

    @{ Group = "Продуктивність"; Default = $true
       Name  = "Вимкнути індексацію пошуку (для HDD)"
       Tip   = "Індексація постійно навантажує жорсткий диск. Пошук працюватиме, але повільніше. На SSD можна не вимикати."
       Action = { Disable-Services @("WSearch") } }

    @{ Group = "Продуктивність"; Default = $true
       Name  = "Вимкнути SysMain / Superfetch (для HDD)"
       Tip   = "Часта причина 'диск 100%' на HDD з 4 ГБ RAM. На SSD або з 8+ ГБ RAM краще не вимикати."
       Action = { Disable-Services @("SysMain") } }

    @{ Group = "Продуктивність"; Default = $true
       Name  = "Вимкнути зайві служби"
       Tip   = "Звіти про помилки, діагностика, карти, факс, демо-режим, віддалений реєстр, мережевий доступ Media Player."
       Action = {
           Disable-Services @("WerSvc","DPS","WdiServiceHost","WdiSystemHost","MapsBroker","Fax",
                              "RetailDemo","RemoteRegistry","WMPNetworkSvc")
       } }

    @{ Group = "Продуктивність"; Default = $true
       Name  = "Не роздавати оновлення іншим комп'ютерам (P2P)"
       Tip   = "Windows не використовуватиме ваш інтернет і диск, щоб роздавати оновлення іншим."
       Action = { Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 0 } }

    @{ Group = "Продуктивність"; Default = $false
       Name  = "Вимкнути гібернацію"
       Tip   = "Звільнить кілька ГБ на диску C:, але вимкне 'швидкий запуск' — на HDD система вантажитиметься довше."
       Action = { powercfg -h off } }

    # ======================= Очищення =======================
    @{ Group = "Очищення"; Default = $true
       Name  = "Видалити тимчасові файли"
       Tip   = "Очищує папки TEMP користувача та Windows."
       Action = {
           Remove-Item "$env:TEMP\*" -Recurse -Force
           Remove-Item "$env:SystemRoot\Temp\*" -Recurse -Force
       } }

    @{ Group = "Очищення"; Default = $false
       Name  = "Очистити кошик"
       Tip   = "Файли з кошика буде видалено назавжди."
       Action = { Clear-RecycleBin -Force } }
)

# ---------------------------------------------------------------------
#  Вікно
# ---------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Оптимізація Windows — $OsName"
$form.Size = New-Object System.Drawing.Size(760, 780)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.MinimumSize = New-Object System.Drawing.Size(600, 500)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 20000

# Список чекбоксів
$listPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$listPanel.Dock = "Fill"
$listPanel.FlowDirection = "TopDown"
$listPanel.WrapContents = $false
$listPanel.AutoScroll = $true
$listPanel.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Наведіть мишку на пункт, щоб побачити подробиці. Виявлено: $OsName."
$hint.AutoSize = $true
$hint.ForeColor = [System.Drawing.Color]::DimGray
$listPanel.Controls.Add($hint)

$checkBoxes = @()
$lastGroup = ""
foreach ($t in $Tweaks) {
    if ($t.Group -ne $lastGroup) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $t.Group
        $lbl.AutoSize = $true
        $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
        $lbl.Margin = New-Object System.Windows.Forms.Padding(0, 14, 0, 2)
        $listPanel.Controls.Add($lbl)
        $lastGroup = $t.Group
    }
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $t.Name
    $cb.AutoSize = $true
    $cb.Tag = $t
    $cb.Margin = New-Object System.Windows.Forms.Padding(14, 2, 0, 2)
    if ($t.Win11Only -and -not $Win11) {
        $cb.Text += "  (лише Windows 11)"
        $cb.Enabled = $false
    } else {
        $cb.Checked = $t.Default
    }
    $tip.SetToolTip($cb, $t.Tip)
    $listPanel.Controls.Add($cb)
    $checkBoxes += $cb
}

# Нижня панель: кнопки + журнал
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = "Bottom"
$bottom.Height = 240

$script:LogBox = New-Object System.Windows.Forms.TextBox
$LogBox.Multiline = $true
$LogBox.ReadOnly = $true
$LogBox.ScrollBars = "Vertical"
$LogBox.Dock = "Fill"
$LogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$LogBox.BackColor = [System.Drawing.Color]::White

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Dock = "Top"
$buttons.Height = 44
$buttons.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 4)

function New-Button($text, $width) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Width = $width
    $b.Height = 30
    $buttons.Controls.Add($b)
    return $b
}
$btnRec  = New-Button "Рекомендовані" 130
$btnAll  = New-Button "Вибрати все" 110
$btnNone = New-Button "Зняти все" 110
$btnRun  = New-Button "Запустити" 140
$btnRun.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnRun.Margin = New-Object System.Windows.Forms.Padding(40, 3, 3, 3)

$btnRec.Add_Click({  foreach ($cb in $checkBoxes) { if ($cb.Enabled) { $cb.Checked = $cb.Tag.Default } } })
$btnAll.Add_Click({  foreach ($cb in $checkBoxes) { if ($cb.Enabled) { $cb.Checked = $true } } })
$btnNone.Add_Click({ foreach ($cb in $checkBoxes) { $cb.Checked = $false } })

$btnRun.Add_Click({
    $selected = @($checkBoxes | Where-Object { $_.Checked })
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Нічого не вибрано.", "Оптимізація") | Out-Null
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Буде виконано пунктів: $($selected.Count). Продовжити?", "Оптимізація",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($c in $buttons.Controls) { $c.Enabled = $false }
    foreach ($cb in $checkBoxes) { $cb.Enabled = $false }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $i = 0
    foreach ($cb in $selected) {
        $i++
        Log "[$i/$($selected.Count)] $($cb.Tag.Name)"
        try   { & $cb.Tag.Action }
        catch { Log "    Помилка: $($_.Exception.Message)" }
    }
    Log ""
    Log "Готово! Перезавантажте комп'ютер, щоб усі зміни набули чинності."

    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    $restart = [System.Windows.Forms.MessageBox]::Show(
        "Готово! Перезавантажити комп'ютер зараз?", "Оптимізація",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($restart -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Computer -Force }
    $btnRun.Text = "Виконано"
    foreach ($c in $buttons.Controls) { if ($c -ne $btnRun) { $c.Enabled = $false } }
})

$bottom.Controls.Add($LogBox)
$bottom.Controls.Add($buttons)
$form.Controls.Add($listPanel)
$form.Controls.Add($bottom)

Log "Виберіть потрібні пункти й натисніть 'Запустити'."
[void]$form.ShowDialog()
