#!/usr/bin/env bash

check_system() {
    [[ "$EUID" -eq 0 ]] || die "Run this script as root."

    [[ -f /etc/os-release ]] || die "Cannot determine operating system."
    source /etc/os-release

    [[ "$ID" == "ubuntu" || "$ID" == "debian" ]] ||
        die "Only Ubuntu and Debian are supported."
}

update_system() {
    log "[1/2] Updating..."
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
            log "Added: ${key##* }"
        else
            log "Already exists: ${key##* }"
        fi
    done
}

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

die() {
    log "ERROR: $*" >&2
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

check_ssh_connection() {
    local error_file="$LOCAL_TMP/ssh_error.log"
    local answer

    if sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" "echo SSH connection successful" 2>"$error_file"; then
        return 0
    fi

    if grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" "$error_file"; then
        log "SSH host key has changed for $SSH_DEST."
        read -r -p "Remove the old host key and reconnect? [y/N]: " answer

        [[ "$answer" =~ ^[Yy]$ ]] || die "SSH host key verification failed."

        ssh-keygen -R "$SSH_DEST" >/dev/null ||
            die "Failed to remove the old SSH host key."

        sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_DEST" "echo SSH connection successful" ||
            die "SSH connection failed after removing the old host key."
    else
        cat "$error_file" >&2
        die "SSH connection failed."
    fi
}