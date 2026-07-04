#!/bin/bash
# this script is designed to provision new domains: purchasing them, setting up the acme DNS record.
# it uses registrars creds saved in sqlite db.

# Get the directory where this script is located
PROVIDERS_DIR="/etc/fqdnmgr/providers"

# Logging configuration
LOG_DIR="/var/log/fqdnmgr"
LOG_FILE="${LOG_DIR}/fqdnmgr.log"

# Initialize logging directory if it doesn't exist
init_logging() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
    # Ensure log file exists and is writable
    touch "$LOG_FILE" 2>/dev/null || true
}

# Log curl request sent to provider
# Usage: log_request "provider_name" "curl_request"
log_request() {
    local provider="$1"
    local request="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    {
        echo "[$timestamp] *** sent $provider"
        echo "$request"
        echo ""
    } >> "$LOG_FILE" 2>/dev/null || true
}

# Log curl response from provider
# Usage: log_response "provider_name" "response"
log_response() {
    local provider="$1"
    local response="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    {
        echo "[$timestamp] *** response from $provider"
        echo "$response"
        echo ""
    } >> "$LOG_FILE" 2>/dev/null || true
}

# Initialize logging on script load
init_logging

# Centralized cache file for a2tools
# Format: type domain value timestamp [extra...]
# Types: whois (1h TTL), ns (2h TTL), dns_change (48h TTL), ap (never expires)
A2TOOLS_CACHE_FILE="/tmp/a2tools.cache"

# TTL values in seconds
CACHE_TTL_WHOIS=3600      # 1 hour
CACHE_TTL_NS=7200         # 2 hours
CACHE_TTL_DNS_CHANGE=172800  # 48 hours
CACHE_TTL_AP=-1           # Never expires (average propagation time)

# Default average propagation time in seconds (fallback when no historical data)
DEFAULT_AVG_PROPAGATION=120  # 2 minutes

# Minimum interval between propagation checks (seconds)
MIN_CHECK_INTERVAL=10

# Garbage collection: remove expired entries from centralized cache
cleanup_expired_cache() {
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 0
    local now_ts
    now_ts=$(date +%s)
    local tmp_file="${A2TOOLS_CACHE_FILE}.tmp"
    
    # Filter out expired entries
    while IFS=' ' read -r type domain value timestamp rest; do
        [ -z "$type" ] && continue
        local ttl=0
        case "$type" in
            whois) ttl=$CACHE_TTL_WHOIS ;;
            ns)    ttl=$CACHE_TTL_NS ;;
            dns_change) ttl=$CACHE_TTL_DNS_CHANGE ;;
            ap)    ttl=$CACHE_TTL_AP ;;  # -1 means never expires
            *)     ttl=3600 ;;  # default 1h for unknown types
        esac
        # Keep entry if TTL is -1 (never expires) or not yet expired
        if [ "$ttl" -eq -1 ] || [ $((now_ts - timestamp)) -lt $ttl ]; then
            echo "$type $domain $value $timestamp $rest"
        fi
    done < "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null
    mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

# Get value from centralized cache
# Usage: cache_get <type> <domain>
# Returns: value on stdout, 0 if found and valid, 1 if not found/expired
cache_get() {
    local type="$1"
    local domain="$2"
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 1
    local now_ts
    now_ts=$(date +%s)
    local ttl=0
    case "$type" in
        whois) ttl=$CACHE_TTL_WHOIS ;;
        ns)    ttl=$CACHE_TTL_NS ;;
        dns_change) ttl=$CACHE_TTL_DNS_CHANGE ;;
        ap)    ttl=$CACHE_TTL_AP ;;
        *)     ttl=3600 ;;
    esac
    
    # Find matching entry (most recent if duplicates exist)
    local found_value="" found_ts=0
    while IFS=' ' read -r etype edomain evalue etimestamp erest; do
        if [ "$etype" = "$type" ] && [ "$edomain" = "$domain" ]; then
            if [ "$etimestamp" -gt "$found_ts" ] 2>/dev/null; then
                found_value="$evalue"
                found_ts="$etimestamp"
            fi
        fi
    done < "$A2TOOLS_CACHE_FILE"
    
    # Check if found and not expired (TTL=-1 means never expires)
    if [ -n "$found_value" ]; then
        if [ "$ttl" -eq -1 ] || [ $((now_ts - found_ts)) -lt $ttl ]; then
            echo "$found_value"
            return 0
        fi
    fi
    return 1
}

# Set value in centralized cache
# Usage: cache_set <type> <domain> <value>
cache_set() {
    local type="$1"
    local domain="$2"
    local value="$3"
    local now_ts
    now_ts=$(date +%s)
    
    # Remove old entry for this type+domain, then append new one
    if [ -f "$A2TOOLS_CACHE_FILE" ]; then
        local tmp_file="${A2TOOLS_CACHE_FILE}.tmp"
        grep -v -- "^${type} ${domain} " "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
    fi
    echo "$type $domain $value $now_ts" >> "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

# Run garbage collection on script load
cleanup_expired_cache

# Helper: get cached authoritative NS for a domain using SOA MNAME
# Uses centralized cache with 2h TTL
# This ensures consistent NS selection across multiple checks (avoids round-robin randomness)
get_cached_ns() {
    local domain="$1"
    
    # Check centralized cache
    local cached_ns
    if cached_ns=$(cache_get "ns" "$domain"); then
        echo "$cached_ns"
        return 0
    fi
    
    # Get primary NS from SOA MNAME field
    local ns_server
    ns_server=$(dig +short SOA "$domain" | awk '{print $1}')
    
    # Fallback to first NS record if SOA lookup fails
    if [ -z "$ns_server" ]; then
        ns_server=$(dig +short NS "$domain" | sort | head -1)
    fi
    
    # Cache and return
    if [ -n "$ns_server" ]; then
        cache_set "ns" "$domain" "$ns_server"
        echo "$ns_server"
        return 0
    fi
    
    return 1
}

# =============================================================================
# DNS Change Tracking and Adaptive Propagation Timing
# =============================================================================

# Record when a DNS record was set (for adaptive propagation timing)
# Format in cache: dns_change <domain>:<record_type>:<host>:<value> <set_timestamp> <timestamp>
# Usage: cache_set_dns_change <domain> <record_type> <host> <value>
cache_set_dns_change() {
    local domain="$1"
    local record_type="$2"
    local host="$3"
    local value="$4"
    local now_ts
    now_ts=$(date +%s)
    
    # Create composite key: domain:type:host:value
    local cache_key="${domain}:${record_type}:${host}:${value}"
    
    # Remove old entry for this key, then append new one
    if [ -f "$A2TOOLS_CACHE_FILE" ]; then
        local tmp_file="${A2TOOLS_CACHE_FILE}.tmp"
        grep -v -- "^dns_change ${cache_key} " "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
    fi
    # Store: dns_change <key> <set_timestamp> <cache_timestamp>
    echo "dns_change $cache_key $now_ts $now_ts" >> "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

# Get the timestamp when a DNS record was set
# Usage: cache_get_dns_change <domain> <record_type> <host> <value>
# Returns: set_timestamp on stdout, 0 if found, 1 if not found
cache_get_dns_change() {
    local domain="$1"
    local record_type="$2"
    local host="$3"
    local value="$4"
    local cache_key="${domain}:${record_type}:${host}:${value}"
    
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 1
    local now_ts
    now_ts=$(date +%s)
    
    # Find matching entry
    local found_set_ts="" found_cache_ts=0
    while IFS=' ' read -r etype ekey eset_ts ecache_ts erest; do
        if [ "$etype" = "dns_change" ] && [ "$ekey" = "$cache_key" ]; then
            if [ "$ecache_ts" -gt "$found_cache_ts" ] 2>/dev/null; then
                found_set_ts="$eset_ts"
                found_cache_ts="$ecache_ts"
            fi
        fi
    done < "$A2TOOLS_CACHE_FILE"
    
    # Check if found and not expired (48h TTL)
    if [ -n "$found_set_ts" ] && [ $((now_ts - found_cache_ts)) -lt $CACHE_TTL_DNS_CHANGE ]; then
        echo "$found_set_ts"
        return 0
    fi
    return 1
}

# Delete a DNS change tracking entry (called after successful propagation)
# Usage: cache_delete_dns_change <domain> <record_type> <host> <value>
cache_delete_dns_change() {
    local domain="$1"
    local record_type="$2"
    local host="$3"
    local value="$4"
    local cache_key="${domain}:${record_type}:${host}:${value}"
    
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 0
    
    local tmp_file="${A2TOOLS_CACHE_FILE}.tmp"
    grep -v -- "^dns_change ${cache_key} " "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

# Get average propagation time for a nameserver
# Usage: cache_get_ap <ns_server>
# Returns: average in seconds on stdout, 0 if found, 1 if not found
cache_get_ap() {
    local ns_server="$1"
    [ -f "$A2TOOLS_CACHE_FILE" ] || return 1
    
    # Find matching entry (ap entries never expire)
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

# Set/update average propagation time for a nameserver
# Usage: cache_set_ap <ns_server> <avg_seconds>
cache_set_ap() {
    local ns_server="$1"
    local avg_seconds="$2"
    local now_ts
    now_ts=$(date +%s)
    
    # Remove old entry for this NS, then append new one
    if [ -f "$A2TOOLS_CACHE_FILE" ]; then
        local tmp_file="${A2TOOLS_CACHE_FILE}.tmp"
        grep -v -- "^ap ${ns_server} " "$A2TOOLS_CACHE_FILE" > "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
    fi
    echo "ap $ns_server $avg_seconds $now_ts" >> "$A2TOOLS_CACHE_FILE" 2>/dev/null || true
}

# Get average propagation time for a nameserver (with fallback to default)
# Usage: get_avg_propagation_time <ns_server> [registrar]
# Returns: average in seconds (always succeeds, uses DEFAULT_AVG_PROPAGATION as fallback)
# Lookup order: 1) cache, 2) domain.conf (by registrar), 3) hardcoded default
get_avg_propagation_time() {
    local ns_server="$1"
    local registrar="${2:-}"
    local avg
    
    # 1) Try cache first
    if avg=$(cache_get_ap "$ns_server"); then
        echo "$avg"
        return 0
    fi
    
    # 2) Try domain.conf by registrar name (e.g., AVG_PROPAGATION_TIME_namecheap_com)
    if [ -n "$registrar" ]; then
        local registrar_normalized="${registrar//./_}"
        local config_var="AVG_PROPAGATION_TIME_${registrar_normalized}"
        if [ -n "${!config_var:-}" ]; then
            echo "${!config_var}"
            return 0
        fi
    fi
    
    # 3) Fallback to hardcoded default
    echo "$DEFAULT_AVG_PROPAGATION"
    return 0
}

# Calculate next wait interval using adaptive timing algorithm
# Formula: max(MIN_CHECK_INTERVAL, (avg - elapsed) / 2)
#   where elapsed = current_ts - first_check_ts
# Usage: calculate_next_wait <ns_server> <first_check_ts>
# Returns: seconds to wait before next check
calculate_next_wait() {
    local ns_server="$1"
    local first_check_ts="$2"
    local now_ts
    now_ts=$(date +%s)
    
    local avg_propagation
    avg_propagation=$(get_avg_propagation_time "$ns_server")
    
    # Calculate: (avg - elapsed) / 2 = (avg_propagation - (now_ts - first_check_ts)) / 2
    local remaining=$((avg_propagation + first_check_ts - now_ts))
    local next_wait=$((remaining / 2))
    
    # Enforce minimum interval
    if [ "$next_wait" -lt "$MIN_CHECK_INTERVAL" ]; then
        next_wait=$MIN_CHECK_INTERVAL
    fi
    
    echo "$next_wait"
}

# Update average propagation time after successful propagation
# If no previous average exists, use actual time directly
# Otherwise: new_avg = (previous_avg + actual_time) / 2
# Usage: update_avg_propagation_time <ns_server> <actual_propagation_seconds>
update_avg_propagation_time() {
    local ns_server="$1"
    local actual_seconds="$2"
    local new_avg
    
    local prev_avg
    if prev_avg=$(cache_get_ap "$ns_server"); then
        # Calculate new average: (previous + actual) / 2
        new_avg=$(( (prev_avg + actual_seconds) / 2 ))
    else
        # First measurement: use actual time directly
        new_avg="$actual_seconds"
    fi
    
    cache_set_ap "$ns_server" "$new_avg"
    # Use /dev/tty for certbot hook context (stderr is captured as "error output")
    [ "$VERBOSE" = true ] && echo "  Updated average propagation time for $ns_server: ${new_avg}s" > /dev/tty 2>/dev/null || true
}

# =============================================================================
# Unified DNS Wait Status Output
# =============================================================================

# Print DNS wait status line with unified format (in-place update)
# Usage: print_dns_wait_status <domain> <phase> <avg> <next_check_in> <elapsed> <timeout> [output_dest]
# If next_check_in is empty or 0, the "next:" part is omitted (first check scenario)
# output_dest: "tty" (default) or "stderr"
print_dns_wait_status() {
    local domain="$1"
    local phase="$2"
    local avg="$3"
    local next_check_in="$4"
    local elapsed="$5"
    local timeout="$6"
    local output_dest="${7:-tty}"
    
    local status_line
    if [ -z "$next_check_in" ] || [ "$next_check_in" -eq 0 ] 2>/dev/null; then
        # First check - no "next:" part
        status_line=$(printf '  %s: [%s] [avg: %ds | elapsed: %ds | timeout: %ds]' "$domain" "$phase" "$avg" "$elapsed" "$timeout")
    else
        # Subsequent checks - include "next:" countdown
        status_line=$(printf '  %s: [%s] [avg: %ds | next: %ds | elapsed: %ds | timeout: %ds]' "$domain" "$phase" "$avg" "$next_check_in" "$elapsed" "$timeout")
    fi
    
    if [ "$output_dest" = "tty" ]; then
        printf '\033[1A\r\033[K%s\n' "$status_line" > /dev/tty
    else
        printf '\r\033[K%s\n' "$status_line" > /dev/tty
    fi
}

# Print DNS wait status for parallel mode (no cursor-up, just clear and reprint)
# Usage: print_dns_wait_status_inline <domain> <avg> <elapsed> <timeout>
print_dns_wait_status_inline() {
    local domain="$1"
    local avg="$2"
    local elapsed="$3"
    local timeout="$4"
    
    printf '\r\033[K  %s: [avg: %ds | elapsed: %ds | timeout: %ds]\n' "$domain" "$avg" "$elapsed" "$timeout" > /dev/tty
}

# =============================================================================

# Verbose mode - controlled by -v flag
VERBOSE=false

# Non-interactive mode - controlled by -ni flag (only effective when -v is set)
NON_INTERACTIVE=false

# Verbose echo - only prints when VERBOSE=true
# Uses /dev/tty for output (avoids stderr which can be captured/redirected)
vecho() { [ "$VERBOSE" = true ] && echo "$@" > /dev/tty 2>/dev/null || true; }

# Database configuration
DOMAINS_DB_PATH="/etc/fqdntools/domains.db"

# Domain configuration file
DOMAIN_CONFIG_PATH="/etc/fqdnmgr/domain.conf"

# Load domain configuration (for TLD priority list, etc.)
load_domain_config() {
    if [ -f "$DOMAIN_CONFIG_PATH" ]; then
        # shellcheck disable=SC1090
        . "$DOMAIN_CONFIG_PATH"
    fi
}

# Get TLD from FQDN (e.g., "example.com" -> "com", "sub.domain.co.uk" -> "uk")
get_tld() {
    local fqdn="$1"
    echo "${fqdn##*.}"
}

# Check TLD priority list for a registrar with credentials.
# Returns the first registrar that has credentials, or empty string if none found.
# Usage: registrar=$(check_tld_priority "example.com")
check_tld_priority() {
    local fqdn="$1"
    local tld
    tld=$(get_tld "$fqdn")
    
    # Get the TLD priority variable name (e.g., TLD_PRIORITY_com)
    local var_name="TLD_PRIORITY_${tld}"
    local registrar_list="${!var_name:-}"
    
    if [ -z "$registrar_list" ]; then
        echo ""
        return 1
    fi
    
    # Split comma-separated list and check each registrar
    local IFS=','
    local registrar
    for registrar in $registrar_list; do
        # Trim whitespace
        registrar=$(echo "$registrar" | xargs)
        if [ -n "$registrar" ] && has_creds_for "$registrar"; then
            echo "$registrar"
            return 0
        fi
    done
    
    echo ""
    return 1
}

# Load domain config on script initialization
load_domain_config

# Helper: validate IPv4 address format
is_valid_ipv4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # Check each octet is <= 255
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [ "$octet" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Helper: get WAN_IP - reads from the process environment first, then the settings file, errors if not set
WAN_IP_SETTINGS_FILE="${WAN_IP_SETTINGS_FILE:-/etc/environment}"

read_wan_ip_from_settings() {
    local settings_file="${1:-$WAN_IP_SETTINGS_FILE}"

    if [ -f "$settings_file" ]; then
        WAN_IP=$(grep -E "^WAN_IP=" "$settings_file" 2>/dev/null | cut -d= -f2 | tr -d '"')
        if [ -n "$WAN_IP" ]; then
            return 0
        fi
    fi

    return 1
}

get_wan_ip() {
    # Check if WAN_IP is already set in environment
    if [ -n "${WAN_IP:-}" ]; then
        export WAN_IP
        return 0
    fi
    
    # Try to read from the settings file
    if read_wan_ip_from_settings; then
        export WAN_IP
        return 0
    fi
    
    echo "Error: WAN_IP not set in the environment or settings file. Please run setup first." >&2
    return 1
}

# Function to get credentials via socket and export them for provider use
CREDS_SOCKET="/run/fqdncredmgr.sock"

get_credentials() {
    local registrar="$1"
    local function_type="$2"
    
    if [ ! -S "$CREDS_SOCKET" ]; then
        echo "CREDS_ERROR:socket_not_found"
        exit 10
    fi
    
    local response
    response=$(echo "GET_CREDS:$registrar" | socat - UNIX-CONNECT:"$CREDS_SOCKET" 2>/dev/null)
    
    case "$response" in
        OK:*)
            local creds="${response#OK:}"
            PROVIDER_USERNAME=$(echo "$creds" | cut -d'|' -f1)
            PROVIDER_API_KEY=$(echo "$creds" | cut -d'|' -f2)
            ;;
        ERROR:no\ credentials\ for\ provider*)
            echo "CREDS_ERROR:no_credentials:$registrar"
            exit 11
            ;;
        ERROR:database\ not\ found*)
            echo "CREDS_ERROR:database_not_found"
            exit 12
            ;;
        ERROR:*)
            echo "CREDS_ERROR:${response#ERROR:}"
            exit 13
            ;;
        *)
            echo "CREDS_ERROR:invalid_response"
            exit 14
            ;;
    esac
    
    if [ -z "$PROVIDER_USERNAME" ] || [ -z "$PROVIDER_API_KEY" ]; then
        echo "CREDS_ERROR:incomplete_credentials:$registrar"
        exit 15
    fi
    
    export PROVIDER_USERNAME
    export PROVIDER_API_KEY
}

