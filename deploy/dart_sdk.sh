# SDK probing runs through the unprivileged builder supplied by the caller.
sky_sdk_supported() {
  local output="$1" found major
  [[ "$output" =~ Dart\ SDK\ version:\ ([0-9]+\.[0-9]+\.[0-9]+)\ \(stable\) ]] || return 1
  found="${BASH_REMATCH[1]}"; major="${found%%.*}"
  [[ "$major" == "$dart_major" && "$(printf '%s\n%s\n' "$dart_min" "$found" | sort -V | head -n 1)" == "$dart_min" ]] || return 1
  sdk_version="$found"
}
sky_compatible_sdk() {
  local candidate="$1" output
  output="$(as_builder "$candidate" --version 2>&1)" || return 1
  sky_sdk_supported "$output" || return 1
  as_builder "$candidate" --suppress-analytics build cli --help >/dev/null 2>&1 || return 1
  sdk="$candidate"
}
sky_try_sdk() {
  local candidate="$1" real sdk_root declared part
  if sky_compatible_sdk "$candidate"; then return; fi
  # Private home directories may hide a usable SDK from the dedicated builder.
  # Copy only SDK components into our workspace; never relax original permissions.
  real="$(realpath -- "$candidate")" || return 1
  sdk_root="$(dirname -- "$(dirname -- "$real")")"
  [[ -f "$sdk_root/version" && -d "$sdk_root/bin/snapshots" && -d "$sdk_root/lib/_internal" ]] || return 1
  declared="$(tr -d '\r\n' <"$sdk_root/version")"
  [[ "$declared" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  sky_sdk_supported "Dart SDK version: $declared (stable)" || return 1
  rm -rf -- "$work/reused-sdk"
  mkdir "$work/reused-sdk"
  for part in bin lib include sdk_packages version revision LICENSE README; do
    if [[ -e "$sdk_root/$part" ]]; then cp -R -- "$sdk_root/$part" "$work/reused-sdk/"; fi
  done
  find "$work/reused-sdk" -type d -exec chmod 0755 {} +
  find "$work/reused-sdk" -type f -perm /111 -exec chmod 0755 {} +
  find "$work/reused-sdk" -type f ! -perm /111 -exec chmod 0644 {} +
  # Even a private SDK is executed only as the unprivileged build account.
  if sky_compatible_sdk "$work/reused-sdk/bin/dart"; then
    printf 'Reusing a private installed Dart SDK through a temporary copy.\n'
    return
  fi
  rm -rf -- "$work/reused-sdk"
  return 1
}
