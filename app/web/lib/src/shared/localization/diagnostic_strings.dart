const diagnosticStrings = <String, String>{
  'diagnostics.action': 'Диагностика',
  'diagnostics.title': 'Диагностика подключения',
  'diagnostics.retry': 'Проверить ещё раз',
  'diagnostics.progress': 'Ход диагностики',
  'diagnostics.starting': 'Запуск проверки…',
  'diagnostics.issue': '{step}: {reason}',
  'diagnostics.current': 'Сейчас: {step}',
  'diagnostics.reconnecting': 'Нет связи с сервером. Ожидаем результат…',
  'diagnostics.scope':
      'Проверка с сервера. Внешняя доступность и вход клиента не проверяются.',
  'diagnostics.outcome.pending': 'Ожидание',
  'diagnostics.outcome.running': 'Проверка…',
  'diagnostics.outcome.passed': 'Проверка сервера завершена',
  'diagnostics.outcome.warning': 'Есть замечания',
  'diagnostics.outcome.failed': 'Обнаружены ошибки',
  'diagnostics.outcome.cancelled': 'Проверка остановлена',
  'diagnostics.state.pending': 'Ожидание',
  'diagnostics.state.running': 'Проверка',
  'diagnostics.state.passed': 'OK',
  'diagnostics.state.warning': 'Внимание',
  'diagnostics.state.failed': 'Ошибка',
  'diagnostics.state.skipped': 'Пропущено',
  'diagnostics.step.configuration': 'Применённые настройки',
  'diagnostics.step.access': 'Доступ пользователей',
  'diagnostics.step.engine': 'Ядро',
  'diagnostics.step.native': 'Конфигурация ядра',
  'diagnostics.step.listener': 'Сокет подключения',
  'diagnostics.step.listeners': 'Порты подключения',
  'diagnostics.step.dns': 'Адрес проверки',
  'diagnostics.step.tcp': 'TCP до точки проверки',
  'diagnostics.step.tls': 'TLS и SNI',
  'diagnostics.step.freshness': 'Актуальность результата',
  'diagnostics.detail.endpoint': 'Listen',
  'diagnostics.detail.transport': 'Transport',
  'diagnostics.detail.interface': 'Interface',
  'diagnostics.detail.target': 'Target',
  'diagnostics.detail.sni': 'SNI',
  'diagnostics.detail.purpose': 'Mode',
  'diagnostics.detail.addresses': 'IP',
  'diagnostics.detail.address': 'IP',
  'diagnostics.detail.protocol': 'TLS',
  'diagnostics.detail.cipher': 'Cipher',
  'diagnostics.detail.service': 'Service',
  'diagnostics.detail.version': 'Version',
  'diagnostics.detail.state': 'State',
  'diagnostics.detail.pid': 'PID',
  'diagnostics.detail.recipients': 'Получателей',
  'diagnostics.detail.checked': 'Проверено',
  'diagnostics.detail.total': 'Всего',
  'diagnostics.code.configuration_ready':
      'Сохранённые настройки соответствуют конфигурации на диске.',
  'diagnostics.code.configuration_out_of_sync':
      'Конфигурация изменена вне панели или не была применена. Сначала восстанови соответствие настроек.',
  'diagnostics.code.settings_invalid':
      'Параметры подключения или выбранный сертификат больше не действуют. Открой настройки подключения.',
  'diagnostics.code.diagnostics_unsupported':
      'Для этого ядра диагностика подключения пока недоступна.',
  'diagnostics.code.access_ready':
      'Подключение включено, доступ выдан активным пользователям.',
  'diagnostics.code.connection_disabled':
      'Подключение выключено. Включи его в таблице подключений.',
  'diagnostics.code.no_recipients':
      'Нет активных пользователей с этим подключением. Выдай доступ во вкладке «Пользователи».',
  'diagnostics.code.engine_ready':
      'Служба ядра работает и сообщает о готовности.',
  'diagnostics.code.binary_missing':
      'Ядро не установлено. Установи его во вкладке «Ядро».',
  'diagnostics.code.platform_unsupported': 'Эта проверка доступна на Linux.',
  'diagnostics.code.service_missing':
      'Служба ядра отсутствует. Проверь установку ядра.',
  'diagnostics.code.core_failed':
      'Ядро завершилось с ошибкой. Проверь его логи.',
  'diagnostics.code.core_stopped':
      'Ядро остановлено. Запусти его во вкладке «Ядро».',
  'diagnostics.code.controller_not_ready':
      'Процесс работает, но управляющий интерфейс ядра ещё не готов. Проверь логи.',
  'diagnostics.code.native_ready':
      'Ядро приняло текущий файл конфигурации без запуска и перезапуска службы.',
  'diagnostics.code.native_invalid':
      'Ядро отклонило файл конфигурации. Проверь настройки и логи службы.',
  'diagnostics.code.validator_missing':
      'Не удалось запустить проверку конфигурации: отсутствует нужная команда.',
  'diagnostics.code.validator_timeout':
      'Ядро не завершило проверку конфигурации вовремя.',
  'diagnostics.code.listener_ready':
      'Сокет обнаружен у системного пользователя службы ядра.',
  'diagnostics.code.listener_missing':
      'Ожидаемый сокет ядра не найден. Проверь порт, адрес Listen и логи ядра.',
  'diagnostics.code.listener_identity_unavailable':
      'Не удалось проверить владельца сокета. Результат не считается успешным.',
  'diagnostics.code.interface_missing':
      'Сетевой интерфейс AmneziaWG не создан. Проверь логи ядра.',
  'diagnostics.code.no_active_listeners':
      'Нет активных входов для проверки. Вход может появиться после выдачи доступа пользователю.',
  'diagnostics.code.listeners_sampled':
      'Проверены первые 16 сокетов. Остальные не проверялись.',
  'diagnostics.code.not_applicable':
      'Для этого протокола отдельная проверка TLS не нужна.',
  'diagnostics.code.quic_client_required':
      'Соединение использует QUIC/UDP. Проверен сокет; handshake нужно проверять совместимым клиентом.',
  'diagnostics.code.awg_client_required':
      'AmneziaWG не использует TLS/SNI. Для проверки handshake нужен клиент AmneziaWG 3.1.',
  'diagnostics.code.target_invalid':
      'Некорректный адрес точки проверки или SNI. Проверь параметры подключения.',
  'diagnostics.code.target_not_public':
      'Handshake-сайт указывает на непубличный IP. Автоматическая внешняя проверка такого адреса не выполняется.',
  'diagnostics.code.dns_ready':
      'Имя разрешено. Дальнейшие проверки используют эти IP без повторного DNS-запроса.',
  'diagnostics.code.address_ready': 'Для проверки используется настроенный IP.',
  'diagnostics.code.dns_failed':
      'Не удалось разрешить имя handshake-сайта. Проверь имя и DNS сервера.',
  'diagnostics.code.dns_timeout':
      'DNS не ответил вовремя. Проверь DNS и сеть сервера.',
  'diagnostics.code.tcp_ready':
      'TCP-соединение с точки зрения сервера устанавливается.',
  'diagnostics.code.tcp_timeout':
      'TCP-соединение не установилось вовремя. Проверь адрес, порт и исходящую сеть сервера.',
  'diagnostics.code.tcp_refused':
      'Точка проверки отклонила TCP-соединение. Проверь порт и запущенную службу.',
  'diagnostics.code.tcp_failed':
      'Не удалось установить TCP-соединение. Проверь сеть, адрес и порт.',
  'diagnostics.code.tls_ready':
      'TLS-handshake выполнен. Сертификат, срок действия и соответствие имени проверены.',
  'diagnostics.code.tls_timeout':
      'TCP доступен, но TLS-handshake не завершился вовремя. Возможны фильтрация SNI или проблема точки проверки.',
  'diagnostics.code.tls_name_mismatch':
      'Сертификат не соответствует SNI. Проверь имя сервера в параметрах подключения.',
  'diagnostics.code.tls_expired':
      'Сертификат истёк. Проверь продление сертификата и часы сервера.',
  'diagnostics.code.tls_not_yet_valid':
      'Сертификат ещё не действует. Проверь дату и время сервера.',
  'diagnostics.code.tls_untrusted':
      'Сертификат не прошёл проверку доверия. Проверь цепочку сертификатов; самоподписанный сертификат требует доверия на клиенте.',
  'diagnostics.code.tls_version':
      'Handshake-сайт не согласовал нужную версию TLS. Для REALITY требуется TLS 1.3.',
  'diagnostics.code.tls_failed':
      'TLS-handshake не удался. Проверь SNI, сертификат и доступность handshake-сайта.',
  'diagnostics.code.openssl_missing':
      'OpenSSL недоступен. TLS-проверка не выполнена.',
  'diagnostics.code.snapshot_current':
      'Во время проверки настройки и состояние службы не изменились.',
  'diagnostics.code.state_changed':
      'Во время проверки настройки или служба изменились. Запусти диагностику ещё раз.',
  'diagnostics.code.blocked':
      'Пропущено: предыдущая необходимая проверка не пройдена.',
  'diagnostics.code.cancelled': 'Проверка остановлена.',
  'diagnostics.code.diagnostic_timeout':
      'Превышено общее время диагностики. Остальные проверки остановлены.',
  'diagnostics.code.check_failed':
      'Проверку не удалось завершить. Повтори её; при повторной ошибке проверь логи Sky UI.',
  'diagnostics.error.diagnostics_busy':
      'Предыдущая диагностика ещё выполняется или завершается. Повтори через несколько секунд.',
  'diagnostics.error.diagnostics_rate_limited':
      'Проверки запускаются слишком часто. Повтори через несколько секунд.',
  'diagnostics.error.not_found':
      'Подключение удалено или результат проверки уже истёк.',
  'diagnostics.error.state_changed':
      'Настройки изменились. Повтори диагностику для текущей версии.',
  'diagnostics.error.failed':
      'Не удалось запустить диагностику. Проверь связь с панелью и повтори.',
};

String? diagnosticText(String key) => diagnosticStrings[key];
