#!/usr/bin/env bash
# Build-only prerequisites; failed compilation must not leave a partial panel.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || exit 1
source "$(dirname -- "$0")/host_packages.sh"
needs_packages=0
for command in cc clang which unzip runuser getent groupadd useradd curl tar gzip openssl find; do
  if ! command -v "$command" >/dev/null; then needs_packages=1; fi
done
if (( ! needs_packages )); then
  # A compiler executable without libc development headers is not sufficient.
  if ! printf '#include <sys/stat.h>\n#include <spawn.h>\nint main(void){return 0;}\n' | cc -x c -fsyntax-only - >/dev/null 2>&1; then needs_packages=1; fi
fi
if (( needs_packages )); then
  available="$(df -B1 --output=avail /var/tmp | tail -n 1 | tr -d ' ')"
  [[ "$available" =~ ^[0-9]+$ ]] && (( available >= 2147483648 )) || {
    printf 'Sky UI: at least 2 GB of free disk space is required before installing build dependencies.\n' >&2; exit 1;
  }
  sky_packages build
fi
sky_builder
