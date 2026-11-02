#!/usr/bin/env bash
# Restricted to the guarded, disposable systemd guest used by acceptance tests.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
[[ $EUID == 0 && -f /unrelated-fixture && "$(cat /unrelated-fixture)" == 'preserve me' && "$(hostname)" == sky-ui-install-test && "$(cat /run/systemd/container)" == systemd-nspawn ]] || { printf 'Use the private acceptance guest.\n' >&2; exit 1; }
[[ -n ${SKY_UI_TEST_PARENT_NET_NS:-} && "$(readlink /proc/self/ns/net)" != "$SKY_UI_TEST_PARENT_NET_NS" ]] || exit 1
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) exit 1 ;; esac
bundle="$root/build/releases/sky-ui-linux-$arch.tar.gz"
bash "$root/install.sh" --bundle "$bundle"
# Development-only harness requires an SDK; the installed panel does not.
dart run "$root/tool/installed_acceptance.dart" "$root/install.sh" "$bundle" "$@"
