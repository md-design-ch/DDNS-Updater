#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="ddns-updater.service"
TIMER_NAME="ddns-updater.timer"
INSTALL_DIR="/usr/local/lib/ddns-updater"
CONFIG_DIR="/etc/default"
CONFIG_FILE="${CONFIG_DIR}/ddns-updater"
CONFIG_SOURCE_FILE="${SCRIPT_DIR}/ddns-updater.env"
LEGACY_CONFIG_EXAMPLE_FILE="${CONFIG_DIR}/ddns-updater.example"
STATE_DIR="/var/lib/ddns-updater"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_source_files() {
    local required_file
    for required_file in \
        "${SCRIPT_DIR}/ddns-updater.sh" \
        "${SCRIPT_DIR}/ddns-updater.service" \
        "${SCRIPT_DIR}/ddns-updater.timer" \
        "$CONFIG_SOURCE_FILE"
    do
        [[ -f "$required_file" ]] || {
            log "Required file is missing: ${required_file}"
            exit 1
        }
    done
}

show_manual_steps() {
    cat <<'EOF'
Manual installation:
1. Install curl using your package manager.
2. Copy ddns-updater.sh to /usr/local/lib/ddns-updater/ddns-updater.sh and make it executable.
3. Copy ddns-updater.service to /etc/systemd/system/ddns-updater.service.
4. Copy ddns-updater.timer to /etc/systemd/system/ddns-updater.timer.
5. Copy ddns-updater.env to /etc/default/ddns-updater.
6. Create /var/lib/ddns-updater.
7. Run: systemctl daemon-reload
8. Run: systemctl enable --now ddns-updater.timer
EOF
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log "This installer must run as root."
        show_manual_steps
        exit 1
    fi
}

install_curl() {
    if command -v curl >/dev/null 2>&1; then
        log "curl is already installed."
        return
    fi

    log "curl is missing. Installing it."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y curl
        return
    fi

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y curl
        return
    fi

    if command -v yum >/dev/null 2>&1; then
        yum install -y curl
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl
        return
    fi

    if command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install curl
        return
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl
        return
    fi

    log "No supported package manager was found to install curl automatically."
    show_manual_steps
    exit 1
}

install_files() {
    install -d -m 0755 "$INSTALL_DIR" "$STATE_DIR" "$CONFIG_DIR"
    install -m 0755 "${SCRIPT_DIR}/ddns-updater.sh" "${INSTALL_DIR}/ddns-updater.sh"
    install -m 0644 "${SCRIPT_DIR}/ddns-updater.service" "$SERVICE_PATH"
    install -m 0644 "${SCRIPT_DIR}/ddns-updater.timer" "$TIMER_PATH"
    rm -f "$LEGACY_CONFIG_EXAMPLE_FILE"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        install -m 0644 "$CONFIG_SOURCE_FILE" "$CONFIG_FILE"
        log "Installed config to ${CONFIG_FILE}"
    else
        log "Keeping existing config at ${CONFIG_FILE}"
    fi
}

enable_timer() {
    command -v systemctl >/dev/null 2>&1 || {
        log "systemctl is not available on this system."
        show_manual_steps
        exit 1
    }

    systemctl daemon-reload
    systemctl enable --now "$TIMER_NAME"
}

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: sudo ./install.sh

Installs curl if needed, installs the DDNS updater script and systemd units,
and enables the timer that runs every minute.

Use the checked-in files directly if you prefer a manual installation.
EOF
    exit 0
fi

require_root
require_source_files
install_curl
install_files
enable_timer

log "Installation complete."
log "Review ${CONFIG_FILE} if you need to change server URLs, headers, or the device ID."
