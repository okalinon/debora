BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    function New-Item9([string]$Name, [string]$Exe, [bool]$Enabled = $true) {
        [pscustomobject]@{ Name = $Name; Command = $Exe; Exe = $Exe; Publisher = 'X'; Enabled = $Enabled; Where = 'Реєстр (користувач)'; Kind = 'reg'
                           ApprovedPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; ValueName = $Name; Missing = $false; Verdict = $null; Reason = $null }
    }
}

Describe 'Поради для автозапуску' {
    It '<name> → <verdict>' -TestCases @(
        @{ name = 'Steam'; exe = 'C:\Program Files (x86)\Steam\steam.exe'; verdict = 'disable' }
        @{ name = 'SecurityHealth'; exe = 'C:\Windows\system32\SecurityHealthSystray.exe'; verdict = 'keep' }
        @{ name = 'Discord'; exe = 'C:\Users\u\AppData\Local\Discord\Update.exe'; verdict = 'optional' }
        @{ name = 'SomethingElse'; exe = 'C:\Users\u\AppData\Local\Other\Update.exe'; verdict = $null }
        @{ name = 'MicrosoftEdgeAutoLaunch_123'; exe = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; verdict = 'disable' }
        @{ name = 'OneDrive'; exe = 'C:\Users\u\AppData\Local\Microsoft\OneDrive\OneDrive.exe'; verdict = 'optional' }
    ) {
        $a = Get-D9StartupAdvice (New-Item9 $name $exe)
        if ($verdict) { $a.Verdict | Should -Be $verdict; $a.Reason | Should -Not -BeNullOrEmpty } else { $a | Should -BeNullOrEmpty }
    }
    It 'оновлювачі браузерів не вимикаються (безпека)' {
        Get-D9StartupAdvice (New-Item9 'GoogleUpdaterTaskUser' 'C:\Program Files\Google\GoogleUpdater\updater.exe') | Should -BeNullOrEmpty
    }
}

Describe 'Автозапуск у скануванні' {
    It 'рекомендоване до вимкнення → автоматичне виправлення з відкатом, «на розсуд» — ні' {
        Mock Get-D9StartupItems {
            $s = New-Item9 'Steam' 'C:\Steam\steam.exe'; $s.Verdict = 'disable'; $s.Reason = 'лаунчер'
            $e = New-Item9 'EpicGamesLauncher' 'C:\Epic\EpicGamesLauncher.exe'; $e.Verdict = 'disable'; $e.Reason = 'лаунчер'
            $v = New-Item9 'Viber' 'C:\Viber\Viber.exe'; $v.Verdict = 'optional'
            $off = New-Item9 'Spotify' 'C:\Spotify.exe' $false; $off.Verdict = 'disable'
            @($s, $e, $v, $off)
        }
        $check = [pscustomobject]@{ id = 'perf.startup'; category = 'performance'; thresholds = [pscustomobject]@{ warning = 8; suggestion = 5; weakPcSuggestion = 3 } }
        $ctx = [pscustomobject]@{ Recommendation = [pscustomobject]@{ Preset = 'Standard' } }
        $f = @(Test-D9Startup $check $ctx)
        $f.Count | Should -Be 1
        $f[0].fix.type | Should -Be 'actions'
        @($f[0].fix.actions).Count | Should -Be 2 -Because 'лише ввімкнені й рекомендовані'
        $f[0].fix.actions[0].type | Should -Be 'registry'
        $f[0].fix.actions[0].value[0] | Should -Be 3 -Because '03… — вимкнено, як у Диспетчері завдань'
        $f[0].title | Should -Match 'Непотрібне в автозапуску: 2'
    }
}
