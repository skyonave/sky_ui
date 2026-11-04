// English text for keys whose Russian catalog entries need translation.
const englishStrings = <String, String>{
  'builder.guide.TCP + QUIC':
      'Enable TCP and QUIC if clients can use either transport. Open the connection port for TCP and UDP. Use TCP on networks that restrict UDP.',
  'builder.choice.transport.TCP + UDP.help':
      'Accepts TCP and UDP on the same port. Allow both protocols in the firewall.',
  'builder.choice.transport.TCP + QUIC.help':
      'Accepts TCP and QUIC on the same port. Open the port for TCP and UDP.',
  "admin.actions": "Actions",
  "admin.changePassword": "Change password",
  "admin.confirmPassword": "Repeat new password",
  "admin.currentPassword": "Current password",
  "admin.currentSession": "Current session",
  "admin.device": "Device",
  "admin.editName": "Change administrator name",
  "admin.lastSeen": "Last active",
  "admin.logoutUnavailable": "Sign-out unavailable",
  "admin.manageSessions": "Manage sessions",
  "admin.newPassword": "New password",
  "admin.password": "Password",
  "admin.passwordHint": "At least 12 characters and at most 72 UTF-8 bytes.",
  "admin.passwordMismatch": "Passwords do not match.",
  "admin.revoke": "End session",
  "admin.revokeHint": "This device will need to sign in again.",
  "admin.revokeOthers": "End other sessions",
  "admin.revokeOthersHint": "All other devices will need to sign in again.",
  "admin.revokeTitle": "End session?",
  "admin.rotationHint": "Other sessions will end after this change.",
  "admin.sessions": "Active sessions",
  "admin.title": "Administrator",
  "admin.username": "Administrator name",
  "app.demo": "Local preview",
  "app.demoHint": "Preview changes are saved in this browser",
  "app.local": "Local settings",
  "app.owner": "Owner",
  "app.version": "Version 0.1 · Preview",
  "auth.setupRequired": "Create an owner account with sudo skyui setup.",
  "auth.signIn": "Sign in",
  "auth.signOut": "Sign out",
  "auth.signingIn": "Signing in…",
  "awg.ContentPaddingAddition.help":
      "Extra padding inside encrypted packets, in bytes. Enter a number or a range, such as 0-32. Keep the default for a first connection.",
  "awg.DisableCookies.help":
      "Disables cookie checks and handshake rate limiting under load. Leave disabled to keep those protections active. Enable only when compatibility requires it. The setting is included in the client profile.",
  "awg.H.help":
      "AmneziaWG packet type identifier. Version 3.1 also protects headers with HeaderProtectionKey, which Sky UI generates for the profile. Keep the default H1–H4 values for a first connection.",
  "awg.I.help":
      "Additional obfuscation packet in AmneziaWG syntax, such as <b 0x1234><r 8>. Leave blank for normal setups. The core validates the specification when applying the configuration.",
  "awg.Jc.help":
      "Number of obfuscation packets before the handshake. Start with 4. Higher values add overhead. The client receives the same setting.",
  "awg.Jmax.help":
      "Maximum obfuscation packet size in bytes. It must be at least Jmin. Large values may cause problems on networks with a small MTU.",
  "awg.Jmin.help":
      "Minimum obfuscation packet size in bytes. It must be at most Jmax. These packets change the handshake's appearance.",
  "awg.KeepaliveTimeout.help":
      "Internal timer in seconds for waiting on keepalive traffic. It controls the protocol's behavior.",
  "awg.MaxHandshakeAttempts.help":
      "Number of handshake attempts before giving up. Start with 18.",
  "awg.RandomTrailers.help":
      "Adds random packet trailers. Requires AmneziaWG 3.1 on the client. Keep enabled for new 3.1 profiles.",
  "awg.RejectAfterTime.help":
      "Maximum lifetime of a session key in seconds. A fresh handshake is required after it expires. Start with 180.",
  "awg.RekeyAfterTime.help":
      "Session rekey interval in seconds. Start with 120. It must be below RejectAfterTime.",
  "awg.RekeyTimeout.help":
      "Time in seconds between handshake retries during rekeying. Start with 5.",
  "awg.S.help":
      "Extra AmneziaWG packet padding in bytes. S1 covers the first handshake message, S2 the reply, S3 cookies, and S4 data packets. Both peers must use matching settings.",
  "builder.addRow": "Add row",
  "builder.address": "Address",
  "builder.advanced": "Advanced parameters",
  "builder.advancedCount": "Advanced parameters: {count}",
  "builder.category.proxy": "Access protocols",
  "builder.category.system": "System listeners",
  "builder.choice.action.allow": "Allow",
  "builder.choice.action.block": "Block",
  "builder.choice.certificateId.panel": "Primary panel address",
  "builder.choice.certificateSource.custom": "Custom certificate",
  "builder.choice.certificateSource.custom.help":
      "Paste the server certificate chain and private key in PEM format. You manage renewal for this certificate.",
  "builder.choice.certificateSource.panel": "Panel certificate",
  "builder.choice.certificateSource.panel.help":
      "Use a panel IP or domain with automatic Let’s Encrypt renewal. The core can pick up the published certificate without restarting.",
  "builder.choice.dnsMode.custom": "Custom DNS servers",
  "builder.choice.dnsMode.existing": "Original configuration",
  "builder.choice.dnsMode.system": "System DNS",
  "builder.choice.native.xhttp-config.mode.auto": "auto (automatic)",
  "builder.choice.native.xhttp-config.mode.packet-up":
      "packet-up (separate requests)",
  "builder.choice.native.xhttp-config.mode.stream-one":
      "stream-one (one stream)",
  "builder.choice.native.xhttp-config.mode.stream-up":
      "stream-up (separate streams)",
  "builder.choice.security.Built-in": "Built-in encryption",
  "builder.choice.security.Built-in.help":
      "The protocol encrypts data itself. A separate TLS layer is usually unnecessary.",
  "builder.choice.security.JLS.help":
      "Authenticated TLS obfuscation. Requires a compatible client and upstream. Authentication settings are included in the profile.",
  "builder.choice.security.None": "No additional security",
  "builder.choice.security.None.help":
      "Transport without TLS. Use within a trusted network or encrypted tunnel.",
  "builder.choice.security.REALITY.help":
      "Protects the connection without a custom certificate. Keys are generated automatically.",
  "builder.choice.security.Restls.help":
      "TLS obfuscation with a configurable record sequence. Requires a reachable TLS service and compatible client. Sky UI generates the main keys.",
  "builder.choice.security.ShadowTLS.help":
      "Makes the handshake look like TLS to the selected site. Version 3 adds authentication to the obfuscation layer. Requires a compatible client and a reachable TLS upstream.",
  "builder.choice.security.TLS.help":
      "Uses a server certificate to verify the connection address.",
  "builder.choice.security.TLSMirror.help":
      "Uses a TLS service as a carrier. The client and upstream TLS cipher suites must be compatible.",
  "builder.choice.transport.IP.help":
      "Routes IP packets through a virtual interface for server networking.",
  "builder.choice.transport.KCP.help":
      "Reliable UDP stream for Shadowsocks. The client needs kcptun support and matching settings.",
  "builder.choice.transport.Mekya.help":
      "VMess HTTP transport with KCP. Requires a compatible mihomo version. Defaults usually work.",
  "builder.choice.transport.QUIC.help":
      "UDP-based transport with encrypted streams and congestion control. Open the server's UDP port to clients.",
  "builder.choice.transport.TCP.help":
      "Direct connection suitable for setups without a reverse proxy.",
  "builder.choice.transport.UDP.help":
      "UDP transport. It can help when TCP is restricted or lossy. Some networks also restrict UDP.",
  "builder.choice.transport.WebSocket.help":
      "WebSocket transport. A compatible reverse proxy is optional.",
  "builder.choice.transport.XHTTP.help":
      "HTTP transfer with configurable upload and download streams.",
  "builder.choice.transport.gRPC.help":
      "HTTP/2 streams. Any reverse proxy in the path must support gRPC.",
  "builder.choice.transport.mKCP.help":
      "VMess transport over UDP. It may help with packet loss at the cost of bandwidth and CPU usage.",
  "builder.choice.type.domain": "Domain",
  "builder.credentialsAuto":
      "Sky UI generates keys and credentials for each recipient.",
  "builder.default": "Default",
  "builder.engineInstalled": "Installed",
  "builder.engineRequired": "Installation required",
  "builder.error.boolean_invalid": "Choose a value.",
  "builder.error.certificate_invalid":
      "The certificate or key is invalid, or the pair does not match.",
  "builder.error.choice_invalid":
      "This option is incompatible with the selected settings.",
  "builder.error.format_invalid": "Check the value format.",
  "builder.error.integer_invalid": "Enter a whole number.",
  "builder.error.range_invalid": "Number is out of range.",
  "builder.error.required": "Fill in this field.",
  "builder.error.rows_invalid": "Check the rows.",
  "builder.error.too_long": "Value is too long.",
  "builder.generate": "Generate a new value",
  "builder.generateField": "Generate: {name}",
  "builder.guide.TCP":
      "Connect directly to the server without an HTTP proxy.\nChoose the available transport security next. TLS requires a server certificate.",
  "builder.guide.UDP":
      "Choose UDP when the network and client support it for this protocol. If UDP is restricted, try TCP. The next steps cover the remaining settings.",
  "builder.guide.WebSocket":
      "Use this when traffic passes through a WebSocket-compatible reverse proxy or CDN. For a direct connection, TCP is a simpler starting point.\nKeep /connect as the path. Configure the proxy to forward it to the connection port with WebSocket Upgrade. Then configure TLS.",
  "builder.guide.XHTTP":
      "XHTTP transfers data in HTTP requests and streams. Connect directly or use a compatible reverse proxy or CDN.\nStart with /connect and auto mode. Select a TLS certificate. If using a proxy, forward the selected path to the connection port.",
  "builder.guide.gRPC":
      "gRPC carries data over HTTP/2 streams and works with a compatible reverse proxy.\nKeep tunnel as the service name. If using a proxy, route the same service name to the core. Then select a TLS certificate.",
  "builder.guide.vless.TCP":
      "For a first connection, start with TCP + REALITY. It works directly without an HTTP proxy or your own certificate.\nChoose REALITY, keep xtls-rprx-vision as the Flow, and pick a suitable SNI. Sky UI prepares the keys and client profile.",
  "builder.guideTitle": "Setup guide",
  "builder.inline.native.grpc-service-name":
      "Keep tunnel as the gRPC service name. If using a reverse proxy, match the name in its route.",
  "builder.inline.native.ws-path":
      "Keep /connect. A reverse proxy must forward the same path to the connection port and allow WebSocket Upgrade.",
  "builder.inline.native.xhttp-config.host":
      "Leave blank for a direct connection. Set it when a reverse proxy expects a particular HTTP Host. Set the TLS name separately in SNI.",
  "builder.inline.native.xhttp-config.mode.auto":
      "Start with auto. The client selects the transfer mode.",
  "builder.inline.native.xhttp-config.mode.packet-up":
      "Client uploads use separate HTTP requests and downloads use a stream. Use this mode when your proxy setup expects packet-up.",
  "builder.inline.native.xhttp-config.mode.stream-one":
      "Both directions share one HTTP stream. The client and proxy must both support this mode. Start with auto if unsure.",
  "builder.inline.native.xhttp-config.mode.stream-up":
      "Uploads and downloads use separate streams. The proxy must support streaming uploads without buffering.",
  "builder.inline.native.xhttp-config.path":
      "HTTP request path, such as /connect. Keep the default if you are unsure. Sky UI puts the path in the subscription.",
  "builder.installChecking": "Looking for a compatible build…",
  "builder.installContinue": "Install and continue",
  "builder.installDetails": "Technical details",
  "builder.installRequired":
      "Install this core to continue setting up the connection.",
  "builder.installing": "Installing…",
  "builder.installingAwg":
      "Building AmneziaWG. Installation can take a few minutes.",
  "builder.isolatedPorts":
      "Each recipient gets a separate port and key. Both are included in the subscription.",
  "builder.networkRightsRequired": "Requires Linux network permissions",
  "builder.next": "Next",
  "builder.planned": "Planned",
  "builder.profileOnly":
      "Share access with a subscription or QR code. An individual protocol link is unavailable.",
  "builder.profileUnavailable":
      "A Clash profile is unavailable for this combination. Use a client that supports it.",
  "builder.reconnecting": "Reconnecting",
  "builder.review": "Connection details",
  "builder.secretStored": "Saved. Leave blank to keep it.",
  "builder.step.core": "Core",
  "builder.step.dependency": "Installation",
  "builder.step.parameters": "Parameters",
  "builder.step.protocol": "Protocol",
  "builder.step.review": "Review",
  "builder.step.security": "Obfuscation",
  "builder.step.transport": "Transport",
  "builder.systemInput":
      "This listener configures server networking and cannot be assigned to users.",
  "builder.unavailableClash": "Clash profile unavailable",
  "common.all": "All",
  "common.back": "Back",
  "common.cancel": "Cancel",
  "common.close": "Close",
  "common.copied": "Copied to clipboard",
  "common.copy": "Copy",
  "common.copyFailed": "Could not copy. Select and copy the text manually.",
  "common.create": "Create connection",
  "common.delete": "Delete",
  "common.deleted": "Deleted",
  "common.disable": "Disable",
  "common.edit": "Edit",
  "common.enable": "Enable",
  "common.error": "Error",
  "common.help": "Help for {name}",
  "common.invalidName": "Enter a name",
  "common.invalidPort": "Enter a port number from 1 to 65535",
  "common.loading": "Loading…",
  "common.refresh": "Refresh",
  "common.next": "Continue",
  "common.noUsers": "Unassigned",
  "common.portUsed": "Another connection already uses this port",
  "common.required": "Fill in the required fields",
  "common.save": "Save",
  "common.saved": "Changes saved",
  "common.share": "Share",
  "connections.active": "Active",
  "connections.activeCount": "Active connections",
  "connections.add": "New connection",
  "connections.all": "All connections",
  "connections.configured": "Configured",
  "connections.count": "Total connections",
  "connections.description": "Protocols, ports, and access on your server.",
  "connections.disabled": "Disabled",
  "connections.empty": "No connections found",
  "connections.emptyHint": "Change the filter or create a connection.",
  "connections.search": "Search connections",
  "connections.title": "Connections",
  "core.alternatives": "Other cores",
  "core.architecture": "Shared controls for separate core adapters",
  "core.changed": "Core state changed in the preview",
  "core.current": "CURRENT CORE",
  "core.demo": "Preview data. systemd controls are unavailable.",
  "core.description": "Manage your cores.",
  "core.feedback.restart": "Core restarted.",
  "core.feedback.start": "Core started.",
  "core.feedback.stop": "Core stopped.",
  "core.feedback.validate":
      "Core configuration is valid. This check did not open a connection or restart the service.",
  "core.future": "Adapter planned",
  "core.install": "Install",
  "core.installHint":
      "Install the approved core version. Saved connections and keys are preserved. The core can start after installation.",
  "core.memory": "Memory",
  "core.missingStatus": "Core not installed",
  "core.notInstalled": "Not installed",
  "core.remove": "Remove core",
  "core.removeHint":
      "The core will stop and be removed. Its connections will stop working. Connections, users, and keys are preserved for reinstallation.",
  "core.restart": "Restart",
  "core.restarted": "Restart simulated",
  "core.service": "Service",
  "core.start": "Start",
  "core.stop": "Stop",
  "core.title": "Cores",
  "core.update": "Update core",
  "core.updateShort": "Update",
  "core.updatesAvailable": "An approved core version is available.",
  "core.updatesChecking": "Checking approved versions…",
  "core.updatesNone": "No approved updates",
  "core.uptime": "Uptime",
  "core.version": "Version",
  "coreProgress.stage.activate": "Installing the core",
  "coreProgress.stage.build": "Building the core",
  "coreProgress.stage.complete": "Core installed",
  "coreProgress.stage.discovery": "Checking the version",
  "coreProgress.stage.download": "Downloading the core",
  "coreProgress.stage.health": "Checking startup",
  "coreProgress.stage.rollback": "Rollback",
  "coreProgress.stage.toolchain": "Downloading Go SDK",
  "coreProgress.stage.validate": "Validating configuration",
  "coreProgress.state.running": "Installing",
  "coreProgress.step.activate": "Install",
  "coreProgress.step.build": "Build",
  "coreProgress.step.download": "Download",
  "coreProgress.step.validate": "Validation",
  "coreSettings.accessRules": "Access rules",
  "coreSettings.apply": "Apply",
  "coreSettings.applyHint":
      "The running core will restart briefly. If applying fails, the previous settings will be restored.",
  "coreSettings.applying": "Applying…",
  "coreSettings.blockPrivate": "Block private addresses",
  "coreSettings.dnsMode": "Name resolution",
  "coreSettings.forCore": "{core} settings",
  "coreSettings.group.access": "Access",
  "coreSettings.group.logs": "Logs",
  "coreSettings.help.accessRules":
      "Up to 64 rules, evaluated top to bottom. Domains include subdomains. Enter IP ranges in CIDR notation. Private address protection runs first. Allow uses DIRECT. Unmatched destinations keep the previous route.",
  "coreSettings.help.blockPrivate":
      "Blocks recipient access to loopback, private networks, link-local addresses, and cloud metadata, including IPv6. The server's public IP is excluded. These proxy rules apply to new connections after a restart.",
  "coreSettings.help.dnsMode":
      "Original configuration keeps the previous DNS settings. System DNS uses Linux resolvers. Custom servers replace the core DNS policy. No public DNS port is opened.",
  "coreSettings.help.logLevel":
      "The core records the selected level and higher. debug may include request addresses. silent turns off core logs. The Logs tab filters recorded entries separately.",
  "coreSettings.help.resolvers":
      "Enter one server per line, up to 16. Examples: 1.1.1.1, https://dns.google/dns-query, and tls://one.one.one.one. Resolver names use system DNS. DoH and DoT certificates are verified.",
  "coreSettings.help.ruleAction":
      "Block rejects matching requests. Allow sends them directly. Rule order matters.",
  "coreSettings.help.ruleType":
      "A domain and its subdomains, or an IP network in CIDR notation.",
  "coreSettings.help.sing-box.logLevel":
      "sing-box records the selected level and higher. disabled turns off core logs. trace and debug are useful for troubleshooting and may include request addresses. The Logs tab filters recorded entries separately.",
  "coreSettings.help.sing-box.resolvers":
      "Choose one primary server: 1.1.1.1, udp://1.1.1.1:53, https://dns.google/dns-query, or tls://one.one.one.one. Resolver names use system DNS. DoH and DoT certificates are verified.",
  "coreSettings.help.target":
      "Enter a domain or CIDR without a scheme or port. Examples: example.com, 203.0.113.0/24, or 2001:db8::/32. A domain rule applies when the client sends the name.",
  "coreSettings.help.xray.logLevel":
      "Xray records the selected level and higher. none disables access and error logs. Turning them back on restores their previous paths. debug may include request addresses. The Logs tab filters recorded entries separately.",
  "coreSettings.help.xray.resolvers":
      "Up to 16 servers, one per line: 1.1.1.1, udp://1.1.1.1:53, tcp://1.1.1.1:53, or https://dns.google/dns-query. Use IPs for UDP and TCP. DoH accepts a hostname. DoH and TCP use the core's direct route. DoH certificates are verified. This Xray version does not support plain DoT.",
  "coreSettings.logLevel": "Core log level",
  "coreSettings.resolver": "DNS server",
  "coreSettings.resolvers": "DNS servers",
  "coreSettings.ruleAction": "Action",
  "coreSettings.ruleType": "Type",
  "coreSettings.target": "Address",
  "coreSettings.title": "Core settings",
  "data.applying": "Applying…",
  "data.persisted": "Server data",
  "diagnostics.action": "Diagnostics",
  "diagnostics.code.access_ready":
      "The connection is enabled and active users have access.",
  "diagnostics.code.address_ready": "The probe uses the configured IP address.",
  "diagnostics.code.awg_client_required":
      "AmneziaWG does not use TLS or SNI. Test its handshake with an AmneziaWG 3.1 client.",
  "diagnostics.code.binary_missing":
      "The core is missing. Install it on the Cores page.",
  "diagnostics.code.blocked":
      "Skipped because a required earlier check failed.",
  "diagnostics.code.cancelled": "Check stopped.",
  "diagnostics.code.check_failed":
      "The check could not finish. Try again and check the Sky UI logs if it keeps failing.",
  "diagnostics.code.configuration_out_of_sync":
      "The configuration changed outside the panel or was not applied. Restore a synchronized configuration first.",
  "diagnostics.code.configuration_ready":
      "Saved settings match the configuration on disk.",
  "diagnostics.code.connection_disabled":
      "Enable this connection in the connection table.",
  "diagnostics.code.controller_not_ready":
      "The process is running but its control interface is not ready. Check the logs.",
  "diagnostics.code.core_failed": "The core failed. Check its logs.",
  "diagnostics.code.core_stopped":
      "The core is stopped. Start it on the Cores page.",
  "diagnostics.code.diagnostic_timeout":
      "The diagnostic deadline elapsed. Remaining checks were stopped.",
  "diagnostics.code.diagnostics_unsupported":
      "Diagnostics are unavailable for this core.",
  "diagnostics.code.dns_failed":
      "Could not resolve the handshake site. Check the hostname and server DNS.",
  "diagnostics.code.dns_ready":
      "DNS resolved the name. Further checks use these IPs without looking it up again.",
  "diagnostics.code.dns_timeout":
      "DNS timed out. Check server DNS and connectivity.",
  "diagnostics.code.engine_ready":
      "The core service is running and reports that it is ready.",
  "diagnostics.code.interface_missing":
      "The AmneziaWG interface is missing. Check the core logs.",
  "diagnostics.code.listener_identity_unavailable":
      "Could not verify socket ownership.",
  "diagnostics.code.listener_missing":
      "The expected socket was not found. Check the port, bind address, and core logs.",
  "diagnostics.code.listener_ready":
      "The socket belongs to the core service account.",
  "diagnostics.code.listeners_sampled":
      "Checked the first 16 sockets. The rest were not checked.",
  "diagnostics.code.native_invalid":
      "The core rejected its configuration. Check the settings and service logs.",
  "diagnostics.code.native_ready":
      "The core accepted its configuration file without starting or restarting the service.",
  "diagnostics.code.no_active_listeners":
      "No active listeners to check. Granting access can activate a listener.",
  "diagnostics.code.no_recipients":
      "No active users have this connection. Grant access on the Users page.",
  "diagnostics.code.not_applicable":
      "This protocol does not require a separate TLS check.",
  "diagnostics.code.openssl_missing":
      "OpenSSL is unavailable, so the TLS check could not run.",
  "diagnostics.code.platform_unsupported": "This check is available on Linux.",
  "diagnostics.code.quic_client_required":
      "The UDP socket was checked. Test the QUIC handshake with a compatible client.",
  "diagnostics.code.service_missing":
      "The core service is missing. Check the installation.",
  "diagnostics.code.settings_invalid":
      "Connection settings or the selected certificate are no longer valid. Open the connection settings.",
  "diagnostics.code.snapshot_current":
      "Settings and service state remained unchanged during the check.",
  "diagnostics.code.state_changed":
      "Settings or the service changed during the check. Run diagnostics again.",
  "diagnostics.code.target_invalid":
      "Invalid probe target or SNI. Check the connection settings.",
  "diagnostics.code.target_not_public":
      "The handshake site resolves to a private IP. Automatic external probing requires a public IP.",
  "diagnostics.code.tcp_failed":
      "Could not connect over TCP. Check the network, address, and port.",
  "diagnostics.code.tcp_ready":
      "The server established a TCP connection to the target.",
  "diagnostics.code.tcp_refused":
      "The target refused TCP. Check its port and service.",
  "diagnostics.code.tcp_timeout":
      "TCP timed out. Check the target address, port, and server's outgoing network.",
  "diagnostics.code.tls_expired":
      "The certificate expired. Check renewal and the server clock.",
  "diagnostics.code.tls_failed":
      "TLS handshake failed. Check SNI, the certificate, and target availability.",
  "diagnostics.code.tls_name_mismatch":
      "The certificate does not match SNI. Check the server name in the connection settings.",
  "diagnostics.code.tls_not_yet_valid":
      "The certificate is not valid yet. Check the server date and time.",
  "diagnostics.code.tls_ready":
      "TLS handshake succeeded. Certificate trust, expiry, and hostname were verified.",
  "diagnostics.code.tls_timeout":
      "TCP connected but TLS timed out. SNI filtering or a problem at the target may be involved.",
  "diagnostics.code.tls_untrusted":
      "The certificate is not trusted. Check the chain. A self-signed certificate must be trusted on the client.",
  "diagnostics.code.tls_version":
      "The handshake site did not negotiate the required TLS version. REALITY requires TLS 1.3.",
  "diagnostics.code.validator_missing":
      "Could not start validation because the required command is missing.",
  "diagnostics.code.validator_timeout":
      "The core did not finish validation in time.",
  "diagnostics.current": "Current check: {step}",
  "diagnostics.detail.checked": "Checked",
  "diagnostics.detail.recipients": "Recipients",
  "diagnostics.detail.total": "Total",
  "diagnostics.error.diagnostics_busy":
      "Another diagnostic run is active or finishing. Try again in a few seconds.",
  "diagnostics.error.diagnostics_rate_limited":
      "Diagnostics are being started too frequently. Try again in a few seconds.",
  "diagnostics.error.failed":
      "Could not start diagnostics. Check the connection to the panel and try again.",
  "diagnostics.error.not_found":
      "The connection was removed or the diagnostic result expired.",
  "diagnostics.error.state_changed":
      "Settings changed. Run diagnostics for the current configuration.",
  "diagnostics.outcome.cancelled": "Check stopped",
  "diagnostics.outcome.failed": "Issues found",
  "diagnostics.outcome.passed": "Server checks complete",
  "diagnostics.outcome.pending": "Waiting",
  "diagnostics.outcome.running": "Checking…",
  "diagnostics.outcome.warning": "Warnings found",
  "diagnostics.progress": "Diagnostic progress",
  "diagnostics.reconnecting": "Connection lost. Waiting for the result…",
  "diagnostics.retry": "Run again",
  "diagnostics.scope":
      "Checks run from the server. Client authentication and reachability from outside are not tested.",
  "diagnostics.starting": "Starting checks…",
  "diagnostics.state.failed": "Failed",
  "diagnostics.state.pending": "Waiting",
  "diagnostics.state.running": "Checking",
  "diagnostics.state.skipped": "Skipped",
  "diagnostics.state.warning": "Warning",
  "diagnostics.step.access": "User access",
  "diagnostics.step.configuration": "Applied settings",
  "diagnostics.step.dns": "Probe address",
  "diagnostics.step.engine": "Core",
  "diagnostics.step.freshness": "Result freshness",
  "diagnostics.step.listener": "Connection socket",
  "diagnostics.step.listeners": "Connection ports",
  "diagnostics.step.native": "Core configuration",
  "diagnostics.step.tcp": "TCP reachability",
  "diagnostics.step.tls": "TLS and SNI",
  "diagnostics.title": "Connection diagnostics",
  "error.interface_in_use": "This network interface name is already in use.",
  "feature.unavailable": "Unavailable",
  "field.certificate": "Certificate path",
  "field.certificateId": "Certificate",
  "field.certificateSource": "TLS certificate",
  "field.cipher": "Cipher",
  "field.clientCertificate": "Client PEM certificate",
  "field.clientPrivateKey": "Client PEM private key",
  "field.congestion": "Congestion control",
  "field.destination": "Destination",
  "field.hysteriaMasquerade": "HTTPS cover site",
  "field.interfaceAddress": "Interface address",
  "field.interfaceName": "Interface name",
  "field.listen": "Bind address",
  "field.name": "Connection name",
  "field.network": "Network protocol",
  "field.obfs": "Obfuscation",
  "field.obfsPassword": "Obfuscation password",
  "field.password": "Password",
  "field.path": "WebSocket path",
  "field.port": "Port",
  "field.privateKey": "Private key path",
  "field.realityMaxTimeDiff": "Maximum REALITY clock skew, s",
  "field.security": "Obfuscation",
  "field.serverAddress": "Server tunnel address",
  "field.serverName": "Server name (SNI)",
  "field.serviceName": "gRPC service name",
  "field.tlsCertificate": "PEM certificate chain",
  "field.tlsMaxVersion": "Maximum TLS version",
  "field.tlsMinVersion": "Minimum TLS version",
  "field.tlsPrivateKey": "PEM private key",
  "field.token": "Token",
  "field.transport": "Transport",
  "field.username": "Username",
  "field.wireguardKey": "WireGuard private key",
  "help.alterId":
      "Legacy VMess identifiers. Keep 0 for current clients to use AEAD. Change only for an older client that requires it.",
  "help.certificate":
      "Absolute path to the certificate on the Linux server, such as /etc/sky_ui/certs/fullchain.pem. The core service needs read access.",
  "help.certificateId":
      "The panel certificate follows the primary panel address. You can also choose a certificate issued for a specific IP or domain. SNI is filled in automatically. Refresh subscriptions after changing the domain.",
  "help.certificateSource":
      "Use the panel's automatically renewed Let’s Encrypt certificate or supply your own PEM pair. A panel certificate appears after HTTPS setup and issuance.",
  "help.cipher":
      "Shadowsocks cipher. Both the client and server must support the selected cipher and key format. The 2022 ciphers have specific key requirements.",
  "help.clientAlpn":
      "Optional client ALPN values, one per line. The default usually works. gRPC uses h2, and WebSocket uses http/1.1.",
  "help.clientCertificate":
      "Recipient TLS certificate for mTLS. The server must trust its public certificate or CA. The client profile contains this certificate and its key.",
  "help.clientCipher":
      "Client-side VMess encryption. Auto chooses a compatible option. None and zero disable the corresponding inner layer. Use suitable transport security when selecting either.",
  "help.clientEchConfig":
      "Public base64 ECH config matching the server's private ECH key. It is included in the client profile. Leave it blank to disable client ECH.",
  "help.clientFingerprint":
      "Browser ClientHello profile, such as Chrome or Firefox. It controls how the TLS handshake looks and must be supported by the client.",
  "help.clientPrivateKey":
      "Private key for the client certificate. It is included in the recipient profile. Keep the server certificate key separate.",
  "help.congestion":
      "Controls sending speed during network congestion. bbr, cubic, and new_reno respond differently to latency and loss. Options depend on the core version.",
  "help.congestionController":
      "TUIC congestion control. Start with bbr. Compare cubic and new_reno on your network if needed. The client profile includes your selection.",
  "help.destination":
      "Destination host and port, such as 127.0.0.1:8080. The exact format depends on the core.",
  "help.dns":
      "DNS servers for the client profile, one IPv4 per line. The recipient device uses these after connecting. This AmneziaWG server routes IPv4. The VPS system DNS stays separate.",
  "help.downMbps":
      "Expected server download bandwidth for Hysteria 2. Use the actual link speed as a starting point and test the connection.",
  "help.flow":
      "VLESS transfer mode. xtls-rprx-vision is a common choice for TCP with REALITY. None disables Vision. Sky UI copies the chosen value to links and client profiles.",
  "help.handshakePort":
      "Port of the TLS cover service, usually 443. Use it with the server name and a service that supports the required handshake.",
  "help.hysteriaMasquerade":
      "Optional HTTPS site that Hysteria 2 serves to ordinary HTTP/3 requests without VPN authentication. Use a public site without private data. Leave blank for a 404 response. The server still needs a certificate, and Salamander or Gecko is configured separately.",
  "help.interfaceAddress":
      "Virtual interface address with a prefix length, such as 10.0.0.1/24. Choose a subnet that does not overlap existing routes or networks.",
  "help.interfaceName":
      "Virtual interface name, such as sky-tun. It must be unused on the server. Creating an interface requires network permissions.",
  "help.keepalive":
      "Interval in seconds between client keepalive packets. Use 25 to keep NAT mappings alive, or 0 to disable periodic packets.",
  "help.listen":
      "Address the core binds to. :: listens on all IPv6 interfaces and on IPv4 with typical Linux settings. Use 0.0.0.0 for IPv4 only or 127.0.0.1 for local access. Allow the port in the firewall too.",
  "help.mtu":
      "Maximum packet size in bytes. Start with 1500. Encapsulation may require a lower value. Limits depend on the core.",
  "help.naiveCongestionControl":
      "Server congestion control for Naive HTTP/3. Start with BBR. Compare CUBIC and Reno if speeds vary. This setting does not affect HTTP/2.",
  "help.name":
      "Choose a name you will recognize in the panel and subscriptions, such as Main or Phone. It does not affect the protocol.",
  "help.network":
      "Traffic accepted by this connection: TCP, UDP, or both. Choose based on app and core support. Open the UDP port in the firewall when using UDP.",
  "help.obfs":
      "Additional traffic obfuscation. With Salamander, the client and server use the same password. Authentication and certificate settings still apply.",
  "help.obfsPassword":
      "Shared Salamander secret. Use the same value on the client and server. User access credentials are separate.",
  "help.password":
      "Authentication secret or protocol key. Use a unique random value of the required format. Use only sample data in the preview.",
  "help.path":
      "HTTP path for WebSocket, such as /connect. The client, server, and any reverse proxy must use the same path.",
  "help.port":
      "Choose a free port from 1 to 65535 and allow it in the server firewall and VPS network settings. Generate checks a random port on the server. SSH, controller, and panel ports are reserved. The panel uses 80 and 443 for HTTPS.",
  "help.privateKey":
      "Absolute path to the certificate private key, such as /etc/sky_ui/certs/privkey.pem. The key stays on the server.",
  "help.realityMaxTimeDiff":
      "The server rejects handshakes beyond the configured clock skew, for example 60 s. Sync the server and client clocks. Use 0 to keep the core default without a time limit.",
  "help.realityServerName":
      "External HTTPS hostname for the REALITY handshake. It must be reachable from the server and support TLS 1.3, preferably with HTTP/2. Enter only the hostname. The client uses it as SNI and the server uses it as the target.",
  "help.realityTarget":
      "HTTPS host and port reachable from the VPS, such as www.kernel.org:443. REALITY uses it for the TLS handshake. SNI must match that site. Filtering of the target on the path can cause timeouts.",
  "help.realmToken":
      "Shared key for the Realm coordinator and its participants. Use a long random value in the Hysteria 2 Realm settings. Recipients still have separate VPN passwords.",
  "help.routingMark":
      "Linux socket or packet mark for outgoing traffic from this listener. Use only with an existing policy routing setup.",
  "help.routingProxy":
      "Outbound used by this listener, usually DIRECT. A different name must already exist in the core configuration.",
  "help.routingRule":
      "Existing core rule set for this listener. Leave blank for normal handling. Define rule sets in the core configuration first.",
  "help.security":
      "Protects traffic between the client and server. REALITY uses an external HTTPS site and an X25519 key pair. Sky UI keeps the private key on the server and includes the public key in links and subscriptions.",
  "help.serverAddress":
      "Private IPv4 address with a /24 to /30 prefix, such as 10.66.0.1/24. Sky UI allocates a free address for each user. Choose a different subnet for each connection. Changing the subnet after granting access requires moving client addresses.",
  "help.serverName":
      "Domain sent by the client during the handshake. For TLS it must match the certificate, for example vpn.example.com. For REALITY choose it together with the target.",
  "help.serviceName":
      "gRPC service name, such as tunnel. It must match on the client and server and in any reverse proxy route.",
  "help.tlsCertificate":
      "Enter the full PEM chain with the server certificate first and the intermediate CAs after it. The server name must match the certificate. Sky UI validates the format and key pair.",
  "help.tlsMaxVersion":
      "Highest TLS version the server accepts. Keep 1.3 unless compatibility requires 1.2. The maximum cannot be below the minimum.",
  "help.tlsMinVersion":
      "Choose 1.2 or 1.3. Setting 1.3 requires support in both the client and any proxy in between. QUIC uses TLS 1.3. The client still verifies the certificate.",
  "help.tlsPrivateKey":
      "Private key for the selected server certificate. It stays on the server. When editing, leave it blank to keep the existing key.",
  "help.token":
      "Secret token for the corresponding service. Use only sample data in the preview.",
  "help.transport":
      "TCP connects directly. WebSocket uses HTTP Upgrade and can require a path. gRPC uses HTTP/2 and a service name. The client and server transport settings must match.",
  "help.tuicAuthTimeout":
      "Time the server waits for authentication after connecting. Start with 3 s. Raising it can help high-latency clients but unauthenticated connections use resources for longer.",
  "help.tuicHeartbeat":
      "Interval between QUIC heartbeat packets. Start with 10 s. A shorter interval increases traffic. A longer interval may cause problems behind NAT with short timeouts.",
  "help.udpTimeout":
      "Idle UDP session timeout in seconds. Start with 300 s. A short timeout can interrupt calls or games during pauses. A longer timeout keeps resources allocated.",
  "help.upMbps":
      "Expected server upload bandwidth for Hysteria 2 congestion control. Use the actual link speed.",
  "help.username":
      "Authentication name for protocols that support it. Each recipient gets separate credentials.",
  "help.vlessEncryption":
      "Additional VLESS encryption. X25519MLKEM768 generates keys automatically and needs a compatible client. It is a separate layer from TLS or REALITY.",
  "help.websocketHost":
      "Host header the client sends, such as vpn.example.com. Use it for reverse proxy routing. Xray also checks the header at the listener. SNI and certificate settings are separate. Leave blank for the client default.",
  "help.wireguardKey":
      "Private key for the WireGuard server interface. Share only its public key with clients.",
  "help.xhttpHost":
      "Optional HTTP hostname for reverse proxy routing. Leave blank for a direct connection. This setting is separate from the server address and SNI.",
  "help.xhttpMode":
      "Start with auto so the client chooses a compatible mode. packet-up uses separate requests, stream-up streams uploads, and stream-one uses one bidirectional stream. Support depends on the client and reverse proxy.",
  "help.xhttpPath":
      "HTTP request path, such as /tunnel. Use the same path on the client and server. If using a reverse proxy, forward it to the connection port.",
  "logs.all": "All levels",
  "logs.clear": "Clear",
  "logs.clearHint":
      "Clear all entries buffered by the panel, including those hidden by filters? New events will continue to arrive. Linux system logs are unaffected.",
  "logs.clearTitle": "Clear logs?",
  "logs.cleared": "Logs cleared",
  "logs.connectionSaved": "Connection saved: {name}",
  "logs.deleted": "Record deleted: {name}",
  "logs.description": "Panel events and core messages.",
  "logs.empty": "No log entries yet",
  "logs.latest": "Jump to latest",
  "logs.level": "Level",
  "logs.live": "Live",
  "logs.noMatches": "No entries at the selected levels",
  "logs.reconnecting": "Connecting to logs…",
  "logs.started": "Panel preview started",
  "logs.title": "Logs",
  "users.devices": "Devices",
  "logs.toggled": "Status changed: {name}",
  "logs.userSaved": "User saved: {name}",
  "maintenance.backupHint":
      "Back up users, connections, settings, the administrator account, and certificates? The panel will restart briefly. The core will continue running.",
  "maintenance.backups": "Backups",
  "maintenance.create": "Create backup",
  "maintenance.download": "Download",
  "maintenance.empty": "No backups yet.",
  "maintenance.loading": "Checking the Sky UI catalog…",
  "maintenance.restore": "Restore",
  "maintenance.restoreHint":
      "Replace the current state with this backup? A safety backup is created first. Services will restart and you will need to sign in again. Restore is available on the same server and panel version.",
  "maintenance.secrets":
      "Backups contain keys and access credentials. Store the downloaded archive securely.",
  "maintenance.status.completed": "Operation completed.",
  "maintenance.status.queued": "Waiting to start…",
  "maintenance.status.running":
      "Operation in progress. The panel will reconnect automatically.",
  "maintenance.updateHint":
      "This version is approved for Sky UI. The panel checks the catalog, artifact SHA-256, and configuration before installing it. A running core restarts briefly. If the update fails, the previous version is restored.",
  "mihomo.native.addr.help":
      "ShadowQUIC cover service in host:port format. It must support QUIC or HTTP/3.",
  "mihomo.native.aead-method.help":
      "Additional Sudoku AEAD. Client and server must use the same method. none disables this layer.",
  "mihomo.native.alpn.help":
      "TLS application protocol identifiers, one per line. Keep the core defaults unless the cover service or client requires a specific ALPN.",
  "mihomo.native.authentication-timeout.help":
      "Time allowed to authenticate a new QUIC connection. A short timeout can affect clients on high-latency networks.",
  "mihomo.native.auto-detect-interface.help":
      "Selects an outbound interface automatically so the core's outgoing connections are not sent back through TUN.",
  "mihomo.native.auto-route.help":
      "Creates routes through TUN. Enable only when intentionally capturing server traffic and when exceptions are configured.",
  "mihomo.native.cipher.help":
      "Shadowsocks cipher. Use a cipher supported by the client. Sky UI generates appropriately sized SS 2022 keys. Changing the cipher may require refreshing subscriptions.",
  "mihomo.native.congestion-controller.help":
      "Congestion control. BBR estimates bandwidth and RTT, cubic and new_reno respond to loss, and brutal needs matching bandwidth settings.",
  "mihomo.native.device.help":
      "Virtual TUN interface name. Use a name that is free on the host. Creating the interface requires network permissions.",
  "mihomo.native.disable-http-mask.help":
      "Disables Sudoku HTTP obfuscation. The client profile includes the corresponding http-mask setting.",
  "mihomo.native.dns-hijack.help":
      "DNS destinations TUN intercepts, such as any:53. Enter one per line and configure core DNS first.",
  "mihomo.native.dns-mode.help":
      "TUN DNS handling mode. It must match the core DNS configuration and affects name resolution for intercepted apps.",
  "mihomo.native.down.help":
      "Expected download bandwidth in the protocol's format. This tunes the corresponding flow control.",
  "mihomo.native.grpc-service-name.help":
      "gRPC service name. The client profile and server use the same name.",
  "mihomo.native.handshake-timeout.help":
      "Time allowed to complete the handshake. A short timeout can reject clients on slow networks.",
  "mihomo.native.host.help":
      "HTTP Host or cover service name. Match the configured reverse proxy route or upstream.",
  "mihomo.native.http-mask-mode.help":
      "Sudoku HTTP obfuscation mode: legacy, stream, poll, or auto. The profile sets the matching client value.",
  "mihomo.native.ignore-client-bandwidth.help":
      "Uses the server's Hysteria 2 bandwidth policy instead of the bandwidth reported by the client.",
  "mihomo.native.inet4-address.help":
      "TUN IPv4 addresses in CIDR notation, one per line, such as 172.19.0.1/30. Avoid overlapping server networks.",
  "mihomo.native.inet6-address.help":
      "TUN IPv6 addresses in CIDR notation, one per line. Configure IPv6 first and avoid overlapping networks.",
  "mihomo.native.masquerade.help":
      "Site or response used for unauthenticated HTTP/3 requests, in the format expected by the core.",
  "mihomo.native.max-idle-time.help":
      "Maximum QUIC idle time before the connection closes. Consider client keepalives and network delays.",
  "mihomo.native.max-udp-relay-packet-size.help":
      "Maximum UDP relay packet size in bytes. The client and server must support the selected size.",
  "mihomo.native.mode.help":
      "Mode for the selected module. Choose a value supported by the client and server.",
  "mihomo.native.mtu.help":
      "Maximum packet size in bytes. Values that are too large can cause fragmentation. Small values increase overhead.",
  "mihomo.native.obfs-password.help":
      "Shared obfuscation key. It must match on both sides and is included in the client profile. Recipient passwords are separate.",
  "mihomo.native.obfs.help":
      "Extra UDP obfuscation for Hysteria 2. Salamander uses the same password on both sides. Sky UI includes it in the client profile.",
  "mihomo.native.padding-max.help":
      "Maximum Sudoku padding. It must fit the client's limits and be at least the minimum.",
  "mihomo.native.padding-min.help":
      "Minimum Sudoku padding. Extra padding changes traffic appearance and adds bandwidth overhead. Keep it at or below the maximum.",
  "mihomo.native.padding-scheme.help":
      "AnyTLS padding scheme, one protocol rule per line. It controls packet sizes and ordering. Keep the core default for typical setups.",
  "mihomo.native.path-root.help":
      "Root path for Sudoku HTTP obfuscation. It must match the client.",
  "mihomo.native.path.help":
      "HTTP transport path. The client and server must use the same value.",
  "mihomo.native.route-address.help":
      "IPv4 or IPv6 networks routed to TUN automatically. Use with auto-route and enter one CIDR per line.",
  "mihomo.native.route-exclude-address.help":
      "IPv4 or IPv6 networks excluded from TUN, one CIDR per line. Keep a route for administrative access.",
  "mihomo.native.sni.help":
      "TLS server name for the cover service or coordinator. It must match the certificate and usually matches the target hostname.",
  "mihomo.native.stack.help":
      "TUN TCP/IP stack. gvisor runs in the process, system uses the OS stack, and mixed combines both. Support depends on the build and OS.",
  "mihomo.native.strict-route.help":
      "Restricts bypassing TUN. This can affect local network and DNS reachability.",
  "mihomo.native.target.help":
      "Fixed destination in host:port format. The tunnel forwards incoming traffic there.",
  "mihomo.native.traffic-pattern.help":
      "Mieru traffic pattern in the format used by this core version. It must match the client implementation. Leave blank for the default.",
  "mihomo.native.udp-timeout.help":
      "Idle UDP session timeout. Shorter values free resources sooner but may interrupt apps that send packets infrequently.",
  "mihomo.native.udp.help":
      "Allows UDP relay on this listener. Turning it off blocks UDP even if the client supports it.",
  "mihomo.native.up.help":
      "Expected upload bandwidth in the protocol's format. Set it close to the actual link rate to avoid additional loss.",
  "mihomo.native.version.help":
      "Snell protocol version. The client must support it. The version affects handshake format and UDP support.",
  "mihomo.native.ws-path.help":
      "WebSocket HTTP path. The client profile uses the same path. Any reverse proxy must forward it and allow WebSocket Upgrade.",
  "mihomo.native.xhttp-config.host.help":
      "HTTP Host for XHTTP. Leave blank for a direct connection. Set it when the reverse proxy route expects a hostname. Use SNI separately for TLS certificate selection and verification.",
  "mihomo.native.xhttp-config.mode.help":
      "Start with auto. packet-up sends separate HTTP uploads, stream-up uses separate upload and download streams, and stream-one uses one shared stream. Select a manual mode only for a compatible proxy setup. Sky UI includes it in the subscription.",
  "mihomo.native.xhttp-config.path.help":
      "URL path that accepts XHTTP requests. Start with /connect. Sky UI copies it to the client profile. If you use a reverse proxy or CDN, forward this path to the connection port.",
  "mihomo.native.zero-rtt.help":
      "Allows QUIC early data on reconnection. It reduces reconnect latency and requires compatible client settings.",
  "modal.core": "Core",
  "modal.deleteHint": "“{name}” will be removed from the local preview.",
  "modal.deleteTitle": "Delete this record?",
  "modal.edit": "Edit connection",
  "modal.general": "General parameters",
  "modal.new": "New connection",
  "modal.previewOnly":
      "Preview only. The core does not validate certificates, keys, or network settings here.",
  "modal.protocol": "Choose a protocol",
  "modal.protocolHint": "Choose a protocol to see its settings.",
  "modal.protocolNote":
      "This preview shows six sample forms. More protocols become available when a core is connected.",
  "modal.protocolSettings": "Protocol parameters",
  "modal.step1": "Protocol",
  "modal.step2": "Settings",
  "modal.stepCore": "Core",
  "nav.connections": "Connections",
  "nav.core": "Cores",
  "nav.logs": "Logs",
  "nav.overview": "Overview",
  "nav.settings": "Settings",
  "nav.system": "System",
  "nav.users": "Users",
  "nav.workspace": "Workspace",
  "overview.activity": "Recent activity",
  "overview.connections": "Recent connections",
  "overview.description": "Your server, connections, and users in one place.",
  "overview.open": "Open all",
  "overview.ready": "Ready to use",
  "overview.readyHint": "Add a connection and grant access in a few steps.",
  "overview.title": "Overview",
  "panelUpdate.artifact": "File",
  "panelUpdate.available": "v{version} is available",
  "panelUpdate.check": "Check",
  "panelUpdate.checkFailed": "Could not check for updates",
  "panelUpdate.checked": "Last checked",
  "panelUpdate.checking": "Checking for updates…",
  "panelUpdate.checkingAction": "Checking…",
  "panelUpdate.current": "The latest version is installed",
  "panelUpdate.details": "Update details",
  "panelUpdate.downloadProgress": "Downloading update files",
  "panelUpdate.finished": "Finished",
  "panelUpdate.hint":
      "The panel restarts briefly. Settings, connections, and administrator access are preserved. Cores continue running. If startup fails, the previous version is restored.",
  "panelUpdate.installed": "Installed",
  "panelUpdate.none": "No updates available",
  "panelUpdate.notRestored": "Incomplete",
  "panelUpdate.reason": "Reason",
  "panelUpdate.release": "Release",
  "panelUpdate.restored": "Completed",
  "panelUpdate.result": "Result",
  "panelUpdate.rollback": "Rollback",
  "panelUpdate.running": "Updating Sky UI…",
  "panelUpdate.sourceVersion": "Previous version",
  "panelUpdate.stage.activate": "Starting the panel",
  "panelUpdate.stage.backup": "Backup",
  "panelUpdate.stage.build": "Building Sky UI",
  "panelUpdate.stage.complete": "Complete",
  "panelUpdate.stage.discovery": "Checking the release",
  "panelUpdate.stage.download": "Downloading",
  "panelUpdate.stage.health": "Checking startup",
  "panelUpdate.stage.install": "Installing",
  "panelUpdate.stage.prepare": "Preparing",
  "panelUpdate.stage.rollback": "Rollback",
  "panelUpdate.stage.toolchain": "Preparing Dart SDK",
  "panelUpdate.stage.validate": "Verifying the build",
  "panelUpdate.stageLabel": "Stage",
  "panelUpdate.started": "Started",
  "panelUpdate.state.available": "Available",
  "panelUpdate.state.checking": "Checking",
  "panelUpdate.state.completed": "Complete",
  "panelUpdate.state.current": "Up to date",
  "panelUpdate.state.failed": "Failed",
  "panelUpdate.state.queued": "Queued",
  "panelUpdate.state.reconnecting": "Restarting",
  "panelUpdate.state.running": "Updating",
  "panelUpdate.targetVersion": "Target version",
  "panelUpdate.title": "Sky UI update",
  "panelUpdate.update": "Update",
  "protocol.amneziawg":
      "AmneziaWG 3.1 VPN tunnel with packet obfuscation. Requires a compatible 3.1 client.",
  "protocol.amneziawg.details":
      "AmneziaWG 3.1 creates a network tunnel and gives each user their own key and address. It requires TUN and routing on the server. Use an AmneziaWG 3.1 client and the native profile.",
  "protocol.anytls": "TLS proxy with configurable packet sizes.",
  "protocol.anytls.details":
      "Uses a recipient password, a protected transport, and a padding scheme that changes packet sizes. Requires a compatible AnyTLS client.",
  "protocol.cloudflared": "Cloudflare Tunnel integration.",
  "protocol.cloudflared.details":
      "Core integration with Cloudflare Tunnel. Requires separate configuration of the Cloudflare service.",
  "protocol.direct": "Listener that forwards traffic to a fixed destination.",
  "protocol.direct.details":
      "Destination and behavior depend on the selected core. Intended for system routing.",
  "protocol.http": "HTTP proxy with username and password authentication.",
  "protocol.http.details":
      "Works with apps that support an HTTP proxy. CONNECT handles HTTPS destinations. TLS on the listener protects credentials between the client and proxy on untrusted networks.",
  "protocol.hysteria": "First-generation Hysteria over QUIC.",
  "protocol.hysteria.details":
      "Requires UDP and a Hysteria v1 client. Hysteria 2 clients are incompatible.",
  "protocol.hysteria2": "QUIC protocol for lossy or high-latency networks.",
  "protocol.hysteria2-realm": "Coordination server for Hysteria 2 Realm.",
  "protocol.hysteria2-realm.details":
      "Realm coordinates discovery and connection setup in a compatible Hysteria 2 Realm deployment. Recipients still need a Hysteria 2 listener.",
  "protocol.hysteria2.details":
      "Uses UDP, TLS, and a recipient password. Supports UDP obfuscation and several congestion control modes. Bandwidth settings tune the protocol. Open UDP for Clash Verge and other compatible clients.",
  "protocol.masque": "Tunneling over supported HTTP transports.",
  "protocol.masque.details":
      "MASQUE tunnels data using HTTP mechanisms. Available features depend on the core and client.",
  "protocol.mieru": "Encrypted connection over TCP or UDP.",
  "protocol.mieru.details":
      "Mieru uses per-recipient credentials and supports TCP, UDP, and configurable traffic patterns. Use a compatible client. Mieru's built-in encryption works without a TLS certificate.",
  "protocol.mixed": "One listener for HTTP and SOCKS.",
  "protocol.mixed.details":
      "Detects HTTP proxy and SOCKS on the same port. Recipients have separate credentials. Encryption depends on transport security.",
  "protocol.naive":
      "HTTPS proxying with a Chromium-based client. Requires a server certificate.",
  "protocol.naive.details":
      "NaiveProxy uses HTTP/2 or HTTP/3 CONNECT. Use a compatible NaiveProxy client. The selected server core handles user authentication and TLS.",
  "protocol.redirect": "System listener for redirected TCP connections.",
  "protocol.redirect.details":
      "Receives traffic redirected by Linux networking rules. Requires the matching rules on the host.",
  "protocol.shadowquic": "QUIC tunnel with JLS obfuscation.",
  "protocol.shadowquic.details":
      "Uses UDP, recipient credentials, and a JLS upstream for handshake obfuscation. Both sides need compatible mihomo versions. Use a ShadowQUIC profile.",
  "protocol.shadowsocks": "Lightweight encrypted proxy for TCP and UDP.",
  "protocol.shadowsocks.details":
      "Built-in encryption usually works without a domain or certificate. The client must support the chosen cipher. In mihomo each user gets a separate port and key for independent revocation.",
  "protocol.shadowtls": "TLS obfuscation for another protocol.",
  "protocol.shadowtls.details":
      "ShadowTLS protects and disguises the transport around another proxy protocol. The client must use the same version and keys.",
  "protocol.snell": "Encrypted proxy with one key per listener.",
  "protocol.snell.details":
      "Choose a Snell version supported by the client. In mihomo each listener uses one PSK, so each recipient gets a separate port and key. Compatibility depends on the core built into Clash Verge.",
  "protocol.socks": "SOCKS proxy with username and password authentication.",
  "protocol.socks.details":
      "Works with apps that support SOCKS. SOCKS5 supports TCP and UDP when the client does. Use compatible transport security on untrusted networks.",
  "protocol.sudoku": "Encryption with configurable traffic obfuscation.",
  "protocol.sudoku.details":
      "Sudoku combines a key, AEAD, and traffic encoding. Extra settings control padding and HTTP obfuscation. Each user gets a separate listener so access can be revoked independently. Check client version support.",
  "protocol.tailcat": "Tailscale network integration.",
  "protocol.tailcat.details":
      "Core integration with a Tailscale network for system networking.",
  "protocol.tproxy": "Transparent TCP and UDP system listener.",
  "protocol.tproxy.details":
      "Accepts traffic sent by Linux TProxy while preserving the original destination. Requires network permissions and matching routing rules.",
  "protocol.trojan": "Password-based access over a protected transport.",
  "protocol.trojan.details":
      "Typically runs over TLS and resembles HTTPS. mihomo supports other security options too. Sky UI issues a separate password to each recipient. Clash Verge must support the selected transport and security.",
  "protocol.trusttunnel": "HTTP/2 and HTTP/3 tunnel with TLS.",
  "protocol.trusttunnel.details":
      "TrustTunnel uses recipient credentials and a server certificate. Choose TCP or QUIC based on client support and UDP reachability.",
  "protocol.tuic": "TUIC v5 QUIC proxy with UUID and password authentication.",
  "protocol.tuic-v4": "QUIC listener for TUIC v4 clients.",
  "protocol.tuic-v4.details":
      "Uses UDP, TLS, and a per-recipient token. Choose a TUIC v4 client and a server certificate that matches the address. TUIC v5 is incompatible.",
  "protocol.tuic.details":
      "Uses UDP and TLS and supports TCP and UDP relay. Sky UI generates a UUID and password for each user. Congestion control affects performance on lossy or high-latency networks. Use a TUIC v5 client.",
  "protocol.tun": "Virtual network interface for traffic capture.",
  "protocol.tun.details":
      "Routes selected IP traffic to the core through a virtual interface. Requires system permissions and routing configuration, and can affect the server's own network.",
  "protocol.tunnel": "Forwards TCP or UDP to a fixed destination.",
  "protocol.tunnel.details":
      "Forwards traffic to a fixed destination without per-recipient authentication. The bind address and port determine who can reach it.",
  "protocol.unavailable": "This protocol is unavailable on the selected core.",
  "protocol.vless": "Flexible proxy with configurable transport and security.",
  "protocol.vless.details":
      "Works with Clash Verge and many other clients. Choose transport security separately. REALITY works without your own certificate, while TLS uses a server certificate. Sky UI generates each recipient's UUID.",
  "protocol.vmess":
      "Encrypted proxy with UUID authentication and several transports.",
  "protocol.vmess.details":
      "VMess includes encryption and authenticates recipients by UUID. You can configure transport and TLS separately. Clash Verge supports VMess. Keep client and server clocks synchronized.",
  "protocol.wireguard": "WireGuard IP tunnel with peer keys.",
  "protocol.wireguard.details":
      "Inbound WireGuard support depends on the core. It needs tunnel addresses and matching keys. Use a WireGuard profile.",
  "runtime.controller": "Readiness",
  "runtime.error.access_empty": "The user has no enabled connections.",
  "runtime.error.address_invalid":
      "Enter the server IP or hostname without a scheme, port, or path.",
  "runtime.error.amnezia_dependencies_required":
      "AmneziaWG requires iproute2 and nftables. Install them and try again.",
  "runtime.error.api_not_ready":
      "The panel failed to start after maintenance. Recover access over SSH.",
  "runtime.error.api_unavailable":
      "Cannot reach the server. Check that the API is running.",
  "runtime.error.auth_invalid": "Incorrect username or password.",
  "runtime.error.auth_not_configured":
      "The administrator account has not been configured.",
  "runtime.error.auth_rate_limited":
      "Too many attempts. Try again in a few minutes.",
  "runtime.error.auth_required": "Your session expired. Sign in again.",
  "runtime.error.backup_checksum_failed":
      "The backup is corrupt. Its checksum does not match.",
  "runtime.error.backup_incomplete": "The backup is missing required data.",
  "runtime.error.backup_invalid": "Could not validate the backup.",
  "runtime.error.backup_too_large": "The backup exceeds the 128 MB limit.",
  "runtime.error.backup_version_mismatch":
      "Restore requires the same panel version as the backup.",
  "runtime.error.backup_wrong_host":
      "This backup was created on another server.",
  "runtime.error.binary_missing":
      "The core binary is missing. Install the core on the server.",
  "runtime.error.binary_probe_failed": "Could not determine the core version.",
  "runtime.error.catalog_unavailable":
      "The Sky UI compatibility catalog is unavailable. Updates are disabled.",
  "runtime.error.command_failed":
      "A system command failed. Check the technical details.",
  "runtime.error.command_timeout": "The operation timed out.",
  "runtime.error.command_unavailable":
      "A program needed to manage the core is missing.",
  "runtime.error.configuration_applied": "Settings applied",
  "runtime.error.configuration_busy":
      "Configuration is being applied. Try again in a few seconds.",
  "runtime.error.configuration_invalid":
      "The core rejected the configuration. The running service was not restarted.",
  "runtime.error.configuration_missing":
      "The core configuration file is missing.",
  "runtime.error.configuration_out_of_sync":
      "The core configuration changed outside the panel. Access sharing is blocked until it is synchronized.",
  "runtime.error.configuration_recovered":
      "Configuration recovered after an interrupted operation",
  "runtime.error.configuration_rollback_failed":
      "Could not restore the working configuration. Changes and access sharing are blocked. Check the logs and restart the Sky UI service to recover.",
  "runtime.error.configuration_rolled_back":
      "Applying failed. Previous settings were restored",
  "runtime.error.configuration_write_failed":
      "Could not save settings. Check disk space and service permissions.",
  "runtime.error.connection_identity_immutable":
      "The core and protocol are fixed for an existing connection. Create a new connection.",
  "runtime.error.controller_not_ready":
      "The process started but its controller is not responding yet.",
  "runtime.error.core_already_installed":
      "The core is already installed. Refresh the page.",
  "runtime.error.core_build_failed":
      "Could not build the core. See the installation step for details.",
  "runtime.error.core_build_space_required":
      "Building AmneziaWG needs at least 1 GB free in /var/tmp. Free up space and retry.",
  "runtime.error.core_not_ready":
      "Start the core and wait until it is ready before sharing access.",
  "runtime.error.core_release_unverified":
      "This core version is not approved for the installed Sky UI version and platform.",
  "runtime.error.core_settings_routing_conflict":
      "Access settings conflict with existing routing. Check the mode, IP rules, and routing script in the original configuration. Settings were not applied.",
  "runtime.error.core_settings_unavailable":
      "Settings are unavailable for this core.",
  "runtime.error.core_unavailable":
      "The selected core is not installed for this instance.",
  "runtime.error.csrf_invalid":
      "The session changed. Reload the page and try again.",
  "runtime.error.engine_not_ready":
      "The core is not ready. Check its service logs.",
  "runtime.error.export_unavailable":
      "No supported subscription format is available for this protocol.",
  "runtime.error.gateway_auth_required":
      "The panel gateway is not trusted. Run sudo skyui setup again.",
  "runtime.error.generation_unsupported":
      "No generator is available for this field.",
  "runtime.error.go_toolchain_required":
      "Building AmneziaWG requires Go. Check the server dependencies.",
  "runtime.error.grant_invalid":
      "The available connections changed. Reopen the user form.",
  "runtime.error.handshake_port_invalid":
      "Enter a REALITY target port from 1 to 65535.",
  "runtime.error.internal_error":
      "Server error. Check the Sky UI service logs.",
  "runtime.error.listen_invalid":
      "Enter a bind address, such as :: or 0.0.0.0.",
  "runtime.error.listener_identity_unavailable":
      "Could not confirm that the core owns the listener. Access sharing is blocked.",
  "runtime.error.listener_not_ready":
      "The core is running but the connection port does not respond. Changes were not saved.",
  "runtime.error.maintenance_busy":
      "Wait for the current maintenance job to finish.",
  "runtime.error.maintenance_failed":
      "The operation failed. Check the maintenance service logs.",
  "runtime.error.maintenance_interrupted":
      "The operation was interrupted. Saved state was restored.",
  "runtime.error.maintenance_unavailable":
      "Maintenance is unavailable. An installed Linux service is required.",
  "runtime.error.name_invalid":
      "Enter a name from 1 to 80 characters with no line breaks.",
  "runtime.error.native_binary_incompatible":
      "The update binaries are incompatible with this server. Check the architecture and system libraries. The installed version is still running.",
  "runtime.error.network_in_use":
      "Another connection uses this subnet. Choose a different one.",
  "runtime.error.not_found": "The record was deleted or access is disabled.",
  "runtime.error.origin_forbidden":
      "The server rejected the request. Check the panel address.",
  "runtime.error.owner_name_invalid":
      "Enter 1 to 32 characters using Latin letters, digits, dots, hyphens, or underscores.",
  "runtime.error.owner_password_invalid":
      "Use at least 12 characters and at most 72 UTF-8 bytes.",
  "runtime.error.panel_update_failed":
      "Could not update Sky UI. Check the maintenance logs.",
  "runtime.error.panel_update_rolled_back":
      "The update failed. The previous version was restored.",
  "runtime.error.panel_update_unavailable":
      "This release is unavailable for updates. Check again.",
  "runtime.error.peer_address_invalid":
      "Recipients still have addresses in the previous subnet. Move them to a new connection first.",
  "runtime.error.peer_address_unavailable":
      "No free peer addresses remain in this subnet.",
  "runtime.error.platform_unsupported":
      "Service management requires Linux with systemd. This host cannot start the core.",
  "runtime.error.port_in_use": "Another connection already uses this port.",
  "runtime.error.port_invalid": "Enter a connection port from 1 to 65535.",
  "runtime.error.port_reserved":
      "This port is reserved for the system or panel. Generate another one next to the port field.",
  "runtime.error.port_unavailable":
      "The address or port is unavailable. Check the bind address and other services.",
  "runtime.error.protocol_unavailable":
      "Server support for this protocol is unavailable.",
  "runtime.error.release_changed":
      "The latest release has changed. Check for updates again.",
  "runtime.error.release_checksum_failed":
      "The download checksum did not match. The core was not changed.",
  "runtime.error.release_checksum_missing":
      "The release has no SHA-256 checksum. The update was cancelled.",
  "runtime.error.release_feed_unavailable":
      "Could not retrieve Sky UI releases. Try again later.",
  "runtime.error.releases_rate_limited":
      "GitHub has temporarily rate-limited requests. Try again later.",
  "runtime.error.releases_unavailable":
      "Could not load releases. Try again later.",
  "runtime.error.request_invalid":
      "The server rejected the request. Reload the page.",
  "runtime.error.request_too_large": "The request is too large.",
  "runtime.error.restart": "Core restarted",
  "runtime.error.restore_rolled_back":
      "The restored configuration failed its checks. The previous state was restored.",
  "runtime.error.service_busy":
      "The core service is changing state. Try again in a few seconds.",
  "runtime.error.service_failed":
      "The core service failed. Check the systemd logs.",
  "runtime.error.service_missing": "The core service is not installed.",
  "runtime.error.service_operation_failed":
      "The service action failed. Check its state and permissions.",
  "runtime.error.service_stop_timeout": "The service did not stop in time.",
  "runtime.error.settings_unsupported":
      "The selected protocol settings are unsupported.",
  "runtime.error.sni_address_invalid":
      "Set a public server IPv4 address in the panel settings before scanning.",
  "runtime.error.sni_invalid":
      "Enter a REALITY target hostname without a scheme or path.",
  "runtime.error.sni_scan_busy": "A scan is already running.",
  "runtime.error.sni_scan_cancelled": "Scan stopped.",
  "runtime.error.sni_scan_failed":
      "The scan failed. Verify any returned results before using them.",
  "runtime.error.sni_scan_timeout":
      "The scan timed out. Existing results are kept until the next scan.",
  "runtime.error.sni_tool_missing": "Install RealiTLScanner first.",
  "runtime.error.sni_tool_platform_unsupported":
      "No approved RealiTLScanner package is available for this architecture.",
  "runtime.error.start": "Core started",
  "runtime.error.state_changed":
      "The data changed in another tab. Reopen the form before saving.",
  "runtime.error.stop": "Core stopped",
  "runtime.error.supervisor_unavailable":
      "Could not read the systemd service state.",
  "runtime.error.update_rolled_back":
      "The core failed its startup check. The previous version was restored.",
  "runtime.error.validate": "Configuration validated",
  "runtime.loading": "Loading…",
  "runtime.notReady": "Not ready",
  "runtime.offline": "Offline",
  "runtime.ready": "Ready",
  "runtime.refresh": "Refresh",
  "runtime.state.activating": "Starting",
  "runtime.state.active": "Running",
  "runtime.state.deactivating": "Stopping",
  "runtime.state.failed": "Startup failed",
  "runtime.state.inactive": "Stopped",
  "runtime.state.unavailable": "Unavailable",
  "runtime.state.unknown": "Unknown",
  "runtime.validate": "Validate configuration",
  "runtime.working": "Working…",
  "settings.address": "Public server address",
  "settings.addressHelp":
      "IP or domain clients use to connect to the core. It appears in links and profiles. Manage the panel's domain and HTTPS separately.",
  "settings.appearance": "Appearance",
  "settings.configure": "Configure",
  "settings.dark": "Dark",
  "settings.description": "Manage your panel settings.",
  "settings.dns": "Core DNS",
  "settings.domain": "Panel address and HTTPS",
  "settings.general": "General",
  "settings.https.apply": "Confirm change",
  "settings.https.certificateExpired": "Certificate expired",
  "settings.https.certificateUnknown": "No certificate details",
  "settings.https.certificateUntil": "Valid until {date}",
  "settings.https.confirm":
      "The panel checks HTTPS before switching addresses. Sign in again at the new address and share updated subscription URLs.",
  "settings.https.dnsHelp":
      "Enter a domain with an A record pointing to this server. Leave it blank to use the IP address only.",
  "settings.https.domain": "Current domain",
  "settings.https.done": "Panel address updated.",
  "settings.https.error.domain_certificate_in_use":
      "A saved VPN connection uses a certificate that would change. Choose another certificate for that connection first.",
  "settings.https.error.domain_dns_mismatch":
      "A and AAAA records must point to this server.",
  "settings.https.error.domain_dns_missing":
      "The domain could not be resolved.",
  "settings.https.error.domain_https_not_ready":
      "HTTPS verification failed. Check DNS and access to ports 80 and 443.",
  "settings.https.error.domain_invalid":
      "Enter a domain without a scheme, port, or path.",
  "settings.https.error.domain_rollback_failed":
      "Automatic recovery failed. Check sky-ui-maintenance-recovery over SSH.",
  "settings.https.error.domain_setup_required":
      "Set up working HTTPS on the IP address with sudo skyui setup first.",
  "settings.https.error.domain_state_changed":
      "The address has changed. Check the current settings and try again.",
  "settings.https.error.domain_unchanged": "This address is already in use.",
  "settings.https.error.generic": "Could not change the panel address.",
  "settings.https.error.load": "Could not load HTTPS status.",
  "settings.https.error.maintenance_busy":
      "Wait for the current maintenance job to finish.",
  "settings.https.error.maintenance_interrupted":
      "The operation was interrupted. Check the current panel address.",
  "settings.https.ip": "Access by IP",
  "settings.https.newDomain": "Panel domain",
  "settings.https.reconnect":
      "If this tab stops responding, open the panel by IP.",
  "settings.https.renewal":
      "Caddy renews Let’s Encrypt certificates automatically.",
  "settings.https.restored": "Previous address restored.",
  "settings.https.review": "Change address",
  "settings.https.stage.apply": "Applying the address and checking HTTPS…",
  "settings.https.stage.certificate":
      "Waiting for a Let’s Encrypt certificate…",
  "settings.https.stage.queued": "Waiting to start…",
  "settings.https.stage.rollback": "Restoring the previous address…",
  "settings.https.stage.validate": "Checking DNS and settings…",
  "settings.https.unavailable": "Set up HTTPS first with sudo skyui setup.",
  "settings.language": "Interface language",
  "settings.logging": "Core log level",
  "settings.reset": "Reset preview",
  "settings.resetConfirm":
      "Local changes will be replaced with the original sample data.",
  "settings.resetDone": "Demo data restored",
  "settings.resetHint": "Restore the sample connections and users.",
  "settings.resetTitle": "Reset demo data?",
  "settings.russian": "Russian",
  "settings.serverName": "Server name",
  "settings.system": "System",
  "settings.title": "Settings",
  "share.changed": "Access changed. Open the subscription again.",
  "share.clashSubscription": "Subscription · Clash Verge / mihomo",
  "share.demo": "Preview link. The subscription server is unavailable.",
  "share.description": "Personal subscription · {name}",
  "share.disabled":
      "Access is disabled. Enable the user to share a subscription.",
  "share.excluded":
      "{client} excludes {names} from this subscription. Use a compatible client for those connections.",
  "share.format": "Automatic format detection",
  "share.selectUser":
      "Choose a user on the Users page to share their subscription.",
  "share.subscription": "Subscription",
  "share.subscriptionUrl": "Subscription URL",
  "share.title": "Share access",
  "share.type": "Subscription or connection",
  "share.uri": "Connection link",
  "share.uriFormat": "{protocol} · connection link",
  "share.v2raySubscription": "Subscription · V2Box / V2Ray",
  "sni.cancel": "Stop search",
  "sni.clientCheck":
      "The scan runs from the server. After choosing a site, refresh the subscription and test from your own network.",
  "sni.description":
      "RealiTLScanner checks up to 64 neighboring IPs on TCP 443. Results support TLS 1.3, HTTP/2, and a valid certificate for the name shown.",
  "sni.empty":
      "No suitable sites found. You can enter a known working site manually.",
  "sni.install": "Install RealiTLScanner · 9.2 MB",
  "sni.installing": "Downloading and verifying RealiTLScanner…",
  "sni.platform": "Available on Linux amd64",
  "sni.start": "Find nearby sites",
  "sni.title": "Find an SNI",
  "status.active": "Active",
  "status.available": "Available",
  "status.disabled": "Disabled",
  "status.planned": "Planned",
  "status.running": "Running",
  "status.stopped": "Stopped",
  "status.unassigned": "Unassigned",
  "storage.failed":
      "The browser could not save the changes. They will last until the page is reloaded.",
  "system.applied": "Applied",
  "system.collecting": "Collecting metrics…",
  "system.configuration": "Configuration",
  "system.configurationHint":
      "Checks that the core matches the saved configuration",
  "system.coreHint": "Active core services are ready",
  "system.coreNotReady": "No core services are ready",
  "system.panel": "Panel",
  "system.panelHint": "API is reachable",
  "system.total": "of {value}",
  "system.unsupported": "Hardware metrics are available on Linux.",
  "table.access": "CONNECTIONS",
  "table.actions": "Actions",
  "table.enabled": "ENABLED",
  "table.name": "CONNECTION",
  "table.protocol": "PROTOCOL",
  "table.recipient": "USER",
  "table.status": "STATUS",
  "table.transport": "TRANSPORT",
  "table.users": "ACCESS",
  "users.access": "Connection access",
  "users.accessHint": "Choose the connections this user can access.",
  "users.accessRevoked": "User access revoked",
  "users.active": "Access enabled",
  "users.add": "Add user",
  "users.count": "Users with access",
  "users.description": "Share access and manage connections from one place.",
  "users.disabled": "Access disabled",
  "users.name": "Username",
  "users.nameHelp":
      "This name is only visible in the panel. The user does not need an account and cannot sign in to the panel.",
  "users.noAccess": "No connections assigned",
  "users.none": "No users yet",
  "users.presence.help.offline": "No open connections were detected.",
  "users.presence.help.online":
      "The core reports an open connection for this user.",
  "users.presence.help.recent":
      "The core recently accepted a request or handshake from this user.",
  "users.presence.help.unavailable":
      "The core has not reported connection data.",
  "users.presence.offline": "Offline",
  "users.presence.online": "Online",
  "users.presence.recent": "Recently active",
  "users.subscription": "QR code",
  "users.title": "Users",
  "users.total": "Total users",
};
