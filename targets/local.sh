#!/usr/bin/env bash

prepare_target() {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r SSH_CLIENT_IP _ <<< "$SSH_CONNECTION"

        if [[ "$SSH_CLIENT_IP" == *:* ]]; then
            HOST_IPV6="$SSH_CLIENT_IP"
        else
            HOST_IPV4="$SSH_CLIENT_IP"
        fi
    elif [[ "$SSH_ALL" == "false" ]]; then
        read -r -p "SSH client IP (SSH_CONNECTION unavailable): " SSH_CLIENT_IP

        python3 - "$SSH_CLIENT_IP" <<'PY'
import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    print("Invalid IP address.")
    sys.exit(1)
PY

        if [[ "$SSH_CLIENT_IP" == *:* ]]; then
            HOST_IPV6="$SSH_CLIENT_IP"
        else
            HOST_IPV4="$SSH_CLIENT_IP"
        fi
    fi
}

run_target() {
    bash "$SCRIPT_DIR/modules/apply.sh" "${ARGS[@]}"
}