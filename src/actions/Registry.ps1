# Дія "registry": встановлення або видалення значення реєстру.
#   { "type": "registry", "path": "HKCU:\\...", "name": "Value", "value": 0, "kind": "DWord" }
#   { "type": "registry", "path": "HKCU:\\...", "name": "Value", "delete": true }
# Порожнє ім'я ("") — значення за замовчуванням ключа.
# Працюємо через .NET API з Registry64, щоб не залежати від перенаправлення WOW64.

$script:D9RegKinds = @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')

function ConvertTo-D9RegLocation {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^(HKLM|HKCU|HKCR|HKU):\\(.+)$') { throw (T-D9 'Некоректний шлях реєстру: {0}' "$Path") }
    $hive = @{ HKLM = 'LocalMachine'; HKCU = 'CurrentUser'; HKCR = 'ClassesRoot'; HKU = 'Users' }[$Matches[1]]
    [pscustomobject]@{
        Hive   = [Microsoft.Win32.RegistryHive]$hive
        Prefix = $Matches[1]
        SubKey = $Matches[2].TrimEnd('\')
    }
}

function Open-D9RegBase {
    param([Microsoft.Win32.RegistryHive]$Hive)
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function Get-D9RegValueName {
    param($Action)
    $name = [string]$Action.name
    if ($name -eq '(default)') { return '' }
    return $name
}

# Приводить значення до порівнюваного вигляду (DWORD без знаку, Binary як масив чисел)
function ConvertTo-D9RegNormalized {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'DWord'       { return [uint32]([int64]$Value -band 0xFFFFFFFFL) }
        'QWord'       { return [int64]$Value }
        'Binary'      { return ,([int[]]@($Value | ForEach-Object { [int]$_ })) }
        'MultiString' { return ,([string[]]@($Value)) }
        default       { return [string]$Value }
    }
}

function ConvertTo-D9RegWritable {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'DWord'       { return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]([int64]$Value -band 0xFFFFFFFFL)), 0) }
        'QWord'       { return [int64]$Value }
        # Кома не дає PowerShell розгорнути масив в object[] на виході з функції
        'Binary'      { return ,([byte[]]@($Value | ForEach-Object { [byte]$_ })) }
        'MultiString' { return ,([string[]]@($Value)) }
        default       { return [string]$Value }
    }
}

function Get-D9RegistryState {
    param([Parameter(Mandatory)]$Action)
    $loc  = ConvertTo-D9RegLocation $Action.path
    $name = Get-D9RegValueName $Action
    $base = Open-D9RegBase $loc.Hive
    try {
        $key = $base.OpenSubKey($loc.SubKey, $false)
        if (-not $key) {
            # Запам'ятовуємо перший відсутній ключ ланцюжка — його й видалимо під час відкату
            $parts = $loc.SubKey.Split('\')
            $missing = $loc.SubKey
            for ($i = 1; $i -le $parts.Count; $i++) {
                $partial = $parts[0..($i - 1)] -join '\'
                $probe = $base.OpenSubKey($partial, $false)
                if (-not $probe) { $missing = $partial; break }
                $probe.Dispose()
            }
            return [ordered]@{ keyExists = $false; exists = $false; firstMissing = "$($loc.Prefix):\$missing" }
        }
        try {
            if ($key.GetValueNames() -notcontains $name) {
                return [ordered]@{ keyExists = $true; exists = $false }
            }
            $kind  = [string]$key.GetValueKind($name)
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [ordered]@{ keyExists = $true; exists = $true; kind = $kind; value = (ConvertTo-D9RegNormalized $value $kind) }
        } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}

function Test-D9Registry {
    param([Parameter(Mandatory)]$Action)
    $state = Get-D9RegistryState $Action
    # ifKeyExists: дія має сенс лише коли ключ є (наприклад, служба SMB1 не встановлена — нічого не робимо)
    if ($Action.ifKeyExists -and -not $state.keyExists) { return $null }
    if ($Action.delete) { return -not $state.exists }
    if (-not $state.exists -or $state.kind -ne $Action.kind) { return $false }
    return Test-D9StateEqual $state.value (ConvertTo-D9RegNormalized $Action.value $Action.kind)
}

function Set-D9RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Kind)
    $loc  = ConvertTo-D9RegLocation $Path
    $base = Open-D9RegBase $loc.Hive
    try {
        $key = $base.CreateSubKey($loc.SubKey)
        if (-not $key) { throw (T-D9 'Не вдалося відкрити ключ для запису: {0}' "$Path") }
        try { $key.SetValue($Name, (ConvertTo-D9RegWritable $Value $Kind), [Microsoft.Win32.RegistryValueKind]$Kind) }
        catch [UnauthorizedAccessException] {
            # Ключ відкрився на запис, а значення — ні: це не права доступу, а захист Windows 11 (драйвер UCPD
            # блокує powershell.exe для віджетів, асоціацій файлів тощо). Обходити його не будемо
            throw (T-D9 'Windows не дозволяє програмам змінювати це налаштування ({0}) — змініть його вручну в «Параметрах».' "$Path\$Name")
        }
        catch [Management.Automation.MethodInvocationException] {
            if ($_.Exception.InnerException -is [UnauthorizedAccessException]) { throw (T-D9 'Windows не дозволяє програмам змінювати це налаштування ({0}) — змініть його вручну в «Параметрах».' "$Path\$Name") }
            throw
        }
        finally { $key.Dispose() }
    } finally { $base.Dispose() }
}

