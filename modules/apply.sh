
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
CERT_METHOD="$4"
CERTBOT_EMAIL="$5"
HOST_IPV4="$6"
HOST_IPV6="$7"
CERT_IS_WILDCARD="$8"
CERT_SOURCE_FULLCHAIN="${9:-}"
CERT_SOURCE_KEY="${10:-}"

if [[ "$INSTALL_MODE" == "remote" && "$CERT_IS_WILDCARD" == "true" ]]; then
    CERT_SOURCE_FULLCHAIN="$SCRIPT_DIR/../fullchain.pem"
    CERT_SOURCE_KEY="$SCRIPT_DIR/../privkey.pem"
fi

echo "========================================"
echo " Applying setup: $MODE"
echo "========================================"

update_system
ensure_dependencies curl
install_ssh_keys

# Configure UFW before Nginx and Certbot.
if [[ "$MODE" == "full" || "$MODE" == "ufw" ]]; then
    install_ufw
fi

if [[ "$MODE" == "full" || "$MODE" == "nginx" ]]; then
    [[ -n "$DOMAIN" ]] || die "Domain is required for Nginx."

    check_domain_ip "$DOMAIN" "$(get_public_ipv4)"

    # Remote certificate selection.
    if [[ "$INSTALL_MODE" == "remote" && "$CERT_IS_WILDCARD" != "true" ]]; then
        echo
        echo "Certificate configuration on remote server:"
        echo "1. Existing certificates"
        echo "2. Let's Encrypt (Certbot)"
        read -r -p "Select certificate method: " CERT_CHOICE

        case "$CERT_CHOICE" in
            1)
                CERT_METHOD="existing"

                read -r -p "Fullchain certificate path: " CERT_SOURCE_FULLCHAIN
                read -r -p "Private key path: " CERT_SOURCE_KEY

                [[ -s "$CERT_SOURCE_FULLCHAIN" ]] || {
                    echo "Certificate not found: $CERT_SOURCE_FULLCHAIN"
                    exit 1
                }

                [[ -s "$CERT_SOURCE_KEY" ]] || {
                    echo "Private key not found: $CERT_SOURCE_KEY"
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

                CERT_SOURCE_FULLCHAIN=""
                CERT_SOURCE_KEY=""
                ;;
            *)
                echo "Invalid selection."
                exit 1
                ;;
        esac
    fi

    # Wildcard certificate is copied from the controller.
    if [[ "$INSTALL_MODE" == "remote" && "$CERT_IS_WILDCARD" == "true" ]]; then
        CERT_METHOD="existing"

        [[ -s "$CERT_SOURCE_FULLCHAIN" ]] || {
            echo "Certificate not found: $CERT_SOURCE_FULLCHAIN"
            exit 1
        }

        [[ -s "$CERT_SOURCE_KEY" ]] || {
            echo "Private key not found: $CERT_SOURCE_KEY"
            exit 1
        }
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
