# Утиліти виробників ПК для драйверів і BIOS: найповніше джерело для своїх моделей. На ПК Dell, Lenovo
# і HP Debora сам ставить утиліту (winget) і запускає її в тихому режимі командного рядка.
# Увага: перевірено за документацією виробників, на реальних ПК ще не запускалося — усе пишеться в журнал.

$script:D9OemTools = @(
    @{ Vendor = 'Dell'; Match = '^Dell'; WingetId = 'Dell.CommandUpdate'; Name = 'Dell Command | Update'
       Exe = @('Dell\CommandUpdate\dcu-cli.exe')
       Args = @('/applyUpdates', '-silent', '-reboot=disable', '-updateType=driver,bios,firmware')
       # 0 — встановлено; 1 — потрібне перезавантаження; 500 — оновлень немає
       Ok = @(0, 1, 500); Reboot = @(1) }
    @{ Vendor = 'Lenovo'; Match = '^LENOVO'; WingetId = 'Lenovo.SystemUpdate'; Name = 'Lenovo System Update'
       Exe = @('Lenovo\System Update\tvsu.exe')
       Args = @('/CM')
       # System Update 5 бере параметри /CM лише з реєстру (захист від підміни командного рядка)
       Prepare = {
           $key = 'HKLM:\SOFTWARE\WOW6432Node\Lenovo\System Update\Preferences\UserSettings\General'
           if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
           Set-ItemProperty -Path $key -Name AdminCommandLine -Value '/CM -search A -action INSTALL -includerebootpackages 1,3,4 -noicon -noreboot -nolicense'
       }
       Ok = @(0); Reboot = @() }
    @{ Vendor = 'HP'; Match = '^(HP|Hewlett)'; WingetId = 'HP.ImageAssistant'; Name = 'HP Image Assistant'
       Exe = @('HP\HPIA\HPImageAssistant.exe', 'HPImageAssistant\HPImageAssistant.exe')
       Args = @('/Operation:Analyze', '/Action:Install', '/Selection:All', '/Category:Drivers,Firmware', '/Silent', '/Noninteractive')
       # 256 — встановлено, потрібне перезавантаження; 3010 — так само; 0 — успішно
       Ok = @(0, 256, 3010, 4096); Reboot = @(256, 3010) }
)

function Get-D9OemTool {
    param([Parameter(Mandatory)]$SystemInfo)
    $script:D9OemTools | Where-Object { [string]$SystemInfo.Manufacturer -match $_.Match } | Select-Object -First 1
}

function Find-D9OemToolExe {
    param([Parameter(Mandatory)]$Tool)
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\SWSetup') | Where-Object { $_ }
    foreach ($rel in $Tool.Exe) { foreach ($r in $roots) { $p = Join-Path $r $rel; if (Test-Path -LiteralPath $p) { return $p } } }
    # HP Image Assistant розпаковується в довільну папку — шукаємо неглибоко
    $leaf = Split-Path $Tool.Exe[0] -Leaf
    foreach ($r in $roots) {
        $hit = Get-ChildItem $r -Filter $leaf -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# Ставить (за потреби) і запускає утиліту виробника. Повертає $null, якщо виробник не підтримується.
function Invoke-D9OemDriverTool {
    param([Parameter(Mandatory)]$SystemInfo)
    $tool = Get-D9OemTool $SystemInfo
    if (-not $tool) { return $null }
    Write-D9Log "Утиліта виробника: $($tool.Name)..."
    $exe = Find-D9OemToolExe $tool
    if (-not $exe -and (Get-D9WingetPath)) {
        Write-D9Log "  Встановлення $($tool.Name) через winget..." Detail
        [void](Install-D9Apps -Apps @([pscustomobject]@{ id = $tool.WingetId; name = $tool.Name }))
        $exe = Find-D9OemToolExe $tool
    }
    if (-not $exe) { Write-D9Log "  $($tool.Name) не знайдено й не вдалося встановити — пропускаю." Warn; return [pscustomobject]@{ Tool = $tool.Name; Done = $false; RebootRecommended = $false } }
    try { if ($tool.Prepare) { & $tool.Prepare } } catch { Write-D9Log "  Підготовка: $($_.Exception.Message)" Warn }
    Write-D9Log "  Запуск: $exe $($tool.Args -join ' ') (може тривати 10–30 хвилин)" Detail
    $p = Start-Process -FilePath $exe -ArgumentList $tool.Args -Wait -PassThru -WindowStyle Hidden
    $code = $p.ExitCode
    $ok = $tool.Ok -contains $code
    Write-D9Log "  $($tool.Name) завершилась з кодом $code$(if ($ok) { ' — успішно' } else { ' — подробиці в журналі утиліти' })" $(if ($ok) { 'Ok' } else { 'Warn' })
    [pscustomobject]@{ Tool = $tool.Name; Done = $ok; Code = $code; RebootRecommended = ($tool.Reboot -contains $code) }
}
