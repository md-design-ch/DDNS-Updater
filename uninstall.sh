#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="ddns-updater.service"
TIMER_NAME="ddns-updater.timer"
INSTALL_DIR="/usr/local/lib/ddns-updater"
COMMAND_LINK="/usr/local/bin/ddns-updater"
CONFIG_DIR="/etc/default"
CONFIG_FILE="${CONFIG_DIR}/ddns-updater"
LEGACY_CONFIG_EXAMPLE_FILE="${CONFIG_DIR}/ddns-updater.example"
STATE_DIR="/var/lib/ddns-updater"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

show_manual_steps() {
    cat <<'EOF'
Manual uninstall:
1. Run: systemctl disable --now ddns-updater.timer
2. Run: systemctl stop ddns-updater.service
3. Delete /etc/systemd/system/ddns-updater.service
4. Delete /etc/systemd/system/ddns-updater.timer
5. Delete /usr/local/bin/ddns-updater
6. Delete /usr/local/lib/ddns-updater/ddns-updater.sh
7. Run: systemctl daemon-reload
8. Delete /etc/default/ddns-updater and /var/lib/ddns-updater
EOF
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log "This uninstaller must run as root."
        show_manual_steps
        exit 1
    fi
}

stop_units() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl is not available. Removing files without stopping units."
        return
    fi

    systemctl disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

remove_files() {
    rm -f "$SERVICE_PATH" "$TIMER_PATH" "$LEGACY_CONFIG_EXAMPLE_FILE"
    rm -f "$COMMAND_LINK"
    rm -rf "$INSTALL_DIR"
    rm -f "$CONFIG_FILE"
    rm -rf "$STATE_DIR"
}

reload_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return
    fi

    systemctl daemon-reload
    systemctl reset-failed >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: sudo ./uninstall.sh

Removes the ddns-updater command, script, systemd units, config, and state.
EOF
    exit 0
fi

if [[ -n "${1:-}" ]]; then
    log "Unknown option: ${1}"
    exit 1
fi

require_root
stop_units
remove_files
reload_systemd

log "Uninstall complete. Config and state were removed."
