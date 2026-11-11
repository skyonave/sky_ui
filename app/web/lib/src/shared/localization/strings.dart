import 'engine_strings.dart';
import 'diagnostic_strings.dart';
import 'mihomo_strings.dart';
import 'english_strings.dart';

class AppStrings {
  const AppStrings({String? locale}) : _locale = locale;
  final String? _locale;
  static const supportedLocales = ['ru', 'en'];
  static String defaultLocale = 'ru';
  String get locale => _locale ?? defaultLocale;
  static Iterable<String> get translationKeys => {
    ..._catalogs['ru']!.keys,
    ...diagnosticStrings.keys,
    ...engineStrings.keys,
    ...mihomoNativeHelpKeys,
    for (final family in ['S', 'H', 'I'])
      for (var index = 1; index <= 4; index++) 'awg.$family$index.help',
    'awg.I5.help',
  };
  String call(String key, [Map<String, Object> values = const {}]) {
    var message =
        (locale == 'en' ? englishStrings[key] : null) ??
        _catalogs['ru']![key] ??
        mihomoNativeText(key, english: locale == 'en') ??
        engineText(key, english: locale == 'en') ??
        diagnosticText(key) ??
        key;
    for (final entry in values.entries) {
      message = message.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return message;
  }

  static const _catalogs = {
    'ru': {
      'builder.route': 'Маршрут',
      'builder.routeAdd': 'Добавить узел',
      'builder.routeRemove': 'Убрать узел',
      'builder.routeIngress': 'Вход',
      'builder.routeTransit': 'Транзит',
      'builder.routeEgress': 'Выход',
      'builder.routeHelp':
          'Первый узел принимает подключения. По умолчанию трафик проходит через все узлы. Для удалённого входа через mihomo с TLS укажите свой сертификат.',
      'routing.title': 'Правила маршрутизации',
      'nav.routing': 'Маршрутизация',
      'routing.noConnections': 'На этой ноде пока нет подключений.',
      'routing.connection': 'Подключение',
      'routing.link': 'Из {from} через {to}, порт {port}',
      'routing.packetHelp':
          'AmneziaWG применяет правила к IPv4-пакетам. Можно указать IP, порт или TCP/UDP. Срабатывает первое совпадение сверху вниз.',
      'routing.help':
          'Срабатывает первое совпадение сверху вниз. Без совпадений используется действие по умолчанию. Прямой трафик выходит с IP текущего узла. На входе общие правила доступа ядра проверяются первыми.',
      'routing.local': 'Этот сервер',
      'routing.direct': 'Напрямую с этого узла',
      'routing.block': 'Блокировать',
      'routing.forward': 'Через {node}',
      'routing.next': 'По маршруту через {node}',
      'routing.fallback': 'Действие по умолчанию',
      'routing.add': 'Добавить правило',
      'routing.type': 'Условие',
      'routing.target': 'Назначение',
      'routing.action': 'Действие',
      'routing.domain': 'Точный домен',
      'routing.suffix': 'Домен и поддомены',
      'routing.wildcard': 'Маска домена',
      'routing.keyword': 'Часть домена',
      'routing.geosite': 'GeoSite · группы доменов',
      'routing.cidr': 'IP или сеть (CIDR)',
      'routing.geoip': 'GeoIP · группы IP',
      'routing.port': 'Порт назначения',
      'routing.network': 'TCP или UDP',
      'routing.help.domain': 'Укажите имя хоста без схемы и пути.',
      'routing.help.suffix':
          'example.com включает сам домен и все его поддомены.',
      'routing.help.wildcard':
          '* заменяет любую часть имени. *.example.com включает поддомены, а example.com добавляется отдельно.',
      'routing.help.keyword':
          'Совпадает, если имя хоста содержит этот фрагмент.',
      'routing.help.geosite':
          'Введите название группы доменов из базы ядра, например youtube или category-ads-all.',
      'routing.help.cidr': 'Укажите один IP или сеть с длиной префикса.',
      'routing.help.geoip':
          'Введите код страны из двух букв, например ru, или private для локальных адресов.',
      'routing.help.port': 'Укажите порт назначения от 1 до 65535.',
      'routing.help.list':
          'До {count} значений через запятую. Достаточно любого совпадения.',
      'routing.up': 'Поднять правило',
      'routing.down': 'Опустить правило',
      'routing.remove': 'Удалить правило',
      'routing.missingNode': 'Выберите доступное действие',
      'routing.review': 'Узлов с настройками: {nodes}, правил: {rules}',
      'routing.links': 'Порты дополнительных переходов (TCP и UDP)',
      'runtime.error.route_policy_invalid':
          'Проверьте условия и действия правил. Передать трафик можно только узлу дальше по маршруту.',
      'runtime.error.route_geo_unknown':
          'Группа GeoSite или GeoIP отсутствует в базе. Проверьте её название.',
      'runtime.error.route_geo_unavailable':
          'Не удалось загрузить базу GeoSite или GeoIP. Проверьте доступ сервера к GitHub и повторите сохранение.',
      'runtime.error.route_policy_conflict':
          'У подключения уже задано собственное правило или выход в настройках ядра. Сбросьте его, чтобы использовать правила панели.',
      'servers.bootstrap': 'Установить по SSH',
      'servers.bootstrapUser': 'Логин SSH',
      'servers.bootstrapAuth': 'Доступ SSH',
      'servers.bootstrapKey': 'Приватный ключ SSH',
      'servers.bootstrapPassword': 'Пароль SSH',
      'servers.bootstrapHelp':
          'Укажите root или пользователя с sudo без пароля. Панель установит mihomo и зарегистрирует свой ключ. Введённый доступ используется только для установки.',
      'servers.error.server_bootstrap_invalid':
          'Укажите логин и один способ доступа SSH.',
      'servers.error.server_bootstrap_arch':
          'Для архитектуры узла нет проверенного пакета mihomo. Установите узел вручную.',
      'servers.error.server_bootstrap_unavailable':
          'Файлы установщика недоступны в этой сборке Sky UI.',
      'servers.error.route_node_in_use':
          'Узел используется в маршруте или ожидает завершения восстановления.',
      'runtime.error.route_invalid':
          'Проверьте маршрут. Каждый сервер может встречаться один раз, порт входа должен быть от 1024.',
      'runtime.error.route_node_missing':
          'Узел маршрута недоступен в списке серверов.',
      'runtime.error.route_address_unavailable':
          'Не удалось определить адрес для связи между узлами.',
      'runtime.error.route_protocol_unsupported':
          'Выберите текущий сервер первым узлом или используйте mihomo для удалённого входа. Для TLS на удалённом входе нужен свой сертификат.',
      'runtime.error.route_node_protocol':
          'Узел нужно обновить через «Установить по SSH».',
      'runtime.error.route_requires_rule_mode':
          'Настройки маршрутизации mihomo конфликтуют с каскадом.',
      'runtime.error.route_configuration_out_of_sync':
          'Конфиг на VPS отличается от ожидаемого. Проверьте узел.',
      'runtime.error.route_configuration_too_large':
          'Конфиг удалённого узла превышает лимит.',
      'runtime.error.route_diagnostics_unavailable':
          'Удалённая диагностика входа недоступна.',
      'runtime.error.server_ssh_failed':
          'Не удалось подключиться к узлу по SSH.',
      'runtime.error.server_operation_failed':
          'Узел не смог применить конфиг. Проверьте состояние и логи на сервере.',
      'runtime.error.server_busy': 'Дождитесь завершения операции на узле.',
      'runtime.error.route_link_unreachable':
          'Переход между узлами недоступен. Проверьте IP и правила firewall для порта каскада.',
      'status.deployed': 'Применено',
      'nav.servers': 'Серверы',
      'servers.title': 'Серверы',
      'servers.local': 'Сервер панели',
      'servers.disabled':
          'Чтобы включить удалённое управление, добавьте SKY_UI_REMOTE_SERVERS=enabled в /etc/sky-ui/server.env и перезапустите Sky UI.',
      'servers.add': 'Добавить сервер',
      'servers.name': 'Название',
      'servers.host': 'Хост SSH',
      'servers.endpoint': 'Адрес для клиентов (опционально)',
      'servers.relayAddress': 'IP для связи узлов (опционально)',
      'servers.port': 'Порт SSH',
      'servers.hostKey': 'Ключ сервера SSH',
      'servers.hostKeyHelp':
          'Возьмите первые два поля из /etc/ssh/ssh_host_ed25519_key.pub через консоль VPS.',
      'servers.enrollmentHelp':
          'Передайте этот публичный ключ установщику узла и нажмите «Проверить».',
      'servers.status': 'Проверить',
      'servers.start': 'Запустить',
      'servers.stop': 'Остановить',
      'servers.restart': 'Перезапустить',
      'servers.logs': 'Логи',
      'servers.emptyLogs': 'Логи пусты',
      'servers.remove': 'Удалить',
      'servers.removeHelp':
          'Удалить сервер из панели? Сервис продолжит работать. Для отзыва ключа удалите /var/lib/sky-ui-node/.ssh/authorized_keys на VPS.',
      'servers.state.active': 'Работает',
      'servers.state.inactive': 'Остановлен',
      'servers.state.failed': 'Ошибка сервиса',
      'servers.state.activating': 'Запускается',
      'servers.state.deactivating': 'Останавливается',
      'servers.state.reloading': 'Перезагружается',
      'servers.state.maintenance': 'Обслуживание',
      'servers.state.refreshing': 'Обновляется',
      'servers.error.server_invalid':
          'Проверьте название, адрес, порт и ключ SSH.',
      'servers.error.server_duplicate': 'Этот SSH-адрес уже добавлен.',
      'servers.error.server_limit': 'Достигнут лимит серверов.',
      'servers.error.server_busy': 'Дождитесь завершения текущей операции.',
      'servers.error.server_key_failed': 'Не удалось создать ключ узла.',
      'servers.error.server_ssh_failed':
          'SSH не подключился. Проверьте адрес, ключ хоста и установку узла.',
      'servers.error.server_operation_failed': 'Узел не выполнил операцию.',
      'servers.error.command_unavailable':
          'На сервере панели недоступен OpenSSH.',
      'servers.error.command_timeout': 'Узел не ответил вовремя.',
      'servers.error.api_unavailable': 'API панели недоступен.',
      'servers.error.maintenance_busy':
          'Дождитесь завершения обслуживания панели.',
      'servers.error.generic': 'Не удалось выполнить операцию.',
      'coreSettings.title': 'Настройки ядра',
      'coreSettings.forCore': 'Настройки {core}',
      'coreSettings.group.dns': 'DNS',
      'coreSettings.group.access': 'Доступ',
      'coreSettings.group.logs': 'Логи',
      'coreSettings.dnsMode': 'Разрешение имён',
      'coreSettings.resolvers': 'DNS-серверы',
      'coreSettings.resolver': 'DNS-сервер',
      'coreSettings.help.sing-box.resolvers':
          'Один основной сервер: 1.1.1.1, udp://1.1.1.1:53, https://dns.google/dns-query или tls://one.one.one.one. Имена резолверов разрешаются системным DNS. Сертификаты DoH и DoT проверяются. sing-box не переключается между списком серверов автоматически, поэтому здесь выбирается один сервер.',
      'coreSettings.help.xray.resolvers':
          'До 16 серверов, по одному на строку: 1.1.1.1, udp://1.1.1.1:53, tcp://1.1.1.1:53 или https://dns.google/dns-query. Для UDP и TCP указывай IP, для DoH можно имя. DoH и TCP используют прямое подключение ядра. Сертификаты DoH проверяются. Обычный DoT этой версией Xray не поддерживается.',
      'coreSettings.help.sing-box.logLevel':
          'Уровень логирования самого sing-box: выбранный уровень и более важные. disabled полностью отключает логи ядра. trace и debug нужны для диагностики и могут содержать адреса запросов. Фильтры во вкладке Логи работают отдельно.',
      'coreSettings.help.xray.logLevel':
          'Уровень логирования самого Xray: выбранный уровень и более важные. none отключает access и error логи. При включении восстанавливаются их прежние пути. debug может содержать адреса запросов. Фильтры во вкладке Логи работают отдельно.',
      'coreSettings.blockPrivate': 'Блокировать внутренние адреса',
      'coreSettings.accessRules': 'Правила доступа',
      'coreSettings.ruleType': 'Тип',
      'coreSettings.target': 'Адрес',
      'coreSettings.ruleAction': 'Действие',
      'coreSettings.logLevel': 'Уровень логирования ядра',
      'coreSettings.apply': 'Применить',
      'coreSettings.applying': 'Применяем…',
      'coreSettings.applyHint':
          'Работающее ядро кратко перезапустится. При ошибке вернутся предыдущие настройки.',
      'coreSettings.help.dnsMode':
          'Исходная конфигурация сохраняет DNS, который был до настройки через панель. Системный DNS использует резолверы Linux. Свои серверы заменяют DNS-политику ядра. DNS-порт наружу не открывается.',
      'coreSettings.help.resolvers':
          'По одному серверу на строку, до 16. Например: 1.1.1.1, https://dns.google/dns-query или tls://one.one.one.one. Имена DNS-серверов сначала разрешаются системным DNS. DoH и DoT проверяют сертификаты.',
      'coreSettings.help.blockPrivate':
          'Запрещает получателям подключения Sky UI доступ к loopback, частным сетям, link-local и cloud metadata, включая IPv6. Публичный IP сервера сюда не входит. Это правила прокси, а не firewall всей машины. Новые правила применяются к новым соединениям после перезапуска.',
      'coreSettings.help.accessRules':
          'До 64 правил сверху вниз. Домен включает поддомены, IP задаётся в CIDR. Первое совпадение определяет действие. Защита внутренних адресов проверяется раньше этих правил. Разрешить означает DIRECT; остальные адреса используют прежний маршрут подключения.',
      'coreSettings.help.ruleType':
          'Домен с поддоменами или IP-сеть в формате CIDR.',
      'coreSettings.help.target':
          'Без протокола и порта: example.com, 203.0.113.0/24 или 2001:db8::/32. Доменное правило работает, когда клиент передаёт имя; оно не блокирует прямое обращение к IP этого сайта.',
      'coreSettings.help.ruleAction':
          'Блокировать отклоняет совпавшие запросы. Разрешить отправляет их напрямую. Порядок правил важен.',
      'coreSettings.help.logLevel':
          'Меняет записи, которые создаёт само ядро: выбранный уровень и более важные. debug нужен для диагностики и может содержать адреса запросов. silent отключает логи ядра. Галочки во вкладке Логи фильтруют уже полученные записи отдельно.',
      'builder.choice.dnsMode.existing': 'Исходная конфигурация',
      'builder.choice.dnsMode.system': 'Системный DNS',
      'builder.choice.dnsMode.custom': 'Свои DNS-серверы',
      'builder.choice.type.domain': 'Домен',
      'builder.choice.type.cidr': 'IP / CIDR',
      'builder.choice.action.block': 'Блокировать',
      'builder.choice.action.allow': 'Разрешить',
      'runtime.error.core_settings_unavailable':
          'Настройки этого ядра пока недоступны.',
      'runtime.error.core_settings_routing_conflict':
          'Настройки доступа конфликтуют со сторонней маршрутизацией ядра. Проверьте режим, IP-правила и routing script в исходной конфигурации. Изменения не применены.',
      'common.loading': 'Загрузка…',
      'common.refresh': 'Обновить',
      'share.clashSubscription': 'Подписка · Clash Verge / mihomo',
      'share.v2raySubscription': 'Подписка · V2Box / V2Ray',
      'core.feedback.validate':
          'Конфигурация проверена ядром. Ошибок не найдено. Подключения не проверялись, служба не перезапускалась.',
      'core.feedback.start': 'Ядро запущено.',
      'core.feedback.stop': 'Ядро остановлено.',
      'core.feedback.restart': 'Ядро перезапущено.',
      'core.updatesChecking': 'Проверяем список проверенных версий Sky UI…',
      'core.updatesNone': 'Проверенных обновлений нет.',
      'core.updatesAvailable': 'Доступна проверенная версия ядра.',
      'runtime.error.catalog_unavailable':
          'Список проверенных версий Sky UI недоступен. Обновление отключено.',
      'runtime.error.core_release_unverified':
          'Эта версия ядра не проверена для установленной версии Sky UI и платформы. Обновление запрещено.',
      'maintenance.backups': 'Резервные копии',
      'maintenance.create': 'Создать копию',
      'maintenance.download': 'Скачать',
      'maintenance.restore': 'Восстановить',
      'maintenance.empty': 'Резервных копий пока нет.',
      'maintenance.secrets':
          'Копия содержит ключи и данные доступа. Храни скачанный архив в защищённом месте.',
      'maintenance.backupHint':
          'Сохранить пользователей, подключения, настройки, администратора и сертификаты? Панель кратко перезапустится. Ядро продолжит работу.',
      'maintenance.restoreHint':
          'Заменить текущее состояние этой копией? Перед восстановлением автоматически создаётся страховочная копия. Службы перезапустятся, потребуется заново войти. Восстановление доступно на этом сервере для той же версии панели.',
      'maintenance.updateHint':
          'Версия проверена для Sky UI. Перед установкой проверим актуальную отметку в каталоге проекта, SHA-256 файла и текущую конфигурацию. Работающее ядро кратко перезапустится. При сбое вернётся предыдущая версия.',
      'maintenance.loading': 'Проверяем список Sky UI…',
      'maintenance.status.queued': 'Операция ожидает запуска…',
      'maintenance.status.running':
          'Операция выполняется. Панель автоматически подключится снова.',
      'maintenance.status.completed': 'Операция завершена.',
      'runtime.error.maintenance_unavailable':
          'Не удалось запустить обслуживание Sky UI. Проверьте состояние службы и логи панели.',
      'runtime.error.maintenance_busy':
          'Дождись завершения текущего обслуживания.',
      'runtime.error.maintenance_failed':
          'Операция не выполнена. Проверь логи службы обслуживания.',
      'runtime.error.maintenance_interrupted':
          'Операция была прервана. Сохранённое состояние восстановлено.',
      'runtime.error.update_rolled_back':
          'Ядро не прошло проверку запуска. Возвращена предыдущая версия.',
      'runtime.error.restore_rolled_back':
          'Восстановление не прошло проверку. Возвращено прежнее состояние.',
      'runtime.error.release_changed':
          'Последний релиз изменился. Проверь обновления ещё раз.',
      'runtime.error.release_checksum_failed':
          'Контрольная сумма загрузки не совпала. Ядро не изменено.',
      'runtime.error.release_checksum_missing':
          'У релиза нет SHA-256. Обновление не выполнено.',
      'runtime.error.backup_version_mismatch':
          'Для восстановления нужна та же версия панели, что в копии.',
      'runtime.error.backup_checksum_failed':
          'Копия повреждена: контрольная сумма не совпала.',
      'runtime.error.backup_wrong_host': 'Эта копия создана на другом сервере.',
      'runtime.error.backup_invalid': 'Не удалось проверить резервную копию.',
      'runtime.error.backup_incomplete':
          'В копии не хватает обязательных данных.',
      'runtime.error.backup_too_large':
          'Копия превышает допустимый размер 128 MB.',
      'runtime.error.api_not_ready':
          'Панель не запустилась после обслуживания. Доступно восстановление через SSH.',
      'builder.recommended': 'RECOMMEND',
      'builder.engineInstalled': 'Установлено',
      'builder.engineRequired': 'Потребуется установка',
      'builder.installRequired':
          'Для подключения нужно установить это ядро. После установки продолжим настройку.',
      'builder.installContinue': 'Установить и продолжить',
      'builder.installChecking': 'Ищем совместимую сборку…',
      'builder.installing': 'Устанавливаем…',
      'builder.step.dependency': 'Установка',
      'builder.planned': 'Планируется',
      'protocol.naive':
          'Передача через HTTPS с клиентом на сетевом стеке Chromium. Нужен сертификат сервера.',
      'protocol.naive.details':
          'NaiveProxy использует HTTP/2 или HTTP/3 CONNECT. Для подключения нужен совместимый клиент NaiveProxy; VLESS-клиент сам по себе этот протокол не заменяет. Панель настроит пользователей и TLS в выбранном серверном ядре.',
      'protocol.amneziawg':
          'VPN-туннель AmneziaWG 3.1 с маскировкой пакетов. Нужен совместимый клиент версии 3.1.',
      'protocol.amneziawg.details':
          'AmneziaWG 3.1 создаёт сетевой туннель и выдаёт каждому получателю собственный ключ и адрес. Нужны TUN-интерфейс и маршрутизация на сервере. Поддержка обычного WireGuard не означает поддержку AmneziaWG 3.1. Профиль выдаётся в родном формате AmneziaWG.',
      'builder.guide.vless.TCP':
          'Для первого подключения к личному серверу начни с TCP + REALITY. Дополнительный HTTP-прокси и свой сертификат подключения не требуются.\nВыбери REALITY. На шаге «Параметры» оставь Flow xtls-rprx-vision и укажи подходящий SNI. Ключи и настройки клиента подготовит панель.',
      'builder.guideTitle': 'Как настроить',
      'builder.guide.TCP':
          'Прямое соединение с сервером — удобный старт для личного использования. Дополнительный HTTP-прокси не требуется.\nДалее настрой защиту, доступную для выбранного протокола. Если используется TLS, потребуется сертификат сервера.',
      'builder.guide.WebSocket':
          'Выбирай для схемы, где трафик проходит через WebSocket-совместимый обратный прокси или CDN. Для прямого подключения можно начать с TCP.\nОставь Path /connect. Если используешь прокси, направь этот путь на порт подключения и включи передачу WebSocket Upgrade. На следующем шаге настрой TLS.',
      'builder.guide.gRPC':
          'Передаёт данные потоками HTTP/2. Подходит для схемы с обратным прокси, который умеет пропускать gRPC.\nОставь имя сервиса tunnel. Если между клиентом и ядром есть прокси, его маршрут должен использовать это же имя. Далее выбери сертификат TLS.',
      'builder.guide.XHTTP':
          'Передаёт данные HTTP-запросами и потоками. Можно подключаться напрямую или через совместимый обратный прокси/CDN.\nНачни с Path /connect и Mode auto. Затем выбери сертификат TLS. Для схемы с прокси отдельно настрой передачу выбранного пути на порт подключения.',
      'builder.guide.UDP':
          'Выбирай, когда сеть и клиент поддерживают UDP для этого протокола. При ограничениях UDP попробуй TCP. Остальные параметры протокола панель предложит на следующих шагах.',
      'builder.guide.TCP + QUIC':
          'Разрешает оба способа подключения на одном порту: TCP и QUIC через UDP. Сеть сервера должна пропускать оба типа трафика. Для первого подключения можно выбрать TCP.',
      'builder.inline.native.xhttp-config.path':
          'Путь в HTTP-запросах, например /connect. Это не папка на сервере. Можно оставить значение по умолчанию — панель перенесёт его в подписку.',
      'builder.inline.native.xhttp-config.mode.auto':
          'Рекомендуемый старт: клиент автоматически выберет режим передачи. Оставь auto, если у твоей схемы нет особых требований.',
      'builder.inline.native.xhttp-config.mode.packet-up':
          'Данные от клиента идут отдельными HTTP-запросами, ответ — потоком. Используй для схемы, рассчитанной на packet-up; иначе начни с auto.',
      'builder.inline.native.xhttp-config.mode.stream-up':
          'Отправка и получение используют отдельные потоки. Промежуточный прокси должен поддерживать потоковую отправку без буферизации.',
      'builder.inline.native.xhttp-config.mode.stream-one':
          'Оба направления используют один HTTP-поток. Требует поддержки такого режима клиентом и промежуточным прокси. Для обычного старта оставь auto.',
      'builder.inline.native.xhttp-config.host':
          'При прямом подключении оставь пустым. Заполняй, если обратный прокси ожидает конкретный HTTP Host. Имя сертификата TLS настраивается отдельно через SNI.',
      'builder.inline.native.ws-path':
          'Оставь /connect. При использовании обратного прокси этот же путь должен вести на порт подключения и пропускать WebSocket Upgrade.',
      'builder.inline.native.grpc-service-name':
          'Оставь tunnel. Это имя маршрута gRPC, а не название сайта; при наличии обратного прокси оно должно совпадать с его настройкой.',
      'builder.choice.native.xhttp-config.mode.auto': 'auto — автоматически',
      'builder.choice.native.xhttp-config.mode.packet-up':
          'packet-up — отдельные запросы',
      'builder.choice.native.xhttp-config.mode.stream-up':
          'stream-up — отдельные потоки',
      'builder.choice.native.xhttp-config.mode.stream-one':
          'stream-one — один поток',
      'builder.unavailableClash': 'Нет профиля Clash',
      'builder.default': 'По умолчанию',
      'error.interface_in_use': 'Имя сетевого интерфейса уже занято.',
      'field.realmToken': 'Realm token',
      'help.realmToken':
          'Общий ключ координатора Realm и его участников. Задайте длинное случайное значение и используйте его в Realm-настройках Hysteria 2. Это техническая авторизация координатора; получатели по-прежнему имеют отдельные пароли VPN.',
      'field.alterId': 'VMess alterId',
      'help.alterId':
          'Legacy-идентификаторы VMess. Для современных клиентов оставляйте 0: используется AEAD. Меняйте только для совместимости со старым клиентом.',
      'builder.systemInput':
          'Этот вход настраивает сетевую функцию сервера и не назначается получателям.',
      "field.certificateSource": "Сертификат TLS",
      "help.certificateSource":
          "Используйте сертификат панели с автоматическим продлением Let’s Encrypt или собственную пару PEM. Сертификат панели доступен после настройки HTTPS и первого выпуска.",
      "field.certificateId": "Сертификат",
      "help.certificateId":
          "Сертификат панели следует за её основным адресом. Можно выбрать отдельный выпущенный сертификат IP/домена. SNI подставится автоматически; после смены домена обновите подписки клиентов.",
      "field.tlsCertificate": "Сертификат и цепочка PEM",
      "help.tlsCertificate":
          "Полная PEM-цепочка сервера: сначала его сертификат, затем промежуточные CA. Имя сервера должно соответствовать сертификату. Сервер проверит формат и пару ключей перед сохранением.",
      "field.tlsPrivateKey": "Приватный ключ PEM",
      "help.tlsPrivateKey":
          "Приватный ключ выбранного серверного сертификата. Хранится только на сервере и не попадает в подписку. При редактировании пустое поле сохраняет существующий ключ.",
      "field.handshakePort": "Handshake port",
      "help.handshakePort":
          "Порт TLS-сервиса маскировки, обычно 443. Используется вместе с именем сервера; выбранный сервис должен поддерживать нужное рукопожатие.",
      "field.clientFingerprint": "TLS client fingerprint",
      "help.clientFingerprint":
          "Шаблон ClientHello браузера: Chrome, Firefox и другие. Это форма TLS-рукопожатия, а не fingerprint сертификата. Должен поддерживаться клиентом.",
      "field.clientAlpn": "Client ALPN",
      "help.clientAlpn":
          "Дополнительный список ALPN клиента, по одному на строку. Обычно оставляйте автоматический выбор транспорта; gRPC использует h2, WebSocket — http/1.1.",
      "field.clientCipher": "VMess cipher",
      "help.clientCipher":
          "Шифрование VMess со стороны клиента. Auto выбирает подходящий вариант. None/zero отключают соответствующий внутренний слой и требуют осознанной настройки защиты транспорта.",
      "field.clientCertificate": "Сертификат клиента PEM",
      "help.clientCertificate":
          "Отдельный TLS-сертификат получателя для mTLS. Его публичная часть/CA должны приниматься сервером. Включается в клиентский профиль вместе с клиентским ключом.",
      "field.clientPrivateKey": "Приватный ключ клиента PEM",
      "help.clientPrivateKey":
          "Ключ отдельного клиентского сертификата. Это клиентские учётные данные: они будут включены в профиль получателя. Не вставляйте сюда приватный ключ серверного сертификата.",
      "field.clientEchConfig": "Client ECH config",
      "help.clientEchConfig":
          "Публичный base64 ECH config, соответствующий приватному ECH-ключу сервера. Включается в профиль клиента. Пустое значение оставляет ECH выключенным на клиенте.",
      "field.vlessEncryption": "VLESS encryption",
      "help.vlessEncryption":
          "Дополнительное шифрование VLESS. X25519MLKEM768 создаёт ключи автоматически; клиент должен поддерживать эту возможность. Это отдельный слой от TLS/REALITY.",
      "field.routingProxy": "Outbound",
      "help.routingProxy":
          "Куда ядро направляет трафик этого входа: обычно DIRECT. Другое имя должно уже существовать в конфигурации ядра.",
      "field.routingRule": "Rule set",
      "help.routingRule":
          "Имя существующего набора правил ядра для этого входа. Пустое значение оставляет стандартную обработку; поле не создаёт правила.",
      "field.routingMark": "Routing mark",
      "help.routingMark":
          "Linux socket/packet mark для исходящего трафика входа. Нужна только для подготовленной схемы policy routing.",
      "builder.addRow": "Добавить строку",
      "builder.secretStored": "Сохранено — оставить без изменения",
      "builder.networkRightsRequired": "Нужны сетевые права Linux",
      "builder.choice.certificateSource.panel": "Сертификат панели",
      "builder.choice.certificateSource.panel.help":
          "IP/домен панели, Let’s Encrypt и автоматическое продление. После выпуска сертификата ядро подхватит обновление без перезапуска.",
      "builder.choice.certificateSource.custom": "Свой сертификат",
      "builder.choice.certificateSource.custom.help":
          "Вставьте серверный сертификат с цепочкой и его приватный ключ в PEM. В таком режиме обновлением сертификата управляете вы.",
      "builder.choice.certificateId.panel": "Основной адрес панели",
      "builder.choice.security.Built-in": "Встроенное шифрование",
      "builder.choice.security.Built-in.help":
          "Протокол уже шифрует данные. Дополнительный TLS-слой для обычного подключения не требуется.",
      "builder.choice.security.ShadowTLS.help":
          "Маскирует рукопожатие под TLS выбранного сайта. В версии 3 добавляет авторизацию маскирующего слоя. Нужен совместимый клиент и доступный TLS upstream.",
      "builder.choice.security.Restls.help":
          "Маскировка под TLS с настраиваемой последовательностью records. Требует доступного TLS-сервиса и совместимого клиента; основные ключи создаются автоматически.",
      "builder.choice.security.JLS.help":
          "Авторизованный слой маскировки TLS. Нужен поддерживающий его клиент и подходящий upstream; данные авторизации попадут в профиль.",
      "builder.choice.security.TLSMirror.help":
          "Маскировка с использованием TLS-сервиса как carrier. Требует совместимого клиента и подходящих TLS cipher suites upstream.",
      "builder.choice.transport.UDP.help":
          "Передача через UDP. Может подходить сетям с потерями/блокировками TCP, но сам UDP иногда ограничивается провайдером.",
      "builder.choice.transport.QUIC.help":
          "Транспорт на UDP с защищёнными потоками и управлением перегрузкой. Серверный UDP-порт должен быть доступен извне.",
      "builder.choice.transport.KCP.help":
          "Надёжный поток поверх UDP для Shadowsocks. Нужен клиент с поддержкой kcptun; параметры должны совпадать.",
      "builder.choice.transport.mKCP.help":
          "Транспорт VMess поверх UDP. Может помогать при потерях пакетов ценой дополнительного трафика и нагрузки CPU.",
      "builder.choice.transport.Mekya.help":
          "HTTP-транспорт VMess с внутренним KCP. Нужен современный совместимый mihomo; дополнительные параметры обычно можно оставить стандартными.",
      "builder.choice.transport.TCP + UDP.help":
          "Принимать TCP и UDP на одном номере порта. Оба вида трафика должны быть разрешены в firewall.",
      "builder.choice.transport.TCP + QUIC.help":
          "Принимать TrustTunnel по TCP и QUIC. Клиентский профиль выбирает поддерживаемый путь; доступны оба транспорта.",
      "builder.choice.transport.IP.help":
          "Обработка IP-пакетов через системный виртуальный интерфейс. Это настройка сети сервера, не протокол для выдачи подписки.",
      "builder.error.certificate_invalid":
          "Сертификат или ключ некорректны либо не подходят друг другу.",
      "builder.profileUnavailable":
          "Для этой комбинации профиль Clash недоступен. Нужен клиент, поддерживающий выбранный вариант.",
      "builder.profileOnly":
          "Выдавайте доступ подпиской или её QR-кодом. Отдельная ссылка протокола не создаётся.",
      "builder.isolatedPorts":
          "Каждый получатель получит отдельный порт и ключ. Они включаются в подписку автоматически.",
      'protocol.masque.details':
          'MASQUE использует HTTP-механизмы для туннелирования. Доступность и настройки определяются выбранным ядром и клиентом.',
      'protocol.masque': 'Туннелирование через поддерживаемый HTTP-транспорт.',
      'protocol.wireguard.details':
          'Поддержка входящего WireGuard зависит от ядра. Требует адресов туннеля и согласованных ключей; профиль отличается от обычной прокси-ссылки.',
      'protocol.wireguard': 'IP-туннель WireGuard с ключами узлов.',
      'protocol.tailcat.details':
          'Служебный режим выбранного ядра для работы с сетью Tailscale. Не является обычным подключением VLESS или SOCKS.',
      'protocol.tailcat': 'Вход интеграции с сетью Tailscale.',
      'protocol.cloudflared.details':
          'Предназначен для поддерживаемой ядром интеграции с Cloudflare Tunnel. Требует отдельной конфигурации соответствующей службы.',
      'protocol.cloudflared': 'Служебный вход Cloudflare Tunnel.',
      'protocol.shadowtls.details':
          'ShadowTLS защищает и маскирует транспорт, но не заменяет внутренний прокси-протокол. Версия и ключи должны совпадать с клиентом.',
      'protocol.shadowtls': 'Маскировка TLS для другого протокола.',
      'protocol.hysteria.details':
          'Требует UDP и совместимого клиента Hysteria v1. Не совместима с Hysteria 2; выбирайте версию клиента, а не похожее название.',
      'protocol.hysteria': 'Первая версия Hysteria через QUIC.',
      'protocol.direct.details':
          'Назначение и поведение зависят от выбранного ядра. Это служебный вход, а не универсальный VPN-протокол с собственной защитой.',
      'protocol.direct': 'Вход для передачи трафика на заданное назначение.',
      'protocol.tunnel.details':
          'Служебный вход пересылает трафик на фиксированный адрес назначения. Это не протокол с собственной проверкой получателей. Обычно используется для локальных связок; адрес прослушивания и доступность порта определяют, кто сможет им воспользоваться.',
      'protocol.tunnel': 'Перенаправление TCP или UDP на заданный адрес.',
      'protocol.tun.details':
          'TUN направляет выбранный IP-трафик в ядро через виртуальный интерфейс. Нужны разрешения системы и настройки маршрутов. Может затронуть сеть самого сервера. Это системный режим, а не протокол подключения клиента.',
      'protocol.tun': 'Виртуальный сетевой интерфейс для захвата трафика.',
      'protocol.tproxy.details':
          'Принимает трафик, направленный Linux TProxy с сохранением исходного назначения. Требует сетевых прав и согласованных правил маршрутизации. Используется для управления трафиком сервера или сети, а не для выдачи персональной ссылки.',
      'protocol.tproxy': 'Прозрачный системный вход для TCP и UDP.',
      'protocol.redirect.details':
          'Служебный вход для Linux-перенаправления трафика. Нужны соответствующие правила сети. Не выдаётся людям в виде обычной ссылки и не является отдельным зашифрованным VPN-протоколом.',
      'protocol.redirect':
          'Системный перехват перенаправленных TCP-соединений.',
      'protocol.mixed.details':
          'Автоматически распознаёт HTTP-прокси и SOCKS на одном порту. Удобен, когда разные приложения используют разные типы прокси. Получатели имеют отдельные учётные данные. Шифрование зависит от выбранной защиты транспорта.',
      'protocol.mixed': 'Один вход для HTTP и SOCKS.',
      'protocol.socks.details':
          'Подходит для приложений, поддерживающих SOCKS. SOCKS5 умеет TCP и UDP при поддержке клиента. Сам SOCKS не шифрует канал до сервера: для недоверенной сети выбирайте совместимую защиту транспорта.',
      'protocol.socks': 'SOCKS-прокси с проверкой имени и пароля.',
      'protocol.http.details':
          'Подходит для приложений с настройкой HTTP-прокси. HTTPS-сайты проходят через CONNECT. TLS на самом входе дополнительно защищает канал между клиентом и прокси; без него не следует передавать учётные данные через недоверенную сеть.',
      'protocol.http': 'HTTP-прокси с именем и паролем.',
      'protocol.shadowquic.details':
          'Использует UDP, учётные данные получателя и JLS upstream для маскировки рукопожатия. Параметры QUIC и совместимость зависят от версии mihomo на обеих сторонах. Обычный профиль Hysteria или TUIC для него не подходит.',
      'protocol.shadowquic': 'QUIC-туннель с маскировкой JLS.',
      'protocol.hysteria2-realm.details':
          'Это вспомогательный сервер Realm для обнаружения и согласования соединений. Он не заменяет обычный вход Hysteria 2 и не является универсальным подключением для раздачи людям. Используется только в соответствующей схеме Realm.',
      'protocol.hysteria2-realm':
          'Служебный сервер координации Hysteria 2 Realm.',
      'protocol.hysteria2.details':
          'Работает через UDP с TLS и паролем получателя. Поддерживает маскировку UDP и несколько режимов контроля перегрузки. Пропускная способность — параметр работы протокола, а не квота пользователя. Поддерживается Clash Verge; UDP должен быть доступен.',
      'protocol.tuic.details':
          'Использует UDP и TLS, поддерживает TCP-трафик и UDP-релей внутри туннеля. Панель создаёт UUID и пароль получателя. Параметры контроля перегрузки влияют на поведение при потерях и задержках. Нужен клиент TUIC v5.',
      'protocol.tuic-v4.details':
          'Использует UDP, TLS и отдельный токен получателя. Версии TUIC v4 и v5 несовместимы: выбирайте вариант своего клиента. Подходит для сетей, где UDP не блокируется. Сертификат должен соответствовать адресу сервера.',
      'protocol.tuic-v4': 'QUIC-вход для клиентов TUIC v4.',
      'protocol.trusttunnel.details':
          'TrustTunnel использует имя и пароль получателя и сертификат сервера. TCP и QUIC выбирают согласно поддержке клиента и доступности UDP в сети. Не путайте протокол с обычным HTTP-прокси.',
      'protocol.trusttunnel': 'Туннель через HTTP/2 и HTTP/3 с TLS.',
      'protocol.sudoku.details':
          'Sudoku сочетает ключ, AEAD и кодирование трафика. Дополнительные параметры управляют padding и HTTP-маскировкой. Для независимого отзыва доступа панель создаёт отдельный вход каждому получателю. Поддержка зависит от версии клиента.',
      'protocol.sudoku': 'Шифрование и настраиваемая маскировка трафика.',
      'protocol.mieru.details':
          'Mieru использует имя и пароль получателя, поддерживает TCP и UDP и настраиваемый профиль трафика. Клиент должен поддерживать выбранную версию протокола. Сертификат TLS для собственного шифрования Mieru не требуется.',
      'protocol.mieru': 'Зашифрованное соединение через TCP или UDP.',
      'protocol.snell.details':
          'Snell имеет несколько несовместимых версий. Выберите версию, которую поддерживает клиент. В mihomo вход использует один PSK; панель выдаёт каждому получателю свой порт и ключ. Совместимость с конкретной версией Clash Verge следует проверять по её встроенному ядру.',
      'protocol.snell': 'Зашифрованный прокси с общим ключом входа.',
      'protocol.anytls.details':
          'Подходит для клиентов с поддержкой AnyTLS. Использует пароль получателя, защищённый транспорт и схему padding. Padding меняет размеры передаваемых блоков. Поддержка зависит от версии ядра клиентского приложения.',
      'protocol.anytls': 'Прокси через TLS с управлением размером пакетов.',
      'protocol.shadowsocks.details':
          'Встроенное шифрование обычно не требует домена и сертификата. Совместимость зависит от выбранного шифра. В mihomo этот вход использует один ключ, поэтому панель выделяет каждому получателю отдельные порт и ключ: отключение одного не затронет остальных.',
      'protocol.trojan.details':
          'Обычно работает поверх TLS и похож на HTTPS-соединение. В mihomo доступны также другие поддерживаемые способы защиты. Панель создаёт отдельный пароль каждому получателю. Поддерживается Clash Verge; выбранные транспорт и защита должны поддерживаться и клиентом.',
      'protocol.vmess.details':
          'VMess включает собственную защиту данных и проверку получателя по UUID. При необходимости поверх него настраивается транспорт и TLS. Поддерживается Clash Verge. Для корректной работы важна синхронизация времени клиента и сервера.',
      'protocol.vless.details':
          'Подходит для личного сервера и поддерживается Clash Verge и многими другими клиентами. Сам VLESS не шифрует трафик: защиту выбирают отдельно. REALITY позволяет обойтись без своего сертификата подключения; TLS использует сертификат сервера. UUID получателя создаст панель.',
      'builder.choice.security.None.help':
          'Транспорт без TLS. Подходит для доверенной сети или защищённого туннеля.',
      'builder.choice.security.None': 'Без дополнительной защиты',
      'builder.choice.security.TLS.help':
          'Защита сертификатом сервера. Проверяется подлинность адреса подключения.',
      'builder.choice.security.REALITY.help':
          'Защита без собственного сертификата подключения. Ключи создадутся автоматически.',
      'builder.choice.transport.XHTTP.help':
          'Передача через HTTP с настраиваемыми потоками отправки и загрузки.',
      'builder.choice.transport.gRPC.help':
          'Потоки HTTP/2. Потребуется поддержка gRPC на обратном прокси, если он используется.',
      'builder.choice.transport.WebSocket.help':
          'Передача через WebSocket. Можно использовать совместимый обратный прокси.',
      'builder.choice.transport.TCP.help':
          'Прямое соединение. Подходит для обычного подключения без обратного прокси.',
      'builder.error.rows_invalid': 'Проверьте заполнение строк.',
      'builder.error.format_invalid': 'Проверьте формат значения.',
      'builder.error.boolean_invalid': 'Выберите значение.',
      'builder.error.range_invalid': 'Число вне допустимого диапазона.',
      'builder.error.integer_invalid': 'Введите целое число.',
      'builder.error.choice_invalid':
          'Этот вариант несовместим с выбранными параметрами.',
      'builder.error.too_long': 'Значение слишком длинное.',
      'builder.error.required': 'Заполните поле.',
      'builder.credentialsAuto':
          'Ключи и учётные данные получателей создаются автоматически.',
      'builder.address': 'Адрес',
      'builder.review': 'Параметры подключения',
      'builder.category.system': 'Системные входы',
      'builder.category.proxy': 'Протоколы доступа',
      'builder.advanced': 'Дополнительные параметры',
      'builder.next': 'Далее',
      'builder.step.review': 'Проверка',
      'builder.step.parameters': 'Параметры',
      'builder.step.security': 'Маскировка',
      'builder.step.transport': 'Транспорт',
      'builder.step.protocol': 'Протокол',
      'builder.step.core': 'Ядро',
      'auth.signIn': 'Войти',
      'auth.signingIn': 'Вход…',
      'auth.signOut': 'Выйти',
      'auth.setupRequired':
          'Создайте администратора на сервере: sudo sky-ui setup.',
      'admin.editName': 'Изменить имя администратора',
      'admin.currentPassword': 'Текущий пароль',
      'admin.newPassword': 'Новый пароль',
      'admin.confirmPassword': 'Повторите новый пароль',
      'admin.passwordMismatch': 'Пароли не совпадают.',
      'admin.passwordHint': 'От 12 символов, не более 72 bytes в UTF-8.',
      'admin.rotationHint': 'После изменения остальные сеансы будут завершены.',
      'admin.revokeOthers': 'Завершить остальные',
      'admin.revokeTitle': 'Завершить сеанс?',
      'admin.revoke': 'Завершить',
      'admin.revokeHint': 'На этом устройстве потребуется войти снова.',
      'admin.revokeOthersHint':
          'Все устройства, кроме текущего, потеряют доступ к панели до повторного входа.',
      'admin.device': 'Устройство',
      'admin.ip': 'IP',
      'admin.lastSeen': 'Активность',
      'admin.actions': 'Действия',
      'admin.currentSession': 'Текущий сеанс',
      'runtime.error.auth_invalid': 'Неверное имя или пароль.',
      'runtime.error.auth_required': 'Сеанс завершён. Войдите снова.',
      'runtime.error.auth_not_configured': 'Администратор пока не настроен.',
      'runtime.error.auth_rate_limited':
          'Слишком много попыток. Повторите через несколько минут.',
      'runtime.error.csrf_invalid':
          'Сеанс изменился. Обновите страницу и повторите.',
      'runtime.error.owner_name_invalid':
          'Логин: от 1 до 32 символов, латиница, цифры, точка, дефис или подчёркивание.',
      'runtime.error.owner_password_invalid':
          'Пароль: от 12 символов, не более 72 bytes в UTF-8.',
      'nav.overview': 'Обзор',
      'nav.connections': 'Подключения',
      'nav.users': 'Пользователи',
      'nav.core': 'Ядро',
      'nav.logs': 'Логи',
      'nav.settings': 'Настройки',
      'nav.workspace': 'УПРАВЛЕНИЕ',
      'nav.system': 'СИСТЕМА',
      'app.name': 'Sky UI',
      'data.applying': 'Применение…',
      'data.persisted': 'Данные сервера',
      'status.unassigned': 'Не выдано',
      'protocol.unavailable':
          'Этот протокол ещё не подключён к серверной части. Сейчас работает VLESS · TCP · REALITY на mihomo.',
      'share.subscriptionUrl': 'Ссылка на подписку',
      'share.subscription': 'Подписка',
      'panelUpdate.title': 'Обновление Sky UI',
      'panelUpdate.details': 'Детали обновления',
      'panelUpdate.checked': 'Проверено',
      'panelUpdate.installed': 'Сейчас',
      'panelUpdate.sourceVersion': 'Исходная версия',
      'panelUpdate.targetVersion': 'Целевая версия',
      'panelUpdate.release': 'Релиз',
      'panelUpdate.downloadProgress': 'Скачивание файлов обновления',
      'panelUpdate.state.checking': 'Проверка',
      'panelUpdate.state.running': 'Обновление',
      'panelUpdate.state.queued': 'В очереди',
      'panelUpdate.state.reconnecting': 'Перезапуск',
      'panelUpdate.state.failed': 'Ошибка',
      'panelUpdate.state.available': 'Доступно',
      'panelUpdate.state.completed': 'Готово',
      'panelUpdate.state.current': 'Актуально',
      'panelUpdate.stage.discovery': 'Проверка релиза',
      'panelUpdate.stage.download': 'Скачивание',
      'panelUpdate.stage.verify': 'SHA256',
      'panelUpdate.stage.backup': 'Резервная копия',
      'panelUpdate.stage.prepare': 'Подготовка',
      'panelUpdate.stage.toolchain': 'Подготовка Dart SDK',
      'panelUpdate.stage.build': 'Сборка Sky UI',
      'panelUpdate.stage.validate': 'Проверка сборки',
      'panelUpdate.stage.install': 'Установка',
      'panelUpdate.stage.activate': 'Запуск панели',
      'panelUpdate.stage.health': 'Проверка запуска',
      'panelUpdate.stage.rollback': 'Откат',
      'panelUpdate.stage.complete': 'Завершено',
      'panelUpdate.result': 'Результат',
      'panelUpdate.stageLabel': 'Этап',
      'panelUpdate.rollback': 'Откат',
      'panelUpdate.restored': 'Выполнен',
      'panelUpdate.notRestored': 'Не выполнен',
      'panelUpdate.code': 'Code',
      'panelUpdate.reason': 'Причина',
      'builder.generate': 'Сгенерировать новое значение',
      'builder.generateField': 'Сгенерировать: {name}',
      'builder.advancedCount': 'Дополнительные параметры: {count}',
      'field.tlsMaxVersion': 'Максимальная версия TLS',
      'field.udpTimeout': 'UDP idle timeout, s',
      'help.udpTimeout':
          'Через сколько секунд без пакетов ядро освободит UDP-сессию. Для большинства сетей достаточно 300 s. Слишком короткое время может прерывать звонки и игры при паузах; увеличение дольше удерживает ресурсы.',
      'field.naiveCongestionControl': 'QUIC congestion control',
      'help.naiveCongestionControl':
          'Алгоритм управления перегрузкой на сервере для Naive HTTP/3. BBR обычно подходит для первого подключения; CUBIC и Reno можно сравнить при нестабильной скорости. На HTTP/2 эта настройка не применяется.',
      'field.hysteriaMasquerade': 'HTTPS-сайт для маскировки',
      'help.hysteriaMasquerade':
          'Необязательный HTTPS-адрес сайта, который Hysteria 2 покажет при обычном HTTP/3-запросе без VPN-аутентификации. Это обратный прокси: выбирай публичный сайт без приватных данных. Пустое поле оставляет стандартный ответ 404. Не заменяет сертификат или Salamander/Gecko.',
      'field.tuicAuthTimeout': 'TUIC authentication timeout, s',
      'help.tuicAuthTimeout':
          'Сколько секунд сервер ждёт команду аутентификации после соединения. Обычно 3 s. Для сетей с большой задержкой можно увеличить, но неавторизованные соединения будут занимать ресурсы дольше.',
      'field.tuicHeartbeat': 'TUIC heartbeat, s',
      'help.tuicHeartbeat':
          'Интервал служебных пакетов, поддерживающих QUIC-соединение. Обычно 10 s. Меньшее значение создаёт больше фонового трафика, большее может хуже работать за NAT с коротким временем ожидания.',
      'help.tlsMaxVersion':
          'Верхняя граница версии TLS на сервере. Обычно оставляй 1.3. Понижение до 1.2 нужно только для совместимости; значение не может быть ниже минимальной версии.',
      'field.realityMaxTimeDiff': 'Допустимое расхождение времени REALITY, s',
      'help.realityMaxTimeDiff':
          'Сервер отклонит REALITY handshake, если время клиента отличается сильнее указанного значения. Например, 60 s. На сервере и клиенте должна работать синхронизация часов. 0 сохраняет поведение ядра без ограничения времени.',
      'field.websocketHost': 'WebSocket Host',
      'help.websocketHost':
          'Host в HTTP-запросе клиента, например vpn.example.com. Нужен при маршрутизации через обратный прокси. Xray также проверяет совпадение Host на сервере. Не меняет SNI или сертификат. Пустое поле оставляет обычное поведение клиента.',
      'field.tlsMinVersion': 'Минимальная версия TLS',
      'help.tlsMinVersion':
          'TLS 1.2 и 1.3 обеспечивают современное шифрование. Значение 1.3 разрешает только TLS 1.3: клиент и промежуточный прокси должны его поддерживать. QUIC использует только TLS 1.3. Проверка сертификата в клиентской конфигурации остаётся обязательной.',
      'sni.title': 'Подобрать SNI',
      'sni.description':
          'RealiTLScanner проверит до 64 соседних IP на TCP 443. В списке будут сайты с TLS 1.3, HTTP/2 и действительным сертификатом для указанного имени.',
      'sni.platform': 'Пока доступно только на Linux amd64',
      'sni.install': 'Установить RealiTLScanner · 9.2 MB',
      'sni.installing': 'Загрузка и проверка RealiTLScanner…',
      'sni.start': 'Найти соседние сайты',
      'sni.cancel': 'Остановить поиск',
      'sni.empty':
          'Подходящие сайты рядом не найдены. Можно указать проверенный сайт вручную.',
      'sni.clientCheck':
          'Проверка выполняется с сервера. После выбора обновите подписку и проверьте подключение в своей сети.',
      'runtime.error.sni_tool_platform_unsupported':
          'Для этой архитектуры пока нет проверенного пакета RealiTLScanner.',
      'runtime.error.sni_tool_missing': 'Сначала установите RealiTLScanner.',
      'runtime.error.sni_scan_busy': 'Поиск уже выполняется.',
      'runtime.error.sni_address_invalid':
          'Для поиска нужен публичный IPv4 сервера в настройках панели.',
      'runtime.error.sni_scan_timeout':
          'Время поиска истекло. Найденные результаты сохранены до следующего поиска.',
      'runtime.error.sni_scan_failed':
          'Поиск завершился с ошибкой. Найденные результаты можно использовать после проверки.',
      'runtime.error.sni_scan_cancelled': 'Поиск остановлен.',
      'panelUpdate.command': 'Command',
      'panelUpdate.exitCode': 'Exit code',
      'panelUpdate.job': 'Job ID',
      'panelUpdate.started': 'Начало',
      'panelUpdate.finished': 'Завершение',
      'panelUpdate.artifact': 'Файл',
      'panelUpdate.update': 'Обновить',
      'panelUpdate.check': 'Проверить',
      'panelUpdate.checkingAction': 'Проверяем…',
      'panelUpdate.current': 'Установлена последняя версия',
      'panelUpdate.available': 'Доступна v{version}',
      'panelUpdate.none': 'Обновлений нет',
      'panelUpdate.checking': 'Проверяем обновления…',
      'panelUpdate.checkFailed': 'Не удалось проверить обновления',
      'panelUpdate.running': 'Обновляем Sky UI…',
      'panelUpdate.hint':
          'Панель кратко перезапустится. Настройки, подключения и доступ администратора сохранятся. Ядро продолжит работать. При ошибке запуска будет восстановлена предыдущая версия.',
      'runtime.error.release_feed_unavailable':
          'Не удалось получить релизы Sky UI. Повторите позже.',
      'runtime.error.panel_update_unavailable':
          'Этот релиз недоступен для обновления. Проверьте обновления ещё раз.',
      'runtime.error.panel_update_rolled_back':
          'Обновление не удалось. Предыдущая версия восстановлена.',
      'runtime.error.panel_update_failed':
          'Не удалось обновить Sky UI. Проверьте логи обслуживания.',
      'runtime.error.native_binary_incompatible':
          'Бинарники обновления несовместимы с сервером. Проверьте архитектуру и системные библиотеки. Текущая версия продолжает работать.',
      'share.type': 'Подписка или подключение',
      'share.uri': 'Ссылка подключения',
      'share.uriFormat': '{protocol} · ссылка подключения',
      'share.changed': 'Доступ изменился. Откройте подписку заново.',
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
          'Этот порт занят системой или панелью. Подберите другой кнопкой генерации рядом с полем.',
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
          'Конфигурация ядра не совпадает с сохранённой в панели. Выдача доступа заблокирована до восстановления.',
      'runtime.error.configuration_rollback_failed':
          'Не удалось восстановить работающую конфигурацию. Изменения и выдача доступа заблокированы. Проверьте логи и перезапустите службу Sky UI для восстановления.',
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
      'runtime.controller': 'Готовность',
      'runtime.ready': 'Готов',
      'runtime.notReady': 'Не готов',
      'runtime.refresh': 'Обновить',
      'runtime.validate': 'Проверить конфигурацию',
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
          'Служба ядра завершилась с ошибкой. Проверьте логи systemd.',
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
      'runtime.error.engine_not_ready':
          'Ядро пока не готово. Проверьте логи его службы.',
      'runtime.error.command_timeout': 'Время ожидания операции истекло.',
      'runtime.error.command_unavailable':
          'Не найдена программа, необходимая для управления ядром.',
      'runtime.error.origin_forbidden':
          'Запрос к серверу отклонён. Проверьте адрес панели.',
      'runtime.error.internal_error':
          'Ошибка сервера. Проверьте логи службы Sky UI.',
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
      'field.security': 'Маскировка',
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
          'Порт, на котором ядро принимает подключения пользователей. Укажите свободный порт от 1 до 65535 и разрешите его в сетевом экране сервера и у провайдера VPS. Кнопка генерации подбирает случайный порт и проверяет его доступность на сервере. Порты служб панели, контроллера и SSH зарезервированы; 80 и 443 используются для HTTPS панели.',
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
      'protocol.vless': 'Гибкий протокол с выбором транспорта и защиты.',
      'protocol.trojan': 'Доступ по паролю с защищённым транспортом.',
      'protocol.shadowsocks': 'Лёгкий зашифрованный прокси для TCP и UDP.',
      'protocol.hysteria2': 'QUIC-протокол для сетей с потерями и задержками.',
      'protocol.vmess': 'Шифрование и доступ по UUID, несколько транспортов.',
      'protocol.tuic': 'QUIC-протокол TUIC v5 с UUID и паролем.',
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
      'users.presence.online': 'В сети',
      'users.presence.recent': 'Был недавно',
      'users.presence.offline': 'Не в сети',
      'users.presence.unavailable': '—',
      'users.presence.help.online':
          'Замечена активность за последние 10 секунд.',
      'users.presence.help.recent':
          'Ядро недавно приняло запрос или рукопожатие пользователя.',
      'users.presence.help.offline':
          'За последние 10 секунд трафика не замечено.',
      'users.presence.help.unavailable':
          'Ядро пока не предоставило данные о подключении.',
      'users.subscription': 'QR-код',
      'users.none': 'Пока нет пользователей',
      'users.nameHelp':
          'Имя видно только вам в панели. Пользователь не получает учётную запись и не входит в панель.',
      'users.noAccess': 'Нет назначенных подключений',
      'users.accessRevoked': 'В макете отключены все доступы пользователя',
      'share.title': 'Поделиться доступом',
      'share.description': 'Личная подписка · {name}',
      'share.format': 'Автоматический формат по клиенту',
      'share.excluded':
          '{client}: не входят в подписку — {names}. Доступны отдельно в подходящем клиенте.',
      'runtime.error.generation_unsupported':
          'Для этого поля генератор недоступен.',
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
      'core.ram': 'RAM',
      'core.updateShort': 'Обновить',
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
      'logs.title': 'Логи',
      'users.devices': 'Устройства',
      'logs.description': 'События панели и демонстрационные сообщения ядра.',
      'logs.empty': 'В логах пока нет событий',
      'logs.started': 'Макет панели запущен',
      'logs.connectionSaved': 'Подключение сохранено: {name}',
      'logs.userSaved': 'Пользователь сохранён: {name}',
      'logs.deleted': 'Запись удалена: {name}',
      'logs.toggled': 'Состояние изменено: {name}',
      'feature.unavailable': 'Недоступно',
      'core.notInstalled': 'Не установлено',
      'core.install': 'Установить',
      'core.remove': 'Удалить ядро',
      'core.missingStatus': 'Ядро не установлено',
      'core.removeHint':
          'Ядро будет остановлено и удалено. Его подключения перестанут работать. Подключения, пользователи и ключи сохранятся и будут доступны после повторной установки.',
      'core.installHint':
          'Будет установлена проверенная версия ядра. Сохранённые подключения и ключи останутся прежними. Запустить ядро можно после установки.',
      'runtime.error.core_already_installed':
          'Ядро уже установлено. Обновите страницу.',
      'core.update': 'Обновить ядро',
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
      'logs.reconnecting': 'Подключение к логам…',
      'logs.latest': 'К последним записям',
      'logs.noMatches': 'Нет записей выбранного уровня',
      'logs.clear': 'Очистить',
      'logs.clearTitle': 'Очистить логи?',
      'logs.clearHint':
          'Будут очищены все записи, накопленные панелью, включая скрытые фильтром. Новые события продолжат поступать. Системные логи Linux не затрагиваются.',
      'logs.cleared': 'Логи очищены',
      'admin.title': 'Администратор',
      'admin.username': 'Имя администратора',
      'admin.password': 'Пароль',
      'admin.sessions': 'Активные сеансы',
      'admin.changePassword': 'Изменить пароль',
      'admin.manageSessions': 'Управление сеансами',
      'admin.logoutUnavailable': 'Выход — пока недоступно',
      'settings.system': 'Система',
      'settings.domain': 'Адрес панели и HTTPS',
      'settings.https.ip': 'Вход по IP',
      'settings.https.domain': 'Текущий домен',
      'settings.https.newDomain': 'Домен панели',
      'settings.https.unavailable':
          'Первичную настройку HTTPS выполните командой sudo skyui setup.',
      'settings.https.renewal':
          'Caddy автоматически продлевает сертификаты Let’s Encrypt.',
      'settings.https.certificateUnknown': 'Нет данных о сертификате',
      'settings.https.certificateExpired': 'Сертификат истёк',
      'settings.https.certificateUntil': 'Действует до {date}',
      'settings.https.dnsHelp':
          'Укажите домен с A-записью на IP сервера. Оставьте поле пустым для входа только по IP.',
      'settings.https.review': 'Изменить адрес',
      'settings.https.apply': 'Подтвердить смену',
      'settings.https.confirm':
          'Панель проверит HTTPS перед сменой адреса. На новом адресе войдите снова. Пользователям понадобится новый URL подписки.',
      'settings.https.reconnect':
          'Если эта вкладка перестанет отвечать, откройте панель по IP.',
      'settings.https.done': 'Адрес панели обновлён.',
      'settings.https.restored': 'Прежний адрес восстановлен.',
      'settings.https.stage.queued': 'Ожидает запуска…',
      'settings.https.stage.validate': 'Проверяем DNS и настройки…',
      'settings.https.stage.certificate': 'Ожидаем сертификат Let’s Encrypt…',
      'settings.https.stage.apply': 'Применяем адрес и проверяем HTTPS…',
      'settings.https.stage.rollback': 'Восстанавливаем прежний адрес…',
      'settings.https.error.load': 'Не удалось загрузить состояние HTTPS.',
      'settings.https.error.generic': 'Не удалось изменить адрес панели.',
      'settings.https.error.domain_invalid':
          'Введите домен без протокола, порта и пути.',
      'settings.https.error.domain_setup_required':
          'Сначала настройте рабочий HTTPS по IP через sudo skyui setup.',
      'settings.https.error.domain_unchanged': 'Этот адрес уже используется.',
      'settings.https.error.domain_state_changed':
          'Адрес уже изменился. Проверьте текущие настройки и повторите.',
      'settings.https.error.domain_dns_missing': 'Домен не разрешается в DNS.',
      'settings.https.error.domain_dns_mismatch':
          'Записи A и AAAA должны вести на этот сервер.',
      'settings.https.error.domain_certificate_in_use':
          'Сохранённое VPN-подключение использует сертификат, который изменится. Сначала выберите для него другой сертификат.',
      'settings.https.error.domain_https_not_ready':
          'HTTPS не прошёл проверку. Проверьте DNS и доступность портов 80 и 443.',
      'settings.https.error.domain_rollback_failed':
          'Автоматическое восстановление не завершилось. Проверьте службу sky-ui-maintenance-recovery через SSH.',
      'settings.https.error.maintenance_busy':
          'Дождитесь завершения текущей операции обслуживания.',
      'settings.https.error.maintenance_interrupted':
          'Операция была прервана. Проверьте текущий адрес панели.',
      'settings.dns': 'DNS ядра',
      'settings.logging': 'Уровень логирования ядра',
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
      'system.coreHint': 'Активные службы ядер готовы',
      'system.coreNotReady': 'Нет готовых служб ядер',
      'settings.title': 'Настройки',
      'settings.description': 'Только необходимое для вашей панели.',
      'settings.general': 'Общие',
      'settings.serverName': 'Название сервера',
      'settings.address': 'Публичный адрес сервера',
      'settings.language': 'Язык интерфейса',
      'settings.russian': 'Русский',
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
