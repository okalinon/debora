# Оновлення самої Debora: чи є новіша версія, перевірка архіву за SHA-256, заміна файлів з резервною копією
BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    function New-Release([string]$Tag, [string]$Zip, [string]$Digest) {
        $asset = [pscustomobject]@{ name = "Debora-$($Tag.TrimStart('v')).zip"; browser_download_url = "https://github.com/x/y/releases/download/$Tag/Debora.zip"; digest = $Digest }
        [pscustomobject]@{ tag_name = $Tag; body = 'Що нового'; html_url = 'https://github.com/x/y/releases'; assets = @($asset) }
    }
}
AfterAll { Remove-Item Env:\D9_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'Оновлення Debora' {
    BeforeEach {
        $env:D9_DATA_ROOT = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Get-D9UpdateRepo { 'x/y' }
        # «Нова версія» в архіві
        $script:pkg = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$pkg\Debora-1.0.1" -Force | Out-Null
        Set-Content "$pkg\Debora-1.0.1\Debora.ps1" 'NEW' -Encoding UTF8
        Set-Content "$pkg\Debora-1.0.1\Debora.dat" 'NEWDAT' -Encoding UTF8
        $script:zip = Join-Path $pkg 'Debora-1.0.1.zip'
        Compress-Archive -Path "$pkg\Debora-1.0.1" -DestinationPath $zip
        $script:hash = (Get-FileHash $zip -Algorithm SHA256).Hash
        # «Встановлена» програма з папками користувача
        $script:prog = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$prog\Звіти" -Force | Out-Null
        Set-Content "$prog\Debora.ps1" 'OLD' -Encoding UTF8
        Set-Content "$prog\Звіти\звіт.html" 'мій звіт' -Encoding UTF8
    }
    It 'новіша версія доступна; та сама чи старша — ні; збірка розробника й порожній repo не перевіряються' {
        (Get-D9UpdateInfo -Current '1.0.0' -Release (New-Release 'v1.0.1' $zip "sha256:$hash")).Available | Should -BeTrue
        (Get-D9UpdateInfo -Current '1.0.1' -Release (New-Release 'v1.0.1' $zip "sha256:$hash")).Available | Should -BeFalse
        (Get-D9UpdateInfo -Current '1.2.0' -Release (New-Release 'v1.0.1' $zip "sha256:$hash")).Available | Should -BeFalse
        Get-D9UpdateInfo -Current '1.0.0-dev' -Release (New-Release 'v1.0.1' $zip "sha256:$hash") | Should -BeNullOrEmpty
        Mock Get-D9UpdateRepo { $null }
        Get-D9UpdateInfo -Current '1.0.0' -Release (New-Release 'v1.0.1' $zip "sha256:$hash") | Should -BeNullOrEmpty
    }
    It 'архів зі збіжною сумою: файли замінено, попередні — у резервній копії, папки користувача цілі' {
        $info = Get-D9UpdateInfo -Current '1.0.0' -Release (New-Release 'v1.0.1' $zip "sha256:$hash")
        $path = Install-D9Update -Info $info -ProgramDir $prog -DownloadFile $zip
        $path | Should -Be (Join-Path $prog 'Debora.ps1')
        (Get-Content "$prog\Debora.ps1" -Raw).Trim() | Should -Be 'NEW'
        (Get-Content "$prog\Debora.dat" -Raw).Trim() | Should -Be 'NEWDAT'
        (Get-Content "$prog\Звіти\звіт.html" -Raw).Trim() | Should -Be 'мій звіт'
        (Get-Content (Join-Path $env:D9_DATA_ROOT 'update-backup\1.0.0\Debora.ps1') -Raw).Trim() | Should -Be 'OLD'
    }
    It 'сума не збігається або її немає — нічого не замінюється' {
        $bad = Get-D9UpdateInfo -Current '1.0.0' -Release (New-Release 'v1.0.1' $zip ('sha256:' + ('0' * 64)))
        { Install-D9Update -Info $bad -ProgramDir $prog -DownloadFile $zip } | Should -Throw '*сума*'
        (Get-Content "$prog\Debora.ps1" -Raw).Trim() | Should -Be 'OLD'
        $none = Get-D9UpdateInfo -Current '1.0.0' -Release (New-Release 'v1.0.1' $zip $null)
        { Install-D9Update -Info $none -ProgramDir $prog -DownloadFile $zip } | Should -Throw
        (Get-Content "$prog\Debora.ps1" -Raw).Trim() | Should -Be 'OLD'
    }
    It 'чужий адрес завантаження відкидається' {
        $r = New-Release 'v1.0.1' $zip "sha256:$hash"
        $r.assets[0].browser_download_url = 'https://evil.example.com/Debora.zip'
        $info = Get-D9UpdateInfo -Current '1.0.0' -Release $r
        { Install-D9Update -Info $info -ProgramDir $prog } | Should -Throw '*джерело*'
    }
    It 'перевірка раз на добу; без repo — ніколи' {
        $saved = $script:D9Version
        try {
            $script:D9Version = '1.0.0'
            Test-D9UpdateCheckDue | Should -BeTrue
            Save-D9UpdateCheck -Latest '1.0.0'
            Test-D9UpdateCheckDue | Should -BeFalse
            Test-D9UpdateCheckDue -Now (Get-Date).AddHours(21) | Should -BeTrue
            Mock Get-D9UpdateRepo { $null }
            Test-D9UpdateCheckDue -Now (Get-Date).AddHours(21) | Should -BeFalse
        } finally { $script:D9Version = $saved }
    }
}
