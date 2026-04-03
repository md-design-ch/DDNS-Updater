#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="ddns-updater"
ARCHITECTURE="all"
MAINTAINER="${DEB_MAINTAINER:-MDSolutions Miljantejs}"
DESCRIPTION="Remote DDNS updater with systemd timer"
OUTPUT_DIR="${SCRIPT_DIR}/dist"
BUILD_STAGING_DIR=""
BUILD_ROOT=""

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
        "${SCRIPT_DIR}/ddns-updater.sh" \
        "${SCRIPT_DIR}/ddns-updater.env" \
        "${SCRIPT_DIR}/ddns-updater.service" \
        "${SCRIPT_DIR}/ddns-updater.timer" \
        "${SCRIPT_DIR}/README.md" \
        "${SCRIPT_DIR}/packaging/deb/postinst" \
        "${SCRIPT_DIR}/packaging/deb/prerm" \
        "${SCRIPT_DIR}/packaging/deb/postrm"
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

write_control_files() {
    local version="$1"

    cat > "${BUILD_ROOT}/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${version}
Section: net
Priority: optional
Architecture: ${ARCHITECTURE}
Maintainer: ${MAINTAINER}
Depends: bash, curl, systemd
Description: ${DESCRIPTION}
 DDNS updater that checks the host public IP and posts updates to
 configured HTTP endpoints. Includes a systemd oneshot service,
 minutely timer, and a ddns-updater CLI command.
EOF

    cat > "${BUILD_ROOT}/DEBIAN/conffiles" <<'EOF'
/etc/default/ddns-updater
EOF

    install -m 0755 "${SCRIPT_DIR}/packaging/deb/postinst" "${BUILD_ROOT}/DEBIAN/postinst"
    install -m 0755 "${SCRIPT_DIR}/packaging/deb/prerm" "${BUILD_ROOT}/DEBIAN/prerm"
    install -m 0755 "${SCRIPT_DIR}/packaging/deb/postrm" "${BUILD_ROOT}/DEBIAN/postrm"
}

populate_package_tree() {
    install -d -m 0755 \
        "${BUILD_ROOT}/DEBIAN" \
        "${BUILD_ROOT}/usr/bin" \
        "${BUILD_ROOT}/usr/lib/ddns-updater" \
        "${BUILD_ROOT}/lib/systemd/system" \
        "${BUILD_ROOT}/etc/default" \
        "${BUILD_ROOT}/usr/share/doc/${PACKAGE_NAME}"

    install -m 0755 "${SCRIPT_DIR}/ddns-updater.sh" "${BUILD_ROOT}/usr/lib/ddns-updater/ddns-updater.sh"
    ln -s ../lib/ddns-updater/ddns-updater.sh "${BUILD_ROOT}/usr/bin/ddns-updater"

    sed 's|^ExecStart=.*$|ExecStart=/usr/bin/ddns-updater run|' \
        "${SCRIPT_DIR}/ddns-updater.service" > "${BUILD_ROOT}/lib/systemd/system/ddns-updater.service"
    chmod 0644 "${BUILD_ROOT}/lib/systemd/system/ddns-updater.service"
    install -m 0644 "${SCRIPT_DIR}/ddns-updater.timer" "${BUILD_ROOT}/lib/systemd/system/ddns-updater.timer"
    install -m 0644 "${SCRIPT_DIR}/ddns-updater.env" "${BUILD_ROOT}/etc/default/ddns-updater"
    install -m 0644 "${SCRIPT_DIR}/README.md" "${BUILD_ROOT}/usr/share/doc/${PACKAGE_NAME}/README.md"
}

create_build_root() {
    BUILD_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${PACKAGE_NAME}-deb.XXXXXX")"
    BUILD_ROOT="${BUILD_STAGING_DIR}/${PACKAGE_NAME}"
}

cleanup_build_root() {
    if [[ -n "$BUILD_STAGING_DIR" && -d "$BUILD_STAGING_DIR" ]]; then
        rm -rf "$BUILD_STAGING_DIR"
    fi
}

build_package() {
    local version="$1"
    local output_file="${OUTPUT_DIR}/${PACKAGE_NAME}_${version}_${ARCHITECTURE}.deb"

    mkdir -p "${OUTPUT_DIR}"
    rm -f "$output_file"

    create_build_root

    populate_package_tree
    write_control_files "$version"

    dpkg-deb --root-owner-group --build "${BUILD_ROOT}" "$output_file" >/dev/null
    log "Built ${output_file}"
}

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: ./build-deb.sh

Builds a Debian package in ./dist using the current project files.

Optional environment variables:
  DEB_MAINTAINER   Override the package maintainer field
EOF
    exit 0
fi

require_tool dpkg-deb
require_tool sed
require_source_files
trap cleanup_build_root EXIT

VERSION="$(get_version)"
[[ -n "$VERSION" ]] || {
    log "Could not determine package version from ddns-updater.sh"
    exit 1
}

build_package "$VERSION"
