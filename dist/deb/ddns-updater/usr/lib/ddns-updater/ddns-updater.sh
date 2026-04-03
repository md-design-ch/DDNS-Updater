#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
DEFAULT_SAVE_FILE="${SCRIPT_DIR}/last_ip.txt"
DEFAULT_CONFIG_FILE="/etc/default/ddns-updater"
LOCAL_CONFIG_FILE="${SCRIPT_DIR}/ddns-updater.env"
VERSION="0.1"

CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
HOSTNAME_VALUE="$(hostname -f 2>/dev/null || hostname)"

CONFIG_VARS=(
    EXTERNAL_SERVER_URLS
    IP_API_URL
    SAVE_FILE
    DEVICE_ID
    AUTH_HEADER
    CURL_BIN
    CONNECT_TIMEOUT
    MAX_TIME
)

declare -A SAVED_ENV_PRESENT=()
declare -A SAVED_ENV_VALUE=()
declare -a SERVER_URLS=()

LAST_SUCCESS_COUNT=0
LAST_ENDPOINT_COUNT=0

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

load_config_file() {
    local var_name

    if [[ ! -f "$CONFIG_FILE" && -f "$LOCAL_CONFIG_FILE" ]]; then
        CONFIG_FILE="$LOCAL_CONFIG_FILE"
    fi

    for var_name in "${CONFIG_VARS[@]}"; do
        if [[ ${!var_name+x} ]]; then
            SAVED_ENV_PRESENT["$var_name"]=1
            SAVED_ENV_VALUE["$var_name"]="${!var_name}"
        fi
    done

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        set -a
        . "$CONFIG_FILE"
        set +a
    fi

    for var_name in "${CONFIG_VARS[@]}"; do
        if [[ ${SAVED_ENV_PRESENT[$var_name]:-0} -eq 1 ]]; then
            printf -v "$var_name" '%s' "${SAVED_ENV_VALUE[$var_name]}"
            export "$var_name"
        fi
    done
}

apply_defaults() {
    EXTERNAL_SERVER_URLS="${EXTERNAL_SERVER_URLS-https://wphh.franckmuller.com/api/update-gate-ip https://wphh.franckmuller.com/dev/api/update-gate-ip}"
    IP_API_URL="${IP_API_URL-https://api.ipify.org}"
    SAVE_FILE="${SAVE_FILE-$DEFAULT_SAVE_FILE}"
    DEVICE_ID="${DEVICE_ID-$(hostname -s 2>/dev/null || hostname)}"
    AUTH_HEADER="${AUTH_HEADER-}"
    CURL_BIN="${CURL_BIN-curl}"
    CONNECT_TIMEOUT="${CONNECT_TIMEOUT-10}"
    MAX_TIME="${MAX_TIME-20}"
}

json_escape() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

shell_escape_double_quoted() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"
    value="${value//\`/\\\`}"
    printf '%s' "$value"
}

ensure_curl() {
    command -v "$CURL_BIN" >/dev/null 2>&1 || fail "curl is not installed."
}

ensure_state_dir() {
    mkdir -p "$(dirname -- "$SAVE_FILE")"
}

ensure_config_writable() {
    local config_dir
    config_dir="$(dirname -- "$CONFIG_FILE")"

    if [[ -f "$CONFIG_FILE" && ! -w "$CONFIG_FILE" ]]; then
        fail "Config file is not writable: ${CONFIG_FILE}. Re-run with sudo."
    fi

    if [[ ! -f "$CONFIG_FILE" && ! -w "$config_dir" ]]; then
        fail "Config directory is not writable: ${config_dir}. Re-run with sudo."
    fi
}