# Probe credential socket for a registrar without modifying shell state.
# Returns 0 if credentials exist (OK:...) else returns 1. Does NOT exit.
has_creds_for() {
    local registrar="$1"
    if [ -z "$registrar" ]; then
        return 1
    fi
    if [ ! -S "$CREDS_SOCKET" ]; then
        return 1
    fi

    local resp
    resp=$(echo "GET_CREDS:${registrar}" | socat - UNIX-CONNECT:"$CREDS_SOCKET" 2>/dev/null || true)
    case "$resp" in
        OK:*) return 0 ;;
        *) return 1 ;;
    esac
}

# decision_evaluate: centralize registrar/credential decision making
# Inputs: whois_norm, provided_norm, VERBOSE
# Outputs (globals): DECISION_ACTION, DECISION_REGISTRAR
# Actions: use_whois, use_provided, prompt_provided, prompt_whois, prompt_mismatch,
#          check_provided, unknown_stdout
decision_evaluate() {
    local whois_norm="$1"
    local provided_norm="$2"
    local fqdn_for_tld="$3"  # Optional: FQDN for TLD priority check

    DECISION_ACTION=""
    DECISION_REGISTRAR=""
    # Follow the decision table provided by the user (see attachment)
    # Case A: WHOIS empty, registrar not provided => check TLD priority, then echo unknown (do not save)
    if [ -z "$whois_norm" ] && [ -z "$provided_norm" ]; then
        # TLD priority check: silently look for a registrar with credentials
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
        DECISION_REGISTRAR=""
        return 0
    fi

    # Case B: WHOIS empty, registrar provided => check creds for provided
    if [ -z "$whois_norm" ] && [ -n "$provided_norm" ]; then
        if has_creds_for "$provided_norm"; then
            DECISION_ACTION="use_provided"
            DECISION_REGISTRAR="$provided_norm"
        else
            if [ "$VERBOSE" = true ]; then
                DECISION_ACTION="prompt_provided"
                DECISION_REGISTRAR="$provided_norm"
            else
                DECISION_ACTION="unknown_stdout"
                DECISION_REGISTRAR=""
            fi
        fi
        return 0
    fi

    # Case C: WHOIS not empty, registrar not provided (or both not provided but handled above)
    if [ -n "$whois_norm" ] && [ -z "$provided_norm" ]; then
        if has_creds_for "$whois_norm"; then
            DECISION_ACTION="use_whois"
            DECISION_REGISTRAR="$whois_norm"
        else
            if [ "$VERBOSE" = true ]; then
                DECISION_ACTION="prompt_whois"
                DECISION_REGISTRAR="$whois_norm"
            else
                DECISION_ACTION="unknown_stdout"
                DECISION_REGISTRAR=""
            fi
        fi
        return 0
    fi

    # Case D: WHOIS not empty and provided present
    if [ -n "$whois_norm" ] && [ -n "$provided_norm" ]; then
        # If they match, treat as single-registrar case
        if [ "$whois_norm" = "$provided_norm" ]; then
            if has_creds_for "$whois_norm"; then
                DECISION_ACTION="use_whois"
                DECISION_REGISTRAR="$whois_norm"
            else
                if [ "$VERBOSE" = true ]; then
                    DECISION_ACTION="prompt_whois"
                    DECISION_REGISTRAR="$whois_norm"
                else
                    DECISION_ACTION="unknown_stdout"
                    DECISION_REGISTRAR=""
                fi
            fi
            return 0
        fi

        # Mismatch: prioritize WHOIS registrar
        if has_creds_for "$whois_norm"; then
            DECISION_ACTION="use_whois"
            DECISION_REGISTRAR="$whois_norm"
            return 0
        fi

        # WHOIS has no creds
        if [ "$VERBOSE" = true ]; then
            # Interactive: offer 3 choices (provide creds, save as unknown, check provided registrar)
            DECISION_ACTION="prompt_mismatch"
            DECISION_REGISTRAR="$whois_norm"
        else
            # Non-interactive: default to checking provided registrar (choice 3)
            DECISION_ACTION="check_provided"
            DECISION_REGISTRAR="$provided_norm"
        fi
        return 0
    fi

    # Fallback: echo unknown
    DECISION_ACTION="unknown_stdout"
    DECISION_REGISTRAR=""
    return 0
}

