# Вибір профілю під залізо (правила — у docs/06-catalog.md, розділ «Профілі»).

function Get-D9RecommendedPreset {
    param([Parameter(Mandatory)]$SystemInfo)
    $reasons = @()
    if ($SystemInfo.SystemDisk -eq 'hdd') { $reasons += 'системний диск — HDD' }
    if ($SystemInfo.RamGB -le 4.5)        { $reasons += "мало пам'яті ($($SystemInfo.RamGB) ГБ)" }
    if ($SystemInfo.Cores -le 2)          { $reasons += "слабкий процесор ($($SystemInfo.Cores) ядра)" }
    if ($reasons) {
        return [pscustomobject]@{ Preset = 'WeakPC'; Reasons = $reasons }
    }
    if (@('ssd', 'nvme') -contains $SystemInfo.SystemDisk -and $SystemInfo.RamGB -ge 7.5) {
        return [pscustomobject]@{ Preset = 'Standard'; Reasons = @("SSD і $($SystemInfo.RamGB) ГБ RAM") }
    }
    return [pscustomobject]@{ Preset = 'Minimal'; Reasons = @('залізо не вдалося точно визначити — лише безпечні зміни') }
}
