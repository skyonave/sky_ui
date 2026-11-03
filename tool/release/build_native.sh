#!/usr/bin/env bash
# Build in an owned disposable workspace, leaving only the runtime bundle.
set -Eeuo pipefail
umask 077
fail() { printf 'Sky UI build: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 && $# == 1 ]] || fail 'Root and one verified payload directory are required.'
payload="$(realpath -- "$1")"
[[ -d "$payload/source/app/api" && -d "$payload/source/app/ops" ]] || fail 'Missing build source.'
source "$(dirname -- "$0")/versions.sh"
source "$(dirname -- "$0")/../../deploy/host_packages.sh"
source "$(dirname -- "$0")/dart_sdk.sh"

printf 'SKY_UI_STAGE=prepare\n'
for command in cc clang which unzip runuser readelf; do command -v "$command" >/dev/null || fail "Missing release build tool: $command"; done
sky_builder
available="$(df -B1 --output=avail "$payload" | tail -n 1 | tr -d ' ')"
[[ "$available" =~ ^[0-9]+$ ]] && (( available >= 1610612736 )) || fail 'At least 1.5 GB of free disk space is required for local compilation.'
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
[[ -n "$sdk" && "$sdk_version" == "$dart_fallback" ]] || fail "Release builds require the pinned Dart SDK $dart_fallback on PATH."
case "$(uname -m)" in x86_64) host_arch=amd64 ;; aarch64|arm64) host_arch=arm64 ;; *) fail 'Unsupported build host.' ;; esac
[[ "$arch" == "$host_arch" ]] || fail 'Build native releases on a runner of the target architecture.'
sdk_root="$(dirname -- "$(dirname -- "$(realpath -- "$sdk")")")"
install -m 0644 "$sdk_root/LICENSE" "$payload/licenses/dart-sdk.LICENSE"
printf 'Using release Dart SDK %s.\n' "$sdk_version"
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
      additional_libraries: [dl, pthread]
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
printf 'Dart: %s\nArchitecture: %s\nLibc: %s\nBuild: release-runner\n' "$sdk_version" "$arch" "$(getconf GNU_LIBC_VERSION)" >"$payload/BUILDINFO"
printf 'native-v1\n' >"$payload/BUILD_MODE"
rm -rf -- "$payload/source"
printf 'Native release compilation complete. Temporary build workspace will be removed.\n'
