#!/usr/bin/env bash
# Fixed host prerequisites, also callable outside the updater's read-only mount.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || exit 1
source "$(dirname -- "$0")/host_packages.sh"
if ! command -v pkaction >/dev/null || ! command -v openssl >/dev/null || ! command -v nft >/dev/null || ! command -v ip >/dev/null || ! command -v setfacl >/dev/null; then
  sky_packages runtime
fi
getent group sky-ui >/dev/null || groupadd --system sky-ui
getent passwd sky-ui >/dev/null || useradd --system --gid sky-ui --no-create-home --home-dir /var/lib/sky-ui --shell /usr/sbin/nologin sky-ui
getent passwd sky-ui-core >/dev/null || useradd --system --gid sky-ui --no-create-home --home-dir /var/lib/sky-ui/cores/mihomo --shell /usr/sbin/nologin sky-ui-core
for engine in sing-box xray; do
  getent passwd "sky-ui-$engine" >/dev/null || useradd --system --gid sky-ui --no-create-home --home-dir "/var/lib/sky-ui/cores/$engine" --shell /usr/sbin/nologin "sky-ui-$engine"
done
sky_builder
getent group sky-ui-edge >/dev/null || groupadd --system sky-ui-edge
getent passwd sky-ui-edge >/dev/null || useradd --system --gid sky-ui-edge --no-create-home --home-dir /var/lib/sky-ui-edge --shell /usr/sbin/nologin sky-ui-edge
install -d -m 0700 -o root -g root /var/lib/sky-ui-amneziawg-network
# Fixed namespace plumbing also works when an older updater mounts /etc read-only.
# Its configuration follows the active release, including rollback.
journal_config=/etc/systemd/journald@sky-ui.conf
journal_target=/opt/sky-ui/current/deploy/journald-sky-ui.conf
if [[ -e "$journal_config" || -L "$journal_config" ]]; then
  [[ -L "$journal_config" && "$(readlink "$journal_config")" == "$journal_target" ]] || { printf 'Sky UI journal namespace is already configured externally.\n' >&2; exit 1; }
else
  ln -s "$journal_target" "$journal_config"
fi
machine="$(tr -d '\n' </etc/machine-id)"
[[ "$machine" =~ ^[0-9a-f]{32}$ ]] || exit 1
journal_dir="/var/log/journal/$machine.sky-ui"
install -d -m 2755 -o root -g systemd-journal "$journal_dir"
setfacl -R -m u:sky-ui:rX "$journal_dir"
setfacl -m d:u:sky-ui:rX "$journal_dir"
