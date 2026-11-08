#!/usr/bin/env bash

prepare_target() {
    echo
    read -r -p "Target IP: " TARGET_IP
    read -r -p "SSH user: " SSH_USER
    read -r -s -p "SSH password: " SSH_PASSWORD
    echo

    python3 - "$TARGET_IP" <<'PY'
import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    print("Invalid target IP address.")
    sys.exit(1)
PY

    [[ "$SSH_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]] || die "Invalid SSH username."

    HOST_IPV4="$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}' | python3 -c 'import sys,ipaddress; [print(x) for x in sys.stdin if (lambda a: a.is_global)(ipaddress.ip_address(x.strip()))]' | head -n1)"

    HOST_IPV6="$(ip -6 -o addr show scope global | awk '!/temporary|deprecated|tentative|dadfailed/ {split($4,a,"/"); print a[1]}' | python3 -c 'import sys,ipaddress; [print(x) for x in sys.stdin if (lambda a: a.version == 6 and a.is_global)(ipaddress.ip_address(x.strip()))]' | head -n1)"

    if [[ "$SSH_ALL" == "false" && -z "$HOST_IPV4" && -z "$HOST_IPV6" && ${#SSH_EXTRA_IPS[@]} -eq 0 ]]; then
        die "No SSH allowed IP addresses configured."
    fi
}

run_target() {
    ensure_dependencies openssh-client sshpass

    SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new)
    SSH_DEST="${SSH_USER}@${TARGET_IP}"
    SCP_DEST="$SSH_DEST"
    [[ "$TARGET_IP" == *:* ]] && SCP_DEST="${SSH_USER}@[$TARGET_IP]"

    export SSHPASS="$SSH_PASSWORD"
    unset SSH_PASSWORD

    REMOTE_DIR=""
    LOCAL_TMP="$(mktemp -d)"

    cleanup() {
        if [[ -n "$REMOTE_DIR" ]]; then
            sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" "rm -rf -- '$REMOTE_DIR'" >/dev/null 2>&1 || true
        fi

        rm -rf "$LOCAL_TMP"
        unset SSHPASS
    }

    trap cleanup EXIT

    check_ssh_connection

    REMOTE_DIR="$(sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" 'mktemp -d /tmp/server-bootstrap.XXXXXX')"

    tar -czf "$LOCAL_TMP/modules.tar.gz" -C "$SCRIPT_DIR" config.conf modules templates scripts

    sshpass -e scp "${SSH_OPTS[@]}" "$LOCAL_TMP/modules.tar.gz" "$SCP_DEST:$REMOTE_DIR/"

    if [[ "$CERT_IS_WILDCARD" == "true" ]]; then
        sshpass -e scp "${SSH_OPTS[@]}" "$CERT_SOURCE_FULLCHAIN" "$SCP_DEST:$REMOTE_DIR/fullchain.pem"
        sshpass -e scp "${SSH_OPTS[@]}" "$CERT_SOURCE_KEY" "$SCP_DEST:$REMOTE_DIR/privkey.pem"
    fi

    REMOTE_ARGS_ESCAPED=""

    for arg in "${ARGS[@]}"; do
        printf -v q '%q' "$arg"
        REMOTE_ARGS_ESCAPED+=" $q"
    done

    REMOTE_COMMAND="mkdir -p '$REMOTE_DIR/package' && tar -xzf '$REMOTE_DIR/modules.tar.gz' -C '$REMOTE_DIR/package' && bash '$REMOTE_DIR/package/modules/apply.sh'$REMOTE_ARGS_ESCAPED"

    if sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" "id -u | grep -qx 0"; then
        sshpass -e ssh -tt "${SSH_OPTS[@]}" "$SSH_DEST" "$REMOTE_COMMAND"
    else
        sshpass -e ssh -tt "${SSH_OPTS[@]}" "$SSH_DEST" \
            "sudo -S -p '' bash -c $(printf '%q' "$REMOTE_COMMAND")"
    fi

    echo
    echo "========================================"
    echo " BOOTSTRAP COMPLETED"
    echo " Server: $TARGET_IP"
    [[ -n "$DOMAIN" ]] && echo " Domain: $DOMAIN"
    echo "========================================"
}