#!/usr/bin/env bash

check_system() {
    [[ "$EUID" -eq 0 ]] || die "Run this script as root."

    [[ -f /etc/os-release ]] || die "Cannot determine operating system."
    source /etc/os-release

    [[ "$ID" == "ubuntu" || "$ID" == "debian" ]] ||
        die "Only Ubuntu and Debian are supported."
}

update_system() {
    log "[1/2] Updating Ubuntu..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
}

install_ssh_keys() {
    local key
    log "[2/2] Installing SSH authorized keys..."
    install -d -o root -g root -m 0700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chown root:root /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys

    for key in "${SSH_KEYS[@]}"; do
        if ! grep -Fqx -- "$key" /root/.ssh/authorized_keys; then
            printf '%s\n' "$key" >> /root/.ssh/authorized_keys
            echo "Added: ${key##* }"
        else
            echo "Already exists: ${key##* }"
        fi
    done
}

log() {
    echo
    echo "[$(date '+%H:%M:%S')] $*"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

check_domain_ip() {
    local domain="$1"
    local ipv4="$2"
    local dns_ipv4=()

    [[ -n "$ipv4" ]] || die "Server IPv4 is not specified."

    mapfile -t dns_ipv4 < <(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u)

    printf '%s\n' "${dns_ipv4[@]}" | grep -Fxq "$ipv4" || {
        die "Domain $domain does not resolve to server IPv4 $ipv4."
    }

    log "Domain $domain correctly resolves to $ipv4."
}

get_public_ipv4() {
    curl -4fsS --max-time 10 https://api.ipify.org || return 1
}

get_public_ipv6() {
    curl -6fsS --max-time 10 https://api6.ipify.org 2>/dev/null || true
}

# ========================================
# DEPENDENCY CHECKS
# ========================================

ensure_dependencies() {
    local missing=()
    local packages=("$@")

    for package in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
            grep -q "install ok installed" || missing+=("$package")
    done

    ((${#missing[@]})) || return 0

    log "Installing missing dependencies: ${missing[*]}"

    if [[ $EUID -eq 0 ]]; then
        apt-get update
        apt-get install -y "${missing[@]}"
    elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    else
        die "Root privileges or sudo are required to install dependencies."
    fi
}