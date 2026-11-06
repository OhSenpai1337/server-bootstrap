#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"
source "$SCRIPT_DIR/modules/common.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    cp "$SCRIPT_DIR/config.conf.example" "$CONFIG_FILE"
    echo "Created config.conf from config.conf.example."
    echo "Please edit the configuration before continuing."
    exit 0
fi

# ========================================
# PRECHECKS
# ========================================

[[ "$EUID" -eq 0 ]] || die "Run this script as root."

[[ -f /etc/os-release ]] || die "Cannot determine operating system."
source /etc/os-release

[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] ||
    die "Only Ubuntu and Debian are supported."

SSH_EXTRA_IPS=()
SSH_KEYS=()
SSL_FULLCHAIN=""
SSL_PRIVKEY=""
SSH_ALL=""
source "$CONFIG_FILE"

: "${SSH_ALL:?SSH_ALL is not configured}"
[[ "$SSH_ALL" =~ ^(true|false)$ ]] || { echo "SSH_ALL must be true or false."; exit 1; }

if [[ -n "$SSL_FULLCHAIN" && -n "$SSL_PRIVKEY" ]]; then
    [[ "$SSL_FULLCHAIN" == /* ]] || SSL_FULLCHAIN="$SCRIPT_DIR/$SSL_FULLCHAIN"
    [[ "$SSL_PRIVKEY" == /* ]] || SSL_PRIVKEY="$SCRIPT_DIR/$SSL_PRIVKEY"

    [[ -s "$SSL_FULLCHAIN" ]] || { echo "Certificate not found: $SSL_FULLCHAIN"; exit 1; }
    [[ -s "$SSL_PRIVKEY" ]] || { echo "Private key not found: $SSL_PRIVKEY"; exit 1; }
elif [[ -n "$SSL_FULLCHAIN" || -n "$SSL_PRIVKEY" ]]; then
    echo "ERROR: SSL_FULLCHAIN and SSL_PRIVKEY must both be configured."
    exit 1
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
    *) log "Invalid selection."; exit 1 ;;
esac

APPLY_MODE="full"

DOMAIN=""
CERT_SOURCE_FULLCHAIN=""
CERT_SOURCE_KEY=""

CERT_METHOD="existing"
CERTBOT_EMAIL=""
CERT_IS_WILDCARD="false"

read -r -p "Domain: " DOMAIN
DOMAIN="${DOMAIN,,}"

if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    log "Invalid domain: $DOMAIN"
    exit 1
fi

# Check whether the configured certificate is a wildcard
# certificate that covers the requested domain.
if [[ -n "$SSL_FULLCHAIN" ]]; then
    while IFS= read -r wildcard_domain; do
        if [[ "$DOMAIN" == *."$wildcard_domain" ]]; then
            prefix="${DOMAIN%.$wildcard_domain}"

            if [[ -n "$prefix" && "$prefix" != *.* ]]; then
                CERT_IS_WILDCARD="true"
                break
            fi
        fi
    done < <(
        openssl x509 -in "$SSL_FULLCHAIN" -noout -ext subjectAltName 2>/dev/null |
            grep -oE 'DNS:\*\.[a-zA-Z0-9.-]+' |
            sed 's/^DNS:\*\.//'
    )
fi

if [[ "$INSTALL_TARGET" == "local" ]]; then

    if [[ -n "$SSL_FULLCHAIN" ]]; then
        CERT_METHOD="existing"
        CERT_SOURCE_FULLCHAIN="$SSL_FULLCHAIN"
        CERT_SOURCE_KEY="$SSL_PRIVKEY"
    else
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

                [[ -s "$CERT_SOURCE_FULLCHAIN" ]] || {
                    log "Certificate not found."
                    exit 1
                }

                [[ -s "$CERT_SOURCE_KEY" ]] || {
                    log "Private key not found."
                    exit 1
                }
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
                log "Invalid selection."
                exit 1
                ;;
        esac
    fi

else
    if [[ "$CERT_IS_WILDCARD" == "true" ]]; then
        CERT_METHOD="existing"
        CERT_SOURCE_FULLCHAIN="$SSL_FULLCHAIN"
        CERT_SOURCE_KEY="$SSL_PRIVKEY"

        log "Wildcard certificate detected. It will be copied to the remote server."
    else
        # Certificate selection will be performed on the remote server.
        CERT_METHOD="existing"
        CERT_SOURCE_FULLCHAIN=""
        CERT_SOURCE_KEY=""

        if [[ -n "$SSL_FULLCHAIN" ]]; then
            log "Configured certificate is not a wildcard certificate for $DOMAIN."
            log "Certificate selection will be performed on the remote server."
        else
            log "No certificate configured. Certificate selection will be performed on the remote server."
        fi
    fi
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
        log "ERROR: No SSH allowed IP addresses configured."
        exit 1
    fi
fi

if [[ "$INSTALL_TARGET" == "local" ]]; then
    [[ $EUID -eq 0 ]] || { log "Run local installation as root: sudo bash setup.sh"; exit 1; }
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

ARGS=(
    "$INSTALL_TARGET"
    "$APPLY_MODE"
    "$DOMAIN"
    "$CERT_METHOD"
    "$CERTBOT_EMAIL"
    "$HOST_IPV4"
    "$HOST_IPV6"
    "$CERT_IS_WILDCARD"
)

ARGS+=("$CERT_SOURCE_FULLCHAIN" "$CERT_SOURCE_KEY")

if [[ "$INSTALL_TARGET" == "local" ]]; then
    bash "$SCRIPT_DIR/modules/apply.sh" "${ARGS[@]}"
    exit $?
fi

for cmd in ssh sshpass scp tar; do
    command -v "$cmd" >/dev/null 2>&1 || { log "Missing dependency: $cmd (apt install $cmd)"; exit 1; }
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

tar -czf "$LOCAL_TMP/modules.tar.gz" -C "$SCRIPT_DIR" config.conf modules templates
sshpass -e scp "${SSH_OPTS[@]}" "$LOCAL_TMP/modules.tar.gz" "$SCP_DEST:$REMOTE_DIR/"
if [[ "$CERT_IS_WILDCARD" == "true" ]]; then
    sshpass -e scp "${SSH_OPTS[@]}" "$CERT_SOURCE_FULLCHAIN" "$SCP_DEST:$REMOTE_DIR/fullchain.pem"
    sshpass -e scp "${SSH_OPTS[@]}" "$CERT_SOURCE_KEY" "$SCP_DEST:$REMOTE_DIR/privkey.pem"
fi

REMOTE_ARGS=("${ARGS[@]}")

if [[ "$CERT_IS_WILDCARD" == "true" ]]; then
    REMOTE_ARGS[9]="$REMOTE_DIR/fullchain.pem"
    REMOTE_ARGS[10]="$REMOTE_DIR/privkey.pem"
fi
REMOTE_ARGS_ESCAPED=""

for arg in "${REMOTE_ARGS[@]}"; do
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
