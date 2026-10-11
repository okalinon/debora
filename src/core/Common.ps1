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
        # Спільний доступ (інший потік, антивірус, програма перегляду журналу) і кілька спроб — щоб рядки
        # не губились мовчки; якщо файл так і не відкрився, пропускаємо рядок, а не ламаємо операцію
        $bytes = [Text.Encoding]::UTF8.GetBytes(("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}`r`n" -f (Get-Date), $Level, $Message))
        for ($try = 0; $try -lt 5; $try++) {
            try {
                $fs = [IO.File]::Open($script:D9LogPath, 'Append', 'Write', 'ReadWrite, Delete')
                try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
                break
            } catch [UnauthorizedAccessException] { break }
            catch { Start-Sleep -Milliseconds (20 * ($try + 1)) }
        }
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
        Add-Content -Path $Path -Value ("`r`n{0:yyyy-MM-dd HH:mm:ss} ===== Debora {1}, режим {2}, {3} =====" -f (Get-Date), $script:D9Version, $Mode, $who) -Encoding UTF8 -ErrorAction Stop
        $script:D9LogPath = $Path
    } catch { $script:D9LogPath = $null }
}

# ---------- Мова інтерфейсу ----------
# Тексти в коді пишуться українською й обгортаються T-D9: (T-D9 <шаблон з {0}> $n). Ключ словника — сам український
# шаблон; переклади — у config/lang-<мова>-*.json ({ "strings": { "uk": "переклад" } }). Немає перекладу — лишається українська.
$script:D9LangTable = $null

function Get-D9LangTable {
    if ($null -ne $script:D9LangTable) { return , $script:D9LangTable }
    # Чутливий до регістру: «Встановлено» (заголовок) і «встановлено» (стан) — різні рядки
    $table = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    if ($script:D9Language -and $script:D9Language -ne 'uk') {
        $names = if ($script:D9Embedded) { @($script:D9Embedded.Keys | Where-Object { $_ -like "lang-$($script:D9Language)-*.json" }) }
                 elseif ($script:D9ConfigDir) { @(Get-ChildItem $script:D9ConfigDir -Filter "lang-$($script:D9Language)-*.json" -ErrorAction SilentlyContinue | ForEach-Object Name) }
                 else { @() }
        # ConvertFrom-Json у PowerShell 5 не приймає ключів, що відрізняються лише регістром, — тому JavaScriptSerializer
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = 64MB
        foreach ($n in $names | Sort-Object) {
            $json = $serializer.DeserializeObject((Get-D9ConfigText $n))
            foreach ($kv in $json['strings'].GetEnumerator()) { if ($kv.Value) { $table[$kv.Key] = [string]$kv.Value } }
        }
    }
    $script:D9LangTable = $table
    return , $table
}

# Переклад шаблону й підстановка {0}, {1}… (фігурні дужки в самому тексті — {{ і }})
function T-D9 {
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text, [Parameter(Position = 1, ValueFromRemainingArguments)][object[]]$Values)
    $s = $Text
    if ($script:D9Language -ne 'uk') { $tr = $null; if ((Get-D9LangTable).TryGetValue($Text, [ref]$tr) -and $tr) { $s = $tr } }
    if ($PSBoundParameters.ContainsKey('Values')) { $s = $s -f $Values }   # навіть коли значення — 0 або порожній рядок
    return $s
}

# Мова: явно (uk|en) → збережений вибір користувача → мова Windows (uk/ru/be — українська, інакше англійська)
function Resolve-D9Language {
    param([string]$Requested = 'auto')
    if ($Requested -in 'uk', 'en') { return $Requested }
    $saved = (Get-ItemProperty 'HKCU:\Software\Debora' -Name Language -ErrorAction SilentlyContinue).Language
    if ($saved -in 'uk', 'en') { return $saved }
    # Українська, якщо вона мова Windows, регіональних форматів або є серед мов введення (часто Windows англійська, а людина — з України)
    $codes = @([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName, [Globalization.CultureInfo]::CurrentCulture.TwoLetterISOLanguageName)
    if ($codes | Where-Object { $_ -in 'uk', 'ru', 'be' }) { return 'uk' }
    $langs = try { @(Get-WinUserLanguageList -ErrorAction Stop | ForEach-Object LanguageTag) } catch { @() }
    if ($langs | Where-Object { $_ -match '^(uk|ru|be)(-|$)' }) { return 'uk' }
    return 'en'
}

function Set-D9Language {
    param([Parameter(Mandatory)][ValidateSet('uk', 'en')][string]$Language, [switch]$Save)
    $script:D9Language = $Language
    $script:D9LangTable = $null
    if ($Save) {
        if (-not (Test-Path 'HKCU:\Software\Debora')) { New-Item -Path 'HKCU:\Software\Debora' -Force | Out-Null }
        Set-ItemProperty 'HKCU:\Software\Debora' -Name Language -Value $Language
    }
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
# Add-Type -TypeDefinition викликає компілятор C# при кожному запуску (~0,3–0,5 с на клас). Компілюємо один раз
# у DLL у %LOCALAPPDATA%\Debora\types (у назві — хеш коду, тож зміна коду дає нову DLL) і далі лише завантажуємо.
# Якщо кеш недоступний — звичайна компіляція в пам'яті.
function Add-D9CachedType {
    param([Parameter(Mandatory)][string]$TypeName, [Parameter(Mandatory)][string]$Source, [string[]]$References)
    if ($TypeName -as [type]) { return }
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Source|$($References -join ',')|$($PSVersionTable.CLRVersion)"))) -replace '-', '').Substring(0, 16)
        $dir = Join-Path $env:LOCALAPPDATA 'Debora\types'
        $dll = Join-Path $dir "$TypeName-$hash.dll"
        if (-not (Test-Path -LiteralPath $dll)) {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $p = @{ TypeDefinition = $Source; OutputAssembly = $dll; ErrorAction = 'Stop' }
            if ($References) { $p.ReferencedAssemblies = $References }
            Add-Type @p
        }
        Add-Type -LiteralPath $dll -ErrorAction Stop
        if ($TypeName -as [type]) { return }
    } catch { }
    $p = @{ TypeDefinition = $Source }
    if ($References) { $p.ReferencedAssemblies = $References }
    Add-Type @p
}

function Initialize-D9Console {
    if ($Host.Name -ne 'ConsoleHost') { return }
    try {
        Add-D9CachedType 'D9ConsoleFont' @'
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
        [void][D9ConsoleFont]::EnsureTrueType('Consolas', 18)
    } catch { }
}

function Test-D9IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
