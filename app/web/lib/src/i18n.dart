class AppStrings {
  const AppStrings({this.locale = 'ru'});
  final String locale;
  String call(String key, [Map<String, Object> values = const {}]) {
    var message = (_catalogs[locale] ?? _catalogs['ru']!)[key] ?? key;
    for (final entry in values.entries) {
      message = message.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return message;
  }

  static const _catalogs = {
    'ru': {
      'nav.overview': 'Обзор',
      'nav.connections': 'Подключения',
      'nav.users': 'Пользователи',
      'nav.core': 'Ядро',
      'nav.logs': 'Журнал',
      'nav.settings': 'Настройки',
      'nav.workspace': 'УПРАВЛЕНИЕ',
      'nav.system': 'СИСТЕМА',
      'app.name': 'Sky UI',
      'data.applying': 'Применение…',
      'data.persisted': 'Данные сервера',
      'status.unassigned': 'Не выдано',
      'protocol.unavailable':
          'Этот протокол ещё не подключён к серверной части. Сейчас работает VLESS · TCP · REALITY на mihomo.',
      'share.type': 'Подписка или подключение',
      'share.uri': 'Ссылка подключения',
      'share.uriFormat': '{protocol} · ссылка подключения',
      'share.changed': 'Доступ изменился. Откройте подписку заново.',
      'field.handshakePort': 'Порт сайта REALITY',
      'help.handshakePort':
          'Порт HTTPS на сайте, указанном в SNI. Обычно 443. Это порт внешнего сайта для рукопожатия REALITY, а не порт вашего подключения.',
      'help.realityServerName':
          'Имя внешнего HTTPS-сайта, используемого для рукопожатия REALITY. Сайт должен быть доступен с сервера и поддерживать TLS 1.3; предпочтительно HTTP/2. Укажите только домен без https:// и пути. Это имя SNI на клиенте и адрес назначения на сервере. Сертификат для домена вашей панели здесь не нужен.',
      'runtime.error.state_changed':
          'Данные изменились в другой вкладке. Откройте форму заново, чтобы сохранить актуальные настройки.',
      'runtime.error.protocol_unavailable':
          'Серверная поддержка этого протокола ещё не реализована.',
      'runtime.error.core_unavailable':
          'Выбранное ядро не установлено для этого экземпляра.',
      'runtime.error.settings_unsupported':
          'Выбраны неподдержанные параметры протокола.',
      'runtime.error.listen_invalid':
          'Укажите IP-адрес прослушивания, например :: или 0.0.0.0.',
      'runtime.error.sni_invalid':
          'Укажите доменное имя сайта REALITY без протокола и пути.',
      'runtime.error.handshake_port_invalid':
          'Порт сайта REALITY должен быть от 1 до 65535.',
      'runtime.error.port_invalid':
          'Порт подключения должен быть от 1 до 65535.',
      'runtime.error.port_reserved':
          'Этот порт занят системой или панелью. Для подключения можно использовать свободный порт, например 8443.',
      'runtime.error.port_in_use':
          'Этот порт уже используется другим подключением.',
      'runtime.error.port_unavailable':
          'Адрес или порт недоступен для прослушивания. Проверьте сетевой адрес и другие службы.',
      'runtime.error.listener_not_ready':
          'Ядро запущено, но порт подключения не отвечает. Изменения не сохранены.',
      'runtime.error.configuration_write_failed':
          'Не удалось сохранить настройки. Проверьте свободное место и права службы.',
      'runtime.error.configuration_busy':
          'Конфигурация сейчас применяется. Повторите запрос через несколько секунд.',
      'runtime.error.configuration_out_of_sync':
          'Конфигурация ядра изменена вне панели. Выдача доступа заблокирована до восстановления согласованной конфигурации.',
      'runtime.error.configuration_rollback_failed':
          'Не удалось восстановить работающую конфигурацию. Изменения и выдача доступа заблокированы. Проверьте журнал и перезапустите службу Sky UI для восстановления.',
      'runtime.error.configuration_applied': 'Настройки применены',
      'runtime.error.configuration_recovered':
          'Конфигурация восстановлена после прерванной операции',
      'runtime.error.configuration_rolled_back':
          'Не удалось применить изменения; предыдущие настройки восстановлены',
      'runtime.error.name_invalid':
          'Введите имя от 1 до 80 символов без переносов строк.',
      'runtime.error.address_invalid':
          'Введите IP-адрес или домен сервера без протокола, порта и пути.',
      'runtime.error.grant_invalid':
          'Список доступных подключений изменился. Откройте форму пользователя заново.',
      'runtime.error.connection_identity_immutable':
          'Ядро и протокол существующего подключения изменить нельзя. Создайте новое подключение.',
      'runtime.error.service_busy':
          'Служба ядра меняет состояние. Повторите запрос через несколько секунд.',
      'runtime.error.core_not_ready':
          'Запустите ядро и дождитесь его готовности перед выдачей доступа.',
      'runtime.error.access_empty':
          'У пользователя нет включённых подключений.',
      'runtime.error.export_unavailable':
          'Для этого протокола ещё нет подходящего формата подписки.',
      'runtime.error.not_found': 'Запись удалена или доступ отключён.',
      'runtime.error.request_invalid':
          'Сервер не принял параметры запроса. Обновите страницу.',
      'runtime.error.request_too_large': 'Запрос слишком большой.',
      'runtime.error.gateway_auth_required':
          'Нет доверенного соединения со шлюзом панели. Повторите настройку через sudo sky-ui setup.',
      'runtime.error.listener_identity_unavailable':
          'Не удалось проверить, что подключение обслуживает процесс ядра. Выдача доступа заблокирована.',
      'runtime.connectedLabel': 'API',
      'runtime.footer': 'Dart Frog · API',
      'runtime.loading': 'Загрузка…',
      'runtime.offline': 'Нет связи',
      'runtime.working': 'Выполняется…',
      'runtime.controller': 'Контроллер',
      'runtime.ready': 'Готов',
      'runtime.notReady': 'Не готов',
      'runtime.refresh': 'Обновить',
      'runtime.validate': 'Проверить',
      'runtime.state.unknown': 'Неизвестно',
      'runtime.state.inactive': 'Остановлено',
      'runtime.state.activating': 'Запускается',
      'runtime.state.active': 'Работает',
      'runtime.state.deactivating': 'Останавливается',
      'runtime.state.failed': 'Ошибка запуска',
      'runtime.state.unavailable': 'Недоступно',
      'runtime.error.platform_unsupported':
          'Управление службами доступно на Linux с systemd. На этой машине запуск ядра недоступен.',
      'runtime.error.api_unavailable':
          'Нет связи с сервером. Проверьте, запущен ли API.',
      'runtime.error.binary_missing':
          'Исполняемый файл ядра не найден. Установите ядро на сервере.',
      'runtime.error.binary_probe_failed': 'Не удалось определить версию ядра.',
      'runtime.error.service_missing': 'Служба ядра не установлена.',
      'runtime.error.service_failed':
          'Служба ядра завершилась с ошибкой. Проверьте журнал systemd.',
      'runtime.error.supervisor_unavailable':
          'Не удалось получить состояние службы systemd.',
      'runtime.error.service_operation_failed':
          'Не удалось выполнить действие со службой. Проверьте её состояние и права управления.',
      'runtime.error.service_stop_timeout':
          'Служба не остановилась за отведённое время.',
      'runtime.error.configuration_missing':
          'Файл конфигурации ядра не найден.',
      'runtime.error.configuration_invalid':
          'Ядро отклонило конфигурацию. Работающая служба не была перезапущена.',
      'runtime.error.controller_not_ready':
          'Процесс запущен, но контроллер ядра пока не отвечает.',
      'runtime.error.command_timeout': 'Время ожидания операции истекло.',
      'runtime.error.command_unavailable':
          'Не найдена программа, необходимая для управления ядром.',
      'runtime.error.origin_forbidden':
          'Запрос к серверу отклонён. Проверьте адрес панели.',
      'runtime.error.internal_error':
          'Ошибка сервера. Проверьте журнал службы Sky UI.',
      'runtime.error.start': 'Ядро запущено',
      'runtime.error.stop': 'Ядро остановлено',
      'runtime.error.restart': 'Ядро перезапущено',
      'runtime.error.validate': 'Конфигурация проверена',
      'app.demo': 'Локальный макет',
      'app.owner': 'Владелец',
      'app.demoHint': 'Макет · изменения сохраняются в браузере',
      'app.version': 'Версия 0.1 · макет',
      'app.local': 'Локальное окружение',
      'connections.title': 'Подключения',
      'connections.description':
          'Протоколы, точки входа и доступ к вашему серверу.',
      'connections.add': 'Новое подключение',
      'connections.all': 'Все подключения',
      'connections.active': 'Активные',
      'connections.disabled': 'Отключённые',
      'connections.search': 'Найти подключение…',
      'connections.count': 'Всего подключений',
      'connections.configured': 'в конфигурации',
      'connections.activeCount': 'Активных подключений',
      'connections.empty': 'Подключений не найдено',
      'connections.emptyHint': 'Измените поиск или создайте новое подключение.',
      'table.name': 'ПОДКЛЮЧЕНИЕ',
      'table.recipient': 'ПОЛЬЗОВАТЕЛЬ',
      'table.access': 'ПОДКЛЮЧЕНИЯ',
      'table.enabled': 'ВКЛЮЧЁН',
      'table.protocol': 'ПРОТОКОЛ',
      'table.transport': 'ТРАНСПОРТ',
      'table.users': 'ДОСТУП',
      'table.status': 'СОСТОЯНИЕ',
      'table.actions': 'Действия',
      'status.active': 'Активно',
      'status.disabled': 'Отключено',
      'status.running': 'Работает',
      'status.stopped': 'Остановлено',
      'status.planned': 'Позже',
      'status.available': 'Доступен',
      'common.edit': 'Редактировать',
      'common.delete': 'Удалить',
      'common.cancel': 'Отмена',
      'common.save': 'Сохранить',
      'common.create': 'Создать подключение',
      'common.next': 'Продолжить',
      'common.back': 'Назад',
      'common.close': 'Закрыть',
      'common.copy': 'Скопировать',
      'common.enable': 'Включить',
      'common.disable': 'Отключить',
      'common.share': 'Поделиться',
      'common.all': 'Все',
      'common.help': 'Подсказка: {name}',
      'common.noUsers': 'Не назначен',
      'common.saved': 'Изменения сохранены в макете',
      'common.copied': 'Ссылка скопирована',
      'common.copyFailed': 'Не удалось скопировать. Выделите ссылку вручную.',
      'common.deleted': 'Запись удалена из макета',
      'common.required': 'Заполните обязательные поля',
      'common.invalidPort': 'Порт должен быть целым числом от 1 до 65535',
      'common.portUsed': 'Этот порт уже используется другим подключением',
      'common.invalidName': 'Введите название',
      'common.error': 'Ошибка',
      'modal.new': 'Новое подключение',
      'modal.edit': 'Настройка подключения',
      'modal.protocol': 'Выберите протокол',
      'modal.protocolHint': 'Сначала протокол. Затем — его настройки.',
      'modal.protocolNote':
          'В макете показаны шесть примеров форм. Полная поддержка протоколов появится при подключении ядра.',
      'modal.step1': 'Протокол',
      'modal.core': 'Ядро',
      'modal.stepCore': 'Ядро',
      'modal.step2': 'Настройки',
      'modal.general': 'Основные параметры',
      'modal.protocolSettings': 'Параметры протокола',
      'modal.previewOnly':
          'Это макет формы: сертификаты, ключи и сетевые настройки не проверяются ядром.',
      'modal.deleteTitle': 'Удалить запись?',
      'modal.deleteHint': '«{name}» будет удалено из локального макета.',
      'field.name': 'Название подключения',
      'field.listen': 'Адрес прослушивания',
      'field.username': 'Имя пользователя',
      'field.destination': 'Адрес назначения',
      'field.interfaceName': 'Имя интерфейса',
      'field.interfaceAddress': 'Адрес интерфейса',
      'field.mtu': 'MTU',
      'field.token': 'Токен',
      'field.wireguardKey': 'Приватный ключ WireGuard',
      'help.listen':
          'IP-адрес, на котором ядро принимает подключения. :: — все IPv6- и, при стандартных настройках Linux, IPv4-интерфейсы. 0.0.0.0 — все IPv4-интерфейсы; используйте его, если IPv6 отключён. 127.0.0.1 принимает только локальные соединения. Порт также должен быть открыт в сетевом экране.',
      'help.username':
          'Имя для аутентификации в поддерживающих её протоколах. В рабочей версии учётные данные назначаются отдельно каждому получателю доступа.',
      'help.destination':
          'Узел и порт назначения для перенаправления, например 127.0.0.1:8080. Точный формат и допустимые сочетания зависят от ядра.',
      'help.interfaceName':
          'Название виртуального сетевого интерфейса, например sky-tun. Оно должно быть свободно на сервере. Создание интерфейса требует соответствующих системных прав.',
      'help.interfaceAddress':
          'IP-адрес виртуального интерфейса с длиной префикса, например 10.0.0.1/24. Подсеть выбирается с учётом маршрутов сервера и подключённых сетей.',
      'help.mtu':
          'Максимальный размер пакета интерфейса в байтах. Обычно начинают с 1500; при инкапсуляции может потребоваться меньшее значение. Конкретные ограничения определяет ядро.',
      'help.token':
          'Секретный токен доступа к соответствующему сервису. В макете значение хранится только в браузере. Не вводите реальные секреты.',
      'help.wireguardKey':
          'Приватный ключ серверного интерфейса WireGuard. Он остаётся на сервере; клиентам передаётся публичный ключ. Здесь форма демонстрационная.',
      'field.port': 'Порт',
      'field.transport': 'Транспорт',
      'field.security': 'Защита соединения',
      'field.serverName': 'Имя сервера (SNI)',
      'field.flow': 'Flow',
      'field.certificate': 'Путь к сертификату',
      'field.privateKey': 'Путь к приватному ключу',
      'field.cipher': 'Метод шифрования',
      'field.password': 'Пароль',
      'field.network': 'Сетевой протокол',
      'field.obfs': 'Обфускация',
      'field.congestion': 'Контроль перегрузки',
      'field.path': 'Путь WebSocket',
      'field.serviceName': 'Имя сервиса gRPC',
      'field.obfsPassword': 'Пароль обфускации',
      'help.name':
          'Понятное вам название подключения. Например, «Основной» или «Для телефона». Оно помогает различать подключения в панели и подписке и не меняет работу протокола.',
      'help.port':
          'Порт, на котором ядро принимает подключения пользователей. Укажите свободный порт от 1 до 65535 и разрешите его в сетевом экране сервера и у провайдера VPS. Например, 8443. Порты служб панели, контроллера и SSH зарезервированы; 80 и 443 используются для HTTPS панели.',
      'help.transport':
          'Способ передачи данных протокола. TCP — прямое соединение; WebSocket использует HTTP Upgrade и может требовать путь; gRPC использует HTTP/2 и имя сервиса. Настройки транспорта на клиенте должны соответствовать серверу.',
      'help.security':
          'Защита соединения клиента с сервером. REALITY использует внешний HTTPS-сайт и пару ключей X25519; сервер генерирует ключи автоматически. Приватный ключ остаётся на сервере, а публичный ключ передаётся клиенту в ссылке и подписке.',
      'help.serverName':
          'Доменное имя, которое клиент передаёт при установке защищённого соединения. Для TLS оно должно соответствовать сертификату. Например, vpn.example.com. Для REALITY значение выбирается вместе с параметрами целевого сервера.',
      'help.flow':
          'Режим передачи VLESS. Для TCP с REALITY обычно выбирают xtls-rprx-vision: он оптимизирует передачу TLS-трафика. None отключает Vision. Значение в ссылке и профиле клиента выставляется автоматически и должно совпадать с сервером.',
      'help.certificate':
          'Абсолютный путь к файлу сертификата на Linux-сервере, например /etc/sky_ui/certs/fullchain.pem. Службе ядра нужен доступ на чтение. Локальный браузер не загружает и не проверяет этот файл.',
      'help.privateKey':
          'Абсолютный путь к приватному ключу сертификата на сервере. Например, /etc/sky_ui/certs/privkey.pem. Этот ключ хранится на сервере и не передаётся получателям подписки. Здесь путь является тестовым значением.',
      'help.cipher':
          'Алгоритм шифрования Shadowsocks. Метод и формат ключа должны поддерживаться сервером и клиентом. Методы семейства 2022 имеют особые требования к ключам; макет пока не проверяет их длину и формат.',
      'help.password':
          'Секрет для аутентификации или формирования ключа протокола. Используйте уникальное случайное значение подходящего формата. Здесь используются только демонстрационные данные, которые сохраняются в браузере.',
      'help.network':
          'Какие типы трафика принимает подключение: TCP, UDP или оба. Выбор зависит от приложений и поддержки ядра. Для UDP порт также должен быть доступен по UDP в сетевом экране.',
      'help.obfs':
          'Дополнительное преобразование трафика. При выборе salamander клиент и сервер должны использовать одинаковый пароль обфускации. Это не заменяет настройку аутентификации и сертификата.',
      'help.congestion':
          'Алгоритм управления скоростью передачи при перегрузке сети. bbr, cubic и new_reno по-разному реагируют на задержки и потери. Реальный набор вариантов определяется версией ядра.',
      'help.path':
          'HTTP-путь для WebSocket, например /connect. Значение должно совпадать у клиента, сервера и обратного прокси, если он используется. Это поле появляется при выборе WebSocket.',
      'help.serviceName':
          'Имя сервиса для gRPC-транспорта. Например, tunnel. Оно должно совпадать в конфигурации сервера и клиента; маршрутизация обратного прокси также должна учитывать выбранный сервис.',
      'help.obfsPassword':
          'Общий секрет для salamander. Укажите одинаковое значение на клиенте и сервере. Он отделён от учётных данных доступа пользователя.',
      'protocol.vless': 'Гибкая настройка транспорта',
      'protocol.trojan': 'Защищённое подключение с TLS',
      'protocol.shadowsocks': 'Простой зашифрованный прокси',
      'protocol.hysteria2': 'Транспорт на основе QUIC',
      'protocol.vmess': 'UUID и несколько транспортов',
      'protocol.tuic': 'QUIC с контролем перегрузки',
      'users.title': 'Пользователи',
      'users.description':
          'Делитесь доступом с близкими. Всё управление остаётся у вас.',
      'users.add': 'Добавить пользователя',
      'users.name': 'Имя пользователя',
      'users.access': 'Доступ к подключениям',
      'users.accessHint': 'Выберите подключения для этого пользователя.',
      'users.count': 'Пользователей с доступом',
      'users.total': 'Всего пользователей',
      'users.active': 'Доступ включён',
      'users.disabled': 'Доступ отключён',
      'users.subscription': 'Подписка',
      'users.none': 'Пока нет пользователей',
      'users.nameHelp':
          'Имя видно только вам в панели. Пользователь не получает учётную запись и не входит в панель.',
      'users.noAccess': 'Нет назначенных подключений',
      'users.accessRevoked': 'В макете отключены все доступы пользователя',
      'share.title': 'Поделиться доступом',
      'share.description': 'Личная подписка · {name}',
      'share.format': 'Clash Verge · mihomo YAML',
      'share.demo':
          'Демонстрационная ссылка: сервер подписок пока не подключён.',
      'share.disabled':
          'Доступ отключён. Включите пользователя, чтобы поделиться подпиской.',
      'share.selectUser':
          'Для выдачи подписки выберите пользователя в разделе «Пользователи».',
      'core.title': 'Ядро',
      'core.description': 'Одна панель. Разные ядра. Ваш выбор.',
      'core.current': 'ТЕКУЩЕЕ ЯДРО',
      'core.version': 'Версия',
      'core.service': 'Служба',
      'core.uptime': 'Время работы',
      'core.memory': 'Память',
      'core.stop': 'Остановить',
      'core.start': 'Запустить',
      'core.restart': 'Перезапустить',
      'core.changed': 'Состояние ядра изменено в макете',
      'core.restarted': 'Перезапуск имитирован',
      'core.future': 'Адаптер запланирован',
      'core.demo':
          'Состояние и характеристики демонстрационные. Управление systemd ещё не подключено.',
      'core.alternatives': 'Другие ядра',
      'core.architecture': 'Общий интерфейс управления · отдельные адаптеры',
      'overview.title': 'Обзор',
      'overview.description': 'Ваш сервер, подключения и люди — в одном месте.',
      'overview.connections': 'Последние подключения',
      'overview.activity': 'Последние события',
      'overview.open': 'Открыть все',
      'overview.ready': 'Всё под вашим контролем',
      'overview.readyHint':
          'Создавайте подключения и выдавайте доступ в пару шагов.',
      'logs.title': 'Журнал',
      'logs.description': 'События панели и демонстрационные сообщения ядра.',
      'logs.empty': 'В журнале пока нет событий',
      'logs.started': 'Макет панели запущен',
      'logs.connectionSaved': 'Подключение сохранено: {name}',
      'logs.userSaved': 'Пользователь сохранён: {name}',
      'logs.deleted': 'Запись удалена: {name}',
      'logs.toggled': 'Состояние изменено: {name}',
      'feature.unavailable': 'Недоступно',
      'core.notInstalled': 'Не установлено',
      'core.install': 'Установить',
      'core.update': 'Обновить ядро',
      'core.refreshStatus': 'Обновить статус',
      'core.releases': 'Изменения в релизах',
      'core.releaseVersions':
          'Установлено: {installed} · Последний релиз: {latest}',
      'core.releaseIncomplete':
          'Показана доступная часть истории. Полный список — в официальном репозитории.',
      'core.releaseEmpty': 'Описание релиза отсутствует.',
      'runtime.error.releases_unavailable':
          'Не удалось загрузить релизы. Попробуйте позже.',
      'runtime.error.releases_rate_limited':
          'GitHub временно ограничил запросы. Попробуйте позже.',
      'logs.level': 'Уровень',
      'logs.all': 'Все уровни',
      'logs.debug': 'DEBUG',
      'logs.info': 'INFO',
      'logs.warning': 'WARN',
      'logs.error': 'ERROR',
      'logs.fatal': 'FATAL',
      'logs.live': 'В реальном времени',
      'logs.reconnecting': 'Подключение к журналу…',
      'logs.latest': 'К последним записям',
      'logs.noMatches': 'Нет записей выбранного уровня',
      'logs.clear': 'Очистить',
      'logs.clearTitle': 'Очистить журнал?',
      'logs.clearHint':
          'Будут очищены все записи, накопленные панелью, включая скрытые фильтром. Новые события продолжат поступать. Системный журнал Linux не затрагивается.',
      'logs.cleared': 'Журнал очищен',
      'admin.title': 'Администратор',
      'admin.username': 'Имя администратора',
      'admin.password': 'Пароль',
      'admin.sessions': 'Активные сеансы',
      'admin.changePassword': 'Изменить пароль',
      'admin.manageSessions': 'Управление сеансами',
      'admin.logoutUnavailable': 'Выход — пока недоступно',
      'settings.system': 'Система',
      'settings.domain': 'Адрес панели и HTTPS',
      'settings.dns': 'DNS ядра',
      'settings.logging': 'Уровень журналирования ядра',
      'settings.configure': 'Настроить',
      'system.cpu': 'CPU',
      'system.collecting': 'Сбор данных…',
      'system.memory': 'RAM',
      'system.disk': 'Disk',
      'system.uptime': 'Uptime',
      'system.gb': 'GB',
      'system.mb': 'MB',
      'system.days': 'd',
      'system.hours': 'h',
      'system.minutes': 'm',
      'system.cores': '{count} cores',
      'system.total': 'из {value}',
      'system.unsupported': 'Метрики оборудования доступны на Linux.',
      'system.panel': 'Панель',
      'system.panelHint': 'API доступен',
      'system.configuration': 'Конфигурация',
      'system.applied': 'Применена',
      'system.configurationHint': 'Проверка соответствия настроек ядру',
      'system.coreHint': 'Процесс работает, контроллер доступен',
      'system.coreNotReady': 'Контроллер ядра не готов',
      'settings.title': 'Настройки',
      'settings.description': 'Только необходимое для вашей панели.',
      'settings.general': 'Общие',
      'settings.serverName': 'Название сервера',
      'settings.address': 'Публичный адрес сервера',
      'settings.language': 'Язык интерфейса',
      'settings.russian': 'Русский',
      'settings.localeHint':
          'Переводы подключаются отдельно. Сейчас доступен русский язык.',
      'settings.appearance': 'Оформление',
      'settings.dark': 'Тёмное',
      'settings.reset': 'Сбросить макет',
      'settings.resetHint': 'Вернуть тестовые подключения и пользователей.',
      'settings.resetTitle': 'Сбросить демонстрационные данные?',
      'settings.resetConfirm':
          'Локальные изменения будут заменены исходными тестовыми данными.',
      'settings.resetDone': 'Демонстрационные данные восстановлены',
      'settings.addressHelp':
          'IP или домен, по которому пользователи подключаются к ядру. Он попадёт в ссылки и профили. Домен самой панели и HTTPS меняются через sudo sky-ui setup.',
      'storage.failed':
          'Браузер не сохранил изменения. Данные останутся до перезагрузки страницы.',
    },
  };
}