# Load provider plugin
load_provider() {
    local registrar="$1"
    local provider_file="$PROVIDERS_DIR/${registrar}.provider"
    
    if [ ! -f "$provider_file" ]; then
        echo "Error: Provider file not found for '$registrar'"
        echo "Expected: $provider_file"
        echo ""
        echo "Available providers:"
        for provider in "$PROVIDERS_DIR"/*.provider; do
            if [ -f "$provider" ]; then
                basename "$provider" .provider
            fi
        done
        exit 1
    fi
    
    # Source the provider file to load its functions
    source "$provider_file"
}

# Function to display usage information (reads external usage.txt only)
usage() {
    local providers_text=""
    for provider in "$PROVIDERS_DIR"/*.provider; do
        if [ -f "$provider" ]; then
            providers_text+=$(printf '  - %s\n' "$(basename "$provider" .provider)")
        fi
    done

    # Determine script directory and external usage file
    local script_dir usage_file
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/fqdnmgr.d"
    usage_file="$script_dir/usage.txt"

    if [ ! -f "$usage_file" ]; then
        echo "Error: usage file not found: $usage_file" >&2
        exit 1
    fi

    cat "$usage_file"

    # Print available providers collected earlier
    printf '%b' "$providers_text"
    exit 1
}

# Common initialization for certify and cleanup - DRY principle
init_provider_for_dns_operation() {
    local registrar="$1"
    local operation="$2"  # "certify" or "cleanup"
    
    # Check required environment variables
    if [ -z "$CERTBOT_DOMAIN" ]; then
        echo "Error: CERTBOT_DOMAIN environment variable not set" 2>/dev/null
        exit 1
    fi
    
    if [ -z "$CERTBOT_VALIDATION" ]; then
        echo "Error: CERTBOT_VALIDATION environment variable not set" 2>/dev/null
        exit 1
    fi
    
    # Get credentials for provider
    if [ "$VERBOSE" = true ]; then
        get_credentials "$registrar" "$operation" 2>&1 || exit $?
    else
        get_credentials "$registrar" "$operation"
    fi
    
    # Load the provider
    if [ "$VERBOSE" = true ]; then
        load_provider "$registrar" 2>&1 || exit $?
    else
        load_provider "$registrar"
    fi
    
    # Get WAN IP (required by some providers)
    if ! get_wan_ip; then
        exit 1
    fi
}

# Main certify function - orchestrates DNS challenge setup
certify() {
    local registrar="$1"
    init_provider_for_dns_operation "$registrar" "certify"
    
    # Calculate challenge progress from certbot environment variables
    # CERTBOT_ALL_DOMAINS: comma-separated list of all domains
    # CERTBOT_REMAINING_CHALLENGES: number of remaining challenges after this one
    if [ "$VERBOSE" = true ] && [ -n "$CERTBOT_ALL_DOMAINS" ]; then
        local total_challenges=$(echo "$CERTBOT_ALL_DOMAINS" | tr ',' '\n' | wc -l | tr -d ' ')
        local remaining=${CERTBOT_REMAINING_CHALLENGES:-0}
        local current_challenge=$((total_challenges - remaining))
        echo "=== ACME Challenge $current_challenge of $total_challenges: $CERTBOT_DOMAIN ===" > /dev/tty
    fi
    
    # Check if TXT record already exists at authoritative NS
    # This prevents false re-setting which would corrupt propagation timing data
    local ns_server
    ns_server=$(get_cached_ns "$CERTBOT_DOMAIN")
    local acme_domain="_acme-challenge.$CERTBOT_DOMAIN"
    local existing_txt
    existing_txt=$(dig +short @"$ns_server" "$acme_domain" TXT 2>/dev/null | tr -d '"')
    
    if [ -n "$existing_txt" ] && echo "$existing_txt" | grep -q "$CERTBOT_VALIDATION"; then
        # TXT already correctly set at authoritative NS
        # Skip provider call, timestamp recording, AND propagation check
        # (propagation check would record 0s and corrupt the average)
        [ "$VERBOSE" = true ] && echo "TXT record already set for $CERTBOT_DOMAIN at $ns_server. Skipping." > /dev/tty 2>/dev/null || true
        return 0
    fi
    
    # Call provider-specific certify implementation
    provider_certify "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION" "$WAN_IP"
    
    # Record DNS change timestamp for adaptive propagation timing
    cache_set_dns_change "$CERTBOT_DOMAIN" "TXT" "_acme-challenge" "$CERTBOT_VALIDATION"
    
    # Check DNS propagation
    check_dns_propagation "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION"
}

# Main cleanup function - orchestrates DNS challenge removal
cleanup() {
    local registrar="$1"
    init_provider_for_dns_operation "$registrar" "cleanup"
    
    # Call provider-specific cleanup implementation
    provider_cleanup "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION" "$WAN_IP"
}

# Main purchase function - orchestrates domain purchase
purchase() {
    local fqdn="$1"
    local registrar="$2"
    
    # Get credentials for provider
    if [ "$VERBOSE" = true ]; then
        get_credentials "$registrar" "purchase" 2>&1 || exit $?
    else
        get_credentials "$registrar" "purchase"
    fi
    
    # Load the provider
    if [ "$VERBOSE" = true ]; then
        load_provider "$registrar" 2>&1 || exit $?
    else
        load_provider "$registrar"
    fi
    
    # Export FQDN for provider use
    export FQDN="$fqdn"
    
    # Call provider-specific purchase implementation
    provider_purchase "$fqdn"
    local result=$?
    
    # Save domain as owned if purchase succeeded
    if [ $result -eq 0 ]; then
        save_domain_status "$fqdn" "owned" "$registrar"
    fi
    
    # Return status: 0=success, 1=insufficient balance, 2=other error
    exit $result
}

# Ensure domains DB exists with correct schema
ensure_domains_db() {
    # Database initialization is handled by the installer; fail fast if missing
    if [ ! -f "$DOMAINS_DB_PATH" ]; then
        echo "Error: Domains DB $DOMAINS_DB_PATH not found. Run the installer to initialize the database." >&2
        exit 1
    fi
}

# Helper to read existing status from local domains DB
get_local_domain_status() {
    local domain="$1"
    ensure_domains_db
    sqlite3 "$DOMAINS_DB_PATH" "SELECT status, registrar FROM domains WHERE domain='$domain' LIMIT 1;" 2>/dev/null
}

# Helper: resolve ownership checks to the base domain.
# For now, subdomains are normalized by removing the left-most label.
get_effective_ownership_domain() {
    local domain="$1"

    if [[ "$domain" =~ ^[^.]+\.(.+\..+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$domain"
    fi
}

# Helper to upsert status into local domains DB
save_domain_status() {
    local domain="$1"; local status="$2"; local registrar="$3"
    local effective_domain
    effective_domain=$(get_effective_ownership_domain "$domain")
    ensure_domains_db

    # Only persist final statuses: 'owned', 'free', 'taken'
    # Never persist 'unavailable' or 'unknown' - these are transient/echo-only
    if [ "$status" = "owned" ] || [ "$status" = "free" ] || [ "$status" = "taken" ]; then
        sqlite3 "$DOMAINS_DB_PATH" "INSERT INTO domains (domain, status, registrar) VALUES ('$effective_domain', '$status', CASE WHEN '$registrar' = '' THEN NULL ELSE '$registrar' END) ON CONFLICT(domain) DO UPDATE SET status=excluded.status, registrar=excluded.registrar;" 2>/dev/null
    fi
    # Note: we do NOT delete records for other statuses - leave existing DB state unchanged
}

# Helper: check if local certificate exists for domain (very simple heuristic)
has_local_certificate() {
    local domain="$1"
    if [ -d "/etc/letsencrypt/live/$domain" ]; then
        return 0
    fi
    return 1
}

# Helper: parse certbot certificates output to get certificate information
# Returns a list of: domain|issue_date|expiry_date
# Format: YYYY-MM-DD for both dates
parse_certbot_certificates() {
    if ! command -v certbot >/dev/null 2>&1; then
        return 1
    fi
    
    local certbot_output
    certbot_output=$(certbot certificates 2>/dev/null || true)
    
    if [ -z "$certbot_output" ]; then
        return 1
    fi
    
    # Parse the certbot output
    # certbot certificates output format example:
    # Certificate Name: example.com
    #   Domains: example.com
    #   Expiry Date: 2024-03-15 12:34:56+00:00 (VALID: 89 days)
    
    local current_domain=""
    local current_expiry=""
    
    while IFS= read -r line; do
        if echo "$line" | grep -q "Certificate Name:"; then
            current_domain=$(echo "$line" | sed 's/.*Certificate Name: //' | tr -d ' ')
        elif echo "$line" | grep -q "Expiry Date:"; then
            # Extract date in format YYYY-MM-DD HH:MM:SS
            current_expiry=$(echo "$line" | sed 's/.*Expiry Date: //' | awk '{print $1}')
            
            if [ -n "$current_domain" ] && [ -n "$current_expiry" ]; then
                # Calculate issue date (typically 90 days before expiry for Let's Encrypt)
                # Use date command to subtract 90 days from expiry
                local issue_date
                if date --version 2>&1 | grep -q "GNU"; then
                    # GNU date
                    issue_date=$(date -d "$current_expiry - 90 days" +%Y-%m-%d 2>/dev/null || echo "")
                else
                    # BSD/macOS date
                    issue_date=$(date -v-90d -j -f "%Y-%m-%d" "$current_expiry" +%Y-%m-%d 2>/dev/null || echo "")
                fi
                
                if [ -n "$issue_date" ]; then
                    echo "$current_domain|$issue_date|$current_expiry"
                fi
                
                current_domain=""
                current_expiry=""
            fi
        fi
    done <<< "$certbot_output"
    
    return 0
}

# Helper: check if DNS has been initialized for a domain
# Returns 0 if DNS is properly initialized, 1 otherwise
check_domain_dns_initialized() {
    local domain="$1"
    local wan_ip="$2"
    
    # Use the existing quick check function
    if check_init_dns_propagation_quick "$domain" "$wan_ip" 2>/dev/null; then
        return 0
    fi
    
    return 1
}

# Helper: update domain certificate and DNS information in database
# Usage: update_domain_cert_dns_info DOMAIN CERT_DATE DNS_INIT
update_domain_cert_dns_info() {
    local domain="$1"
    local cert_date="$2"  # YYYY-MM-DD or empty
    local dns_init="$3"   # 1 for initialized, 0 for not, empty to skip
    
    ensure_domains_db
    
    # Build the SQL update statement dynamically
    local sql_updates=()
    
    if [ -n "$cert_date" ]; then
        sql_updates+=("cert_date='$cert_date'")
    fi
    
    if [ -n "$dns_init" ]; then
        sql_updates+=("dns_init=$dns_init")
    fi
    
    if [ ${#sql_updates[@]} -eq 0 ]; then
        return 0
    fi
    
    # Join updates with commas
    local update_clause=$(IFS=,; echo "${sql_updates[*]}")
    
    # Update the domain if it exists
    sqlite3 "$DOMAINS_DB_PATH" "UPDATE domains SET $update_clause WHERE domain='$domain';" 2>/dev/null || true
}

# Helper: get WHOIS info for a domain
# Fetches WHOIS, parses it, and caches only the extracted values (1h TTL):
#   - whois_registrar: normalized registrar name
#   - whois_available: true/false (based on "No match" detection)
# Sets globals: WHOIS_REGISTRAR (normalized), WHOIS_AVAILABLE (true/false)
# Returns 0 on success, 1 on failure
get_whois_info() {
    local domain="$1"
    WHOIS_REGISTRAR=""
    WHOIS_AVAILABLE="false"
    
    # Check centralized cache first
    local cached_registrar cached_available
    if cached_registrar=$(cache_get "whois_registrar" "$domain"); then
        # Convert sentinel _none_ back to empty string
        [ "$cached_registrar" = "_none_" ] && cached_registrar=""
        WHOIS_REGISTRAR="$cached_registrar"
        # Also get availability from cache
        cached_available=$(cache_get "whois_available" "$domain") || cached_available="false"
        WHOIS_AVAILABLE="$cached_available"
        return 0
    fi
    
    if ! command -v whois >/dev/null 2>&1; then
        return 1
    fi
    
    local out
    out=$(whois "$domain" 2>/dev/null || true)
    
    if [ -z "$out" ]; then
        return 1
    fi
    
    # Check for "No match" - indicates domain may be available
    if echo "$out" | grep -qi "No match for"; then
        WHOIS_AVAILABLE="true"
        WHOIS_REGISTRAR=""
    else
        WHOIS_AVAILABLE="false"
        # Extract registrar from WHOIS output
        local raw_registrar
        raw_registrar=$(echo "$out" | grep -i '^registrar:' | head -n1 | sed -E 's/^[Rr]egistrar:[[:space:]]*//; s/^[[:space:]]+|[[:space:]]+$//g')
        WHOIS_REGISTRAR=$(normalize_registrar "$raw_registrar")
    fi
    
    # Cache the extracted values (not the full WHOIS output)
    cache_set "whois_registrar" "$domain" "${WHOIS_REGISTRAR:-_none_}"
    cache_set "whois_available" "$domain" "$WHOIS_AVAILABLE"
    
    return 0
}

# Helper: normalize registrar name to canonical form for database storage
# Detects known registrars via regex and returns normalized name
normalize_registrar() {
    local raw="$1"
    local lower
    lower=$(echo "$raw" | tr '[:upper:]' '[:lower:]')
    
    # Match known registrars using regex patterns
    # Return canonical names matching provider files (with .com where applicable)
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
        # Unknown registrar - keep original lowercased and trimmed
        echo "$lower" | sed 's/[^a-z0-9.-]//g'
    else
        echo ""
    fi
}

