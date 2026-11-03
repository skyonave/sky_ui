#!/usr/bin/env bash
set -Eeuo pipefail
# Candidate validation must always use its packaged native bridge.
unset SKY_UI_POSIX_LIBRARY
umask 077

fail() { printf 'Sky UI: %s\n' "$*" >&2; exit 1; }
native_fail() { printf 'SKY_UI_ERROR=native_binary_incompatible\n' >&2; fail "$*"; }
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
prepare_only=
while (( $# )); do
  case "$1" in
    --version) (( $# >= 2 )) || fail 'Missing version.'; version="$2"; shift 2 ;;
    --bundle) (( $# >= 2 )) || fail 'Missing bundle path.'; bundle="$2"; shift 2 ;;
    --port) (( $# >= 2 )) || fail 'Missing port.'; port="$2"; shift 2 ;;
    --verify-only) verify_only=1; shift ;;
    --prepare-only) (( $# >= 2 )) || fail 'Missing preparation output.'; prepare_only="$2"; shift 2 ;;
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
  command -v systemctl >/dev/null && command -v awk >/dev/null || fail 'systemctl and awk are required.'
  systemd_version="$(systemctl --version | awk 'NR == 1 {print $2}')"
  [[ "$systemd_version" =~ ^[0-9]+$ ]] && (( systemd_version >= 245 )) || fail 'systemd 245 or newer is required for isolated Sky UI logs.'
  getconf GNU_LIBC_VERSION >/dev/null 2>&1 || fail 'A glibc-based Linux distribution is required.'
  [[ ! -e /var/lib/sky-ui-maintenance/core-remove-intent.json ]] || fail 'Core removal recovery is required. Start sky-ui-maintenance-recovery.service first.'
  [[ ! -e /var/lib/sky-ui-maintenance/engine-intent.json ]] || fail 'Engine recovery is required. Start sky-ui-maintenance-recovery.service first.'
  # Always pair the online entry point with the installer's published release.
  # Pushing a new source format to main must not break the previous live release.
  if [[ -z "$bundle" && "${SKY_UI_RELEASE_INSTALLER:-0}" != 1 ]]; then
    for command in curl sha256sum awk mktemp stat; do command -v "$command" >/dev/null || fail "Missing dependency: $command"; done
    bootstrap="$(mktemp -d /var/tmp/sky-ui-install.XXXXXXXX)"
    trap 'rm -rf -- "$bootstrap"' EXIT
    bootstrap_base="https://github.com/skyonave/sky_ui/releases/download/$version"
    if [[ "$version" == latest ]]; then bootstrap_base=https://github.com/skyonave/sky_ui/releases/latest/download; fi
    curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --max-filesize 262144 -o "$bootstrap/install.sh" "$bootstrap_base/install.sh"
    curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --max-filesize 4096 -o "$bootstrap/install.sh.sha256" "$bootstrap_base/install.sh.sha256"
    bootstrap_expected="$(awk '$2 == "install.sh" || $2 == "*install.sh" {print $1}' "$bootstrap/install.sh.sha256")"
    [[ "$bootstrap_expected" =~ ^[a-fA-F0-9]{64}$ && "$(sha256sum "$bootstrap/install.sh" | awk '{print $1}')" == "$bootstrap_expected" ]] || fail 'Release installer checksum mismatch.'
    bootstrap_args=(--version "$version")
    if [[ -n "$port" ]]; then bootstrap_args+=(--port "$port"); fi
    SKY_UI_RELEASE_INSTALLER=1 bash "$bootstrap/install.sh" "${bootstrap_args[@]}"
    exit $?
  fi
  command -v flock >/dev/null || fail 'flock is required.'
  if [[ "${SKY_UI_TRANSACTION_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    [[ "$(readlink "/proc/self/fd/$SKY_UI_TRANSACTION_LOCK_FD")" == /run/lock/sky-ui-install.lock ]] || fail 'Invalid update transaction lock.'
    exec 9>&"$SKY_UI_TRANSACTION_LOCK_FD"
  else
    [[ ! -L /run/lock/sky-ui-install.lock && ( ! -e /run/lock/sky-ui-install.lock || -f /run/lock/sky-ui-install.lock ) ]] || fail 'Unsafe installation lock.'
    exec 9>>/run/lock/sky-ui-install.lock
  fi
  [[ "$(readlink /proc/self/fd/9)" == /run/lock/sky-ui-install.lock &&
     -f /proc/self/fd/9 && "$(stat -Lc '%u:%h' /proc/self/fd/9)" == 0:1 ]] || fail 'Unsafe installation lock.'
  flock -n 9 || fail 'Another Sky UI installation is in progress.'
fi
for command in tar sha256sum awk grep sed mktemp; do
  command -v "$command" >/dev/null || fail "Missing dependency: $command"
done
if (( verify_only )); then
  temp="$(mktemp -d)"
else
  temp="$(mktemp -d /var/tmp/sky-ui-install.XXXXXXXX)"
fi
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
      for engine in sing-box xray amneziawg; do
        if [[ -f "$previous/deploy/systemd/sky-ui-$engine.service" ]]; then
          install -m 0644 "$previous/deploy/systemd/sky-ui-$engine.service" "/etc/systemd/system/sky-ui-$engine.service"
        else
          systemctl disable --now "sky-ui-$engine.service" 2>/dev/null || true
          rm -f -- "/etc/systemd/system/sky-ui-$engine.service"
        fi
      done
      install -m 0644 "$previous/deploy/systemd/sky-ui-edge.service" /etc/systemd/system/sky-ui-edge.service
      for unit in sky-ui-maintenance.service sky-ui-maintenance-recovery.service sky-ui-update.service sky-ui-update-recovery.service sky-ui-cleanup.service sky-ui-cleanup.timer; do
        if [[ -f "$previous/deploy/systemd/$unit" ]]; then
          install -m 0644 "$previous/deploy/systemd/$unit" "/etc/systemd/system/$unit"
        else
          systemctl disable --now "$unit" 2>/dev/null || true
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
      for command in skyui sky-ui; do
        if [[ -f "$previous/deploy/$command" ]]; then install -m 0755 "$previous/deploy/$command" "/usr/local/bin/$command"; fi
      done
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
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --output "$bundle.sha256" "$base/$asset.sha256"
  # The cache helper is inside the bundle. Bootstrap reads only an immutable,
  # checksum-matching archive from its root-only cache before extracting it.
  download_sha="$(awk -v name="$asset" '$2 == name || $2 == "*"name {print $1}' "$bundle.sha256")"
  [[ "$download_sha" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Invalid checksum file.'
  cache_root=/var/cache/sky-ui-install
  cached_bundle="$cache_root/panel-$download_sha.tar.gz"
  if [[ "$(realpath -m -- "$cache_root")" == "$cache_root" && ! -L "$cache_root" && -d "$cache_root" &&
        "$(stat -c '%u:%g:%a' -- "$cache_root")" == 0:0:700 &&
        ! -L "$cache_root/managed-by-sky-ui" && -f "$cache_root/managed-by-sky-ui" &&
        "$(stat -c '%u:%h:%a' -- "$cache_root/managed-by-sky-ui")" == 0:1:600 &&
        "$(cat "$cache_root/managed-by-sky-ui")" == sky-ui-download-cache-v1 &&
        ! -L "$cached_bundle" && -f "$cached_bundle" &&
        "$(stat -c '%u:%h:%a' -- "$cached_bundle")" == 0:1:600 &&
        "$(stat -c %s -- "$cached_bundle")" -le 167772160 &&
        "$(( $(date +%s) - $(stat -c %Y -- "$cached_bundle") ))" -lt 86400 &&
        "$(sha256sum -- "$cached_bundle" | awk '{print $1}')" == "$download_sha" ]]; then
    cp -- "$cached_bundle" "$bundle"
    printf 'Reusing verified Sky UI download.\n'
  else
    curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --max-filesize 167772160 --output "$bundle" "$base/$asset"
  fi
fi
[[ -f "$bundle" && -f "$bundle.sha256" ]] || fail 'Bundle and adjacent .sha256 file are required.'
expected="$(awk -v name="$asset" '$2 == name || $2 == "*"name {print $1}' "$bundle.sha256")"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Invalid checksum file.'
actual="$(sha256sum -- "$bundle" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || fail 'Bundle checksum mismatch; nothing was installed.'
archive_bytes="$(stat -c %s -- "$bundle")"
(( archive_bytes <= 167772160 )) || fail 'Archive is too large.'
tar -tzf "$bundle" >"$temp/entries"
tar -tvzf "$bundle" >"$temp/types"
(( $(wc -l <"$temp/entries") <= 20000 )) || fail 'Too many archive entries.'
archive_expanded="$(awk '{sum += $3} END {printf "%.0f", sum}' "$temp/types")"
(( archive_expanded <= 536870912 )) || fail 'Expanded archive is too large.'
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
build_mode="$(tr -d '\r\n' <"$payload/BUILD_MODE")"
[[ "$build_mode" == native-v1 ]] || fail 'This installer requires a prebuilt native release.'
release_digest="$(tr -d '\r\n' <"$payload/SOURCE_SHA256")"
[[ "$release_digest" =~ ^[a-f0-9]{64}$ ]] || fail 'Missing source identity.'
for file in VERSION ARCH BUILD_MODE MIN_GLIBC BUILD_MANIFEST.json licenses/dart-sdk.LICENSE bin/caddy web/index.html web/main.dart.js web/styles.css \
  web/fonts/PxPlus_IBM_VGA8.ttf web/fonts/LICENSE-IBM-VGA.txt web/fonts/ATTRIBUTION.txt \
  deploy/systemd/sky-ui.service deploy/systemd/sky-ui-mihomo.service deploy/polkit/49-sky-ui.rules \
  deploy/systemd/sky-ui-sing-box.service deploy/systemd/sky-ui-xray.service deploy/systemd/sky-ui-amneziawg.service \
  deploy/journald-sky-ui.conf deploy/systemd/sky-ui-cleanup.service deploy/systemd/sky-ui-cleanup.timer deploy/prepare_host.sh deploy/host_packages.sh deploy/download_cache.sh deploy/sky-ui-install-tmpfiles.conf compatibility/cores/amneziawg.json \
  deploy/mihomo/config.example.yaml deploy/setup.sh deploy/render_access.sh deploy/sky-ui deploy/skyui compatibility/cores/mihomo.json compatibility/cores/sing-box.json compatibility/cores/xray.json deploy/systemd/sky-ui-edge.service deploy/systemd/sky-ui-certificates.service deploy/systemd/sky-ui-certificates.timer deploy/systemd/sky-ui-maintenance.service deploy/systemd/sky-ui-maintenance-recovery.service deploy/systemd/sky-ui-update.service deploy/systemd/sky-ui-update-recovery.service LICENSE licenses/caddy.LICENSE; do
  [[ -f "$payload/$file" ]] || fail "Incomplete release: $file"
done
for file in bin/sky-ui bin/sky-ops lib/libsqlite3.so lib/libsky_posix.so; do [[ -f "$payload/$file" ]] || fail "Incomplete native release: $file"; done
[[ ! -d "$payload/source" ]] || fail 'Native releases must not contain build sources.'
release_version="$(tr -d '\r\n' <"$payload/VERSION")"
release_arch="$(tr -d '\r\n' <"$payload/ARCH")"
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] || fail 'Invalid release metadata.'
[[ "$release_arch" == "$arch" ]] || fail 'Release architecture mismatch.'
if [[ "$version" != latest ]]; then [[ "$version" == "v$release_version" ]] || fail 'Release version mismatch.'; fi
minimum_glibc="$(tr -d '\r\n' <"$payload/MIN_GLIBC")"
[[ "$minimum_glibc" == 2.31 ]] || fail 'Unknown native compatibility baseline.'
if (( ! verify_only )); then
  host_glibc="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
  [[ "$host_glibc" =~ ^[0-9]+\.[0-9]+$ && "$(printf '%s\n%s\n' "$minimum_glibc" "$host_glibc" | sort -V | head -n 1)" == "$minimum_glibc" ]] || native_fail "This release needs glibc $minimum_glibc or newer; found $host_glibc. Nothing was installed."
fi
if (( verify_only )); then printf 'Verified Sky UI %s for %s. No host changes made.\n' "$release_version" "$arch"; exit 0; fi
source "$payload/deploy/download_cache.sh"
if [[ -z "$prepare_only" ]]; then
  sky_cache_put panel "$actual" "$bundle" || printf 'Sky UI: could not retain the panel download for retry.\n' >&2
fi
if [[ ! -f /etc/sky-ui/managed-by-sky-ui ]]; then
  for path in /etc/sky-ui /var/lib/sky-ui /var/lib/sky-ui-edge /var/lib/sky-ui-maintenance /var/lib/sky-ui-certificates /opt/sky-ui /usr/local/bin/sky-ui /usr/local/bin/skyui /etc/systemd/system/sky-ui.service /etc/systemd/system/sky-ui-mihomo.service /etc/systemd/system/sky-ui-edge.service /etc/polkit-1/rules.d/49-sky-ui.rules; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "Refusing to overwrite an unmanaged path: $path"
  done
  if getent passwd sky-ui >/dev/null || getent passwd sky-ui-core >/dev/null || getent group sky-ui >/dev/null || getent passwd sky-ui-edge >/dev/null || getent group sky-ui-edge >/dev/null; then
    fail 'Reserved Sky UI accounts already exist without an installation marker.'
  fi
fi
printf 'SKY_UI_STAGE=prepare\n'
prepare_fixed_host() {
  local script="$1" helper_dir helper_status
  [[ "$script" == prepare_host.sh ]] || fail 'Invalid prerequisite helper.'
  if [[ -w /etc && -w /usr && -w /var/lib ]]; then
    bash "$payload/deploy/$script"
    return
  fi
  # Older update services have read-only /etc and /var/lib. Execute only the
  # verified, fixed prerequisite helper through the host service manager. The
  # parent keeps both installation locks; this helper never acquires them.
  [[ -f /etc/sky-ui/managed-by-sky-ui ]] || fail 'Host preparation requires an installed panel.'
  helper_dir="$(mktemp -d /var/lib/sky-ui-maintenance/work/prepare.XXXXXXXX)"
  install -m 0700 "$payload/deploy/$script" "$helper_dir/$script"
  install -m 0600 "$payload/deploy/host_packages.sh" "$helper_dir/host_packages.sh"
  helper_status=0
  systemd-run --quiet --wait --pipe --collect --unit="sky-ui-prepare-${helper_dir##*.}" \
    --property=RuntimeMaxSec=600 /usr/bin/bash "$helper_dir/$script" || helper_status=$?
  rm -f -- "$helper_dir/$script" "$helper_dir/host_packages.sh"
  rmdir -- "$helper_dir"
  (( helper_status == 0 )) || fail "Host preparation failed (exit $helper_status)."
}
chmod 0755 "$temp" "$payload" "$payload/bin" "$payload/lib" "$payload/bin/sky-ui" "$payload/bin/sky-ops" "$payload/bin/caddy"
[[ "$("$payload/bin/sky-ui" --version)" == "Sky UI $release_version" ]] || native_fail 'The API binary cannot run on this host.'
"$payload/bin/sky-ops" --self-test || native_fail 'The CLI or native libraries cannot run on this host.'
if [[ -n "$prepare_only" ]]; then
  [[ -f /etc/sky-ui/managed-by-sky-ui && -d "$prepare_only" && ! -L "$prepare_only" && "$prepare_only" == /var/lib/sky-ui-maintenance/work/panel-update-*/compiled ]] || fail 'Invalid preparation destination.'
  tar -czf "$prepare_only/$asset" -C "$payload" .
  (cd "$prepare_only" && sha256sum "$asset" >"$asset.sha256")
  exit 0
fi
prepare_fixed_host prepare_host.sh
for command in systemctl getent groupadd useradd install runuser curl; do
  command -v "$command" >/dev/null || fail "Missing dependency: $command"
done
chmod 0755 "$temp" "$payload" "$payload/bin"
validation_binary=-
# Fresh panels acquire a core only after the owner chooses a protocol. Preserve
# and migrate a previously installed mihomo without downloading an unrelated core.
if [[ -L /opt/sky-ui/cores/mihomo/current || -f /opt/sky-ui/current/bin/mihomo ]]; then
  validation_binary="$("$payload/bin/sky-ops" core-bootstrap prepare --panel-version "$release_version" --platform "linux-$arch" --output "$temp/core")"
fi
printf 'SKY_UI_STAGE=install\n'
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
for engine in sing-box xray amneziawg; do
  install -d -m 0755 -o root -g root "/opt/sky-ui/cores/$engine"
  install -d -m 0770 -o sky-ui -g sky-ui "/var/lib/sky-ui/cores/$engine"
  if [[ ! -f "/var/lib/sky-ui/cores/$engine/config.json" ]]; then
    case "$engine" in
      xray) printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}' >"$temp/engine.json" ;;
      sing-box) printf '%s\n' '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' >"$temp/engine.json" ;;
      amneziawg) printf '%s\n' '{"version":"3.1","interfaces":[]}' >"$temp/engine.json" ;;
    esac
    install -m 0660 -o sky-ui -g sky-ui "$temp/engine.json" "/var/lib/sky-ui/cores/$engine/config.json"
  fi
done
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
  "$payload/bin/sky-ops" core-bootstrap validate --binary "$validation_binary" --directory /var/lib/sky-ui/cores/mihomo --configuration /var/lib/sky-ui/cores/mihomo/config.yaml
fi
release="/opt/sky-ui/releases/$release_version-$arch"
if [[ -e "$release" ]]; then
  [[ -f "$release/BUNDLE_SHA256" && "$(cat "$release/BUNDLE_SHA256")" == "$release_digest" ]] || fail 'This version already exists with different contents. Use a new release version.'
else
  find "$payload" -type d -exec chmod 0755 {} +
  find "$payload" -type f -exec chmod 0644 {} +
  chmod 0755 "$payload/bin/sky-ui" "$payload/bin/sky-ops" "$payload/bin/caddy"
  printf '%s\n' "$release_digest" >"$payload/BUNDLE_SHA256"
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
if [[ "$validation_binary" != - ]]; then "$release/bin/sky-ops" core-bootstrap activate --prepared "$temp/core"; fi
sed -i 's#^SKY_UI_CORE_BINARY=.*#SKY_UI_CORE_BINARY=/opt/sky-ui/cores/mihomo/current/mihomo#' /etc/sky-ui/server.env
if (( edge_was_running )); then systemctl stop sky-ui-edge.service; fi
if (( api_was_running )); then systemctl stop sky-ui.service; fi
install -m 0644 "$release/deploy/systemd/sky-ui.service" /etc/systemd/system/sky-ui.service
install -m 0644 "$release/deploy/systemd/sky-ui-mihomo.service" /etc/systemd/system/sky-ui-mihomo.service
for engine in sing-box xray amneziawg; do
  install -m 0644 "$release/deploy/systemd/sky-ui-$engine.service" "/etc/systemd/system/sky-ui-$engine.service"
done
install -m 0644 "$release/deploy/systemd/sky-ui-edge.service" /etc/systemd/system/sky-ui-edge.service
install -m 0644 "$release/deploy/systemd/sky-ui-certificates.service" /etc/systemd/system/sky-ui-certificates.service
install -m 0644 "$release/deploy/systemd/sky-ui-certificates.timer" /etc/systemd/system/sky-ui-certificates.timer
install -m 0644 "$release/deploy/systemd/sky-ui-maintenance.service" /etc/systemd/system/sky-ui-maintenance.service
install -m 0644 "$release/deploy/systemd/sky-ui-maintenance-recovery.service" /etc/systemd/system/sky-ui-maintenance-recovery.service
install -m 0644 "$release/deploy/systemd/sky-ui-update.service" /etc/systemd/system/sky-ui-update.service
install -m 0644 "$release/deploy/systemd/sky-ui-update-recovery.service" /etc/systemd/system/sky-ui-update-recovery.service
install -m 0644 "$release/deploy/systemd/sky-ui-cleanup.service" /etc/systemd/system/sky-ui-cleanup.service
install -m 0644 "$release/deploy/systemd/sky-ui-cleanup.timer" /etc/systemd/system/sky-ui-cleanup.timer
install -d -m 0755 /usr/local/bin
install -m 0755 "$release/deploy/sky-ui" /usr/local/bin/sky-ui
install -m 0755 "$release/deploy/skyui" /usr/local/bin/skyui
install -d -m 0755 /etc/polkit-1/rules.d
install -m 0644 "$release/deploy/polkit/49-sky-ui.rules" /etc/polkit-1/rules.d/49-sky-ui.rules
ln -s "$release" /opt/sky-ui/.next-link
mv -Tf /opt/sky-ui/.next-link /opt/sky-ui/current
unlock_worker
systemctl daemon-reload
systemctl try-restart systemd-journald@sky-ui.service
systemctl enable sky-ui-maintenance-recovery.service
# The core is not boot-enabled: the API restores its persisted desired state.
systemctl reset-failed sky-ui.service
printf 'SKY_UI_STAGE=activate\n'
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
"$release/bin/sky-ops" storage --record-panel "$previous" || printf 'Sky UI: retention history could not be saved.\n' >&2
systemctl enable --now sky-ui-cleanup.timer
sky_cache_clear || printf 'Sky UI: retry downloads will be removed by scheduled cleanup.\n' >&2
changed=0
printf 'Sky UI %s installed: http://127.0.0.1:%s\n' "$release_version" "$port"
if [[ ! -f /etc/sky-ui/access.conf ]]; then printf 'Configure public HTTPS and owner access with sudo skyui setup.\n'; fi
printf 'The core starts only after a panel action or restoration of a previously saved running state.\n'
if [[ -z "${SKY_UI_TRANSACTION_LOCK_FD:-}" ]]; then flock -u 9; fi
systemctl start --no-block sky-ui-cleanup.service || true
if [[ -z "${SKY_UI_TRANSACTION_LOCK_FD:-}" && ! -f /etc/sky-ui/access.conf ]] && (: </dev/tty) 2>/dev/null; then
  bash /opt/sky-ui/current/deploy/setup.sh
else
  printf 'Configure owner access and IP/domain: sudo skyui setup\n'
fi
