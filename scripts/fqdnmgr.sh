#!/bin/bash
# fqdnmgr - provision domains: registrar status checks, purchases, DNS record
# management and ACME DNS-01 challenge hooks for certbot.
#
# Provider plugins are sourced from /etc/a2tools/providers (local overrides)
# or /usr/lib/a2tools/providers (shipped). Credentials come from the root-only
# SQLite DB managed by fqdncredmgr (see lib/common.sh: creds_get).

A2TOOLS_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
. "$A2TOOLS_SELF_DIR/lib/common.sh"

# =============================================================================
# Centralized cache
# =============================================================================
# Root-owned cache in /var/cache (NOT /tmp: a predictable world-writable path
# would let any local user poison NS/propagation entries read by root).
# Format: type domain value timestamp [extra...]
# Types: whois_* (1h TTL), ns (2h TTL), dns_change (48h TTL), ap (never expires)
A2TOOLS_CACHE_FILE="$A2TOOLS_CACHE_DIR/a2tools.cache"
# Advisory lock serializing cache read-modify-write across concurrent runs
# (e.g. certbot firing hooks in parallel). See _with_cache_lock.
A2TOOLS_CACHE_LOCK="$A2TOOLS_CACHE_DIR/.a2tools.cache.lock"

CACHE_TTL_WHOIS=3600         # 1 hour
CACHE_TTL_NS=7200            # 2 hours
CACHE_TTL_DNS_CHANGE=172800  # 48 hours
CACHE_TTL_AP=-1              # never expires (average propagation time)

# Default average propagation time in seconds (fallback when no history)
DEFAULT_AVG_PROPAGATION=120

# Minimum interval between propagation checks (seconds)
MIN_CHECK_INTERVAL=10

init_cache() {
    [ -d "$A2TOOLS_CACHE_DIR" ] || mkdir -p "$A2TOOLS_CACHE_DIR" 2>/dev/null || true
    if [ ! -f "$A2TOOLS_CACHE_FILE" ]; then
        ( umask 027; touch "$A2TOOLS_CACHE_FILE" 2>/dev/null ) || true
    fi
}

# _with_cache_lock CMD [ARGS...]: run CMD holding an exclusive flock so two
# concurrent processes never clobber each other's cache rewrite (grep>tmp;mv).
# Degrades to running unlocked if flock is unavailable.
_with_cache_lock() {
    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 9 2>/dev/null || true
            "$@"
        ) 9>"$A2TOOLS_CACHE_LOCK"
    else
        "$@"
    fi
}

_cache_ttl_for() {
    case "$1" in
        whois_registrar|whois_available) echo "$CACHE_TTL_WHOIS" ;;
        ns)         echo "$CACHE_TTL_NS" ;;
        dns_change) echo "$CACHE_TTL_DNS_CHANGE" ;;
        ap)         echo "$CACHE_TTL_AP" ;;
        *)          echo 3600 ;;
    esac
}

