#!/usr/bin/env bash
# Run only on a fresh disposable Linux VM: this installs system-wide services.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) exit 1 ;; esac
bundle="$root/build/releases/sky-ui-linux-$arch.tar.gz"
sudo bash "$root/install.sh" --bundle "$bundle"
api=http://127.0.0.1:39241/api/v1
curl --noproxy '*' --fail --silent "$api/health"
curl --noproxy '*' --fail --silent -H 'Content-Type: application/json' -X POST "$api/cores/primary/actions/start" | grep '"controllerReady":true'
curl --noproxy '*' --fail --silent -H 'Content-Type: application/json' -X POST "$api/cores/primary/actions/restart" | grep '"controllerReady":true'
curl --noproxy '*' --fail --silent -H 'Content-Type: application/json' -X POST "$api/cores/primary/actions/stop" | grep '"processState":"inactive"'
secret_before="$(sudo sha256sum /etc/sky-ui/controller.secret)"
config_before="$(sudo sha256sum /var/lib/sky-ui/cores/mihomo/config.yaml)"
sudo bash "$root/install.sh" --bundle "$bundle"
[[ "$secret_before" == "$(sudo sha256sum /etc/sky-ui/controller.secret)" ]]
[[ "$config_before" == "$(sudo sha256sum /var/lib/sky-ui/cores/mihomo/config.yaml)" ]]
curl --noproxy '*' --fail --silent "$api/cores/primary" | grep '"processState":"inactive"'
printf 'Linux systemd smoke checks passed.\n'
