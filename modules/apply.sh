
#!/usr/bin/env bash
set -Eeuo pipefail

MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd -- "$MODULE_DIR/.." && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

[[ -f "$CONFIG_FILE" ]] || {
    echo "Missing configuration: $CONFIG_FILE"
    exit 1
}

source "$CONFIG_FILE"
source "$MODULE_DIR/common.sh"
source "$MODULE_DIR/ufw.sh"
source "$MODULE_DIR/nginx.sh"
source "$MODULE_DIR/3x-ui.sh"

INSTALL_MODE="$1"
MODE="$2"
DOMAIN="$3"
HOST_IPV4="$4"
HOST_IPV6="$5"
CERT_IS_WILDCARD="$6"
CERT_SOURCE_FULLCHAIN="${7:-}"
CERT_SOURCE_KEY="${8:-}"

CERT_METHOD=""
CERTBOT_EMAIL=""

if [[ "$INSTALL_MODE" == "remote" && "$CERT_IS_WILDCARD" == "true" ]]; then
    CERT_SOURCE_FULLCHAIN="$SCRIPT_DIR/../fullchain.pem"
    CERT_SOURCE_KEY="$SCRIPT_DIR/../privkey.pem"
fi

echo "========================================"
echo " Applying setup: $MODE"
echo "========================================"

[[ "$UPDATE_SYSTEM" == "true" ]] && update_system

ensure_dependencies curl

if [[ "$USE_SSH_KEYS" == "true" && ${#SSH_KEYS[@]} -gt 0 ]]; then
    install_ssh_keys

    if [[ "$SSH_KEY_ONLY" == "true" ]]; then
        configure_ssh_key_only
    fi
elif [[ "$USE_SSH_KEYS" == "true" && "$SSH_KEY_ONLY" == "true" ]]; then
    echo "ERROR: SSH_KEY_ONLY=true requires SSH_KEYS."
    exit 1
fi

# Configure UFW before Nginx and Certbot.
[[ "$MODE" == "full" || "$MODE" == "ufw" ]] && install_ufw

if [[ "$MODE" == "full" || "$MODE" == "nginx" ]]; then
    [[ -n "$DOMAIN" ]] || die "Domain is required for Nginx."

    check_domain_ip "$DOMAIN" "$(get_public_ipv4)"

    # Select certificate method.
    if [[ "$SSL_USE_EXISTING" == "false" ]]; then
        CERT_METHOD="certbot"

        read -r -p "Let's Encrypt email: " CERTBOT_EMAIL

        [[ "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Invalid email address."

    elif [[ "$CERT_IS_WILDCARD" == "true" ]]; then
        CERT_METHOD="existing"

        log "Using configured wildcard certificate."

    else
        echo
        echo "Certificate configuration:"
        echo "1. Existing certificates"
        echo "2. Let's Encrypt (Certbot)"
        read -r -p "Select certificate method: " CERT_CHOICE

        case "$CERT_CHOICE" in
            1)
                CERT_METHOD="existing"

                # Use configured paths on local installation.
                if [[ "$INSTALL_MODE" == "local" && -n "$SSL_FULLCHAIN" ]]; then
                    CERT_SOURCE_FULLCHAIN="$SSL_FULLCHAIN"
                    CERT_SOURCE_KEY="$SSL_PRIVKEY"

                    [[ "$CERT_SOURCE_FULLCHAIN" == /* ]] || CERT_SOURCE_FULLCHAIN="$SCRIPT_DIR/$CERT_SOURCE_FULLCHAIN"
                    [[ "$CERT_SOURCE_KEY" == /* ]] || CERT_SOURCE_KEY="$SCRIPT_DIR/$CERT_SOURCE_KEY"
                else
                    read -r -p "Fullchain certificate path: " CERT_SOURCE_FULLCHAIN
                    read -r -p "Private key path: " CERT_SOURCE_KEY
                fi
                ;;

            2)
                CERT_METHOD="certbot"

                read -r -p "Let's Encrypt email: " CERTBOT_EMAIL

                [[ "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Invalid email address."
                ;;

            *)
                die "Invalid selection."
                ;;
        esac
    fi

    # Validate selected certificate paths.
    if [[ "$CERT_METHOD" == "existing" ]]; then
        [[ -s "$CERT_SOURCE_FULLCHAIN" ]] || die "Certificate not found: $CERT_SOURCE_FULLCHAIN"
        [[ -s "$CERT_SOURCE_KEY" ]] || die "Private key not found: $CERT_SOURCE_KEY"
    fi

    install_nginx
fi

if [[ "$MODE" == "full" || "$MODE" == "3x-ui" ]]; then
    # Do not overwrite an existing installation.
    if systemctl cat x-ui >/dev/null 2>&1; then
        if systemctl is-active --quiet x-ui; then
            die "3x-ui is already running."
        fi

        die "x-ui service already exists but is inactive. Refusing to overwrite it."
    fi
    install_3x_ui
fi

log "Installation completed successfully."
