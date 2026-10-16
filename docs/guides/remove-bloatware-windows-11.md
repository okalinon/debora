# How to remove bloatware from Windows 11 and 10

*[Українською](uk/remove-bloatware-windows-11.md)*

"Bloatware" on a new Windows PC is mostly pre-installed apps (Candy Crush, TikTok, Spotify, Clipchamp, Xbox apps,
Bing News and Weather), suggested apps that Windows installs by itself, and ads in Start, Settings and the lock
screen. Removing them is safe as long as you keep system components.

## Quick answer

- One app: **Settings → Apps → Installed apps → … → Uninstall**.
- Stop Windows from installing "suggested" apps again: turn off *Show suggestions* in **Settings → Personalization →
  Start**, and disable consumer features (registry below).
- Do not remove: Microsoft Store, App Installer (winget), Windows Security, Photos, Calculator, Terminal — other
  things depend on them.

## Manual steps (PowerShell)

```powershell
# Remove an app for the current user (example: Clipchamp)
Get-AppxPackage *Clipchamp* | Remove-AppxPackage
# Remove it for every user and for new accounts (elevated PowerShell)
Get-AppxPackage -AllUsers *Clipchamp* | Remove-AppxPackage -AllUsers
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like '*Clipchamp*' | Remove-AppxProvisionedPackage -Online
# Block automatic installation of suggested apps
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' DisableWindowsConsumerFeatures 1 -Type DWord
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' SilentInstalledAppsEnabled 0 -Type DWord
```

Removed Store apps can be installed again from the Microsoft Store.

## With Debora

The **Debloat** tab lists only the built-in apps that are actually on your PC, grouped as *Ads and pushed games*,
*Rarely needed Microsoft apps*, *AI and cloud services*, *Xbox* and *Useful, but not for everyone*.

- **Careful** — ads, games and obsolete apps (Candy Crush, Spotify promo, Paint 3D, Skype, Cortana…).
- **Recommended** — plus Clipchamp, Teams, the new Outlook, Phone Link and other Microsoft apps most people never open.
- **Maximum** — plus Xbox and Game Bar, widgets and small useful apps (Alarms, Sticky Notes, Quick Assist).

Every row shows what will stop working (for example, *Xbox Game Bar: game clips, screenshots, FPS counter*).
Apps are removed for all users and for new accounts, and each one can be restored from *Change history*.
Programs that are not Store apps (trial antivirus, OEM tools) are under **Uninstall**, with leftover cleanup.

Command line: `Debora.exe -Debloat -Level Safe -WhatIf` shows the list without changing anything.
