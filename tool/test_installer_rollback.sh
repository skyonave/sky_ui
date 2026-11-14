#!/usr/bin/env bash
set -Eeuo pipefail
# Exercise the public offline installer, not extracted shell functions. All
# system paths and service commands live inside a private Linux mount namespace.
[[ "$(uname -s)" == Linux && $EUID == 0 ]] || { printf 'Run this isolated test as root on Linux.\n' >&2; exit 1; }
if [[ ${1:-} != --inside ]]; then
  exec unshare --mount --propagation private bash "$0" --inside
fi
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
stage="$(mktemp -d /var/tmp/sky-ui-installer-test.XXXXXXXX)"
guest="$stage/root"
cleanup() {
  for directory in /proc /lib64 /usr/lib /usr/sbin /usr/bin; do
    umount "$guest$directory" 2>/dev/null || true
  done
  case "$stage" in /var/tmp/sky-ui-installer-test.*) rm -rf -- "$stage" ;; esac
}
trap cleanup EXIT
mkdir -p "$guest"/{usr/bin,usr/sbin,usr/lib,usr/local/bin,proc,dev,fixture/bin}
for directory in /usr/bin /usr/sbin /usr/lib; do
  mount --bind "$directory" "$guest$directory"
  mount -o remount,bind,ro "$guest$directory"
done
ln -s usr/bin "$guest/bin"
ln -s usr/sbin "$guest/sbin"
ln -s usr/lib "$guest/lib"
if [[ -d /lib64 ]]; then
  mkdir "$guest/lib64"
  mount --bind /lib64 "$guest/lib64"
  mount -o remount,bind,ro "$guest/lib64"
fi
mount -t proc proc "$guest/proc"
mknod -m 0666 "$guest/dev/null" c 1 3
mknod -m 0666 "$guest/dev/urandom" c 1 9
cp "$root/install.sh" "$guest/fixture/install.sh"
payload="$stage/payload"
mkdir -p "$payload"/{bin,lib,web/fonts,licenses,compatibility}
cp -a "$root/deploy" "$payload/"
cp -a "$root/compatibility/cores" "$payload/compatibility/"
for file in LICENSE BUILD_MANIFEST.json licenses/dart-sdk.LICENSE licenses/caddy.LICENSE lib/libsqlite3.so lib/libsky_posix.so web/index.html web/main.dart.js web/styles.css web/fonts/PxPlus_IBM_VGA8.ttf web/fonts/LICENSE-IBM-VGA.txt web/fonts/ATTRIBUTION.txt; do
  printf 'Isolated installer fixture.\n' >"$payload/$file"
