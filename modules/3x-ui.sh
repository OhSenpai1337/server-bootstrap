
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
    : "${SUBSCRIPTION:?SUBSCRIPTION is not configured.}"
    : "${XUI_INSTALL_URL:?XUI_INSTALL_URL is not configured.}"
    : "${PANEL_PORT:?PANEL_PORT is not configured.}"
    : "${SUBSCRIPTION_PORT:?SUBSCRIPTION_PORT is not configured.}"
    : "${WEB_BASE_PATH:?WEB_BASE_PATH is not configured.}"
    : "${SUB_PATH:?SUB_PATH is not configured.}"
    : "${SUB_CLASH_PATH:?SUB_CLASH_PATH is not configured.}"
    : "${VLESS_WS_PATH:?VLESS_WS_PATH is not configured.}"

    [[ "$SUBSCRIPTION" == "true" || "$SUBSCRIPTION" == "false" ]] ||
        die "SUBSCRIPTION must be true or false."    

    for port in "$PANEL_PORT" "$SUBSCRIPTION_PORT"; do
        [[ "$port" =~ ^[0-9]+$ ]] &&
            ((port >= 1 && port <= 65535)) ||
            die "Invalid port: $port"
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

    if [[ "$SUBSCRIPTION" == "true" ]]; then
        SUB_REVERSE_PROXY="true"
        SUB_LISTEN="127.0.0.1"
    fi

    SUB_URI="https://$DOMAIN$SUB_PATH"
    SUB_CLASH_URI="https://$DOMAIN$SUB_CLASH_PATH"

    TMP_DIR="$(mktemp -d)"
    INSTALLER_TMP="$(mktemp)"

    cleanup_3x_ui() {
        rm -f "$INSTALLER_TMP" "$HAPP_ROUTING_TMP" "$INCY_ROUTING_TMP"
        rm -rf "$TMP_DIR"
    }

    trap cleanup_3x_ui RETURN

    log "3x-ui configuration:"
    log "Installer: $XUI_INSTALL_URL"
    log "Panel port: $PANEL_PORT"
    log "Subscription port: $SUBSCRIPTION_PORT"
    log "Subscription reverse proxy: $SUB_REVERSE_PROXY"

    # ========================================
    # DEPENDENCIES
    # ========================================

    log "Installing dependencies..."

    apt-get update
    apt-get install -y curl ca-certificates openssl sqlite3 python3

    # ========================================
    # PORT CHECK
    # ========================================

    check_port() {
        local port="$1"

        if ss -ltnH | awk -v p=":$port" '$4 ~ (p"$") {found=1} END {exit !found}'; then
            die "TCP port $port is already in use."
        fi
    }

    check_port "$PANEL_PORT"
    check_port "$SUBSCRIPTION_PORT"

    # ========================================
    # GET COUNTRY
    # ========================================

    get_server_country() {
        local COUNTRIES_FILE="$TMP_DIR/country.json"

        curl -fsSL --retry 2 --max-time 15 \
            "https://raw.githubusercontent.com/umpirsky/country-list/master/data/en/country.json" \
            -o "$COUNTRIES_FILE" || {
                echo "Unknown"
                return
            }

        python3 - "$COUNTRIES_FILE" <<'PY'
import json
import sys
import urllib.request

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        countries = json.load(f)

    req = urllib.request.Request(
        "https://ipapi.co/json/",
        headers={"User-Agent": "3x-ui-installer"}
    )

    with urllib.request.urlopen(req, timeout=7) as response:
        data = json.load(response)

    code = data.get("country_code", "").upper()
    name = countries.get(code)

    if not name or len(code) != 2 or not code.isalpha():
        raise ValueError("Country not found")

    flag = "".join(chr(ord(c) + 127397) for c in code)

    print(f"{flag} {name}")

except Exception:
    print("Unknown")
PY
    }

    SERVER_COUNTRY="$(get_server_country)"
    log "Server location: $SERVER_COUNTRY"
    export SERVER_COUNTRY

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
    export XUI_PANEL_PORT="$PANEL_PORT"
    export XUI_WEB_BASE_PATH="$WEB_BASE_PATH"
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
        set_setting "webPort" "$PANEL_PORT"
        set_setting "webListen" "127.0.0.1"
        set_setting "webBasePath" "$WEB_BASE_PATH"

        # Subscription
        set_setting "subPort" "$SUBSCRIPTION_PORT"
        set_setting "subListen" "$SUB_LISTEN"
        set_setting "subPath" "$SUB_PATH"
        set_setting "subClashPath" "$SUB_CLASH_PATH"
        set_setting "subClashEnable" "true"
        set_setting "subClashAutoDetect" "true"

        # Subscription URLs
        if [[ "$SUBSCRIPTION" == "true" ]]; then
            set_setting "subURI" "$SUB_URI"
            set_setting "subClashURI" "$SUB_CLASH_URI"
        fi

        # Routing
        set_setting "subHappAutoDetect" "true"
        set_setting "subEnableRouting" "true"
        set_setting "subRoutingRules" "$HAPP_ROUTING_RULES"

        set_setting "subIncyAppAutoDetect" "true"
        set_setting "subIncyEnableRouting" "true"
        set_setting "subIncyRoutingRules" "$INCY_ROUTING_RULES"

        # Remark template
        set_setting "remarkTemplate" '{{INBOUND}}|📊{{TRAFFIC_LEFT}}|⏳{{DAYS_LEFT}}D'

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

    log "Creating Xray inbounds..."

    if ! DOMAIN="$DOMAIN" \
        CERT_FILE="$CERT_FILE" \
        KEY_FILE="$KEY_FILE" \
        VLESS_WS_PATH="$VLESS_WS_PATH" \
        HYSTERIA_PASSWORD="$HYSTERIA_PASSWORD" \
        python3 <<'PY'
