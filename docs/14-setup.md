# 14. Майстер «Налаштування з нуля»

Один прохід після чистого встановлення Windows: усе, що зазвичай роблять руками годину-дві, Debora робить за один запуск і за одним профілем.

## Кроки (у цьому порядку)

| Крок | Що робить | Звідки |
|---|---|---|
| `drivers` | Драйвери з Microsoft Update Catalog і Windows Update за ID пристроїв; лише точні збіги, попередні драйвери зберігаються | `Invoke-D9DriverAutoUpdate` |
| `debloat` | Рекомендований деблоат: нав'язані застосунки, реклама, Copilot, телеметрія | `Get-D9DebloatRecommended` → `Invoke-D9Debloat` |
| `tweaks` | Профіль налаштувань (`Recommended` — рекомендований для цього ПК, або id з `presets.json`) | `New-D9Plan` / `Invoke-D9Plan` |
| `apps` | Програми: набори `bundles` + окремі ID з `apps.json`; уже встановлені пропускаються | `Install-D9Apps` |
| `windowsUpdate` | Пошук і встановлення оновлень через Windows Update Agent | `Install-D9WindowsUpdates` |
| `scanFix` | Сканування → автоматичні кроки чекліста → повторне сканування (оцінка до/після) | сканер + чекліст |

Одна точка відновлення на початку; кожен крок — окремо (збій не зупиняє решту); усі зміни через рушій, тож відкочуються в «Журналі змін». Підсумок — `%ProgramData%\Debloater9\setup-last.json`.

## Профіль

```json
{ "schema": 1, "name": "Офіс", "created": "2026-10-11T12:00:00",
  "steps": ["drivers", "debloat", "tweaks", "apps", "windowsUpdate", "scanFix"],
  "preset": "Recommended", "bundles": ["basic", "work"], "apps": ["7zip.7zip"], "reboot": true }
```

- Зберігається сам у `%ProgramData%\Debloater9\setup-profile.json` при кожному запуску чи «Що буде зроблено».
- «Зберегти профіль у файл…» / «Завантажити профіль з файлу…» — перенесення на інший ПК; CLI `-ExportProfile`, `-Setup -ProfilePath`.
- Невідомі кроки, порожні ID й повтори відкидаються при читанні (`ConvertTo-D9SetupProfile`); профіль новішої схеми — помилка.
- Флешка перевстановлення (вкладка «Перевстановлення»): якщо профіль збережено, він копіюється в `Debora\setup-profile.json`, і після першого входу виконується `-Setup -ProfilePath … -Yes -NoRestorePoint` замість окремих `-Preset` і `-DriverUpdate`. З `-Yes` і `reboot: true` ПК перезавантажується через 60 с (`shutdown /a` — скасувати).

## Де в програмі

- Вкладка **«З нуля»**: галочки кроків, список профілів налаштувань, набори програм, поле ID, «Додати вибрані на вкладці «Програми»», «Що буде зроблено», «Почати налаштування».
- CLI: `-Setup [-ProfilePath файл] [-WhatIf] [-Yes] [-NoRestorePoint]`, `-ExportProfile файл`; меню — пункт 15.
- Код: `src/maintenance/Setup.ps1`; тести — `tests/Setup.Tests.ps1`, вкладка — у `tests/Gui.Tests.ps1`, флешка — `tests/Reinstall.Tests.ps1`.
