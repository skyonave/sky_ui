# Sky UI

## License / Лицензия

[MIT](LICENSE)

### Core support

| Core | Tested version | Supported |
| --- | --- | --- |
| [mihomo](https://github.com/MetaCubeX/mihomo) | v1.19.33 | ✅ |
| [sing-box](https://github.com/SagerNet/sing-box) | N/A | ❌ |
| [Xray](https://github.com/XTLS/Xray-core) | N/A | ❌ |


## English

A self-hosted panel for proxy cores on your Linux server. Create connections and share access through links, QR codes and subscriptions. Built for one owner and a few friends.

Jaspr frontend, Dart Frog backend, SQLite storage, systemd services. Active development.

### Installation

Linux:
```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/skyonave/sky_ui/main/install.sh)"
```

The installer downloads a ready-made release. The setup wizard creates the administrator and configures IP access or an optional domain. Let's Encrypt certificates renew automatically. Domain access requires DNS pointing to your server and open TCP ports 80 and 443.

Run `sudo skyui setup` to change the address or recover administrator access. Run `sudo skyui --help` for local management, backups and HTTPS settings. `sudo skyui uninstall` removes the installation and its data after confirmation.

Core updates use the project's [compatibility catalog](compatibility/cores). Only releases verified for your panel version and server architecture can be installed.

## Русский

Панель для управления прокси-ядрами на своём Linux-сервере. Создавай подключения и делись доступом через ссылки, QR-коды и подписки. Для одного владельца и нескольких близких.

Jaspr, Dart Frog, SQLite и службы systemd. Проект в активной разработке.

### Установка

Linux:
```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/skyonave/sky_ui/main/install.sh)"
```

Установщик скачает готовый релиз. Мастер создаст администратора и предложит доступ по IP или домену. Сертификаты Let's Encrypt продлеваются автоматически. Для домена направь DNS на сервер и открой TCP-порты 80 и 443.

`sudo skyui setup` меняет адрес и восстанавливает доступ администратора. Все команды управления, резервного копирования и HTTPS доступны в `sudo skyui --help`. `sudo skyui uninstall` удаляет установку и её данные.

Обновления берутся из [каталога совместимости проекта](compatibility/cores). Устанавливаются только версии, проверенные для вашей версии панели и архитектуры сервера.
