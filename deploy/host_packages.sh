#!/usr/bin/env bash
# Source-only package-manager abstraction; install fixed package names only.
sky_packages() {
  local purpose="$1"
  local -a packages
  if command -v apt-get >/dev/null; then
    local polkit_package=policykit-1
    apt-get update
    if apt-cache show polkitd >/dev/null 2>&1; then polkit_package=polkitd; fi
    packages=(ca-certificates curl tar gzip coreutils findutils mawk util-linux passwd openssl "$polkit_package" nftables iproute2 acl)
    if [[ "$purpose" == build ]]; then packages+=(gcc clang libc6-dev unzip debianutils); fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
  elif command -v dnf >/dev/null; then
    # Minimal RPM images provide the same commands in conflicting package variants.
    # Retain those variants instead of erasing/replacing the user's packages.
    local curl_package=curl coreutils_package=coreutils
    if command -v rpm >/dev/null && rpm -q curl-minimal >/dev/null 2>&1; then curl_package=curl-minimal; fi
    if command -v rpm >/dev/null && rpm -q coreutils-single >/dev/null 2>&1; then coreutils_package=coreutils-single; fi
    packages=(ca-certificates "$curl_package" tar gzip "$coreutils_package" findutils gawk util-linux shadow-utils openssl polkit nftables iproute acl)
    if [[ "$purpose" == build ]]; then packages+=(gcc clang glibc-devel unzip which); fi
    dnf install -y "${packages[@]}"
  elif command -v zypper >/dev/null; then
    packages=(ca-certificates curl tar gzip coreutils findutils gawk util-linux shadow openssl polkit nftables iproute2 acl)
    if [[ "$purpose" == build ]]; then packages+=(gcc clang glibc-devel unzip which); fi
    zypper --non-interactive install --no-recommends "${packages[@]}"
  elif command -v pacman >/dev/null; then
    packages=(ca-certificates curl tar gzip coreutils findutils gawk util-linux shadow openssl polkit nftables iproute2 acl)
    if [[ "$purpose" == build ]]; then packages+=(gcc clang glibc unzip which); fi
    # Use the host's existing repository snapshot; never upgrade the entire host.
    pacman -S --needed --noconfirm "${packages[@]}"
  else
    printf 'Sky UI: unsupported package manager. Need apt-get, dnf, zypper or pacman.\n' >&2
    return 1
  fi
}

sky_builder() {
  getent group sky-ui-build >/dev/null || groupadd --system sky-ui-build
  getent passwd sky-ui-build >/dev/null || useradd --system --gid sky-ui-build --no-create-home --home-dir /nonexistent --shell /bin/false sky-ui-build
  local builder_name builder_password builder_uid builder_gid builder_gecos builder_home builder_shell
  IFS=: read -r builder_name builder_password builder_uid builder_gid builder_gecos builder_home builder_shell < <(getent passwd sky-ui-build)
  [[ "$builder_uid" =~ ^[0-9]+$ && "$builder_gid" =~ ^[0-9]+$ && "$builder_uid" != 0 && "$builder_gid" != 0 &&
     "$builder_home" == /nonexistent && ( "$builder_shell" == /bin/false || "$builder_shell" == /sbin/nologin || "$builder_shell" == /usr/sbin/nologin ) ]] || {
    printf 'Sky UI: refusing an unsafe build account.\n' >&2; return 1;
  }
  [[ "$(getent group sky-ui-build | cut -d: -f3)" == "$builder_gid" && "$(id -G sky-ui-build)" == "$builder_gid" ]] || {
    printf 'Sky UI: build account has unexpected group access.\n' >&2; return 1;
  }
  local builder_members
  builder_members="$(getent group sky-ui-build | cut -d: -f4)"
  [[ -z "$builder_members" || "$builder_members" == sky-ui-build ]] || {
    printf 'Sky UI: build group contains another account.\n' >&2; return 1;
  }
  [[ -z "$(getent passwd | awk -F: -v gid="$builder_gid" '$4 == gid && $1 != "sky-ui-build" {print $1}')" ]] || {
    printf 'Sky UI: build group is shared with another account.\n' >&2; return 1;
  }
}
