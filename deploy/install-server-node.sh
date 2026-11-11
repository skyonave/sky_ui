#!/bin/bash
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

account=sky-ui-node
state=/var/lib/sky-ui-node
program=/usr/local/libexec/sky-ui-node
unit=sky-ui-node-mihomo.service

if (( EUID != 0 || $# != 2 )); then
  echo 'Usage: sudo bash install-server-node.sh /path/to/mihomo /path/to/panel.pub' >&2
  exit 2
fi
for tool in sudo visudo ssh-keygen flock systemctl runuser ss timeout sha256sum; do
  command -v "$tool" >/dev/null
done
exec 9>/run/lock/sky-ui-node.lock
flock -w 15 9
test -x "$1"
ssh-keygen -lf "$2" >/dev/null
read -r key_type key_blob _ < "$2" || [[ -n "$key_blob" ]]
if [[ "$key_type" != ssh-ed25519 || ! "$key_blob" =~ ^AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}$ ]]; then
  echo 'Expected a Sky UI Ed25519 enrollment key.' >&2
  exit 2
fi

if ! getent passwd "$account" >/dev/null; then
  useradd --system --user-group --home-dir "$state" --shell /bin/sh "$account"
fi
if [[ "$(getent passwd "$account" | cut -d: -f6-7)" != "$state:/bin/sh" ]]; then
  echo 'Existing sky-ui-node account has unexpected settings.' >&2
  exit 1
fi
if ! getent passwd sky-ui-relay >/dev/null; then
  useradd --system --user-group --home-dir "$state/runtime" --shell /usr/sbin/nologin sky-ui-relay
fi

install -d -o root -g root -m 0755 "$program" "$state" "$state/.ssh"
install -d -o sky-ui-relay -g sky-ui-relay -m 0750 "$state/runtime"
if [[ ! -e "$state/config.json" ]]; then
  printf '%s\n' '{"mode":"rule","log-level":"info","listeners":[]}' > "$state/config.json"
  chgrp sky-ui-relay "$state/config.json"
  chmod 0640 "$state/config.json"
fi

candidate=$(mktemp "$program/.mihomo.XXXXXX")
sudoers=
key_file=
trap 'rm -f -- "$candidate" "${sudoers:-$candidate}" "${key_file:-$candidate}"' EXIT
install -o root -g root -m 0755 "$1" "$candidate"
runuser -u sky-ui-relay -- "$candidate" -t -d "$state/runtime" -f "$state/config.json"
mv -fT "$candidate" "$program/mihomo"

cat > "$program/dispatch" <<'SH'
#!/bin/sh
set -eu
case "${SSH_ORIGINAL_COMMAND:-}" in
  status|start|stop|restart|logs|inspect|validate|deploy|rollback|probe)
    exec /usr/bin/sudo -n /usr/local/libexec/sky-ui-node/control "$SSH_ORIGINAL_COMMAND"
    ;;
  *) exit 2 ;;
esac
SH
cat > "$program/control" <<'SH'
#!/bin/bash
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
unit=sky-ui-node-mihomo.service
state=/var/lib/sky-ui-node
program=/usr/local/libexec/sky-ui-node
config="$state/config.json"
undo="$state/undo"
aborted="$state/aborted"
test "$#" -eq 1

locked() {
  exec 9>/run/lock/sky-ui-node.lock
  flock -w 15 9
}
digest() {
  sha256sum "$1" | cut -d' ' -f1
}
active() {
  systemctl show -p ActiveState --value "$unit"
}
validate_candidate() {
  chgrp sky-ui-relay "$1"
  chmod 0640 "$1"
  timeout 15 runuser -u sky-ui-relay -- "$program/mihomo" \
    -t -d "$state/runtime" -f "$1" >/dev/null 2>&1
}
receive_candidate() {
  # Read a bounded document after the fixed-size protocol headers.
  timeout 15 head -c 524289 > "$1"
  test "$(wc -c < "$1")" -le 524288
  validate_candidate "$1"
}
replace_config() {
  chgrp sky-ui-relay "$1"
  chmod 0640 "$1"
  sync -f "$1"
  mv -fT "$1" "$config"
  sync -f "$state"
}
restore() {
  [[ -f "$undo/transaction" && "$(cat "$undo/transaction")" == "$tx" ]] || return 0
  cp -- "$undo/config.json" "$candidate"
  replace_config "$candidate"
  if [[ "$(cat "$undo/running")" == active ]]; then
    timeout 18 systemctl restart "$unit" >/dev/null
  else
    timeout 18 systemctl stop "$unit" >/dev/null
  fi
  if [[ "$(cat "$undo/enabled")" == enabled ]]; then
    systemctl enable "$unit" >/dev/null 2>&1
  else
    systemctl disable "$unit" >/dev/null 2>&1
  fi
  rm -f -- "$undo/"{transaction,config.json,running,enabled}
  rmdir -- "$undo"
}

