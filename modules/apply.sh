#!/usr/bin/env bash
set -Eeuo pipefail

MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd -- "$MODULE_DIR/.." && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

source "$MODULE_DIR/common.sh"
source "$MODULE_DIR/ufw.sh"
source "$MODULE_DIR/nginx.sh"

INSTALL_MODE="$1"
MODE="$2"
SUBSCRIPTION="$3"
DOMAIN="$4"
CERT_METHOD="$5"
CERTBOT_EMAIL="$6"
HOST_IPV4="$7"
HOST_IPV6="$8"
SSH_ALL="$9"
shift 9

SSH_EXTRA_COUNT="$1"; shift
SSH_EXTRA_IPS=()
for ((i=0; i<SSH_EXTRA_COUNT; i++)); do SSH_EXTRA_IPS+=("$1"); shift; done

SSH_KEYS_COUNT="$1"; shift
SSH_KEYS=()
for ((i=0; i<SSH_KEYS_COUNT; i++)); do SSH_KEYS+=("$1"); shift; done

CERT_SOURCE_FULLCHAIN="${1:-}"
CERT_SOURCE_KEY="${2:-}"

check_ubuntu
echo "========================================"
echo " Applying setup: $MODE"
echo "========================================"

update_system
install_ssh_keys

if [[ "$MODE" == "full" || "$MODE" == "nginx" ]]; then
    [[ -n "$DOMAIN" ]] || { echo "Domain is required for Nginx."; exit 1; }
    install_nginx "$DOMAIN" "$CERT_METHOD" "$CERT_SOURCE_FULLCHAIN" "$CERT_SOURCE_KEY" "$SUBSCRIPTION" "$CERTBOT_EMAIL" "$INSTALL_MODE"
fi

if [[ "$MODE" == "full" || "$MODE" == "ufw" ]]; then
    install_ufw
fi

echo "Installation completed successfully."
