# shellcheck shell=bash
# a2tools shared library.
#
# Sourced by every a2tools entry script. Provides:
#   - canonical filesystem paths (config / state / cache / logs)
#   - a user-facing output channel (FD 3) that works with and without a TTY
#   - SQL helpers (safe quoting for the sqlite3 CLI)
#   - credential storage access (replaces the old fqdncredmgrd socket daemon)
#   - WAN IP detection (validated, cached in state - never touches /etc/environment)
#   - provider plugin resolution and loading
#   - request/response logging
#
# This file must NOT set shell options (set -e etc.) or traps: it is a library
# and must not mutate the calling script's execution environment.

# ---------------------------------------------------------------------------
# Path layout
# ---------------------------------------------------------------------------
# A2TOOLS_ROOT is the directory holding the entry scripts (lib/..):
#   installed: /usr/lib/a2tools        repo: <repo>/scripts
A2TOOLS_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# Shared data (templates, usage texts, SQL schemas)
if [ -d "$A2TOOLS_ROOT/share" ]; then
    A2TOOLS_SHARE="$A2TOOLS_ROOT/share"          # running from the repo
else
    A2TOOLS_SHARE="/usr/share/a2tools"           # installed
fi

A2TOOLS_ETC="/etc/a2tools"
A2TOOLS_STATE="/var/lib/a2tools"
A2TOOLS_CACHE_DIR="/var/cache/a2tools"
A2TOOLS_LOG_DIR="/var/log/a2tools"

DOMAINS_DB_PATH="$A2TOOLS_STATE/domains.db"
CREDS_DB_PATH="$A2TOOLS_STATE/creds.db"
DOMAIN_CONFIG_PATH="$A2TOOLS_ETC/domain.conf"
WAN_IP_STATE_FILE="$A2TOOLS_STATE/wan_ip"
LOG_FILE="$A2TOOLS_LOG_DIR/fqdnmgr.log"

# Provider plugins: local overrides in /etc take precedence over shipped ones.
A2TOOLS_PROVIDER_DIRS=("$A2TOOLS_ETC/providers" "$A2TOOLS_ROOT/providers")

# ---------------------------------------------------------------------------
# User-facing output channel (FD 3)
# ---------------------------------------------------------------------------
# Interactive progress/status output goes to FD 3:
#   - a TTY when one is available (so output survives command substitution and
#     certbot hook capture),
#   - stderr otherwise (cron, CI, certbot-without-tty) instead of failing.
if [ -z "${A2TOOLS_FD3_SET:-}" ]; then
    if { exec 3>/dev/tty; } 2>/dev/null; then
        A2TOOLS_HAS_TTY=true
    else
        exec 3>&2
        A2TOOLS_HAS_TTY=false
    fi
    A2TOOLS_FD3_SET=1
fi

# ui: unconditional user-facing message
ui() { printf '%s\n' "$*" >&3; }

# vecho: verbose-only user-facing message (callers set VERBOSE=true)
VERBOSE="${VERBOSE:-false}"
vecho() { [ "$VERBOSE" = true ] && printf '%s\n' "$*" >&3; return 0; }

# ---------------------------------------------------------------------------
# Logging (file-based, non-fatal on failure)
# ---------------------------------------------------------------------------
init_logging() {
    [ -d "$A2TOOLS_LOG_DIR" ] || mkdir -p "$A2TOOLS_LOG_DIR" 2>/dev/null || true
    if [ ! -f "$LOG_FILE" ]; then
        ( umask 027; touch "$LOG_FILE" 2>/dev/null ) || true
    fi
}

log_msg() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Log an outbound provider request. Callers are responsible for masking secrets.
log_request() {
    local provider="$1" request="$2"
    {
        printf '[%s] *** sent %s\n%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$provider" "$request"
    } >> "$LOG_FILE" 2>/dev/null || true
}

log_response() {
    local provider="$1" response="$2"
    {
        printf '[%s] *** response from %s\n%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$provider" "$response"
    } >> "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# SQL helpers
# ---------------------------------------------------------------------------
# Escape a value for interpolation inside single quotes in a sqlite3 statement.
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Run a statement against the domains DB.
db_domains() { sqlite3 "$DOMAINS_DB_PATH" "$@"; }

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.' octet
    read -ra _octets <<< "$ip"
    for octet in "${_octets[@]}"; do
        [ "$octet" -le 255 ] || return 1
    done
    return 0
}

