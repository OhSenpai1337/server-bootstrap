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

check_system
[[ $EUID -eq 0 ]] || die "Run installation as root: sudo bash setup.sh"
ensure_dependencies \
    python3 \
    openssl \
    grep \
    sed \
    gawk \
    iproute2 \
    coreutils \
    tar

SSH_EXTRA_IPS=()
SSH_KEYS=()
SSL_FULLCHAIN=""
SSL_PRIVKEY=""
SSH_ALL=""
source "$CONFIG_FILE"

: "${SSH_ALL:?SSH_ALL is not configured}"
[[ "$SSH_ALL" =~ ^(true|false)$ ]] || die "SSH_ALL must be true or false."

: "${SSL_USE_EXISTING:=true}"
[[ "$SSL_USE_EXISTING" =~ ^(true|false)$ ]] || die "SSL_USE_EXISTING must be true or false."

# Validate URL paths.
[[ -n "$XUI_WEB_BASE_PATH" && "$XUI_WEB_BASE_PATH" != "/PATH_TO_YOUR_PANEL/" ]] || die "XUI_WEB_BASE_PATH is empty or has its default value."
[[ -n "$XUI_VLESS_WS_PATH" && "$XUI_VLESS_WS_PATH" != "/VLESS_WS_PATH/" ]] || die "XUI_VLESS_WS_PATH is empty or has its default value."
[[ -n "$XUI_SUB_PATH" && "$XUI_SUB_PATH" != "/SUB_PATH/" ]] || die "XUI_SUB_PATH is empty or has its default value."
[[ -n "$XUI_SUB_CLASH_PATH" && "$XUI_SUB_CLASH_PATH" != "/SUB_CLASH_PATH/" ]] || die "XUI_SUB_CLASH_PATH is empty or has its default value."

if [[ "$SSL_USE_EXISTING" == "true" && -n "$SSL_FULLCHAIN" && -n "$SSL_PRIVKEY" ]]; then
    SSL_FULLCHAIN="${SSL_FULLCHAIN/#\~/$HOME}"
    SSL_PRIVKEY="${SSL_PRIVKEY/#\~/$HOME}"

    [[ "$SSL_FULLCHAIN" == /* ]] || SSL_FULLCHAIN="$SCRIPT_DIR/$SSL_FULLCHAIN"
    [[ "$SSL_PRIVKEY" == /* ]] || SSL_PRIVKEY="$SCRIPT_DIR/$SSL_PRIVKEY"

    [[ -s "$SSL_FULLCHAIN" ]] || die "Certificate not found: $SSL_FULLCHAIN"
    [[ -s "$SSL_PRIVKEY" ]] || die "Private key not found: $SSL_PRIVKEY"

elif [[ "$SSL_USE_EXISTING" == "true" && ( -n "$SSL_FULLCHAIN" || -n "$SSL_PRIVKEY" ) ]]; then
    die "SSL_FULLCHAIN and SSL_PRIVKEY must both be configured."
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
    [[ "$key" == *" "* ]] || die "Invalid SSH public key entry: $key"
done

# ========================================
# INSTALLATION TARGET
# ========================================

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
    *) die "Invalid selection." ;;
esac

APPLY_MODE="full"

# ========================================
# DOMAIN AND CERTIFICATE
# ========================================

DOMAIN=""
CERT_SOURCE_FULLCHAIN=""
CERT_SOURCE_KEY=""
CERT_IS_WILDCARD="false"

read -r -p "Domain: " DOMAIN
DOMAIN="${DOMAIN,,}"

if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    die "Invalid domain: $DOMAIN"
fi

# Check whether the configured certificate is a wildcard
# certificate that covers the requested domain.
if [[ "$SSL_USE_EXISTING" == "true" && -n "$SSL_FULLCHAIN" ]]; then
    while IFS= read -r wildcard_domain; do
        if [[ "$DOMAIN" == *."$wildcard_domain" ]]; then
            prefix="${DOMAIN%.$wildcard_domain}"

            if [[ -n "$prefix" && "$prefix" != *.* ]]; then
                CERT_IS_WILDCARD="true"
                CERT_SOURCE_FULLCHAIN="$SSL_FULLCHAIN"
                CERT_SOURCE_KEY="$SSL_PRIVKEY"

                log "Wildcard certificate detected."
                break
            fi
        fi
    done < <(
        openssl x509 -in "$SSL_FULLCHAIN" -noout -ext subjectAltName 2>/dev/null |
            grep -oE 'DNS:\*\.[a-zA-Z0-9.-]+' |
            sed 's/^DNS:\*\.//'
    )
fi

# ========================================
# TARGET PREPARATION
# ========================================

HOST_IPV4=""
HOST_IPV6=""

source "$SCRIPT_DIR/targets/$INSTALL_TARGET.sh"
prepare_target

# ========================================
# CONFIRMATION
# ========================================

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
    "$HOST_IPV4"
    "$HOST_IPV6"
    "$CERT_IS_WILDCARD"
    "$CERT_SOURCE_FULLCHAIN"
    "$CERT_SOURCE_KEY"
)

run_target