write_config_var() {
    local key="$1"
    local value="$2"
    local replacement
    local tmp_file
    local line
    local updated=0

    ensure_config_writable
    mkdir -p "$(dirname -- "$CONFIG_FILE")"

    replacement="${key}=\"$(shell_escape_double_quoted "$value")\""
    tmp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"

    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "${key}="* ]]; then
                if (( updated == 0 )); then
                    printf '%s\n' "$replacement" >> "$tmp_file"
                    updated=1
                fi
            else
                printf '%s\n' "$line" >> "$tmp_file"
            fi
        done < "$CONFIG_FILE"
    fi

    if (( updated == 0 )); then
        if [[ -s "$tmp_file" ]]; then
            printf '\n' >> "$tmp_file"
        fi
        printf '%s\n' "$replacement" >> "$tmp_file"
    fi

    mv "$tmp_file" "$CONFIG_FILE"
}

parse_server_urls() {
    local raw_urls="${EXTERNAL_SERVER_URLS//$'\n'/ }"
    read -r -a SERVER_URLS <<< "$raw_urls"
}

load_server_urls() {
    parse_server_urls
    [[ ${#SERVER_URLS[@]} -gt 0 ]] || fail "EXTERNAL_SERVER_URLS is empty."
}

persist_server_urls() {
    local joined_urls=""
    local url

    for url in "${SERVER_URLS[@]}"; do
        if [[ -n "$joined_urls" ]]; then
            joined_urls+=" "
        fi
        joined_urls+="$url"
    done

    EXTERNAL_SERVER_URLS="$joined_urls"
    write_config_var "EXTERNAL_SERVER_URLS" "$EXTERNAL_SERVER_URLS"
}

get_current_ip() {
    "$CURL_BIN" -fsS \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$IP_API_URL"
}

resolve_current_ip() {
    local current_ip
    current_ip="$(get_current_ip | tr -d '[:space:]')"
    [[ -n "$current_ip" ]] || fail "Could not determine the current public IP."
    is_valid_ip "$current_ip" || fail "Received an invalid IP address: ${current_ip}"
    printf '%s' "$current_ip"
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
    local success_count=0
    local endpoint_count=0
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
        endpoint_count=$((endpoint_count + 1))

        if http_status="$("$CURL_BIN" "${curl_args[@]}" "$url")"; then
            if is_success_status "$http_status"; then
                log "Posted IP ${current_ip} to ${url} (HTTP ${http_status})"
                success_count=$((success_count + 1))
            else
                log "POST to ${url} returned HTTP ${http_status}"
            fi
        else
            curl_exit=$?
            log "Failed to POST IP ${current_ip} to ${url} (curl exit ${curl_exit}, HTTP ${http_status:-000})"
        fi
    done

    LAST_SUCCESS_COUNT=$success_count
    LAST_ENDPOINT_COUNT=$endpoint_count

    if (( success_count > 0 )); then
        log "${success_count}/${endpoint_count} endpoint(s) accepted the IP update."
        return 0
    fi

    log "No endpoint accepted the IP update. The saved IP was left unchanged so the next run retries."
    return 1
}

run_update() {
    local current_ip
    local last_ip
    local payload

    ensure_curl
    ensure_state_dir
    load_server_urls

    current_ip="$(resolve_current_ip)"
    last_ip="$(get_last_ip)"

    if [[ "$current_ip" == "$last_ip" ]]; then
        log "IP address is unchanged (${current_ip}); no update required."
        return 0
    fi

    log "IP address changed from '${last_ip:-<none>}' to '${current_ip}'. Sending update."

    payload="$(build_payload "$current_ip")"

    if send_update "$current_ip" "$payload"; then
        update_last_ip "$current_ip"
        log "Saved ${current_ip} to ${SAVE_FILE}"
    fi
}

test_connection_cmd() {
    local current_ip

    ensure_curl
    current_ip="$(resolve_current_ip)"

    printf 'Config file: %s\n' "$CONFIG_FILE"
    printf 'Public IP API: %s\n' "$IP_API_URL"
    printf 'Public IP: %s\n' "$current_ip"
}

test_endpoints_cmd() {
    local current_ip
    local payload

    ensure_curl
    load_server_urls
    current_ip="$(resolve_current_ip)"
    payload="$(build_payload "$current_ip")"

    printf 'Testing %s endpoint(s) with IP %s\n' "${#SERVER_URLS[@]}" "$current_ip"

    if send_update "$current_ip" "$payload"; then
        return 0
    fi

    return 1
}

list_urls_cmd() {
    parse_server_urls

    printf 'Config file: %s\n' "$CONFIG_FILE"
    printf 'Configured endpoint URL(s):\n'
    if [[ ${#SERVER_URLS[@]} -eq 0 ]]; then
        printf '(none)\n'
        return 0
    fi

    printf '%s\n' "${SERVER_URLS[@]}"
}

add_url_cmd() {
    local url="${1:-}"
    local existing_url

    [[ -n "$url" ]] || fail "Usage: ddns-updater add-url <url>"
    parse_server_urls

    for existing_url in "${SERVER_URLS[@]}"; do
        if [[ "$existing_url" == "$url" ]]; then
            log "URL already exists in ${CONFIG_FILE}: ${url}"
            return 0
        fi
    done

    SERVER_URLS+=("$url")
    persist_server_urls
    log "Added URL to ${CONFIG_FILE}: ${url}"
}

remove_url_cmd() {
    local url="${1:-}"
    local existing_url
    local removed=0
    local remaining_urls=()

    [[ -n "$url" ]] || fail "Usage: ddns-updater remove-url <url>"
    parse_server_urls

    for existing_url in "${SERVER_URLS[@]}"; do
        if [[ "$existing_url" == "$url" ]]; then
            removed=1
            continue
        fi
        remaining_urls+=("$existing_url")
    done

    if (( removed == 0 )); then
        log "URL not present in ${CONFIG_FILE}: ${url}"
        return 0
    fi

    SERVER_URLS=("${remaining_urls[@]}")
    persist_server_urls
    log "Removed URL from ${CONFIG_FILE}: ${url}"
}

report_ok() {
    printf 'OK: %s\n' "$*"
}

report_warn() {
    printf 'WARN: %s\n' "$*"
}

report_fail() {
    printf 'FAIL: %s\n' "$*"
}

doctor_cmd() {
    local failures=0
    local warnings=0
    local timer_enabled
    local timer_active
    local service_result
    local next_elapse
    local command_path
    local configured_urls

    ensure_curl

    if command_path="$(command -v ddns-updater 2>/dev/null)"; then
        report_ok "ddns-updater command is available at ${command_path}"
    else
        report_fail "ddns-updater command is not on PATH"
        failures=$((failures + 1))
    fi

    if [[ -x "/usr/local/lib/ddns-updater/ddns-updater.sh" ]]; then
        report_ok "installed script exists at /usr/local/lib/ddns-updater/ddns-updater.sh"
    else
        report_fail "installed script is missing at /usr/local/lib/ddns-updater/ddns-updater.sh"
        failures=$((failures + 1))
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        report_ok "config file exists at ${CONFIG_FILE}"
    else
        report_fail "config file is missing at ${CONFIG_FILE}"
        failures=$((failures + 1))
    fi

    configured_urls="${EXTERNAL_SERVER_URLS//$'\n'/ }"
    read -r -a SERVER_URLS <<< "$configured_urls"
    if [[ ${#SERVER_URLS[@]} -gt 0 ]]; then
        report_ok "${#SERVER_URLS[@]} endpoint URL(s) configured"
    else
        report_warn "no endpoint URLs are configured"
        warnings=$((warnings + 1))
    fi

    if [[ -d "$(dirname -- "$SAVE_FILE")" ]]; then
        report_ok "state directory exists at $(dirname -- "$SAVE_FILE")"
    else
        report_warn "state directory does not exist yet at $(dirname -- "$SAVE_FILE")"
        warnings=$((warnings + 1))
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        report_fail "systemctl is not available on this system"
        failures=$((failures + 1))
    else
        if systemctl cat ddns-updater.service >/dev/null 2>&1; then
            report_ok "systemd service ddns-updater.service is installed"
        else
            report_fail "systemd service ddns-updater.service is not installed"
            failures=$((failures + 1))
        fi

        if systemctl cat ddns-updater.timer >/dev/null 2>&1; then
            report_ok "systemd timer ddns-updater.timer is installed"
        else
            report_fail "systemd timer ddns-updater.timer is not installed"
            failures=$((failures + 1))
        fi

        timer_enabled="$(systemctl is-enabled ddns-updater.timer 2>/dev/null || true)"
        if [[ "$timer_enabled" == "enabled" ]]; then
            report_ok "ddns-updater.timer is enabled"
        else
            report_fail "ddns-updater.timer is not enabled (${timer_enabled:-unknown})"
            failures=$((failures + 1))
        fi

        timer_active="$(systemctl is-active ddns-updater.timer 2>/dev/null || true)"
        if [[ "$timer_active" == "active" ]]; then
            report_ok "ddns-updater.timer is active"
        else
            report_fail "ddns-updater.timer is not active (${timer_active:-unknown})"
            failures=$((failures + 1))
        fi

        next_elapse="$(systemctl show ddns-updater.timer --property=NextElapseUSecRealtime --value 2>/dev/null || true)"
        if [[ -n "$next_elapse" && "$next_elapse" != "n/a" ]]; then
            report_ok "next timer elapse is scheduled"
        else
            report_warn "next timer elapse is not currently scheduled"
            warnings=$((warnings + 1))
        fi

        service_result="$(systemctl show ddns-updater.service --property=Result --value 2>/dev/null || true)"
        case "$service_result" in
            ""|"success")
                report_ok "last service result is ${service_result:-success}"
                ;;
            *)
                report_warn "last service result is ${service_result}"
                warnings=$((warnings + 1))
                ;;
        esac
    fi

    printf 'Summary: %s failure(s), %s warning(s)\n' "$failures" "$warnings"

    if (( failures > 0 )); then
        return 1
    fi

    return 0
}

version_cmd() {
    printf 'ddns-updater %s\n' "$VERSION"
}

show_help() {
    cat <<EOF
Usage: ddns-updater <command>

Commands:
  run               Check the current public IP and post updates if it changed
  test-connection   Verify curl and public-IP lookup connectivity
  test-endpoints    POST a test payload to all configured endpoints
  list-urls         Show configured EXTERNAL_SERVER_URLS
  add-url           Add one endpoint URL to EXTERNAL_SERVER_URLS
  remove-url        Remove one endpoint URL from EXTERNAL_SERVER_URLS
  doctor            Check whether the installed command, config, timer, and service are operational
  version           Show the installed version
  help              Show this help text

Examples:
  ddns-updater run
  ddns-updater test-connection
  ddns-updater test-endpoints
  ddns-updater list-urls
  sudo ddns-updater add-url https://example.com/api/update-gate-ip
  sudo ddns-updater remove-url https://example.com/api/update-gate-ip
  ddns-updater doctor
  ddns-updater version
EOF
}

main() {
    local command="${1:-run}"

    load_config_file
    apply_defaults

    case "$command" in
        run)
            run_update
            ;;
        test-connection)
            test_connection_cmd
            ;;
        test-endpoints)
            test_endpoints_cmd
            ;;
        list-urls|list-endpoints)
            list_urls_cmd
            ;;
        add-url|add-endpoint)
            add_url_cmd "${2:-}"
            ;;
        remove-url|remove-endpoint)
            remove_url_cmd "${2:-}"
            ;;
        doctor|check|status)
            doctor_cmd
            ;;
        version|--version|-v)
            version_cmd
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            fail "Unknown command: ${command}"
            ;;
    esac
}

main "$@"
