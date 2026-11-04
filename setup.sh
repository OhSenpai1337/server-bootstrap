
#!/usr/bin/env bash
set -Eeuo pipefail

# ========================================
# SERVER BOOTSTRAP - CENTRAL CONTROLLER
# ========================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

TEMPLATES_DIR="$SCRIPT_DIR/templates"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing configuration: $CONFIG_FILE"
    exit 1
fi

SSH_EXTRA_IPS=()
SSH_KEYS=()

source "$CONFIG_FILE"

: "${CERT_DIR:?CERT_DIR is not configured}"
: "${SSH_ALL:?SSH_ALL is not configured}"

# Resolve relative certificate directory against script directory
if [[ "$CERT_DIR" != /* ]]; then
    CERT_DIR="$SCRIPT_DIR/$CERT_DIR"
fi

if [[ ! "$SSH_ALL" =~ ^(true|false)$ ]]; then
    echo "SSH_ALL must be true or false."
    exit 1
fi

# SSH settings
SSH_OPTS=(
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new
)

# Check dependencies
for cmd in ssh sshpass scp python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing dependency: $cmd"
        echo "Install it with: apt install $cmd"
        exit 1
    fi
done

# Check local files
for file in nginx.conf common-site.conf; do
    [[ -s "$TEMPLATES_DIR/$file" ]] || {
        echo "Missing template: $TEMPLATES_DIR/$file"
        exit 1
    }
done

for file in fullchain.pem privkey.pem; do
    [[ -s "$CERT_DIR/$file" ]] || {
        echo "Missing certificate: $CERT_DIR/$file"
        exit 1
    }
done

HOST_IPV4="$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}' | python3 -c '
import sys, ipaddress
for line in sys.stdin:
    try:
        ip = ipaddress.ip_address(line.strip())
        if ip.is_global:
            print(ip)
            break
    except ValueError:
        pass
')"

HOST_IPV6="$(ip -6 -o addr show scope global |
    awk '!/temporary|deprecated|tentative|dadfailed/ {split($4,a,"/"); print a[1]}' |
    python3 -c '
import sys, ipaddress
for line in sys.stdin:
    try:
        ip = ipaddress.ip_address(line.strip())
        if ip.version == 6 and ip.is_global:
            print(ip)
            break
    except ValueError:
        pass
')"

if [[ "$SSH_ALL" == "false" && -z "$HOST_IPV4" && -z "$HOST_IPV6" && ${#SSH_EXTRA_IPS[@]} -eq 0 ]]; then
    echo "ERROR: No SSH allowed IP addresses configured."
    exit 1
fi

for ip in "${SSH_EXTRA_IPS[@]}"; do
    python3 - "$ip" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    print(f"Invalid SSH IP: {sys.argv[1]}")
    sys.exit(1)
PY
done

# Input
echo "========================================"
echo "         SERVER BOOTSTRAP"
echo "========================================"
echo

echo "========================================"
echo "Controller IPv4: ${HOST_IPV4:-not detected}"
echo "Controller IPv6: ${HOST_IPV6:-not detected}"
echo "SSH unrestricted: $SSH_ALL"
echo "========================================"
echo

read -r -p "Target IP: " TARGET_IP
read -r -p "SSH user: " SSH_USER
read -r -s -p "SSH password: " SSH_PASSWORD
echo
read -r -p "Domain: " DOMAIN

# Validate IP
python3 - "$TARGET_IP" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    print("Invalid IP address.")
    sys.exit(1)
PY

# Validate username
if [[ ! "$SSH_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]]; then
    echo "Invalid SSH username."
    exit 1
fi

# Normalize domain
DOMAIN="${DOMAIN,,}"

if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    echo "Invalid domain: $DOMAIN"
    exit 1
fi

SSH_DEST="${SSH_USER}@${TARGET_IP}"

# SCP requires brackets around IPv6 addresses
if [[ "$TARGET_IP" == *:* ]]; then
    SCP_DEST="${SSH_USER}@[$TARGET_IP]"
else
    SCP_DEST="$SSH_DEST"
fi

echo
echo "----------------------------------------"
echo "Target:   $TARGET_IP"
echo "User:     $SSH_USER"
echo "Hostname: $DOMAIN"
echo "----------------------------------------"
echo
echo "WARNING:"
echo "UFW will be reset and reconfigured."
echo "SSH access configuration:"
if [[ "$SSH_ALL" == "true" ]]; then
    echo "  SSH: allowed from ANY IP"
else
    echo "  SSH IPv4: ${HOST_IPV4:-not detected}"
    echo "  SSH IPv6: ${HOST_IPV6:-not detected}"

    for ip in "${SSH_EXTRA_IPS[@]}"; do
        echo "  Additional SSH IP: $ip"
    done
fi
echo

read -r -p "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

# Password is supplied to sshpass through environment,
# not through command-line arguments.
export SSHPASS="$SSH_PASSWORD"
unset SSH_PASSWORD

REMOTE_DIR=""
CLEANUP_NEEDED=0

cleanup() {
    if [[ "$CLEANUP_NEEDED" -eq 1 && -n "$REMOTE_DIR" ]]; then
        sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" \
            "rm -rf -- '$REMOTE_DIR'" >/dev/null 2>&1 || true
    fi

    unset SSHPASS
}

trap cleanup EXIT

ssh_target() {
    sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" "$@"
}

scp_target() {
    sshpass -e scp "${SSH_OPTS[@]}" "$@" "$SCP_DEST:$REMOTE_DIR/"
}

# Check SSH connection
echo
echo "[1/5] Checking SSH connection..."

ssh_target "echo SSH connection successful" || {
    echo "Cannot connect to target server."
    exit 1
}

# Create remote temporary directory
REMOTE_DIR="$(ssh_target 'mktemp -d /tmp/server-bootstrap.XXXXXX')"
CLEANUP_NEEDED=1

echo "Remote directory: $REMOTE_DIR"

# Create remote installation script
LOCAL_TMP="$(mktemp -d)"
trap 'rm -rf "$LOCAL_TMP"; cleanup' EXIT

cat > "$LOCAL_TMP/remote-setup.sh" <<'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN="$1"
STAGE_DIR="$2"
HOST_IPV4="$3"
HOST_IPV6="$4"
SSH_ALL="$5"

shift 5

SSH_EXTRA_COUNT="$1"
shift

SSH_EXTRA_IPS=()

for ((i = 0; i < SSH_EXTRA_COUNT; i++)); do
    SSH_EXTRA_IPS+=("$1")
    shift
done

SSH_KEYS_COUNT="$1"
shift

SSH_KEYS=()

for ((i = 0; i < SSH_KEYS_COUNT; i++)); do
    SSH_KEYS+=("$1")
    shift
done

if [[ $EUID -ne 0 ]]; then
    echo "Remote script must run as root."
    exit 1
fi

echo
echo "========================================"
echo " Remote setup: $DOMAIN"
echo "========================================"

# Check operating system
source /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    echo "This script supports Ubuntu only."
    exit 1
fi

# Set hostname
echo "[1/8] Setting hostname..."
hostnamectl set-hostname "$DOMAIN"

# Update system
echo "[2/8] Updating Ubuntu..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y

# Install dependencies
echo "[3/8] Installing packages..."

apt-get install -y \
    ufw \
    curl \
    gnupg2 \
    ca-certificates \
    lsb-release \
    ubuntu-keyring \
    nano \
    openssl

# Add official Nginx repository
echo "[4/8] Installing Nginx..."

install -d -m 0755 /usr/share/keyrings

curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

chmod 0644 /usr/share/keyrings/nginx-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list

apt-get update -y
apt-get install -y nginx

# Validate certificate and private key
echo "[5/8] Installing certificates..."

if [[ ! -s "$STAGE_DIR/fullchain.pem" || ! -s "$STAGE_DIR/privkey.pem" ]]; then
    echo "Certificate files are missing."
    exit 1
fi

if ! openssl x509 -in "$STAGE_DIR/fullchain.pem" \
    -noout -checkhost "$DOMAIN"; then
    echo "Certificate does not cover $DOMAIN"
    exit 1
fi

openssl x509 -in "$STAGE_DIR/fullchain.pem" -pubkey -noout \
    | openssl pkey -pubin -outform DER \
    > "$STAGE_DIR/cert.pub"

openssl pkey -in "$STAGE_DIR/privkey.pem" -pubout -outform DER \
    > "$STAGE_DIR/key.pub"

if ! cmp -s "$STAGE_DIR/cert.pub" "$STAGE_DIR/key.pub"; then
    echo "Certificate and private key do not match."
    exit 1
fi

install -d -o root -g root -m 0700 /etc/nginx/ssl

install -o root -g root -m 0644 \
    "$STAGE_DIR/fullchain.pem" \
    /etc/nginx/ssl/fullchain.pem

install -o root -g root -m 0600 \
    "$STAGE_DIR/privkey.pem" \
    /etc/nginx/ssl/privkey.pem

# Deploy Nginx configuration
echo "[6/8] Deploying Nginx configuration..."

install -d -m 0755 /etc/nginx/snippets
install -d -m 0755 /etc/nginx/sites-available
install -d -m 0755 /etc/nginx/sites-enabled
install -d -m 0755 /var/www/html

install -m 0644 "$STAGE_DIR/nginx.conf" \
    /etc/nginx/nginx.conf

install -m 0644 "$STAGE_DIR/common-site.conf" \
    /etc/nginx/snippets/common-site.conf

# Remove package default virtual host, if present
rm -f /etc/nginx/conf.d/default.conf

# Generate default virtual host
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

    include /etc/nginx/snippets/common-site.conf;
}
EOF

chmod 0644 /etc/nginx/sites-available/default

ln -sfn /etc/nginx/sites-available/default \
    /etc/nginx/sites-enabled/default

# Add SSH authorized keys
echo "Adding SSH authorized keys..."

install -d -o root -g root -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

for key in "${SSH_KEYS[@]}"; do
    if ! grep -Fqx -- "$key" /root/.ssh/authorized_keys; then
        echo "$key" >> /root/.ssh/authorized_keys
        echo "Added: ${key##* }"
    else
        echo "Already exists: ${key##* }"
    fi
done

# Check Nginx configuration
echo "[7/8] Testing Nginx..."

nginx -t

systemctl enable nginx
systemctl restart nginx

# Configure firewall
echo "[8/8] Configuring UFW..."

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# SSH
if [[ "$SSH_ALL" == "true" ]]; then
    ufw allow 22/tcp
else
    [[ -n "$HOST_IPV4" ]] && ufw allow from "$HOST_IPV4" to any port 22 proto tcp
    [[ -n "$HOST_IPV6" ]] && ufw allow from "$HOST_IPV6" to any port 22 proto tcp

    for ip in "${SSH_EXTRA_IPS[@]}"; do
        ufw allow from "$ip" to any port 22 proto tcp
    done
fi

# HTTP / HTTPS
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 8443/udp

# Panel 8080
[[ -n "$HOST_IPV4" ]] && ufw allow from "$HOST_IPV4" to any port 8080 proto tcp
[[ -n "$HOST_IPV6" ]] && ufw allow from "$HOST_IPV6" to any port 8080 proto tcp

# SMTP 465
[[ -n "$HOST_IPV4" ]] && ufw allow from "$HOST_IPV4" to any port 465 proto tcp
[[ -n "$HOST_IPV6" ]] && ufw allow from "$HOST_IPV6" to any port 465 proto tcp

ufw --force enable

echo
echo "========================================"
echo " Remote setup completed successfully"
echo " Hostname: $(hostname)"
echo " Nginx: $(nginx -v 2>&1)"
echo "========================================"
REMOTE_SCRIPT

chmod 0700 "$LOCAL_TMP/remote-setup.sh"

# Transfer files
echo
echo "[2/5] Transferring configuration and certificates..."

scp_target \
    "$LOCAL_TMP/remote-setup.sh" \
    "$TEMPLATES_DIR/nginx.conf" \
    "$TEMPLATES_DIR/common-site.conf" \
    "$CERT_DIR/fullchain.pem" \
    "$CERT_DIR/privkey.pem"

# Run remote setup
echo
echo "[3/5] Starting remote installation..."

REMOTE_ARGS=()

REMOTE_ARGS+=("$DOMAIN" "$REMOTE_DIR" "$HOST_IPV4" "$HOST_IPV6" "$SSH_ALL")
REMOTE_ARGS+=("${#SSH_EXTRA_IPS[@]}")
REMOTE_ARGS+=("${SSH_EXTRA_IPS[@]}")
REMOTE_ARGS+=("${#SSH_KEYS[@]}")
REMOTE_ARGS+=("${SSH_KEYS[@]}")

REMOTE_ARGS_ESCAPED=""

for arg in "${REMOTE_ARGS[@]}"; do
    printf -v escaped '%q' "$arg"
    REMOTE_ARGS_ESCAPED+=" $escaped"
done

REMOTE_COMMAND="if [ \"\$(id -u)\" -eq 0 ]; then
    bash '$REMOTE_DIR/remote-setup.sh'$REMOTE_ARGS_ESCAPED
else
    sudo -S -p '' bash '$REMOTE_DIR/remote-setup.sh'$REMOTE_ARGS_ESCAPED
fi"

printf '%s\n' "$SSHPASS" | sshpass -e ssh "${SSH_OPTS[@]}" \
    "$SSH_DEST" "$REMOTE_COMMAND"

echo
echo "[4/5] Checking remote Nginx..."

ssh_target "nginx -t && systemctl is-active nginx"

echo
echo "[5/5] Cleaning up..."

echo
echo "========================================"
echo " BOOTSTRAP COMPLETED"
echo " Server: $TARGET_IP"
echo " Domain: $DOMAIN"
echo "========================================"
