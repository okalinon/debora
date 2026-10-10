BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $script:ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
    function Get-Xml([hashtable]$Options) { [xml](New-D9AutounattendXml -Options $Options) }
    function Get-Component($x, [string]$pass, [string]$name) { $x.unattend.settings | Where-Object pass -eq $pass | ForEach-Object { $_.component } | Where-Object name -eq $name }
}

Describe 'autounattend.xml' {
    It 'типові налаштування: мова, локальний акаунт, без акаунта Microsoft і мережі, обхід вимог Windows 11' {
        $x = Get-Xml @{ UserName = 'Оля' }
        (Get-Component $x 'windowsPE' 'Microsoft-Windows-International-Core-WinPE').UILanguage | Should -Be 'uk-UA'
        (Get-Component $x 'windowsPE' 'Microsoft-Windows-Setup').UserData.AcceptEula | Should -Be 'true'
        $bypass = @((Get-Component $x 'windowsPE' 'Microsoft-Windows-Setup').RunSynchronous.RunSynchronousCommand.Path)
        $bypass.Count | Should -Be 5
        $bypass -join ' ' | Should -Match 'BypassTPMCheck'
        (Get-Component $x 'specialize' 'Microsoft-Windows-Deployment').RunSynchronous.RunSynchronousCommand.Path | Should -Match 'BypassNRO'
        (Get-Component $x 'specialize' 'Microsoft-Windows-Shell-Setup').TimeZone | Should -Be 'FLE Standard Time'
        $shell = Get-Component $x 'oobeSystem' 'Microsoft-Windows-Shell-Setup'
        $shell.OOBE.HideOnlineAccountScreens | Should -Be 'true'
        $shell.UserAccounts.LocalAccounts.LocalAccount.Name | Should -Be 'Оля'
        $shell.UserAccounts.LocalAccounts.LocalAccount.Group | Should -Be 'Administrators'
        $shell.AutoLogon.LogonCount | Should -Be '1'
    }
    It 'після першого входу запускає Debloater9: профіль і драйвери з інтернету' {
        $cmds = @((Get-Component (Get-Xml @{ PostInstall = 'WeakPC' }) 'oobeSystem' 'Microsoft-Windows-Shell-Setup').FirstLogonCommands.SynchronousCommand)
        $cmds.Count | Should -Be 2
        $cmds[0].CommandLine | Should -Match '-Preset WeakPC -Yes'
        $cmds[1].CommandLine | Should -Match '-DriverUpdate -Yes'
        $cmds[0].CommandLine | Should -Match 'Debloater9\\Debloater9\.ps1'
    }
    It 'команда після входу — коректний PowerShell' {
        $line = (@((Get-Component (Get-Xml @{}) 'oobeSystem' 'Microsoft-Windows-Shell-Setup').FirstLogonCommands.SynchronousCommand)[0]).CommandLine
        $line -match '-Command "(.*)"$' | Should -BeTrue
        $err = $null; [void][Management.Automation.Language.Parser]::ParseInput($Matches[1], [ref]$null, [ref]$err)
        $err.Count | Should -Be 0
    }
    It 'спецсимволи в паролі екрануються, редакція задає загальний ключ' {
        $x = Get-Xml @{ Password = 'a<b>&"c'''; Edition = 'Pro' }
        (Get-Component $x 'oobeSystem' 'Microsoft-Windows-Shell-Setup').UserAccounts.LocalAccounts.LocalAccount.Password.Value | Should -Be 'a<b>&"c'''
        (Get-Component $x 'windowsPE' 'Microsoft-Windows-Setup').UserData.ProductKey.Key | Should -Be 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
    }
    It 'обхід вимог, мережі й автозапуск можна вимкнути' {
        $x = Get-Xml @{ BypassRequirements = $false; BypassNetwork = $false; PostInstall = ''; DriverUpdate = $false }
        (Get-Component $x 'windowsPE' 'Microsoft-Windows-Setup').RunSynchronous | Should -BeNullOrEmpty
        Get-Component $x 'specialize' 'Microsoft-Windows-Deployment' | Should -BeNullOrEmpty
        (Get-Component $x 'oobeSystem' 'Microsoft-Windows-Shell-Setup').FirstLogonCommands | Should -BeNullOrEmpty
    }
    It 'недопустимі імена відхиляються' {
        { New-D9AutounattendXml -Options @{ UserName = 'a/b' } } | Should -Throw
        { New-D9AutounattendXml -Options @{ ComputerName = 'ПК Олі' } } | Should -Throw
    }
}

Describe 'Підготовка флешки' {
    It 'на диску без файлів Windows — зрозуміла помилка' {
        $tmp = Join-Path $TestDrive 'usb'; New-Item -ItemType Directory $tmp | Out-Null
        { Initialize-D9InstallUsb -Drive 'Q:' -Options @{} } | Should -Throw '*Media Creation Tool*'
    }
}
