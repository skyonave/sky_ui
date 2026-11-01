#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { printf 'Sky UI: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage: bash install.sh [--version v0.1.0] [--port 39241]
       bash install.sh --bundle /path/sky-ui-linux-amd64.tar.gz [--verify-only]
Requires Linux with systemd and a published, checksummed release.
Local bundles require an adjacent .sha256 file.
--verify-only checks bundle integrity/contents without executing it or changing the host.
HELP
}
version=latest
bundle=
port=
verify_only=0
while (( $# )); do
  case "$1" in
    --version) (( $# >= 2 )) || fail 'Missing version.'; version="$2"; shift 2 ;;
    --bundle) (( $# >= 2 )) || fail 'Missing bundle path.'; bundle="$2"; shift 2 ;;
    --port) (( $# >= 2 )) || fail 'Missing port.'; port="$2"; shift 2 ;;
    --verify-only) verify_only=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$version" == latest || "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] || fail 'Invalid release tag.'
[[ -z "$port" || "$port" =~ ^[0-9]+$ ]] || fail 'Invalid port.'
if [[ -n "$port" ]]; then (( port >= 1 && port <= 65535 )) || fail 'Invalid port.'; fi
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) fail 'Only amd64 and arm64 bundles are available.' ;;
esac
if (( ! verify_only )); then
  [[ "$(uname -s)" == Linux ]] || fail 'Linux is required.'
  (( EUID == 0 )) || fail 'Run the installer with sudo or as root.'
  [[ -d /run/systemd/system ]] || fail 'systemd must be running as the service manager.'
  [[ ! -e /var/lib/sky-ui-maintenance/core-remove-intent.json ]] || fail 'Core removal recovery is required. Start sky-ui-maintenance-recovery.service first.'
  command -v flock >/dev/null || fail 'flock is required.'
  if [[ "${SKY_UI_TRANSACTION_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    [[ "$(readlink "/proc/self/fd/$SKY_UI_TRANSACTION_LOCK_FD")" == /run/lock/sky-ui-install.lock ]] || fail 'Invalid update transaction lock.'
    exec 9>&"$SKY_UI_TRANSACTION_LOCK_FD"
  else
    exec 9>/run/lock/sky-ui-install.lock
  fi
  flock -n 9 || fail 'Another Sky UI installation is in progress.'
fi
for command in tar sha256sum awk grep sed mktemp; do
  command -v "$command" >/dev/null || fail "Missing dependency: $command"
done
temp="$(mktemp -d)"
previous=
changed=0
api_was_running=0
edge_was_running=0
core_previous=
core_link_changed=0
worker_locked=0
cleanup() { rm -rf -- "$temp"; }
unlock_worker() {
  if (( worker_locked )); then flock -u 8; worker_locked=0; fi
}
rollback() {
  local status=$?
  trap - ERR
  set +e
  if (( changed )); then
    if (( core_link_changed )); then
      if [[ -n "$core_previous" ]]; then
        ln -s "$core_previous" /opt/sky-ui/cores/mihomo/.rollback-link
        mv -Tf /opt/sky-ui/cores/mihomo/.rollback-link /opt/sky-ui/cores/mihomo/current
      else
        rm -f -- /opt/sky-ui/cores/mihomo/current
      fi
    fi
    systemctl stop sky-ui-edge.service
    systemctl stop sky-ui.service
    if [[ -n "$previous" && -d "$previous" ]]; then
      ln -s "$previous" /opt/sky-ui/.rollback-link
      mv -Tf /opt/sky-ui/.rollback-link /opt/sky-ui/current
      install -m 0644 "$previous/deploy/systemd/sky-ui.service" /etc/systemd/system/sky-ui.service
      install -m 0644 "$previous/deploy/systemd/sky-ui-mihomo.service" /etc/systemd/system/sky-ui-mihomo.service
      install -m 0644 "$previous/deploy/systemd/sky-ui-edge.service" /etc/systemd/system/sky-ui-edge.service
      for unit in sky-ui-maintenance.service sky-ui-maintenance-recovery.service sky-ui-update.service sky-ui-update-recovery.service; do
        if [[ -f "$previous/deploy/systemd/$unit" ]]; then
          install -m 0644 "$previous/deploy/systemd/$unit" "/etc/systemd/system/$unit"
        else
          systemctl disable "$unit" 2>/dev/null || true
          rm -f -- "/etc/systemd/system/$unit"
        fi
      done
      if [[ -f "$temp/old-server.env" ]]; then install -m 0640 -o root -g sky-ui "$temp/old-server.env" /etc/sky-ui/server.env; fi
      if [[ -f "$previous/deploy/systemd/sky-ui-certificates.timer" ]]; then
        install -m 0644 "$previous/deploy/systemd/sky-ui-certificates.service" /etc/systemd/system/sky-ui-certificates.service
        install -m 0644 "$previous/deploy/systemd/sky-ui-certificates.timer" /etc/systemd/system/sky-ui-certificates.timer
      else
        systemctl disable --now sky-ui-certificates.timer || true
        systemctl stop sky-ui-certificates.service || true
        rm -f -- /etc/systemd/system/sky-ui-certificates.service /etc/systemd/system/sky-ui-certificates.timer
      fi
      install -m 0644 "$previous/deploy/polkit/49-sky-ui.rules" /etc/polkit-1/rules.d/49-sky-ui.rules
      if [[ -f "$temp/old-Caddyfile" ]]; then install -m 0640 -o root -g sky-ui-edge "$temp/old-Caddyfile" /etc/sky-ui/Caddyfile; fi
      unlock_worker
      systemctl daemon-reload
      if (( api_was_running )) && [[ "${SKY_UI_DEFER_ROLLBACK_START:-0}" != 1 ]]; then
        systemctl reset-failed sky-ui.service
        systemctl restart sky-ui.service
      fi
      if (( edge_was_running )) && [[ "${SKY_UI_DEFER_ROLLBACK_START:-0}" != 1 ]]; then systemctl restart sky-ui-edge.service; fi
      printf 'Previous release restored; configuration and data were retained.\n' >&2
    fi
  fi
  unlock_worker
  printf 'Sky UI installation failed. Inspect journalctl -u sky-ui.service.\n' >&2
  exit "$status"
}
trap cleanup EXIT
trap rollback ERR
asset="sky-ui-linux-$arch.tar.gz"
if [[ -z "$bundle" ]]; then
  command -v curl >/dev/null || fail 'curl is required.'
  base="https://github.com/skyonave/sky_ui/releases/download/$version"
  if [[ "$version" == latest ]]; then base=https://github.com/skyonave/sky_ui/releases/latest/download; fi
  bundle="$temp/$asset"
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "$bundle" "$base/$asset"
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "$bundle.sha256" "$base/$asset.sha256"
fi
[[ -f "$bundle" && -f "$bundle.sha256" ]] || fail 'Bundle and adjacent .sha256 file are required.'
expected="$(awk -v name="$asset" '$2 == name || $2 == "*"name {print $1}' "$bundle.sha256")"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Invalid checksum file.'
actual="$(sha256sum -- "$bundle" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || fail 'Bundle checksum mismatch; nothing was installed.'
tar -tzf "$bundle" >"$temp/entries"
tar -tvzf "$bundle" >"$temp/types"
if grep -vE '^[-d]' "$temp/types" >/dev/null; then fail 'Archive links and special files are forbidden.'; fi
while IFS= read -r entry; do
  entry="$(printf '%s' "$entry" | sed 's#^\./##;s#/$##')"
  [[ -z "$entry" ]] && continue
  [[ "$entry" =~ ^[A-Za-z0-9_./+-]+$ && "$entry" != /* ]] || fail 'Invalid archive path.'
  case "/$entry/" in *'/../'*|*'/./'*) fail 'Archive traversal is forbidden.' ;; esac
done <"$temp/entries"
mkdir "$temp/payload"
tar -xzf "$bundle" -C "$temp/payload" --no-same-owner --no-same-permissions
payload="$temp/payload"
for file in VERSION ARCH bin/sky-ui bin/caddy lib/libsqlite3.so web/index.html web/main.dart.js web/styles.css \
  web/fonts/PxPlus_IBM_VGA8.ttf web/fonts/LICENSE-IBM-VGA.txt web/fonts/ATTRIBUTION.txt \
  deploy/systemd/sky-ui.service deploy/systemd/sky-ui-mihomo.service deploy/polkit/49-sky-ui.rules \
  deploy/mihomo/config.example.yaml deploy/setup.sh deploy/render_access.sh deploy/certificate_sync.py deploy/maintenance.py deploy/panel_releases.py deploy/panel_update.py deploy/core_artifacts.py deploy/core_install.py deploy/sky-ui deploy/skyui deploy/cli.py compatibility/cores/mihomo.json compatibility/cores/sing-box.json compatibility/cores/xray.json deploy/systemd/sky-ui-edge.service deploy/systemd/sky-ui-certificates.service deploy/systemd/sky-ui-certificates.timer deploy/systemd/sky-ui-maintenance.service deploy/systemd/sky-ui-maintenance-recovery.service deploy/systemd/sky-ui-update.service deploy/systemd/sky-ui-update-recovery.service LICENSE licenses/caddy.LICENSE; do
  [[ -f "$payload/$file" ]] || fail "Incomplete release: $file"
done
release_version="$(tr -d '\r\n' <"$payload/VERSION")"
release_arch="$(tr -d '\r\n' <"$payload/ARCH")"
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] || fail 'Invalid release metadata.'
[[ "$release_arch" == "$arch" ]] || fail 'Release architecture mismatch.'
if [[ "$version" != latest ]]; then [[ "$version" == "v$release_version" ]] || fail 'Release version mismatch.'; fi
if (( verify_only )); then printf 'Verified Sky UI %s for %s. No host changes made.\n' "$release_version" "$arch"; exit 0; fi

# Native binaries are checked before changing users, services, or configuration.
chmod 0755 "$payload/bin/sky-ui" "$payload/bin/caddy"
[[ "$("$payload/bin/sky-ui" --version)" == "Sky UI $release_version" ]] || fail 'The API binary cannot run on this host.'
if [[ ! -f /etc/sky-ui/managed-by-sky-ui ]]; then
  for path in /etc/sky-ui /var/lib/sky-ui /var/lib/sky-ui-edge /var/lib/sky-ui-maintenance /var/lib/sky-ui-certificates /opt/sky-ui /usr/local/bin/sky-ui /usr/local/bin/skyui /etc/systemd/system/sky-ui.service /etc/systemd/system/sky-ui-mihomo.service /etc/systemd/system/sky-ui-edge.service /etc/polkit-1/rules.d/49-sky-ui.rules; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "Refusing to overwrite an unmanaged path: $path"
  done
  if getent passwd sky-ui >/dev/null || getent passwd sky-ui-core >/dev/null || getent group sky-ui >/dev/null || getent passwd sky-ui-edge >/dev/null || getent group sky-ui-edge >/dev/null; then
    fail 'Reserved Sky UI accounts already exist without an installation marker.'
  fi
fi
if ! command -v pkaction >/dev/null || ! command -v openssl >/dev/null; then
  command -v apt-get >/dev/null || fail 'Install polkit and openssl before continuing on this distribution.'
  apt-get update
  apt-get install -y --no-install-recommends polkitd openssl ca-certificates python3
fi
for command in systemctl getent groupadd useradd install runuser curl python3; do
  command -v "$command" >/dev/null || fail "Missing dependency: $command"
done
chmod 0755 "$temp" "$payload" "$payload/bin"
validation_binary="$(python3 "$payload/deploy/core_install.py" prepare --panel-version "$release_version" --platform "linux-$arch" --output "$temp/core")"
getent group sky-ui >/dev/null || groupadd --system sky-ui
getent passwd sky-ui >/dev/null || useradd --system --gid sky-ui --no-create-home --home-dir /var/lib/sky-ui --shell /usr/sbin/nologin sky-ui
getent passwd sky-ui-core >/dev/null || useradd --system --gid sky-ui --no-create-home --home-dir /var/lib/sky-ui/cores/mihomo --shell /usr/sbin/nologin sky-ui-core
getent group sky-ui-edge >/dev/null || groupadd --system sky-ui-edge
getent passwd sky-ui-edge >/dev/null || useradd --system --gid sky-ui-edge --no-create-home --home-dir /var/lib/sky-ui-edge --shell /usr/sbin/nologin sky-ui-edge
install -d -m 0755 /opt/sky-ui /opt/sky-ui/releases
install -d -m 0711 -o root -g root /etc/sky-ui
install -d -m 0750 -o sky-ui -g sky-ui /var/lib/sky-ui /var/lib/sky-ui/cores
install -d -m 0700 -o sky-ui-edge -g sky-ui-edge /var/lib/sky-ui-edge
install -d -m 0750 -o root -g sky-ui /var/lib/sky-ui-certificates
install -d -m 0770 -o sky-ui-core -g sky-ui /var/lib/sky-ui/cores/mihomo
install -d -m 0750 -o root -g sky-ui /var/lib/sky-ui-maintenance /var/lib/sky-ui-maintenance/backups /var/lib/sky-ui-maintenance/validation
install -d -m 0700 -o root -g root /var/lib/sky-ui-maintenance/work
install -d -m 0700 -o sky-ui -g sky-ui /var/lib/sky-ui-maintenance/inbox
install -d -m 0755 -o root -g root /opt/sky-ui/cores /opt/sky-ui/cores/mihomo
touch /etc/sky-ui/managed-by-sky-ui
if [[ ! -f /etc/sky-ui/gateway.secret ]]; then
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' >"$temp/gateway.secret"
  install -m 0600 -o sky-ui -g sky-ui "$temp/gateway.secret" /etc/sky-ui/gateway.secret
fi
[[ "$(cat /etc/sky-ui/gateway.secret)" =~ ^[a-f0-9]{64}$ ]] || fail 'Invalid gateway credential.'
chown sky-ui:sky-ui /etc/sky-ui/gateway.secret
chmod 0600 /etc/sky-ui/gateway.secret
if [[ -f /var/lib/sky-ui/cores/mihomo/config.yaml && ! -f /etc/sky-ui/controller.secret ]]; then
  fail 'Existing core configuration has no controller secret file; restore it before retrying.'
fi
if [[ ! -f /etc/sky-ui/controller.secret ]]; then
  openssl rand -hex 32 >/etc/sky-ui/controller.secret
  chown root:sky-ui /etc/sky-ui/controller.secret
  chmod 0640 /etc/sky-ui/controller.secret
fi
secret="$(tr -d '\r\n' </etc/sky-ui/controller.secret)"
[[ "$secret" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Invalid controller secret file.'
if [[ ! -f /var/lib/sky-ui/cores/mihomo/config.yaml ]]; then
  sed "s/__SKY_UI_CONTROLLER_SECRET__/$secret/" "$payload/deploy/mihomo/config.example.yaml" >"$temp/config.yaml"
  install -m 0660 -o sky-ui-core -g sky-ui "$temp/config.yaml" /var/lib/sky-ui/cores/mihomo/config.yaml
fi
unset secret
if [[ -f /etc/sky-ui/server.env ]]; then
  saved_port="$(sed -n 's/^SKY_UI_PORT=//p' /etc/sky-ui/server.env)"
  [[ "$saved_port" =~ ^[0-9]+$ ]] || fail 'Cannot read existing API port.'
  [[ -z "$port" || "$port" == "$saved_port" ]] || fail 'Change the existing port in server.env; the installer preserves configuration.'
  port="$saved_port"
else
  if [[ -z "$port" ]]; then port=39241; fi
  cat >/etc/sky-ui/server.env <<ENV
SKY_UI_HOST=127.0.0.1
SKY_UI_PORT=$port
SKY_UI_WEB_ORIGIN=http://127.0.0.1:$port
SKY_UI_PUBLIC_DIR=/opt/sky-ui/current/web
SKY_UI_DATA_DIR=/var/lib/sky-ui
SKY_UI_CORE_BINARY=/opt/sky-ui/cores/mihomo/current/mihomo
SKY_UI_CORE_DIRECTORY=/var/lib/sky-ui/cores/mihomo
SKY_UI_CORE_CONFIG=/var/lib/sky-ui/cores/mihomo/config.yaml
SKY_UI_CONTROLLER_URL=http://127.0.0.1:19090
SKY_UI_CONTROLLER_SECRET_FILE=/etc/sky-ui/controller.secret
SKY_UI_GATEWAY_SECRET_FILE=/etc/sky-ui/gateway.secret
SKY_UI_OWNER_SEED_FILE=/etc/sky-ui/owner.seed
ENV
  chown root:sky-ui /etc/sky-ui/server.env
  chmod 0640 /etc/sky-ui/server.env
fi
# Validate as the same unprivileged account that will run the core.
if ! grep -q '^SKY_UI_GATEWAY_SECRET_FILE=' /etc/sky-ui/server.env; then
  printf 'SKY_UI_GATEWAY_SECRET_FILE=/etc/sky-ui/gateway.secret\n' >>/etc/sky-ui/server.env
fi
if ! grep -q '^SKY_UI_OWNER_SEED_FILE=' /etc/sky-ui/server.env; then
  printf 'SKY_UI_OWNER_SEED_FILE=/etc/sky-ui/owner.seed\n' >>/etc/sky-ui/server.env
fi
if [[ ! -f /etc/sky-ui/owner.seed && -f /etc/sky-ui/admin.hash ]]; then
  install -m 0600 -o sky-ui -g sky-ui /etc/sky-ui/admin.hash /etc/sky-ui/owner.seed
fi
if [[ "$validation_binary" != - ]]; then
  python3 "$payload/deploy/core_install.py" validate --binary "$validation_binary" --directory /var/lib/sky-ui/cores/mihomo --configuration /var/lib/sky-ui/cores/mihomo/config.yaml
fi
release="/opt/sky-ui/releases/$release_version-$arch"
if [[ -e "$release" ]]; then
  [[ -f "$release/BUNDLE_SHA256" && "$(cat "$release/BUNDLE_SHA256")" == "$actual" ]] || fail 'This version already exists with different contents. Use a new release version.'
else
  find "$payload" -type d -exec chmod 0755 {} +
  find "$payload" -type f -exec chmod 0644 {} +
  chmod 0755 "$payload/bin/sky-ui" "$payload/bin/caddy"
  printf '%s\n' "$actual" >"$payload/BUNDLE_SHA256"
  mv "$payload" "$release"
fi
if [[ -L /opt/sky-ui/current ]]; then previous="$(readlink -f /opt/sky-ui/current)"; fi
if systemctl is-active --quiet sky-ui.service; then api_was_running=1; fi
if systemctl is-active --quiet sky-ui-edge.service; then edge_was_running=1; fi
if [[ -f /etc/sky-ui/access.conf ]]; then
  [[ -f /etc/sky-ui/admin.hash && -f /etc/sky-ui/Caddyfile ]] || fail 'Incomplete gateway configuration.'
  cp /etc/sky-ui/Caddyfile "$temp/old-Caddyfile"
  access_ip="$(sed -n '1p' /etc/sky-ui/access.conf)"
  access_domain="$(sed -n '2p' /etc/sky-ui/access.conf)"
  bash "$release/deploy/render_access.sh" "$temp/new-Caddyfile" "$access_ip" "$access_domain" "$port" /etc/sky-ui/admin.hash /etc/sky-ui/gateway.secret
  "$release/bin/caddy" fmt --overwrite "$temp/new-Caddyfile"
  "$release/bin/caddy" validate --config "$temp/new-Caddyfile" --adapter caddyfile
fi
exec 8>>/var/lib/sky-ui-maintenance/worker.lock
flock -n 8 || fail 'Core maintenance is in progress. Retry installation when it finishes.'
worker_locked=1
changed=1
cp /etc/sky-ui/server.env "$temp/old-server.env"
if [[ -L /opt/sky-ui/cores/mihomo/current ]]; then core_previous="$(readlink -f /opt/sky-ui/cores/mihomo/current)"; fi
if [[ -d "$temp/core" ]]; then core_link_changed=1; fi
if [[ "$validation_binary" != - ]]; then python3 "$release/deploy/core_install.py" activate --prepared "$temp/core"; fi
sed -i 's#^SKY_UI_CORE_BINARY=.*#SKY_UI_CORE_BINARY=/opt/sky-ui/cores/mihomo/current/mihomo#' /etc/sky-ui/server.env
if (( edge_was_running )); then systemctl stop sky-ui-edge.service; fi
if (( api_was_running )); then systemctl stop sky-ui.service; fi
install -m 0644 "$release/deploy/systemd/sky-ui.service" /etc/systemd/system/sky-ui.service
install -m 0644 "$release/deploy/systemd/sky-ui-mihomo.service" /etc/systemd/system/sky-ui-mihomo.service
install -m 0644 "$release/deploy/systemd/sky-ui-edge.service" /etc/systemd/system/sky-ui-edge.service
install -m 0644 "$release/deploy/systemd/sky-ui-certificates.service" /etc/systemd/system/sky-ui-certificates.service
install -m 0644 "$release/deploy/systemd/sky-ui-certificates.timer" /etc/systemd/system/sky-ui-certificates.timer
install -m 0644 "$release/deploy/systemd/sky-ui-maintenance.service" /etc/systemd/system/sky-ui-maintenance.service
install -m 0644 "$release/deploy/systemd/sky-ui-maintenance-recovery.service" /etc/systemd/system/sky-ui-maintenance-recovery.service
install -m 0644 "$release/deploy/systemd/sky-ui-update.service" /etc/systemd/system/sky-ui-update.service
install -m 0644 "$release/deploy/systemd/sky-ui-update-recovery.service" /etc/systemd/system/sky-ui-update-recovery.service
install -d -m 0755 /usr/local/bin
install -m 0755 "$release/deploy/sky-ui" /usr/local/bin/sky-ui
install -m 0755 "$release/deploy/skyui" /usr/local/bin/skyui
install -d -m 0755 /etc/polkit-1/rules.d
install -m 0644 "$release/deploy/polkit/49-sky-ui.rules" /etc/polkit-1/rules.d/49-sky-ui.rules
ln -s "$release" /opt/sky-ui/.next-link
mv -Tf /opt/sky-ui/.next-link /opt/sky-ui/current
unlock_worker
systemctl daemon-reload
systemctl enable sky-ui-maintenance-recovery.service
# The core is not boot-enabled: the API restores its persisted desired state.
systemctl reset-failed sky-ui.service
systemctl enable --now sky-ui.service
healthy=0
for attempt in $(seq 1 20); do
  if systemctl is-active --quiet sky-ui.service &&
     curl --noproxy '*' --fail --silent --max-time 2 "http://127.0.0.1:$port/api/v1/health" | grep -F "\"version\":\"$release_version\"" >/dev/null; then
    healthy=1; break
  fi
  sleep 1
done
if (( ! healthy )); then printf 'API health check failed.\n' >&2; false; fi
if [[ -f "$temp/new-Caddyfile" ]]; then
  install -m 0640 -o root -g sky-ui-edge "$temp/new-Caddyfile" /etc/sky-ui/Caddyfile
fi
if (( edge_was_running )); then systemctl restart sky-ui-edge.service; fi
systemctl enable --now sky-ui-certificates.timer
systemctl start sky-ui-certificates.service
changed=0
printf 'Sky UI %s installed: http://127.0.0.1:%s\n' "$release_version" "$port"
if [[ ! -f /etc/sky-ui/access.conf ]]; then printf 'Configure public HTTPS and owner access with sudo skyui setup.\n'; fi
printf 'The core starts only after a panel action or restoration of a previously saved running state.\n'
if [[ -z "${SKY_UI_TRANSACTION_LOCK_FD:-}" ]]; then flock -u 9; fi
if [[ -z "${SKY_UI_TRANSACTION_LOCK_FD:-}" && ! -f /etc/sky-ui/access.conf ]] && (: </dev/tty) 2>/dev/null; then
  bash /opt/sky-ui/current/deploy/setup.sh
else
  printf 'Configure owner access and IP/domain: sudo skyui setup\n'
fi
