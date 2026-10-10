BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:out  = Join-Path $TestDrive 'dist'
    & (Join-Path $root 'build\Compile.ps1') -OutDir $out -Version '0.0.0-test' *> $null
    $script:file = Join-Path $out 'Debora.ps1'
}

Describe 'Збірка' {
    It 'створює один файл і SHA256SUMS' {
        Test-Path $file | Should -BeTrue
        Get-Content (Join-Path $out 'SHA256SUMS') | Should -Match '^[0-9a-f]{64}  Debora\.ps1$'
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
        $output = powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $file -Gui -SelfTest 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'вкладок 10'
    }
    It 'поруч лежать обидва запускачі й інструкція' {
        foreach ($f in 'run.bat', 'run-menu.bat', 'Інструкція.txt') { Test-Path (Join-Path $out $f) | Should -BeTrue -Because $f }
    }
    It 'вбудована база пристроїв працює в зібраному файлі' {
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file -Drivers 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Важливі драйвери'
    }
    It 'зібраний файл виводить каталог у дочірньому процесі' {
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file -ListTweaks 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'privacy\.telemetry'
    }
}
