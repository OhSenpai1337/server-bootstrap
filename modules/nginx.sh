
#!/usr/bin/env bash

install_nginx() {
    local NGINX_CERT_FULLCHAIN=""
    local NGINX_CERT_KEY=""
    local CERT_TMP_DIR=""

    [[ -n "$DOMAIN" ]] || {
        echo "ERROR: Domain is required for Nginx."
        return 1
    }

    local ports=("$XUI_PANEL_PORT")
    [[ "$NGINX_SUBSCRIPTION" == "true" ]] && ports+=("$XUI_SUBSCRIPTION_PORT")

    for port in "${ports[@]}"; do
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || {
            echo "ERROR: Invalid port: $port"
            return 1
        }
    done

    ensure_dependencies gnupg2 ca-certificates lsb-release openssl

    . /etc/os-release

    case "$ID" in
        ubuntu)
            NGINX_REPO="ubuntu"
            ensure_dependencies ubuntu-keyring
            ;;
        debian)
            NGINX_REPO="debian"
            ensure_dependencies debian-archive-keyring
            ;;
        *)
            die "Unsupported distribution: $ID"
            ;;
    esac

    log "Installing official Nginx package..."
    install -d -m 0755 /usr/share/keyrings

    curl -fsSL https://nginx.org/keys/nginx_signing.key |
        gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

    chmod 0644 /usr/share/keyrings/nginx-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/$NGINX_REPO $(lsb_release -cs) nginx" \
        > /etc/apt/sources.list.d/nginx.list

    apt-get update
    apt-get install -y nginx

    # Obtain Let's Encrypt certificate.
    if [[ "$CERT_METHOD" == "certbot" ]]; then
        [[ -n "$CERTBOT_EMAIL" ]] || {
            echo "ERROR: Certbot email is required."
            return 1
        }

        echo "Installing Certbot..."
        apt-get install -y snapd

        snap list core >/dev/null 2>&1 || snap install core
        snap refresh core

        snap list certbot >/dev/null 2>&1 || snap install --classic certbot
        ln -sf /snap/bin/certbot /usr/bin/certbot

        echo "Installing Certbot renewal hooks..."
        install -d -m 0755 \
            /etc/letsencrypt/renewal-hooks/pre \
            /etc/letsencrypt/renewal-hooks/post

        cat > /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl stop nginx
EOF

        cat > /etc/letsencrypt/renewal-hooks/post/start-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl start nginx
