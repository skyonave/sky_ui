#!/usr/bin/env bash
set -Eeuo pipefail
umask 022
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
[[ "$(uname -s)" == Linux ]] || { printf 'Prepare release assets on Linux.\n' >&2; exit 1; }
[[ $EUID == 0 ]] || { printf 'Release checks require Linux root for native ownership and cleanup tests.\n' >&2; exit 1; }
case "${SKY_UI_RELEASE_ARCH:-$(uname -m)}" in
  x86_64|amd64) arch=amd64; caddy_sha=727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b ;;
  aarch64|arm64) arch=arm64; caddy_sha=d8fc6d179a5d283028a472a5618564f6ad8a86fed513e64f032b3b0b7cc45e42 ;;
  *) printf 'Unsupported release architecture.\n' >&2; exit 1 ;;
esac
source "$root/tool/release/versions.sh"
version="$(tr -d '\r\n' <"$root/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]
output="$root/build/releases"
mkdir -p "$output"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
cc -shared -fPIC -O2 -Wall -Wextra -Werror "$root/app/ops/native/posix.c" -o "$stage/libsky_posix.so"
export SKY_UI_POSIX_LIBRARY="$stage/libsky_posix.so"
payload="$stage/payload"
mkdir -p "$payload/bin" "$payload/web/fonts" "$payload/deploy" "$payload/licenses" "$payload/source/app" "$payload/source/native"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 -o "$stage/sqlite.tar.gz" "$sqlite_url"
[[ "$(openssl dgst -sha3-256 "$stage/sqlite.tar.gz" | awk '{print $NF}')" == "$sqlite_sha3" ]] || { printf 'SQLite source checksum mismatch.\n' >&2; exit 1; }
tar -xOzf "$stage/sqlite.tar.gz" --wildcards '*/sqlite3.c' >"$payload/source/native/sqlite3.c"
checks="$stage/checks"
mkdir -p "$checks/app"
tar -C "$root/app" --exclude=.dart_tool --exclude=build -cf - api ops shared web | tar -C "$checks/app" -xf -
for package in api ops; do
  cat >>"$checks/app/$package/pubspec.yaml" <<HOOKS

hooks:
  user_defines:
    sqlite3:
      source: source
      path: $payload/source/native/sqlite3.c
      additional_libraries: [dl, pthread]
HOOKS
  (cd "$checks/app/$package"; dart pub get --enforce-lockfile; dart analyze; dart test --concurrency=1)
done
for package in api ops; do
  cd "$root/app/$package"
  dart pub get --enforce-lockfile
  dart analyze
  mkdir "$payload/source/app/$package"
  cp pubspec.yaml pubspec.lock "$payload/source/app/$package/"
  mkdir "$payload/source/app/$package/bin"
  if [[ "$package" == api ]]; then entry=server; else entry=sky_ops; fi
  cp "bin/$entry.dart" "$payload/source/app/$package/bin/"
  cp -R lib "$payload/source/app/$package/"
done
cp -R "$root/app/ops/native" "$payload/source/app/ops/"
mkdir "$payload/source/app/shared"
cp "$root/app/shared/pubspec.yaml" "$payload/source/app/shared/"
cp -R "$root/app/shared/lib" "$payload/source/app/shared/"
cd "$root/app/web"
dart pub get --enforce-lockfile
dart analyze lib web tool
dart compile js -O2 -DSKY_UI_VERSION="$version" web/main.dart -o "$payload/web/main.dart.js"
rm -f -- "$payload/web/main.dart.js.deps" "$payload/web/main.dart.js.map"
cp web/index.html web/styles.css "$payload/web/"
cp web/fonts/* "$payload/web/fonts/"
cp -R "$root/deploy/systemd" "$root/deploy/polkit" "$root/deploy/mihomo" "$payload/deploy/"
cp "$root/deploy/"*.sh "$root/deploy/sky-ui" "$root/deploy/skyui" "$root/deploy/journald-sky-ui.conf" "$root/deploy/sky-ui-install-tmpfiles.conf" "$payload/deploy/"
cp -R "$root/compatibility" "$payload/"
dart "$root/tool/collect_licenses.dart" "$root/app/api" "$root/app/ops" "$root/app/web" "$payload/licenses/dart"
cp "$root/LICENSE" "$payload/LICENSE"
cp "$root/app/web/FEATHER-LICENSE.txt" "$payload/licenses/feather.LICENSE"
printf '%s\n' "$version" >"$payload/VERSION"
printf '%s\n' "$arch" >"$payload/ARCH"
printf 'source-v1\n' >"$payload/BUILD_MODE"
printf 'SQLite is in the public domain: https://sqlite.org/copyright.html\nSource: %s\nSHA3-256: %s\n' "$sqlite_url" "$sqlite_sha3" >"$payload/licenses/sqlite.NOTICE"
curl --proto '=https' --tlsv1.2 --fail --location --retry 3 -o "$stage/caddy.tar.gz" "https://github.com/caddyserver/caddy/releases/download/v2.11.7/caddy_2.11.7_linux_$arch.tar.gz"
printf '%s  %s\n' "$caddy_sha" "$stage/caddy.tar.gz" | sha256sum --check --status
tar -xzf "$stage/caddy.tar.gz" -C "$payload/bin" caddy
tar -xOzf "$stage/caddy.tar.gz" LICENSE >"$payload/licenses/caddy.LICENSE"
chmod 0755 "$payload/bin/caddy"
bash "$root/tool/release/build_native.sh" "$payload"
bash "$root/tool/release/audit_native.sh" "$payload" "$arch"
cd "$root/app/ops"
dart run tool/native_manifest.dart "$root" "$payload" "$arch"
asset="sky-ui-linux-$arch.tar.gz"
tar -czf "$output/$asset" -C "$payload" .
(cd "$output" && sha256sum "$asset" >"$asset.sha256")
cp "$root/install.sh" "$output/install.sh"
(cd "$output" && sha256sum install.sh >install.sh.sha256)
if [[ "$arch" == "$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" ]]; then bash "$root/install.sh" --bundle "$output/$asset" --verify-only; fi
printf 'Native release bundle: %s/%s\n' "$output" "$asset"
