# Мультимовність: T-D9, словники config/lang-en-*.json, переклад розмітки вікна
BeforeAll {
    . (Join-Path $PSScriptRoot '_Load.ps1')
    $script:root = Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName System.Web.Extensions
    $script:ser = New-Object Web.Script.Serialization.JavaScriptSerializer
    $script:dict = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($f in Get-ChildItem (Join-Path $root 'config') -Filter 'lang-en-*.json') {
        $j = $ser.DeserializeObject([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
        foreach ($kv in $j['strings'].GetEnumerator()) { $dict[$kv.Key] = $kv.Value }
    }
    # Шаблони T-D9 з коду: перший аргумент — рядок в одинарних лапках ('' — апостроф)
    $script:templates = @(foreach ($f in Get-ChildItem (Join-Path $root 'src') -Recurse -Filter '*.ps1') {
        $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        foreach ($m in [regex]::Matches($text, "T-D9\s+'((?:[^']|'')*)'")) {
            [pscustomobject]@{ File = $f.Name; Text = $m.Groups[1].Value.Replace("''", "'") }
        }
    })
    function Get-Placeholders([string]$s) { @([regex]::Matches(($s -replace '\{\{|\}\}', ''), '\{(\d+)[^}]*\}') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique) }
}
AfterAll { Set-D9Language uk }

Describe 'Словники' {
    It 'усі словники — коректний JSON без порожніх перекладів' {
        foreach ($f in Get-ChildItem (Join-Path $root 'config') -Filter 'lang-*.json') {
            $j = $ser.DeserializeObject([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
            foreach ($kv in $j['strings'].GetEnumerator()) { [string]$kv.Value | Should -Not -BeNullOrEmpty -Because "$($f.Name): $($kv.Key)" }
        }
    }
    It 'кожен шаблон T-D9 у коді має англійський переклад' {
        $missing = @($templates | Where-Object { -not $dict.ContainsKey($_.Text) } | ForEach-Object { "$($_.File): $($_.Text)" } | Sort-Object -Unique)
        $missing | Should -BeNullOrEmpty
    }
    It 'у перекладі ті самі підстановки {0}, {1}…' {
        $bad = @(foreach ($t in $templates | Where-Object { $dict.ContainsKey($_.Text) }) {
            if (((Get-Placeholders $t.Text) -join ',') -ne ((Get-Placeholders $dict[$t.Text]) -join ',')) { "$($t.File): $($t.Text)" }
        })
        $bad | Should -BeNullOrEmpty
    }
    It 'уся розмітка вікна перекладена' {
        Set-D9Language en
        $x = Convert-D9XamlLanguage (Get-D9UiText 'MainWindow.xaml')
        $left = @([regex]::Matches($x, '(?:Text|Content|Header|ToolTip|Title)="([^"]*[А-Яа-яІіЇїЄєҐґ][^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'Українська / English' })
        $left | Should -BeNullOrEmpty
        { [xml]$x } | Should -Not -Throw
        Set-D9Language uk
    }
}

Describe 'Мова' {
    It 'T-D9: українська без змін, англійська — переклад, підстановки' {
        Set-D9Language uk
        T-D9 'Огляд' | Should -Be 'Огляд'
        Set-D9Language en
        T-D9 'Огляд' | Should -Be 'Overview'
        T-D9 'Немає такого рядка {0}' 5 | Should -Be 'Немає такого рядка 5'   # без перекладу — українська
        Set-D9Language uk
    }
    It 'Resolve-D9Language: явний вибір має перевагу' {
        Resolve-D9Language 'en' | Should -Be 'en'
        Resolve-D9Language 'uk' | Should -Be 'uk'
        Resolve-D9Language 'auto' | Should -BeIn 'uk', 'en'
    }
}
