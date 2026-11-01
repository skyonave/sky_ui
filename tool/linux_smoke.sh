#!/usr/bin/env bash
# Run only on a fresh disposable Linux VM: this installs system-wide services.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) exit 1 ;; esac
bundle="$root/build/releases/sky-ui-linux-$arch.tar.gz"
sudo bash "$root/install.sh" --bundle "$bundle"
sudo python3 "$root/tool/linux_owner_smoke.py" "$root/install.sh" "$bundle"
