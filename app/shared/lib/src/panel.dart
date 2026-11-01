import 'models.dart';
import 'protocols.dart';

class PanelSnapshot {
  const PanelSnapshot({
    required this.revision,
    required this.connections,
    required this.recipients,
    required this.serverName,
    required this.address,
    required this.synchronized,
    required this.deliveryReady,
    required this.protocols,
    this.errorCode,
    this.coreAvailability = const {},
    this.instanceIds = const {},
    this.instanceReadiness = const {},
  });
  final int revision;
  final List<Connection> connections;
  final List<Recipient> recipients;
  final String serverName;
  final String address;
  final bool synchronized;
  final bool deliveryReady;
  final Map<String, List<ProtocolDefinition>> protocols;
  final String? errorCode;
  final Map<String, bool> coreAvailability;
  final Map<String, String> instanceIds;
  final Map<String, bool> instanceReadiness;
  Map<String, Object?> toJson() => {
    'revision': revision,
    'connections': connections.map((v) => v.toJson()).toList(),
    'recipients': recipients.map((v) => v.toJson()).toList(),
    'serverName': serverName,
    'address': address,
    'synchronized': synchronized,
    'deliveryReady': deliveryReady,
    'errorCode': errorCode,
    'coreAvailability': coreAvailability,
    'instanceIds': instanceIds,
    'instanceReadiness': instanceReadiness,
    'protocols': protocols.map(
      (k, v) => MapEntry(k, v.map((p) => p.toJson()).toList()),
    ),
  };
  factory PanelSnapshot.fromJson(Map<String, dynamic> json) => PanelSnapshot(
    revision: json['revision'] as int,
    connections: (json['connections'] as List)
        .map((v) => Connection.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
    recipients: (json['recipients'] as List)
        .map((v) => Recipient.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
    serverName: json['serverName'] as String,
    address: json['address'] as String,
    synchronized: json['synchronized'] as bool,
    deliveryReady: json['deliveryReady'] as bool,
    errorCode: json['errorCode'] as String?,
    coreAvailability: Map<String, bool>.from(
      json['coreAvailability'] as Map? ?? const {},
    ),
    instanceIds: Map<String, String>.from(
      json['instanceIds'] as Map? ?? const {},
    ),
    instanceReadiness: Map<String, bool>.from(
      json['instanceReadiness'] as Map? ?? const {},
    ),
    protocols: (json['protocols'] as Map).map(
      (k, v) => MapEntry(
        k as String,
        (v as List)
            .map(
              (p) => ProtocolDefinition.fromJson(
                Map<String, dynamic>.from(p as Map),
              ),
            )
            .toList(),
      ),
    ),
  );
}

class ShareLink {
  const ShareLink({
    required this.name,
    required this.uri,
    this.content,
    this.filename,
  });
  final String name;
  final String uri;
  final String? content, filename;
  String get payload => content ?? uri;
  Map<String, Object?> toJson() => {
    'name': name,
    'uri': uri,
    if (content != null) 'content': content,
    if (filename != null) 'filename': filename,
  };
  factory ShareLink.fromJson(Map<String, dynamic> json) => ShareLink(
    name: json['name'] as String,
    uri: json['uri'] as String,
    content: json['content'] as String?,
    filename: json['filename'] as String?,
  );
}

class RecipientShare {
  const RecipientShare({
    required this.subscriptionUrl,
    required this.links,
    this.subscriptionUrls = const {},
  });
  final String subscriptionUrl;
  final Map<String, String> subscriptionUrls;
  final List<ShareLink> links;
  Map<String, Object?> toJson() => {
    'subscriptionUrl': subscriptionUrl,
    'subscriptionUrls': subscriptionUrls,
    'links': links.map((v) => v.toJson()).toList(),
  };
  factory RecipientShare.fromJson(Map<String, dynamic> json) => RecipientShare(
    subscriptionUrl: json['subscriptionUrl'] as String,
    subscriptionUrls: Map<String, String>.from(
      json['subscriptionUrls'] as Map? ?? const {},
    ),
    links: (json['links'] as List)
        .map((v) => ShareLink.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
  );
}
