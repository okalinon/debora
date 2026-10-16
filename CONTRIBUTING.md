# Contributing to Debora

Thanks for helping! The most useful contributions are:

- **Bug reports** with the diagnostics zip (*Change history → Collect diagnostics*) — use the
  [bug report form](https://github.com/okalinon/debora/issues/new?template=bug_report.yml).
- **New debloat items or tweaks** — something Windows does that most people do not want. Please include where the
  setting lives (registry path, policy, service, app package), which Windows versions have it and what stops working.
- **Translations** — the interface is Ukrainian and English; texts live in `config/lang-en-*.json`.

## Development

Requirements: Windows 10/11, Windows PowerShell 5.1, [Pester](https://pester.dev) 5+.

```powershell
.\src\Main.ps1 -Gui                  # run from source
.\build\Test-All.ps1                 # all tests (each file in its own process)
.\build\Compile.ps1 -Version 0.0.0   # build dist\Debora.ps1, Debora.dat, Debora.exe
```

Rules that keep Debora safe and maintainable:

- Every change to Windows goes through the engine (`src/core/Engine.ps1`): it records the previous state, so every
  change is undoable. Tweaks and debloat items are data (`config/tweaks.json`, `config/debloat.json`), not code.
- Each debloat item has a `level` (`safe`, `recommended`, `max`) and, unless it is `safe`, a `loses` text that says
  what stops working — in Ukrainian and English.
- One function lives on one tab only; the test *No duplicates between tabs* checks it.
- `.ps1` files are UTF-8 with BOM (PowerShell 5.1 needs it for Cyrillic text).
- User-facing text goes through `T-D9` with an English translation in `config/lang-en-*.json`
  (`tests/I18n.Tests.ps1` checks it).

Pull requests run the full test suite on GitHub Actions. Design notes (Ukrainian) are in [docs/](docs/).
