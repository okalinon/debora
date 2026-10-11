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
    Write-D9Log (T-D9 'Крок 1/2: відновлення сховища компонентів Windows (DISM). Це може тривати 10–30 хвилин...')
    try {
        $r = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop
        Write-D9Log ('  ' + (T-D9 'Стан образу: {0}' $r.ImageHealthState)) $(if ([string]$r.ImageHealthState -eq 'Healthy') { 'Ok' } else { 'Warn' })
    } catch { Write-D9Log "  DISM: $($_.Exception.Message)" Warn }
    Write-D9Log (T-D9 'Крок 2/2: перевірка системних файлів (sfc /scannow)...')
    $code = Invoke-D9Native 'sfc.exe' @('/scannow')
    if ($code -eq 0) { Write-D9Log (T-D9 'Системні файли перевірено.') Ok } else { Write-D9Log (T-D9 'sfc завершився з кодом {0} — подробиці в C:\Windows\Logs\CBS\CBS.log' $code) Warn }
    return [pscustomobject]@{ Done = $true; RebootRecommended = $true }
}

# Очищення кешу DNS, скидання Winsock і TCP/IP — коли інтернет «є, але не працює»
function Invoke-D9NetworkReset {
    Write-D9Log (T-D9 'Скидання мережевих налаштувань...')
    [void](Invoke-D9Native 'ipconfig.exe' @('/flushdns'))
    [void](Invoke-D9Native 'netsh.exe' @('winsock', 'reset'))
    [void](Invoke-D9Native 'netsh.exe' @('int', 'ip', 'reset'))
    Write-D9Log (T-D9 'Готово. Перезавантажте комп''ютер, щоб скидання запрацювало.') Ok
    return [pscustomobject]@{ Done = $true; RebootRecommended = $true }
}

# Коли оновлення «зависли» або постійно падають: зупинка служб, перейменування кешів, запуск служб
function Invoke-D9WindowsUpdateReset {
    $services = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
    Write-D9Log (T-D9 'Зупинка служб оновлення...')
    foreach ($s in $services) { Stop-Service $s -Force -ErrorAction SilentlyContinue }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($dir in "$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2") {
        if (Test-Path $dir) {
            try { Rename-Item $dir "$(Split-Path $dir -Leaf).d9-$stamp" -ErrorAction Stop; Write-D9Log ('  ' + (T-D9 'Перейменовано: {0} → *.d9-{1}' $dir $stamp)) Detail }
            catch { Write-D9Log ('  ' + (T-D9 'Не вдалося перейменувати {0} (зайнято?): {1}' $dir $_.Exception.Message)) Warn }
        }
    }
    Write-D9Log (T-D9 'Запуск служб оновлення...')
    foreach ($s in $services) { Start-Service $s -ErrorAction SilentlyContinue }
    Write-D9Log (T-D9 'Готово. Windows Update створить кеш заново; старі папки *.d9-* Debora прибере сама через тиждень під час очищення диска.') Ok
    return [pscustomobject]@{ Done = $true; RebootRecommended = $false }
}

# Власні залишки Debora: завантажені пакети драйверів (вже встановлені — копії лежать у сховищі драйверів
# Windows, а для відкату — у driver-backup) і кеші Windows Update, перейменовані скиданням понад $Days днів тому.
function Get-D9DeboraLeftovers {
    param([int]$Days = 7, [datetime]$Now = (Get-Date))
    $items = @()
    $dl = Join-Path (Get-D9DataRoot) 'driver-downloads'
    if (Test-Path -LiteralPath $dl) { $items += @(Get-ChildItem -LiteralPath $dl -Force -ErrorAction SilentlyContinue | ForEach-Object FullName) }
    foreach ($parent in $env:SystemRoot, "$env:SystemRoot\System32") {
        foreach ($d in @(Get-ChildItem -LiteralPath $parent -Directory -Filter '*.d9-*' -ErrorAction SilentlyContinue)) {
            if ($d.Name -match '\.d9-(\d{8})-\d{6}$' -and [datetime]::ParseExact($Matches[1], 'yyyyMMdd', $null) -lt $Now.AddDays(-$Days)) { $items += $d.FullName }
        }
    }
    $items
}

