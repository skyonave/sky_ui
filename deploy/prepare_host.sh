#!/usr/bin/env bash
# Fixed host prerequisites, also callable outside the updater's read-only mount.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || exit 1
if ! command -v pkaction >/dev/null || ! command -v openssl >/dev/null || ! command -v nft >/dev/null || ! command -v ip >/dev/null; then
  command -v apt-get >/dev/null || { printf 'Missing host dependencies: polkit, openssl, nftables, iproute2.\n' >&2; exit 1; }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends polkitd openssl ca-certificates python3 nftables iproute2
fi
getent group sky-ui >/dev/null || groupadd --system sky-ui
getent passwd sky-ui >/dev/null || useradd --system --gid sky-ui --no-create-home --home-dir /var/lib/sky-ui --shell /usr/sbin/nologin sky-ui
getent passwd sky-ui-core >/dev/null || useradd --system --gid sky-ui --no-create-home --home-dir /var/lib/sky-ui/cores/mihomo --shell /usr/sbin/nologin sky-ui-core
for engine in sing-box xray; do
  getent passwd "sky-ui-$engine" >/dev/null || useradd --system --gid sky-ui --no-create-home --home-dir "/var/lib/sky-ui/cores/$engine" --shell /usr/sbin/nologin "sky-ui-$engine"
done
getent group sky-ui-build >/dev/null || groupadd --system sky-ui-build
getent passwd sky-ui-build >/dev/null || useradd --system --gid sky-ui-build --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin sky-ui-build
getent group sky-ui-edge >/dev/null || groupadd --system sky-ui-edge
getent passwd sky-ui-edge >/dev/null || useradd --system --gid sky-ui-edge --no-create-home --home-dir /var/lib/sky-ui-edge --shell /usr/sbin/nologin sky-ui-edge
install -d -m 0700 -o root -g root /var/lib/sky-ui-amneziawg-network
