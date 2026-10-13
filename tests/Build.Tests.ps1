BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:out  = Join-Path $TestDrive 'dist'
    & (Join-Path $root 'build\Compile.ps1') -OutDir $out -Version '0.0.0-test' *> $null
    $script:file = Join-Path $out 'Debora.ps1'
    # Дочірні процеси успадковують змінну — журнал і дані йдуть у тимчасову папку, а не в журнал користувача
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
}
AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Збірка' {
    It 'створює Debora.ps1, бази в Debora.dat і SHA256SUMS для обох' {
        Test-Path $file | Should -BeTrue
        Test-Path (Join-Path $out 'Debora.dat') | Should -BeTrue
        $sums = @(Get-Content (Join-Path $out 'SHA256SUMS'))
        $sums[0] | Should -Match '^[0-9a-f]{64}  Debora\.ps1$'
        $sums[1] | Should -Match '^[0-9a-f]{64}  Debora\.dat$'
        Get-Content $file -Raw | Should -Not -Match '(?m)^<#D9-DATA\s*$'   # великі бази не сповільнюють розбір скрипта
    }
    It 'стиснена конфігурація розпаковується: усі JSON і розмітка на місці' {
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". { `$s = [IO.File]::ReadAllText('$file'); `$a = `$s.IndexOf('`$script:D9Embedded = @{}'); `$b = `$s.IndexOf('#endregion D9-COMPILED'); Invoke-Expression `$s.Substring(`$a, `$b - `$a); (`$script:D9Embedded.Keys | Sort-Object) -join ',' }" 2>&1 | Out-String
        foreach ($n in 'tweaks.json', 'checks.json', 'apps.json', 'lang-en-gui.json', 'MainWindow.xaml') { $output | Should -Match ([regex]::Escape($n)) }
    }
    It 'файл у UTF-8 з BOM' {
        $bytes = [IO.File]::ReadAllBytes($file)[0..2]
        $bytes | Should -Be @(0xEF, 0xBB, 0xBF)
    }
    It 'не містить блоку завантаження для розробки' {
        Get-Content $file -Raw | Should -Not -Match '#region D9-LOAD'
    }
    It 'містить версію' {
        Get-Content $file -Raw | Should -Match "D9Version\s*=\s*'0\.0\.0-test'"
    }
    It 'вікно будується із вбудованої розмітки' {
        $output = powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $file -Gui -SelfTest -Language uk 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'вкладок 12'
    }
    It 'поруч лежать обидва запускачі й інструкція' {
        foreach ($f in 'run.bat', 'run-menu.bat', 'Інструкція.txt') { Test-Path (Join-Path $out $f) | Should -BeTrue -Because $f }
    }
    It 'вбудована база пристроїв працює в зібраному файлі' {
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file -Drivers -Language uk 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Важливі драйвери'
    }
    It 'зібраний файл виводить каталог у дочірньому процесі' {
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file -ListTweaks 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'privacy\.telemetry'
    }
}
