#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
[[ "$(uname -s)" == Linux ]] || { printf 'Build native Linux bundles on Linux.\n' >&2; exit 1; }
case "$(uname -m)" in
  x86_64) arch=amd64; caddy_sha=727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b; mihomo_asset=mihomo-linux-amd64-v1-v1.19.33.gz; mihomo_sha=8ec92e7b2fdc6b853ba00156bab7e4e965c8b0d843b8c4ac8ab98795f02ad524 ;;
  aarch64|arm64) arch=arm64; caddy_sha=d8fc6d179a5d283028a472a5618564f6ad8a86fed513e64f032b3b0b7cc45e42; mihomo_asset=mihomo-linux-arm64-v1.19.33.gz; mihomo_sha=ba408b317080ee265c46cb923a50018c1b82cbd708551cdd46a1e3e307396187 ;;
  *) printf 'Unsupported build architecture.\n' >&2; exit 1 ;;
esac
version="$(tr -d '\r\n' <"$root/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]
output="$root/build/releases"
mkdir -p "$output"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/payload/bin" "$stage/payload/web/fonts" "$stage/payload/deploy" "$stage/payload/licenses"
cd "$root/app/api"
dart pub get --enforce-lockfile
dart analyze
dart test --concurrency=1
dart build cli --target bin/server.dart --output "$stage/api" --verbosity warning
cp "$stage/api/bundle/bin/server" "$stage/payload/bin/sky-ui"
cp -R "$stage/api/bundle/lib" "$stage/payload/lib"
cd "$root/app/web"
dart pub get --enforce-lockfile
dart analyze lib web tool
dart compile js -O2 -DSKY_UI_VERSION="$version" web/main.dart -o "$stage/payload/web/main.dart.js"
cp web/index.html web/styles.css "$stage/payload/web/"
cp web/fonts/* "$stage/payload/web/fonts/"
cp -R "$root/deploy/systemd" "$root/deploy/polkit" "$root/deploy/mihomo" "$stage/payload/deploy/"
cp "$root/deploy/setup.sh" "$root/deploy/sky-ui" "$root/deploy/skyui" "$root/deploy/cli.py" "$stage/payload/deploy/"
cp "$root/deploy/render_access.sh" "$stage/payload/deploy/"
cp "$root/deploy/certificate_sync.py" "$stage/payload/deploy/"
cp -R "$root/compatibility" "$stage/payload/"
cp "$root/deploy/maintenance.py" "$stage/payload/deploy/"
dart "$root/tool/collect_licenses.dart" "$root/app/api" "$root/app/web" "$stage/payload/licenses/dart"
cp "$root/LICENSE" "$stage/payload/LICENSE"
cp "$root/app/web/FEATHER-LICENSE.txt" "$stage/payload/licenses/feather.LICENSE"
printf '%s\n' "$version" >"$stage/payload/VERSION"
printf '%s\n' "$arch" >"$stage/payload/ARCH"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
  -o "$stage/mihomo.gz" "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/$mihomo_asset"
printf '%s  %s\n' "$mihomo_sha" "$stage/mihomo.gz" | sha256sum --check --status
gzip -dc "$stage/mihomo.gz" >"$stage/payload/bin/mihomo"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
  -o "$stage/payload/licenses/mihomo.LICENSE" https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.33/LICENSE
chmod 0755 "$stage/payload/bin/sky-ui" "$stage/payload/bin/mihomo"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 -o "$stage/caddy.tar.gz" "https://github.com/caddyserver/caddy/releases/download/v2.11.7/caddy_2.11.7_linux_$arch.tar.gz"
printf '%s  %s\n' "$caddy_sha" "$stage/caddy.tar.gz" | sha256sum --check --status
tar -xzf "$stage/caddy.tar.gz" -C "$stage/payload/bin" caddy
tar -xOzf "$stage/caddy.tar.gz" LICENSE >"$stage/payload/licenses/caddy.LICENSE"
chmod 0755 "$stage/payload/bin/caddy"
"$stage/payload/bin/sky-ui" --version
"$stage/payload/bin/mihomo" -v
printf 'Dart: %s\nArchitecture: %s\nLibc: %s\n' "$(dart --version 2>&1)" "$arch" "$(getconf GNU_LIBC_VERSION)" >"$stage/payload/BUILDINFO"
asset="sky-ui-linux-$arch.tar.gz"
tar -czf "$output/$asset" -C "$stage/payload" .
(cd "$output" && sha256sum "$asset" >"$asset.sha256")
cp "$root/install.sh" "$output/install.sh"
(cd "$output" && sha256sum install.sh >install.sh.sha256)
bash "$root/install.sh" --bundle "$output/$asset" --verify-only
printf 'Release bundle: %s/%s\n' "$output" "$asset"
