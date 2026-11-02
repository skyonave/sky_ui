#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
fail() { printf 'Sky UI: %s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || fail 'Запустите sudo skyui setup.'
[[ -f /etc/sky-ui/managed-by-sky-ui ]] || fail 'Сначала установите Sky UI.'
case "${1:-setup}" in setup|status) mode="${1:-setup}" ;; *) fail 'Использование: skyui setup или skyui status' ;; esac
caddy=/opt/sky-ui/current/bin/caddy
port="$(sed -n 's/^SKY_UI_PORT=//p' /etc/sky-ui/server.env)"
[[ "$port" =~ ^[0-9]+$ ]] || fail 'Некорректный порт API.'
ip_address=
domain=
if [[ -f /etc/sky-ui/access.conf ]]; then
  ip_address="$(sed -n '1p' /etc/sky-ui/access.conf)"
  domain="$(sed -n '2p' /etc/sky-ui/access.conf)"
fi
if [[ "$mode" == status ]]; then
  systemctl is-active sky-ui.service sky-ui-edge.service sky-ui-mihomo.service || true
  [[ -z "$ip_address" ]] || printf 'IP: https://%s\n' "$ip_address"
  [[ -z "$domain" ]] || printf 'Домен: https://%s\n' "$domain"
  exit 0
fi
exec 9>/run/lock/sky-ui-install.lock
flock -n 9 || fail 'Установка или настройка уже выполняется.'
exec 3<>/dev/tty
temp="$(mktemp -d /etc/sky-ui/.setup.XXXXXXXX)"
trap 'rm -rf -- "$temp"' EXIT
for name in server.env Caddyfile access.conf admin.hash owner.seed; do
  if [[ -f "/etc/sky-ui/$name" ]]; then cp "/etc/sky-ui/$name" "$temp/old-$name"; fi
