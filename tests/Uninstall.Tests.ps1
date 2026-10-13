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
    # Шляхи в прикладах вигадані — вважаємо, що деінсталятори існують (осиротілі записи перевіряються окремо)
    BeforeAll { Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like 'C:\Program Files*' -or $LiteralPath -like 'C:\App*' } }
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

Describe 'Розмір, папка й залишки програм' {
    # Не в TestDrive: папки в \Temp\ навмисно не вважаються папками програм
    BeforeAll { $script:work = Join-Path $env:LOCALAPPDATA ('DeboraTests\' + [guid]::NewGuid().ToString('N')) }
    AfterAll { if (Test-Path $work) { [IO.Directory]::Delete((Split-Path $work), $true) } }
    It 'назва без версії й розрядності: <name> → <clean>' -TestCases @(
        @{ name = 'Notepad++ (64-bit x64)'; clean = 'Notepad++' }
        @{ name = 'NVIDIA PhysX System Software 9.23.1019'; clean = 'NVIDIA PhysX System Software' }
        @{ name = '7-Zip 24.08 (x64)'; clean = '7-Zip' }
        @{ name = 'OBS Studio'; clean = 'OBS Studio' }
    ) {
        param($name, $clean)
        Get-D9CleanProgramName $name | Should -Be $clean
    }
    It 'папка програми: зі значка у вкладеній bin\64bit — корінь програми; системні папки — ні' {
        $root = Join-Path $work 'Apps\Studio'
        New-Item -ItemType Directory -Path (Join-Path $root 'bin\64bit') -Force | Out-Null
        Get-D9ProgramFolder ([pscustomobject]@{ DisplayIcon = "`"$root\bin\64bit\studio.exe`",0" }) | Should -Be $root
        Get-D9ProgramFolder ([pscustomobject]@{ InstallLocation = $env:ProgramFiles }) | Should -BeNullOrEmpty
        Get-D9ProgramFolder ([pscustomobject]@{ UninstallString = "MsiExec.exe /X{11111111-2222-3333-4444-555555555555}" }) | Should -BeNullOrEmpty
    }
    It 'залишки: папка в AppData і розділ Software; чужі й великі вкладення — пропускаються' {
        $old = $env:APPDATA
        try {
            $env:APPDATA = Join-Path $work 'Roaming'
            New-Item -ItemType Directory -Path (Join-Path $env:APPDATA 'ZzDeboraTestApp') -Force | Out-Null
            Set-Content (Join-Path $env:APPDATA 'ZzDeboraTestApp\settings.ini') 'x'
            New-Item -Path 'HKCU:\SOFTWARE\ZzDeboraTestApp' -Force | Out-Null
            $prog = [pscustomobject]@{ Name = 'ZzDeboraTestApp 1.2.3'; Publisher = ''; Folder = $null }
            $left = @(Find-D9UninstallLeftovers -Program $prog)
            ($left | Where-Object Type -eq 'folder').Path | Should -Be (Join-Path $env:APPDATA 'ZzDeboraTestApp')
            ($left | Where-Object Type -eq 'registry').Path | Should -Contain 'HKCU:\SOFTWARE\ZzDeboraTestApp'
            # Інша встановлена програма з тією ж назвою — нічого не чіпаємо
            @(Find-D9UninstallLeftovers -Program $prog -Remaining @([pscustomobject]@{ Name = 'ZzDeboraTestApp 2.0'; Folder = $null })).Count | Should -Be 0
            # Усередині папки стоїть інша програма (як ігри в папці Steam) — папку пропускаємо
            $nested = [pscustomobject]@{ Name = 'Game'; Folder = (Join-Path $env:APPDATA 'ZzDeboraTestApp\games\Game') }
            @(Find-D9UninstallLeftovers -Program $prog -Remaining @($nested) | Where-Object Type -eq 'folder').Count | Should -Be 0
        } finally { $env:APPDATA = $old; [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('SOFTWARE\ZzDeboraTestApp', $false) }
    }
    It 'розділ реєстру видаляється лише після резервної копії .reg' {
        New-Item -Path 'HKCU:\SOFTWARE\Debloater9Test\leftover\sub' -Force | Out-Null
        Set-ItemProperty 'HKCU:\SOFTWARE\Debloater9Test\leftover' -Name v -Value 1
        $r = Remove-D9UninstallLeftovers -Items @([pscustomobject]@{ Type = 'registry'; Path = 'HKCU:\SOFTWARE\Debloater9Test\leftover'; Size = 0 })
        $r.Removed | Should -Be 1
        Test-Path 'HKCU:\SOFTWARE\Debloater9Test\leftover' | Should -BeFalse
        $reg = Get-ChildItem $r.Backup -Filter '*.reg'
        $reg.Count | Should -Be 1
        (Get-Content $reg[0].FullName -Raw) | Should -Match 'Debloater9Test\\leftover'
    }
}

Describe 'Записи без деінсталятора й порожні аргументи' {
    It 'деінсталятор без аргументів запускається (раніше: «ArgumentList is null or empty»)' {
        $key = 'HKCU:\Software\Debloater9Test\noargs'
        New-Item -Path $key -Force | Out-Null
        $prog = New-Prog @{ Name = 'NoArgs'; Key = $key; UninstallString = "$env:SystemRoot\System32\whoami.exe" }
        (Get-D9UninstallCommand $prog).Args | Should -BeNullOrEmpty
        $r = Uninstall-D9Programs -Programs @($prog) -TimeoutMinutes 1
        $r.result | Should -Be 'stillPresent'   # whoami не видаляє запис, але запуск має пройти без помилки
        $r.message | Should -Not -Match 'ArgumentList'
    }
    It 'осиротілий запис (немає ні деінсталятора, ні папки) — прибирається лише запис, з копією .reg' {
        $key = 'HKCU:\Software\Debloater9Test\orphan'
        New-Item -Path $key -Force | Out-Null
        $prog = New-Prog @{ Name = 'Orphan'; Key = (Get-Item $key).PSPath; UninstallString = 'Q:\NoSuchDir\NoSuch App\app.exe' }
        (Get-D9UninstallCommand $prog).Method | Should -Be 'orphan'
        $r = Uninstall-D9Programs -Programs @($prog)
        $r.result | Should -Be 'removed'
        Test-Path $key | Should -BeFalse
    }
    It 'деінсталятора немає, а папка програми є — нічого не чіпаємо, радимо лаунчер' {
        $key = 'HKCU:\Software\Debloater9Test\missing'
        New-Item -Path $key -Force | Out-Null
        $dir = Join-Path $TestDrive 'Game'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $prog = New-Prog @{ Name = 'Game'; Key = (Get-Item $key).PSPath; UninstallString = "$dir\uninstall.exe" }
        (Get-D9UninstallCommand $prog).Method | Should -Be 'missing'
        (Uninstall-D9Programs -Programs @($prog)).result | Should -Be 'failed'
        Test-Path $key | Should -BeTrue
    }
}

Describe 'Швидке читання «Програм і засобів» (.NET)' {
    It 'ті самі записи й значення, що й Get-ChildItem + Get-ItemProperty; шлях придатний для Test-Path' {
        $key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\zzDeboraFast'
        try {
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty $key -Name DisplayName -Value 'Debora Fast Test'
            Set-ItemProperty $key -Name EstimatedSize -Value 1234 -Type DWord
            Set-ItemProperty $key -Name UninstallString -Value '%SystemRoot%\x.exe' -Type ExpandString
            $fast = @(Get-D9UninstallEntries | Where-Object PSChildName -eq 'zzDeboraFast')
            $fast.Count | Should -Be 1
            $slow = Get-ItemProperty -LiteralPath (Get-Item $key).PSPath
            $fast[0].DisplayName | Should -Be $slow.DisplayName
            $fast[0].EstimatedSize | Should -Be $slow.EstimatedSize
            $fast[0].UninstallString | Should -Be $slow.UninstallString   # розгорнуто, як у Get-ItemProperty
            $fast[0].PSPath | Should -Be (Get-Item $key).PSPath
            Test-Path -LiteralPath $fast[0].PSPath | Should -BeTrue
            # Набір ключів поточного користувача — такий самий, як у Get-ChildItem
            $root = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            $a = @(Get-ChildItem $root | ForEach-Object PSChildName | Sort-Object)
            $b = @(Get-D9UninstallEntries | Where-Object { $_.PSPath -like '*HKEY_CURRENT_USER*' } | ForEach-Object PSChildName | Sort-Object)
            ($b -join '|') | Should -Be ($a -join '|')
        } finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\zzDeboraFast', $false) }
    }
}

Describe 'Записи від видалених програм у реєстрі' {
    It 'App Paths на неіснуючий exe — знаходиться й прибирається з копією .reg' {
        $key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\zzdeboratest.exe'
        try {
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -Path $key -Name '(default)' -Value 'Q:\NoSuchDir\zzdeboratest.exe'
            $hit = @(Get-D9OrphanRegistryEntries | Where-Object Name -eq 'zzdeboratest.exe')
            $hit.Count | Should -Be 1
            $hit[0].Kind | Should -Be 'apppath'
            # Прибираємо лише тестовий запис (справжні записи цього ПК тест не чіпає)
            (Remove-D9UninstallLeftovers -Items @([pscustomobject]@{ Type = 'registry'; Path = $hit[0].Path; Size = 0 })).Removed | Should -Be 1
            Test-Path $key | Should -BeFalse
        } finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\zzdeboratest.exe', $false) }
    }
}

Describe 'Видалення через лаунчер (Steam тощо)' {
    It 'розпізнає лаунчери, яким деінсталятор лише передає команду' {
        Get-D9UninstallLauncher ([pscustomobject]@{ File = 'C:\Program Files (x86)\Steam\steam.exe'; Args = 'steam://uninstall/377160' }) | Should -Be 'Steam'
        Get-D9UninstallLauncher ([pscustomobject]@{ File = 'C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe'; Args = '' }) | Should -Be 'Epic Games'
        Get-D9UninstallLauncher ([pscustomobject]@{ File = 'C:\Games\X\unins000.exe'; Args = '/SILENT' }) | Should -BeNullOrEmpty
    }
}
