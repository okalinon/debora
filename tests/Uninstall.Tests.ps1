BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $env:D9_DATA_ROOT = Join-Path $TestDrive 'data'
    function New-Prog([hashtable]$P) {
        $base = @{ Name = 'Test'; Version = '1'; Publisher = ''; Size = 0; InstallDate = $null; Key = 'HKCU:\Software\Debloater9Test\none'; KeyName = 'x'
                   UninstallString = ''; QuietUninstallString = ''; IsMsi = $false; Bloat = $null; Keep = $false }
        foreach ($k in $P.Keys) { $base[$k] = $P[$k] }
        [pscustomobject]$base
    }
}
AfterAll {
    Remove-Item 'HKCU:\Software\Debloater9Test' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue
}

Describe 'Команда видалення' {
    It 'розбір командного рядка: <line>' -TestCases @(
        @{ line = '"C:\Program Files\App\unins000.exe" /LOG'; file = 'C:\Program Files\App\unins000.exe'; rest = '/LOG' }
        @{ line = 'C:\Program Files\App\Uninstall.exe /S'; file = 'C:\Program Files\App\Uninstall.exe'; rest = '/S' }
        @{ line = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}'; file = 'MsiExec.exe'; rest = '/X{11111111-2222-3333-4444-555555555555}' }
    ) {
        $c = Split-D9CommandLine $line
        $c.File | Should -Be $file
        $c.Args | Should -Be $rest
    }
    It 'спосіб: <case>' -TestCases @(
        @{ case = 'QuietUninstallString'; p = @{ QuietUninstallString = '"C:\A\u.exe" /quiet'; UninstallString = '"C:\A\u.exe"' }; method = 'quiet'; silent = $true; expectArgs = '/quiet' }
        @{ case = 'MSI за ключем';         p = @{ IsMsi = $true; KeyName = '{11111111-2222-3333-4444-555555555555}'; UninstallString = 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}' }; method = 'msi'; silent = $true; expectArgs = '/x {11111111-2222-3333-4444-555555555555} /qn /norestart' }
        @{ case = 'MsiExec /I у рядку';    p = @{ UninstallString = 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}' }; method = 'msi'; silent = $true; expectArgs = '/x {11111111-2222-3333-4444-555555555555} /qn /norestart' }
        @{ case = 'Inno Setup';            p = @{ UninstallString = '"C:\App\unins000.exe"' }; method = 'inno'; silent = $true; expectArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        @{ case = 'NSIS';                  p = @{ UninstallString = '"C:\App\uninst.exe"' }; method = 'nsis'; silent = $true; expectArgs = '/S' }
        @{ case = 'невідомий — з вікном';  p = @{ UninstallString = '"C:\App\Setup.exe" --uninstall' }; method = 'interactive'; silent = $false; expectArgs = '--uninstall' }
    ) {
        $c = Get-D9UninstallCommand (New-Prog $p)
        $c.Method | Should -Be $method
        $c.Silent | Should -Be $silent
        $c.Args | Should -Be $expectArgs
    }
}

Describe 'Видалення (справжній запуск)' {
    BeforeAll {
        $script:key = "HKCU:\Software\Debloater9Test\uninst-$([guid]::NewGuid().ToString('N'))"
        New-Item $key -Force | Out-Null
        $regPath = $key -replace '^HKCU:\\', 'HKCU\'
        $script:gone = New-Prog @{ Name = 'Зникне'; Key = $key; QuietUninstallString = "reg.exe delete `"$regPath`" /f" }
        $script:stays = New-Prog @{ Name = 'Лишиться'; Key = 'HKCU:\Software\Debloater9Test'; QuietUninstallString = 'cmd.exe /c exit 0' }
        $script:res = @(Uninstall-D9Programs -Programs @($gone, $stays))
    }
    It 'деінсталятор прибрав запис — «видалено»' {
        $res[0].result | Should -Be 'removed'
        Test-Path $key | Should -BeFalse
    }
    It 'запис лишився — «не видалено», а не успіх' {
        $res[1].result | Should -Be 'stillPresent'
    }
}

Describe 'Небажані програми в чеклісті' {
    It 'знахідка з видаленням → автоматичний крок' {
        $check = [pscustomobject]@{ id = 'perf.known-bloat'; category = 'performance' }
        $f = New-D9Finding $check warning 'Знайдено небажані програми: 2' 'd' @{ type = 'uninstall'; names = @('McAfee LiveSafe', 'WildTangent Games') }
        $scan = [pscustomobject]@{ id = 't'; findings = @($f); system = (New-TestSystemInfo); recommendation = [pscustomobject]@{ Preset = 'Standard' } }
        $list = New-D9Checklist -Scan $scan -Catalog (Import-D9Catalog)
        $item = $list.items | Where-Object { $_.action.type -eq 'uninstall' }
        $item.auto | Should -BeTrue
        $item.title | Should -Match '\(2\)'
        $item.action.names | Should -Contain 'McAfee LiveSafe'
        ($list.items | Where-Object { $_.action.type -eq 'restorePoint' }) | Should -Not -BeNullOrEmpty
    }
}
