const engineStrings = <String, String>{
  'builder.installingAwg':
      'Сборка AmneziaWG. Установка может занять несколько минут.',
  'field.obfs': 'Маскировка Hysteria 2',
  'help.obfs':
      'Salamander меняет внешний вид UDP-пакетов. Клиент должен поддерживать ту же маскировку и пароль. Без маскировки используется обычный Hysteria 2 с TLS.',
  'field.obfsPassword': 'Obfs password',
  'help.obfsPassword':
      'Общий пароль маскировки. Можно оставить пустым: панель создаст его и добавит в клиентский профиль автоматически. Это не пароль получателя.',
  'field.xhttpHost': 'XHTTP Host',
  'help.xhttpHost':
      'Необязательное имя узла в HTTP-запросах. Нужен для маршрутизации на совместимом обратном прокси. При прямом подключении можно оставить пустым. Это поле не меняет адрес VPS и не заменяет SNI.',
  'runtime.error.go_toolchain_required':
      'Для сборки AmneziaWG нужен Go. Проверь зависимости на сервере.',
  'runtime.error.amnezia_dependencies_required':
      'Для AmneziaWG нужны iproute2 и nftables. Установи их и повтори.',
  'runtime.error.network_in_use':
      'Эта подсеть уже используется другим подключением. Выбери другую.',
  'runtime.error.peer_address_invalid':
      'У получателей остались адреса прежней подсети. Сначала перенеси их в новое подключение.',
  'runtime.error.peer_address_unavailable':
      'В подсети не осталось свободных адресов.',
  'field.serverAddress': 'Адрес сервера в туннеле',
  'help.serverAddress':
      'Приватный IPv4-адрес с маской /24…/30, например 10.66.0.1/24. Панель выделит каждому получателю свободный адрес этой подсети. Для другого подключения выбери другую подсеть. После выдачи доступа изменение подсети потребует переноса адресов клиентов.',
  'field.dns': 'DNS',
  'help.dns':
      'DNS-серверы для клиентского профиля, по одному IPv4 в строке. Их использует устройство получателя после подключения. Текущая серверная настройка AmneziaWG маршрутизирует IPv4. Это не меняет системный DNS VPS.',
  'field.mtu': 'MTU',
  'help.mtu':
      'Максимальный размер пакета внутри туннеля. Начни с 1280: это помогает избежать проблем с размером пакетов в мобильных сетях. Поднимать значение стоит после проверки на своих устройствах.',
  'field.keepalive': 'PersistentKeepalive',
  'help.keepalive':
      'Период служебного пакета от клиента, в секундах. Значение 25 помогает поддерживать связь за NAT. Значение 0 отключает периодические пакеты.',
  'field.realityTarget': 'Handshake target',
  'help.realityTarget':
      'Домен и порт доступного с VPS HTTPS-сайта, например www.kernel.org:443. REALITY использует его при TLS-handshake. SNI должен подходить этому сайту. Если выбранный сайт блокируется на пути, подключение может завершаться таймаутом.',
  'field.xhttpPath': 'XHTTP Path',
  'help.xhttpPath':
      'Путь HTTP-запросов, например /tunnel. Это не каталог на сервере. Клиент и сервер должны использовать один путь. При использовании обратного прокси направь этот путь на порт подключения.',
  'field.xhttpMode': 'XHTTP Mode',
  'help.xhttpMode':
      'Начни с auto: клиент выбирает совместимый способ передачи. packet-up отправляет данные отдельными запросами, stream-up — потоком, stream-one использует один двусторонний поток. Доступность зависит от клиента и промежуточного прокси.',
  'field.upMbps': 'Upload, Mbps',
  'help.upMbps':
      'Ожидаемая пропускная способность отправки сервера для управления передачей Hysteria 2. Это не квота получателя. Не завышай значение относительно реального канала.',
  'field.downMbps': 'Download, Mbps',
  'help.downMbps':
      'Ожидаемая пропускная способность приёма сервера для Hysteria 2. Это не ограничение общего объёма трафика. Начни с реальной скорости VPS и проверь соединение.',
  'field.congestionController': 'Congestion control',
  'help.congestionController':
      'Алгоритм управления передачей TUIC. Начни с bbr. cubic и new_reno нужны для проверки поведения на конкретной сети. Клиентский профиль получит выбранное значение.',
  'awg.Jc': 'Jc',
  'awg.Jc.help':
      'Количество маскирующих пакетов перед handshake. Стартовое значение 4. Повышение увеличивает служебный трафик; клиенту передаются те же параметры.',
  'awg.Jmin': 'Jmin',
  'awg.Jmin.help':
      'Минимальный размер маскирующего пакета в bytes. Должен быть не больше Jmax. Эти пакеты помогают менять внешний вид handshake.',
  'awg.Jmax': 'Jmax',
  'awg.Jmax.help':
      'Максимальный размер маскирующего пакета в bytes. Должен быть не меньше Jmin. Слишком большие значения могут ухудшить работу на сети с небольшим MTU.',
  'awg.ContentPaddingAddition': 'ContentPaddingAddition',
  'awg.ContentPaddingAddition.help':
      'Дополнительное заполнение внутри зашифрованных пакетов, в bytes. Можно указать число или диапазон, например 0-32. Для первого подключения оставь значение по умолчанию.',
  'awg.RandomTrailers': 'RandomTrailers',
  'awg.RandomTrailers.help':
      'Возможность AmneziaWG 3.1 добавлять случайные окончания пакетов. Требует поддержки 3.1 на клиенте. Оставь включённой для нового профиля 3.1.',
  'awg.DisableCookies': 'DisableCookies',
  'awg.DisableCookies.help':
      'Параметр 3.1, отключающий механизм cookie-пакетов WireGuard. Меняет поведение при нагрузке и внешний вид протокола. Передаётся клиенту; используй согласованные настройки с обеих сторон.',
  'awg.I.help':
      'Дополнительный маскирующий пакет в формате AmneziaWG, например <b 0x1234><r 8>. Для обычной настройки поле можно оставить пустым. Неверная спецификация не пройдёт проверку ядра при применении.',
  'awg.RekeyAfterTime': 'RekeyAfterTime',
  'awg.RekeyAfterTime.help':
      'Интервал обновления сессионных ключей в seconds. Стартовое значение 120. Должен быть меньше RejectAfterTime.',
  'awg.RekeyTimeout': 'RekeyTimeout',
  'awg.RekeyTimeout.help':
      'Пауза между попытками handshake при обновлении ключей, в seconds. Начальное значение 5.',
  'awg.RejectAfterTime': 'RejectAfterTime',
  'awg.RejectAfterTime.help':
      'Максимальный срок использования сессионного ключа, в seconds. После него трафик требует нового handshake. Стартовое значение 180.',
  'awg.KeepaliveTimeout': 'KeepaliveTimeout',
  'awg.KeepaliveTimeout.help':
      'Внутренний таймер ожидания служебного обмена в seconds. Это параметр протокола, не квота и не время жизни доступа.',
  'awg.MaxHandshakeAttempts': 'MaxHandshakeAttempts',
  'awg.MaxHandshakeAttempts.help':
      'Число попыток установить handshake до отказа от текущего обмена. Стартовое значение 18. Это не ограничение числа клиентов.',
};

String? engineText(String key) {
  if (engineStrings.containsKey(key)) return engineStrings[key];
  final match = RegExp(r'^awg\.([SHI])([1-5])(\.help)?$').firstMatch(key);
  if (match == null) return null;
  if (match[3] == null) return '${match[1]}${match[2]}';
  if (match[1] == 'I') return engineStrings['awg.I.help'];
  if (match[1] == 'S')
    return 'Дополнительное заполнение пакетов AmneziaWG в bytes. S1 относится к первому сообщению handshake, S2 — к ответу, S3 — к cookie, S4 — к пакетам данных. Параметры должны совпадать с клиентом; для начала оставь значения панели.';
  return 'Идентификатор типа пакета AmneziaWG. В версии 3.1 заголовок дополнительно защищён HeaderProtectionKey, который панель создаёт и передаёт автоматически. Для первого подключения оставь значения H1–H4 по умолчанию.';
}