# Helper: detect registrar for a domain using check_status
# Returns registrar name or empty string if not found
detect_registrar_for_domain() {
    local fqdn="$1"
    local check_output
    
    # Propagate verbose mode to subcommand by calling fqdnmgr directly with -v if set
    if [ "$VERBOSE" = true ]; then
        vecho "Detecting registrar for $fqdn..."
        check_output=$("$0" check "$fqdn" -v 2>&1)
        local check_exit=$?
        if [ $check_exit -ne 0 ]; then
            vecho "Warning: check command failed with exit code $check_exit" >&2
        fi
    else
        check_output=$(check_status "$fqdn" 2>/dev/null)
    fi
    
    # Extract registrar from output (format: status=xxx registrar=yyy)
    local detected_registrar
    detected_registrar=$(echo "$check_output" | grep -oE 'registrar=[^ ]+' | cut -d'=' -f2)
    
    if [ -z "$detected_registrar" ]; then
        vecho "Debug: Failed to detect registrar for $fqdn" >&2
        vecho "Debug: check_status output: $check_output" >&2
    fi
    
    echo "$detected_registrar"
}

# Helper: process a single domain's init DNS records
# Returns: 0=success, 1=error, 2=skipped (not owned)
# Sets LAST_DOMAIN_STATUS for reporting
process_single_domain_init() {
    local fqdn="$1"
    local hint_registrar="$2"  # optional hint from -r flag
    local sync_mode="$3"
    local override_mode="$4"  # "override" to delete existing records
    local max_wait="${5:-600}"  # Default to 600 seconds if not provided
    
    LAST_DOMAIN_STATUS="error"
    
    # Detect the actual registrar via whois/check
    local detected_registrar
    detected_registrar=$(detect_registrar_for_domain "$fqdn")
    
    local actual_registrar=""
    
    if [ -n "$detected_registrar" ]; then
        actual_registrar="$detected_registrar"
        
        # If user provided a hint and it doesn't match, warn (only if verbose)
        if [ -n "$hint_registrar" ] && [ "$hint_registrar" != "$detected_registrar" ]; then
            [ "$VERBOSE" = true ] && echo "Warning: Domain $fqdn is at $detected_registrar, not $hint_registrar" >&2
        fi
    elif [ -n "$hint_registrar" ]; then
        # Whois detection failed, try user's hint
        actual_registrar="$hint_registrar"
    else
        # No registrar could be determined
        vecho "Error: Could not determine registrar for $fqdn" >&2
        LAST_DOMAIN_STATUS="no-registrar"
        return 1
    fi
    
    # Normalize registrar
    actual_registrar=$(normalize_registrar "$actual_registrar")
    
    if [ -z "$actual_registrar" ]; then
        vecho "Error: Could not normalize registrar for $fqdn" >&2
        LAST_DOMAIN_STATUS="no-registrar"
        return 1
    fi
    
    # Get credentials for provider
    if [ "$VERBOSE" = true ]; then
        if ! get_credentials "$actual_registrar" "setInitDNSRecords" 2>&1; then
            echo "Error: No credentials for registrar $actual_registrar" >&2
            LAST_DOMAIN_STATUS="no-credentials"
            return 1
        fi
    else
        if ! get_credentials "$actual_registrar" "setInitDNSRecords" 2>/dev/null; then
            echo "Error: No credentials for registrar $actual_registrar" >&2
            LAST_DOMAIN_STATUS="no-credentials"
            return 1
        fi
    fi
    
    # Load the provider
    if [ "$VERBOSE" = true ]; then
        if ! load_provider "$actual_registrar" 2>&1; then
            echo "Error: Failed to load provider $actual_registrar" >&2
            LAST_DOMAIN_STATUS="provider-error"
            return 1
        fi
    else
        if ! load_provider "$actual_registrar" 2>/dev/null; then
            echo "Error: Failed to load provider $actual_registrar" >&2
            LAST_DOMAIN_STATUS="provider-error"
            return 1
        fi
    fi
    
    # Get WAN IP
    if ! get_wan_ip; then
        vecho "Error: Failed to determine WAN IP" >&2
        LAST_DOMAIN_STATUS="wan-ip-error"
        return 1
    fi
    
    # Check if DNS records are already correctly set at authoritative NS
    # This prevents false re-setting which would corrupt propagation timing data
    local ns_server
    ns_server=$(get_cached_ns "$fqdn")
    local dns_already_set=true
    
    # Check A record for @ (root domain)
    local a_root_check=$(dig +short @"$ns_server" "$fqdn" A 2>/dev/null)
    if [ -z "$a_root_check" ] || ! echo "$a_root_check" | grep -q "$WAN_IP"; then
        dns_already_set=false
    fi
    
    # Check A record for * (wildcard)
    if [ "$dns_already_set" = true ]; then
        local a_wildcard_check=$(dig +short @"$ns_server" "wildcard-test.${fqdn}" A 2>/dev/null)
        if [ -z "$a_wildcard_check" ] || ! echo "$a_wildcard_check" | grep -q "$WAN_IP"; then
            dns_already_set=false
        fi
    fi
    
    # Check MX record
    if [ "$dns_already_set" = true ]; then
        local mx_check=$(dig +short @"$ns_server" "$fqdn" MX 2>/dev/null)
        if [ -z "$mx_check" ] || ! echo "$mx_check" | grep -q "mail.${fqdn}"; then
            dns_already_set=false
        fi
    fi
    
    # Skip early return if override mode is set - we need to re-call the API to delete other records
    if [ "$dns_already_set" = true ] && [ "$override_mode" != "override" ]; then
        vecho "DNS records already correctly set for $fqdn at $ns_server. Skipping provider call."
        # DNS already propagated - skip the propagation loop entirely
        # This prevents corrupting the average with 0s measurements
        LAST_DOMAIN_STATUS="success"
        return 0
    fi
    
    # Track whether we should skip propagation check (records already propagated)
    local skip_propagation_check=false
    
    if [ "$dns_already_set" = true ] && [ "$override_mode" = "override" ]; then
        vecho "DNS records already set for $fqdn, but override mode requested. Re-setting records..."
        # Records already propagated - we'll call API but skip propagation check
        skip_propagation_check=true
    else
        vecho "Setting init DNS records for $fqdn via $actual_registrar..."
    fi

    # Log that we're about to call the provider (one-line, non-fatal)
    printf '%s [provider-call] %s %s %s override=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$actual_registrar" "provider_set_init_dns_records" "$fqdn" "${override_mode:-false}" >> "$LOG_FILE" 2>/dev/null || true
    vecho "Invoking provider_set_init_dns_records for $fqdn via $actual_registrar (wan=$WAN_IP, override=${override_mode:-false})"

    # Call provider-specific single-domain init implementation
    provider_set_init_dns_records "$fqdn" "$WAN_IP" "" "$override_mode"
    local result=$?
    
    if [ $result -ne 0 ]; then
        LAST_DOMAIN_STATUS="api-error"
        return 1
    fi
    
    # Record DNS change timestamps for adaptive propagation timing
    # Only set these when we actually made DNS changes (records weren't already set)
    if [ "$skip_propagation_check" != true ]; then
        cache_set_dns_change "$fqdn" "A" "@" "$WAN_IP"
        cache_set_dns_change "$fqdn" "A" "*" "$WAN_IP"
        cache_set_dns_change "$fqdn" "MX" "@" "mail.${fqdn}"
    fi
    
    # Skip propagation check if records were already propagated
    # This prevents corrupting the average propagation time with near-0 measurements
    if [ "$skip_propagation_check" = true ]; then
        vecho "DNS records already propagated for $fqdn. Skipping propagation check."
        LAST_DOMAIN_STATUS="success"
        return 0
    fi
    
    # If sync mode, wait for DNS propagation with adaptive timing
    if [ "$sync_mode" = "sync" ]; then
        local elapsed=0
        local a_root_ok=false
        local a_wildcard_ok=false
        local mx_ok=false
        
        # Get the authoritative NS for adaptive timing
        local ns_server
        ns_server=$(get_cached_ns "$fqdn")
        
        # Get average propagation time for this NS
        local avg_propagation
        avg_propagation=$(get_avg_propagation_time "$ns_server" "$actual_registrar")
        
        echo "Waiting for DNS propagation (timeout: ${max_wait}s)..." > /dev/tty
        [ "$VERBOSE" = true ] && echo "  [NS: $ns_server] average propagation time: ${avg_propagation}s" > /dev/tty
        
        # Track first check timestamp for adaptive timing
        # Check if we already have a DNS change timestamp (script restart scenario)
        local first_check_ts
        first_check_ts=$(cache_get_dns_change "$fqdn" "A" "@" "$WAN_IP" 2>/dev/null) || first_check_ts=$(date +%s)
        
        local is_first_check=true
        local check_start_ts
        check_start_ts=$(date +%s)
        
        # Print initial status line (first check happens immediately, no "next:")
        echo "  $fqdn: [Init DNS] checking..." > /dev/tty
        
        while [ $elapsed -lt $max_wait ]; do
            local remaining=$((max_wait - elapsed))
            
            if check_init_dns_propagation "$fqdn" "$WAN_IP" "$elapsed" "$avg_propagation" "$max_wait"; then
                # Move up and clear the status line, then print success
                printf '\033[1A\r\033[K  %s: \033[32mPROPAGATED\033[0m (%ds)\n' "$fqdn" "$elapsed" > /dev/tty
                [ "$VERBOSE" = true ] && echo "DNS propagation complete for $fqdn." > /dev/tty
                
                # Calculate actual propagation time and update average
                local now_ts
                now_ts=$(date +%s)
                local actual_propagation=$((now_ts - first_check_ts))
                update_avg_propagation_time "$ns_server" "$actual_propagation"
                
                # Clean up DNS change tracking entries
                cache_delete_dns_change "$fqdn" "A" "@" "$WAN_IP"
                cache_delete_dns_change "$fqdn" "A" "*" "$WAN_IP"
                cache_delete_dns_change "$fqdn" "MX" "@" "mail.${fqdn}"
                
                # Re-set records with production TTL (7200s = 2 hours)
                vecho "Updating TTL to 7200s for production use..."
                # Log TTL-update provider call
                printf '%s [provider-call] %s %s %s ttl=7200 override=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$actual_registrar" "provider_set_init_dns_records" "$fqdn" "${override_mode:-false}" >> "$LOG_FILE" 2>/dev/null || true
                [ "$VERBOSE" = true ] && echo "Invoking provider_set_init_dns_records (ttl=7200) for $fqdn via $actual_registrar" > /dev/tty
                provider_set_init_dns_records "$fqdn" "$WAN_IP" 7200 "$override_mode"
                
                a_root_ok=false; a_wildcard_ok=false; mx_ok=false

                LAST_DOMAIN_STATUS="success"
                return 0
            fi
            
            # First check happens immediately, subsequent checks use adaptive timing
            if [ "$is_first_check" = true ]; then
                is_first_check=false
                # First check done, now we wait - continue to calculate wait interval
            fi
            
            # Calculate next wait interval using adaptive timing
            local wait_interval
            wait_interval=$(calculate_next_wait "$ns_server" "$first_check_ts")
            
            # Ensure we don't exceed max_wait
            if [ $((elapsed + wait_interval)) -gt $max_wait ]; then
                wait_interval=$((max_wait - elapsed))
                [ "$wait_interval" -le 0 ] && break
            fi
            
            # Countdown timer with unified format: [avg: X | next: Y | elapsed: Z | timeout: T]
            local countdown=$wait_interval
            while [ $countdown -gt 0 ]; do
                local current_elapsed=$((elapsed + (wait_interval - countdown)))
                print_dns_wait_status "$fqdn" "Init DNS" "$avg_propagation" "$countdown" "$current_elapsed" "$max_wait" "tty"
                sleep 1
                countdown=$((countdown - 1))
            done
            
            elapsed=$((elapsed + wait_interval))
        done
        
        # Timeout - update status line
        printf '\033[1A\r\033[K  %s: \033[31mTIMEOUT\033[0m (%ds)\n' "$fqdn" "$max_wait" > /dev/tty
        [ "$VERBOSE" = true ] && echo "Warning: DNS propagation timed out for $fqdn" > /dev/tty
        a_root_ok=false; a_wildcard_ok=false; mx_ok=false
        LAST_DOMAIN_STATUS="timeout"
        return 1
    fi
    
    LAST_DOMAIN_STATUS="success"
    return 0
}

