# Changelog

Debora — Windows 10/11 debloat, setup from scratch and maintenance (PowerShell 5.1 + WPF, Ukrainian and English).
Before 0.19.0 the program was called Debloater9.

## 1.0.1 — 2026-10-16

- Releases are now built by GitHub Actions from this repository (prepared for code signing by SignPath Foundation).
- Preferences: turn off the automatic daily update check (*Check for Debora updates*).
- README in English and Ukrainian with screenshots, privacy, uninstall and code signing policy; both are in the package.
- Tests no longer depend on console encoding, screen size or number format.

## 1.0.0 — 2026-10-16

First public release.

- **Debora.exe** launcher with its own icon: one UAC prompt, no console window. With arguments it runs the
  command line (`Debora.exe -Scan`, `-Debloat -Level Max`, `-Setup`, `-Guard`, `-Update`, `-Help`).
- **Self-update** from GitHub Releases: background check once a day, "Debora X is available" bar, one-click
  update; the archive is verified by SHA-256 and the previous files are kept.
- **Setup from scratch continues after restarts**: when Windows updates need a restart, the wizard restarts the PC
  and continues after sign-in (up to 3 rounds of updates, at most 4 restarts).
- New `CHANGELOG.md`, English README, `-Help`, updated instructions; every test file can run in its own process
  (`build\Test-All.ps1`).

## 0.42.0 — 2026-10-14
- 25 new debloat items: ads in Settings and search, Edge nags and new tab ads, ShutUp10-level privacy (app permissions,
  CEIP, handwriting data, Find my device, settings sync), Windows generative AI permission and Edge AI, Family, NFC,
  hotspot and compatibility services, error report and Xbox save tasks. 74 items in total.

## 0.41.0 — 2026-10-14
- Debloat levels **Careful / Recommended / Maximum** (cumulative) and, for every item, what will stop working —
  shown in the list, before applying and in the CLI (`-Debloat -Level`). The setup wizard stores the level.

## 0.40.0 — 2026-10-14
- **Watch for changes Windows undoes** after updates (Copilot, ads, apps, policies, services): a bar after start,
  a scanner check, a weekly maintenance step and `-Guard`; restoring is an undoable journal session.

## 0.39 — 2026-10-13
- The window opens in about **1 second** (was 12–18 s): shown before tab handlers are wired, WPF warm-up on a
  background thread, compressed configuration, large databases in `Debora.dat`.
- Faster tabs: drivers 6.7 → 2.5 s, GitHub apps 4.7 → 0.2 s, uninstall list 1.2 → 0.45 s.
- Regression pass comparing old and new code on real data; the whole test suite is green.

## 0.37 — 2026-10-11/12
- Preferences tab (language, theme, hidden findings, notifications, data folders). Compact two-line lists everywhere.

## 0.31 – 0.36 — 2026-10-11
- One function per tab; **Fix** and **How to fix** buttons in every finding; hide (acknowledge) findings;
  progress panel with timer, ETA, queue and Stop; usability audit (49 items) worked through.

## 0.30.0 — 2026-10-11
- **Setup from scratch** wizard: drivers, debloat, settings profile, apps, Windows Update and scan-and-fix in one pass;
  the plan is a portable JSON profile that the reinstall USB runs after the first sign-in.

## 0.24 – 0.29 — 2026-10-11
- Battery health, full device and driver list, Debloat tab (apps one by one, features, components, services, tasks),
  finding details with files and folders.

## 0.19 – 0.23 — 2026-10-10
- Renamed to **Debora**; 553 apps with icons; apps from GitHub releases (ArtCraft suite); uninstall with sizes, dates
  and leftover cleanup; Ukrainian and English interface; fixes from live administrator runs.

## 0.6 – 0.18 — 2026-10-10
- First versions as Debloater9: tweak engine with journal and exact undo, scanner with score and checklist,
  online drivers (Microsoft Update Catalog), apps via winget, reinstall USB (autounattend.xml + drivers),
  scheduled maintenance, dark theme, startup advice, disk health (SMART), deeper analysis (blue screens, crashes,
  slow boot).
