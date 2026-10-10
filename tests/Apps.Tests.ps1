BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $script:apps = Import-D9AppCatalog
}

Describe 'Каталог програм' {
    It 'ID унікальні, категорії відомі, є назва й опис' {
        $ids = @($apps.apps.id)
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        foreach ($a in $apps.apps) {
            $apps.categories.id | Should -Contain $a.category -Because $a.id
            $a.name | Should -Not -BeNullOrEmpty -Because $a.id
            $a.description.uk | Should -Not -BeNullOrEmpty -Because $a.id
            if ($a.source) { $a.source | Should -BeIn @('winget', 'msstore') -Because $a.id }
        }
    }
    It 'ID Microsoft Store — 12 символів, winget — «Видавець.Назва»' {
        foreach ($a in $apps.apps) {
            if ($a.source -eq 'msstore') { $a.id | Should -Match '^[0-9A-Z]{12}$' -Because $a.name }
            else { $a.id | Should -Match '^[^\s.]+\.[^\s]+$' -Because $a.name }
        }
    }
    It 'кожна категорія має програми' {
        foreach ($c in $apps.categories) { @($apps.apps | Where-Object category -eq $c.id).Count | Should -BeGreaterThan 0 -Because $c.id }
    }
}

Describe 'Виклик winget' {
    It 'аргументи встановлення: точний ID, джерело, без запитань' {
        $args1 = Get-D9AppArguments ([pscustomobject]@{ id = 'Google.Chrome' })
        $args1[0..2] | Should -Be @('install', '--id', 'Google.Chrome')
        $args1 | Should -Contain '--exact'
        $args1[$args1.IndexOf('--source') + 1] | Should -Be 'winget'
        $args1 | Should -Contain '--silent'
        $args1 | Should -Contain '--disable-interactivity'
        $store = Get-D9AppArguments ([pscustomobject]@{ id = '9WZDNCRFHVN5'; source = 'msstore' })
        $store[$store.IndexOf('--source') + 1] | Should -Be 'msstore'
    }
    It 'коди завершення: <code> → <result>' -TestCases @(
        @{ code = 0; result = 'installed' }
        @{ code = -1978335135; result = 'already' }
        @{ code = -1978335189; result = 'upToDate' }
        @{ code = -1978335212; result = 'notFound' }
        @{ code = -1978334967; result = 'reboot' }
        @{ code = 1603; result = 'failed' }
    ) {
        ConvertFrom-D9WingetCode $code | Should -Be $result
    }
    It 'журнал без індикаторів прогресу' {
        $lines = Select-D9WingetLines @('Found Google Chrome [Google.Chrome]', '  ██████████▒▒▒▒  50 MB / 100 MB', '-', "  \`r  /", 'Successfully installed')
        $lines | Should -Be @('Found Google Chrome [Google.Chrome]', 'Successfully installed')
    }
}

Describe 'Розбір таблиці winget upgrade' {
    It 'англійський вивід зі сміттям прогресу і підсумком' {
        $out = @(
            '   - \ | /'
            'Name                         Id                          Version  Available Source'
            '----------------------------------------------------------------------------------'
            '7-Zip 24.07 (x64)            7zip.7zip                   24.07    26.04     winget'
            'Microsoft Visual Studio Cod… Microsoft.VisualStudioCode  1.90.0   1.105.1   winget'
            'Epic Games Launcher          EpicGames.EpicGamesLauncher < 1.3.93 1.3.210.0 winget'
            '3 upgrades available.'
        )
        $r = @(ConvertFrom-D9WingetTable $out)
        $r.Count | Should -Be 3
        $r[0].Id | Should -Be '7zip.7zip'
        $r[0].Name | Should -Be '7-Zip 24.07 (x64)'
        $r[0].Version | Should -Be '24.07'
        $r[0].Available | Should -Be '26.04'
        $r[1].Id | Should -Be 'Microsoft.VisualStudioCode'
        $r[2].Version | Should -Be '< 1.3.93'
    }
    It 'локалізований заголовок і порожній результат' {
        @(ConvertFrom-D9WingetTable @('Не знайдено доступних оновлень.')).Count | Should -Be 0
        $out = @('Назва   Ідентифікатор   Версія  Доступно  Джерело', '----------------------------------------------------', 'Git     Git.Git         2.45.1  2.51.0    winget')
        (@(ConvertFrom-D9WingetTable $out))[0].Id | Should -Be 'Git.Git'
    }
}

Describe 'Встановлення (з підміною winget)' {
    It 'повертає результат для кожної програми й не зупиняється на помилці' {
        Mock Invoke-D9Winget {
            $code = switch ($Arguments[2]) { 'Ok.App' { 0 } 'Has.App' { -1978335135 } default { 1603 } }
            [pscustomobject]@{ Code = $code; Output = @('Installer failed with exit code: 1603') }
        }
        $list = @(
            [pscustomobject]@{ id = 'Ok.App'; name = 'Ok' }
            [pscustomobject]@{ id = 'Bad.App'; name = 'Bad' }
            [pscustomobject]@{ id = 'Has.App'; name = 'Has' }
        )
        $r = @(Install-D9Apps -Apps $list)
        $r.result | Should -Be @('installed', 'failed', 'already')
        Should -Invoke Invoke-D9Winget -Times 3 -Exactly
    }
    It 'оновлення конкретних програм: якщо winget не пов''язав програму з пакетом — встановлює поверх' {
        Mock Invoke-D9Winget {
            $code = if ($Arguments[0] -eq 'upgrade' -and $Arguments[2] -eq 'VideoLAN.VLC') { -1978335212 } else { 0 }
            [pscustomobject]@{ Code = $code; Output = @() }
        }
        $r = @(Update-D9Apps -Ids @('7zip.7zip', 'VideoLAN.VLC'))
        $r.result | Should -Be @('installed', 'installed')
        Should -Invoke Invoke-D9Winget -Times 3 -Exactly
        Should -Invoke Invoke-D9Winget -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'install' -and $Arguments[2] -eq 'VideoLAN.VLC' }
    }
    It 'встановлені програми: ID з усіх джерел winget export' {
        Mock Invoke-D9Winget {
            $file = $Arguments[$Arguments.IndexOf('-o') + 1]
            $json = '{"Sources":[{"Packages":[{"PackageIdentifier":"Google.Chrome"},{"PackageIdentifier":"7zip.7zip"}]},{"Packages":[{"PackageIdentifier":"9NKSQGP7F2NH"}]}]}'
            [IO.File]::WriteAllText($file, $json)
            [pscustomobject]@{ Code = 0; Output = @() }
        }
        $ids = Get-D9InstalledAppIds
        $ids.Count | Should -Be 3
        $ids.Contains('google.chrome') | Should -BeTrue -Because 'порівняння без урахування регістру'
        $ids.Contains('9NKSQGP7F2NH') | Should -BeTrue
    }
}
