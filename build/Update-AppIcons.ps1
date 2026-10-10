# Збирає іконки програм каталогу (config/apps.json) у knowledge/app-icons/<id>.png (64×64, PNG).
# Джерела по черзі: база іконок UniGetUI →
# іконка сайту (Google favicon, 128 px). Іконки, яких не вдалося знайти, у вікні замінює літера.
# Потрібен інтернет. Наявні файли не перезавантажуються (-Force — перезавантажити все).
# Без -Part скрипт сам запускає 6 паралельних частин (кожна — окремий процес) і чекає на них.
#   powershell -STA -File .\build\Update-AppIcons.ps1 [-Only Google.Chrome] [-Force]
param([string]$Only, [switch]$Force, [int]$Part = -1, [int]$Parts = 6)
if ($Part -lt 0 -and -not $Only) {
    $procs = for ($i = 0; $i -lt $Parts; $i++) {
        $a = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Part', $i, '-Parts', $Parts)
        if ($Force) { $a += '-Force' }
        Start-Process powershell.exe -ArgumentList $a -NoNewWindow -PassThru
    }
    $procs | Wait-Process
    $n = @(Get-ChildItem (Join-Path (Split-Path $PSScriptRoot -Parent) 'knowledge\app-icons') -Filter '*.png').Count
    Write-Host "Готово: іконок у knowledge\app-icons — $n"
    return
}
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, WindowsBase
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $root 'knowledge\app-icons'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$catalog = Get-Content (Join-Path $root 'config\apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$size = 64

Write-Host 'Завантаження бази іконок UniGetUI...'
$dbText = (Invoke-WebRequest 'https://raw.githubusercontent.com/marticliment/UniGetUI/main/WebBasedData/screenshot-database-v2.json' -UseBasicParsing).Content
if ($dbText -is [byte[]]) { $dbText = [Text.Encoding]::UTF8.GetString($dbText) }
# У базі є ключі, що відрізняються лише регістром (ConvertFrom-Json на них падає) — розбираємо регулярним виразом
$db = @{}
foreach ($m in [regex]::Matches($dbText, '"([^"]+)"\s*:\s*\{\s*"icon"\s*:\s*"([^"]*)"')) { $k = $m.Groups[1].Value.ToLower(); if ($m.Groups[2].Value -and -not $db.ContainsKey($k)) { $db[$k] = $m.Groups[2].Value } }
Write-Host "  іконок у базі: $($db.Count)"

# Завантаження з тайм-аутом 10 с і обмеженням 5 МБ (деякі сайти не відповідають або віддають величезні файли)
function Get-UrlBytes([string]$Url) {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 10000; $req.ReadWriteTimeout = 10000
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $resp = $req.GetResponse()
    try {
        $in = $resp.GetResponseStream(); $out = New-Object IO.MemoryStream
        $buf = New-Object byte[] 65536
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n); if ($out.Length -gt 5MB) { throw 'завеликий файл' } }
        , $out.ToArray()
    } finally { $resp.Close() }
}

# Ключі бази UniGetUI: останній сегмент ID, назва через дефіс тощо
function Get-IconKeys([object]$App) {
    $parts = $App.id -split '\.'
    $last = $parts[-1].ToLower()
    $name = ($App.name -replace '\s*\(.*?\)', '').Trim().ToLower()
    @(
        $last, ($last -replace '(desktop|install|client|app)$', ''), ($name -replace '[^a-z0-9]+', '-').Trim('-'), ($name -replace '[^a-z0-9]+', ''),
        ($App.id.ToLower() -replace '\.', '-'), (($parts | Select-Object -Last 2) -join '-').ToLower()
    ) | Where-Object { $_ } | Select-Object -Unique
}

# Байти зображення → PNG size×size (ICO — найбільший кадр; пропорції зберігаються, прозорі поля)
function Convert-IconBytes([byte[]]$Bytes) {
    $ms = New-Object IO.MemoryStream (, $Bytes)
    $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create($ms, [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $frame = $decoder.Frames | Sort-Object { $_.PixelWidth * $_.PixelHeight } -Descending | Select-Object -First 1
    if ($frame.PixelWidth -lt 24) { return $null }   # 16-піксельні фавікони після збільшення розмиті
    $scale = [math]::Min($size / $frame.PixelWidth, $size / $frame.PixelHeight)
    $w = $frame.PixelWidth * $scale; $h = $frame.PixelHeight * $scale
    $visual = New-Object Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($visual, 'HighQuality')
    $dc.DrawImage($frame, (New-Object Windows.Rect (($size - $w) / 2), (($size - $h) / 2), $w, $h))
    $dc.Close()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($visual)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $out = New-Object IO.MemoryStream
    $enc.Save($out)
    , $out.ToArray()
}

# Заглушки, які віддають деякі хостинги замість видаленого зображення (MD5 готового PNG)
$rejectHashes = @('2E946EB076A2D750EBD2990F5F44C7B6', 'C21D17FB86B1F57E8B5B2D5F7DC80745')

function Get-IconUrls([object]$App) {
    if ($App.icon) { [string]$App.icon }   # пряме посилання з каталогу (напр. іконка з репозиторію програми)
    foreach ($k in Get-IconKeys $App) { $u = $db[$k]; if ($u) { $u; break } }
    $hp = [string]$App.homepage
    if ($hp -match '^https?://([^/]+)') {
        $hostName = $Matches[1]
        if ($hostName -notmatch '(^|\.)(github\.com|gitlab\.com|sourceforge\.net|microsoft\.com|apps\.microsoft\.com|google\.com)$') { "https://www.google.com/s2/favicons?domain=$hostName&sz=128" }
    }
}

$ok = 0; $missing = @(); $index = -1
foreach ($app in $catalog.apps | Where-Object { -not $Only -or $_.id -like $Only }) {
    $index++
    if ($Part -ge 0 -and $index % $Parts -ne $Part) { continue }
    $file = Join-Path $outDir ($app.id + '.png')
    if ((Test-Path -LiteralPath $file) -and -not $Force) { $ok++; continue }
    $done = $false
    foreach ($url in @(Get-IconUrls $app)) {
        try {
            $png = Convert-IconBytes (Get-UrlBytes $url)
            if ($png) {
                $md5 = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash($png)) -replace '-', ''
                if ($rejectHashes -contains $md5) { continue }
                [IO.File]::WriteAllBytes($file, $png); $done = $true; break
            }
        } catch { if ($env:D9_ICON_DEBUG) { Write-Host "  $url : $($_.Exception.Message)" } }
    }
    if ($done) { $ok++; Write-Host "OK    $($app.id)" -ForegroundColor Green }
    else { $missing += $app.id; Write-Host "НЕМАЄ $($app.id)" -ForegroundColor Yellow }
}
Write-Host "Іконок: $ok з $(@($catalog.apps).Count). Без іконки (буде літера): $($missing -join ', ')"
