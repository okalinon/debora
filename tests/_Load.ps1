# Підвантажує модулі з src/ для тестів (так само, як Main.ps1 у режимі розробки).
$srcRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
foreach ($file in @('core\Common.ps1', 'core\Catalog.ps1', 'core\SystemInfo.ps1', 'core\Recommender.ps1', 'core\Journal.ps1', 'core\Engine.ps1')) {
    . (Join-Path $srcRoot $file)
}
foreach ($d9ModuleDir in 'actions', 'scan', 'drivers', 'maintenance', 'ui') {
    Get-ChildItem (Join-Path $srcRoot $d9ModuleDir) -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}
$script:D9UiDir = Join-Path $srcRoot 'ui'
$script:D9ConfigDir    = Join-Path (Split-Path $srcRoot -Parent) 'config'
$script:D9KnowledgeDir = Join-Path (Split-Path $srcRoot -Parent) 'knowledge'
$script:D9OnLog = { param($Message, $Level) }   # тиша в тестах

# Тестова «система» без звернень до заліза
function New-TestSystemInfo {
    param([string]$OsFamily = 'win11', [string]$SystemDisk = 'ssd', [double]$RamGB = 16, [int]$Cores = 8, [bool]$HasBattery = $false)
    [pscustomobject]@{
        OsName = 'Test'; OsFamily = $OsFamily; Build = $(if ($OsFamily -eq 'win11') { 26100 } else { 19045 }); DisplayVersion = 'test'
        Manufacturer = 'Test'; Model = 'Test'; Cpu = 'Test CPU'; Cores = $Cores; RamGB = $RamGB
        SystemDisk = $SystemDisk; HasBattery = $HasBattery; Firmware = 'UEFI'; PartitionStyle = 'GPT'
    }
}
