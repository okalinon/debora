# Як прибрати непотрібні застосунки (bloatware) з Windows 11 і 10

*[English](../remove-bloatware-windows-11.md)*

«Сміття» на новому ПК з Windows — це здебільшого попередньо встановлені застосунки (Candy Crush, TikTok, Spotify,
Clipchamp, Xbox, Новини й Погода Bing), «рекомендовані» застосунки, які Windows ставить сама, і реклама в Пуску,
Параметрах і на екрані блокування. Прибирати їх безпечно, якщо не чіпати системні компоненти.

## Коротко

- Один застосунок: **Параметри → Програми → Інстальовані програми → … → Видалити**.
- Щоб Windows не ставила «рекомендовані» застосунки знову: вимкніть «Показувати пропозиції» в
  **Параметри → Персоналізація → Пуск** і споживчі функції (реєстр нижче).
- Не видаляйте: Microsoft Store, «Інсталятор застосунків» (winget), «Безпека Windows», «Фотографії», «Калькулятор»,
  «Термінал» — від них залежить інше.

## Вручну (PowerShell)

```powershell
# Видалити застосунок для поточного користувача (наприклад, Clipchamp)
Get-AppxPackage *Clipchamp* | Remove-AppxPackage
# Для всіх користувачів і для нових облікових записів (PowerShell від адміністратора)
Get-AppxPackage -AllUsers *Clipchamp* | Remove-AppxPackage -AllUsers
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like '*Clipchamp*' | Remove-AppxProvisionedPackage -Online
# Заборонити автоматичне встановлення «рекомендованих» застосунків
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' DisableWindowsConsumerFeatures 1 -Type DWord
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' SilentInstalledAppsEnabled 0 -Type DWord
```

Видалені застосунки зі Store можна встановити знову з Microsoft Store.

## За допомогою Debora

Вкладка **«Деблоат»** показує лише ті вбудовані застосунки, що справді є на вашому ПК, у групах «Реклама й нав'язані
ігри», «Застосунки Microsoft, що рідко потрібні», «ШІ та хмарні сервіси», «Xbox» і «Корисні, але не всім».

- **«Обережно»** — реклама, ігри й застаріле (Candy Crush, рекламний Spotify, Paint 3D, Skype, Cortana…).
- **«Рекомендовано»** — плюс Clipchamp, Teams, новий Outlook, «Зв'язок із телефоном» та інші застосунки Microsoft,
  яких більшість ніколи не відкриває.
- **«Максимально»** — плюс Xbox і Game Bar, віджети й дрібні корисні застосунки (Будильники, Записки, Швидка допомога).

У кожному рядку видно, що перестане працювати (наприклад, «Xbox Game Bar: запис відео з ігор, знімки екрана, лічильник
FPS»). Застосунки видаляються для всіх користувачів і для нових облікових записів, кожен можна повернути з «Журналу
змін». Звичайні програми (пробні антивіруси, утиліти виробника) — на вкладці **«Видалення»**, з прибиранням залишків.

Командний рядок: `Debora.exe -Debloat -Level Safe -WhatIf` покаже перелік, нічого не змінюючи.
