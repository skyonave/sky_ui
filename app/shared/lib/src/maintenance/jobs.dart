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
    this.progress,
    this.core,
    this.tag,
    this.domain,
  });
  final String id, action, status;
  final String? error;
  final String? core, tag, domain;
  final PanelUpdateProgress? progress;
  bool get busy => status == 'queued' || status == 'running';
  factory MaintenanceJob.fromJson(Map<String, dynamic> v) => MaintenanceJob(
    id: v['id'] as String,
    action: v['action'] as String,
    status: v['status'] as String,
    error: v['error'] as String?,
    core: v['core'] as String?,
    tag: v['tag'] as String?,
    domain: v['domain'] as String?,
    progress: v['progress'] is Map
        ? PanelUpdateProgress.fromJson(
            Map<String, dynamic>.from(v['progress'] as Map),
          )
        : null,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'action': action,
    'status': status,
    'error': error,
    if (core != null) 'core': core,
    if (tag != null) 'tag': tag,
    if (domain != null) 'domain': domain,
    if (progress != null) 'progress': progress!.toJson(),
  };
}

class PanelUpdateProgress {
  const PanelUpdateProgress({
    required this.stage,
    this.currentVersion,
    this.targetVersion,
    this.startedAt,
    this.updatedAt,
    this.finishedAt,
    this.failedStage,
    this.errorCode,
    this.command,
    this.artifact,
    this.bytesReceived,
    this.bytesTotal,
    this.exitCode,
    this.rolledBack,
  });
  final String stage;
  final String? currentVersion,
      targetVersion,
      startedAt,
      updatedAt,
      finishedAt,
      failedStage,
      errorCode,
      command,
      artifact;
  final int? bytesReceived, bytesTotal, exitCode;
  final bool? rolledBack;
  factory PanelUpdateProgress.fromJson(Map<String, dynamic> j) =>
      PanelUpdateProgress(
        stage: j['stage'] as String? ?? 'discovery',
        currentVersion: j['currentVersion'] as String?,
        targetVersion: j['targetVersion'] as String?,
        startedAt: j['startedAt'] as String?,
        updatedAt: j['updatedAt'] as String?,
        finishedAt: j['finishedAt'] as String?,
        failedStage: j['failedStage'] as String?,
        errorCode: j['errorCode'] as String?,
        command: j['command'] as String?,
        artifact: j['artifact'] as String?,
        bytesReceived: j['bytesReceived'] as int?,
        bytesTotal: j['bytesTotal'] as int?,
        exitCode: j['exitCode'] as int?,
        rolledBack: j['rolledBack'] as bool?,
      );
  Map<String, Object?> toJson() => {
    'stage': stage,
    'currentVersion': currentVersion,
    'targetVersion': targetVersion,
    'startedAt': startedAt,
    'updatedAt': updatedAt,
    'finishedAt': finishedAt,
    'failedStage': failedStage,
    'errorCode': errorCode,
    'command': command,
    'artifact': artifact,
    'bytesReceived': bytesReceived,
    'bytesTotal': bytesTotal,
    'exitCode': exitCode,
    'rolledBack': rolledBack,
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
