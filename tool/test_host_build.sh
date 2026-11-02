#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
source "$root/deploy/build_versions.sh"
source "$root/deploy/dart_sdk.sh"
as_builder() { "$@"; }
for version in 3.12.9 3.13.0 3.13.7 3.14.0 4.0.0; do
  printf '#!/bin/bash\nprintf "Dart SDK version: %s (stable) on linux_x64\\n"\n' "$version" >"$test_dir/dart"
  chmod 0755 "$test_dir/dart"
  sdk=;sdk_version=
  if sky_compatible_sdk "$test_dir/dart"; then
    [[ "$version" == 3.13.0 || "$version" == 3.13.7 || "$version" == 3.14.0 ]]
    [[ "$sdk_version" == "$version" && "$sdk" == "$test_dir/dart" ]]
  else [[ "$version" == 3.12.9 || "$version" == 4.0.0 ]]; fi
done
printf '#!/bin/bash\nprintf "Dart SDK version: 3.14.0 (dev) on linux_x64\\n"\n' >"$test_dir/dart"
if sky_compatible_sdk "$test_dir/dart"; then printf 'Accepted prerelease SDK.\n' >&2;exit 1;fi
printf '#!/bin/bash\nif [[ "$1" == --version ]]; then printf "Dart SDK version: 3.13.7 (stable) on linux_x64\\n"; else exit 2; fi\n' >"$test_dir/dart"
if sky_compatible_sdk "$test_dir/dart"; then printf 'Accepted SDK without native build command.\n' >&2;exit 1;fi
source "$root/deploy/host_packages.sh"
for manager in apt-get dnf zypper pacman; do
  bin="$test_dir/$manager";mkdir "$bin"
  printf '#!/bin/bash\nprintf "%%s " "$@" >>"$SKY_UI_PACKAGE_TEST_LOG"; printf "\\n" >>"$SKY_UI_PACKAGE_TEST_LOG"\n' >"$bin/$manager"
  chmod 0755 "$bin/$manager"
  if [[ "$manager" == apt-get ]]; then cp "$bin/$manager" "$bin/apt-cache"; fi
  SKY_UI_PACKAGE_TEST_LOG="$test_dir/$manager.log" PATH="$bin" sky_packages build
  grep -F clang "$test_dir/$manager.log" >/dev/null
  if [[ "$manager" == pacman ]]; then
    grep -F -- '-S --needed --noconfirm' "$test_dir/$manager.log" >/dev/null
    if grep -F -- '-Syu' "$test_dir/$manager.log" >/dev/null; then exit 1; fi
  fi
done
printf 'PASS: SDK minimum/major/stable selection and four package-manager plans.\n'
