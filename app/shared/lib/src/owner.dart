class OwnerState {
  const OwnerState({
    required this.configured,
    required this.authenticated,
    this.username,
    this.csrf,
    this.sessionId,
  });
  final bool configured, authenticated;
  final String? username, csrf, sessionId;
  Map<String, Object?> toJson() => {
    'configured': configured,
    'authenticated': authenticated,
    if (username != null) 'username': username,
    if (csrf != null) 'csrf': csrf,
    if (sessionId != null) 'sessionId': sessionId,
  };
  factory OwnerState.fromJson(Map<String, dynamic> j) => OwnerState(
    configured: j['configured'] as bool,
    authenticated: j['authenticated'] as bool,
    username: j['username'] as String?,
    csrf: j['csrf'] as String?,
    sessionId: j['sessionId'] as String?,
  );
}

class OwnerSession {
  const OwnerSession({
    required this.id,
    required this.createdAt,
    required this.lastSeen,
    required this.expiresAt,
    required this.ip,
    required this.agent,
    required this.current,
  });
  final String id, ip, agent;
  final DateTime createdAt, lastSeen, expiresAt;
  final bool current;
  Map<String, Object?> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastSeen': lastSeen.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'ip': ip,
    'agent': agent,
    'current': current,
  };
  factory OwnerSession.fromJson(Map<String, dynamic> j) => OwnerSession(
    id: j['id'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    lastSeen: DateTime.parse(j['lastSeen'] as String),
    expiresAt: DateTime.parse(j['expiresAt'] as String),
    ip: j['ip'] as String,
    agent: j['agent'] as String,
    current: j['current'] as bool,
  );
}
