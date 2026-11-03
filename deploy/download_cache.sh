# Root-only, bounded retry cache. Extracted SDKs and build trees remain disposable.
sky_download_cache=/var/cache/sky-ui-install
sky_cache_init() {
  [[ $EUID == 0 && "$(realpath -m -- "$sky_download_cache")" == "$sky_download_cache" && ! -L "$sky_download_cache" ]] || return 1
  if [[ ! -e "$sky_download_cache" ]]; then
    mkdir -m 0700 -- "$sky_download_cache" || return 1
    (umask 077; printf 'sky-ui-download-cache-v1\n' >"$sky_download_cache/managed-by-sky-ui") || return 1
  fi
  [[ -d "$sky_download_cache" && "$(stat -c '%u:%g:%a' -- "$sky_download_cache")" == 0:0:700 &&
     ! -L "$sky_download_cache/managed-by-sky-ui" && -f "$sky_download_cache/managed-by-sky-ui" &&
     "$(stat -c '%u:%h:%a' -- "$sky_download_cache/managed-by-sky-ui")" == 0:1:600 &&
     "$(cat "$sky_download_cache/managed-by-sky-ui")" == sky-ui-download-cache-v1 ]] || return 1
  [[ ! -L "$sky_download_cache/.lock" && ( ! -e "$sky_download_cache/.lock" || -f "$sky_download_cache/.lock" ) ]] || return 1
}
sky_cache_name() {
  [[ "$2" =~ ^[a-f0-9]{64}$ ]] || return 1
  case "$1" in panel) printf 'panel-%s.tar.gz' "$2" ;; dart) printf 'dart-%s.zip' "$2" ;; *) return 1 ;; esac
}
sky_cache_file_safe() {
  [[ ! -L "$1" && -f "$1" && "$(stat -c '%u:%h:%a' -- "$1")" == 0:1:600 ]]
}
sky_cache_prune_locked() {
  local file name now modified
  now=$(date +%s)
  for file in "$sky_download_cache"/* "$sky_download_cache"/.download.*; do
    [[ -e "$file" || -L "$file" ]] || continue
    name="${file##*/}"
    [[ "$name" =~ ^(panel-[a-f0-9]{64}\.tar\.gz|dart-[a-f0-9]{64}\.zip|\.download\.[A-Za-z0-9]{8})$ ]] || continue
    sky_cache_file_safe "$file" || return 1
    modified=$(stat -c %Y -- "$file")
    if [[ "$name" == .download.* ]] || (( now - modified >= 86400 )); then rm -f -- "$file" || return 1; fi
  done
}
sky_cache_get() (
  local name file
  name=$(sky_cache_name "$1" "$2") || return 1
  sky_cache_init || return 1
  [[ -w "$sky_download_cache" ]] || return 1
  exec 7>>"$sky_download_cache/.lock" || return 1
  [[ "$(stat -Lc '%u:%h' /proc/self/fd/7)" == 0:1 ]] || return 1
  flock 7 || return 1
  sky_cache_prune_locked || return 1
  file="$sky_download_cache/$name"
  sky_cache_file_safe "$file" || return 1
  local limit
  if [[ "$1" == dart ]]; then limit=268435456; else limit=167772160;fi
  (( $(stat -c %s -- "$file") <= limit )) || return 1
  if [[ "$(sha256sum -- "$file" | awk '{print $1}')" != "$2" ]]; then rm -f -- "$file";return 1;fi
  cp -- "$file" "$3" || return 1
  touch -- "$file"
)
sky_cache_put() (
  local name temporary file limit size
  name=$(sky_cache_name "$1" "$2") || return 1
  if [[ "$1" == dart ]]; then limit=268435456; else limit=167772160;fi
  size=$(stat -c %s -- "$3") || return 1
  (( size > 0 && size <= limit )) || return 1
  sky_cache_init || return 1
  [[ -w "$sky_download_cache" ]] || return 1
  exec 7>>"$sky_download_cache/.lock" || return 1
  [[ "$(stat -Lc '%u:%h' /proc/self/fd/7)" == 0:1 ]] || return 1
  flock 7 || return 1
  sky_cache_prune_locked || return 1
  # Evict the previous archive of this kind before storing the next one.
  for file in "$sky_download_cache/$1-"*; do
    [[ -e "$file" || -L "$file" ]] || continue
    [[ "${file##*/}" =~ ^(panel-[a-f0-9]{64}\.tar\.gz|dart-[a-f0-9]{64}\.zip)$ ]] || continue
    sky_cache_file_safe "$file" || return 1
    rm -f -- "$file" || return 1
  done
  temporary=$(mktemp "$sky_download_cache/.download.XXXXXXXX") || return 1
  trap 'rm -f -- "$temporary"' EXIT
  cp -- "$3" "$temporary" || return 1
  chmod 0600 "$temporary" || return 1
  [[ "$(sha256sum -- "$temporary" | awk '{print $1}')" == "$2" ]] || return 1
  mv -f -- "$temporary" "$sky_download_cache/$name"
)
sky_cache_clear() (
  [[ -e "$sky_download_cache" || -L "$sky_download_cache" ]] || return 0
  sky_cache_init || return 1
  [[ -w "$sky_download_cache" ]] || return 1
  exec 7>>"$sky_download_cache/.lock" || return 1
  [[ "$(stat -Lc '%u:%h' /proc/self/fd/7)" == 0:1 ]] || return 1
  flock 7 || return 1
  local file
  for file in "$sky_download_cache"/panel-*.tar.gz "$sky_download_cache"/dart-*.zip "$sky_download_cache"/.download.*; do
    [[ -e "$file" || -L "$file" ]] || continue
    [[ "${file##*/}" =~ ^(panel-[a-f0-9]{64}\.tar\.gz|dart-[a-f0-9]{64}\.zip|\.download\.[A-Za-z0-9]{8})$ ]] || continue
    sky_cache_file_safe "$file" || return 1
    rm -f -- "$file" || return 1
  done
)
