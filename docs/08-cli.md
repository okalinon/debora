# 8. CLI та автоматизація

Той самий `Debloater9.ps1` без інтерфейсу — для сервісних центрів і масового налаштування.

## Параметри

```powershell
.\Debloater9.ps1                                  # звичайний запуск з інтерфейсом
.\Debloater9.ps1 -Preset WeakPC -Yes              # застосувати профіль без питань
.\Debloater9.ps1 -Preset Recommended -WhatIf      # показати план для профілю під це залізо
.\Debloater9.ps1 -Profile .\office.json -Yes      # власний набір твіків
.\Debloater9.ps1 -ListTweaks -Format Json         # каталог із поточним станом
.\Debloater9.ps1 -ListSessions
.\Debloater9.ps1 -Undo 2026-10-10T14-32-05-a1b2 -Yes
.\Debloater9.ps1 -Preset Standard -NoRestorePoint -LogPath C:\logs\d9.log
```

| Параметр | Опис |
|---|---|
| `-Preset` | `Minimal`, `Standard`, `WeakPC`, `Gaming`, `Maximum`, `Recommended` (вибір за залізом) |
| `-Profile` | Шлях до JSON-профілю (формат нижче) |
| `-WhatIf` | Лише план і попередній перегляд, без змін |
| `-Yes` | Не питати підтвердження (обов'язковий для змін без інтерфейсу) |
| `-NoRestorePoint` | Не створювати точку відновлення |
| `-Undo <id>` | Відкотити сесію |
| `-LogPath` | Журнал роботи в інший файл (типово — `%ProgramData%\Debloater9\logs\РРРР-ММ.log`) |
| `-DriverUpdate [-WhatIf] [-IncludeOptional] [-Yes]` | Знайти в інтернеті (Microsoft Update Catalog + Windows Update) драйвери для пристроїв без драйвера й новіші версії, завантажити з перевіркою SHA-256 і встановити з відкатом; на Dell / Lenovo / HP — ще й утиліта виробника |
| `-Maintain` | Автоматичне обслуговування зараз: точка відновлення, очищення, бази Захисника, програми (winget), драйвери (каталог Microsoft), за бажанням — оновлення Windows; швидке сканування й сповіщення. Кроки — з `%ProgramData%\Debloater9\maintenance.json` |
| `-Schedule <день>\|Off [-At 12:00]` | Щотижневий запуск `-Maintain` через Планувальник (від поточного користувача з найвищими правами); копія програми — у `%ProgramData%\Debloater9\app` із доступом на запис лише для SYSTEM і адміністраторів |
| `-Uninstall "Назва*"[,…] [-Yes]` | Видалити встановлені програми за назвою (тихо, де можливо: QuietUninstallString, MSI, Inno Setup, NSIS); перед цим — точка відновлення |
| `-ExportDrivers <папка>` | Зберегти всі сторонні драйвери цього ПК (`pnputil /export-driver *`) |
| `-PrepareUsb <диск> [-UserName] [-AccountPassword] [-Edition Home\|Pro] [-Preset] [-KeepRequirements] [-NoDrivers]` | Доповнити флешку з Windows: `autounattend.xml` (без запитань, локальний акаунт, обхід вимог Windows 11), драйвери цього ПК у `$WinpeDriver$`, Debloater9 для налаштування після першого входу |
| `-Apps` | Каталог програм (`config/apps.json`) і що вже встановлено |
| `-InstallApp <ID>[,<ID>…] [-Yes]` | Встановити програми через winget (ID з каталогу, назва або будь-який точний ID winget) |
| `-UpgradeApps [-Yes]` | Оновити всі програми (`winget upgrade --all`) |
| `-Disks` | Стан фізичних дисків: модель, тип, томи, оцінка Windows; від адміністратора — температура, знос SSD, години роботи, невиправні помилки, прогноз відмови SMART. Код виходу 2, якщо внутрішній диск несправний. Меню — пункт 12 |
| `-Diagnostics [-OutDir <папка>]` | Зібрати zip для розбору проблеми: система, пристрої й драйвери, хвіст `setupapi.dev.log`, помилки з журналів подій за 7 днів, служби, автозапуск, останні сканування, сесії змін і логи. Типово — у папку «Звіти» |
| `-Language` | `uk` / `en` |

## Формат профілю

Профіль зберігається з інтерфейсу («Експорт вибору») або пишеться вручну:

```json
{
  "name": "Офісні ноутбуки",
  "schema": 1,
  "tweaks": ["privacy.telemetry", "privacy.ads-tips", "apps.remove-bloat", "ui.search-local"],
  "appx": { "remove": ["Microsoft.BingNews", "Clipchamp.Clipchamp"] },
  "install": ["Mozilla.Firefox", "VideoLAN.VLC", "7zip.7zip"],
  "options": { "restorePoint": true, "skipNotApplicable": true }
}
```

Твіки, що не підходять до ОС чи заліза, пропускаються і позначаються в звіті (не помилка).

## Коди завершення

| Код | Значення |
|---|---|
| 0 | Усе застосовано |
| 1 | Частина дій завершилась помилкою (див. журнал) |
| 2 | Помилка параметрів або профілю |
| 3 | Немає прав адміністратора |
| 4 | Користувач скасував / немає `-Yes` |
| 10 | Потрібне перезавантаження (усе інше успішно) |
