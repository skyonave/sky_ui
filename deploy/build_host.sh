#!/usr/bin/env bash
# Build in an owned disposable workspace, leaving only the runtime bundle.
set -Eeuo pipefail
umask 077
fail() { printf 'Sky UI build: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 && $# == 1 ]] || fail 'Root and one verified payload directory are required.'
payload="$(realpath -- "$1")"
[[ -d "$payload/source/app/api" && -d "$payload/source/app/ops" ]] || fail 'Missing build source.'
source "$payload/deploy/build_versions.sh"
source "$payload/deploy/host_packages.sh"
source "$payload/deploy/dart_sdk.sh"
source "$payload/deploy/download_cache.sh"
printf 'SKY_UI_STAGE=prepare\n'
if ! command -v cc >/dev/null || ! command -v clang >/dev/null || ! command -v which >/dev/null || ! command -v unzip >/dev/null || ! command -v runuser >/dev/null; then
  sky_packages build
fi
sky_builder
available="$(df -B1 --output=avail "$payload" | tail -n 1 | tr -d ' ')"
[[ "$available" =~ ^[0-9]+$ ]] && (( available >= 1610612736 )) || fail 'At least 1.5 GB of free disk space is required for local compilation.'
memory_kb="$(awk '/^MemAvailable:|^SwapFree:/ {total += $2} END {printf "%.0f", total}' /proc/meminfo)"
[[ "$memory_kb" =~ ^[0-9]+$ ]] && (( memory_kb >= 524288 )) || fail 'At least 512 MB of available RAM and swap is required for local compilation.'
work="$(mktemp -d /var/tmp/sky-ui-build.XXXXXXXX)"
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 0755 "$work"
mkdir "$work/source" "$work/cache" "$work/home" "$work/tmp" "$work/output"
cp -R "$payload/source/." "$work/source/"
chown -R sky-ui-build:sky-ui-build "$work/source" "$work/cache" "$work/home" "$work/tmp" "$work/output"
arch="$(tr -d '\r\n' <"$payload/ARCH")"
case "$arch" in amd64) sdk_arch=x64; sdk_sha="$dart_x64_sha" ;; arm64) sdk_arch=arm64; sdk_sha="$dart_arm64_sha" ;; *) fail 'Unsupported architecture.' ;; esac
sdk=;sdk_version=
if command -v dart >/dev/null; then
  candidate="$(command -v dart)"
  sky_try_sdk "$candidate" || true
  if [[ -z "$sdk" && -x "$(dirname -- "$candidate")/cache/dart-sdk/bin/dart" ]]; then sky_try_sdk "$(dirname -- "$candidate")/cache/dart-sdk/bin/dart" || true; fi