function Remove-D9RegValue {
    param([string]$Path, [string]$Name)
    $loc  = ConvertTo-D9RegLocation $Path
    $base = Open-D9RegBase $loc.Hive
    try {
        $key = $base.OpenSubKey($loc.SubKey, $true)
        if ($key) { try { $key.DeleteValue($Name, $false) } finally { $key.Dispose() } }
    } finally { $base.Dispose() }
}

# Видаляє порожні ключі від $Path вгору до $StopAt включно (лише ті, що ми створили)
function Remove-D9RegEmptyChain {
    param([string]$Path, [string]$StopAt)
    $loc  = ConvertTo-D9RegLocation $Path
    $stop = (ConvertTo-D9RegLocation $StopAt).SubKey
    $base = Open-D9RegBase $loc.Hive
    try {
        $current = $loc.SubKey
        while ($current.Length -ge $stop.Length) {
            $key = $base.OpenSubKey($current, $false)
            if (-not $key) { break }
            $empty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0)
            $key.Dispose()
            if (-not $empty) { break }
            $base.DeleteSubKey($current, $false)
            if ($current -eq $stop) { break }
            $current = $current.Substring(0, $current.LastIndexOf('\'))
        }
    } finally { $base.Dispose() }
}

function Invoke-D9Registry {
    param([Parameter(Mandatory)]$Action)
    $name = Get-D9RegValueName $Action
    if ($Action.delete) { Remove-D9RegValue $Action.path $name; return }
    if ($script:D9RegKinds -notcontains $Action.kind) { throw (T-D9 'Невідомий тип значення реєстру: {0}' "$($Action.kind)") }
    if ($Action.ifKeyExists -and -not (Get-D9RegistryState $Action).keyExists) { return }
    Set-D9RegValue $Action.path $name $Action.value $Action.kind
}

function Restore-D9Registry {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Before)
    $name = Get-D9RegValueName $Action
    if ($Before.exists) {
        Set-D9RegValue $Action.path $name $Before.value $Before.kind
        return
    }
    Remove-D9RegValue $Action.path $name
    if (-not $Before.keyExists -and $Before.firstMissing) {
        Remove-D9RegEmptyChain $Action.path $Before.firstMissing
    }
}

function Get-D9RegistryDescription {
    param([Parameter(Mandatory)]$Action, $State)
    $name = Get-D9RegValueName $Action
    $label = "$($Action.path)\$(if ($name) { $name } else { '(default)' })"
    $old = if ($State -and $State.exists) { (ConvertTo-D9StateJson $State.value) } else { (T-D9 '<немає>') }
    $new = if ($Action.delete) { (T-D9 '<видалити>') } else { ConvertTo-D9StateJson (ConvertTo-D9RegNormalized $Action.value $Action.kind) }
    return "$label : $old -> $new"
}
