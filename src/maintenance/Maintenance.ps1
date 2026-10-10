# Інструменти обслуговування: відновлення системних файлів, скидання мережі й Windows Update,
# пауза оновлень. Пауза — через рушій (журнал і відкат); решта — разові операції з журналом виконання.

function Invoke-D9Native {
    param([string]$File, [string[]]$Arguments)
    Write-D9Log "  > $File $($Arguments -join ' ')" Detail
    $out = & $File @Arguments 2>&1 | Out-String
    $out = $out -replace "`0", ''          # sfc пише UTF-16 — прибираємо нульові символи
    foreach ($line in ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 6)) { Write-D9Log "    $($line.Trim())" Detail }
    return $LASTEXITCODE
}

# DISM /RestoreHealth (потрібен інтернет) + sfc /scannow. 10–40 хвилин.
function Invoke-D9RepairSystem {
    Write-D9Log 'Крок 1/2: відновлення сховища компонентів Windows (DISM). Це може тривати 10–30 хвилин...'
    try {
        $r = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop
        Write-D9Log "  Стан образу: $($r.ImageHealthState)" $(if ([string]$r.ImageHealthState -eq 'Healthy') { 'Ok' } else { 'Warn' })
    } catch { Write-D9Log "  DISM: $($_.Exception.Message)" Warn }
    Write-D9Log 'Крок 2/2: перевірка системних файлів (sfc /scannow)...'
    $code = Invoke-D9Native 'sfc.exe' @('/scannow')
    if ($code -eq 0) { Write-D9Log 'Системні файли перевірено.' Ok } else { Write-D9Log "sfc завершився з кодом $code — подробиці в C:\Windows\Logs\CBS\CBS.log" Warn }
    return [pscustomobject]@{ Done = $true; RebootRecommended = $true }
}

# Очищення кешу DNS, скидання Winsock і TCP/IP — коли інтернет «є, але не працює»
function Invoke-D9NetworkReset {
    Write-D9Log 'Скидання мережевих налаштувань...'
    [void](Invoke-D9Native 'ipconfig.exe' @('/flushdns'))
    [void](Invoke-D9Native 'netsh.exe' @('winsock', 'reset'))
    [void](Invoke-D9Native 'netsh.exe' @('int', 'ip', 'reset'))
    Write-D9Log 'Готово. Перезавантажте комп''ютер, щоб скидання запрацювало.' Ok
    return [pscustomobject]@{ Done = $true; RebootRecommended = $true }
}

# Коли оновлення «зависли» або постійно падають: зупинка служб, перейменування кешів, запуск служб
function Invoke-D9WindowsUpdateReset {
    $services = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
    Write-D9Log 'Зупинка служб оновлення...'
    foreach ($s in $services) { Stop-Service $s -Force -ErrorAction SilentlyContinue }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($dir in "$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2") {
        if (Test-Path $dir) {
            try { Rename-Item $dir "$(Split-Path $dir -Leaf).d9-$stamp" -ErrorAction Stop; Write-D9Log "  Перейменовано: $dir → *.d9-$stamp" Detail }
            catch { Write-D9Log "  Не вдалося перейменувати $dir (зайнято?): $($_.Exception.Message)" Warn }
        }
    }
    Write-D9Log 'Запуск служб оновлення...'
    foreach ($s in $services) { Start-Service $s -ErrorAction SilentlyContinue }
    Write-D9Log 'Готово. Windows Update створить кеш заново; старі папки *.d9-* можна видалити через тиждень.' Ok
    return [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

# Пауза оновлень Windows на N днів (як кнопка в Параметрах; максимум 35 днів)
function New-D9PauseUpdatesCatalog {
    param([ValidateRange(1, 35)][int]$Days = 7, [datetime]$Now = (Get-Date))
    $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $start = $Now.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $end = $Now.AddDays($Days).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $values = [ordered]@{
        PauseUpdatesStartTime = $start; PauseUpdatesExpiryTime = $end
        PauseFeatureUpdatesStartTime = $start; PauseFeatureUpdatesEndTime = $end
        PauseQualityUpdatesStartTime = $start; PauseQualityUpdatesEndTime = $end
    }
    $actions = foreach ($k in $values.Keys) { [pscustomobject]@{ type = 'registry'; path = $key; name = $k; value = $values[$k]; kind = 'String' } }
    [pscustomobject]@{ Presets = @(); Tweaks = @([pscustomobject]@{
        id = 'updates.pause'; category = 'updates'; risk = 'moderate'
        name = [pscustomobject]@{ uk = "Призупинити оновлення Windows на $Days дн."; en = "Pause Windows updates for $Days days" }
        description = [pscustomobject]@{ uk = "До $($Now.AddDays($Days).ToString('dd.MM.yyyy')). На цей час не приходять і виправлення безпеки."; en = 'Security fixes are paused too.' }
        actions = @($actions)
    }) }
}

function New-D9ResumeUpdatesCatalog {
    $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $names = 'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime'
    [pscustomobject]@{ Presets = @(); Tweaks = @([pscustomobject]@{
        id = 'updates.resume'; category = 'updates'; risk = 'safe'
        name = [pscustomobject]@{ uk = 'Відновити оновлення Windows'; en = 'Resume Windows updates' }
        description = [pscustomobject]@{ uk = 'Скасовує паузу оновлень.'; en = 'Cancels the update pause.' }
        actions = @($names | ForEach-Object { [pscustomobject]@{ type = 'registry'; path = $key; name = $_; delete = $true } })
    }) }
}
