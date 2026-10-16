# Debora

**Windows 10/11 debloat, setup from scratch and maintenance — with exact undo.**
[Українською](README.md) · [Changelog](CHANGELOG.md)

Debora checks your PC, explains what is wrong in plain language and fixes most of it itself. Every change is written
to a journal with the previous state, so any session can be undone exactly. The interface is in Ukrainian and English
(chosen automatically, switchable in Preferences).

## Download and run

1. Download `Debora-<version>.zip` from [Releases](../../releases) and extract the whole folder.
2. Double-click **Debora.exe** and allow administrator rights (without them Debora only shows the state of the PC).
3. Windows SmartScreen may say "Windows protected your PC" because the program is not signed yet:
   *More info → Run anyway*. File checksums are in `SHA256SUMS`.

Requirements: Windows 10 or 11 with Windows PowerShell 5.1 (built in). No installation; Debora updates itself from
GitHub Releases (checked once a day, every archive is verified by SHA-256).

## What it does

| Tab | |
|---|---|
| **Overview** | 185 checks (security, updates, disk, stability, privacy, performance, battery…) with a 0–100 score. Every finding has **Fix** or **How to fix**; "Scan and fix everything" does the safe steps in one go. Blue screen codes, crashing modules and slow boot are explained. |
| **Debloat** | Levels **Careful** (ads, telemetry, obsolete), **Recommended** (+ Copilot and AI, Microsoft apps most people don't use) and **Maximum** (+ Xbox, OneDrive, widgets). Every item says what will stop working. 59 built-in apps one by one, 74 settings, services, tasks and Windows components. |
| **Setup from scratch** | After a clean Windows install: drivers, debloat, settings, apps, Windows Update and scan-and-fix in one pass. Restarts when updates need it and continues after sign-in. The plan is a portable JSON profile. |
| **Settings** | Performance, File Explorer and security tweaks with a preview of every change. |
| **Drivers** | Every device with its driver; new drivers from the official Microsoft Update Catalog and Windows Update; install from a folder with backup. |
| **Programs / Uninstall** | 567 programs (winget and GitHub releases); uninstall with sizes and leftover cleanup. |
| **Startup, Maintenance** | Startup advice; disk (SMART) and battery health; cleanup, system file repair, network and Windows Update reset; weekly automatic maintenance. |
| **Reinstall** | A Windows USB that installs without questions, with this PC's drivers, and runs your Debora setup plan after the first sign-in. |
| **Change log** | Everything Debora changed; undo any session. |

After Windows updates, Debora notices what Windows brought back (Copilot, ads, apps, policies) and restores it in
one click — or automatically during weekly maintenance.

## Safety

- A system restore point before changes; every change in the journal with exact undo.
- Nothing is sent anywhere: Debora only downloads drivers, programs and its own updates from official sources.
- Problems: Change log → *Collect diagnostics* creates a zip to attach to an issue.

## Command line

`Debora.exe -Help` lists all commands, e.g. `-Scan`, `-Debloat -Level Safe|Recommended|Max -WhatIf`, `-Setup`,
`-Guard`, `-Update`, `-Drivers`, `-DriverUpdate`, `-Uninstall`, `-Maintain`, `-Diagnostics`. Details:
[docs/08-cli.md](docs/08-cli.md) (Ukrainian).

## Building from source

```powershell
.\build\Compile.ps1 -Version 1.0.0     # dist\: Debora.ps1, Debora.dat, Debora.exe, run.bat, SHA256SUMS
.\build\Test-All.ps1                   # Pester tests, every file in its own process
.\build\Release.ps1 -Version 1.0.0     # zip + checksums (+ GitHub release with -Publish)
```

## License

MIT — see [LICENSE](LICENSE).