import json
import os
import sqlite3
import secrets
import time

DB_FILE = "/etc/x-ui/x-ui.db"

domain = os.environ["DOMAIN"]
cert_file = os.environ["CERT_FILE"]
key_file = os.environ["KEY_FILE"]
vless_ws_path = os.environ["VLESS_WS_PATH"]
hysteria_password = os.environ["HYSTERIA_PASSWORD"]
server_country = os.environ.get("SERVER_COUNTRY", "Unknown")


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


sniffing = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic", "fakedns"]
}

# VLESS + WebSocket
vless_settings = {
    "clients": [],
    "decryption": "none",
    "encryption": "none",
    "disable_flow": 1
}

vless_stream = {
    "network": "ws",
    "wsSettings": {
        "acceptProxyProtocol": False,
        "path": vless_ws_path,
        "host": "",
        "headers": {},
        "heartbeatPeriod": 0
    },
    "security": "none"
}

# Hysteria 2
hysteria_settings = {
    "version": 2
}

hysteria_stream = {
    "network": "hysteria",
    "hysteriaSettings": {
        "version": 2,
        "udpIdleTimeout": 60,
        "masquerade": {
            "type": "proxy",
            "dir": "",
            "url": f"https://{domain}/",
            "rewriteHost": False,
            "insecure": False,
            "content": "",
            "headers": {},
            "statusCode": 0
        }
    },
    "security": "tls",
    "tlsSettings": {
        "serverName": domain,
        "minVersion": "1.2",
        "maxVersion": "1.3",
        "cipherSuites": "",
        "rejectUnknownSni": False,
        "disableSystemRoot": False,
        "enableSessionResumption": False,
        "certificates": [{
            "ocspStapling": 0,
            "oneTimeLoading": False,
            "usage": "encipherment",
            "buildChain": False,
            "certificateFile": cert_file,
            "keyFile": key_file,
            "useFile": True
        }],
        "alpn": ["h3"],
        "echServerKeys": "",
        "settings": {
            "fingerprint": "chrome",
            "echConfigList": "",
            "pinnedPeerCertSha256": [],
            "verifyPeerCertByName": ""
        }
    },
    "finalmask": {
        "udp": [{
            "type": "salamander",
            "settings": {
                "password": hysteria_password
            }
        }]
    }
}

# TUIC
tuic_settings = {
    "server": {
        "alpn": ["h3", "spdy/3.1"],
        "authentication_timeout": 3,
        "certificate": cert_file,
        "congestion_control": "bbr",
        "log_level": "info",
        "max_idle_time": 15,
        "max_udp_relay_packet_size": 1500,
        "private_key": key_file,
        "sni": domain,
        "udp_relay_mode": "native",
        "zero_rtt_handshake": True
    }
}

