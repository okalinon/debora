<#
.SYNOPSIS
    Малює значок Debora (темний заокруглений квадрат із лінією пульсу, як логотип у вікні) і зберігає
    build\debora.ico з розмірами 16–256 (PNG усередині ICO — так підтримує Windows Vista і новіші).
    Запускати лише коли значок треба змінити; готовий debora.ico лежить у репозиторії.
#>
Add-Type -AssemblyName System.Drawing
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) {
    $bmp = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([Drawing.Color]::Transparent)
    $r = [math]::Max(3, [int]($s * 0.22))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $w = $s - 1
    $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $path.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $path.AddArc($w - $r * 2, $w - $r * 2, $r * 2, $r * 2, 0, 90); $path.AddArc(0, $w - $r * 2, $r * 2, $r * 2, 90, 90); $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 29, 29, 31))), $path)
    # Лінія пульсу
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 242, 242, 247)), ([math]::Max(1.4, $s * 0.075))
    $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $pts = @(@(0.18, 0.54), @(0.36, 0.54), @(0.45, 0.30), @(0.56, 0.74), @(0.64, 0.46), @(0.82, 0.46)) | ForEach-Object { New-Object Drawing.PointF ([float]($_[0] * $s)), ([float]($_[1] * $s)) }
    $g.DrawLines($pen, [Drawing.PointF[]]$pts)
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    if ($s -ge 256) {
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)   # 256 — PNG, як у значках Windows
    } else {
        # Менші — класичний DIB: BITMAPINFOHEADER (висота ×2), 32-бітні пікселі знизу вгору, 1-бітна маска
        $w = New-Object IO.BinaryWriter $ms
        $w.Write([uint32]40); $w.Write([int32]$s); $w.Write([int32]($s * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]0); $w.Write([uint32]0); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
        for ($y = $s - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $s; $x++) { $c = $bmp.GetPixel($x, $y); $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A) } }
        $maskRow = [int]([math]::Ceiling($s / 32) * 4)
        for ($y = 0; $y -lt $s; $y++) { $w.Write((New-Object byte[] $maskRow)) }
        $w.Flush()
    }
    $bmp.Dispose()
    , $ms.ToArray()
}
# ICO: заголовок, каталог (16 байтів на зображення), далі PNG
$out = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Flush()
$file = Join-Path $PSScriptRoot 'debora.ico'
[IO.File]::WriteAllBytes($file, $out.ToArray())
Write-Host "Значок: $file ($([int]($out.Length / 1KB)) КБ)"