function Clear-D9DeboraLeftovers {
    param([int]$Days = 7)
    $freed = [long]0
    foreach ($p in @(Get-D9DeboraLeftovers -Days $Days)) {
        $size = Get-D9FolderSize $p
        try {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop   # -Force знімає «лише читання» з файлів кешу
            $freed += $size
        } catch { Write-D9Log ('  ' + (T-D9 'Не вдалося видалити {0}: {1}' $p $_.Exception.Message)) Detail }
    }
    if ($freed) { Write-D9Log ('  ' + (T-D9 'Залишки Debora (пакети драйверів, старі кеші оновлень): звільнено {0}.' (Format-D9Size $freed))) Detail }
    return $freed
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
        description = [pscustomobject]@{ uk = "До $($Now.AddDays($Days).ToString('dd.MM.yyyy')). На цей час не приходять і виправлення безпеки."; en = "Until $($Now.AddDays($Days).ToString('yyyy-MM-dd')). Security fixes are paused too." }
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

# Старі журнали обслуговування (CBS): архіви CbsPersist_*.log / *.cab. Поточний CBS.log не чіпаємо.
function Clear-D9CbsLogs {
    $dir = Join-Path $env:SystemRoot 'Logs\CBS'
    $files = @(Get-ChildItem $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'CbsPersist_*' -or $_.Extension -eq '.cab' })
    $size = [long](($files | Measure-Object Length -Sum).Sum)
    $removed = 0
    foreach ($f in $files) {
        try { [IO.File]::Delete($f.FullName); $removed++ } catch { Write-D9Log ('  ' + (T-D9 'Зайнятий, пропущено: {0}' $f.Name)) Detail }
    }
    Write-D9Log (T-D9 'Видалено старих журналів CBS: {0} з {1} ({2}).' $removed $files.Count (Format-D9Size $size)) Ok
    [pscustomobject]@{ Done = $true; RebootRecommended = $false; Removed = $removed }
}

# Windows.old і тимчасові файли встановлення — штатним «Очищенням диска» (cleanmgr /sagerun): воно саме
# знімає захист цих папок. Після цього відкотити оновлення Windows уже не можна.
function Remove-D9WindowsOld {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $handlers = @('Previous Installations', 'Temporary Setup Files')
    $flag = 'StateFlags0091'
    $before = [long]((@("$env:SystemDrive\Windows.old", "$env:SystemDrive\`$WINDOWS.~BT") | ForEach-Object { Get-D9FolderSize $_ 4000 } | Measure-Object -Sum).Sum)
    Write-D9Log (T-D9 'Видалення попередньої версії Windows через «Очищення диска» (кілька хвилин)...')
    try {
        foreach ($h in $handlers) { if (Test-Path -LiteralPath "$root\$h") { Set-ItemProperty -LiteralPath "$root\$h" -Name $flag -Value 2 -Type DWord } }
        Start-Process cleanmgr.exe -ArgumentList '/sagerun:91' -Wait -WindowStyle Hidden
    } finally {
        foreach ($h in $handlers) { if (Test-Path -LiteralPath "$root\$h") { Remove-ItemProperty -LiteralPath "$root\$h" -Name $flag -ErrorAction SilentlyContinue } }
    }
    $left = Test-Path -LiteralPath "$env:SystemDrive\Windows.old"
    if ($left) { Write-D9Log (T-D9 'Windows.old ще є — частину файлів Windows видалить після перезавантаження.') Warn }
    else { Write-D9Log (T-D9 'Попередню версію Windows видалено, звільнено близько {0}.' (Format-D9Size $before)) Ok }
    [pscustomobject]@{ Done = $true; RebootRecommended = $left }
}

# Файли — у Кошик (їх можна відновити). Повертає кількість перенесених.
function Move-D9FilesToRecycleBin {
    param([string[]]$Paths)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $moved = 0
    foreach ($p in @($Paths | Where-Object { $_ })) {
        try {
            if (Test-Path -LiteralPath $p -PathType Container) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin') }
            elseif (Test-Path -LiteralPath $p) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin') }
            else { continue }
            $moved++
            Write-D9Log ('  ' + (T-D9 'У Кошик: {0}' $p)) Detail
        } catch { Write-D9Log ('  ' + (T-D9 'Не вдалося перенести в Кошик {0}: {1}' $p $_.Exception.Message)) Warn }
    }
    Write-D9Log (T-D9 'Перенесено в Кошик: {0}. Відновити можна з Кошика.' $moved) Ok
    $moved
}
