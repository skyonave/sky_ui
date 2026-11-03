/// User-facing protocol scope, independent of a core's full native inventory.
class ProductProtocol {
  const ProductProtocol(
    this.id,
    this.name,
    this.engines, {
    this.tentative = false,
  });
  final String id, name;

  /// Ordered product recommendations, not a claim of implemented server support.
  final List<String> engines;
  final bool tentative;
  String get descriptionKey => 'protocol.$id';
  String get detailsKey => 'protocol.$id.details';
}

const productProtocols = [
  ProductProtocol('vless', 'VLESS', ['xray', 'mihomo', 'sing-box']),
  ProductProtocol('naive', 'NaiveProxy', ['sing-box']),
  ProductProtocol('amneziawg', 'AmneziaWG 3.1', ['amneziawg']),
  ProductProtocol('hysteria2', 'Hysteria 2', ['mihomo', 'sing-box']),
  ProductProtocol('shadowsocks', 'Shadowsocks', ['mihomo', 'sing-box', 'xray']),
  ProductProtocol('tuic', 'TUIC v5', ['mihomo', 'sing-box']),
  ProductProtocol('mieru', 'Mieru', ['mihomo']),
  ProductProtocol('trusttunnel', 'TrustTunnel', ['mihomo'], tentative: true),
];

ProductProtocol? productProtocol(String id) =>
    productProtocols.where((p) => p.id == id).firstOrNull;
