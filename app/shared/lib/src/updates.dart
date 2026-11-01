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
