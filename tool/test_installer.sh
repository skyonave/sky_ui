#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
mkdir -p "$root/build"
test_dir="$(mktemp -d "$root/build/installer-test.XXXXXX")"
case "$test_dir" in "$root"/build/installer-test.*) ;; *) printf 'Unsafe temporary path.\n' >&2; exit 1 ;; esac
trap 'rm -rf -- "$test_dir"' EXIT
export TMPDIR="$test_dir"
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) exit 1 ;; esac
payload="$test_dir/payload"
mkdir -p "$payload/bin" "$payload/lib" "$payload/web/fonts" "$payload/deploy/systemd" "$payload/deploy/polkit" "$payload/deploy/mihomo" "$payload/licenses" "$payload/compatibility/cores"
for file in bin/sky-ui bin/caddy lib/libsqlite3.so web/index.html web/main.dart.js web/styles.css web/fonts/PxPlus_IBM_VGA8.ttf \
  web/fonts/LICENSE-IBM-VGA.txt web/fonts/ATTRIBUTION.txt deploy/systemd/sky-ui.service \
  deploy/systemd/sky-ui-sing-box.service deploy/systemd/sky-ui-xray.service deploy/systemd/sky-ui-amneziawg.service \
  deploy/engine_install.py deploy/amnezia_network.py compatibility/cores/amneziawg.json \
  deploy/systemd/sky-ui-mihomo.service deploy/systemd/sky-ui-edge.service deploy/systemd/sky-ui-certificates.service deploy/systemd/sky-ui-certificates.timer deploy/systemd/sky-ui-maintenance.service deploy/systemd/sky-ui-maintenance-recovery.service deploy/systemd/sky-ui-update.service deploy/systemd/sky-ui-update-recovery.service deploy/setup.sh deploy/render_access.sh deploy/certificate_sync.py deploy/maintenance.py deploy/panel_releases.py deploy/panel_update.py deploy/core_artifacts.py deploy/core_install.py deploy/sky-ui deploy/skyui deploy/cli.py compatibility/cores/mihomo.json compatibility/cores/sing-box.json compatibility/cores/xray.json deploy/polkit/49-sky-ui.rules deploy/mihomo/config.example.yaml LICENSE licenses/caddy.LICENSE; do
  printf 'Verification fixture; must never execute.\n' >"$payload/$file"
done
printf '0.1.0\n' >"$payload/VERSION"
printf '%s\n' "$arch" >"$payload/ARCH"
asset="sky-ui-linux-$arch.tar.gz"
bundle="$test_dir/$asset"
checksum() { (cd "$test_dir" && sha256sum "$asset" >"$asset.sha256"); }
reject() {
  local reason="$1"
  if bash "$root/install.sh" --bundle "$bundle" --verify-only >"$test_dir/result" 2>&1; then
    printf 'Installer unexpectedly accepted %s.\n' "$reason" >&2; exit 1
  fi
  grep -F "$reason" "$test_dir/result" >/dev/null
}
tar -czf "$bundle" -C "$payload" .
checksum
bash "$root/install.sh" --bundle "$bundle" --verify-only
printf '%064d  %s\n' 0 "$asset" >"$bundle.sha256"
reject 'checksum mismatch'
tar -czf "$bundle" --transform='s#^\./VERSION$#../outside#' -C "$payload" .
checksum
reject 'traversal'
[[ ! -e "$test_dir/outside" ]]
printf 'wrong-architecture\n' >"$payload/ARCH"
tar -czf "$bundle" -C "$payload" .
checksum
reject 'architecture mismatch'
printf '%s\n' "$arch" >"$payload/ARCH"
if [[ "$(uname -s)" == Linux ]]; then
  ln -s /etc/passwd "$payload/escape"
  tar -czf "$bundle" -C "$payload" .
  checksum
  reject 'links and special files'
fi
printf 'Installer archive checks passed.\n'
