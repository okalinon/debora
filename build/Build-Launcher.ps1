<#
.SYNOPSIS
    Компілює Debora.exe (build\Launcher.cs) компілятором C# з .NET Framework: значок build\debora.ico,
    маніфест із запитом прав адміністратора, версія з -Version. Викликає build\Compile.ps1.
#>
param([Parameter(Mandatory)][string]$OutFile, [string]$Version = '0.0.0')
$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Launcher.cs'), [Text.Encoding]::UTF8)
$num = if ($Version -match '^(\d+)\.(\d+)\.(\d+)') { "$($Matches[1]).$($Matches[2]).$($Matches[3]).0" } else { '0.0.0.0' }
$src = $src.Replace('%VERSION%', $num).Replace('%INFOVERSION%', $Version)
$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.GenerateExecutable = $true
$cp.OutputAssembly = $OutFile
[void]$cp.ReferencedAssemblies.Add('System.dll')
$manifest = Join-Path $PSScriptRoot 'Launcher.manifest'
$icon = Join-Path $PSScriptRoot 'debora.ico'
$cp.CompilerOptions = "/target:winexe /optimize+ /platform:anycpu /win32manifest:`"$manifest`" /win32icon:`"$icon`""
$r = $provider.CompileAssemblyFromSource($cp, $src)
if ($r.Errors.HasErrors) { throw "Debora.exe не скомпільовано: " + (($r.Errors | Where-Object { -not $_.IsWarning } | ForEach-Object { "$($_.Line): $($_.ErrorText)" }) -join '; ') }
$OutFile