# Main setInitDNSRecords function - unified DNS initialization
# Usage: setInitDNSRecords [-d "DOMAIN(S)"] [-r REGISTRAR] [-o] [--sync] [--timeout SECONDS]
# At least one of -d or -r is required.
# -d: space-separated domain(s) to process
# -r: registrar (hint if -d given, required otherwise for batch mode)
# -o: override mode - delete all existing DNS records before setting initial ones
# If only -r: process all owned domains at registrar (interactive if -v)
# --sync: wait for DNS propagation before returning
# --timeout: maximum wait time in seconds for DNS propagation (default: 600)
# Shorthand: single argument without flag is treated as -d
setInitDNSRecords() {
    local domains_arg=""
    local registrar_arg=""
    local sync_mode=""
    local override_mode=""
    local timeout_arg="600"
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            -d)
                shift
                domains_arg="$1"
                ;;
            -r)
                shift
                registrar_arg="$1"
                ;;
            -o)
                override_mode="override"
                ;;
            --sync)
                sync_mode="sync"
                ;;
            --timeout)
                shift
                if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; then
                    timeout_arg="$1"
                else
                    echo "Error: --timeout requires a positive integer (seconds)" >&2
                    echo "Usage: setInitDNSRecords [-d \"DOMAIN(S)\"] [-r REGISTRAR] [-o] [--sync] [--timeout SECONDS]" >&2
                    return 1
                fi
                ;;
            -*)
                echo "Error: Unknown argument '$1'" >&2
                echo "Usage: setInitDNSRecords [-d \"DOMAIN(S)\"] [-r REGISTRAR] [-o] [--sync] [--timeout SECONDS]" >&2
                return 1
                ;;
            *)
                # Positional argument without flag - treat as domain (-d)
                if [ -z "$domains_arg" ]; then
                    domains_arg="$1"
                else
                    # Append to existing domains (space-separated)
                    domains_arg="$domains_arg $1"
                fi
                ;;
        esac
        shift
    done
    
    # Validate: at least one of -d or -r is required
    if [ -z "$domains_arg" ] && [ -z "$registrar_arg" ]; then
        echo "Error: At least one of -d or -r is required" >&2
        echo "Usage: setInitDNSRecords [-d \"DOMAIN(S)\"] [-r REGISTRAR] [-o] [--sync] [--timeout SECONDS]" >&2
        return 1
    fi
    
    # Normalize registrar if provided
    local registrar_norm=""
    if [ -n "$registrar_arg" ]; then
        registrar_norm=$(normalize_registrar "$registrar_arg")
    fi
    
    # Track results for reporting
    local -a domain_results=()  # Format: "domain:status"
    local success_count=0
    local total_count=0
    
    if [ -n "$domains_arg" ]; then
        # MODE: Process specific domain(s) provided via -d
        # -r is used as a hint (non-conclusive)
        
        # Split domains by space
        read -ra DOMAINS_TO_PROCESS <<< "$domains_arg"
        total_count=${#DOMAINS_TO_PROCESS[@]}
        
        vecho "Processing $total_count domain(s)..."
        
        for domain in "${DOMAINS_TO_PROCESS[@]}"; do
            process_single_domain_init "$domain" "$registrar_norm" "$sync_mode" "$override_mode" "$timeout_arg"
            local result=$?
            
            domain_results+=("$domain:$LAST_DOMAIN_STATUS")
            
            if [ $result -eq 0 ]; then
                ((success_count++))
            fi
        done
        
    else
        # MODE: Process domains from registrar (only -r provided)
        # Interactive mode if -v, batch all otherwise
        
        if [ -z "$registrar_norm" ]; then
            echo "Error: Registrar is required when -d is not provided" >&2
            return 1
        fi
        
        # Get credentials for provider
        if [ "$VERBOSE" = true ]; then
            get_credentials "$registrar_norm" "setInitDNSRecords" 2>&1 || return $?
        else
            get_credentials "$registrar_norm" "setInitDNSRecords"
        fi
        
        # Load the provider
        if [ "$VERBOSE" = true ]; then
            load_provider "$registrar_norm" 2>&1 || return $?
        else
            load_provider "$registrar_norm"
        fi
        
        # Get WAN IP
        if ! get_wan_ip; then
            echo "Error: Failed to determine WAN IP" >&2
            return 1
        fi
        
        # Fetch owned domains from registrar
        vecho "Fetching owned domains from $registrar_norm..."
        # In verbose mode, suppress provider output since we'll show interactive prompt
        # In non-verbose mode, let provider output pass through for batch processing
        if [ "$VERBOSE" = true ]; then
            provider_list_owned_domains "$WAN_IP" "$override_mode" >/dev/null
        else
            provider_list_owned_domains "$WAN_IP" "$override_mode"
        fi
        local list_result=$?
        
        if [ $list_result -eq 2 ]; then
            # All domains already initialized (only relevant when not in override mode)
            if [ -z "$override_mode" ]; then
                vecho "All domains already initialized."
                return 0
            else
                # In override mode, this shouldn't happen, but handle gracefully
                echo "No domains found" >&2
                return 1
            fi
        elif [ $list_result -ne 0 ]; then
            echo "Error: Failed to fetch domain list" >&2
            return 1
        fi
        
        local domain_count=${#OWNED_DOMAINS_LIST[@]}
        
        if [ $domain_count -eq 0 ]; then
            vecho "No owned domains found at $registrar_norm"
            return 0
        fi
        
        local selected_domains=()
        
        if [ "$VERBOSE" = true ] && [ "$NON_INTERACTIVE" != true ]; then
            # Interactive mode: prompt for selection (only when -v is set and -ni is not set)
            echo ""
            echo "Found $domain_count domain(s) at $registrar_norm:"
            for ((i=0; i<domain_count; i++)); do
                echo "  $((i+1))) ${OWNED_DOMAINS_LIST[$i]}"
            done
            echo ""
            echo "Enter domain numbers to initialize (e.g., 1,3-5 or 'all'):"
            echo "Press Enter for all, or Ctrl+C to cancel"
            read -t 60 -p "> " domain_selection
            
            # Default to all if empty or timeout
            if [ -z "$domain_selection" ]; then
                domain_selection="all"
                vecho "Auto-selecting all domains"
            fi
            
            # Parse the selection
            parse_domain_selection "$domain_selection" "$domain_count"
            
            if [ ${#SELECTED_INDICES[@]} -eq 0 ]; then
                echo "No valid domains selected" >&2
                return 1
            fi
            
            # Build list of selected domain names
            for idx in "${SELECTED_INDICES[@]}"; do
                selected_domains+=("${OWNED_DOMAINS_LIST[$idx]}")
            done
        else
            # Non-interactive: process all domains (when -v is not set, or when -ni is set)
            selected_domains=("${OWNED_DOMAINS_LIST[@]}")
        fi
        
        total_count=${#selected_domains[@]}
        vecho "Processing $total_count domain(s)..."
        
        # Use provider batch function for rate-limited processing
        # Pass sync_mode and timeout_arg so batch function can wait for propagation when --sync is specified
        provider_set_all_domains_init_records "$WAN_IP" "$override_mode" "$sync_mode" "$timeout_arg" "${selected_domains[@]}"
        local batch_result=$?
        
        # For batch mode, we trust the provider's internal tracking
        # Set success if batch completed (even partially)
        if [ $batch_result -eq 0 ]; then
            success_count=$total_count
            for domain in "${selected_domains[@]}"; do
                domain_results+=("$domain:success")
            done
        else
            # Batch had issues, mark as partial
            success_count=1  # At least consider partial success
            for domain in "${selected_domains[@]}"; do
                domain_results+=("$domain:batch-processed")
            done
        fi
    fi
    
    # Print report if verbose and multiple domains
    if [ "$VERBOSE" = true ] && [ ${#domain_results[@]} -gt 1 ]; then
        echo ""
        echo "=== DNS Init Report ==="
        for entry in "${domain_results[@]}"; do
            local domain="${entry%%:*}"
            local status="${entry#*:}"
            echo "$domain $status"
        done
        echo "======================="
    fi
    
    # Print concise summary for non-verbose mode
    if [ "$VERBOSE" != true ]; then
        if [ $success_count -eq $total_count ] && [ $total_count -gt 0 ]; then
            echo "Success: All $total_count domain(s) initialized successfully"
        elif [ $success_count -gt 0 ]; then
            echo "Partial success: $success_count/$total_count domain(s) initialized"
        else
            echo "Error: Failed to initialize DNS records"
        fi
    fi
    
    # Return success if at least one domain succeeded (and no API errors for all)
    if [ $success_count -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# Main check_status implementation
check_status() {
    local fqdn="$1"
    local provided_registrar="$2"
    local ownership_domain=""


    if [ -z "$fqdn" ]; then
        echo "Error: FQDN is required" >&2
        return 1
    fi

    ownership_domain=$(get_effective_ownership_domain "$fqdn")
    vecho "Checking ownership for $ownership_domain (input: $fqdn)"

    # Normalize provided registrar upfront
    local provided_registrar_norm=""
    if [ -n "$provided_registrar" ]; then
        provided_registrar_norm=$(normalize_registrar "$provided_registrar")
    fi

    # 1) Check local domains DB first
    local db_row db_status db_registrar
    db_row=$(get_local_domain_status "$ownership_domain")
    if [ -n "$db_row" ]; then
        db_status=$(echo "$db_row" | cut -d'|' -f1)
        db_registrar=$(echo "$db_row" | cut -d'|' -f2)
        # Final statuses: free, owned, taken - return immediately
        # Transient status: unavailable - continue checking to resolve
        if [ "$db_status" = "free" ] || [ "$db_status" = "owned" ] || [ "$db_status" = "taken" ]; then
            echo "status=$db_status registrar=${db_registrar:-}" 
            return 0
        fi
        # unavailable is transient, continue to re-check
    fi

    # 2) Check local certificate existence
    if has_local_certificate "$ownership_domain"; then
        save_domain_status "$ownership_domain" "owned" "$provided_registrar_norm"
        echo "status=owned registrar=${provided_registrar_norm:-}"
        return 0
    fi

    # 3) Use whois lookup to infer registrar and basic availability
    local whois_registrar_norm status_decision registrar_to_save
    get_whois_info "$ownership_domain" || true

    # Check for "No match" - indicates domain might be available
    # Don't conclude "free" yet - let decision_evaluate handle it
    # (may use TLD priority to verify via registrar API)
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
    # Centralized decision: determine what to do next using lightweight checks
    decision_evaluate "$whois_registrar_norm" "$provided_registrar_norm" "$ownership_domain"

    case "$DECISION_ACTION" in
        use_tld_priority)
            registrar_for_api="$DECISION_REGISTRAR"
            ;;
        use_whois)
            registrar_for_api="$DECISION_REGISTRAR"
            ;;
        use_provided)
            registrar_for_api="$DECISION_REGISTRAR"
            ;;
        prompt_provided)
            # Interactive for provided registrar when creds missing: prompt to add creds or echo unknown
            echo ""
            echo "No credentials found for '${DECISION_REGISTRAR}'. Choose an action:"
            echo "  1) Add credentials for '${DECISION_REGISTRAR}' now"
            echo "  2) Save as 'unknown' (do not persist)"
            read -t 30 -p "Enter choice [1/2]: " user_choice

            case "$user_choice" in
                1)
                    read -p "Enter API username for '${DECISION_REGISTRAR}': " new_username
                    read -s -p "Enter API key for '${DECISION_REGISTRAR}': " new_api_key
                    echo ""
                    if [ -n "$new_username" ] && [ -n "$new_api_key" ]; then
                        if command -v fqdncredmgr >/dev/null 2>&1; then
                            if [ "$VERBOSE" = true ]; then
                                fqdncredmgr add "$DECISION_REGISTRAR" "$new_username" -p "$new_api_key" -v
                            else
                                fqdncredmgr add "$DECISION_REGISTRAR" "$new_username" -p "$new_api_key"
                            fi
                            if [ $? -eq 0 ]; then
                                echo "Credentials added. Re-run 'fqdnmgr check $ownership_domain' to check ownership."
                            else
                                echo "Error: Failed to add credentials" >&2
                            fi
                        else
                            echo "Error: fqdncredmgr command not found" >&2
                        fi
                    else
                        echo "Error: Username and API key are required" >&2
                    fi
                    echo "status=unknown registrar="
                    return 0
                    ;;
                2|*)
                    echo "status=unknown registrar="
                    return 0
                    ;;
            esac
            ;;
        prompt_whois)
            # Interactive for WHOIS-detected registrar when creds missing
            echo ""
            echo "No credentials found for WHOIS registrar '${DECISION_REGISTRAR}'. Choose an action:"
            echo "  1) Add credentials for '${DECISION_REGISTRAR}' now"
            echo "  2) Save as 'unknown' (do not persist)"
            read -t 30 -p "Enter choice [1/2]: " user_choice

            case "$user_choice" in
                1)
                    read -p "Enter API username for '${DECISION_REGISTRAR}': " new_username
                    read -s -p "Enter API key for '${DECISION_REGISTRAR}': " new_api_key
                    echo ""
                    if [ -n "$new_username" ] && [ -n "$new_api_key" ]; then
                        if command -v fqdncredmgr >/dev/null 2>&1; then
                            if [ "$VERBOSE" = true ]; then
                                fqdncredmgr add "$DECISION_REGISTRAR" "$new_username" -p "$new_api_key" -v
                            else
                                fqdncredmgr add "$DECISION_REGISTRAR" "$new_username" -p "$new_api_key"
                            fi
                            if [ $? -eq 0 ]; then
                                echo "Credentials added. Re-run 'fqdnmgr check $ownership_domain' to check ownership."
                            else
                                echo "Error: Failed to add credentials" >&2
                            fi
                        else
                            echo "Error: fqdncredmgr command not found" >&2
                        fi
                    else
                        echo "Error: Username and API key are required" >&2
                    fi
                    echo "status=unknown registrar="
                    return 0
                    ;;
                2|*)
                    echo "status=unknown registrar="
                    return 0
                    ;;
            esac
            ;;
        prompt_mismatch)
            # Interactive mismatch: prioritize WHOIS, offer 3 choices
            echo ""
            echo "WHOIS registrar '${DECISION_REGISTRAR}' has no credentials. Choose an action:"
            echo "  1) Provide credentials for WHOIS registrar ('${DECISION_REGISTRAR}') now"
            echo "  2) Save as 'unknown' (do not persist)"
            echo "  3) Check registrar provided on the command line instead"
            read -t 30 -p "Enter choice [1/2/3]: " user_choice

            case "$user_choice" in
                1)
                    read -p "Enter API username for '${DECISION_REGISTRAR}': " new_username
                    read -s -p "Enter API key for '${DECISION_REGISTRAR}': " new_api_key
                    echo ""
                    if [ -n "$new_username" ] && [ -n "$new_api_key" ]; then
                        if command -v fqdncredmgr >/dev/null 2>&1; then
                            if [ "$VERBOSE" = true ]; then
                                fqdncredmgr add "$DECISION_REGISTRAR" "$new_username" -p "$new_api_key" -v
                            else
                                fqdncredmgr add "$DECISION_REGISTRAR" "$new_username" -p "$new_api_key"
                            fi
                            if [ $? -eq 0 ]; then
                                echo "Credentials added. Re-run 'fqdnmgr check $ownership_domain' to check ownership."
                            else
                                echo "Error: Failed to add credentials" >&2
                            fi
                        else
                            echo "Error: fqdncredmgr command not found" >&2
                        fi
                    else
                        echo "Error: Username and API key are required" >&2
                    fi
                    echo "status=unknown registrar="
                    return 0
                    ;;
                2)
                    echo "status=unknown registrar="
                    return 0
                    ;;
                3)
                    # Check provided registrar instead
                    # If creds exist, proceed to API query; if not, show secondary prompt
                    if has_creds_for "$provided_registrar_norm"; then
                        registrar_for_api="$provided_registrar_norm"
                        # Break out to continue with API query below
                    else
                        # Secondary prompt: creds not found for provided registrar
                        echo ""
                        echo "No credentials found for provided registrar '${provided_registrar_norm}'. Choose an action:"
                        echo "  1) Provide credentials for '${provided_registrar_norm}' now"
                        echo "  2) Save as 'unknown' (do not persist)"
                        read -t 30 -p "Enter choice [1/2]: " sub_choice

                        case "$sub_choice" in
                            1)
                                read -p "Enter API username for '${provided_registrar_norm}': " new_username
                                read -s -p "Enter API key for '${provided_registrar_norm}': " new_api_key
                                echo ""
                                if [ -n "$new_username" ] && [ -n "$new_api_key" ]; then
                                    if command -v fqdncredmgr >/dev/null 2>&1; then
                                        if [ "$VERBOSE" = true ]; then
                                            fqdncredmgr add "$provided_registrar_norm" "$new_username" -p "$new_api_key" -v
                                        else
                                            fqdncredmgr add "$provided_registrar_norm" "$new_username" -p "$new_api_key"
                                        fi
                                        if [ $? -eq 0 ]; then
                                            echo "Credentials added. Re-run 'fqdnmgr check $ownership_domain' to check ownership."
                                        else
                                            echo "Error: Failed to add credentials" >&2
                                        fi
                                    else
                                        echo "Error: fqdncredmgr command not found" >&2
                                    fi
                                else
                                    echo "Error: Username and API key are required" >&2
                                fi
                                echo "status=unknown registrar="
                                return 0
                                ;;
                            2|*)
                                echo "status=unknown registrar="
                                return 0
                                ;;
                        esac
                    fi
                    ;;
                *)
                    echo "status=unknown registrar="
                    return 0
                    ;;
            esac
            ;;
        check_provided)
            # Non-interactive: check provided registrar for creds and act
            if has_creds_for "$DECISION_REGISTRAR"; then
                registrar_for_api="$DECISION_REGISTRAR"
            else
                # Default non-interactive fallback: echo unknown and do not save
                echo "status=unknown registrar="
                return 0
            fi
            ;;
        unknown_stdout)
            echo "status=unknown registrar="
            return 0
            ;;
    esac

    # If we reach here, registrar_for_api should be set (from use_whois, use_provided, 
    # check_provided with creds, or prompt_mismatch option 3 with creds)
    # Now query the provider API to get the final status
    
    if [ -z "$registrar_for_api" ]; then
        # Shouldn't happen, but handle gracefully
        echo "status=unknown registrar="
        return 0
    fi

    # Get credentials (may already be set from earlier decision logic)
    if [ -z "$PROVIDER_USERNAME" ] || [ -z "$PROVIDER_API_KEY" ]; then
        if [ "$VERBOSE" = true ]; then
            get_credentials "$registrar_for_api" "check" 2>&1 || {
                vecho "Warning: Failed to get credentials for $registrar_for_api" >&2
                echo "status=unknown registrar="
                return 0
            }
        else
            get_credentials "$registrar_for_api" "check" 2>/dev/null || {
                echo "status=unknown registrar="
                return 0
            }
        fi
    fi

    # Get WAN IP
    if ! get_wan_ip; then
        vecho "Error: Failed to determine WAN IP" >&2
        echo "status=unknown registrar="
        return 0
    fi

    # Load provider plugin
    if [ "$VERBOSE" = true ]; then
        load_provider "$registrar_for_api" 2>&1 || {
            vecho "Warning: Failed to load provider $registrar_for_api" >&2
            echo "status=unknown registrar="
            return 0
        }
    else
        load_provider "$registrar_for_api" 2>/dev/null || {
            echo "status=unknown registrar="
            return 0
        }
    fi

    # Query provider for domain status
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

    # Final status determination based on provider response
    case "$provider_status" in
        owned|free|taken)
            save_domain_status "$ownership_domain" "$provider_status" "$registrar_for_api"
            echo "status=$provider_status registrar=$registrar_for_api"
            ;;
        *)
            # Provider returned something unexpected - echo unknown, don't save
            echo "status=unknown registrar="
            ;;
    esac
}

