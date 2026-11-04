#!/usr/bin/env bash

check_ubuntu() {
    [[ $EUID -eq 0 ]] || { echo "This module must run as root."; return 1; }
    [[ -r /etc/os-release ]] || { echo "Cannot identify operating system."; return 1; }
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || { echo "This script supports Ubuntu only."; return 1; }
}

update_system() {
    echo "[1/2] Updating Ubuntu..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
}

install_ssh_keys() {
    local key
    echo "[2/2] Installing SSH authorized keys..."
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
