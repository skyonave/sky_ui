#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { printf 'Run cache ownership checks as Linux root.\n' >&2;exit 1; }
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
source "$root/deploy/download_cache.sh"
sky_download_cache="$test_dir/downloads"
printf 'fixture-1' >"$test_dir/input"
one=$(sha256sum "$test_dir/input" | awk '{print $1}')
sky_cache_put dart "$one" "$test_dir/input"
sky_cache_get dart "$one" "$test_dir/output"
cmp "$test_dir/input" "$test_dir/output"
printf 'fixture-2' >"$test_dir/input"
two=$(sha256sum "$test_dir/input" | awk '{print $1}')
sky_cache_put dart "$two" "$test_dir/input"
[[ ! -e "$sky_download_cache/dart-$one.zip" ]]
sky_cache_put panel "$two" "$test_dir/input"
[[ $(find "$sky_download_cache" -type f \( -name '*.zip' -o -name '*.tar.gz' \) | wc -l) == 2 ]]
printf 'damaged' >"$sky_download_cache/dart-$two.zip"
if sky_cache_get dart "$two" "$test_dir/output"; then exit 1;fi
[[ ! -e "$sky_download_cache/dart-$two.zip" ]]
touch -d '25 hours ago' "$sky_download_cache/panel-$two.tar.gz"
if sky_cache_get panel "$two" "$test_dir/output"; then exit 1;fi
printf 'foreign' >"$test_dir/sentinel"
ln -s "$test_dir/sentinel" "$sky_download_cache/dart-$one.zip"
if sky_cache_get dart "$one" "$test_dir/output"; then exit 1;fi
[[ $(cat "$test_dir/sentinel") == foreign ]]
rm -- "$sky_download_cache/dart-$one.zip"
ln "$test_dir/sentinel" "$sky_download_cache/dart-$one.zip"
if sky_cache_get dart "$one" "$test_dir/output"; then exit 1;fi
[[ $(cat "$test_dir/sentinel") == foreign ]]
rm -- "$sky_download_cache/dart-$one.zip"
sky_cache_put dart "$one" "$test_dir/sentinel" && exit 1
sky_cache_put dart "$two" "$test_dir/input"
sky_cache_clear
[[ $(find "$sky_download_cache" -name '*.zip' -o -name '*.tar.gz' | wc -l) == 0 ]]
sky_download_cache="$test_dir/foreign"
mkdir -m 0700 "$sky_download_cache"
printf 'preserve' >"$sky_download_cache/sentinel"
if sky_cache_get dart "$one" "$test_dir/output"; then exit 1;fi
[[ $(cat "$sky_download_cache/sentinel") == preserve ]]
if command -v systemd-tmpfiles >/dev/null; then
  mirror="$test_dir/system"
  mkdir -p "$mirror/var/cache/sky-ui-install"
  for name in managed-by-sky-ui .lock archive.zip; do printf fixture >"$mirror/var/cache/sky-ui-install/$name"; done
  sed 's/ 1d$/ 0/' "$root/deploy/sky-ui-install-tmpfiles.conf" >"$test_dir/policy.conf"
  sleep 1
  systemd-tmpfiles --root="$mirror" --clean "$test_dir/policy.conf"
  [[ -f "$mirror/var/cache/sky-ui-install/managed-by-sky-ui" && -f "$mirror/var/cache/sky-ui-install/.lock" && ! -e "$mirror/var/cache/sky-ui-install/archive.zip" ]]
fi
printf 'PASS: retry cache reuse, SHA-256, expiry, bounds, cleanup and foreign-file boundaries.\n'
