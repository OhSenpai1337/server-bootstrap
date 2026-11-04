#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing configuration: $CONFIG_FILE"
    exit 1
fi

SSH_EXTRA_IPS=()
SSH_KEYS=()
CERT_DIR=""
SSH_ALL=""
source "$CONFIG_FILE"

: "${SSH_ALL:?SSH_ALL is not configured}"
[[ "$SSH_ALL" =~ ^(true|false)$ ]] || { echo "SSH_ALL must be true or false."; exit 1; }

if [[ "$CERT_DIR" != /* && -n "$CERT_DIR" ]]; then
    CERT_DIR="$SCRIPT_DIR/$CERT_DIR"
fi

for ip in "${SSH_EXTRA_IPS[@]}"; do
    python3 - "$ip" <<'PY'
import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    print(f"Invalid SSH_EXTRA_IP: {sys.argv[1]}")
    sys.exit(1)
PY
done

for key in "${SSH_KEYS[@]}"; do
    [[ "$key" == *" "* ]] || { echo "Invalid SSH public key entry: $key"; exit 1; }
done

echo "========================================"
echo "           SERVER BOOTSTRAP"
echo "========================================"
echo
echo "1. Local installation"
echo "2. Remote installation (SSH)"
echo "0. Exit"
read -r -p "Select installation target: " TARGET_MODE

case "$TARGET_MODE" in
    1) INSTALL_TARGET="local" ;;
    2) INSTALL_TARGET="remote" ;;
    0) exit 0 ;;
    *) echo "Invalid selection."; exit 1 ;;
esac

echo
echo "1. Full installation (UFW + Nginx)"
echo "2. UFW only"
echo "3. Nginx only"
echo "0. Back"
read -r -p "Select installation mode: " INSTALL_MODE

case "$INSTALL_MODE" in
    1) APPLY_MODE="full" ;;
    2) APPLY_MODE="ufw" ;;
    3) APPLY_MODE="nginx" ;;
    0) exit 0 ;;
    *) echo "Invalid selection."; exit 1 ;;
esac

SUBSCRIPTION="false"
DOMAIN=""
CERT_SOURCE_FULLCHAIN=""
CERT_SOURCE_KEY=""

CERT_METHOD="existing"
CERTBOT_EMAIL=""

if [[ "$APPLY_MODE" == "nginx" || "$APPLY_MODE" == "full" ]]; then
    echo
    echo "Nginx configuration:"
    echo "1. Without subscription"
    echo "2. With subscription"
    read -r -p "Select configuration: " SUB_MODE
    case "$SUB_MODE" in
        1) SUBSCRIPTION="false" ;;
        2) SUBSCRIPTION="true" ;;
        *) echo "Invalid selection."; exit 1 ;;
    esac

    read -r -p "Domain: " DOMAIN
    DOMAIN="${DOMAIN,,}"
    if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
        echo "Invalid domain: $DOMAIN"
        exit 1
    fi

    if [[ "$INSTALL_TARGET" == "local" ]]; then
        echo
        echo "Certificate configuration:"
        echo "1. Existing certificates"
        echo "2. Let's Encrypt (Certbot)"
        read -r -p "Select certificate method: " CERT_CHOICE

        case "$CERT_CHOICE" in
            1)
                CERT_METHOD="existing"
                read -r -p "Fullchain certificate path: " CERT_SOURCE_FULLCHAIN
                read -r -p "Private key path: " CERT_SOURCE_KEY

                [[ -s "$CERT_SOURCE_FULLCHAIN" ]] || { echo "Certificate not found."; exit 1; }
                [[ -s "$CERT_SOURCE_KEY" ]] || { echo "Private key not found."; exit 1; }
                ;;
            2)
                CERT_METHOD="certbot"
                read -r -p "Let's Encrypt email: " CERTBOT_EMAIL

                [[ "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || {
                    echo "Invalid email address."
                    exit 1
                }
                ;;
            *)
                echo "Invalid selection."
                exit 1
                ;;
        esac
    else
        CERT_METHOD="existing"
        CERT_SOURCE_FULLCHAIN="$CERT_DIR/fullchain.pem"
        CERT_SOURCE_KEY="$CERT_DIR/privkey.pem"

        [[ -s "$CERT_SOURCE_FULLCHAIN" ]] || { echo "Certificate not found: $CERT_SOURCE_FULLCHAIN"; exit 1; }
        [[ -s "$CERT_SOURCE_KEY" ]] || { echo "Private key not found: $CERT_SOURCE_KEY"; exit 1; }
    fi
fi

if [[ "$APPLY_MODE" == "nginx" ]]; then
    echo
    echo "WARNING: Nginx will be installed WITHOUT configuring UFW."
    echo "The server may be exposed to unauthorized access."
    read -r -p "Are you sure you want to continue? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
fi

HOST_IPV4=""
HOST_IPV6=""
SSH_CLIENT_IP=""

if [[ "$INSTALL_TARGET" == "local" ]]; then
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
        if [[ "$SSH_CLIENT_IP" == *:* ]]; then HOST_IPV6="$SSH_CLIENT_IP"; else HOST_IPV4="$SSH_CLIENT_IP"; fi
    fi
else
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
    [[ "$SSH_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]] || { echo "Invalid SSH username."; exit 1; }

    HOST_IPV4="$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}' | python3 -c 'import sys,ipaddress; [print(x) for x in sys.stdin if (lambda a: a.is_global)(ipaddress.ip_address(x.strip()))]' | head -n1)"
    HOST_IPV6="$(ip -6 -o addr show scope global | awk '!/temporary|deprecated|tentative|dadfailed/ {split($4,a,"/"); print a[1]}' | python3 -c 'import sys,ipaddress; [print(x) for x in sys.stdin if (lambda a: a.version == 6 and a.is_global)(ipaddress.ip_address(x.strip()))]' | head -n1)"

    if [[ "$SSH_ALL" == "false" && -z "$HOST_IPV4" && -z "$HOST_IPV6" && ${#SSH_EXTRA_IPS[@]} -eq 0 ]]; then
        echo "ERROR: No SSH allowed IP addresses configured."
        exit 1
    fi
fi

if [[ "$INSTALL_TARGET" == "local" ]]; then
    [[ $EUID -eq 0 ]] || { echo "Run local installation as root: sudo bash setup.sh"; exit 1; }
fi

echo
echo "----------------------------------------"
echo "Target:       $INSTALL_TARGET"
[[ "$INSTALL_TARGET" == "remote" ]] && echo "Server:       $TARGET_IP"
echo "Mode:         $APPLY_MODE"
[[ -n "$DOMAIN" ]] && echo "Domain:       $DOMAIN"
echo "SSH_ALL:      $SSH_ALL"
echo "----------------------------------------"
read -r -p "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

ARGS=("$INSTALL_TARGET" "$APPLY_MODE" "$SUBSCRIPTION" "$DOMAIN" "$CERT_METHOD" "$CERTBOT_EMAIL" "$HOST_IPV4" "$HOST_IPV6" "$SSH_ALL")
ARGS+=("${#SSH_EXTRA_IPS[@]}")
ARGS+=("${SSH_EXTRA_IPS[@]}")
ARGS+=("${#SSH_KEYS[@]}")
ARGS+=("${SSH_KEYS[@]}")

if [[ "$INSTALL_TARGET" == "local" ]]; then
    bash "$SCRIPT_DIR/modules/apply.sh" "${ARGS[@]}" "$CERT_SOURCE_FULLCHAIN" "$CERT_SOURCE_KEY"
    exit $?
fi

for cmd in ssh sshpass scp tar; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd (apt install $cmd)"; exit 1; }
done

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

sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" "echo SSH connection successful"
REMOTE_DIR="$(sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" 'mktemp -d /tmp/server-bootstrap.XXXXXX')"

tar -czf "$LOCAL_TMP/modules.tar.gz" -C "$SCRIPT_DIR" modules templates
sshpass -e scp "${SSH_OPTS[@]}" "$LOCAL_TMP/modules.tar.gz" "$SCP_DEST:$REMOTE_DIR/"
if [[ "$APPLY_MODE" == "nginx" || "$APPLY_MODE" == "full" ]]; then
    sshpass -e scp "${SSH_OPTS[@]}" "$CERT_SOURCE_FULLCHAIN" "$SCP_DEST:$REMOTE_DIR/fullchain.pem"
    sshpass -e scp "${SSH_OPTS[@]}" "$CERT_SOURCE_KEY" "$SCP_DEST:$REMOTE_DIR/privkey.pem"
fi

REMOTE_ARGS=("${ARGS[@]}")
for arg in "${REMOTE_ARGS[@]}"; do printf -v q '%q' "$arg"; REMOTE_ARGS_ESCAPED+=" $q"; done
REMOTE_COMMAND="mkdir -p '$REMOTE_DIR/package' && tar -xzf '$REMOTE_DIR/modules.tar.gz' -C '$REMOTE_DIR/package' && bash '$REMOTE_DIR/package/modules/apply.sh'$REMOTE_ARGS_ESCAPED"
if [[ "$APPLY_MODE" == "nginx" || "$APPLY_MODE" == "full" ]]; then
    REMOTE_COMMAND+=" '$REMOTE_DIR/fullchain.pem' '$REMOTE_DIR/privkey.pem'"
else
    REMOTE_COMMAND+=" '' ''"
fi

if sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" "id -u | grep -qx 0"; then
    sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" "$REMOTE_COMMAND"
else
    printf '%s\n' "$SSHPASS" | sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" "sudo -S -p '' bash -c $(printf '%q' "$REMOTE_COMMAND")"
fi

echo
echo "========================================"
echo " BOOTSTRAP COMPLETED"
echo " Server: $TARGET_IP"
[[ -n "$DOMAIN" ]] && echo " Domain: $DOMAIN"
echo "========================================"