case "$1" in
  status) ;;
  start|stop|restart)
    locked
    case "$1" in
      start)
        systemctl start "$unit" >/dev/null
        systemctl enable "$unit" >/dev/null 2>&1
        ;;
      stop)
        systemctl disable --now "$unit" >/dev/null 2>&1
        ;;
      restart)
        systemctl restart "$unit" >/dev/null
        systemctl enable "$unit" >/dev/null 2>&1
        ;;
    esac
    ;;
  logs)
    exec journalctl --unit "$unit" --lines 30 --output short-iso --no-pager
    ;;
  inspect)
    locked
    printf '%s %s 2\n' "$(digest "$config")" "$(active)"
    exit 0
    ;;
  probe)
    IFS= read -r -t 10 -n 46 host
    IFS= read -r -t 10 -n 6 port
    [[ "$host" =~ ^[a-fA-F0-9:.]{2,45}$ && "$port" =~ ^[45][0-9]{4}$ ]]
    timeout 5 runuser -u sky-ui-relay -- /bin/bash -c 'exec 8<>"/dev/tcp/$1/$2"' bash "$host" "$port"
    exit 0
    ;;
  validate|deploy|rollback)
    locked
    candidate=$(mktemp "$state/.candidate.XXXXXX")
    trap 'rm -f -- "$candidate"' EXIT
    if [[ "$1" == validate ]]; then
      receive_candidate "$candidate"
      exit 0
    fi
    IFS= read -r -t 10 -n 26 tx
    [[ "$tx" =~ ^tx_[a-zA-Z0-9_-]{22}$ ]]
    if [[ "$1" == rollback ]]; then
      printf '%s\n' "$tx" > "$aborted"
      sync -f "$aborted"
      restore
      exit 0
    fi
    if [[ -f "$aborted" && "$(cat "$aborted")" == "$tx" ]]; then exit 1; fi
    IFS= read -r -t 10 -n 65 previous
    [[ "$previous" =~ ^[0-9a-f]{64}$ && "$(digest "$config")" == "$previous" ]]
    IFS= read -r -t 10 -n 8192 ports
    IFS= read -r -t 10 -n 8192 udp_ports
    for list in "$ports" "$udp_ports"; do
      [[ -z "$list" || "$list" =~ ^[1-9][0-9]{3,4}(\ [1-9][0-9]{3,4})*$ ]]
      for port in $list; do
        (( port >= 1024 && port <= 65535 ))
      done
    done
    receive_candidate "$candidate"
    if [[ -d "$undo" ]]; then
      rm -f -- "$undo/"{transaction,config.json,running,enabled}
      rmdir -- "$undo"
    fi
    mkdir -m 0700 -- "$undo"
    cp -- "$config" "$undo/config.json"
    active > "$undo/running"
    (systemctl is-enabled "$unit" 2>/dev/null || true) > "$undo/enabled"
    printf '%s\n' "$tx" > "$undo/transaction"
    sync -f "$state"
    replace_config "$candidate"
    if [[ -n "$ports$udp_ports" || "$(cat "$undo/running")" == active ]]; then
      timeout 18 systemctl restart "$unit" >/dev/null
      verify_ports() {
        local flag=$1 port ready attempt pid
        shift
        for port in "$@"; do
          ready=false
          for attempt in {1..10}; do
            pid=$(systemctl show -p MainPID --value "$unit")
            if [[ "$pid" != 0 ]] && ss "-Hlnp$flag" "sport = :$port" | grep -Fq "pid=$pid,"; then
              ready=true
              break
            fi
            sleep 0.15
          done
          "$ready"
        done
      }
      verify_ports t $ports
      verify_ports u $udp_ports
      if [[ -n "$ports$udp_ports" ]]; then systemctl enable "$unit" >/dev/null 2>&1; fi
    fi
    exit 0
    ;;
  *) exit 2 ;;
esac
test "$(systemctl show -p LoadState --value "$unit")" = loaded
exec systemctl show -p ActiveState --value "$unit"
SH
chmod 0755 "$program/dispatch" "$program/control"

sudoers=$(mktemp /etc/sudoers.d/.sky-ui-node.XXXXXX)
for verb in status start stop restart logs inspect validate deploy rollback probe; do
  printf '%s ALL=(root) NOPASSWD: %s/control %s\n' "$account" "$program" "$verb"
done > "$sudoers"
visudo -cf "$sudoers" >/dev/null
chmod 0440 "$sudoers"
mv -fT "$sudoers" /etc/sudoers.d/sky-ui-node

cat > "/etc/systemd/system/$unit" <<'UNIT'
[Unit]
Description=Sky UI headless Mihomo
After=network.target

[Service]
User=sky-ui-relay
Group=sky-ui-relay
WorkingDirectory=/var/lib/sky-ui-node/runtime
ExecStartPre=/usr/local/libexec/sky-ui-node/mihomo -t -d /var/lib/sky-ui-node/runtime -f /var/lib/sky-ui-node/config.json
ExecStart=/usr/local/libexec/sky-ui-node/mihomo -d /var/lib/sky-ui-node/runtime -f /var/lib/sky-ui-node/config.json
Restart=on-failure
RestartSec=3
TimeoutStopSec=10
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/sky-ui-node/runtime
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "/etc/systemd/system/$unit"
systemctl daemon-reload

key_file=$(mktemp "$state/.ssh/.authorized.XXXXXX")
printf 'restrict,command="%s/dispatch" %s %s sky-ui-node\n' "$program" "$key_type" "$key_blob" > "$key_file"
chmod 0644 "$key_file"
mv -fT "$key_file" "$state/.ssh/authorized_keys"
printf '%s\n' 'Sky UI node installed. Check the connection in the panel.'
