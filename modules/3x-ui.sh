
#!/usr/bin/env bash

install_3x_ui() {
    local DB_FILE="/etc/x-ui/x-ui.db"
    local INSTALL_RESULT="/etc/x-ui/install-result.env"
    local INSTALLER_TMP=""
    local TMP_DIR=""
    local CERT_FILE=""
    local KEY_FILE=""
    local SUB_REVERSE_PROXY="false"
    local SUB_LISTEN=""
    local SUB_URI=""
    local SUB_CLASH_URI=""
    local HAPP_ROUTING_URL="https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/refs/heads/main/HAPP/WHITELIST.DEEPLINK"
    local INCY_ROUTING_URL="https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/refs/heads/main/INCY/WHITELIST.DEEPLINK"
    local HAPP_ROUTING_TMP=""
    local INCY_ROUTING_TMP=""
    local HAPP_ROUTING_RULES=""
    local INCY_ROUTING_RULES=""
    local SERVER_COUNTRY=""
    local HYSTERIA_PASSWORD=""
    local DB_BACKUP=""

    # ========================================
    # CONFIGURATION
    # ========================================

    : "${DOMAIN:?DOMAIN is not configured.}"
    : "${XUI_INSTALL_URL:?XUI_INSTALL_URL is not configured.}"

    : "${XUI_PANEL_PORT:?XUI_PANEL_PORT is not configured.}"
    : "${XUI_WEB_BASE_PATH:?XUI_WEB_BASE_PATH is not configured.}"
    : "${XUI_VLESS_WS_PATH:?XUI_VLESS_WS_PATH is not configured.}"

    : "${XUI_SUBSCRIPTION:=false}"

    [[ "$XUI_SUBSCRIPTION" == "true" || "$XUI_SUBSCRIPTION" == "false" ]] ||
        die "SUBSCRIPTION must be true or false." 

    if [[ "$XUI_SUBSCRIPTION" == "true" ]]; then
        : "${XUI_SUBSCRIPTION_PORT:?XUI_SUBSCRIPTION_PORT is not configured.}"
        : "${XUI_SUB_PATH:?XUI_SUB_PATH is not configured.}"
        : "${XUI_SUB_CLASH_PATH:?XUI_SUB_CLASH_PATH is not configured.}"
    fi   

    local ports=("$XUI_PANEL_PORT")
    [[ "$XUI_SUBSCRIPTION" == "true" ]] && ports+=("$XUI_SUBSCRIPTION_PORT")

    for port in "${ports[@]}"; do
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || {
            die "ERROR: Invalid port: $port"
        }
    done

    # Certificate paths
    if [[ "$CERT_METHOD" == "certbot" ]]; then
        CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    elif [[ "$INSTALL_MODE" == "remote" ]]; then
        CERT_FILE="/etc/nginx/ssl/fullchain.pem"
        KEY_FILE="/etc/nginx/ssl/privkey.pem"
    else
        CERT_FILE="$CERT_SOURCE_FULLCHAIN"
        KEY_FILE="$CERT_SOURCE_KEY"
    fi

    if [[ "$NGINX_SUBSCRIPTION" == "true" ]]; then
        SUB_REVERSE_PROXY="true"
        SUB_LISTEN="127.0.0.1"
        SUB_URI="https://$DOMAIN$XUI_SUB_PATH"
        SUB_CLASH_URI="https://$DOMAIN$XUI_SUB_CLASH_PATH"
    fi

    TMP_DIR="$(mktemp -d)"
    INSTALLER_TMP="$(mktemp)"

    cleanup_3x_ui() {
        rm -f "$INSTALLER_TMP" "$HAPP_ROUTING_TMP" "$INCY_ROUTING_TMP"
        rm -rf "$TMP_DIR"
    }

    trap cleanup_3x_ui RETURN

    log "3x-ui configuration:"
    log "Installer: $XUI_INSTALL_URL"
    log "Panel port: $XUI_PANEL_PORT"
    if [[ "$NGINX_SUBSCRIPTION" == "true" ]]; then
        log "Subscription port: $XUI_SUBSCRIPTION_PORT"
        log "Subscription reverse proxy: $SUB_REVERSE_PROXY"
    fi

    # ========================================
    # DEPENDENCIES
    # ========================================

    ensure_dependencies ca-certificates openssl sqlite3 python3

    # ========================================
    # PORT CHECK
    # ========================================

    check_port() {
        local port="$1"

        if ss -ltnH | awk -v p=":$port" '$4 ~ (p"$") {found=1} END {exit !found}'; then
            die "TCP port $port is already in use."
        fi
    }

    check_port "$XUI_PANEL_PORT"
    [[ "$XUI_SUBSCRIPTION" == "true" ]] && check_port "$XUI_SUBSCRIPTION_PORT"

    # ========================================
    # GET COUNTRY
    # ========================================

    if [[ "$XUI_AUTODETECT_COUNTRY" == "true" ]]; then
        SERVER_COUNTRY="$(python3 "$SCRIPT_DIR/scripts/get_country.py")"
        log "Server location: $SERVER_COUNTRY"
        export SERVER_COUNTRY
    fi

    # ========================================
    # DOWNLOAD INSTALLER
    # ========================================

    log "Downloading 3x-ui installer..."

    curl -fLsS --retry 3 --connect-timeout 15 \
        "$XUI_INSTALL_URL" -o "$INSTALLER_TMP"

    [[ -s "$INSTALLER_TMP" ]] || die "Installer download failed."

    grep -q '^#!/' "$INSTALLER_TMP" ||
        die "Downloaded file does not look like a shell script."

    # ========================================
    # INSTALL 3X-UI
    # ========================================

    log "Installing 3x-ui..."

    export XUI_NONINTERACTIVE=1
    export XUI_DB_TYPE=sqlite
    export XUI_PANEL_PORT="$XUI_PANEL_PORT"
    export XUI_WEB_BASE_PATH="$XUI_WEB_BASE_PATH"
    export XUI_SSL_MODE=none
    export XUI_ENABLE_FAIL2BAN=true

    bash "$INSTALLER_TMP" ||
        die "3x-ui installer failed."

    # ========================================
    # VERIFY INSTALLATION
    # ========================================

    log "Checking installation..."

    [[ -x /usr/local/x-ui/x-ui ]] ||
        die "3x-ui executable not found."

    [[ -s "$DB_FILE" ]] ||
        die "3x-ui database not found."

    [[ -s "$INSTALL_RESULT" ]] ||
        die "Installation credentials file not found."

    systemctl stop x-ui

    # ========================================
    # DOWNLOAD ROUTING RULES
    # ========================================
    if [[ "$XUI_SUBSCRIPTION" == "true" && "$XUI_ROSCOMVPN_ROUTING_RULES" == "true" ]]; then
        log "Downloading routing rules..."

        HAPP_ROUTING_TMP="$(mktemp)"
        INCY_ROUTING_TMP="$(mktemp)"

        curl -fLsS --retry 3 --connect-timeout 15 \
            "$HAPP_ROUTING_URL" -o "$HAPP_ROUTING_TMP" ||
            die "Failed to download Happ routing rules."

        curl -fLsS --retry 3 --connect-timeout 15 \
            "$INCY_ROUTING_URL" -o "$INCY_ROUTING_TMP" ||
            die "Failed to download INCY routing rules."

        HAPP_ROUTING_RULES="$(cat "$HAPP_ROUTING_TMP")"
        INCY_ROUTING_RULES="$(cat "$INCY_ROUTING_TMP")"

        [[ "$HAPP_ROUTING_RULES" == happ://routing/onadd/* ]] ||
            die "Invalid Happ routing rules."

        [[ "$INCY_ROUTING_RULES" == incy://routing/onadd/* ]] ||
            die "Invalid INCY routing rules."

        log "Routing rules downloaded successfully."
    fi

    # ========================================
    # DATABASE CONFIGURATION
    # ========================================

    log "Configuring 3x-ui database..."

    DB_BACKUP="/etc/x-ui/x-ui.db.backup.$(date +%Y%m%d_%H%M%S)"

    sqlite3 "$DB_FILE" ".backup '$DB_BACKUP'"
    chmod 600 "$DB_BACKUP"

    HAS_KEY="$(sqlite3 "$DB_FILE" \
        "SELECT COUNT(*) FROM pragma_table_info('settings') WHERE name='key';")"

    HAS_VALUE="$(sqlite3 "$DB_FILE" \
        "SELECT COUNT(*) FROM pragma_table_info('settings') WHERE name='value';")"

    [[ "$HAS_KEY" == "1" && "$HAS_VALUE" == "1" ]] ||
        die "Settings table has an unexpected structure."

    sql_quote() {
        local value="$1"
        value="${value//\'/\'\'}"
        printf "'%s'" "$value"
    }

    set_setting() {
        local key="$1"
        local value="$2"

        printf "UPDATE settings SET value=%s WHERE key=%s;\n" \
            "$(sql_quote "$value")" "$(sql_quote "$key")"

        printf "INSERT INTO settings (key, value) SELECT %s, %s WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key=%s);\n" \
            "$(sql_quote "$key")" \
            "$(sql_quote "$value")" \
            "$(sql_quote "$key")"
    }

    if ! {
        echo ".bail on"
        echo "BEGIN IMMEDIATE;"

        # Panel
        set_setting "webPort" "$XUI_PANEL_PORT"
        set_setting "webListen" "127.0.0.1"
        set_setting "webBasePath" "$XUI_WEB_BASE_PATH"

        # Subscription
        if [[ "$XUI_SUBSCRIPTION" == "true" ]]; then
            set_setting "subPort" "$XUI_SUBSCRIPTION_PORT"
            set_setting "subListen" "$SUB_LISTEN"
            set_setting "subPath" "$XUI_SUB_PATH"
            set_setting "subClashPath" "$XUI_SUB_CLASH_PATH"
            set_setting "subClashEnable" "true"
            set_setting "subClashAutoDetect" "true"

            set_setting "subHappAutoDetect" "true"
            set_setting "subIncyAppAutoDetect" "true"

            # Subscription URLs
            if [[ "$NGINX_SUBSCRIPTION" == "true" ]]; then
                set_setting "subURI" "$SUB_URI"
                set_setting "subClashURI" "$SUB_CLASH_URI"
            fi

            if [[ "$XUI_ROSCOMVPN_ROUTING_RULES" == "true" ]]; then
                set_setting "subEnableRouting" "true"
                set_setting "subRoutingRules" "$HAPP_ROUTING_RULES"

                set_setting "subIncyEnableRouting" "true"
                set_setting "subIncyRoutingRules" "$INCY_ROUTING_RULES"
            fi

            # Remark template
            set_setting "remarkTemplate" '{{INBOUND}}|📊{{TRAFFIC_LEFT}}|⏳{{DAYS_LEFT}}D'
        else
            set_setting "subEnable" "false"
        fi

        echo "COMMIT;"
    } | sqlite3 "$DB_FILE"; then

        log "Database update failed. Restoring backup..."

        cp -a "$DB_BACKUP" "$DB_FILE"
        systemctl start x-ui || true

        die "Failed to configure 3x-ui database."
    fi

    log "Database configuration completed."

    HYSTERIA_PASSWORD="$(openssl rand -hex 16)"

    # ========================================
    # CREATE INBOUNDS
    # ========================================
    if [[ "$XUI_CREATE_INBOUNDS" == "true" ]]; then
        log "Creating Xray inbounds..."

        if ! DOMAIN="$DOMAIN" \
            CERT_FILE="$CERT_FILE" \
            KEY_FILE="$KEY_FILE" \
            XUI_VLESS_WS_PATH="$XUI_VLESS_WS_PATH" \
            HYSTERIA_PASSWORD="$HYSTERIA_PASSWORD" \
            XUI_AUTODETECT_COUNTRY="$XUI_AUTODETECT_COUNTRY" \
            SERVER_COUNTRY="$SERVER_COUNTRY" \
            python3 "$SCRIPT_DIR/scripts/create_inbounds.py"; then

            log "Inbound creation failed. Restoring database backup..."

            cp -a "$DB_BACKUP" "$DB_FILE"
            systemctl start x-ui || true

            die "Failed to create Xray inbounds."
        fi
    fi
    # ========================================
    # START SERVICE
    # ========================================

    log "Starting 3x-ui..."

    systemctl enable x-ui
    systemctl restart x-ui

    sleep 3

    systemctl is-active --quiet x-ui ||
        die "3x-ui service failed to start. Check: journalctl -u x-ui -n 100"

    # ========================================
    # CREDENTIALS
    # ========================================

    # The installer writes shell-escaped variables to this root-only file.
    # shellcheck disable=SC1090
    source "$INSTALL_RESULT"

    # ========================================
    # RESULT
    # ========================================

    echo
    echo "========================================"
    echo "          3X-UI INSTALLATION"
    echo "========================================"
    echo
    echo "Service:       $(systemctl is-active x-ui)"
    echo
    echo "Panel URL:     https://$DOMAIN$XUI_WEB_BASE_PATH"

    if [[ "$NGINX_SUBSCRIPTION" == "true" ]]; then
        echo "Subscription:  https://$DOMAIN$XUI_SUB_PATH"
        echo "Clash:         https://$DOMAIN$XUI_SUB_CLASH_PATH"
    fi

    echo
    echo "Panel username: $XUI_USERNAME"
    echo "Panel password: $XUI_PASSWORD"
    echo "Panel API key: $XUI_API_TOKEN"
    echo

    if [[ "$NGINX_SUBSCRIPTION" == "true" ]]; then
        echo "Subscription reverse proxy: $SUB_REVERSE_PROXY"
        echo "Subscription listen:        ${SUB_LISTEN:-0.0.0.0}"
        echo
    fi
    echo
    echo "Database backup: $DB_BACKUP"
    echo "Credentials:     $INSTALL_RESULT"
    echo
    echo "========================================"
}
