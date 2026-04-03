#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="ddns-updater"
OUTPUT_DIR="${SCRIPT_DIR}/dist"
ARCHIVE_ROOT="DDNS-Updater"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        log "Required tool is missing: $1"
        exit 1
    }
}

require_source_files() {
    local required_file
    for required_file in \
        "${SCRIPT_DIR}/README.md" \
        "${SCRIPT_DIR}/ddns-updater.env" \
        "${SCRIPT_DIR}/ddns-updater.service" \
        "${SCRIPT_DIR}/ddns-updater.sh" \
        "${SCRIPT_DIR}/ddns-updater.timer" \
        "${SCRIPT_DIR}/install.sh" \
        "${SCRIPT_DIR}/uninstall.sh"
    do
        [[ -f "$required_file" ]] || {
            log "Required file is missing: ${required_file}"
            exit 1
        }
    done
}

get_version() {
    sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "${SCRIPT_DIR}/ddns-updater.sh" | head -n 1
}

build_archive() {
    local version="$1"
    local output_file="${OUTPUT_DIR}/${PACKAGE_NAME}_${version}_linux.tar.gz"

    mkdir -p "$OUTPUT_DIR"
    rm -f "$output_file"

    tar -czf "$output_file" \
        --transform="s,^,${ARCHIVE_ROOT}/," \
        -C "$SCRIPT_DIR" \
        README.md \
        ddns-updater.env \
        ddns-updater.service \
        ddns-updater.sh \
        ddns-updater.timer \
        install.sh \
        uninstall.sh

    log "Built ${output_file}"
}

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./build-tar.sh

Builds a clean tar.gz archive in ./dist containing the runtime files only.
The archive can be used for either automatic installation with install.sh
or manual installation following the README.
EOF
    exit 0
fi

require_tool tar
require_tool sed
require_source_files

VERSION="$(get_version)"
[[ -n "$VERSION" ]] || {
    log "Could not determine archive version from ddns-updater.sh"
    exit 1
}

build_archive "$VERSION"
