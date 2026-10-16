# Як вимкнути Copilot і Recall у Windows 11

*Для Windows 11 23H2, 24H2 і 25H2. [English](../disable-copilot-windows-11.md)*

Copilot у Windows 11 — це окремий застосунок (Microsoft.Copilot), кнопка на панелі завдань, а в деяких версіях ще й
бічна панель. Recall і Click to Do є лише на ПК Copilot+. Усе це можна вимкнути, а згодом увімкнути знову.

## Коротко

1. Видаліть застосунок: **Параметри → Програми → Інстальовані програми → Copilot → Видалити**.
2. Сховайте кнопку: **Параметри → Персоналізація → Панель завдань → Copilot** (вимкнути), якщо ваша версія її показує.
3. Заблокуйте політикою, щоб оновлення не повертали його (Pro/Enterprise — груповою політикою, будь-яка редакція —
   через реєстр нижче).
4. На ПК Copilot+: **Параметри → Конфіденційність і захист → Recall і знімки** → вимкніть «Зберігати знімки».

## Вручну (реєстр, будь-яка редакція)

У PowerShell від адміністратора:

```powershell
# Вимкнути Windows Copilot (політика для поточного й усіх користувачів)
New-Item 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1 -Type DWord
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1 -Type DWord
# Сховати кнопку на панелі завдань
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ShowCopilotButton 0 -Type DWord
# Recall: не зберігати знімки (ПК Copilot+)
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' DisableAIDataAnalysis 1 -Type DWord
# Видалити застосунок Copilot для поточного користувача
Get-AppxPackage *Microsoft.Copilot* | Remove-AppxPackage
```

Якщо захочете повернути як було — спершу запишіть попередні значення (або скористайтеся Debora, вона робить це сама).

## За допомогою Debora

1. Завантажте [Debora](https://github.com/okalinon/debora/releases/latest), запустіть **Debora.exe**.
2. Вкладка **«Деблоат»** → рівень **«Рекомендовано»**. Розділ «Copilot і штучний інтелект» містить застосунок Copilot,
   політику, Recall, Click to Do, ШІ в Paint і Блокноті, кнопку Copilot в Edge і «Запитати Copilot» у контекстному
   меню. У кожному рядку — що перестане працювати.
3. **«Застосувати вибране»**. Спершу створюється точка відновлення; «Журнал змін» точно відкочує все.

Командний рядок: `Debora.exe -Debloat -Level Recommended`.

## Чому Copilot повертається

Великі оновлення можуть перевстановити застосунок і скинути налаштування. Debora перевіряє це після кожного оновлення
Windows і пропонує повернути вимкнене — див. [Як зберегти налаштування після оновлень Windows](windows-updates-reset-settings.md).