fi
if [[ -z "$sdk" && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  for candidate in "$user_home/dart-sdk/bin/dart" "$user_home/flutter/bin/cache/dart-sdk/bin/dart" "$user_home/.local/share/dart-sdk/bin/dart"; do
    if [[ -x "$candidate" ]]; then sky_try_sdk "$candidate" && break || true; fi
  done
fi
printf 'SKY_UI_STAGE=toolchain\n'
if [[ -z "$sdk" ]]; then
  if sky_cache_get dart "$sdk_sha" "$work/dart.zip"; then
    printf 'Reusing verified Dart SDK download %s (%s).\n' "$dart_fallback" "$sdk_arch"
  else
    printf 'Downloading temporary Dart SDK %s (%s).\n' "$dart_fallback" "$sdk_arch"
    curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --max-time 600 --max-filesize 268435456 \
      -o "$work/dart.zip" "https://storage.googleapis.com/dart-archive/channels/stable/release/$dart_fallback/sdk/dartsdk-linux-$sdk_arch-release.zip"
  fi
  printf '%s  %s\n' "$sdk_sha" "$work/dart.zip" | sha256sum --check --status || fail 'Dart SDK checksum mismatch.'
  sky_cache_put dart "$sdk_sha" "$work/dart.zip" || printf 'Sky UI: could not retain the SDK download for retry.\n' >&2
  unzip -q "$work/dart.zip" -d "$work"
  rm -f -- "$work/dart.zip"
  # The SDK is read-only to the build account; only owned caches are writable.
  find "$work/dart-sdk" -type d -exec chmod 0755 {} +
  find "$work/dart-sdk" -type f -perm /111 -exec chmod 0755 {} +
  find "$work/dart-sdk" -type f ! -perm /111 -exec chmod 0644 {} +
  if ! sky_compatible_sdk "$work/dart-sdk/bin/dart"; then
    printf 'Dart SDK probe failed (%s, exit %s):\n' "$sdk_probe_stage" "$sdk_probe_status" >&2
    printf '%s\n' "$sdk_probe_output" | tail -c 16384 >&2
    fail 'The downloaded SDK could not pass its build capability check.'
  fi
else
  printf 'Using existing Dart SDK %s: %s\n' "$sdk_version" "$sdk"
fi
printf 'SKY_UI_STAGE=build\n'
# The verified release contains SQLite source, not a build-host shared library.
[[ -f "$work/source/native/sqlite3.c" ]] || fail 'Missing SQLite source.'
for package in api ops; do
  cat >>"$work/source/app/$package/pubspec.yaml" <<HOOKS

hooks:
  user_defines:
    sqlite3:
      source: source
      path: $work/source/native/sqlite3.c
HOOKS
  if ! as_builder bash -ec 'cd -- "$1"; "$2" --suppress-analytics pub get --enforce-lockfile; "$2" --suppress-analytics build cli --target "$3" --output "$4" --verbosity warning' \
    sky-ui-build "$work/source/app/$package" "$sdk" "bin/$([[ "$package" == api ]] && printf server || printf sky_ops).dart" "$work/output/$package" >"$work/$package-build.log" 2>&1; then
    tail -n 80 -- "$work/$package-build.log" >&2
    fail "Failed to compile $package."
  fi
  printf 'Built %s.\n' "$package"
done
as_builder cc -shared -fPIC -O2 -Wall -Wextra -Werror "$work/source/app/ops/native/posix.c" -o "$work/output/libsky_posix.so"
mkdir -p "$payload/bin" "$payload/lib"
install -m 0755 "$work/output/api/bundle/bin/server" "$payload/bin/sky-ui"
install -m 0755 "$work/output/ops/bundle/bin/sky_ops" "$payload/bin/sky-ops"
cp -R "$work/output/api/bundle/lib/." "$payload/lib/"
# Both executables resolve the same relative SQLite asset. Compare before merging.
for library in "$work/output/ops/bundle/lib/"*; do
  name="$(basename -- "$library")"
  if [[ -e "$payload/lib/$name" ]]; then cmp -- "$library" "$payload/lib/$name" || fail 'Native asset collision.'
  else install -m 0644 "$library" "$payload/lib/$name"; fi
done
install -m 0644 "$work/output/libsky_posix.so" "$payload/lib/libsky_posix.so"
printf 'SKY_UI_STAGE=validate\n'
chmod 0755 "$payload" "$payload/bin" "$payload/lib"
install -m 0644 "$work/output/libsky_posix.so" "$work/output/ops/bundle/lib/libsky_posix.so"
as_builder "$work/output/ops/bundle/bin/sky_ops" --self-test
[[ "$("$payload/bin/sky-ui" --version)" == "Sky UI $(tr -d '\r\n' <"$payload/VERSION")" ]] || fail 'Candidate API version mismatch.'
printf 'Dart: %s\nArchitecture: %s\nLibc: %s\nBuild: target-host\n' "$sdk_version" "$arch" "$(getconf GNU_LIBC_VERSION)" >"$payload/BUILDINFO"
printf 'native-v1\n' >"$payload/BUILD_MODE"
rm -rf -- "$payload/source"
printf 'Target-host compilation complete. Temporary SDK, source and caches will be removed.\n'
