<#
.SYNOPSIS
    Усі тести Pester — кожен файл в окремому процесі з обмеженням часу (тести вікна можуть повиснути на модальному
    вікні, а один спільний процес тоді зупинив би все). Виводить рядок на файл і повертає код 1, якщо щось не пройшло.
.EXAMPLE
    .\build\Test-All.ps1
.EXAMPLE
    .\build\Test-All.ps1 -Only Setup,Gui
#>
param([string[]]$Only, [int]$TimeoutSec = 240)
$root = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path ([IO.Path]::GetTempPath()) "d9-tests-$PID"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
if ($Only) { $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }
$failed = 0; $passed = 0; $skipped = 0
foreach ($f in Get-ChildItem (Join-Path $root 'tests') -Filter '*.Tests.ps1') {
    $name = $f.BaseName -replace '\.Tests$', ''
    if ($Only -and $Only -notcontains $name) { continue }
    $res = Join-Path $tmp "$name.txt"
    $cmd = "Import-Module Pester -MinimumVersion 5; `$r = Invoke-Pester '$($f.FullName)' -PassThru -Output None; " +
           "@('{0} {1} {2}' -f `$r.PassedCount, `$r.FailedCount, `$r.SkippedCount) + @(`$r.Failed | ForEach-Object { `$_.ExpandedPath + ' :: ' + (`$_.ErrorRecord[0].ToString() -split [char]10)[0] }) | Out-File '$res' -Encoding utf8"
    $t = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process powershell -ArgumentList '-NoProfile', '-Command', $cmd -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $p.Kill(); $failed++
        Write-Host ("{0,-16} TIMEOUT ({1} с)" -f $name, $TimeoutSec) -ForegroundColor Red
        continue
    }
    $lines = @(Get-Content $res -Encoding UTF8 -ErrorAction SilentlyContinue)
    if (-not $lines) { $failed++; Write-Host ("{0,-16} немає результату" -f $name) -ForegroundColor Red; continue }
    $p1, $f1, $s1 = @($lines[0] -split ' ' | ForEach-Object { [int]$_ })
    $passed += $p1; $failed += $f1; $skipped += $s1
    Write-Host ("{0,-16} {1,4} ok {2,3} fail {3,3} skip  {4,5:n0} с" -f $name, $p1, $f1, $s1, $t.Elapsed.TotalSeconds) -ForegroundColor $(if ($f1) { 'Red' } else { 'Green' })
    foreach ($l in $lines | Select-Object -Skip 1) { Write-Host "    $l" -ForegroundColor Red }
}
Write-Host ("Разом: {0} пройшли, {1} не пройшли, {2} пропущено" -f $passed, $failed, $skipped) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
if ($failed) { exit 1 }