# Garbage collection: remove expired entries
cleanup_expired_cache() {
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 0
    [ -w "$A2TOOLS_CACHE_FILE" ] || return 0
    _with_cache_lock _cleanup_expired_cache_locked
}
_cleanup_expired_cache_locked() {
    local now_ts tmp_file
    now_ts=$(date +%s)
    tmp_file="${A2TOOLS_CACHE_FILE}.tmp.$$"

    while IFS=' ' read -r type domain value timestamp rest; do
        [ -z "$type" ] && continue
        local ttl
        ttl=$(_cache_ttl_for "$type")
        if [ "$ttl" -eq -1 ] || [ $((now_ts - timestamp)) -lt "$ttl" ] 2>/dev/null; then
            echo "$type $domain $value $timestamp $rest"
        fi
    done < "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null
    mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

# cache_get <type> <key> -> value on stdout, 0 if found and valid
cache_get() {
    local type="$1" domain="$2"
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 1
    local now_ts ttl
    now_ts=$(date +%s)
    ttl=$(_cache_ttl_for "$type")

    local found_value="" found_ts=0
    while IFS=' ' read -r etype edomain evalue etimestamp erest; do
        if [ "$etype" = "$type" ] && [ "$edomain" = "$domain" ]; then
            if [ "$etimestamp" -gt "$found_ts" ] 2>/dev/null; then
                found_value="$evalue"
                found_ts="$etimestamp"
            fi
        fi
    done < "$A2TOOLS_CACHE_FILE"

    if [ -n "$found_value" ]; then
        if [ "$ttl" -eq -1 ] || [ $((now_ts - found_ts)) -lt "$ttl" ]; then
            echo "$found_value"
            return 0
        fi
    fi
    return 1
}

# cache_set <type> <key> <value>
cache_set() {
    local type="$1" domain="$2" value="$3"
    init_cache
    _with_cache_lock _cache_set_locked "$type" "$domain" "$value"
}
_cache_set_locked() {
    local type="$1" domain="$2" value="$3" now_ts
    now_ts=$(date +%s)
    if [ -f "$A2TOOLS_CACHE_FILE" ] && [ -w "$A2TOOLS_CACHE_FILE" ]; then
        local tmp_file="${A2TOOLS_CACHE_FILE}.tmp.$$"
        grep -v -- "^${type} ${domain} " "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
    fi
    echo "$type $domain $value $now_ts" >> "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

init_cache
cleanup_expired_cache

# Helper: cached authoritative NS for a domain using SOA MNAME.
# Ensures consistent NS selection across checks (avoids round-robin noise).
get_cached_ns() {
    local domain="$1" cached_ns ns_server

    if cached_ns=$(cache_get "ns" "$domain"); then
        echo "$cached_ns"
        return 0
    fi

    ns_server=$(dig +short SOA "$domain" | awk '{print $1}')
    if [ -z "$ns_server" ]; then
        ns_server=$(dig +short NS "$domain" | sort | head -1)
    fi

    if [ -n "$ns_server" ]; then
        cache_set "ns" "$domain" "$ns_server"
        echo "$ns_server"
        return 0
    fi
    return 1
}

# =============================================================================
# DNS change tracking and adaptive propagation timing
# =============================================================================

# Record when a DNS record was set.
# Cache line: dns_change <domain>:<type>:<host>:<value> <set_ts> <cache_ts>
cache_set_dns_change() {
    local domain="$1" record_type="$2" host="$3" value="$4"
    init_cache
    _with_cache_lock _cache_set_dns_change_locked "$domain" "$record_type" "$host" "$value"
}
_cache_set_dns_change_locked() {
    local domain="$1" record_type="$2" host="$3" value="$4" now_ts
    now_ts=$(date +%s)
    local cache_key="${domain}:${record_type}:${host}:${value}"
    if [ -f "$A2TOOLS_CACHE_FILE" ] && [ -w "$A2TOOLS_CACHE_FILE" ]; then
        local tmp_file="${A2TOOLS_CACHE_FILE}.tmp.$$"
        grep -v -- "^dns_change ${cache_key} " "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
    fi
    echo "dns_change $cache_key $now_ts $now_ts" >> "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

# cache_get_dns_change <domain> <type> <host> <value> -> set_timestamp
cache_get_dns_change() {
    local domain="$1" record_type="$2" host="$3" value="$4"
    local cache_key="${domain}:${record_type}:${host}:${value}"
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 1
    local now_ts
    now_ts=$(date +%s)

    local found_set_ts="" found_cache_ts=0
    while IFS=' ' read -r etype ekey eset_ts ecache_ts erest; do
        if [ "$etype" = "dns_change" ] && [ "$ekey" = "$cache_key" ]; then
            if [ "$ecache_ts" -gt "$found_cache_ts" ] 2>/dev/null; then
                found_set_ts="$eset_ts"
                found_cache_ts="$ecache_ts"
            fi
        fi
    done < "$A2TOOLS_CACHE_FILE"

    if [ -n "$found_set_ts" ] && [ $((now_ts - found_cache_ts)) -lt "$CACHE_TTL_DNS_CHANGE" ]; then
        echo "$found_set_ts"
        return 0
    fi
    return 1
}

cache_delete_dns_change() {
    local domain="$1" record_type="$2" host="$3" value="$4"
    local cache_key="${domain}:${record_type}:${host}:${value}"
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 0
    [ -w "$A2TOOLS_CACHE_FILE" ] || return 0
    _with_cache_lock _cache_delete_dns_change_locked "$cache_key"
}
_cache_delete_dns_change_locked() {
    local cache_key="$1"
    local tmp_file="${A2TOOLS_CACHE_FILE}.tmp.$$"
    grep -v -- "^dns_change ${cache_key} " "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

# cache_get_ap <ns_server> -> average propagation seconds
cache_get_ap() {
    local ns_server="$1"
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 1
    local found_value=""
    while IFS=' ' read -r etype ens evalue etimestamp erest; do
        if [ "$etype" = "ap" ] && [ "$ens" = "$ns_server" ]; then
            found_value="$evalue"
        fi
    done < "$A2TOOLS_CACHE_FILE"
    if [ -n "$found_value" ]; then
        echo "$found_value"
        return 0
    fi
    return 1
}

cache_set_ap() {
    local ns_server="$1" avg_seconds="$2"
    init_cache
    _with_cache_lock _cache_set_ap_locked "$ns_server" "$avg_seconds"
}
_cache_set_ap_locked() {
    local ns_server="$1" avg_seconds="$2" now_ts
    now_ts=$(date +%s)
    if [ -f "$A2TOOLS_CACHE_FILE" ] && [ -w "$A2TOOLS_CACHE_FILE" ]; then
        local tmp_file="${A2TOOLS_CACHE_FILE}.tmp.$$"
        grep -v -- "^ap ${ns_server} " "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
    fi
    echo "ap $ns_server $avg_seconds $now_ts" >> "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

# get_avg_propagation_time <ns_server> [registrar]
# Lookup order: 1) cache, 2) domain.conf (AVG_PROPAGATION_TIME_<registrar>),
# 3) hardcoded default. Always succeeds.
get_avg_propagation_time() {
    local ns_server="$1" registrar="${2:-}" avg

    if avg=$(cache_get_ap "$ns_server"); then
        echo "$avg"
        return 0
    fi

    if [ -n "$registrar" ]; then
        local registrar_normalized="${registrar//./_}"
        local config_var="AVG_PROPAGATION_TIME_${registrar_normalized}"
        if [ -n "${!config_var:-}" ]; then
            echo "${!config_var}"
            return 0
        fi
    fi

    echo "$DEFAULT_AVG_PROPAGATION"
    return 0
}

# calculate_next_wait <ns_server> <first_check_ts>
# Formula: max(MIN_CHECK_INTERVAL, (avg - elapsed) / 2)
calculate_next_wait() {
    local ns_server="$1" first_check_ts="$2" now_ts
    now_ts=$(date +%s)

    local avg_propagation
    avg_propagation=$(get_avg_propagation_time "$ns_server")

    local remaining=$((avg_propagation + first_check_ts - now_ts))
    local next_wait=$((remaining / 2))

    [ "$next_wait" -lt "$MIN_CHECK_INTERVAL" ] && next_wait=$MIN_CHECK_INTERVAL
    echo "$next_wait"
}

# update_avg_propagation_time <ns_server> <actual_seconds>
# new_avg = (previous_avg + actual) / 2, or actual on first measurement.
update_avg_propagation_time() {
    local ns_server="$1" actual_seconds="$2" new_avg prev_avg
    if prev_avg=$(cache_get_ap "$ns_server"); then
        new_avg=$(( (prev_avg + actual_seconds) / 2 ))
    else
        new_avg="$actual_seconds"
    fi
    cache_set_ap "$ns_server" "$new_avg"
    vecho "  Updated average propagation time for $ns_server: ${new_avg}s"
}

# =============================================================================
# Unified DNS wait status output (FD 3 = tty when available, stderr otherwise)
# =============================================================================

# print_dns_wait_status <domain> <phase> <avg> <next_check_in> <elapsed> <timeout> [mode]
# mode "up" (default) rewrites the previous line; "inline" just reprints.
print_dns_wait_status() {
    local domain="$1" phase="$2" avg="$3" next_check_in="$4" elapsed="$5" timeout="$6"
    local mode="${7:-up}"

    local status_line
    if [ -z "$next_check_in" ] || [ "$next_check_in" -eq 0 ] 2>/dev/null; then
        status_line=$(printf '  %s: [%s] [avg: %ds | elapsed: %ds | timeout: %ds]' \
            "$domain" "$phase" "$avg" "$elapsed" "$timeout")
    else
        status_line=$(printf '  %s: [%s] [avg: %ds | next: %ds | elapsed: %ds | timeout: %ds]' \
            "$domain" "$phase" "$avg" "$next_check_in" "$elapsed" "$timeout")
    fi

    if [ "$A2TOOLS_HAS_TTY" = true ] && [ "$mode" = "up" ]; then
        printf '\033[1A\r\033[K%s\n' "$status_line" >&3
    elif [ "$A2TOOLS_HAS_TTY" = true ]; then
        printf '\r\033[K%s\n' "$status_line" >&3
    else
        printf '%s\n' "$status_line" >&3
    fi
}

# Rewrite/print a status line without cursor-up (parallel mode / final states)
print_status_line() {
    local line="$1" mode="${2:-inline}"
    if [ "$A2TOOLS_HAS_TTY" = true ] && [ "$mode" = "up" ]; then
        printf '\033[1A\r\033[K%b\n' "$line" >&3
    elif [ "$A2TOOLS_HAS_TTY" = true ]; then
        printf '\r\033[K%b\n' "$line" >&3
    else
        printf '%b\n' "$line" >&3
    fi
}

# =============================================================================
# Modes / configuration
# =============================================================================

NON_INTERACTIVE=false

# Load domain configuration (TLD priority lists, propagation averages, ...)
load_domain_config() {
    if [ -f "$DOMAIN_CONFIG_PATH" ]; then
        # shellcheck disable=SC1090
        . "$DOMAIN_CONFIG_PATH"
    fi
}
load_domain_config

get_tld() { echo "${1##*.}"; }

# Check TLD priority list for a registrar with stored credentials.
check_tld_priority() {
    local fqdn="$1" tld
    tld=$(get_tld "$fqdn")

    local var_name="TLD_PRIORITY_${tld}"
    local registrar_list="${!var_name:-}"
    if [ -z "$registrar_list" ]; then
        echo ""
        return 1
    fi

    local IFS=',' registrar
    for registrar in $registrar_list; do
        registrar=$(echo "$registrar" | xargs)
        if [ -n "$registrar" ] && has_creds_for "$registrar"; then
            echo "$registrar"
            return 0
        fi
    done

    echo ""
    return 1
}

# =============================================================================
# Credentials / providers
# =============================================================================

# get_credentials REGISTRAR
# exit-on-failure wrapper around creds_get so hooks (certify/cleanup) abort
# with distinct exit codes that a2sitemgr can map to actionable messages:
#   11=no credentials, 12=creds DB missing, 15=incomplete row
get_credentials() {
    local registrar="$1"
    creds_get "$registrar" || exit $?
}

usage() {
    local exit_code="${1:-1}"
    local usage_file="$A2TOOLS_SHARE/usage/fqdnmgr.txt"
    if [ ! -f "$usage_file" ]; then
        echo "Error: usage file not found: $usage_file" >&2
        exit 1
    fi
    cat "$usage_file"
    list_providers | sed 's/^/  - /'
    exit "$exit_code"
}

# Common initialization for certify and cleanup
init_provider_for_dns_operation() {
    local registrar="$1"

    if [ -z "${CERTBOT_DOMAIN:-}" ]; then
        echo "Error: CERTBOT_DOMAIN environment variable not set" >&2
        exit 1
    fi
    if [ -z "${CERTBOT_VALIDATION:-}" ]; then
        echo "Error: CERTBOT_VALIDATION environment variable not set" >&2
        exit 1
    fi

    get_credentials "$registrar"
    load_provider "$registrar" || exit 1

    if ! get_wan_ip; then
        exit 1
    fi
}

# =============================================================================
# certify / cleanup / purchase
# =============================================================================

certify() {
    local registrar="$1"
    init_provider_for_dns_operation "$registrar"

    # Show challenge progress from certbot environment variables
    if [ "$VERBOSE" = true ] && [ -n "${CERTBOT_ALL_DOMAINS:-}" ]; then
        local total_challenges remaining current_challenge
        total_challenges=$(echo "$CERTBOT_ALL_DOMAINS" | tr ',' '\n' | wc -l | tr -d ' ')
        remaining=${CERTBOT_REMAINING_CHALLENGES:-0}
        current_challenge=$((total_challenges - remaining))
        ui "=== ACME Challenge $current_challenge of $total_challenges: $CERTBOT_DOMAIN ==="
    fi

    # If the TXT record is already present at the authoritative NS, skip the
    # provider call AND the propagation check (a 0s measurement would corrupt
    # the propagation average).
    local ns_server acme_domain existing_txt
    ns_server=$(get_cached_ns "$CERTBOT_DOMAIN")
    acme_domain="_acme-challenge.$CERTBOT_DOMAIN"
    existing_txt=$(dig +short @"$ns_server" "$acme_domain" TXT 2>/dev/null | tr -d '"')

    if [ -n "$existing_txt" ] && echo "$existing_txt" | grep -qF "$CERTBOT_VALIDATION"; then
        vecho "TXT record already set for $CERTBOT_DOMAIN at $ns_server. Skipping."
        return 0
    fi

    provider_certify "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION" "$WAN_IP"

    cache_set_dns_change "$CERTBOT_DOMAIN" "TXT" "_acme-challenge" "$CERTBOT_VALIDATION"

    check_dns_propagation "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION"
}

cleanup() {
    local registrar="$1"
    init_provider_for_dns_operation "$registrar"
    provider_cleanup "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION" "$WAN_IP"
}

purchase() {
    local fqdn="$1" registrar="$2"

    get_credentials "$registrar"
    load_provider "$registrar" || exit 1

    export FQDN="$fqdn"

    provider_purchase "$fqdn"
    local result=$?

    if [ $result -eq 0 ]; then
        save_domain_status "$fqdn" "owned" "$registrar"
    fi

    # 0=success, 1=insufficient balance, 2=other error
    exit $result
}

# =============================================================================
# Domains DB helpers
# =============================================================================

ensure_domains_db() {
    if [ ! -f "$DOMAINS_DB_PATH" ]; then
        echo "Error: Domains DB $DOMAINS_DB_PATH not found. Reinstall a2tools to initialize it." >&2
        exit 1
    fi
}

get_local_domain_status() {
    local domain="$1"
    ensure_domains_db
    db_domains "SELECT status, registrar FROM domains WHERE domain='$(sql_escape "$domain")' LIMIT 1;" 2>/dev/null
}

# Ownership checks resolve to the base domain (left-most label stripped).
get_effective_ownership_domain() {
    local domain="$1"
    if [[ "$domain" =~ ^[^.]+\.(.+\..+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$domain"
    fi
}

# Upsert status. Only final statuses ('owned', 'free', 'taken') are persisted.
save_domain_status() {
    local domain="$1" status="$2" registrar="$3" effective_domain
    effective_domain=$(get_effective_ownership_domain "$domain")
    ensure_domains_db

    if [ "$status" = "owned" ] || [ "$status" = "free" ] || [ "$status" = "taken" ]; then
        local d r
        d=$(sql_escape "$effective_domain")
        r=$(sql_escape "$registrar")
        db_domains "INSERT INTO domains (domain, status, registrar)
                    VALUES ('$d', '$status', CASE WHEN '$r' = '' THEN NULL ELSE '$r' END)
                    ON CONFLICT(domain) DO UPDATE SET status=excluded.status, registrar=excluded.registrar;" 2>/dev/null
    fi
}

# update_domain_cert_dns_info DOMAIN CERT_DATE DNS_INIT
update_domain_cert_dns_info() {
    local domain="$1" cert_date="$2" dns_init="$3"
    ensure_domains_db

    local sql_updates=()
    [ -n "$cert_date" ] && sql_updates+=("cert_date='$(sql_escape "$cert_date")'")
    if [ -n "$dns_init" ] && [[ "$dns_init" =~ ^[01]$ ]]; then
        sql_updates+=("dns_init=$dns_init")
    fi
    [ ${#sql_updates[@]} -eq 0 ] && return 0

    local update_clause
    update_clause=$(IFS=,; echo "${sql_updates[*]}")
    db_domains "UPDATE domains SET $update_clause WHERE domain='$(sql_escape "$domain")';" 2>/dev/null || true
}

has_local_certificate() {
    [ -d "/etc/letsencrypt/live/$1" ]
}

# Parse `certbot certificates` output -> lines of domain|issue_date|expiry_date
parse_certbot_certificates() {
    command -v certbot >/dev/null 2>&1 || return 1

    local certbot_output
    certbot_output=$(certbot certificates 2>/dev/null || true)
    [ -n "$certbot_output" ] || return 1

    local current_domain="" current_expiry="" line
    while IFS= read -r line; do
        if echo "$line" | grep -q "Certificate Name:"; then
            current_domain=$(echo "$line" | sed 's/.*Certificate Name: //' | tr -d ' ')
        elif echo "$line" | grep -q "Expiry Date:"; then
            current_expiry=$(echo "$line" | sed 's/.*Expiry Date: //' | awk '{print $1}')
            if [ -n "$current_domain" ] && [ -n "$current_expiry" ]; then
                # Let's Encrypt certs are valid 90 days; derive the issue date.
                local issue_date
                if date --version 2>&1 | grep -q "GNU"; then
                    issue_date=$(date -d "$current_expiry - 90 days" +%Y-%m-%d 2>/dev/null || echo "")
                else
                    issue_date=$(date -v-90d -j -f "%Y-%m-%d" "$current_expiry" +%Y-%m-%d 2>/dev/null || echo "")
                fi
                [ -n "$issue_date" ] && echo "$current_domain|$issue_date|$current_expiry"
                current_domain=""
                current_expiry=""
            fi
        fi
    done <<< "$certbot_output"
    return 0
}

check_domain_dns_initialized() {
    local domain="$1" wan_ip="$2"
    check_init_dns_propagation_quick "$domain" "$wan_ip" 2>/dev/null
}

# =============================================================================
# WHOIS / registrar detection
# =============================================================================

# get_whois_info DOMAIN
# Sets globals: WHOIS_REGISTRAR (normalized), WHOIS_AVAILABLE (true/false).
# Only extracted values are cached (1h TTL), never raw WHOIS output.
get_whois_info() {
    local domain="$1"
    WHOIS_REGISTRAR=""
    WHOIS_AVAILABLE="false"

    local cached_registrar cached_available
    if cached_registrar=$(cache_get "whois_registrar" "$domain"); then
        [ "$cached_registrar" = "_none_" ] && cached_registrar=""
        WHOIS_REGISTRAR="$cached_registrar"
        cached_available=$(cache_get "whois_available" "$domain") || cached_available="false"
        WHOIS_AVAILABLE="$cached_available"
        return 0
    fi

    command -v whois >/dev/null 2>&1 || return 1

    local out
    out=$(whois "$domain" 2>/dev/null || true)
    [ -n "$out" ] || return 1

    if echo "$out" | grep -qi "No match for"; then
        WHOIS_AVAILABLE="true"
        WHOIS_REGISTRAR=""
    else
        WHOIS_AVAILABLE="false"
        local raw_registrar
        raw_registrar=$(echo "$out" | grep -i '^registrar:' | head -n1 | \
            sed -E 's/^[Rr]egistrar:[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')
        WHOIS_REGISTRAR=$(normalize_registrar "$raw_registrar")
    fi

    cache_set "whois_registrar" "$domain" "${WHOIS_REGISTRAR:-_none_}"
    cache_set "whois_available" "$domain" "$WHOIS_AVAILABLE"
    return 0
}

# Normalize registrar name to the canonical form used for provider files.
normalize_registrar() {
    local raw="$1" lower
    lower=$(echo "$raw" | tr '[:upper:]' '[:lower:]')

    if [[ "$lower" =~ namecheap ]]; then
        echo "namecheap.com"
    elif [[ "$lower" =~ godaddy ]]; then
        echo "godaddy"
    elif [[ "$lower" =~ wedos ]]; then
        echo "wedos.com"
    elif [[ "$lower" =~ cloudflare ]]; then
        echo "cloudflare"
    elif [[ "$lower" =~ google ]]; then
        echo "google"
    elif [[ "$lower" =~ aws|amazon|route.?53 ]]; then
        echo "aws"
    elif [[ "$lower" =~ gandi ]]; then
        echo "gandi"
    elif [[ "$lower" =~ hover ]]; then
        echo "hover"
    elif [[ "$lower" =~ dynadot ]]; then
        echo "dynadot"
    elif [[ "$lower" =~ porkbun ]]; then
        echo "porkbun"
    elif [[ "$lower" =~ name\.com|name,?.inc ]]; then
        echo "name.com"
    elif [[ "$lower" =~ ionos|1and1|1\&1 ]]; then
        echo "ionos"
    elif [[ "$lower" =~ ovh ]]; then
        echo "ovh"
    elif [ -n "$raw" ]; then
        echo "$lower" | sed 's/[^a-z0-9.-]//g'
    else
        echo ""
    fi
}

# decision_evaluate WHOIS_NORM PROVIDED_NORM [FQDN]
# Centralized registrar/credential decision making.
# Outputs (globals): DECISION_ACTION, DECISION_REGISTRAR
# Actions: use_tld_priority, use_whois, use_provided, prompt_provided,
#          prompt_whois, prompt_mismatch, check_provided, unknown_stdout
decision_evaluate() {
    local whois_norm="$1" provided_norm="$2" fqdn_for_tld="$3"

    DECISION_ACTION=""
    DECISION_REGISTRAR=""

    # Case A: WHOIS empty, registrar not provided => TLD priority, else unknown
    if [ -z "$whois_norm" ] && [ -z "$provided_norm" ]; then
        if [ -n "$fqdn_for_tld" ]; then
            local tld_registrar
            tld_registrar=$(check_tld_priority "$fqdn_for_tld")
            if [ -n "$tld_registrar" ]; then
                DECISION_ACTION="use_tld_priority"
                DECISION_REGISTRAR="$tld_registrar"
                return 0
            fi
        fi
        DECISION_ACTION="unknown_stdout"
        return 0
    fi

    # Case B: WHOIS empty, registrar provided => check creds for provided
    if [ -z "$whois_norm" ] && [ -n "$provided_norm" ]; then
        if has_creds_for "$provided_norm"; then
            DECISION_ACTION="use_provided"
            DECISION_REGISTRAR="$provided_norm"
        elif [ "$VERBOSE" = true ]; then
            DECISION_ACTION="prompt_provided"
            DECISION_REGISTRAR="$provided_norm"
        else
            DECISION_ACTION="unknown_stdout"
        fi
        return 0
    fi

    # Case C: WHOIS not empty, registrar not provided
    if [ -n "$whois_norm" ] && [ -z "$provided_norm" ]; then
        if has_creds_for "$whois_norm"; then
            DECISION_ACTION="use_whois"
            DECISION_REGISTRAR="$whois_norm"
        elif [ "$VERBOSE" = true ]; then
            DECISION_ACTION="prompt_whois"
            DECISION_REGISTRAR="$whois_norm"
        else
            DECISION_ACTION="unknown_stdout"
        fi
        return 0
    fi

    # Case D: both present
    if [ "$whois_norm" = "$provided_norm" ]; then
        if has_creds_for "$whois_norm"; then
            DECISION_ACTION="use_whois"
            DECISION_REGISTRAR="$whois_norm"
        elif [ "$VERBOSE" = true ]; then
            DECISION_ACTION="prompt_whois"
            DECISION_REGISTRAR="$whois_norm"
        else
            DECISION_ACTION="unknown_stdout"
        fi
        return 0
    fi

    # Mismatch: prioritize the WHOIS registrar
    if has_creds_for "$whois_norm"; then
        DECISION_ACTION="use_whois"
        DECISION_REGISTRAR="$whois_norm"
        return 0
    fi

    if [ "$VERBOSE" = true ]; then
        DECISION_ACTION="prompt_mismatch"
        DECISION_REGISTRAR="$whois_norm"
    else
        DECISION_ACTION="check_provided"
        DECISION_REGISTRAR="$provided_norm"
    fi
    return 0
}

# detect_registrar_for_domain FQDN -> registrar name or empty
detect_registrar_for_domain() {
    local fqdn="$1" check_output

    if [ "$VERBOSE" = true ]; then
        vecho "Detecting registrar for $fqdn..."
        check_output=$("$0" check "$fqdn" -v 2>&1)
        local check_exit=$?
        [ $check_exit -ne 0 ] && vecho "Warning: check command failed with exit code $check_exit"
    else
        check_output=$(check_status "$fqdn" 2>/dev/null)
    fi

    local detected_registrar
    detected_registrar=$(echo "$check_output" | grep -oE 'registrar=[^ ]+' | cut -d'=' -f2)

    if [ -z "$detected_registrar" ]; then
        vecho "Debug: Failed to detect registrar for $fqdn"
        vecho "Debug: check_status output: $check_output"
    fi

    echo "$detected_registrar"
}

# =============================================================================
# Interactive credential prompts (deduplicated)
# =============================================================================

# prompt_store_creds REGISTRAR
# Interactively collect a username + API key and store them via fqdncredmgr
# (key passed over stdin, never argv). Returns 0 if stored.
prompt_store_creds() {
    local registrar="$1" new_username new_api_key
    read -r -p "Enter API username for '$registrar': " new_username
    read -r -s -p "Enter API key for '$registrar': " new_api_key
    echo ""
    if [ -z "$new_username" ] || [ -z "$new_api_key" ]; then
        echo "Error: Username and API key are required" >&2
        return 1
    fi
    if ! command -v fqdncredmgr >/dev/null 2>&1; then
        echo "Error: fqdncredmgr command not found" >&2
        return 1
    fi
    if printf '%s\n' "$new_api_key" | fqdncredmgr add "$registrar" "$new_username" -p -; then
        echo "Credentials added. Re-run 'fqdnmgr check' to check ownership."
        return 0
    fi
    echo "Error: Failed to add credentials" >&2
    return 1
}

# prompt_add_creds_or_unknown REGISTRAR [LABEL]
# Two-way prompt used whenever a registrar lacks credentials.
prompt_add_creds_or_unknown() {
    local registrar="$1" label="${2:-}"
    echo ""
    echo "No credentials found for ${label:+$label }'$registrar'. Choose an action:"
    echo "  1) Add credentials for '$registrar' now"
    echo "  2) Save as 'unknown' (do not persist)"
    local user_choice
    read -r -p "Enter choice [1/2]: " user_choice
    case "$user_choice" in
        1) prompt_store_creds "$registrar" || true ;;
        *) : ;;
    esac
}

# =============================================================================
# setInitDNSRecords
# =============================================================================

# process_single_domain_init FQDN HINT_REGISTRAR SYNC_MODE OVERRIDE_MODE [MAX_WAIT]
# Returns: 0=success, 1=error. Sets LAST_DOMAIN_STATUS for reporting.
process_single_domain_init() {
    local fqdn="$1" hint_registrar="$2" sync_mode="$3" override_mode="$4"
    local max_wait="${5:-600}"

    LAST_DOMAIN_STATUS="error"

    local detected_registrar actual_registrar=""
    detected_registrar=$(detect_registrar_for_domain "$fqdn")

    if [ -n "$detected_registrar" ]; then
        actual_registrar="$detected_registrar"
        if [ -n "$hint_registrar" ] && [ "$hint_registrar" != "$detected_registrar" ]; then
            vecho "Warning: Domain $fqdn is at $detected_registrar, not $hint_registrar"
        fi
    elif [ -n "$hint_registrar" ]; then
        actual_registrar="$hint_registrar"
    else
        vecho "Error: Could not determine registrar for $fqdn"
        LAST_DOMAIN_STATUS="no-registrar"
        return 1
    fi

    actual_registrar=$(normalize_registrar "$actual_registrar")
    if [ -z "$actual_registrar" ]; then
        vecho "Error: Could not normalize registrar for $fqdn"
        LAST_DOMAIN_STATUS="no-registrar"
        return 1
    fi

    if ! creds_get "$actual_registrar" >/dev/null; then
        echo "Error: No credentials for registrar $actual_registrar" >&2
        LAST_DOMAIN_STATUS="no-credentials"
        return 1
    fi

    if ! load_provider "$actual_registrar"; then
        echo "Error: Failed to load provider $actual_registrar" >&2
        LAST_DOMAIN_STATUS="provider-error"
        return 1
    fi

    if ! get_wan_ip; then
        vecho "Error: Failed to determine WAN IP"
        LAST_DOMAIN_STATUS="wan-ip-error"
        return 1
    fi

    # Check whether the records are already correct at the authoritative NS.
    # Prevents false re-setting which would corrupt propagation timing data.
    local ns_server dns_already_set=true
    ns_server=$(get_cached_ns "$fqdn")

    local a_root_check a_wildcard_check mx_check
    a_root_check=$(dig +short @"$ns_server" "$fqdn" A 2>/dev/null)
    if [ -z "$a_root_check" ] || ! echo "$a_root_check" | grep -qF "$WAN_IP"; then
        dns_already_set=false
    fi
    if [ "$dns_already_set" = true ]; then
        a_wildcard_check=$(dig +short @"$ns_server" "wildcard-test.${fqdn}" A 2>/dev/null)
        if [ -z "$a_wildcard_check" ] || ! echo "$a_wildcard_check" | grep -qF "$WAN_IP"; then
            dns_already_set=false
        fi
    fi
    if [ "$dns_already_set" = true ]; then
        mx_check=$(dig +short @"$ns_server" "$fqdn" MX 2>/dev/null)
        if [ -z "$mx_check" ] || ! echo "$mx_check" | grep -qF "mail.${fqdn}"; then
            dns_already_set=false
        fi
    fi

    if [ "$dns_already_set" = true ] && [ "$override_mode" != "override" ]; then
        vecho "DNS records already correctly set for $fqdn at $ns_server. Skipping provider call."
        LAST_DOMAIN_STATUS="success"
        return 0
    fi

    local skip_propagation_check=false
    if [ "$dns_already_set" = true ] && [ "$override_mode" = "override" ]; then
        vecho "DNS records already set for $fqdn, but override mode requested. Re-setting records..."
        skip_propagation_check=true
    else
        vecho "Setting init DNS records for $fqdn via $actual_registrar..."
    fi

    log_msg "[provider-call] $actual_registrar provider_set_init_dns_records $fqdn override=${override_mode:-false}"
    vecho "Invoking provider_set_init_dns_records for $fqdn via $actual_registrar (wan=$WAN_IP, override=${override_mode:-false})"

    provider_set_init_dns_records "$fqdn" "$WAN_IP" "" "$override_mode"
    local result=$?
    if [ $result -ne 0 ]; then
        LAST_DOMAIN_STATUS="api-error"
        return 1
    fi

    if [ "$skip_propagation_check" != true ]; then
        cache_set_dns_change "$fqdn" "A" "@" "$WAN_IP"
        cache_set_dns_change "$fqdn" "A" "*" "$WAN_IP"
        cache_set_dns_change "$fqdn" "MX" "@" "mail.${fqdn}"
    fi

    if [ "$skip_propagation_check" = true ]; then
        vecho "DNS records already propagated for $fqdn. Skipping propagation check."
        LAST_DOMAIN_STATUS="success"
        return 0
    fi

    # Sync mode: wait for DNS propagation with adaptive timing
    if [ "$sync_mode" = "sync" ]; then
        local elapsed=0 avg_propagation first_check_ts is_first_check=true

        avg_propagation=$(get_avg_propagation_time "$ns_server" "$actual_registrar")

        ui "Waiting for DNS propagation (timeout: ${max_wait}s)..."
        vecho "  [NS: $ns_server] average propagation time: ${avg_propagation}s"

        # Reuse the change timestamp when resuming after a script restart.
        first_check_ts=$(cache_get_dns_change "$fqdn" "A" "@" "$WAN_IP" 2>/dev/null) || first_check_ts=$(date +%s)

        ui "  $fqdn: [Init DNS] checking..."

        while [ $elapsed -lt "$max_wait" ]; do
            if check_init_dns_propagation "$fqdn" "$WAN_IP" "$elapsed" "$avg_propagation" "$max_wait"; then
                print_status_line "  $fqdn: \033[32mPROPAGATED\033[0m (${elapsed}s)" "up"
                vecho "DNS propagation complete for $fqdn."

                local now_ts actual_propagation
                now_ts=$(date +%s)
                actual_propagation=$((now_ts - first_check_ts))
                update_avg_propagation_time "$ns_server" "$actual_propagation"

                cache_delete_dns_change "$fqdn" "A" "@" "$WAN_IP"
                cache_delete_dns_change "$fqdn" "A" "*" "$WAN_IP"
                cache_delete_dns_change "$fqdn" "MX" "@" "mail.${fqdn}"

                # Re-set records with production TTL (7200s)
                vecho "Updating TTL to 7200s for production use..."
                log_msg "[provider-call] $actual_registrar provider_set_init_dns_records $fqdn ttl=7200 override=${override_mode:-false}"
                provider_set_init_dns_records "$fqdn" "$WAN_IP" 7200 "$override_mode"

                LAST_DOMAIN_STATUS="success"
                return 0
            fi

            [ "$is_first_check" = true ] && is_first_check=false

            local wait_interval
            wait_interval=$(calculate_next_wait "$ns_server" "$first_check_ts")
            if [ $((elapsed + wait_interval)) -gt "$max_wait" ]; then
                wait_interval=$((max_wait - elapsed))
                [ "$wait_interval" -le 0 ] && break
            fi

            if [ "$A2TOOLS_HAS_TTY" = true ]; then
                local countdown=$wait_interval
                while [ $countdown -gt 0 ]; do
                    local current_elapsed=$((elapsed + (wait_interval - countdown)))
                    print_dns_wait_status "$fqdn" "Init DNS" "$avg_propagation" "$countdown" "$current_elapsed" "$max_wait"
                    sleep 1
                    countdown=$((countdown - 1))
                done
            else
                print_dns_wait_status "$fqdn" "Init DNS" "$avg_propagation" "$wait_interval" "$elapsed" "$max_wait"
                sleep "$wait_interval"
            fi

            elapsed=$((elapsed + wait_interval))
        done

        print_status_line "  $fqdn: \033[31mTIMEOUT\033[0m (${max_wait}s)" "up"
        vecho "Warning: DNS propagation timed out for $fqdn"
        LAST_DOMAIN_STATUS="timeout"
        return 1
    fi

    LAST_DOMAIN_STATUS="success"
    return 0
}

# setInitDNSRecords [-d "DOMAIN(S)"] [-r REGISTRAR] [-o] [--sync] [--timeout SECONDS]
setInitDNSRecords() {
    local domains_arg="" registrar_arg="" sync_mode="" override_mode="" timeout_arg="600"

    while [ $# -gt 0 ]; do
        case "$1" in
            -d) shift; domains_arg="$1" ;;
            -r) shift; registrar_arg="$1" ;;
            -o) override_mode="override" ;;
            --sync) sync_mode="sync" ;;
            --timeout)
                shift
                if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; then
                    timeout_arg="$1"
                else
                    echo "Error: --timeout requires a positive integer (seconds)" >&2
                    return 1
                fi
                ;;
            -*)
                echo "Error: Unknown argument '$1'" >&2
                echo "Usage: setInitDNSRecords [-d \"DOMAIN(S)\"] [-r REGISTRAR] [-o] [--sync] [--timeout SECONDS]" >&2
                return 1
                ;;
            *)
                if [ -z "$domains_arg" ]; then
                    domains_arg="$1"
                else
                    domains_arg="$domains_arg $1"
                fi
                ;;
        esac
        shift
    done

    if [ -z "$domains_arg" ] && [ -z "$registrar_arg" ]; then
        echo "Error: At least one of -d or -r is required" >&2
        echo "Usage: setInitDNSRecords [-d \"DOMAIN(S)\"] [-r REGISTRAR] [-o] [--sync] [--timeout SECONDS]" >&2
        return 1
    fi

    local registrar_norm=""
    [ -n "$registrar_arg" ] && registrar_norm=$(normalize_registrar "$registrar_arg")

    local -a domain_results=()
    local success_count=0 total_count=0

    if [ -n "$domains_arg" ]; then
        # MODE: specific domain(s) via -d, -r is a hint
        read -ra DOMAINS_TO_PROCESS <<< "$domains_arg"
        total_count=${#DOMAINS_TO_PROCESS[@]}

        local domain
        for domain in "${DOMAINS_TO_PROCESS[@]}"; do
            if ! is_valid_fqdn "$domain"; then
                echo "Error: Invalid domain '$domain' - skipping" >&2
                domain_results+=("$domain:invalid")
                continue
            fi
        done

        vecho "Processing $total_count domain(s)..."

        for domain in "${DOMAINS_TO_PROCESS[@]}"; do
            is_valid_fqdn "$domain" || continue
            process_single_domain_init "$domain" "$registrar_norm" "$sync_mode" "$override_mode" "$timeout_arg"
            local result=$?
            domain_results+=("$domain:$LAST_DOMAIN_STATUS")
            [ $result -eq 0 ] && ((success_count++))
        done
    else
        # MODE: all owned domains at the registrar
        creds_get "$registrar_norm"
        local creds_rc=$?
        [ $creds_rc -ne 0 ] && return $creds_rc
        load_provider "$registrar_norm" || return 1

        if ! get_wan_ip; then
            echo "Error: Failed to determine WAN IP" >&2
            return 1
        fi

        vecho "Fetching owned domains from $registrar_norm..."
        if [ "$VERBOSE" = true ]; then
            provider_list_owned_domains "$WAN_IP" "$override_mode" >/dev/null
        else
            provider_list_owned_domains "$WAN_IP" "$override_mode"
        fi
        local list_result=$?

        if [ $list_result -eq 2 ]; then
            if [ -z "$override_mode" ]; then
                vecho "All domains already initialized."
                return 0
            else
                echo "No domains found" >&2
                return 1
            fi
        elif [ $list_result -ne 0 ]; then
            echo "Error: Failed to fetch domain list" >&2
            return 1
        fi

        local domain_count=${#OWNED_DOMAINS_LIST[@]}
        if [ "$domain_count" -eq 0 ]; then
            vecho "No owned domains found at $registrar_norm"
            return 0
        fi

        local selected_domains=()
        if [ "$VERBOSE" = true ] && [ "$NON_INTERACTIVE" != true ]; then
            echo ""
            echo "Found $domain_count domain(s) at $registrar_norm:"
            local i
            for ((i=0; i<domain_count; i++)); do
                echo "  $((i+1))) ${OWNED_DOMAINS_LIST[$i]}"
            done
            echo ""
            echo "Enter domain numbers to initialize (e.g., 1,3-5 or 'all'):"
            echo "Press Enter for all, or Ctrl+C to cancel"
            local domain_selection
            read -r -p "> " domain_selection

            if [ -z "$domain_selection" ]; then
                domain_selection="all"
                vecho "Auto-selecting all domains"
            fi

            parse_domain_selection "$domain_selection" "$domain_count"
            if [ ${#SELECTED_INDICES[@]} -eq 0 ]; then
                echo "No valid domains selected" >&2
                return 1
            fi

            local idx
            for idx in "${SELECTED_INDICES[@]}"; do
                selected_domains+=("${OWNED_DOMAINS_LIST[$idx]}")
            done
        else
            selected_domains=("${OWNED_DOMAINS_LIST[@]}")
        fi

        total_count=${#selected_domains[@]}
        vecho "Processing $total_count domain(s)..."

        provider_set_all_domains_init_records "$WAN_IP" "$override_mode" "$sync_mode" "$timeout_arg" "${selected_domains[@]}"
        local batch_result=$?

        local domain
        if [ $batch_result -eq 0 ]; then
            success_count=$total_count
            for domain in "${selected_domains[@]}"; do
                domain_results+=("$domain:success")
            done
        else
            success_count=1
            for domain in "${selected_domains[@]}"; do
                domain_results+=("$domain:batch-processed")
            done
        fi
    fi

    if [ "$VERBOSE" = true ] && [ ${#domain_results[@]} -gt 1 ]; then
        echo ""
        echo "=== DNS Init Report ==="
        local entry
        for entry in "${domain_results[@]}"; do
            echo "${entry%%:*} ${entry#*:}"
        done
        echo "======================="
    fi

    if [ "$VERBOSE" != true ]; then
        if [ "$success_count" -eq "$total_count" ] && [ "$total_count" -gt 0 ]; then
            echo "Success: All $total_count domain(s) initialized successfully"
        elif [ "$success_count" -gt 0 ]; then
            echo "Partial success: $success_count/$total_count domain(s) initialized"
        else
            echo "Error: Failed to initialize DNS records"
        fi
    fi

    [ "$success_count" -gt 0 ]
}

# =============================================================================
# check
# =============================================================================

check_status() {
    local fqdn="$1" provided_registrar="$2" ownership_domain=""

    if [ -z "$fqdn" ]; then
        echo "Error: FQDN is required" >&2
        return 1
    fi

    ownership_domain=$(get_effective_ownership_domain "$fqdn")
    vecho "Checking ownership for $ownership_domain (input: $fqdn)"

    local provided_registrar_norm=""
    [ -n "$provided_registrar" ] && provided_registrar_norm=$(normalize_registrar "$provided_registrar")

    # 1) local domains DB (final statuses short-circuit)
    local db_row db_status db_registrar
    db_row=$(get_local_domain_status "$ownership_domain")
    if [ -n "$db_row" ]; then
        db_status="${db_row%%|*}"
        db_registrar="${db_row#*|}"
        if [ "$db_status" = "free" ] || [ "$db_status" = "owned" ] || [ "$db_status" = "taken" ]; then
            echo "status=$db_status registrar=${db_registrar:-}"
            return 0
        fi
        # 'unavailable' is transient - continue to re-check
    fi

    # 2) local certificate existence
    if has_local_certificate "$ownership_domain"; then
        save_domain_status "$ownership_domain" "owned" "$provided_registrar_norm"
        echo "status=owned registrar=${provided_registrar_norm:-}"
        return 0
    fi

    # 3) WHOIS: registrar + availability hints
    local whois_registrar_norm
    get_whois_info "$ownership_domain" || true

    if [ "$WHOIS_AVAILABLE" = "true" ]; then
        whois_registrar_norm=""
        vecho "WHOIS: No match found (domain may be available)"
    else
        whois_registrar_norm="$WHOIS_REGISTRAR"
        if [ -n "$whois_registrar_norm" ]; then
            vecho "WHOIS: Detected registrar '$whois_registrar_norm'"
        else
            vecho "WHOIS: Could not detect registrar"
        fi
    fi

    decision_evaluate "$whois_registrar_norm" "$provided_registrar_norm" "$ownership_domain"

    local registrar_for_api=""
    case "$DECISION_ACTION" in
        use_tld_priority|use_whois|use_provided)
            registrar_for_api="$DECISION_REGISTRAR"
            ;;
        prompt_provided)
            prompt_add_creds_or_unknown "$DECISION_REGISTRAR"
            echo "status=unknown registrar="
            return 0
            ;;
        prompt_whois)
            prompt_add_creds_or_unknown "$DECISION_REGISTRAR" "WHOIS registrar"
            echo "status=unknown registrar="
            return 0
            ;;
        prompt_mismatch)
            echo ""
            echo "WHOIS registrar '${DECISION_REGISTRAR}' has no credentials. Choose an action:"
            echo "  1) Provide credentials for WHOIS registrar ('${DECISION_REGISTRAR}') now"
            echo "  2) Save as 'unknown' (do not persist)"
            echo "  3) Check registrar provided on the command line instead"
            local user_choice
            read -r -p "Enter choice [1/2/3]: " user_choice
            case "$user_choice" in
                1)
                    prompt_store_creds "$DECISION_REGISTRAR" || true
                    echo "status=unknown registrar="
                    return 0
                    ;;
                3)
                    if has_creds_for "$provided_registrar_norm"; then
                        registrar_for_api="$provided_registrar_norm"
                    else
                        prompt_add_creds_or_unknown "$provided_registrar_norm" "provided registrar"
                        echo "status=unknown registrar="
                        return 0
                    fi
                    ;;
                *)
                    echo "status=unknown registrar="
                    return 0
                    ;;
            esac
            ;;
        check_provided)
            if has_creds_for "$DECISION_REGISTRAR"; then
                registrar_for_api="$DECISION_REGISTRAR"
            else
                echo "status=unknown registrar="
                return 0
            fi
            ;;
        unknown_stdout|*)
            echo "status=unknown registrar="
            return 0
            ;;
    esac

    if [ -z "$registrar_for_api" ]; then
        echo "status=unknown registrar="
        return 0
    fi

    # Query the provider API for the final status
    if [ -z "${PROVIDER_USERNAME:-}" ] || [ -z "${PROVIDER_API_KEY:-}" ]; then
        if ! creds_get "$registrar_for_api" >/dev/null; then
            vecho "Warning: Failed to get credentials for $registrar_for_api"
            echo "status=unknown registrar="
            return 0
        fi
    fi

    if ! get_wan_ip; then
        vecho "Error: Failed to determine WAN IP"
        echo "status=unknown registrar="
        return 0
    fi

    if ! load_provider "$registrar_for_api" 2>/dev/null; then
        vecho "Warning: Failed to load provider $registrar_for_api"
        echo "status=unknown registrar="
        return 0
    fi

    if ! declare -F provider_check_domain_status >/dev/null 2>&1; then
        vecho "Provider plugin for '$registrar_for_api' does not implement domain status check"
        echo "status=unknown registrar="
        return 0
    fi

    local provider_result provider_status
    if [ "$VERBOSE" = true ]; then
        provider_result=$(provider_check_domain_status "$ownership_domain" "$WAN_IP" 2>&1 || true)
    else
        provider_result=$(provider_check_domain_status "$ownership_domain" "$WAN_IP" 2>/dev/null || true)
    fi
    provider_status=$(echo "$provider_result" | awk -F'=' '/^status=/{print $2; exit}')

    case "$provider_status" in
        owned|free|taken)
            save_domain_status "$ownership_domain" "$provider_status" "$registrar_for_api"
            echo "status=$provider_status registrar=$registrar_for_api"
            ;;
        *)
            echo "status=unknown registrar="
            ;;
    esac
}