EOF

        chmod 0755 \
            /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh \
            /etc/letsencrypt/renewal-hooks/post/start-nginx.sh

        echo "Obtaining Let's Encrypt certificate..."
        systemctl stop nginx

        if ! certbot certonly \
            --standalone \
            --non-interactive \
            --agree-tos \
            --keep-until-expiring \
            --email "$CERTBOT_EMAIL" \
            -d "$DOMAIN"; then

            systemctl start nginx || true
            echo "ERROR: Certbot certificate issuance failed."
            return 1
        fi

        CERT_SOURCE_FULLCHAIN="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        CERT_SOURCE_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    elif [[ "$CERT_METHOD" != "existing" ]]; then
        echo "ERROR: Invalid certificate method: $CERT_METHOD"
        return 1
    fi

    # Select certificate paths.
    if [[ "$CERT_METHOD" == "certbot" ]]; then
        NGINX_CERT_FULLCHAIN="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        NGINX_CERT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    elif [[ "$INSTALL_MODE" == "remote" ]]; then
        NGINX_CERT_FULLCHAIN="/etc/nginx/ssl/fullchain.pem"
        NGINX_CERT_KEY="/etc/nginx/ssl/privkey.pem"

        install -d -o root -g root -m 0700 /etc/nginx/ssl
        install -o root -g root -m 0644 "$CERT_SOURCE_FULLCHAIN" "$NGINX_CERT_FULLCHAIN"
        install -o root -g root -m 0600 "$CERT_SOURCE_KEY" "$NGINX_CERT_KEY"

    else
        NGINX_CERT_FULLCHAIN="$CERT_SOURCE_FULLCHAIN"
        NGINX_CERT_KEY="$CERT_SOURCE_KEY"
    fi

    # Validate selected certificate and private key.
    [[ -s "$NGINX_CERT_FULLCHAIN" ]] || {
        echo "ERROR: Certificate not found: $NGINX_CERT_FULLCHAIN"
        return 1
    }

    [[ -s "$NGINX_CERT_KEY" ]] || {
        echo "ERROR: Private key not found: $NGINX_CERT_KEY"
        return 1
    }

    if ! openssl x509 -in "$NGINX_CERT_FULLCHAIN" -noout -checkhost "$DOMAIN"; then
        echo "ERROR: Certificate does not cover $DOMAIN."
        return 1
    fi

    CERT_TMP_DIR="$(mktemp -d)"

    if ! openssl x509 -in "$NGINX_CERT_FULLCHAIN" -pubkey -noout |
        openssl pkey -pubin -outform DER > "$CERT_TMP_DIR/cert.pub"; then
        rm -rf "$CERT_TMP_DIR"
        echo "ERROR: Could not read certificate public key."
        return 1
    fi

    if ! openssl pkey -in "$NGINX_CERT_KEY" -pubout -outform DER > "$CERT_TMP_DIR/key.pub"; then
        rm -rf "$CERT_TMP_DIR"
        echo "ERROR: Could not read private key."
        return 1
    fi

    if ! cmp -s "$CERT_TMP_DIR/cert.pub" "$CERT_TMP_DIR/key.pub"; then
        rm -rf "$CERT_TMP_DIR"
        echo "ERROR: Certificate and private key do not match."
        return 1
    fi

    rm -rf "$CERT_TMP_DIR"

    # Install Nginx configuration.
    install -d -m 0755 \
        /etc/nginx/snippets \
        /etc/nginx/sites-available \
        /etc/nginx/sites-enabled \
        /var/www/html

    install -m 0644 "$TEMPLATES_DIR/nginx.conf" /etc/nginx/nginx.conf

    install -m 644 "$TEMPLATES_DIR/common-site.conf" \
    /etc/nginx/snippets/common-site.conf

    # Generate 3x-ui panel configuration.
    sed \
        -e "s|__WEB_BASE_PATH__|$XUI_WEB_BASE_PATH|g" \
        -e "s|__PANEL_PORT__|$XUI_PANEL_PORT|g" \
        "$TEMPLATES_DIR/3x-ui.conf" \
        > /etc/nginx/snippets/3x-ui.conf

    # Generate WebSocket API configuration.
    if [[ "$XUI_CREATE_INBOUNDS" == "true" ]]; then
        sed \
            -e "s|__VLESS_WS_PATH__|$XUI_VLESS_WS_PATH|g" \
            "$TEMPLATES_DIR/ws.conf" \
            > /etc/nginx/snippets/ws.conf
    else
        rm -f /etc/nginx/snippets/ws.conf
    fi    

    # Generate SSL snippet with selected certificate paths.
    if ! awk \
        -v cert="$NGINX_CERT_FULLCHAIN" \
        -v key="$NGINX_CERT_KEY" '
        /^[[:space:]]*ssl_certificate[[:space:]]/ {
            print "ssl_certificate \"" cert "\";"
            cert_found++
            next
        }
        /^[[:space:]]*ssl_certificate_key[[:space:]]/ {
            print "ssl_certificate_key \"" key "\";"
            key_found++
            next
        }
        { print }
        END {
            if (cert_found != 1 || key_found != 1) {
                exit 1
            }
        }
    ' "$TEMPLATES_DIR/ssl.conf" > /etc/nginx/snippets/ssl.conf; then
        echo "ERROR: Could not find certificate directives in ssl.conf."
        return 1
    fi

    # Generate sub.conf with configured subscription port.
    if [[ "$NGINX_SUBSCRIPTION" == "true" ]]; then
        # Generate subscription configuration.
        sed \
            -e "s|__SUB_PATH__|$XUI_SUB_PATH|g" \
            -e "s|__SUB_CLASH_PATH__|$XUI_SUB_CLASH_PATH|g" \
            -e "s|__SUBSCRIPTION_PORT__|$XUI_SUBSCRIPTION_PORT|g" \
            "$TEMPLATES_DIR/sub.conf" \
            > /etc/nginx/snippets/sub.conf
    else
        rm -f /etc/nginx/snippets/sub.conf
    fi

    rm -f /etc/nginx/conf.d/default.conf

    cat > /etc/nginx/sites-available/default <<EOF
# HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

# HTTPS + HTTP/2
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN;

    include /etc/nginx/snippets/ssl.conf;
    include /etc/nginx/snippets/common-site.conf;
    include /etc/nginx/snippets/3x-ui.conf;
    include /etc/nginx/snippets/ws.conf;
EOF

    [[ "$XUI_CREATE_INBOUNDS" == "true" ]] && printf '    include /etc/nginx/snippets/ws.conf;\n' >> /etc/nginx/sites-available/default
    [[ "$NGINX_SUBSCRIPTION" == "true" ]] && printf '    include /etc/nginx/snippets/sub.conf;\n' >> /etc/nginx/sites-available/default

    cat >> /etc/nginx/sites-available/default <<'EOF'
}
EOF

    chmod 0644 /etc/nginx/sites-available/default
    ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

    nginx -t || return 1

    systemctl enable nginx
    systemctl restart nginx

    log "Nginx installed and configured for $DOMAIN."
}
