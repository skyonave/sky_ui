#!/usr/bin/env bash
# Build-only Debian 11 userspace. No container engine is needed or installed.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { printf 'Use sudo on a dedicated Linux release runner.\n' >&2;exit 1; }
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
if [[ ${1:-} != --private-mounts ]]; then
  exec unshare --mount --propagation private bash "$0" --private-mounts
fi
source "$root/tool/release/versions.sh"
case "$(uname -m)" in
  x86_64) arch=amd64;sdk_arch=x64;sdk_sha="$dart_x64_sha" ;;
  aarch64|arm64) arch=arm64;sdk_arch=arm64;sdk_sha="$dart_arm64_sha" ;;
  *) exit 1 ;;
esac
stage=$(mktemp -d /var/tmp/sky-ui-release.XXXXXXXX)
cleanup() {
  for path in proc dev; do if mountpoint -q "$stage/root/$path"; then umount "$stage/root/$path"; fi;done
  rm -rf -- "$stage"
}
trap cleanup EXIT
debootstrap --variant=minbase --arch="$arch" --keyring=/usr/share/keyrings/debian-archive-keyring.gpg bullseye "$stage/root" https://deb.debian.org/debian
mount -t proc proc "$stage/root/proc"
mount --bind /dev "$stage/root/dev"
chroot "$stage/root" env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "$stage/root" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc clang libc6-dev curl unzip binutils ca-certificates openssl git
chroot "$stage/root" apt-get clean
mkdir -p "$stage/root/project" "$stage/root/opt"
git -c safe.directory="$root" -C "$root" ls-files --cached --others --exclude-standard -z | while IFS= read -r -d '' name; do
  case "$name" in app/*|deploy/*|tool/*|compatibility/*|VERSION|LICENSE|install.sh|README.md)
    if [[ -f "$root/$name" ]]; then printf '%s\0' "$name"; fi ;;
  esac
done >"$stage/files"
tar -C "$root" --null -T "$stage/files" -cf - | tar -C "$stage/root/project" -xf -
curl --proto '=https' --tlsv1.2 -fL --retry 3 -o "$stage/dart.zip" "https://storage.googleapis.com/dart-archive/channels/stable/release/$dart_fallback/sdk/dartsdk-linux-$sdk_arch-release.zip"
printf '%s  %s\n' "$sdk_sha" "$stage/dart.zip" | sha256sum --check --status
unzip -q "$stage/dart.zip" -d "$stage/root/opt"
rm -- "$stage/dart.zip"
chroot "$stage/root" /usr/bin/env HOME=/root PUB_CACHE=/root/.pub-cache PATH=/opt/dart-sdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin CI=true DART_SUPPRESS_ANALYTICS=true bash /project/tool/build_release.sh
version=$(tr -d '\r\n' <"$root/VERSION")
output="$root/build/releases/v$version"
mkdir -p "$output"
cp "$stage/root/project/build/releases/sky-ui-linux-$arch.tar.gz"{,.sha256} "$stage/root/project/build/releases/install.sh"{,.sha256} "$output/"
printf 'Prepared native %s assets in %s.\n' "$arch" "$output"
