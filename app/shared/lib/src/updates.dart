class CoreUpdateInfo {
  const CoreUpdateInfo({
    required this.coreId,
    required this.source,
    required this.versions,
    required this.checkedAt,
    this.installed,
  });
  final String coreId, source, checkedAt;
  final String? installed;
  final List<String> versions;
  bool get available => versions.isNotEmpty;
  Map<String, Object?> toJson() => {
    'coreId': coreId,
    'source': source,
    'installed': installed,
    'versions': versions,
    'checkedAt': checkedAt,
  };
  factory CoreUpdateInfo.fromJson(Map<String, dynamic> value) => CoreUpdateInfo(
    coreId: value['coreId'] as String,
    source: value['source'] as String,
    installed: value['installed'] as String?,
    checkedAt: value['checkedAt'] as String,
    versions: (value['versions'] as List).cast<String>(),
  );
}

class PanelUpdateInfo {
  const PanelUpdateInfo({
    required this.currentVersion,
    required this.available,
    required this.supported,
    required this.checkedAt,
    this.latestVersion,
    this.tag,
    this.releaseUrl,
  });
  final String currentVersion, checkedAt;
  final String? latestVersion, tag, releaseUrl;
  final bool available, supported;
  factory PanelUpdateInfo.fromJson(Map<String, dynamic> value) =>
      PanelUpdateInfo(
        currentVersion: value['currentVersion'] as String,
        available: value['available'] as bool,
        supported: value['supported'] as bool,
        checkedAt: value['checkedAt'] as String,
        latestVersion: value['latestVersion'] as String?,
        tag: value['tag'] as String?,
        releaseUrl: value['releaseUrl'] as String?,
      );
  Map<String, Object?> toJson() => {
    'currentVersion': currentVersion,
    'available': available,
    'supported': supported,
    'checkedAt': checkedAt,
    'latestVersion': latestVersion,
    'tag': tag,
    'releaseUrl': releaseUrl,
  };
}
