import 'package:sky_ui_shared/sky_ui_shared.dart';

// Discovery inventory only. Live form schemas and save capabilities come from the API.
const protocolCatalog = [
  ProtocolDefinition('vless', 'VLESS', []),
  ProtocolDefinition('trojan', 'Trojan', []),
  ProtocolDefinition('shadowsocks', 'Shadowsocks', []),
  ProtocolDefinition('hysteria2', 'Hysteria 2', []),
  ProtocolDefinition('vmess', 'VMess', []),
  ProtocolDefinition('tuic', 'TUIC', []),
  ProtocolDefinition('anytls', 'AnyTLS', []),
  ProtocolDefinition('snell', 'Snell', []),
  ProtocolDefinition('mieru', 'Mieru', []),
  ProtocolDefinition('sudoku', 'Sudoku', []),
  ProtocolDefinition('trusttunnel', 'TrustTunnel', []),
  ProtocolDefinition('tuic-v4', 'TUIC v4', []),
  ProtocolDefinition('hysteria2-realm', 'Hysteria 2 Realm', []),
  ProtocolDefinition('shadowquic', 'ShadowQUIC', []),
  ProtocolDefinition('http', 'HTTP', []),
  ProtocolDefinition('socks', 'SOCKS', []),
  ProtocolDefinition('mixed', 'Mixed', []),
  ProtocolDefinition('redirect', 'Redirect', []),
  ProtocolDefinition('tproxy', 'TProxy', []),
  ProtocolDefinition('tun', 'TUN', []),
  ProtocolDefinition('tunnel', 'Tunnel', []),
  ProtocolDefinition('direct', 'Direct', []),
  ProtocolDefinition('naive', 'Naive', []),
  ProtocolDefinition('hysteria', 'Hysteria', []),
  ProtocolDefinition('shadowtls', 'ShadowTLS', []),
  ProtocolDefinition('cloudflared', 'Cloudflared', []),
  ProtocolDefinition('tailcat', 'Tailcat', []),
  ProtocolDefinition('wireguard', 'WireGuard', []),
  ProtocolDefinition('masque', 'MASQUE', []),
];

const coreCatalog = [
  CoreDescriptor('mihomo', 'mihomo'),
  CoreDescriptor('sing-box', 'sing-box'),
  CoreDescriptor('xray', 'Xray'),
];

// Inbound inventories from official documentation, checked 2026-10-31.
// These are selectable mock schemas, not validated native core configurations.
const coreProtocolInventory = {
  'mihomo': [
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'anytls',
    'snell',
    'mieru',
    'sudoku',
    'trusttunnel',
    'tuic-v4',
    'tuic',
    'hysteria2',
    'hysteria2-realm',
    'shadowquic',
    'http',
    'socks',
    'mixed',
    'redirect',
    'tproxy',
    'tun',
    'tunnel',
  ],
  'sing-box': [
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'anytls',
    'snell',
    'tuic',
    'hysteria2',
    'hysteria',
    'shadowtls',
    'naive',
    'http',
    'socks',
    'mixed',
    'direct',
    'tun',
    'redirect',
    'tproxy',
    'cloudflared',
    'tailcat',
  ],
  'xray': [
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'http',
    'socks',
    'tunnel',
    'wireguard',
    'hysteria',
    'masque',
    'tun',
  ],
};

List<ProtocolDefinition> protocolsForCore(String coreId) => [
  for (final id in coreProtocolInventory[coreId] ?? <String>[])
    protocolCatalog.firstWhere((p) => p.id == id),
];

String coreName(String coreId) =>
    coreCatalog.firstWhere((c) => c.id == coreId).name;
