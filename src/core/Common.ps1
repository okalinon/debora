# Спільні допоміжні функції: журнал повідомлень, локалізація, порівняння станів.

$script:D9Language = 'uk'
$script:D9LogPath  = $null
$script:D9OnLog      = $null   # scriptblock для інтерфейсу: { param($Message, $Level) }
$script:D9OnProgress = $null   # scriptblock для інтерфейсу: { param($Done, $Total, $Name) }

function Write-D9Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Detail')][string]$Level = 'Info'
    )
    # Файл — першим, щоб у нього потрапляли й повідомлення фонових завдань вікна (там $D9OnLog)
    if ($script:D9LogPath) {
        try { Add-Content -Path $script:D9LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message) -Encoding UTF8 -ErrorAction Stop }
        catch { }   # файл зайнятий іншим потоком — рядок пропускаємо, а не ламаємо операцію
    }
    if ($script:D9OnLog) { & $script:D9OnLog $Message $Level; return }
    $color = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red'; Detail = 'DarkGray' }[$Level]
    Write-Host $Message -ForegroundColor $color
}

# Постійний журнал виконання: %ProgramData%\Debloater9\logs\РРРР-ММ.log (або -LogPath).
# Якщо писати нікуди (немає прав на файл, створений адміністратором) — працюємо без файлу.
function Initialize-D9LogFile {
    param([string]$Path, [string]$Mode)
    if (-not $Path) { $Path = Join-Path (Join-Path (Get-D9DataRoot) 'logs') ('{0:yyyy-MM}.log' -f (Get-Date)) }
    try {
        $dir = Split-Path $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $who = if (Test-D9IsAdmin) { 'адміністратор' } else { 'без прав адміністратора' }
        Add-Content -Path $Path -Value ("`r`n{0:yyyy-MM-dd HH:mm:ss} ===== Debloater9 {1}, режим {2}, {3} =====" -f (Get-Date), $script:D9Version, $Mode, $who) -Encoding UTF8 -ErrorAction Stop
        $script:D9LogPath = $Path
    } catch { $script:D9LogPath = $null }
}

# Повертає текст потрібною мовою з об'єкта виду { "uk": "...", "en": "..." }
function Get-D9Text {
    param($Text)
    if ($null -eq $Text) { return '' }
    if ($Text -is [string]) { return $Text }
    $value = $Text.$script:D9Language
    if (-not $value) { $value = $Text.en }
    if (-not $value) { $value = $Text.uk }
    return [string]$value
}

# Нормалізує стан через JSON, щоб стан "з пам'яті" і стан "з файлу журналу" порівнювались однаково
function ConvertTo-D9StateJson {
    param($State)
    if ($null -eq $State) { return 'null' }
    $json = ConvertTo-Json -InputObject $State -Depth 8 -Compress
    return (ConvertTo-Json -InputObject (ConvertFrom-Json $json) -Depth 8 -Compress)
}

function Test-D9StateEqual {
    param($Left, $Right)
    return (ConvertTo-D9StateJson $Left) -ceq (ConvertTo-D9StateJson $Right)
}

# Растрові шрифти консолі не мають кирилиці (замість літер — «?»): перемикаємо на Consolas
function Initialize-D9Console {
    if ($Host.Name -ne 'ConsoleHost') { return }
    try {
        if (-not ('D9ConsoleFont' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class D9ConsoleFont {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct FontInfo {
        public uint cbSize; public uint nFont; public short X; public short Y;
        public int FontFamily; public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
    }
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool GetCurrentConsoleFontEx(IntPtr h, bool max, ref FontInfo f);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref FontInfo f);
    public static bool EnsureTrueType(string face, short height) {
        var h = GetStdHandle(-11);
        var f = new FontInfo(); f.cbSize = (uint)Marshal.SizeOf(f);
        if (!GetCurrentConsoleFontEx(h, false, ref f)) return false;
        if ((f.FontFamily & 4) != 0) return false;   // TMPF_TRUETYPE — уже TrueType
        f.FaceName = face; f.FontFamily = 54; f.FontWeight = 400; f.X = 0; f.Y = height;
        return SetCurrentConsoleFontEx(h, false, ref f);
    }
}
'@
        }
        [void][D9ConsoleFont]::EnsureTrueType('Consolas', 18)
    } catch { }
}

function Test-D9IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