done
printf '2.0.0\n' >"$payload/VERSION"
printf '2.31\n' >"$payload/MIN_GLIBC"
printf 'native-v1\n' >"$payload/BUILD_MODE"
printf '%064d\n' 2 >"$payload/SOURCE_SHA256"
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) exit 1 ;; esac
printf '%s\n' "$arch" >"$payload/ARCH"
cat >"$payload/bin/sky-ui" <<'SH'
#!/bin/bash
printf 'Sky UI %s\n' "$(cat "${BASH_SOURCE[0]%/bin/*}/VERSION")"
SH
printf '#!/bin/bash\nexit 0\n' >"$payload/bin/sky-ops"
cp "$payload/bin/sky-ops" "$payload/bin/caddy"
cat >"$payload/deploy/prepare_host.sh" <<'SH'
#!/bin/bash
if ! getent passwd sky-ui >/dev/null; then
  printf 'sky-ui:x:1000:1000::/:/bin/false\nsky-ui-core:x:1001:1000::/:/bin/false\nsky-ui-edge:x:1002:1002::/:/bin/false\n' >>/etc/passwd
  printf 'sky-ui:x:1000:\nsky-ui-edge:x:1002:\n' >>/etc/group
fi
SH
printf 'sky_cache_put() { :; }\nsky_cache_clear() { :; }\n' >"$payload/deploy/download_cache.sh"
printf '#!/bin/bash\nprintf "fixture\\n" >"$1"\n' >"$payload/deploy/render_access.sh"
asset="sky-ui-linux-$arch.tar.gz"
tar -czf "$guest/fixture/$asset" -C "$payload" .
(cd "$guest/fixture" && sha256sum "$asset" >"$asset.sha256")
cat >"$guest/fixture/databases.py" <<'PY'
import hashlib, json, os, sqlite3, sys
from pathlib import Path

base = Path('/var/lib/sky-ui')
names = [n + s for n in ('panel.sqlite', 'owner.sqlite')
         for s in ('', '-wal', '-shm', '-journal')]
def manifest():
    return {n: [hashlib.sha256((base / n).read_bytes()).hexdigest(),
                (base / n).stat().st_mode, (base / n).stat().st_uid,
                (base / n).stat().st_gid]
            for n in names if (base / n).exists()}

operation, mode = sys.argv[1:]
if operation == 'seed':
    connections = []
    for name in ('panel', 'owner'):
        if mode == 'missing-owner' and name == 'owner':
            continue
        db = sqlite3.connect(base / (name + '.sqlite'))
        connections.append(db)
        if mode == 'wal':
            db.execute('PRAGMA journal_mode=WAL')
            db.execute('PRAGMA wal_autocheckpoint=0')
        db.execute('PRAGMA user_version=' + ('2' if name == 'panel' else '1'))
        db.execute('CREATE TABLE identity (name TEXT, value TEXT)')
        db.execute('INSERT INTO identity VALUES (?, ?)',
                   ('peer-key' if name == 'panel' else 'session', 'preserved-' + name))
        db.commit()
        if mode != 'wal':
            db.close()
    for name in names:
        path = base / name
        if path.exists():
            os.chmod(path, 0o600)
            os.chown(path, 1000, 1000)
    Path('/fixture/before.json').write_text(json.dumps(manifest()))
    os._exit(0)  # Keep real SQLite WAL/SHM from the last committed writer.
elif operation == 'migrate':
    connections = []
    for name in ('panel', 'owner'):
        db = sqlite3.connect(base / (name + '.sqlite'))
        connections.append(db)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA wal_autocheckpoint=0')
        db.execute('PRAGMA user_version=3')
        db.execute('CREATE TABLE failed_upgrade (value TEXT)')
        if name == 'panel' or mode != 'missing-owner':
            db.execute('UPDATE identity SET value="mutated-by-new-version"')
        db.commit()
    os._exit(0)
elif operation == 'verify':
    # Check bytes, sidecar absence and ownership before SQLite can checkpoint.
    assert manifest() == json.loads(Path('/fixture/before.json').read_text()), manifest()
    for name in ('panel', 'owner'):
        if mode == 'missing-owner' and name == 'owner':
            assert not (base / 'owner.sqlite').exists()
            continue
        db = sqlite3.connect(base / (name + '.sqlite'))
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert db.execute('PRAGMA user_version').fetchone()[0] == (2 if name == 'panel' else 1)
        assert db.execute('SELECT value FROM identity').fetchone()[0] == 'preserved-' + name
        assert not db.execute('SELECT name FROM sqlite_master WHERE name="failed_upgrade"').fetchall()
        db.close()
    Path('/fixture/verified').touch()
PY
cat >"$guest/fixture/bin/systemctl" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>/fixture/commands
if [[ "$1" == --version ]]; then printf 'systemd 252\n'; exit; fi
unit="${*: -1}"
version=none
if [[ -f /opt/sky-ui/current/VERSION ]]; then version="$(cat /opt/sky-ui/current/VERSION)"; fi
failure="$(cat /fixture/failure)"
mode="$(cat /fixture/mode)"
case "$1" in
  is-active) [[ -f "/fixture/$unit.active" ]] ;;
  show)
    if [[ "$*" == *LoadState* ]]; then
      if [[ -f /fixture/fresh && ! -f /etc/systemd/system/sky-ui.service ]]; then printf 'not-found\n'; exit 4; else printf 'loaded\n'; fi
    elif [[ "$*" == *MainPID* ]]; then
      if [[ -f /fixture/sky-ui.service.active ]]; then printf '123\n'; else printf '0\n'; fi
    else
      if [[ -f /fixture/sky-ui.service.active ]]; then printf 'active\n'; else printf 'inactive\n'; fi
    fi ;;
  stop)
    if [[ "$failure" == stop && "$version" == 2.0.0 && "$unit" == sky-ui.service ]]; then exit 1; fi
    rm -f "/fixture/$unit.active" ;;
  enable|start|restart)
    if [[ "$unit" == sky-ui.service && "$*" != 'enable sky-ui.service' ]]; then
      if [[ "$version" == 2.0.0 ]]; then
        if [[ -f /fixture/fresh ]]; then
          python3 /fixture/databases.py seed plain
        else
          python3 /fixture/databases.py migrate "$mode"
        fi
      else
        python3 /fixture/databases.py verify "$mode"
      fi
      touch "/fixture/$unit.active"
    elif [[ "$version" == 2.0.0 && "$unit" == sky-ui-edge.service && "$failure" == edge ]]; then
      exit 1
    elif [[ "$version" == 2.0.0 && "$unit" == sky-ui-certificates.service && "$failure" == certificates ]]; then
      exit 1
    fi ;;
esac
SH
cat >"$guest/fixture/bin/curl" <<'SH'
#!/bin/bash
if [[ "$(cat /fixture/failure)" =~ ^(health|stop|restore)$ ]]; then
  printf '{"version":"0.0.0"}\n'
else
  printf '{"version":"2.0.0"}\n'
fi
SH
cat >"$guest/fixture/bin/cp" <<'SH'
#!/bin/bash
if [[ "$(cat /fixture/failure)" == restore && "$*" == *'/databases/'* && "${*: -1}" == /var/lib/sky-ui/* ]]; then exit 1; fi
exec /usr/bin/cp "$@"
SH
printf '#!/bin/bash\nexit 0\n' >"$guest/fixture/bin/sleep"
chmod 0755 "$guest/fixture/bin/"*
run_guest() {
  chroot "$guest" /usr/bin/env PATH=/fixture/bin:/usr/local/bin:/usr/bin:/usr/sbin:/bin HOME=/root "$@"
}
for scenario in health:wal edge:plain certificates:missing-owner stop:wal restore:wal fresh:plain; do
  failure="${scenario%%:*}"
  mode="${scenario#*:}"
  # Only private guest state is reset between cases; shared host mounts are read-only.
  rm -rf -- "$guest/etc" "$guest/opt" "$guest/var" "$guest/run"
  rm -f -- "$guest/fixture/"*.active "$guest/fixture/verified" "$guest/fixture/fresh"
  mkdir -p "$guest"/{etc/sky-ui,etc/systemd/system,run/systemd/system,run/lock,var/tmp,var/lib/sky-ui,opt/sky-ui/releases/1.5.0-amd64}
  printf 'root:x:0:0:root:/root:/bin/bash\nsky-ui:x:1000:1000::/:/bin/false\nsky-ui-core:x:1001:1000::/:/bin/false\nsky-ui-edge:x:1002:1002::/:/bin/false\n' >"$guest/etc/passwd"
  printf 'root:x:0:\nsky-ui:x:1000:\nsky-ui-edge:x:1002:\n' >"$guest/etc/group"
  printf 'passwd: files\ngroup: files\n' >"$guest/etc/nsswitch.conf"
  cp -a /etc/alternatives "$guest/etc/"
  cp -a "$payload/." "$guest/opt/sky-ui/releases/1.5.0-amd64/"
  printf '1.5.0\n' >"$guest/opt/sky-ui/releases/1.5.0-amd64/VERSION"
  ln -s /opt/sky-ui/releases/1.5.0-amd64 "$guest/opt/sky-ui/current"
  touch "$guest/etc/sky-ui/managed-by-sky-ui" "$guest/fixture/sky-ui.service.active" "$guest/fixture/sky-ui-edge.service.active"
  printf 'SKY_UI_PORT=39241\nSKY_UI_CORE_BINARY=/unused\n' >"$guest/etc/sky-ui/server.env"
  printf '%064d\n' 1 >"$guest/etc/sky-ui/controller.secret"
  cp "$guest/etc/sky-ui/controller.secret" "$guest/etc/sky-ui/gateway.secret"
  printf '127.0.0.1\nexample.invalid\n' >"$guest/etc/sky-ui/access.conf"
  printf 'fixture\n' >"$guest/etc/sky-ui/admin.hash"
  printf 'old gateway\n' >"$guest/etc/sky-ui/Caddyfile"
  printf '%s\n' "$failure" >"$guest/fixture/failure"
  printf '%s\n' "$mode" >"$guest/fixture/mode"
  if [[ "$failure" == fresh ]]; then
    rm -rf -- "$guest/etc/sky-ui" "$guest/opt/sky-ui" "$guest/var/lib/sky-ui"
    rm -f -- "$guest/usr/local/bin/skyui" "$guest/usr/local/bin/sky-ui"
    sed -i '/^sky-ui/d' "$guest/etc/passwd" "$guest/etc/group"
    rm -f -- "$guest/fixture/"*.active
    touch "$guest/fixture/fresh"
    if ! run_guest bash /fixture/install.sh --bundle "/fixture/$asset" >"$stage/$failure.log" 2>&1; then
      cat "$stage/$failure.log" >&2; exit 1
    fi
    [[ -f "$guest/var/lib/sky-ui/panel.sqlite" && -f "$guest/var/lib/sky-ui/owner.sqlite" ]]
    [[ "$(readlink "$guest/opt/sky-ui/current")" == "/opt/sky-ui/releases/2.0.0-$arch" ]]
    printf 'PASS clean install with absent service and no databases.\n'
    continue
  fi
  run_guest python3 /fixture/databases.py seed "$mode"
  if run_guest bash /fixture/install.sh --bundle "/fixture/$asset" >"$stage/$failure.log" 2>&1; then
    cat "$stage/$failure.log" >&2
    printf 'Expected failed upgrade: %s\n' "$scenario" >&2; exit 1
  fi
  if [[ "$failure" == stop || "$failure" == restore ]]; then
    [[ ! -f "$guest/fixture/verified" ]]
    [[ "$(readlink "$guest/opt/sky-ui/current")" == "/opt/sky-ui/releases/2.0.0-$arch" ]]
    snapshot="$(find "$guest/var/tmp" -name databases -type d -print -quit)"
    [[ -n "$snapshot" && -s "$snapshot/panel.sqlite" && -s "$snapshot/owner.sqlite" ]]
    [[ "$(stat -c '%u:%g:%a' "$snapshot")" == 0:0:700 ]]
    grep -F 'Recovery files retained at' "$stage/$failure.log" >/dev/null || grep -F 'recovery files retained at' "$stage/$failure.log" >/dev/null
    if [[ "$failure" == restore ]]; then [[ ! -f "$guest/fixture/sky-ui.service.active" ]]; fi
    printf 'PASS rollback %s failure retains private snapshot and never starts the old panel.\n' "$failure"
    continue
  fi
  if [[ ! -f "$guest/fixture/verified" ]]; then cat "$stage/$failure.log" >&2; exit 1; fi
  grep -F 'Previous release and pre-upgrade databases restored.' "$stage/$failure.log" >/dev/null
  [[ "$(readlink "$guest/opt/sky-ui/current")" == /opt/sky-ui/releases/1.5.0-amd64 ]]
  [[ -f "$guest/fixture/sky-ui.service.active" && "$(cat "$guest/etc/sky-ui/Caddyfile")" == 'old gateway' ]]
  [[ -z "$(find "$guest/var/tmp" -mindepth 1 -print -quit)" ]]
  printf 'PASS installer rollback after %s failure (%s SQLite state).\n' "$failure" "$mode"
done
