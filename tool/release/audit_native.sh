#!/usr/bin/env bash
# Audit the entire native bundle, including SQLite and the POSIX bridge.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 1
payload="$1"; arch="$2"; baseline=2.31
case "$arch" in amd64) machine='Advanced Micro Devices X86-64' ;; arm64) machine=AArch64 ;; *) exit 1 ;; esac
for file in "$payload/bin/sky-ui" "$payload/bin/sky-ops" "$payload/bin/caddy" "$payload/lib/"*.so; do
  actual=$(LC_ALL=C readelf -h "$file" | sed -n 's/^ *Machine: *//p')
  [[ "$actual" == "$machine" ]] || { printf 'Wrong ELF architecture: %s\n' "$file" >&2;exit 1; }
  versions=$(LC_ALL=C readelf --version-info "$file")
  for version in $(printf '%s\n' "$versions" | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -Vu || true); do
    [[ "$(printf '%s\n%s\n' "$baseline" "${version#GLIBC_}" | sort -V | tail -n 1)" == "$baseline" ]] || {
      printf '%s requires %s, above the release baseline glibc %s. Build in the compatibility environment.\n' "$file" "$version" "$baseline" >&2;exit 1;
    }
  done
  while IFS= read -r library; do
    case "$library" in libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|libgcc_s.so.1|ld-linux-x86-64.so.2|ld-linux-aarch64.so.1) ;;
      *) printf 'Unbundled native dependency: %s (%s)\n' "$library" "$file" >&2;exit 1 ;;
    esac
  done < <(LC_ALL=C readelf -d "$file" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
done
printf '%s\n' "$baseline" >"$payload/MIN_GLIBC"
printf 'PASS: %s ELF architecture, dependency set and glibc <= %s.\n' "$arch" "$baseline"
