#!/usr/bin/env bash

install_ufw() {
    log "Installing UFW..."
    ensure_dependencies ufw

    echo "Resetting and configuring UFW..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    if [[ "$SSH_ALL" == "true" ]]; then
        ufw allow 22/tcp
    else
        # Fallback to current SSH client IP if no IPs are configured.
        if [[ -z "$HOST_IPV4" && -z "$HOST_IPV6" && ${#SSH_EXTRA_IPS[@]} -eq 0 ]]; then
            if [[ -n "${SSH_CONNECTION:-}" ]]; then
                read -r SSH_CLIENT_IP _ <<< "$SSH_CONNECTION"

                if [[ "$SSH_CLIENT_IP" == *:* ]]; then
                    HOST_IPV6="$SSH_CLIENT_IP"
                else
                    HOST_IPV4="$SSH_CLIENT_IP"
                fi
            fi
        fi

        [[ -n "$HOST_IPV4" ]] && ufw allow from "$HOST_IPV4" to any port 22 proto tcp
        [[ -n "$HOST_IPV6" ]] && ufw allow from "$HOST_IPV6" to any port 22 proto tcp

        for ip in "${SSH_EXTRA_IPS[@]}"; do
            ufw allow from "$ip" to any port 22 proto tcp
        done

        if [[ -z "$HOST_IPV4" && -z "$HOST_IPV6" && ${#SSH_EXTRA_IPS[@]} -eq 0 ]]; then
            die "ERROR: No SSH allow-list entries. Refusing to enable UFW."
        fi
    fi

    # HTTP / HTTPS and UDP transports
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    ufw allow 8443/udp

    # Panel and subscription ports are restricted to the controller/client IP.
    if [[ "$INSTALL_MODE" != "local" && "$XUI_SUBSCRIPTION" == "true" && "$NGINX_SUBSCRIPTION" == "false" ]]; then
        [[ -n "$HOST_IPV4" ]] && ufw allow from "$HOST_IPV4" to any port "$XUI_SUBSCRIPTION_PORT" proto tcp
        [[ -n "$HOST_IPV6" ]] && ufw allow from "$HOST_IPV6" to any port "$XUI_SUBSCRIPTION_PORT" proto tcp
    fi

    ufw --force enable
    ufw status verbose

    log "UFW installed and configured."
}
