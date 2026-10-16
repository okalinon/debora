<#
.SYNOPSIS
    Картинки для сторінки GitHub (System.Drawing, темний фон як у головної кнопки Debora):
    social-preview.png — превʼю посилання й шапка README; levels.png — три рівні деблоату;
    how-it-works.png — сканування → виправлення → нагляд → відкат. Англійська — docs\images, українська — docs\images\uk.
    Спершу — build\New-Screenshots.ps1 (шапка вбудовує скріншот «Деблоату»). Числа беруться з config\*.json.
#>
param([ValidateSet('en', 'uk')][string[]]$Lang = @('en', 'uk'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent

function Read-Json([string]$name) { ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root "config\$name"), [Text.Encoding]::UTF8)) }
$debloat = Read-Json 'debloat.json'
$all = @($debloat.apps) + @($debloat.features) + @($debloat.items)
$nSafe = @($all | Where-Object level -eq 'safe').Count
$nRec = $nSafe + @($all | Where-Object level -eq 'recommended').Count
$nMax = $nRec + @($all | Where-Object level -eq 'max').Count
$nChecks = @((Read-Json 'checks.json').checks).Count

$bg = [Drawing.Color]::FromArgb(29, 29, 31)
$card = [Drawing.Color]::FromArgb(44, 44, 46)
$white = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(242, 242, 247))
$grey = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(174, 174, 178))
$accent = @{ green = [Drawing.Color]::FromArgb(48, 209, 88); blue = [Drawing.Color]::FromArgb(10, 132, 255); orange = [Drawing.Color]::FromArgb(255, 159, 10); purple = [Drawing.Color]::FromArgb(191, 90, 242) }
function Font([float]$px, [switch]$Bold) { New-Object Drawing.Font $(if ($Bold) { 'Segoe UI Semibold' } else { 'Segoe UI' }), $px, ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel) }
function New-Canvas([int]$w, [int]$h) {
    $bmp = New-Object Drawing.Bitmap $w, $h
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'   # GridFit розтягує проміжки в кирилиці; $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear($bg)
    @{ Bmp = $bmp; G = $g }
}
function Save-Canvas($c, [string]$path) { $c.G.Dispose(); $c.Bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $c.Bmp.Dispose(); Write-Host "  $path" }
function Text($g, [string]$s, $font, $brush, [float]$x, [float]$y, [float]$w = 0, [float]$h = 0) {
    if ($w) { $g.DrawString($s, $font, $brush, (New-Object Drawing.RectangleF $x, $y, $w, $h)) } else { $g.DrawString($s, $font, $brush, $x, $y) }
}
function RoundRect($g, $color, [float]$x, [float]$y, [float]$w, [float]$h, [float]$r = 18) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90); $p.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
    $p.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90); $p.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90); $p.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush $color), $p)
}
function Logo($g, [float]$x, [float]$y, [float]$size) {
    $ico = New-Object Drawing.Icon (Join-Path $PSScriptRoot 'debora.ico'), 256, 256
    $g.DrawImage($ico.ToBitmap(), $x, $y, $size, $size)
}

