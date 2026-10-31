#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $# == 6 ]] || exit 1
output="$1"; ip_address="$2"; domain="$3"; port="$4"
read -r admin_user admin_hash <"$5"
gateway_secret="$(cat "$6")"
[[ "$gateway_secret" =~ ^[a-f0-9]{64}$ ]] || exit 1
[[ "$ip_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$port" =~ ^[0-9]+$ ]] || exit 1
[[ -z "$domain" || "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || exit 1
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
    @subscription {
        method GET HEAD
        path_regexp subscription ^/s/[A-Za-z0-9_-]{43}\\.yaml$
    }
    handle @subscription {
        reverse_proxy 127.0.0.1:$port {
            header_up Host 127.0.0.1:$port
            header_up -Authorization
            header_up X-Sky-UI-Gateway $gateway_secret
        }
    }
    handle {
        basic_auth {
            $admin_user $admin_hash
        }
        reverse_proxy 127.0.0.1:$port {
            header_up Host 127.0.0.1:$port
            header_up -Authorization
            header_up X-Sky-UI-Gateway $gateway_secret
        }
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
if [[ -n "$domain" ]]; then
  cat >>"$output" <<CADDY
https://$domain {
    tls {
        issuer acme {
            dir https://acme-v02.api.letsencrypt.org/directory
        }
    }
    import sky_ui_protected
}
CADDY
fi
