# Вибір профілю під залізо (правила — у docs/06-catalog.md, розділ «Профілі»).

function Get-D9RecommendedPreset {
    param([Parameter(Mandatory)]$SystemInfo)
    $reasons = @()
    if ($SystemInfo.SystemDisk -eq 'hdd') { $reasons += (T-D9 'системний диск — HDD') }
    if ($SystemInfo.RamGB -le 4.5)        { $reasons += (T-D9 'мало пам''яті ({0} ГБ)' "$($SystemInfo.RamGB)") }
    if ($SystemInfo.Cores -le 2)          { $reasons += (T-D9 'слабкий процесор ({0} ядра)' "$($SystemInfo.Cores)") }
    if ($reasons) {
        return [pscustomobject]@{ Preset = 'WeakPC'; Reasons = $reasons }
    }
    if (@('ssd', 'nvme') -contains $SystemInfo.SystemDisk -and $SystemInfo.RamGB -ge 7.5) {
        return [pscustomobject]@{ Preset = 'Standard'; Reasons = @(T-D9 'SSD і {0} ГБ RAM' "$($SystemInfo.RamGB)") }
    }
    return [pscustomobject]@{ Preset = 'Minimal'; Reasons = @(T-D9 'залізо не вдалося точно визначити — лише безпечні зміни') }
}