foreach ($l in $Lang) {
    $uk = $l -eq 'uk'
    $dir = if ($uk) { Join-Path $root 'docs\images\uk' } else { Join-Path $root 'docs\images' }
    function T([string]$ukText, [string]$enText) { if ($uk) { $ukText } else { $enText } }

    # ---------- Шапка / превʼю посилання (1280×640) ----------
    $c = New-Canvas 1280 640; $g = $c.G
    $shot = [Drawing.Image]::FromFile((Join-Path $dir 'debloat.png'))
    $sw = 760; $sh = [int]($shot.Height * $sw / $shot.Width)
    $g.DrawImage($shot, 600, 90, $sw, $sh); $shot.Dispose()
    Logo $g 64 70 96
    Text $g 'Debora' (Font 60 -Bold) $white 176 82
    Text $g (T "Деблоат і налаштування`nWindows 11 і 10" "Windows 11 & 10`ndebloater and setup tool") (Font 34 -Bold) $white 64 210 520 120
    Text $g (T "Реклама, телеметрія й зайві застосунки`nВимкнути Copilot і Recall`nНалаштування не злітають після оновлень`nБудь-яку зміну можна відкотити" "Remove bloatware, ads and telemetry`nTurn off Copilot and Recall`nKeep settings after Windows updates`nUndo any change") (Font $(if ($uk) { 23 } else { 25 })) $grey 64 350 520 170
    Text $g (T 'github.com/okalinon/debora  ·  безкоштовно, відкритий код' 'github.com/okalinon/debora  ·  free & open source') (Font 25) $white 64 560
    Save-Canvas $c (Join-Path $dir 'social-preview.png')

    # ---------- Три рівні деблоату (1280×640) ----------
    $c = New-Canvas 1280 680; $g = $c.G
    Text $g (T 'Три рівні деблоату — ви обираєте, як далеко йти' 'Three debloat levels — you choose how far to go') (Font 36 -Bold) $white 64 44
    Text $g (T 'Рівні накопичуються. У кожному рядку написано, що перестане працювати.' 'Levels add up. Every row tells you what stops working.') (Font 22) $grey 64 96
    $cols = @(
        @{ Color = $accent.green; Name = (T 'Обережно' 'Careful'); Count = $nSafe; Sub = (T 'реклама, телеметрія, застаріле' 'ads, telemetry, obsolete apps')
           Items = (T "Candy Crush, TikTok та інші промо-застосунки`nРеклама й поради в «Пуску», Параметрах, Edge`nТелеметрія й діагностичні дані`nCortana, Skype, Paint 3D, 3D Viewer" "Candy Crush, TikTok and other promo apps`nAds and tips in Start, Settings and Edge`nTelemetry and diagnostic data`nCortana, Skype, Paint 3D, 3D Viewer")
           Foot = (T 'Нічого потрібного не зникає' 'Nothing you use stops working') }
        @{ Color = $accent.blue; Name = (T 'Рекомендовано' 'Recommended'); Count = $nRec; Sub = (T '+ ШІ й рідко потрібні застосунки' '+ AI and rarely used Microsoft apps')
           Items = (T "Copilot, Recall, Click to Do`nШІ в Paint, Блокноті й Edge`nПогода, Clipchamp, Карти, To Do`n«Рекомендоване» в «Пуску», веб-пошук" "Copilot, Recall, Click to Do`nAI in Paint, Notepad and Edge`nWeather, Clipchamp, Maps, To Do`nRecommended in Start, web search")
           Foot = (T 'Кожна втрата підписана' 'Each loss is spelled out') }
        @{ Color = $accent.orange; Name = (T 'Максимально' 'Maximum'); Count = $nMax; Sub = (T '+ Xbox, OneDrive, віджети' '+ Xbox, OneDrive, Widgets')
           Items = (T "Xbox, Game Bar і служби Xbox`nOneDrive`nВіджети, Медіаплеєр, Нотатки`nРозташування, «Знайти пристрій»" "Xbox app, Game Bar and Xbox services`nOneDrive`nWidgets, Media Player, Sticky Notes`nLocation, Find my device")
           Foot = (T 'Для ПК, яким це не потрібно' "For PCs that don't need them") }
    )
    for ($i = 0; $i -lt 3; $i++) {
        $col = $cols[$i]; $x = 64 + $i * 392; $y = 150; $w = 368; $h = 440
        RoundRect $g $card $x $y $w $h
        $g.FillRectangle((New-Object Drawing.SolidBrush $col.Color), $x + 28, $y + 30, 44, 6)
        Text $g $col.Name (Font 30 -Bold) (New-Object Drawing.SolidBrush $col.Color) ($x + 24) ($y + 46)
        Text $g (T "до $($col.Count) змін" "up to $($col.Count) changes") (Font 20) $white ($x + 28) ($y + 92)
        Text $g $col.Sub (Font 19) $grey ($x + 28) ($y + 120) ($w - 50) 30
        $yy = $y + 166
        foreach ($line in ($col.Items -split "`n")) {
            $g.FillEllipse((New-Object Drawing.SolidBrush $col.Color), $x + 30, $yy + 10, 7, 7)
            $f = Font 19
            Text $g $line $f $white ($x + 46) $yy ($w - 70) 60
            $yy += $g.MeasureString($line, $f, [int]($w - 70)).Height + 10
        }
        Text $g $col.Foot (Font 18) $grey ($x + 28) ($y + $h - 48) ($w - 50) 30
    }
    Text $g (T 'Спершу — точка відновлення  ·  кожну зміну можна відкотити  ·  показано лише те, що є на вашому ПК' 'Restore point first  ·  every change can be undone  ·  only what exists on your PC is shown') (Font 19) $grey 64 620
    Save-Canvas $c (Join-Path $dir 'levels.png')

    # ---------- Як це працює (1280×420) ----------
    $c = New-Canvas 1280 420; $g = $c.G
    Text $g (T 'Як це працює' 'How it works') (Font 36 -Bold) $white 64 40
    $steps = @(
        @{ Color = $accent.blue; Title = (T 'Сканування' 'Scan'); Text = (T "$nChecks перевірок: безпека, оновлення, диск, приватність, стабільність, батарея" "$nChecks checks: security, updates, disk, privacy, stability, battery") }
        @{ Color = $accent.green; Title = (T 'Виправлення' 'Fix'); Text = (T 'Кнопка в кожній знахідці або «Сканувати й виправити все». Спершу — точка відновлення' 'A button on every finding, or “Scan and fix everything”. Restore point first') }
        @{ Color = $accent.orange; Title = (T 'Нагляд' 'Guard'); Text = (T 'Після оновлень Windows Debora помічає, що Windows повернула, і пропонує прибрати знову' 'After Windows updates Debora spots what Windows brought back and offers to restore your choice') }
        @{ Color = $accent.purple; Title = (T 'Відкат' 'Undo'); Text = (T 'Кожна зміна записана зі станом «до». Будь-яку сесію можна точно скасувати' 'Every change is journaled with its previous state. Undo any session exactly') }
    )
    for ($i = 0; $i -lt 4; $i++) {
        $s = $steps[$i]; $x = 64 + $i * 294; $y = 120; $w = 270; $h = 250
        RoundRect $g $card $x $y $w $h
        $g.FillEllipse((New-Object Drawing.SolidBrush $s.Color), $x + 24, $y + 26, 48, 48)
        $num = "$($i + 1)"; $nf = Font 26 -Bold; $sz = $g.MeasureString($num, $nf)
        Text $g $num $nf (New-Object Drawing.SolidBrush $bg) ($x + 48 - $sz.Width / 2) ($y + 50 - $sz.Height / 2)
        Text $g $s.Title (Font 26 -Bold) $white ($x + 86) ($y + 32)
        Text $g $s.Text (Font 19) $grey ($x + 24) ($y + 96) ($w - 44) 140
        if ($i -lt 3) {
            $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(99, 99, 102)), 3
            $ax = $x + $w + 4; $ay = $y + $h / 2
            $g.DrawLine($pen, $ax, $ay, $ax + 14, $ay); $g.DrawLine($pen, $ax + 8, $ay - 6, $ax + 14, $ay); $g.DrawLine($pen, $ax + 8, $ay + 6, $ax + 14, $ay)
        }
    }
    Save-Canvas $c (Join-Path $dir 'how-it-works.png')
}
