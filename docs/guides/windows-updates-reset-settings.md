# Windows update turned Copilot, ads or removed apps back on — how to keep your settings

*[Українською](uk/windows-updates-reset-settings.md)*

After a feature update (for example 24H2 → 25H2) and sometimes after cumulative updates, Windows can reinstall
built-in apps, re-enable Copilot, ads and "suggestions", reset policies and switch services back to automatic.
This is the most common reason people say "I debloated Windows and a month later everything was back".

## Why it happens

- Feature updates are a new Windows image: provisioned apps come back for existing users.
- Some settings live in places the update rewrites (Start layout, ContentDeliveryManager, app packages).
- Apps such as OneDrive or Teams update themselves and re-enable their startup entries.

## What you can do manually

1. Remove apps also as *provisioned* packages (`Remove-AppxProvisionedPackage -Online`), not only for your user.
2. Prefer policies (`HKLM\SOFTWARE\Policies\…`) over per-user settings — they survive updates more often.
3. After each feature update, re-check: Settings → Apps, Privacy & security, Personalization → Start, Startup apps.

## With Debora (automatic)

Debora remembers every change you applied with it (its change journal) and compares it with the current state:

- after a Windows build change, Debora shows **"Windows undid your changes: N"** with a list — keep the checks on the
  items to restore, untick the ones you want to leave as Windows set them;
- weekly **automatic maintenance** can restore them without asking;
- the **Overview** scan has a finding for it with a **Fix** button;
- command line: `Debora.exe -Guard` (list) and `Debora.exe -Guard -Yes` (restore).

Restoring is itself a journal session, so it can be undone too. If you undo a change in *Change history*, Debora
stops watching it.
