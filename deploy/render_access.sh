#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $# == 6 || $# == 7 ]] || exit 1
output="$1"; ip_address="$2"; domain="$3"; port="$4"
previous_domain="${7:-}"
read -r admin_user admin_hash <"$5"
gateway_secret="$(cat "$6")"
[[ "$gateway_secret" =~ ^[a-f0-9]{64}$ ]] || exit 1
[[ "$ip_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$port" =~ ^[0-9]+$ ]] || exit 1
[[ -z "$domain" || "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || exit 1
[[ -z "$previous_domain" || "$previous_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || exit 1
[[ "$admin_user" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,31}$ && "$admin_hash" =~ ^\$2[aby]\$[0-9]{2}\$[./a-zA-Z0-9]{53}$ ]] || exit 1
cat >"$output" <<CADDY
{
    admin unix//run/sky-ui-edge/admin.sock
    default_sni $ip_address
    log default {
        format filter {
            wrap json
            fields {
                request>uri delete
            }
        }
    }
}
(sky_ui_protected) {
    reverse_proxy 127.0.0.1:$port {
        flush_interval -1
        header_up Host 127.0.0.1:$port
        header_up -Authorization
        header_up X-Sky-UI-Gateway $gateway_secret
        header_up X-Sky-UI-Client-IP {remote_host}
    }
}
https://$ip_address {
    tls {
        issuer acme {
            dir https://acme-v02.api.letsencrypt.org/directory
            profile shortlived
        }
    }
    import sky_ui_protected
}
CADDY
for name in "$domain" "$previous_domain"; do
  [[ -n "$name" ]] || continue
  cat >>"$output" <<CADDY
https://$name {
    tls {
        issuer acme {
            dir https://acme-v02.api.letsencrypt.org/directory
        }
    }
    import sky_ui_protected
}
CADDY
done