done
edge_was_running=0
if systemctl is-active --quiet sky-ui-edge.service; then edge_was_running=1; fi
changed=0
owner_dir="$(sed -n 's/^SKY_UI_DATA_DIR=//p' /etc/sky-ui/server.env)"
[[ "$owner_dir" == /* && "$owner_dir" != / ]] || fail 'Некорректная папка данных.'
owner_db="$owner_dir/owner.sqlite"
if [[ -f "$owner_db" ]]; then
  /opt/sky-ui/current/bin/sky-ops database-copy "$owner_db" "$temp/old-owner.sqlite"
fi
rollback() {
  trap - ERR
  set +e
  if (( changed )); then
    systemctl stop sky-ui.service
    rm -f -- "$owner_db" "$owner_db-wal" "$owner_db-shm"
    if [[ -f "$temp/old-owner.sqlite" ]]; then install -m 0600 -o sky-ui -g sky-ui "$temp/old-owner.sqlite" "$owner_db"; fi
    for name in server.env Caddyfile access.conf admin.hash owner.seed; do
      if [[ -f "$temp/old-$name" ]]; then cp "$temp/old-$name" "/etc/sky-ui/$name"; else rm -f -- "/etc/sky-ui/$name"; fi
    done
    chown root:sky-ui /etc/sky-ui/server.env
    chmod 0640 /etc/sky-ui/server.env
    if [[ -f /etc/sky-ui/owner.seed ]]; then chown sky-ui:sky-ui /etc/sky-ui/owner.seed; chmod 0600 /etc/sky-ui/owner.seed; fi
    if [[ -f /etc/sky-ui/Caddyfile ]]; then chown root:sky-ui-edge /etc/sky-ui/Caddyfile; chmod 0640 /etc/sky-ui/Caddyfile; fi
    systemctl restart sky-ui.service
    if (( edge_was_running )); then systemctl reload-or-restart sky-ui-edge.service; else systemctl disable --now sky-ui-edge.service; fi
    printf 'Не удалось применить настройку. Предыдущие параметры восстановлены.\n' >&2
  fi
  exit 1
}
trap rollback ERR
valid_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local octet
  local -a octets
  IFS=. read -ra octets <<<"$1"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
    [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
  done
}
valid_domain() {
  [[ ${#1} -le 253 && "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}
create_admin() {
  local username password repeated hash generated=0
  printf '\nУчётная запись владельца\n' >&3
  read -rp 'Логин [admin]: ' username <&3
  username="${username:-admin}"
  [[ "$username" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,31}$ ]] || fail 'Используйте буквы, цифры, точку, дефис или подчёркивание в логине.'
  read -rsp 'Пароль (Enter — сгенерировать): ' password <&3
  printf '\n' >&3
  if [[ -z "$password" ]]; then password="$(openssl rand -hex 18)"; generated=1
  else
    (( ${#password} >= 12 && $(printf '%s' "$password" | wc -c) <= 72 )) || fail 'Пароль: от 12 символов, не более 72 bytes в UTF-8.'
    read -rsp 'Повторите пароль: ' repeated <&3
    printf '\n' >&3
    [[ "$password" == "$repeated" ]] || fail 'Пароли не совпадают.'
  fi
  hash="$(printf '%s\n' "$password" | "$caddy" hash-password --algorithm bcrypt --bcrypt-cost 12)"
  printf '%s %s\n' "$username" "$hash" >"$temp/admin.hash"
  if (( generated )); then printf 'Логин: %s\nПароль: %s\nСохраните пароль: он показывается один раз.\n' "$username" "$password" >&3; fi
  unset password repeated hash
}
choose_address() {
  local choice detected entered
  printf '\nДоступ к панели\n1) По IP (по умолчанию)\n2) По домену и IP\n' >&3
  read -rp 'Вариант [1]: ' choice <&3
  case "${choice:-1}" in
    1) domain= ;;
    2) read -rp 'Домен: ' domain <&3
       domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
       valid_domain "$domain" || fail 'Введите домен без протокола, порта и пути.'
       getent ahosts "$domain" >/dev/null || fail 'Домен не найден в DNS. Сначала настройте A/AAAA-записи.' ;;
    *) fail 'Выберите 1 или 2.' ;;
  esac
  detected="$ip_address"
  if [[ -z "$detected" ]]; then detected="$(ip -4 -o addr show scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"; fi
  read -rp "IP сервера [$detected]: " entered <&3
  ip_address="${entered:-$detected}"
  valid_ip "$ip_address" || fail 'Введите корректный IPv4-адрес сервера.'
}
if [[ ! -f /etc/sky-ui/admin.hash ]]; then create_admin; choose_address
else
  printf '\nSky UI\n1) Настроить IP / домен\n2) Изменить учётную запись владельца\n0) Выход\n' >&3
  read -rp 'Действие [1]: ' choice <&3
  case "${choice:-1}" in
    1) choose_address ;;
    2) create_admin; if [[ -z "$ip_address" ]]; then choose_address; fi ;;
    0) exit 0 ;;
    *) fail 'Выберите 0, 1 или 2.' ;;
  esac
fi
if [[ ! -f "$temp/admin.hash" ]]; then cp /etc/sky-ui/admin.hash "$temp/admin.hash"; fi
read -r admin_user admin_hash <"$temp/admin.hash"
[[ "$admin_user" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,31}$ && "$admin_hash" =~ ^\$2[aby]\$ ]] || fail 'Некорректная учётная запись.'
if (( ! edge_was_running )) && [[ -n "$(ss -H -lnt '( sport = :80 or sport = :443 )')" ]]; then fail 'Порты 80/443 заняты другой службой. Освободите их перед настройкой HTTPS.'; fi
bash "$(dirname -- "$0")/render_access.sh" "$temp/Caddyfile" "$ip_address" "$domain" "$port" "$temp/admin.hash" /etc/sky-ui/gateway.secret
unset admin_hash
"$caddy" fmt --overwrite "$temp/Caddyfile"
"$caddy" validate --config "$temp/Caddyfile" --adapter caddyfile
primary="$ip_address"
extra=
if [[ -n "$domain" ]]; then primary="$domain"; extra="https://$ip_address"; fi
awk '!/^SKY_UI_WEB_ORIGIN=/ && !/^SKY_UI_EXTRA_ORIGIN=/' /etc/sky-ui/server.env >"$temp/server.env"
printf 'SKY_UI_WEB_ORIGIN=https://%s\nSKY_UI_EXTRA_ORIGIN=%s\n' "$primary" "$extra" >>"$temp/server.env"
changed=1
install -m 0600 "$temp/admin.hash" /etc/sky-ui/admin.hash
install -m 0600 -o sky-ui -g sky-ui "$temp/admin.hash" /etc/sky-ui/owner.seed
install -m 0640 -o root -g sky-ui-edge "$temp/Caddyfile" /etc/sky-ui/Caddyfile
install -m 0640 -o root -g sky-ui "$temp/server.env" /etc/sky-ui/server.env
printf '%s\n%s\n' "$ip_address" "$domain" >/etc/sky-ui/access.conf
systemctl restart sky-ui.service
systemctl enable sky-ui-edge.service
systemctl reload-or-restart sky-ui-edge.service
printf 'Ожидаю HTTPS и сертификаты Let’s Encrypt…\n' >&3
for host in "$ip_address" "$domain"; do
  [[ -n "$host" ]] || continue
  ready=0
  for attempt in $(seq 1 45); do
    code="$(curl --noproxy '*' --silent --connect-timeout 2 --max-time 4 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/api/v1/panel" 2>/dev/null || true)"
    if [[ "$code" == 401 ]]; then ready=1; break; fi
    sleep 2
  done
  if (( ! ready )); then printf 'HTTPS для %s не готов. Проверьте DNS и доступность портов 80/443.\n' "$host" >&2; false; fi
done
changed=0
printf 'Готово: https://%s\nПовторная настройка: sudo skyui setup\n' "$primary" >&3
systemctl start sky-ui-certificates.service
