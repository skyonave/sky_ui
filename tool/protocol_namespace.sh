#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="${1:?Pass an isolated protocol-matrix directory.}"
binary="${2:?Pass the pinned mihomo binary.}"
[[ "$fixture" == /*protocol-matrix* && "$fixture" != / ]] || { printf 'Invalid fixture directory.\n' >&2; exit 1; }
(( EUID == 0 )) || { printf 'Isolated kernel tests require root.\n' >&2; exit 1; }
if [[ "${3:-}" != --inside ]]; then
  export SKY_UI_TEST_PARENT_NET_NS="$(readlink /proc/self/ns/net)"
  export SKY_UI_TEST_PARENT_MOUNT_NS="$(readlink /proc/self/ns/mnt)"
  exec unshare --net --mount --propagation private bash "$0" "$fixture" "$binary" --inside
fi
[[ -n "${SKY_UI_TEST_PARENT_NET_NS:-}" && -n "${SKY_UI_TEST_PARENT_MOUNT_NS:-}" ]]
[[ "$(readlink /proc/self/ns/net)" != "$SKY_UI_TEST_PARENT_NET_NS" ]]
[[ "$(readlink /proc/self/ns/mnt)" != "$SKY_UI_TEST_PARENT_MOUNT_NS" ]]
mount -t sysfs -o nosuid,nodev,noexec sysfs /sys
ip link set lo up
export SKY_UI_TEST_ISOLATED_NETNS=1
umask 077
mkdir -p -- "$fixture"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -keyout "$fixture/key.pem" -out "$fixture/cert.pem" 2>"$fixture/certificate-generation.log"
cd "$root/app/api"
dart --suppress-analytics run tool/protocol_matrix.dart "$binary" "$fixture" --variants --listen