# Validate that a given string is a fully-qualified domain name (FQDN).
# Returns 0 if valid, 1 otherwise.
# Rules enforced:
# - Overall length <= 253
# - Contains at least one dot
# - Each label length 1..63
# - Labels contain only A-Z a-z 0-9 and hyphen
# - Labels do not start or end with a hyphen
# - Last label (TLD) is alphabetic and at least 2 characters
is_valid_fqdn() {
    local fqdn="$1"
    if [ -z "$fqdn" ]; then
        return 1
    fi

    # Overall length
    if [ ${#fqdn} -gt 253 ]; then
        return 1
    fi

    # Must contain at least one dot
    if [[ "$fqdn" != *.* ]]; then
        return 1
    fi

    # Split labels on dot
    IFS='.' read -ra labels <<< "$fqdn"
    local lab
    for lab in "${labels[@]}"; do
        # Label length
        if [ ${#lab} -lt 1 ] || [ ${#lab} -gt 63 ]; then
            return 1
        fi

        # No leading or trailing hyphen
        if [[ "$lab" =~ ^- ]] || [[ "$lab" =~ -$ ]]; then
            return 1
        fi

        # Allowed characters: alnum and hyphen only
        if ! [[ "$lab" =~ ^[A-Za-z0-9-]+$ ]]; then
            return 1
        fi
    done

    # TLD checks: last label should be alphabetic and at least 2 chars
    local tld
    tld="${labels[-1]}"
    if ! [[ "$tld" =~ ^[A-Za-z]{2,}$ ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# Parallel DNS Propagation Check with Per-Domain Countdown
# =============================================================================

# Check DNS propagation for multiple domains in parallel with per-domain countdown
# Usage: wait_for_dns_propagation_parallel <wan_ip> <max_wait> <domain1> [domain2] ...
# Each domain gets its own line showing countdown until timeout
wait_for_dns_propagation_parallel() {
    local wan_ip="$1"
    local max_wait="$2"
    shift 2
    local domains=("$@")
    
    local num_domains=${#domains[@]}
    if [ $num_domains -eq 0 ]; then
        return 0
    fi
    
    # Initialize tracking arrays
    declare -A domain_status      # "pending" | "propagated" | "timeout"
    declare -A domain_start_ts    # When we started checking this domain
    declare -A domain_ns_server   # Authoritative NS for each domain
    declare -A domain_avg_prop    # Average propagation time for each NS
    
    # Initialize all domains as pending
    for domain in "${domains[@]}"; do
        domain_status["$domain"]="pending"
        domain_start_ts["$domain"]=$(date +%s)
        domain_ns_server["$domain"]=$(get_cached_ns "$domain" 2>/dev/null || echo "")
        local ns="${domain_ns_server[$domain]}"
        domain_avg_prop["$domain"]=$(get_avg_propagation_time "$ns" 2>/dev/null || echo "$DEFAULT_AVG_PROPAGATION")
    done
    
    echo "Checking DNS propagation for $num_domains domain(s) (timeout: ${max_wait}s)..." > /dev/tty
    
    # Print initial status lines (one per domain) - first check happens immediately
    for domain in "${domains[@]}"; do
        local avg="${domain_avg_prop[$domain]}"
        echo "  $domain: [avg: ${avg}s | elapsed: 0s | timeout: ${max_wait}s]" > /dev/tty
    done
    
    # Main loop - check all domains until all are done or timed out
    local all_done=false
    while [ "$all_done" = false ]; do
        all_done=true
        local now_ts=$(date +%s)
        
        # Move cursor up to beginning of domain status area
        printf '\033[%dA' "$num_domains" > /dev/tty
        
        local idx=0
        for domain in "${domains[@]}"; do
            local status="${domain_status[$domain]}"
            local start_ts="${domain_start_ts[$domain]}"
            local elapsed=$((now_ts - start_ts))
            local remaining=$((max_wait - elapsed))
            local avg="${domain_avg_prop[$domain]}"
            
            if [ "$status" = "pending" ]; then
                all_done=false
                
                # Check if timed out
                if [ $remaining -le 0 ]; then
                    domain_status["$domain"]="timeout"
                    printf '\r\033[K  %s: \033[31mTIMEOUT\033[0m (%ds)\n' "$domain" "$max_wait" > /dev/tty
                else
                    # Check DNS propagation (non-blocking, single check)
                    if check_init_dns_propagation_quick "$domain" "$wan_ip"; then
                        domain_status["$domain"]="propagated"
                        
                        # Update average propagation time
                        local ns="${domain_ns_server[$domain]}"
                        if [ -n "$ns" ]; then
                            update_avg_propagation_time "$ns" "$elapsed" 2>/dev/null || true
                        fi
                        
                        # Clean up DNS change tracking entries
                        cache_delete_dns_change "$domain" "A" "@" "$wan_ip" 2>/dev/null || true
                        cache_delete_dns_change "$domain" "A" "*" "$wan_ip" 2>/dev/null || true
                        cache_delete_dns_change "$domain" "MX" "@" "mail.${domain}" 2>/dev/null || true
                        
                        printf '\r\033[K  %s: \033[32mPROPAGATED\033[0m (%ds)\n' "$domain" "$elapsed" > /dev/tty
                    else
                        # Still pending - show unified format (no "next:" since checks are continuous)
                        printf '\r\033[K  %s: [avg: %ds | elapsed: %ds | timeout: %ds]\n' "$domain" "$avg" "$elapsed" "$max_wait" > /dev/tty
                    fi
                fi
            else
                # Already done (propagated or timeout) - just reprint status
                if [ "$status" = "propagated" ]; then
                    printf '\r\033[K  %s: \033[32mPROPAGATED\033[0m\n' "$domain" > /dev/tty
                else
                    printf '\r\033[K  %s: \033[31mTIMEOUT\033[0m (%ds)\n' "$domain" "$max_wait" > /dev/tty
                fi
            fi
            
            idx=$((idx + 1))
        done
        
        # If not all done, wait 1 second before next check
        if [ "$all_done" = false ]; then
            sleep 1
        fi
    done
    
    # Count results
    local propagated_count=0
    local timeout_count=0
    for domain in "${domains[@]}"; do
        if [ "${domain_status[$domain]}" = "propagated" ]; then
            propagated_count=$((propagated_count + 1))
        else
            timeout_count=$((timeout_count + 1))
        fi
    done
    
    echo "" > /dev/tty
    echo "Propagation complete: $propagated_count propagated, $timeout_count timed out" > /dev/tty
    
    # Return success if at least one propagated
    [ $propagated_count -gt 0 ] && return 0 || return 1
}

# Quick DNS propagation check for parallel processing (no output, no loops)
# Returns 0 if propagated, 1 if not yet
check_init_dns_propagation_quick() {
    local domain="$1"
    local wan_ip="$2"
    
    # Get authoritative NS
    local ns_server
    ns_server=$(get_cached_ns "$domain" 2>/dev/null)
    [ -z "$ns_server" ] && return 1
    
    # Check A record for @ at authoritative NS
    local a_root=$(dig +short @"$ns_server" "$domain" A 2>/dev/null)
    [ -z "$a_root" ] || ! echo "$a_root" | grep -q "$wan_ip" && return 1
    
    # Check A record for wildcard at authoritative NS
    local a_wildcard=$(dig +short @"$ns_server" "wildcard-test.${domain}" A 2>/dev/null)
    [ -z "$a_wildcard" ] || ! echo "$a_wildcard" | grep -q "$wan_ip" && return 1
    
    # Check MX record at authoritative NS
    local mx=$(dig +short @"$ns_server" "$domain" MX 2>/dev/null)
    [ -z "$mx" ] || ! echo "$mx" | grep -q "mail.${domain}" && return 1
    
    # All records confirmed at authoritative NS
    # Now check Google DNS for global propagation
    local a_root_google=$(dig +short @8.8.8.8 "$domain" A 2>/dev/null)
    [ -z "$a_root_google" ] || ! echo "$a_root_google" | grep -q "$wan_ip" && return 1
    
    local a_wildcard_google=$(dig +short @8.8.8.8 "wildcard-test.${domain}" A 2>/dev/null)
    [ -z "$a_wildcard_google" ] || ! echo "$a_wildcard_google" | grep -q "$wan_ip" && return 1
    
    local mx_google=$(dig +short @8.8.8.8 "$domain" MX 2>/dev/null)
    [ -z "$mx_google" ] || ! echo "$mx_google" | grep -q "mail.${domain}" && return 1
    
    return 0
}

# =============================================================================

# Function to check DNS propagation for initial DNS records (A @, A *, MX @)
# This verifies the records set by provider_set_init_records()
# Returns 0 if all records are propagated, 1 otherwise (single check, no loop)
# Parameters: domain wan_ip [elapsed_seconds] [avg_propagation] [timeout]
check_init_dns_propagation() {
    local domain="$1"
    local wan_ip="$2"
    # Optional parameters for display
    local elapsed_seconds="${3:-0}"
    local avg_propagation="${4:-}"
    local timeout="${5:-}"
    
    # Phase 1: Check authoritative nameserver first (avoid negative caching at Google)
    # Get the authoritative NS for this domain (cached for consistency)
    local ns_server
    ns_server=$(get_cached_ns "$domain")
    
    # Check A record for @ (root domain) at authoritative NS
    local a_root_auth=$(dig +short @"$ns_server" "$domain" A 2>/dev/null)
    if [ -z "$a_root_auth" ] || ! echo "$a_root_auth" | grep -q "$wan_ip"; then
        return 1
    fi
    
    # Check A record for wildcard at authoritative NS
    local a_wildcard_auth=$(dig +short @"$ns_server" "wildcard-test.${domain}" A 2>/dev/null)
    if [ -z "$a_wildcard_auth" ] || ! echo "$a_wildcard_auth" | grep -q "$wan_ip"; then
        return 1
    fi
    
    # Check MX record at authoritative NS
    local mx_auth=$(dig +short @"$ns_server" "$domain" MX 2>/dev/null)
    if [ -z "$mx_auth" ] || ! echo "$mx_auth" | grep -q "mail.${domain}"; then
        return 1
    fi
    
    if [ "$VERBOSE" = true ]; then
        echo "  [Auth NS] All records confirmed at authoritative nameserver" > /dev/tty
    fi
    
    # Phase 2: Now safe to check Google DNS for global propagation
    # Check A record for @ (root domain)
    local a_root_response=$(dig +short @8.8.8.8 "${domain}" A 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$a_root_response" ]; then
        if echo "$a_root_response" | grep -q "$wan_ip"; then
            a_root_ok=true
        fi
    fi
    
    # Check A record for * (wildcard) - query a random subdomain
    local a_wildcard_response=$(dig +short @8.8.8.8 "wildcard-test.${domain}" A 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$a_wildcard_response" ]; then
        if echo "$a_wildcard_response" | grep -q "$wan_ip"; then
            a_wildcard_ok=true
        fi
    fi
    
    # Check MX record for @ (root domain) - mail.$domain with priority 10
    local mx_response=$(dig +short @8.8.8.8 "${domain}" MX 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$mx_response" ]; then
        if echo "$mx_response" | grep -q "mail.${domain}"; then
            mx_ok=true
        fi
    fi
    
    # All records propagated
    if [ "$a_root_ok" = true ] && [ "$a_wildcard_ok" = true ] && [ "$mx_ok" = true ]; then
        if [ "$VERBOSE" = true ]; then
            echo "  [Google DNS] All records propagated globally" > /dev/tty
        fi
        return 0  # Success
    fi
    
    return 1
}

# Function to check DNS propagation for ACME TXT record with adaptive timing
check_dns_propagation() {
    local domain="$1"
    local expected_value="$2"
    local max_wait="${3:-600}"  # Default to 600 seconds (10 minutes) if not provided
    local acme_domain="_acme-challenge.$domain"
    local elapsed=0
    local ns_propagated=false
    
    # Get the authoritative NS for this domain (cached for consistency)
    local ns_server
    ns_server=$(get_cached_ns "$domain")
    
    # Get average propagation time for this NS
    local avg_propagation
    avg_propagation=$(get_avg_propagation_time "$ns_server")
    
    # Track first check timestamp for adaptive timing
    # Check if we already have a DNS change timestamp (script restart scenario)
    local first_check_ts
    first_check_ts=$(cache_get_dns_change "$domain" "TXT" "_acme-challenge" "$expected_value" 2>/dev/null) || first_check_ts=$(date +%s)
    echo > /dev/tty
    echo "Waiting for ACME TXT record propagation (timeout: ${max_wait}s)..." > /dev/tty
    # First check happens immediately - show initial line without "next:"
    echo "  $domain: [Auth NS] checking..." > /dev/tty
    
    local is_first_check=true
    
    while [ $elapsed -lt $max_wait ]; do
        local remaining=$((max_wait - elapsed))
        
        # Check authoritative nameserver first (avoid negative caching)
        local auth_txt=$(dig +short @"$ns_server" "$acme_domain" TXT 2>/dev/null | tr -d '"')
        
        if [ -z "$auth_txt" ] || ! echo "$auth_txt" | grep -q "$expected_value"; then
            # First check happens immediately, subsequent checks use adaptive timing
            if [ "$is_first_check" = true ]; then
                is_first_check=false
                # First check done, now we wait
            fi
            
            # Calculate next wait interval using adaptive timing
            local wait_interval
            wait_interval=$(calculate_next_wait "$ns_server" "$first_check_ts")
            
            # Ensure we don't exceed max_wait
            if [ $((elapsed + wait_interval)) -gt $max_wait ]; then
                wait_interval=$((max_wait - elapsed))
                [ "$wait_interval" -le 0 ] && break
            fi
            
            # Countdown timer with unified format: [avg: X | next: Y | elapsed: Z | timeout: T]
            local countdown=$wait_interval
            while [ $countdown -gt 0 ]; do
                local current_elapsed=$((elapsed + (wait_interval - countdown)))
                print_dns_wait_status "$domain" "Auth NS" "$avg_propagation" "$countdown" "$current_elapsed" "$max_wait" "tty"
                sleep 1
                countdown=$((countdown - 1))
            done
            
            elapsed=$((elapsed + wait_interval))
            continue
        fi
        
        if [ "$ns_propagated" = false ]; then
            printf '  %s: [Auth NS] confirmed, checking [Google]...\n' "$domain" > /dev/tty
            ns_propagated=true
        fi
        
        # Check Google DNS (8.8.8.8) for global propagation
        local response=$(dig +short @8.8.8.8 "${acme_domain}" TXT 2>/dev/null | tr -d '"')
        local dig_exit=$?
        
        if [ $dig_exit -eq 0 ] && [ -n "$response" ]; then
            # Check if the expected value is in the response
            if echo "$response" | grep -q "$expected_value"; then
                printf '  %s: [Google] \033[32mPROPAGATED\033[0m (%ds)\n' "$domain" "$elapsed" > /dev/tty
                
                # Calculate actual propagation time and update average BEFORE buffer
                # The buffer time should NOT be counted in the average calculation
                local now_ts
                now_ts=$(date +%s)
                local actual_propagation=$((now_ts - first_check_ts))
                update_avg_propagation_time "$ns_server" "$actual_propagation"
                
                # Buffer to allow other DNS resolvers (Let's Encrypt) to catch up
                local buffer=${DNS_PROPAGATION_BUFFER:-10}
                printf '  %s: [Buffer] waiting %ds for global DNS sync...\n' "$domain" "$buffer" > /dev/tty
                sleep "$buffer"
                printf '  %s: [Buffer] done\n' "$domain" > /dev/tty
                echo > /dev/tty
                
                # Clean up DNS change tracking entry
                cache_delete_dns_change "$domain" "TXT" "_acme-challenge" "$expected_value"
                
                return 0  # Success - DNS propagated
            fi
        fi
        
        # Calculate next wait interval for Google DNS phase
        local wait_interval
        wait_interval=$(calculate_next_wait "$ns_server" "$first_check_ts")
        
        # Ensure we don't exceed max_wait
        if [ $((elapsed + wait_interval)) -gt $max_wait ]; then
            wait_interval=$((max_wait - elapsed))
            [ "$wait_interval" -le 0 ] && break
        fi
        
        # Countdown timer with unified format: [avg: X | next: Y | elapsed: Z | timeout: T]
        local countdown=$wait_interval
        while [ $countdown -gt 0 ]; do
            local current_elapsed=$((elapsed + (wait_interval - countdown)))
            print_dns_wait_status "$domain" "Global" "$avg_propagation" "$countdown" "$current_elapsed" "$max_wait" "tty"
            sleep 1
            countdown=$((countdown - 1))
        done
        
        elapsed=$((elapsed + wait_interval))
    done
    
    printf '  %s: \033[31mTIMEOUT\033[0m (%ds)\n' "$domain" "$max_wait" > /dev/tty
    return 1  # Timeout - DNS did not propagate within max_wait
}

# List all domains for a registrar
# Usage: list [REGISTRAR] [local|remote]
#   No args     - list all local domains with their status and registrar (machine parsable)
#   REGISTRAR local  - query the local domains DB for domains associated with REGISTRAR
#   REGISTRAR remote - use provider API to fetch domains and save only non-free statuses to DB
list() {
    local registrar="$1"
    local mode="$2"

    # If no registrar provided, list all local domains
    if [ -z "$registrar" ]; then
        ensure_domains_db

        local rows
        rows=$(sqlite3 "$DOMAINS_DB_PATH" "SELECT domain, status, registrar FROM domains ORDER BY domain;" 2>/dev/null || true)

        if [ -z "$rows" ]; then
            return 0
        fi

        # Machine-parsable output: domain|status|registrar
        while IFS="|" read -r domain status registrar; do
            [ -z "$domain" ] && continue
            printf "%s|%s|%s\n" "$domain" "$status" "$registrar"
        done <<< "$rows"

        return 0
    fi

    # If registrar provided, mode is required
    if [ -z "$mode" ]; then
        echo "Error: when REGISTRAR is specified, mode (local|remote) is required" >&2
        return 1
    fi

    mode=$(echo "$mode" | tr '[:upper:]' '[:lower:]')
    if [ "$mode" != "local" ] && [ "$mode" != "remote" ]; then
        echo "Error: mode must be either 'local' or 'remote'" >&2
        return 1
    fi

    # Normalize registrar for DB lookups
    local registrar_norm
    registrar_norm=$(normalize_registrar "$registrar")

    if [ "$mode" = "local" ]; then
        # Local: query domains DB for entries matching this registrar
        ensure_domains_db

        local rows
        rows=$(sqlite3 "$DOMAINS_DB_PATH" "SELECT domain, status FROM domains WHERE registrar='${registrar_norm}' ORDER BY domain;" 2>/dev/null || true)

        if [ -z "$rows" ]; then
            vecho "No domains found for registrar '${registrar_norm}' in local DB"
            return 0
        fi

        vecho "Local domains for registrar '${registrar_norm}':"
        local idx=1
        while IFS="|" read -r domain status; do
            [ -z "$domain" ] && continue
            if [ "$VERBOSE" = true ]; then
                echo "  ${idx}) ${domain} [${status}]"
            else
                # Machine-parsable: domain<single-space>status
                printf "%s %s\n" "$domain" "$status"
            fi
            idx=$((idx + 1))
        done <<< "$rows"

        return 0
    fi

    # Remote: use provider API to fetch domains and save only non-free statuses
    ensure_domains_db

    # Get credentials for provider
    if [ "$VERBOSE" = true ]; then
        get_credentials "$registrar" "list" 2>&1 || return $?
    else
        get_credentials "$registrar" "list"
    fi
    
    # Load provider
    if [ "$VERBOSE" = true ]; then
        load_provider "$registrar" 2>&1 || return $?
    else
        load_provider "$registrar"
    fi

    # Get WAN IP
    if ! get_wan_ip; then
        echo "Error: Failed to determine WAN IP" >&2
        return 1
    fi

    vecho "Fetching domains from $registrar via API..."

    # Capture provider output (many providers print numbered lists)
    local provider_output
    provider_output=$(provider_list_all_domains "$WAN_IP" 2>/dev/null || true)

    # If provider is Wedos, provider_list_all_domains emits machine-parsable
    # lines in the format: domain|status. Use that output directly and
    # persist only domains with status 'active' (as 'owned'). Do NOT call
    # provider_check_domain_status for Wedos to avoid extra queries.
    if [ "$registrar_norm" = "wedos.com" ]; then
        local lines
        lines=$(printf "%s" "$provider_output" | sed '/^\s*$/d')

        if [ -z "$lines" ]; then
            vecho "No domains returned by provider API or none detected in output."
            if [ -n "$provider_output" ] && [ "$VERBOSE" = true ]; then
                echo "Provider output:" >&2
                printf "%s\n" "$provider_output" | sed -n '1,200p' >&2
            fi
            return 0
        fi

        # Collect all active domains for later processing
        local active_domains=()
        local idx=1
        while IFS='|' read -r domain status; do
            [ -z "$domain" ] && continue

            # Only persist when status == active (user requirement)
            if [ "$status" = "active" ]; then
                save_domain_status "$domain" "owned" "$registrar_norm"
                active_domains+=("$domain")
            fi

            if [ "$VERBOSE" = true ]; then
                echo "  ${idx}) ${domain} [${status}]"
            else
                echo "$domain"
            fi
            idx=$((idx + 1))
        done <<< "$lines"

        # After fetching all domains, update certificate and DNS information
        if [ ${#active_domains[@]} -gt 0 ]; then
            vecho "Checking certificate and DNS status for domains..."
            
            # Parse certbot certificates output
            local cert_info
            cert_info=$(parse_certbot_certificates 2>/dev/null || true)
            
            # Create associative arrays for certificate dates
            declare -A cert_dates
            if [ -n "$cert_info" ]; then
                while IFS='|' read -r cert_domain issue_date expiry_date; do
                    [ -z "$cert_domain" ] && continue
                    cert_dates["$cert_domain"]="$issue_date"
                done <<< "$cert_info"
            fi
            
            # Check each domain for certificate and DNS status
            for domain in "${active_domains[@]}"; do
                # Check if domain has certificate
                local cert_date=""
                if [ -n "${cert_dates[$domain]}" ]; then
                    cert_date="${cert_dates[$domain]}"
                    vecho "  $domain: certificate issued on $cert_date"
                fi
                
                # Check if DNS is initialized
                local dns_init=""
                if check_domain_dns_initialized "$domain" "$WAN_IP" 2>/dev/null; then
                    dns_init="1"
                    vecho "  $domain: DNS initialized"
                else
                    dns_init="0"
                    vecho "  $domain: DNS not initialized"
                fi
                
                # Update database with certificate and DNS information
                if [ -n "$cert_date" ] || [ -n "$dns_init" ]; then
                    update_domain_cert_dns_info "$domain" "$cert_date" "$dns_init"
                fi
            done
        fi

        return 0
    fi

    # Try to extract domain names from provider output. Support numbered lists
    local domains
    domains=$(printf "%s" "$provider_output" | sed -n 's/^[[:space:]]*[0-9]\+)\s*//p' | sed '/^\s*$/d')

    # If no numbered lines found, try to extract FQDN-like tokens
    if [ -z "$domains" ]; then
        domains=$(printf "%s" "$provider_output" | grep -Eo '([a-zA-Z0-9_-]+\.)+[a-zA-Z]{2,}' | sort -u || true)
    fi

    if [ -z "$domains" ]; then
        vecho "No domains returned by provider API or none detected in output."
        # If provider printed something helpful, show it in verbose mode
        if [ -n "$provider_output" ] && [ "$VERBOSE" = true ]; then
            echo "Provider output:" >&2
            printf "%s\n" "$provider_output" | sed -n '1,200p' >&2
        fi
        return 0
    fi

    local idx=1
    vecho "Domains reported by provider:"
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        # Determine precise status via provider_check_domain_status if available
        local status="owned"
        if declare -F provider_check_domain_status >/dev/null 2>&1; then
            local provider_result
            provider_result=$(provider_check_domain_status "$domain" "$WAN_IP" 2>/dev/null || true)
            if echo "$provider_result" | grep -q '^status='; then
                status=$(echo "$provider_result" | awk -F'=' '/^status=/{print $2; exit}')
            fi
        fi

        # Save to DB only if status is 'owned' or 'unavailable'. Other statuses are not persisted.
        if [ "$status" = "owned" ] || [ "$status" = "unavailable" ]; then
            save_domain_status "$domain" "$status" "$registrar_norm"
        else
            # Ensure any previous record is removed for non-persistable statuses
            save_domain_status "$domain" "$status" "$registrar_norm"
        fi

        if [ "$VERBOSE" = true ]; then
            # Human-readable (verbose) remote output: list domains only (server results imply owned)
            echo "  ${idx}) ${domain}"
        else
            # Machine-parsable: just the domain name
            echo "$domain"
        fi
        idx=$((idx + 1))
    done <<< "$domains"

    # After fetching all domains, update certificate and DNS information
    vecho "Checking certificate and DNS status for domains..."
    
    # Parse certbot certificates output
    local cert_info
    cert_info=$(parse_certbot_certificates 2>/dev/null || true)
    
    # Create associative arrays for certificate dates
    declare -A cert_dates
    if [ -n "$cert_info" ]; then
        while IFS='|' read -r cert_domain issue_date expiry_date; do
            [ -z "$cert_domain" ] && continue
            cert_dates["$cert_domain"]="$issue_date"
        done <<< "$cert_info"
    fi
    
    # Check each domain for certificate and DNS status
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        
        # Check if domain has certificate
        local cert_date=""
        if [ -n "${cert_dates[$domain]}" ]; then
            cert_date="${cert_dates[$domain]}"
            vecho "  $domain: certificate issued on $cert_date"
        fi
        
        # Check if DNS is initialized
        local dns_init=""
        if check_domain_dns_initialized "$domain" "$WAN_IP" 2>/dev/null; then
            dns_init="1"
            vecho "  $domain: DNS initialized"
        else
            dns_init="0"
            vecho "  $domain: DNS not initialized"
        fi
        
        # Update database with certificate and DNS information
        if [ -n "$cert_date" ] || [ -n "$dns_init" ]; then
            update_domain_cert_dns_info "$domain" "$cert_date" "$dns_init"
        fi
    done <<< "$domains"

    return 0
}

# Check for -v and -ni flags first (can appear anywhere)
for arg in "$@"; do
    [ "$arg" = "-v" ] && VERBOSE=true
    [ "$arg" = "-ni" ] && NON_INTERACTIVE=true
done
# Remove -v and -ni from args
set -- $(printf '%s\n' "$@" | grep -v '^-v$' | grep -v '^-ni$')

# Check for help flag
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
fi

# Check if at least one argument is provided
if [ $# -lt 1 ]; then
    usage
fi

# Get the function name from the first argument
FUNCTION_NAME="$1"
shift  # Remove the first argument, leaving any additional arguments

# Check if the function exists and call it
case "$FUNCTION_NAME" in
    "certify")
        if [ $# -lt 1 ]; then
            echo "Error: certify function requires REGISTRAR argument"
            echo "Usage: $0 certify <REGISTRAR>"
            exit 1
        fi
        REGISTRAR="$1"
        certify "$REGISTRAR"
        ;;
    "purchase")
        if [ $# -lt 2 ]; then
            echo "Error: purchase function requires FQDN and REGISTRAR arguments"
            echo "Usage: $0 purchase <FQDN> <REGISTRAR>"
            exit 1
        fi
        FQDN="$1"
        REGISTRAR="$2"
        purchase "$FQDN" "$REGISTRAR"
        ;;
    "cleanup")
        if [ $# -lt 1 ]; then
            echo "Error: cleanup function requires REGISTRAR argument"
            echo "Usage: $0 cleanup <REGISTRAR>"
            exit 1
        fi
        REGISTRAR="$1"
        cleanup "$REGISTRAR"
        ;;
    "check")
        if [ $# -lt 1 ]; then
            echo "Error: check function requires FQDN argument"
            echo "Usage: $0 check <FQDN> [REGISTRAR]"
            exit 1
        fi
        FQDN="$1"; shift

        # Validate that provided domain is a fully-qualified domain name (not a single label)
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
                echo "Error: unexpected argument '$1'"
                echo "Usage: $0 check <FQDN> [REGISTRAR]"
                exit 1
            fi
            shift
        done
        check_status "$FQDN" "$REGISTRAR"
        ;;
    "setInitDNSRecords")
        # Pass all remaining arguments directly to the function
        # The function handles its own argument parsing (-d, -r, --sync)
        setInitDNSRecords "$@"
        ;;
    "checkInitDns")
        if [ $# -lt 1 ]; then
            echo "Error: checkInitDns function requires FQDN argument"
            echo "Usage: $0 checkInitDns <FQDN>"
            exit 1
        fi
        FQDN="$1"
        if ! get_wan_ip; then
            echo "Error: Cannot proceed without WAN IP" >&2
            exit 1
        fi
        check_init_dns_propagation "$FQDN" "$WAN_IP"
        ;;
    "list")
        if [ $# -eq 0 ]; then
            # No arguments - list all local domains
            list
        elif [ $# -eq 1 ]; then
            echo "Error: when REGISTRAR is specified, mode (local|remote) is required"
            echo "Usage: $0 list [REGISTRAR] [local|remote]"
            exit 1
        else
            REGISTRAR="$1"
            MODE="$2"
            list "$REGISTRAR" "$MODE"
        fi
        ;;
    *)
        echo "Error: Unknown function '$FUNCTION_NAME'"
        echo "Available functions: certify, purchase, cleanup, check, setInitDNSRecords, checkInitDns, list"
        ;;
esac
