#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SAVE_FILE="${SCRIPT_DIR}/last_ip.txt"

EXTERNAL_SERVER_URLS="${EXTERNAL_SERVER_URLS:-https://wphh.franckmuller.com/api/update-gate-ip https://wphh.franckmuller.com/dev/api/update-gate-ip}"
IP_API_URL="${IP_API_URL:-https://api.ipify.org}"
SAVE_FILE="${SAVE_FILE:-$DEFAULT_SAVE_FILE}"
DEVICE_ID="${DEVICE_ID:-$(hostname -s 2>/dev/null || hostname)}"
HOSTNAME_VALUE="$(hostname -f 2>/dev/null || hostname)"
AUTH_HEADER="${AUTH_HEADER:-}"
CURL_BIN="${CURL_BIN:-curl}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
MAX_TIME="${MAX_TIME:-20}"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

json_escape() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

ensure_requirements() {
    command -v "$CURL_BIN" >/dev/null 2>&1 || fail "curl is not installed."
    mkdir -p "$(dirname -- "$SAVE_FILE")"
}

load_server_urls() {
    local raw_urls="${EXTERNAL_SERVER_URLS//$'\n'/ }"
    read -r -a SERVER_URLS <<< "$raw_urls"
    [[ ${#SERVER_URLS[@]} -gt 0 ]] || fail "EXTERNAL_SERVER_URLS is empty."
}

get_current_ip() {
    "$CURL_BIN" -fsS \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$IP_API_URL"
}

get_last_ip() {
    if [[ -f "$SAVE_FILE" ]]; then
        tr -d '[:space:]' < "$SAVE_FILE"
    fi
}

update_last_ip() {
    local tmp_file
    tmp_file="$(mktemp "${SAVE_FILE}.tmp.XXXXXX")"
    printf '%s\n' "$1" > "$tmp_file"
    mv "$tmp_file" "$SAVE_FILE"
}

is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$ip" =~ ^[0-9A-Fa-f:]+$ ]]
}

build_payload() {
    local current_ip="$1"
    printf '{"ip":"%s","device_id":"%s","hostname":"%s"}' \
        "$(json_escape "$current_ip")" \
        "$(json_escape "$DEVICE_ID")" \
        "$(json_escape "$HOSTNAME_VALUE")"
}

is_success_status() {
    local status="$1"
    [[ "$status" =~ ^2[0-9][0-9]$ ]]
}

send_update() {
    local current_ip="$1"
    local payload="$2"
    local url
    local failed=0
    local http_status
    local curl_exit
    local curl_args=(
        -sS
        --connect-timeout "$CONNECT_TIMEOUT"
        --max-time "$MAX_TIME"
        -X POST
        -H "Content-Type: application/json"
        -d "$payload"
        -o /dev/null
        -w "%{http_code}"
    )

    if [[ -n "$AUTH_HEADER" ]]; then
        curl_args+=(-H "$AUTH_HEADER")
    fi

    for url in "${SERVER_URLS[@]}"; do
        if http_status="$("$CURL_BIN" "${curl_args[@]}" "$url")"; then
            if is_success_status "$http_status"; then
                log "Posted IP ${current_ip} to ${url} (HTTP ${http_status})"
            else
                log "POST to ${url} returned HTTP ${http_status}"
                failed=1
            fi
        else
            curl_exit=$?
            log "Failed to POST IP ${current_ip} to ${url} (curl exit ${curl_exit}, HTTP ${http_status:-000})"
            failed=1
        fi
    done

    return "$failed"
}

ensure_requirements
load_server_urls

current_ip="$(get_current_ip | tr -d '[:space:]')"
last_ip="$(get_last_ip)"

[[ -n "$current_ip" ]] || fail "Could not determine the current public IP."
is_valid_ip "$current_ip" || fail "Received an invalid IP address: ${current_ip}"

if [[ "$current_ip" == "$last_ip" ]]; then
    log "IP address is unchanged (${current_ip}); no update required."
    exit 0
fi

log "IP address changed from '${last_ip:-<none>}' to '${current_ip}'. Sending update."

payload="$(build_payload "$current_ip")"

if send_update "$current_ip" "$payload"; then
    update_last_ip "$current_ip"
    log "Saved ${current_ip} to ${SAVE_FILE}"
else
    fail "At least one update failed. The saved IP was left unchanged so the next run retries."
fi