# =============================================================================
# DNS propagation checks
# =============================================================================

# Parallel propagation check with per-domain status lines.
# wait_for_dns_propagation_parallel <wan_ip> <max_wait> <domain...>
wait_for_dns_propagation_parallel() {
    local wan_ip="$1" max_wait="$2"
    shift 2
    local domains=("$@")

    local num_domains=${#domains[@]}
    [ "$num_domains" -eq 0 ] && return 0

    declare -A domain_status domain_start_ts domain_ns_server domain_avg_prop

    local domain
    for domain in "${domains[@]}"; do
        domain_status["$domain"]="pending"
        domain_start_ts["$domain"]=$(date +%s)
        domain_ns_server["$domain"]=$(get_cached_ns "$domain" 2>/dev/null || echo "")
        local ns="${domain_ns_server[$domain]}"
        domain_avg_prop["$domain"]=$(get_avg_propagation_time "$ns" 2>/dev/null || echo "$DEFAULT_AVG_PROPAGATION")
    done

    ui "Checking DNS propagation for $num_domains domain(s) (timeout: ${max_wait}s)..."

    for domain in "${domains[@]}"; do
        ui "  $domain: [avg: ${domain_avg_prop[$domain]}s | elapsed: 0s | timeout: ${max_wait}s]"
    done

    local all_done=false
    while [ "$all_done" = false ]; do
        all_done=true
        local now_ts
        now_ts=$(date +%s)

        # Rewrite the whole status block in place when a TTY is available.
        [ "$A2TOOLS_HAS_TTY" = true ] && printf '\033[%dA' "$num_domains" >&3

        for domain in "${domains[@]}"; do
            local status="${domain_status[$domain]}"
            local start_ts="${domain_start_ts[$domain]}"
            local elapsed=$((now_ts - start_ts))
            local remaining=$((max_wait - elapsed))
            local avg="${domain_avg_prop[$domain]}"

            if [ "$status" = "pending" ]; then
                all_done=false

                if [ "$remaining" -le 0 ]; then
                    domain_status["$domain"]="timeout"
                    print_status_line "  $domain: \033[31mTIMEOUT\033[0m (${max_wait}s)"
                elif check_init_dns_propagation_quick "$domain" "$wan_ip"; then
                    domain_status["$domain"]="propagated"

                    local ns="${domain_ns_server[$domain]}"
                    [ -n "$ns" ] && update_avg_propagation_time "$ns" "$elapsed" 2>/dev/null || true

                    cache_delete_dns_change "$domain" "A" "@" "$wan_ip" 2>/dev/null || true
                    cache_delete_dns_change "$domain" "A" "*" "$wan_ip" 2>/dev/null || true
                    cache_delete_dns_change "$domain" "MX" "@" "mail.${domain}" 2>/dev/null || true

                    print_status_line "  $domain: \033[32mPROPAGATED\033[0m (${elapsed}s)"
                else
                    print_status_line "  $domain: [avg: ${avg}s | elapsed: ${elapsed}s | timeout: ${max_wait}s]"
                fi
            else
                if [ "$status" = "propagated" ]; then
                    print_status_line "  $domain: \033[32mPROPAGATED\033[0m"
                else
                    print_status_line "  $domain: \033[31mTIMEOUT\033[0m (${max_wait}s)"
                fi
            fi
        done

        [ "$all_done" = false ] && sleep 1
    done

    local propagated_count=0 timeout_count=0
    for domain in "${domains[@]}"; do
        if [ "${domain_status[$domain]}" = "propagated" ]; then
            propagated_count=$((propagated_count + 1))
        else
            timeout_count=$((timeout_count + 1))
        fi
    done

    ui ""
    ui "Propagation complete: $propagated_count propagated, $timeout_count timed out"

    [ "$propagated_count" -gt 0 ]
}

# Quick, single-shot propagation check (no output, no loops).
check_init_dns_propagation_quick() {
    local domain="$1" wan_ip="$2"

    local ns_server
    ns_server=$(get_cached_ns "$domain" 2>/dev/null)
    [ -z "$ns_server" ] && return 1

    local rec
    # Authoritative NS
    rec=$(dig +short @"$ns_server" "$domain" A 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "$wan_ip"; } || return 1

    rec=$(dig +short @"$ns_server" "wildcard-test.${domain}" A 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "$wan_ip"; } || return 1

    rec=$(dig +short @"$ns_server" "$domain" MX 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "mail.${domain}"; } || return 1

    # Google DNS (global propagation)
    rec=$(dig +short @8.8.8.8 "$domain" A 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "$wan_ip"; } || return 1

    rec=$(dig +short @8.8.8.8 "wildcard-test.${domain}" A 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "$wan_ip"; } || return 1

    rec=$(dig +short @8.8.8.8 "$domain" MX 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "mail.${domain}"; } || return 1

    return 0
}

# Single check of initial DNS records (A @, A *, MX @) at the authoritative
# NS first (avoids negative caching at Google), then at Google DNS.
# Params: domain wan_ip [elapsed] [avg] [timeout] (display only)
check_init_dns_propagation() {
    local domain="$1" wan_ip="$2"

    local ns_server rec
    ns_server=$(get_cached_ns "$domain")

    # Phase 1: authoritative NS
    rec=$(dig +short @"$ns_server" "$domain" A 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "$wan_ip"; } || return 1

    rec=$(dig +short @"$ns_server" "wildcard-test.${domain}" A 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "$wan_ip"; } || return 1

    rec=$(dig +short @"$ns_server" "$domain" MX 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "mail.${domain}"; } || return 1

    vecho "  [Auth NS] All records confirmed at authoritative nameserver"

    # Phase 2: Google DNS
    rec=$(dig +short @8.8.8.8 "${domain}" A 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "$wan_ip"; } || return 1

    rec=$(dig +short @8.8.8.8 "wildcard-test.${domain}" A 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "$wan_ip"; } || return 1

    rec=$(dig +short @8.8.8.8 "${domain}" MX 2>/dev/null)
    { [ -n "$rec" ] && echo "$rec" | grep -qF "mail.${domain}"; } || return 1

    vecho "  [Google DNS] All records propagated globally"
    return 0
}

# Wait for the ACME TXT record to propagate, with adaptive timing.
check_dns_propagation() {
    local domain="$1" expected_value="$2" max_wait="${3:-600}"
    local acme_domain="_acme-challenge.$domain"
    local elapsed=0 ns_propagated=false

    local ns_server avg_propagation first_check_ts
    ns_server=$(get_cached_ns "$domain")
    avg_propagation=$(get_avg_propagation_time "$ns_server")

    first_check_ts=$(cache_get_dns_change "$domain" "TXT" "_acme-challenge" "$expected_value" 2>/dev/null) || first_check_ts=$(date +%s)

    ui ""
    ui "Waiting for ACME TXT record propagation (timeout: ${max_wait}s)..."
    ui "  $domain: [Auth NS] checking..."

    while [ $elapsed -lt "$max_wait" ]; do
        # Authoritative NS first (avoid negative caching at Google)
        local auth_txt
        auth_txt=$(dig +short @"$ns_server" "$acme_domain" TXT 2>/dev/null | tr -d '"')

        if [ -z "$auth_txt" ] || ! echo "$auth_txt" | grep -qF "$expected_value"; then
            local wait_interval
            wait_interval=$(calculate_next_wait "$ns_server" "$first_check_ts")
            if [ $((elapsed + wait_interval)) -gt "$max_wait" ]; then
                wait_interval=$((max_wait - elapsed))
                [ "$wait_interval" -le 0 ] && break
            fi

            if [ "$A2TOOLS_HAS_TTY" = true ]; then
                local countdown=$wait_interval
                while [ $countdown -gt 0 ]; do
                    local current_elapsed=$((elapsed + (wait_interval - countdown)))
                    print_dns_wait_status "$domain" "Auth NS" "$avg_propagation" "$countdown" "$current_elapsed" "$max_wait"
                    sleep 1
                    countdown=$((countdown - 1))
                done
            else
                print_dns_wait_status "$domain" "Auth NS" "$avg_propagation" "$wait_interval" "$elapsed" "$max_wait"
                sleep "$wait_interval"
            fi

            elapsed=$((elapsed + wait_interval))
            continue
        fi

        if [ "$ns_propagated" = false ]; then
            ui "  $domain: [Auth NS] confirmed, checking [Google]..."
            ns_propagated=true
        fi

        # Google DNS (8.8.8.8)
        local response
        response=$(dig +short @8.8.8.8 "${acme_domain}" TXT 2>/dev/null | tr -d '"')

        if [ -n "$response" ] && echo "$response" | grep -qF "$expected_value"; then
            ui "  $domain: [Google] PROPAGATED (${elapsed}s)"

            # Update the average BEFORE the buffer (buffer isn't propagation).
            local now_ts actual_propagation
            now_ts=$(date +%s)
            actual_propagation=$((now_ts - first_check_ts))
            update_avg_propagation_time "$ns_server" "$actual_propagation"

            # Buffer so other resolvers (Let's Encrypt) catch up
            local buffer=${DNS_PROPAGATION_BUFFER:-10}
            ui "  $domain: [Buffer] waiting ${buffer}s for global DNS sync..."
            sleep "$buffer"
            ui "  $domain: [Buffer] done"
            ui ""

            cache_delete_dns_change "$domain" "TXT" "_acme-challenge" "$expected_value"
            return 0
        fi

        local wait_interval
        wait_interval=$(calculate_next_wait "$ns_server" "$first_check_ts")
        if [ $((elapsed + wait_interval)) -gt "$max_wait" ]; then
            wait_interval=$((max_wait - elapsed))
            [ "$wait_interval" -le 0 ] && break
        fi

        if [ "$A2TOOLS_HAS_TTY" = true ]; then
            local countdown=$wait_interval
            while [ $countdown -gt 0 ]; do
                local current_elapsed=$((elapsed + (wait_interval - countdown)))
                print_dns_wait_status "$domain" "Global" "$avg_propagation" "$countdown" "$current_elapsed" "$max_wait"
                sleep 1
                countdown=$((countdown - 1))
            done
        else
            print_dns_wait_status "$domain" "Global" "$avg_propagation" "$wait_interval" "$elapsed" "$max_wait"
            sleep "$wait_interval"
        fi

        elapsed=$((elapsed + wait_interval))
    done

    ui "  $domain: TIMEOUT (${max_wait}s)"
    return 1
}

# =============================================================================
# list
# =============================================================================

# list [REGISTRAR] [local|remote]
list() {
    local registrar="$1" mode="$2"

    # No registrar: list all local domains (machine-parsable)
    if [ -z "$registrar" ]; then
        ensure_domains_db
        local rows
        rows=$(db_domains "SELECT domain, status, registrar FROM domains ORDER BY domain;" 2>/dev/null || true)
        [ -z "$rows" ] && return 0

        while IFS='|' read -r domain status reg; do
            [ -z "$domain" ] && continue
            printf '%s|%s|%s\n' "$domain" "$status" "$reg"
        done <<< "$rows"
        return 0
    fi

    if [ -z "$mode" ]; then
        echo "Error: when REGISTRAR is specified, mode (local|remote) is required" >&2
        return 1
    fi

    mode=$(echo "$mode" | tr '[:upper:]' '[:lower:]')
    if [ "$mode" != "local" ] && [ "$mode" != "remote" ]; then
        echo "Error: mode must be either 'local' or 'remote'" >&2
        return 1
    fi

    local registrar_norm
    registrar_norm=$(normalize_registrar "$registrar")

    if [ "$mode" = "local" ]; then
        ensure_domains_db
        local rows
        rows=$(db_domains "SELECT domain, status FROM domains WHERE registrar='$(sql_escape "$registrar_norm")' ORDER BY domain;" 2>/dev/null || true)
        if [ -z "$rows" ]; then
            vecho "No domains found for registrar '${registrar_norm}' in local DB"
            return 0
        fi

        vecho "Local domains for registrar '${registrar_norm}':"
        local idx=1
        while IFS='|' read -r domain status; do
            [ -z "$domain" ] && continue
            if [ "$VERBOSE" = true ]; then
                echo "  ${idx}) ${domain} [${status}]"
            else
                printf '%s %s\n' "$domain" "$status"
            fi
            idx=$((idx + 1))
        done <<< "$rows"
        return 0
    fi

    # remote
    ensure_domains_db
    creds_get "$registrar_norm"
    local creds_rc=$?
    [ $creds_rc -ne 0 ] && return $creds_rc
    load_provider "$registrar_norm" || return 1

    if ! get_wan_ip; then
        echo "Error: Failed to determine WAN IP" >&2
        return 1
    fi

    vecho "Fetching domains from $registrar_norm via API..."

    local provider_output
    provider_output=$(provider_list_all_domains "$WAN_IP" 2>/dev/null || true)

    # Extract "domain" or "domain|status" lines from provider output.
    # Providers either emit machine-parsable "domain|status" lines (wedos) or
    # numbered "N) domain" listings (namecheap).
    local -a listed_domains=()
    local -A listed_status=()
    local line domain status

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" == *"|"* ]]; then
            domain="${line%%|*}"
            status="${line#*|}"
        else
            domain=$(echo "$line" | sed -n 's/^[[:space:]]*[0-9]\{1,\})[[:space:]]*//p')
            [ -z "$domain" ] && domain=$(echo "$line" | grep -Eo '([a-zA-Z0-9_-]+\.)+[a-zA-Z]{2,}' | head -n1)
            status=""
        fi
        [ -z "$domain" ] && continue
        is_valid_fqdn "$domain" || continue
        listed_domains+=("$domain")
        listed_status["$domain"]="$status"
    done <<< "$provider_output"

    # Deduplicate, preserving order
    local -a unique_domains=()
    local -A seen=()
    for domain in "${listed_domains[@]}"; do
        [ -n "${seen[$domain]:-}" ] && continue
        seen["$domain"]=1
        unique_domains+=("$domain")
    done

    if [ ${#unique_domains[@]} -eq 0 ]; then
        vecho "No domains returned by provider API or none detected in output."
        if [ -n "$provider_output" ] && [ "$VERBOSE" = true ]; then
            echo "Provider output:" >&2
            printf '%s\n' "$provider_output" | sed -n '1,200p' >&2
        fi
        return 0
    fi

    local -a owned_domains=()
    local idx=1
    for domain in "${unique_domains[@]}"; do
        status="${listed_status[$domain]}"

        if [ -n "$status" ]; then
            # Machine-parsable provider output: persist active domains as owned
            if [ "$status" = "active" ]; then
                save_domain_status "$domain" "owned" "$registrar_norm"
                owned_domains+=("$domain")
            fi
            if [ "$VERBOSE" = true ]; then
                echo "  ${idx}) ${domain} [${status}]"
            else
                echo "$domain"
            fi
        else
            # No status from the listing: resolve precisely when possible
            local resolved="owned"
            if declare -F provider_check_domain_status >/dev/null 2>&1; then
                local provider_result
                provider_result=$(provider_check_domain_status "$domain" "$WAN_IP" 2>/dev/null || true)
                if echo "$provider_result" | grep -q '^status='; then
                    resolved=$(echo "$provider_result" | awk -F'=' '/^status=/{print $2; exit}')
                fi
            fi

            save_domain_status "$domain" "$resolved" "$registrar_norm"
            [ "$resolved" = "owned" ] && owned_domains+=("$domain")

            if [ "$VERBOSE" = true ]; then
                echo "  ${idx}) ${domain}"
            else
                echo "$domain"
            fi
        fi
        idx=$((idx + 1))
    done

    # Enrich owned domains with certificate and DNS init information
    if [ ${#owned_domains[@]} -gt 0 ]; then
        vecho "Checking certificate and DNS status for domains..."

        local cert_info
        cert_info=$(parse_certbot_certificates 2>/dev/null || true)

        declare -A cert_dates
        if [ -n "$cert_info" ]; then
            local cert_domain issue_date expiry_date
            while IFS='|' read -r cert_domain issue_date expiry_date; do
                [ -z "$cert_domain" ] && continue
                cert_dates["$cert_domain"]="$issue_date"
            done <<< "$cert_info"
        fi

        for domain in "${owned_domains[@]}"; do
            local cert_date="" dns_init=""
            if [ -n "${cert_dates[$domain]:-}" ]; then
                cert_date="${cert_dates[$domain]}"
                vecho "  $domain: certificate issued on $cert_date"
            fi

            if check_domain_dns_initialized "$domain" "$WAN_IP" 2>/dev/null; then
                dns_init="1"
                vecho "  $domain: DNS initialized"
            else
                dns_init="0"
                vecho "  $domain: DNS not initialized"
            fi

            update_domain_cert_dns_info "$domain" "$cert_date" "$dns_init"
        done
    fi

    return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

# Extract -v / -ni wherever they appear, without word-splitting other args.
ARGS=()
for arg in "$@"; do
    case "$arg" in
        -v)  VERBOSE=true ;;
        -ni) NON_INTERACTIVE=true ;;
        *)   ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage 0
fi

if [ $# -lt 1 ]; then
    usage 1
fi

FUNCTION_NAME="$1"
shift

case "$FUNCTION_NAME" in
    certify)
        if [ $# -lt 1 ]; then
            echo "Error: certify requires REGISTRAR argument" >&2
            echo "Usage: $0 certify <REGISTRAR>" >&2
            exit 1
        fi
        certify "$1"
        ;;
    purchase)
        if [ $# -lt 2 ]; then
            echo "Error: purchase requires FQDN and REGISTRAR arguments" >&2
            echo "Usage: $0 purchase <FQDN> <REGISTRAR>" >&2
            exit 1
        fi
        if ! is_valid_fqdn "$1"; then
            echo "Error: Invalid domain '$1'." >&2
            exit 2
        fi
        purchase "$1" "$2"
        ;;
    cleanup)
        if [ $# -lt 1 ]; then
            echo "Error: cleanup requires REGISTRAR argument" >&2
            echo "Usage: $0 cleanup <REGISTRAR>" >&2
            exit 1
        fi
        cleanup "$1"
        ;;
    check)
        if [ $# -lt 1 ]; then
            echo "Error: check requires FQDN argument" >&2
            echo "Usage: $0 check <FQDN> [REGISTRAR]" >&2
            exit 1
        fi
        FQDN="$1"; shift
        if ! is_valid_fqdn "$FQDN"; then
            echo "Error: Invalid domain '$FQDN'. Provide a fully-qualified domain name like 'example.com' (not just 'example')." >&2
            echo "Usage: $0 check <FQDN> [REGISTRAR]" >&2
            exit 2
        fi
        REGISTRAR=""
        while [ $# -gt 0 ]; do
            if [ -z "$REGISTRAR" ]; then
                REGISTRAR="$1"
            else
                echo "Error: unexpected argument '$1'" >&2
                echo "Usage: $0 check <FQDN> [REGISTRAR]" >&2
                exit 1
            fi
            shift
        done
        check_status "$FQDN" "$REGISTRAR"
        ;;
    setInitDNSRecords)
        setInitDNSRecords "$@"
        ;;
    checkInitDns)
        if [ $# -lt 1 ]; then
            echo "Error: checkInitDns requires FQDN argument" >&2
            echo "Usage: $0 checkInitDns <FQDN>" >&2
            exit 1
        fi
        if ! get_wan_ip; then
            echo "Error: Cannot proceed without WAN IP" >&2
            exit 1
        fi
        check_init_dns_propagation "$1" "$WAN_IP"
        ;;
    list)
        if [ $# -eq 0 ]; then
            list "" ""
        elif [ $# -eq 1 ]; then
            echo "Error: when REGISTRAR is specified, mode (local|remote) is required" >&2
            echo "Usage: $0 list [REGISTRAR] [local|remote]" >&2
            exit 1
        else
            list "$1" "$2"
        fi
        ;;
    *)
        echo "Error: Unknown function '$FUNCTION_NAME'" >&2
        echo "Available functions: certify, purchase, cleanup, check, setInitDNSRecords, checkInitDns, list" >&2
        exit 1
        ;;
esac
