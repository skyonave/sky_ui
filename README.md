# Sky UI

## License / Лицензия

[MIT](LICENSE)

### Core support

| Core | Tested version | Protocols |
| --- | --- | --- |
| [mihomo](https://github.com/MetaCubeX/mihomo) | v1.19.34 | VLESS, Hysteria 2, Shadowsocks, TUIC v5, Mieru, TrustTunnel |
| [sing-box](https://github.com/SagerNet/sing-box) | v1.14.4 | VLESS, NaiveProxy, Hysteria 2, Shadowsocks, TUIC v5 |
| [Xray](https://github.com/XTLS/Xray-core) | v26.11.9 | VLESS, Shadowsocks |
| [AmneziaWG Go](https://github.com/amnezia-vpn/amneziawg-go) | v3.1.20260828 | AmneziaWG 3.1 |

Linux amd64 and arm64, glibc 2.31+, systemd 245+. Verified versions are listed in the [compatibility catalog](compatibility/cores).


## English

A self-hosted panel for proxy cores on your Linux server. Create connections and share access through links, QR codes and subscriptions. Built for one owner and a few friends.

The panel is available in English and Russian. Switch languages at sign-in or in Settings.

### Windows client

For Windows x64, use [Sky Relink](https://github.com/skyonave/sky_relink). Copy the subscription link from Sky UI and import it under Profiles in Relink. Each user has one peer per AmneziaWG connection. For another device, create a separate user and use that user's subscription. Several users can share the same connection.

After updating, previously registered devices appear as separate users. Replace the shared subscription on each device with its user's subscription link. Existing imported profiles retain their previous peer until refreshed or reimported.

### Installation

Linux:
```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/skyonave/sky_ui/main/install.sh)"
```

The installer downloads the panel. Choose a protocol when creating a connection; the panel installs its engine if needed. Engines run together and are preserved when reinstalling the panel. The setup wizard creates the administrator and configures IP access or an optional domain. Let's Encrypt certificates renew automatically. Domain access requires DNS pointing to your server and open TCP ports 80 and 443.

Change the domain in Settings. Use `sudo skyui setup` to change the IP address or recover administrator access. Run `sudo skyui --help` for local management, backups and HTTPS settings. `sudo skyui uninstall` removes the installation and its data after confirmation.

The installer downloads ready-to-run binaries. Dart SDK and compilers are not required. Releases target glibc 2.31 or newer and systemd 245 or newer. Engines are downloaded separately.

Core updates use the project's [compatibility catalog](compatibility/cores). Only releases verified for your panel version and server architecture can be installed.

Add remote Linux servers over SSH in Servers. They support mihomo, sing-box, Xray and AmneziaWG, including NaiveProxy through sing-box. In Routing, create a route and its rules, then select it when creating a connection. Rules are checked from top to bottom; the first match wins. A remote server can handle both entry and exit. Set the client IP or domain on its server card. Remote TLS requires that server's certificate. AmneziaWG uses a single server, without a proxy cascade. The release includes `install-server-node.sh` for manual installation.

### Source layout

[app/web](app/web) is the Jaspr UI, [app/api](app/api) is the Dart Frog API, [app/shared](app/shared) contains portable contracts, and [app/ops](app/ops) handles the CLI and server maintenance. Features are grouped inside each application. Run `dart tool/check.dart` to check dependencies, analyze the code and run tests.

New panel releases appear in the sidebar. Confirm the update there or run `sudo skyui update`. A failed update restores the previous panel and its data.

## Русский

Панель для управления прокси-ядрами на своём Linux-сервере. Создавайте подключения и делитесь доступом через ссылки, QR-коды и подписки. Подходит для личного сервера, которым пользуются несколько человек.

Панель доступна на русском и английском. Язык можно сменить при входе или в настройках.

### Клиент для Windows

Для Windows x64 используйте [Sky Relink](https://github.com/skyonave/sky_relink). Скопируйте ссылку на подписку из Sky UI и импортируйте её в разделе «Профили» в Relink. У каждого пользователя один пир на подключение AmneziaWG. Для другого устройства создайте отдельного пользователя и используйте его подписку. Одно подключение можно выдать нескольким пользователям.

После обновления ранее зарегистрированные устройства появятся отдельными пользователями. Замените общую подписку на каждом устройстве ссылкой его пользователя. Уже импортированные профили сохраняют прежний пир до обновления подписки или повторного импорта.

### Установка

Linux:
```sh
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/skyonave/sky_ui/main/install.sh)"
```

Установщик скачает панель. При создании подключения выберите протокол, а панель установит нужное ядро, если его нет. Разные ядра работают одновременно и сохраняются при повторной установке панели. Мастер создаст администратора и предложит доступ по IP или домену. Сертификаты Let's Encrypt продлеваются автоматически. Для домена направьте DNS на сервер и откройте TCP-порты 80 и 443.

Домен можно сменить в настройках панели. Команда `sudo skyui setup` меняет IP-адрес панели и восстанавливает доступ администратора. Команды управления, резервного копирования и HTTPS доступны в `sudo skyui --help`. `sudo skyui uninstall` удаляет установку и её данные после подтверждения.

Установщик скачивает готовые бинарники. Dart SDK и компиляторы не нужны. Требуются glibc от 2.31 и systemd от 245. Ядра скачиваются отдельно.

Обновления берутся из [каталога совместимости проекта](compatibility/cores). Устанавливаются только версии, проверенные для вашей версии панели и архитектуры сервера.

Подключайте удалённые Linux-серверы по SSH в разделе «Серверы». На них доступны mihomo, sing-box, Xray и AmneziaWG, включая NaiveProxy через sing-box. Создайте маршрут и правила в «Маршрутизации», затем выберите его при создании подключения. Правила проверяются сверху вниз, применяется первое совпадение. Удалённый сервер может быть одновременно входом и выходом. IP или домен для клиентов задаётся в его карточке. Для удалённого TLS нужен сертификат этого сервера. AmneziaWG работает на одном сервере, без прокси-каскада. Для ручной установки в релизе есть `install-server-node.sh`.

### Структура проекта

[app/web](app/web) содержит интерфейс Jaspr, [app/api](app/api) сервер Dart Frog, [app/shared](app/shared) общие контракты, [app/ops](app/ops) CLI и обслуживание сервера. Внутри приложений код сгруппирован по функциям. Команда `dart tool/check.dart` проверяет зависимости, анализирует код и запускает тесты.

Новая версия появится в боковой панели. Обновите Sky UI оттуда или командой `sudo skyui update`. При ошибке восстановятся предыдущая версия и её данные.
