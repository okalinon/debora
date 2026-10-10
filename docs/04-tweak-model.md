# 4. Модель твіків

Твік — це **дані**: назва, опис, умови застосовності й список атомарних дій. Код знає лише, як виконати кожен *тип* дії. Додати новий твік = додати запис у `config/tweaks.json`.

## Приклад

```json
{
  "id": "perf.disable-sysmain",
  "category": "performance",
  "name":  { "uk": "Вимкнути SysMain / Superfetch", "en": "Disable SysMain / Superfetch" },
  "description": {
    "uk": "Часта причина «диск 100%» на HDD з малим обсягом пам'яті. На SSD шкодить.",
    "en": "Common cause of 100% disk usage on HDD with low RAM. Harmful on SSD."
  },
  "risk": "moderate",
  "requires": {
    "os": ["win10", "win11"],
    "hardware": { "systemDisk": ["hdd"] }
  },
  "rebootRequired": false,
  "actions": [
    { "type": "service", "name": "SysMain", "startup": "Disabled", "stop": true }
  ]
}
```

## Поля

| Поле | Тип | Обов'язкове | Опис |
|---|---|---|---|
| `id` | string | так | Унікальний, `категорія.назва-через-дефіс`; не змінюється між версіями (на нього посилаються журнали й профілі) |
| `category` | enum | так | `privacy`, `apps`, `ui`, `performance`, `gaming`, `cleanup`, `updates`, `safety` |
| `name`, `description` | `{uk, en}` | так | Тексти для інтерфейсу |
| `risk` | enum | так | `safe` — безпечно для всіх · `moderate` — може вимкнути функцію, якою хтось користується · `expert` — може зламати щось помітне |
| `requires.os` | масив | ні | `win10`, `win11`; або `minBuild` / `maxBuild` |
| `requires.hardware` | об'єкт | ні | `systemDisk: [hdd, ssd, nvme]`, `maxRamGB`, `minRamGB`, `battery: true/false` |
| `conflicts` | масив id | ні | Твіки, які не можна вибрати разом |
| `rebootRequired` | bool | ні | Показати «потрібне перезавантаження» |
| `actions` | масив | так | Атомарні дії (нижче) |
| `irreversible` | bool | ні | Твік не можна відкотити за суттю (очищення файлів). Дозволяє `command` без `undoRun`; інтерфейс попереджає |

## Типи дій

| `type` | Параметри | Що робить | Знімок для відкату |
|---|---|---|---|
| `registry` | `path`, `name`, `value`, `kind` (`DWord`, `QWord`, `String`, `ExpandString`, `Binary`, `MultiString`), або `delete: true` | Встановлює/видаляє значення; створює ключ за потреби | Старе значення й тип, або «значення не існувало», або «ключ не існував» |
| `service` | `name`, `startup` (`Disabled`, `Manual`, `Automatic`, `AutomaticDelayed`), `stop` | Змінює тип запуску, зупиняє | Тип запуску й стан (Running/Stopped) |
| `appx` | `package` (з `*`), `allUsers`, `deprovision` | Видаляє пакет і забороняє перевстановлення | Список видалених `PackageFamilyName` → відкат через winget/Store |
| `scheduledTask` | `path`, `state` (`Disabled`/`Enabled`) | Вмикає/вимикає завдання | Попередній стан |
| `powercfg` | `scheme` (GUID або `high`, `balanced`, `ultimate`), `hibernate` | Активує схему (дублює, якщо її немає), гібернація | Попередня активна схема, стан гібернації |
| `command` | `run`, `undoRun`, `test` (необов'язково: вираз, що повертає `$true`, якщо вже застосовано) | Довільний PowerShell-код — **лише якщо інші типи не підходять** | Лише через явний `undoRun` |
| `winget` | `id`, `action` (`install`/`uninstall`) | Встановлення програм | — |

## Контракт дії

Кожен модуль у `src/actions/` реалізує чотири функції:

```powershell
Get-D9<Type>State    -Action $a   # → поточний стан (для знімка й показу)
Test-D9<Type>        -Action $a   # → $true, якщо стан уже бажаний
Invoke-D9<Type>      -Action $a   # → застосувати; ідемпотентно
Restore-D9<Type>     -Snapshot $s # → повернути стан зі знімка
```

Стан твіка = агрегат `Test` його дій: усі `true` → **застосовано**, частина → **частково**, жодної → **не застосовано**, твік не підходить → **н/д**.

## Знімок і журнал

Перед кожним `Invoke` виконавець викликає `Get-…State` і записує знімок:

```json
{
  "session": "2026-10-10T14-32-05-a1b2",
  "machine": "DESKTOP-A4JHUQ7",
  "os": "Windows 10 Home 22H2 (19045)",
  "restorePoint": "Debloater9 2026-10-10 14:32",
  "entries": [
    {
      "tweak": "perf.disable-sysmain",
      "action": { "type": "service", "name": "SysMain", "startup": "Disabled", "stop": true },
      "before": { "startup": "Automatic", "status": "Running" },
      "after":  { "startup": "Disabled",  "status": "Stopped" },
      "result": "ok",
      "time": "2026-10-10T14:32:41"
    }
  ]
}
```

Відкат проходить записи сесії **у зворотному порядку** і викликає `Restore-…` з `before`. Якщо поточний стан уже не дорівнює `after` (користувач чи Windows змінили його після нас), відкат цього запису пропускається з попередженням — щоб не затерти чужу зміну.

## Перевірка каталогу

- JSON Schema у `config/schema/tweaks.schema.json`; перевірка — під час збірки (помилка збірки) і під час запуску (твік вимикається з попередженням).
- Додаткові правила в тестах: унікальні `id`; кожна дія `command` має `undoRun`, якщо твік не позначено `irreversible`; `risk: expert` не входить у профілі «Мінімальний» і «Слабкий ПК»; кожен твік має обидві мови.