# Validate a fully-qualified domain name.
# Rules: length <= 253, at least one dot, labels 1..63 chars of [A-Za-z0-9-]
# not starting/ending with '-', alphabetic TLD of >= 2 chars.
is_valid_fqdn() {
    local fqdn="$1"
    [ -n "$fqdn" ] || return 1
    [ ${#fqdn} -le 253 ] || return 1
    [[ "$fqdn" == *.* ]] || return 1
    local IFS='.' lab
    read -ra _labels <<< "$fqdn"
    for lab in "${_labels[@]}"; do
        [ ${#lab} -ge 1 ] && [ ${#lab} -le 63 ] || return 1
        [[ "$lab" =~ ^[A-Za-z0-9-]+$ ]] || return 1
        [[ "$lab" != -* && "$lab" != *- ]] || return 1
    done
    [[ "${_labels[$(( ${#_labels[@]} - 1 ))]}" =~ ^[A-Za-z]{2,}$ ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# WAN IP
# ---------------------------------------------------------------------------
# Resolution order: process environment -> state file -> public-IP lookup.
# The fetched value is strictly validated as an IPv4 address before being
# trusted or persisted. State lives in /var/lib/a2tools/wan_ip (root-only),
# never in /etc/environment.
#
# Public-IP lookup prefers DNS-based reflectors (Cloudflare/Google)
# over a plain HTTP endpoint: they reuse the already-required `dig` (dnsutils),
# are a long-standing standard technique, and are harder to tamper with than an
# arbitrary web service. The HTTPS endpoint is only a last-resort fallback and
# stays overridable via WAN_IP_LOOKUP_URL.
WAN_IP_LOOKUP_URL="${WAN_IP_LOOKUP_URL:-https://ifconfig.me/ip}"

# Reflect our public IPv4 back via authoritative resolvers. Prints a validated
# IPv4 on success (rc 0), nothing on failure (rc 1).
_wan_ip_from_dns() {
    command -v dig >/dev/null 2>&1 || return 1
    local ip

    # Cloudflare: CHAOS-class TXT reflector (value is quoted).
    ip=$(dig -4 +short +time=3 +tries=1 CH TXT whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"[:space:]')
    if is_valid_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi

    # Google: TXT reflector on the public resolver (value is quoted).
    ip=$(dig -4 +short +time=3 +tries=1 TXT o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null | tr -d '"[:space:]')
    if is_valid_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi

    return 1
}

# HTTPS fallback reflector. Prints a validated IPv4 on success, nothing on fail.
_wan_ip_from_https() {
    local ip
    ip="$(curl -fsS --max-time 10 "$WAN_IP_LOOKUP_URL" 2>/dev/null | tr -d '[:space:]')"
    if is_valid_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
    return 1
}

get_wan_ip() {
    # 1) process environment
    if [ -n "${WAN_IP:-}" ]; then
        if ! is_valid_ipv4 "$WAN_IP"; then
            echo "Error: WAN_IP environment value '$WAN_IP' is not a valid IPv4 address" >&2
            return 1
        fi
        export WAN_IP
        return 0
    fi

    # 2) state file
    if [ -f "$WAN_IP_STATE_FILE" ]; then
        WAN_IP="$(head -n1 "$WAN_IP_STATE_FILE" 2>/dev/null | tr -d '[:space:]')"
        if is_valid_ipv4 "$WAN_IP"; then
            export WAN_IP
            return 0
        fi
        WAN_IP=""
    fi

    # 3) public-IP lookup: DNS-based reflectors first, HTTPS as last resort.
    WAN_IP="$(_wan_ip_from_dns)" || WAN_IP="$(_wan_ip_from_https)" || WAN_IP=""
    if ! is_valid_ipv4 "$WAN_IP"; then
        WAN_IP=""
        echo "Error: Failed to determine WAN IP (DNS reflectors and HTTPS fallback $WAN_IP_LOOKUP_URL all failed or returned garbage)" >&2
        return 1
    fi

    # Cache for later runs (root only; ignore failure for non-root callers)
    if [ "$(id -u)" -eq 0 ]; then
        mkdir -p "$A2TOOLS_STATE" 2>/dev/null || true
        ( umask 077; printf '%s\n' "$WAN_IP" > "$WAN_IP_STATE_FILE" ) 2>/dev/null || true
    fi

    export WAN_IP
    return 0
}

# ---------------------------------------------------------------------------
# Credentials (direct DB access - replaces the fqdncredmgrd socket daemon)
# ---------------------------------------------------------------------------
# creds_get PROVIDER
#   On success: exports PROVIDER_USERNAME and PROVIDER_API_KEY, returns 0.
#   On failure: prints a machine-parsable CREDS_ERROR line on stdout and
#   returns a distinct status:
#     11 = no credentials for provider
#     12 = credentials database not found
#     15 = row exists but is incomplete
creds_get() {
    local provider="$1"

    if [ ! -f "$CREDS_DB_PATH" ]; then
        echo "CREDS_ERROR:database_not_found"
        return 12
    fi

    local row
    row=$(sqlite3 -separator '|' "$CREDS_DB_PATH" \
        "SELECT username, key FROM creds WHERE provider='$(sql_escape "$provider")' LIMIT 1;" 2>/dev/null)

    if [ -z "$row" ]; then
        echo "CREDS_ERROR:no_credentials:$provider"
        return 11
    fi

    PROVIDER_USERNAME="${row%%|*}"
    PROVIDER_API_KEY="${row#*|}"

    if [ -z "$PROVIDER_USERNAME" ] || [ -z "$PROVIDER_API_KEY" ]; then
        echo "CREDS_ERROR:incomplete_credentials:$provider"
        return 15
    fi

    export PROVIDER_USERNAME PROVIDER_API_KEY
    return 0
}

# has_creds_for PROVIDER: silent probe, 0 if usable credentials exist.
has_creds_for() {
    local provider="$1"
    [ -n "$provider" ] || return 1
    [ -f "$CREDS_DB_PATH" ] || return 1
    local n
    n=$(sqlite3 "$CREDS_DB_PATH" \
        "SELECT COUNT(1) FROM creds WHERE provider='$(sql_escape "$provider")' AND username != '' AND key != '';" 2>/dev/null)
    [ -n "$n" ] && [ "$n" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Provider plugins
# ---------------------------------------------------------------------------
# provider_file REGISTRAR: print path of the plugin file, 1 if not found.
provider_file() {
    local registrar="$1" dir
    for dir in "${A2TOOLS_PROVIDER_DIRS[@]}"; do
        if [ -f "$dir/${registrar}.provider" ]; then
            printf '%s\n' "$dir/${registrar}.provider"
            return 0
        fi
    done
    return 1
}

# list_providers: print available provider names (deduplicated), one per line.
list_providers() {
    local dir f
    {
        for dir in "${A2TOOLS_PROVIDER_DIRS[@]}"; do
            [ -d "$dir" ] || continue
            for f in "$dir"/*.provider; do
                [ -e "$f" ] || continue
                basename "$f" .provider
            done
        done
    } | sort -u
}

# _provider_source_safe FILE: guard against loading a tampered plugin.
# Provider plugins are sourced (executed) with the caller's privileges - root
# in production - so a plugin that is group/world-writable, or owned by an
# unexpected user, is a root code-execution vector. Accept files owned by root
# OR by the current user (so the repo/dev checkout still works) and reject any
# file writable by group or others. Requires GNU stat (Linux target).
_provider_source_safe() {
    local f="$1" meta uid mode
    # GNU stat (Linux target) with a BSD stat fallback so the repo/dev checkout
    # on macOS still works.
    meta=$(stat -c '%u %a' "$f" 2>/dev/null) || meta=$(stat -f '%u %Lp' "$f" 2>/dev/null) || return 1
    uid="${meta%% *}"
    mode="${meta##* }"
    [ -n "$uid" ] && [ -n "$mode" ] || return 1
    [ "$uid" = "0" ] || [ "$uid" = "$(id -u)" ] || return 1
    # 022 = group-write (020) | other-write (002); leading 0 forces octal.
    [ $(( 0${mode} & 022 )) -eq 0 ] || return 1
    return 0
}

# load_provider REGISTRAR: source the plugin into the current shell.
load_provider() {
    local registrar="$1" pfile
    if ! pfile=$(provider_file "$registrar"); then
        echo "Error: Provider file not found for '$registrar'" >&2
        echo "Available providers:" >&2
        list_providers >&2
        return 1
    fi
    if ! _provider_source_safe "$pfile"; then
        echo "Error: Refusing to load provider '$registrar': '$pfile' must be owned by root (or you) and not group/world-writable." >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$pfile"
}

init_logging
