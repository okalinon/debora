# What to do after a clean install of Windows 11 or 10

*[Українською](uk/setup-windows-11-after-clean-install.md)*

A checklist for a freshly installed Windows, in an order that avoids doing work twice.

## Checklist

1. **Network driver first.** If there is no internet, install the LAN or Wi-Fi driver from the PC/laptop
   manufacturer's site (copy it on a USB stick from another PC).
2. **Drivers.** Windows Update installs basic drivers; for graphics, chipset and audio prefer the manufacturer's
   or the chip vendor's (Intel, AMD, NVIDIA) packages.
3. **Windows Update** until there is nothing left — often 2–3 rounds with restarts.
4. **Debloat and privacy.** Remove pre-installed apps, turn off ads, telemetry and Copilot if you do not use it
   (see [Remove bloatware](remove-bloatware-windows-11.md), [Telemetry and ads](disable-telemetry-windows-11.md),
   [Copilot](disable-copilot-windows-11.md)).
5. **Apps.** Install with winget instead of downloading installers one by one:
   `winget install Google.Chrome 7zip.7zip VideoLAN.VLC` (no bundled toolbars or ads).
6. **Protection.** Make sure System Protection (restore points) is on and Windows Security is active.
7. **Restore point / backup** once everything works.

## With Debora — one pass

The **From scratch** tab does steps 2–7 in one run:

- drivers from the Microsoft Update Catalog and Windows Update (only exact matches for your hardware);
- debloat at the level you choose (*Careful / Recommended / Maximum*);
- a settings profile matched to the PC (SSD/HDD, RAM, laptop or desktop);
- apps from bundles (Essentials, Study & work, Gaming, Creative, Development…) or your own list;
- Windows Update — **if updates need a restart, the PC restarts and setup continues by itself after sign-in**;
- a final health scan that fixes what it finds.

Save the plan to a file and reuse it on other PCs. The **Reinstall** tab can put the plan on a Windows USB stick:
Windows installs without questions, gets this PC's drivers and runs the plan after the first sign-in.

Command line: `Debora.exe -Setup -ProfilePath plan.json -WhatIf` shows the plan.
