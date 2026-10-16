# How to turn off telemetry and ads in Windows 11 and 10

*[Українською](uk/disable-telemetry-windows-11.md)*

Windows sends diagnostic data to Microsoft and shows "suggestions" (ads) in Start, Settings, the lock screen and
File Explorer. You can reduce both a lot. One honest limit: on **Home and Pro** the lowest telemetry level is
*Required diagnostic data*; the *Off/Security* level works only on Enterprise and Education.

## Quick answer

1. **Settings → Privacy & security → Diagnostics & feedback**: turn off *Optional diagnostic data*,
   *Tailored experiences*, set *Feedback frequency* to *Never*.
2. **Settings → Privacy & security → General**: turn off all four options (advertising ID, tracking app launches,
   suggested content in Settings).
3. **Settings → Personalization → Start**: turn off *Show recommendations for tips, shortcuts, new apps*.
4. **Settings → Personalization → Lock screen**: turn off *Get fun facts, tips, tricks*.

## Manual steps (elevated PowerShell)

```powershell
# Lowest telemetry level allowed by your edition
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' AllowTelemetry 0 -Type DWord
# Connected User Experiences and Telemetry service
Set-Service DiagTrack -StartupType Disabled; Stop-Service DiagTrack
# Advertising ID and tailored experiences
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' Enabled 0 -Type DWord
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' TailoredExperiencesWithDiagnosticDataEnabled 0 -Type DWord
# Bing web results in Start search
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' DisableWebSearch 1 -Type DWord
```

## With Debora

The **Debloat** tab groups these as *Ads, tips and nagging*, *Telemetry and tracking* and *Start, taskbar and
File Explorer*: telemetry policy and service, telemetry scheduled tasks, CEIP, error reporting, advertising ID,
ads in Start, Settings, lock screen and File Explorer, Bing in search, Edge ads and nags, app permissions
(contacts, calendar, messages), activity history and more.

*Careful* turns off ads and telemetry without losing features; *Recommended* and *Maximum* add items that change how
Windows works, and each says what will stop working. Everything is undoable from *Change history*.

The **Overview** scan also checks privacy settings and offers a **Fix** button for each finding.
