# База знань

| Файл | Що це | Джерело й ліцензія |
|---|---|---|
| `pci.ids` | Назви виробників і пристроїв PCI за кодами VEN/DEV | [The PCI ID Repository](https://pci-ids.ucw.cz/) — GNU GPL v2+ або 3-clause BSD (на вибір); використовується за BSD |
| `usb.ids` | Назви виробників і пристроїв USB за кодами VID/PID | [The Linux USB ID Repository](http://www.linux-usb.org/usb.ids) — GNU GPL v2+ або 3-clause BSD (на вибір); використовується за BSD |

Оновлення: завантажити свіжі файли з тих самих адрес і перезібрати (`build\Compile.ps1`). У збірку потрапляють лише рядки виробників і пристроїв (без підсистем і класів), стиснені gzip.

Де брати драйвери (сторінки виробників ПК і чипів) — `config/driver-sources.json`.