conn = sqlite3.connect(DB_FILE)

try:
    conn.execute("BEGIN IMMEDIATE")

    # Prevent duplicate inbounds
    tags = [
        "in-8888-tcp",
        "in-443-udp",
        "in-8443-udp"
    ]

    placeholders = ",".join("?" for _ in tags)

    existing = conn.execute(
        f"SELECT tag FROM inbounds WHERE tag IN ({placeholders})",
        tags
    ).fetchall()

    if existing:
        raise RuntimeError(
            "Inbound tags already exist: " +
            ", ".join(row[0] for row in existing)
        )

    def add_inbound(remark, tag, listen, port, protocol,
                    settings, stream_settings, flow):
        cursor = conn.execute("""
            INSERT INTO inbounds (
                user_id, up, down, total,
                remark, enable, expiry_time,
                listen, port, protocol,
                settings, stream_settings,
                tag, sniffing, disable_flow
            )
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, (
            1, 0, 0, 0,
            remark, 1, 0,
            listen, port, protocol,
            encode(settings),
            encode(stream_settings),
            tag,
            encode(sniffing),
            flow
        ))

        return cursor.lastrowid

    # 1. VLESS + WS
    vless_id = add_inbound(
        remark=f"{server_country} (WS)",
        tag="in-8888-tcp",
        listen="127.0.0.1",
        port=8888,
        protocol="vless",
        settings=vless_settings,
        stream_settings=vless_stream,
        flow=1
    )

    # 2. Hysteria 2
    hysteria_id = add_inbound(
        remark=f"{server_country} (Hysteria)",
        tag="in-443-udp",
        listen="",
        port=443,
        protocol="hysteria",
        settings=hysteria_settings,
        stream_settings=hysteria_stream,
        flow=0
    )

    # 3. TUIC
    tuic_id = add_inbound(
        remark=f"{server_country} (TUIC)",
        tag="in-8443-udp",
        listen="",
        port=8443,
        protocol="tuic",
        settings=tuic_settings,
        stream_settings={},
        flow=0
    )

    # WebSocket Host for VLESS
    now = int(time.time() * 1000)

    conn.execute("""
        INSERT INTO hosts (
            group_id,
            inbound_id,
            sort_order,
            remark,
            server_description,
            is_disabled,
            is_hidden,
            tags,
            address,
            port,
            security,
            sni,
            host_header,
            path,
            alpn,
            fingerprint,
            cipher_suites,
            override_sni_from_address,
            keep_sni_blank,
            created_at,
            updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        secrets.token_hex(8),
        vless_id,
        0,
        "WS",
        "",
        0,
        0,
        "[]",
        domain,
        443,
        "tls",
        "",
        "",
        "",
        encode(["h2", "http/1.1"]),
        "chrome",
        "",
        1,
        0,
        now,
        now
    ))

    conn.commit()

    print("Created inbounds:")
    print(f"  VLESS WS:    ID={vless_id}, port=8888")
    print(f"  Hysteria 2:  ID={hysteria_id}, port=443/UDP")
    print(f"  TUIC:        ID={tuic_id}, port=8443/UDP")
    print(f"  WebSocket Host: {domain}:443")

except Exception:
    conn.rollback()
    raise

finally:
    conn.close()
PY
    then
        log "Inbound creation failed. Restoring database backup..."

        cp -a "$DB_BACKUP" "$DB_FILE"
        systemctl start x-ui || true

        die "Failed to create Xray inbounds."
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
    echo "Panel URL:     https://$DOMAIN$WEB_BASE_PATH"

    if [[ "$SUBSCRIPTION" == "true" ]]; then
        echo "Subscription:  https://$DOMAIN$SUB_PATH"
        echo "Clash:         https://$DOMAIN$SUB_CLASH_PATH"
    fi

    echo
    echo "Panel username: $XUI_USERNAME"
    echo "Panel password: $XUI_PASSWORD"
    echo "Panel API key: $XUI_API_TOKEN"
    echo

    if [[ "$SUBSCRIPTION" == "true" ]]; then
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
