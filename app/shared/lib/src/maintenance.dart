class BackupInfo {
  const BackupInfo({
    required this.id,
    required this.created,
    required this.version,
    required this.size,
    required this.sha256,
    required this.coreVersion,
  });
  final String id, created, version, sha256, coreVersion;
  final int size;
  factory BackupInfo.fromJson(Map<String, dynamic> v) => BackupInfo(
    id: v['id'] as String,
    created: v['created'] as String,
    version: v['version'] as String,
    size: v['size'] as int,
    sha256: v['sha256'] as String,
    coreVersion: v['coreVersion'] as String,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'created': created,
    'version': version,
    'size': size,
    'sha256': sha256,
    'coreVersion': coreVersion,
  };
}

class MaintenanceJob {
  const MaintenanceJob({
    required this.id,
    required this.action,
    required this.status,
    this.error,
  });
  final String id, action, status;
  final String? error;
  bool get busy => status == 'queued' || status == 'running';
  factory MaintenanceJob.fromJson(Map<String, dynamic> v) => MaintenanceJob(
    id: v['id'] as String,
    action: v['action'] as String,
    status: v['status'] as String,
    error: v['error'] as String?,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'action': action,
    'status': status,
    'error': error,
  };
}

class MaintenanceSnapshot {
  const MaintenanceSnapshot({
    required this.available,
    required this.backups,
    this.job,
  });
  final bool available;
  final List<BackupInfo> backups;
  final MaintenanceJob? job;
  factory MaintenanceSnapshot.fromJson(
    Map<String, dynamic> v,
  ) => MaintenanceSnapshot(
    available: v['available'] as bool,
    backups: (v['backups'] as List)
        .map((b) => BackupInfo.fromJson(Map<String, dynamic>.from(b as Map)))
        .toList(),
    job: v['job'] == null
        ? null
        : MaintenanceJob.fromJson(Map<String, dynamic>.from(v['job'] as Map)),
  );
  Map<String, Object?> toJson() => {
    'available': available,
    'backups': backups.map((b) => b.toJson()).toList(),
    'job': job?.toJson(),
  };
}
