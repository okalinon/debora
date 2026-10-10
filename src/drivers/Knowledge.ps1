# База знань про пристрої: що це за пристрій (за Hardware ID) і де взяти драйвер.

$script:D9KnowledgeDir = $null
$script:D9IdTables = $null
$script:D9DriverSources = $null

# Текст бази: у зібраному файлі — стиснений gzip+base64 у $script:D9Embedded['<name>.gz'], у розробці — файл у knowledge/
function Get-D9KnowledgeText {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:D9Embedded -and $script:D9Embedded.ContainsKey("$Name.gz")) {
        $bytes = [Convert]::FromBase64String(($script:D9Embedded["$Name.gz"] -replace '\s', ''))
        $in = New-Object IO.MemoryStream (, $bytes)
        $gz = New-Object IO.Compression.GZipStream $in, ([IO.Compression.CompressionMode]::Decompress)
        $reader = New-Object IO.StreamReader $gz, ([Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    $path = Join-Path $script:D9KnowledgeDir $Name
    if (Test-Path $path) { return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
    return ''
}

# Формат pci.ids / usb.ids: «vvvv  Виробник», «<TAB>dddd  Пристрій»; підсистеми й класи пропускаємо
function ConvertFrom-D9IdsText {
    param([string]$Text, [hashtable]$Table, [string]$Prefix)
    $vendor = $null
    foreach ($line in $Text -split "`n") {
        if ($line.Length -lt 6 -or $line[0] -eq '#') { continue }
        if ($line.StartsWith('C ')) { break }                      # далі — таблиця класів
        if ($line[0] -ne "`t") {
            $vendor = $line.Substring(0, 4).ToUpper()
            $Table["$Prefix$vendor"] = $line.Substring(6).Trim()
        } elseif ($line[1] -ne "`t" -and $vendor) {
            $Table["$Prefix${vendor}:$($line.Substring(1, 4).ToUpper())"] = $line.Substring(7).Trim()
        }
    }
}

function Get-D9IdTables {
    if (-not $script:D9IdTables) {
        $t = @{}
        ConvertFrom-D9IdsText (Get-D9KnowledgeText 'pci.ids') $t 'PCI:'
        ConvertFrom-D9IdsText (Get-D9KnowledgeText 'usb.ids') $t 'USB:'
        $script:D9IdTables = $t
    }
    return $script:D9IdTables
}

function Get-D9DriverSources {
    if (-not $script:D9DriverSources) { $script:D9DriverSources = ConvertFrom-Json (Get-D9ConfigText 'driver-sources.json') }
    return $script:D9DriverSources
}

# Розбір Hardware ID → шина, виробник, пристрій і людська назва
function Resolve-D9Device {
    param([string[]]$HardwareIds)
    $ids = Get-D9IdTables
    $src = Get-D9DriverSources
    foreach ($hwid in @($HardwareIds | Where-Object { $_ })) {
        $u = $hwid.ToUpper()
        if ($u -match '^PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') {
            $v = $Matches[1]; $d = $Matches[2]
            return [pscustomobject]@{ Bus = 'PCI'; VendorId = $v; DeviceId = $d; Vendor = $ids["PCI:$v"]; Name = $ids["PCI:${v}:$d"]; HardwareId = $hwid }
        }
        if ($u -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
            $v = $Matches[1]; $d = $Matches[2]
            return [pscustomobject]@{ Bus = 'USB'; VendorId = $v; DeviceId = $d; Vendor = $ids["USB:$v"]; Name = $ids["USB:${v}:$d"]; HardwareId = $hwid }
        }
        if ($u -match '^(HDAUDIO|INTELAUDIO)\\FUNC_\d+&VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') {
            $v = $Matches[2]; $d = $Matches[3]
            $vendor = $ids["PCI:$v"]
            $name = if ($v -eq '10EC') { "Realtek ALC$($d.TrimStart('0')) (аудіокодек)" } else { "аудіокодек $vendor $d" }
            return [pscustomobject]@{ Bus = 'HDAUDIO'; VendorId = $v; DeviceId = $d; Vendor = $vendor; Name = $name; HardwareId = $hwid }
        }
        if ($u -match '^ACPI\\([A-Z]{2,4}?)([0-9A-F]{4})$' -or $u -match '^ACPI\\([A-Z]{3,4})([0-9A-F]{4})') {
            $prefix = $Matches[1]
            $vendor = $src.acpiVendors.$prefix
            if (-not $vendor) { $vendor = $src.acpiVendors.($prefix.Substring(0, 3)) }
            return [pscustomobject]@{ Bus = 'ACPI'; VendorId = $prefix; DeviceId = $Matches[2]; Vendor = $vendor; Name = $(if ($vendor) { "пристрій $vendor ($($hwid.Split('\')[1]))" }); HardwareId = $hwid }
        }
    }
    return [pscustomobject]@{ Bus = $null; VendorId = $null; DeviceId = $null; Vendor = $null; Name = $null; HardwareId = (@($HardwareIds) | Select-Object -First 1) }
}

function Get-D9DeviceDisplayName {
    param($Info, [string]$WindowsName)
    if ($Info.Name -and $Info.Vendor -and $Info.Name -notlike "*$($Info.Vendor.Split(' ')[0])*") { return "$($Info.Vendor) $($Info.Name)" }
    if ($Info.Name) { return $Info.Name }
    if ($Info.Vendor) { return "пристрій $($Info.Vendor)" }
    if ($WindowsName) { return $WindowsName }
    return 'Невідомий пристрій'
}

# Сторінка драйверів виробника ПК для цієї моделі
function Get-D9OemSupport {
    param($SystemInfo)
    $src = Get-D9DriverSources
    $rule = $src.oem | Where-Object { $SystemInfo.Manufacturer -match $_.match } | Select-Object -First 1
    if (-not $rule) { return $null }
    $serial = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
    $vars = @{ model = $SystemInfo.Model; modelUnderscore = ($SystemInfo.Model -replace '\s+', '_'); serial = "$serial".Trim() }
    $fill = { param($t) foreach ($k in $vars.Keys) { $t = $t.Replace("{$k}", [uri]::EscapeDataString([string]$vars[$k])) }; $t }
    $fillText = { param($t) foreach ($k in $vars.Keys) { $t = $t.Replace("{$k}", [string]$vars[$k]) }; $t }
    [pscustomobject]@{
        Name     = $rule.name
        Url      = & $fill $rule.url
        Fallback = $rule.fallback
        Note     = if ($rule.note) { & $fillText $rule.note } else { $null }
        Serial   = $vars.serial
    }
}

# Посилання «де взяти драйвер» для пристрою: виробник ПК → виробник чипа → Microsoft Update Catalog
function Get-D9DriverLinks {
    param($Info, $Oem)
    $links = @()
    $chip = if ($Info.VendorId) { (Get-D9DriverSources).chipVendors.($Info.VendorId) } else { $null }
    if ($Oem) {
        $label = "Драйвери $($Oem.Name) для цієї моделі"
        if ($Oem.Note) { $label += " ($($Oem.Note))" }
        $links += New-D9Link $label $Oem.Url
    }
    if ($chip -and $chip.url) {
        $label = "Сайт $($chip.name)"
        if ($chip.tool) { $label += " — $($chip.tool)" }
        $links += New-D9Link $label $chip.url
    }
    if ($Info.HardwareId) {
        $q = ($Info.HardwareId -split '&REV_|&SUBSYS_')[0]
        $links += New-D9Link 'Microsoft Update Catalog (пошук за ID пристрою)' ("https://www.catalog.update.microsoft.com/Search.aspx?q=" + [uri]::EscapeDataString($q))
    }
    return $links
}
