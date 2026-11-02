# Sky UI

## License / Лицензия

[MIT](LICENSE)

### Core support

| Core | Tested version | Protocols |
| --- | --- | --- |
| [mihomo](https://github.com/MetaCubeX/mihomo) | v1.19.33 | VLESS, Hysteria 2, Shadowsocks, TUIC v5, Mieru, TrustTunnel |
| [sing-box](https://github.com/SagerNet/sing-box) | v1.14.4 | VLESS, NaiveProxy, Hysteria 2, Shadowsocks, TUIC v5 |
| [Xray](https://github.com/XTLS/Xray-core) | v26.10.31 | VLESS, Shadowsocks |
| [AmneziaWG Go](https://github.com/amnezia-vpn/amneziawg-go) | v3.1.20260828 | AmneziaWG 3.1 |

Linux amd64, glibc and systemd 245+. Native builds tested on Ubuntu 24.04, Debian 12 and Rocky Linux 9. Verified versions are listed in the [compatibility catalog](compatibility/cores).


## English

A self-hosted panel for proxy cores on your Linux server. Create connections and share access through links, QR codes and subscriptions. Built for one owner and a few friends.

Jaspr frontend, Dart Frog backend, SQLite storage, systemd services. Active development.

### Installation

Linux:
```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/skyonave/sky_ui/main/install.sh)"
```

The installer downloads the panel. Choose a protocol when creating a connection; the panel installs its engine if needed. Engines run together and are preserved when reinstalling the panel. The setup wizard creates the administrator and configures IP access or an optional domain. Let's Encrypt certificates renew automatically. Domain access requires DNS pointing to your server and open TCP ports 80 and 443.

Run `sudo skyui setup` to change the address or recover administrator access. Run `sudo skyui --help` for local management, backups and HTTPS settings. `sudo skyui uninstall` removes the installation and its data after confirmation.

The installer compiles the server and management tools on your machine. It reuses a compatible Dart SDK (3.13 or newer, below 4.0), or downloads a temporary SDK. Build sources, temporary SDK and caches are removed afterwards. The installed panel runs native binaries. Build dependencies are installed through the system package manager.

After a failed attempt, verified panel and SDK downloads are kept for retry for up to one day. A successful installation clears them.

Core updates use the project's [compatibility catalog](compatibility/cores). Only releases verified for your panel version and server architecture can be installed.

New panel releases appear in the sidebar. Confirm the update there or run `sudo skyui update`. A failed update restores the previous panel and its data.

## Русский

Панель для управления прокси-ядрами на своём Linux-сервере. Создавай подключения и делись доступом через ссылки, QR-коды и подписки. Для одного владельца и нескольких близких.

Jaspr, Dart Frog, SQLite и службы systemd. Проект в активной разработке.

### Установка

Linux:
```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/skyonave/sky_ui/main/install.sh)"
```

Установщик скачает панель. При создании подключения выбери протокол, а панель установит нужное ядро, если его нет. Разные ядра работают одновременно и сохраняются при повторной установке панели. Мастер создаст администратора и предложит доступ по IP или домену. Сертификаты Let's Encrypt продлеваются автоматически. Для домена направь DNS на сервер и открой TCP-порты 80 и 443.

`sudo skyui setup` меняет адрес и восстанавливает доступ администратора. Все команды управления, резервного копирования и HTTPS доступны в `sudo skyui --help`. `sudo skyui uninstall` удаляет установку и её данные.

Сервер и инструменты управления собираются на вашей машине. Установщик использует подходящий Dart SDK (от 3.13, ниже 4.0), а если его нет, скачивает временный. После сборки исходники, временный SDK и кэши удаляются. Установленная панель работает из бинарников. Зависимости для сборки устанавливаются через пакетный менеджер системы.

Если установка не удалась, проверенные архивы панели и SDK сохраняются для повторной попытки на сутки. После успешной установки они удаляются.

Обновления берутся из [каталога совместимости проекта](compatibility/cores). Устанавливаются только версии, проверенные для вашей версии панели и архитектуры сервера.

Новая версия панели появится в боковой панели. Обновись оттуда или через `sudo skyui update`. При ошибке вернутся предыдущая версия и её данные.
