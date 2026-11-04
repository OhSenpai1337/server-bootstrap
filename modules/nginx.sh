
#!/usr/bin/env bash

install_nginx() {
    local DOMAIN="$1"
    local CERT_METHOD="$2"
    local CERT_SOURCE_FULLCHAIN="$3"
    local CERT_SOURCE_KEY="$4"
    local SUBSCRIPTION="$5"
    local CERTBOT_EMAIL="$6"
    local INSTALL_MODE="$7"

    local NGINX_CERT_FULLCHAIN=""
    local NGINX_CERT_KEY=""

    echo "Installing Nginx dependencies..."
    apt-get install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring openssl

    echo "Installing official Nginx package..."
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://nginx.org/keys/nginx_signing.key |
        gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg
    chmod 0644 /usr/share/keyrings/nginx-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
        > /etc/apt/sources.list.d/nginx.list

    apt-get update
    apt-get install -y nginx

    # Obtain Let's Encrypt certificate locally.
    if [[ "$CERT_METHOD" == "certbot" ]]; then
        if [[ "$INSTALL_MODE" != "local" ]]; then
            echo "ERROR: Certbot is only supported for local installation."
            return 1
        fi

        [[ -n "$CERTBOT_EMAIL" ]] || {
            echo "Certbot email is required."
            return 1
        }

        echo "Installing Certbot..."
        apt-get install -y snapd
        snap install core
        snap refresh core
        snap install --classic certbot
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
            systemctl start nginx
            echo "ERROR: Certbot certificate issuance failed."
            return 1
        fi

        CERT_SOURCE_FULLCHAIN="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        CERT_SOURCE_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    fi

    # Validate certificate and private key.
    [[ -s "$CERT_SOURCE_FULLCHAIN" && -s "$CERT_SOURCE_KEY" ]] || {
        echo "ERROR: Certificate or private key is missing."
        return 1
    }

    openssl x509 -in "$CERT_SOURCE_FULLCHAIN" -noout -checkhost "$DOMAIN" || {
        echo "ERROR: Certificate does not cover $DOMAIN."
        return 1
    }

    openssl x509 -in "$CERT_SOURCE_FULLCHAIN" -pubkey -noout |
        openssl pkey -pubin -outform DER > /tmp/nginx-cert.pub

    openssl pkey -in "$CERT_SOURCE_KEY" -pubout -outform DER > /tmp/nginx-key.pub

    if ! cmp -s /tmp/nginx-cert.pub /tmp/nginx-key.pub; then
        rm -f /tmp/nginx-cert.pub /tmp/nginx-key.pub
        echo "ERROR: Certificate and private key do not match."
        return 1
    fi

    rm -f /tmp/nginx-cert.pub /tmp/nginx-key.pub

    # Select certificate paths.
    if [[ "$INSTALL_MODE" == "remote" ]]; then
        NGINX_CERT_FULLCHAIN="/etc/nginx/ssl/fullchain.pem"
        NGINX_CERT_KEY="/etc/nginx/ssl/privkey.pem"

        install -d -o root -g root -m 0700 /etc/nginx/ssl
        install -o root -g root -m 0644 "$CERT_SOURCE_FULLCHAIN" "$NGINX_CERT_FULLCHAIN"
        install -o root -g root -m 0600 "$CERT_SOURCE_KEY" "$NGINX_CERT_KEY"
    else
        NGINX_CERT_FULLCHAIN="$CERT_SOURCE_FULLCHAIN"
        NGINX_CERT_KEY="$CERT_SOURCE_KEY"
    fi

    # Install Nginx configuration.
    install -d -m 0755 \
        /etc/nginx/snippets \
        /etc/nginx/sites-available \
        /etc/nginx/sites-enabled \
        /var/www/html

    install -m 0644 "$TEMPLATES_DIR/nginx.conf" /etc/nginx/nginx.conf
    install -m 0644 "$TEMPLATES_DIR/common-site.conf" /etc/nginx/snippets/common-site.conf

    # Generate SSL snippet with selected certificate paths.
    if ! awk \
        -v cert="$NGINX_CERT_FULLCHAIN" \
        -v key="$NGINX_CERT_KEY" '
        /^[[:space:]]*ssl_certificate[[:space:]]/ {
            print "ssl_certificate " cert ";"
            cert_found++
            next
        }
        /^[[:space:]]*ssl_certificate_key[[:space:]]/ {
            print "ssl_certificate_key " key ";"
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

    if [[ "$SUBSCRIPTION" == "true" ]]; then
        install -m 0644 "$TEMPLATES_DIR/sub.conf" /etc/nginx/snippets/sub.conf
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
EOF

    if [[ "$SUBSCRIPTION" == "true" ]]; then
        printf '    include /etc/nginx/snippets/sub.conf;\n' >> /etc/nginx/sites-available/default
    fi

    cat >> /etc/nginx/sites-available/default <<'EOF'
}
EOF

    chmod 0644 /etc/nginx/sites-available/default
    ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

    nginx -t || return 1

    systemctl enable nginx
    systemctl restart nginx

    echo "Nginx installed and configured for $DOMAIN."
}
