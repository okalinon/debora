# How to disable Copilot and Recall in Windows 11

*Applies to Windows 11 23H2, 24H2 and 25H2. [Українською](uk/disable-copilot-windows-11.md)*

Copilot in Windows 11 is a separate app (Microsoft.Copilot) plus a taskbar button and, on some versions, a sidebar.
Recall and Click to Do exist only on Copilot+ PCs. You can turn all of them off and turn them back on later.

## Quick answer

1. Uninstall the Copilot app: **Settings → Apps → Installed apps → Copilot → Uninstall**.
2. Hide the button: **Settings → Personalization → Taskbar → Copilot** (off), if your version still shows it.
3. Block it with policy so updates do not bring it back (Pro/Enterprise: Group Policy; any edition: registry below).
4. On Copilot+ PCs: **Settings → Privacy & security → Recall & snapshots** → turn off *Save snapshots*.

## Manual steps (registry, any edition)

Run in an elevated PowerShell:

```powershell
# Turn off Windows Copilot (policy, current user and all users)
New-Item 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1 -Type DWord
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1 -Type DWord
# Hide the taskbar button
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ShowCopilotButton 0 -Type DWord
# Recall: do not save snapshots (Copilot+ PCs)
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' DisableAIDataAnalysis 1 -Type DWord
# Remove the Copilot app for the current user
Get-AppxPackage *Microsoft.Copilot* | Remove-AppxPackage
```

Write down the previous values first if you want to undo this later — or use Debora, which does that for you.

## With Debora

1. Download [Debora](https://github.com/okalinon/debora/releases/latest), run **Debora.exe**.
2. **Debloat** tab → **Recommended** level. The *Copilot and AI* section includes the Copilot app, the policy,
   Recall, Click to Do, AI in Paint and Notepad, the Copilot button in Edge and *Ask Copilot* in the context menu.
   Each row says what will stop working.
3. **Apply selected.** A restore point is created first; *Change history* undoes everything exactly.

Command line: `Debora.exe -Debloat -Level Recommended`.

## Why Copilot comes back

Feature updates can reinstall the app and reset settings. Debora checks after every Windows update and offers to
restore what you turned off — see [Keep your settings after Windows updates](windows-updates-reset-settings.md).
