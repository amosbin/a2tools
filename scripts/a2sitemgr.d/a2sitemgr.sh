#!/bin/bash

# source prerequisites
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/a2sitemgr.d"
. "$SCRIPT_DIR/../getinput.d/getinput.sh"

# Disable errexit inherited from getinput.sh - we handle errors explicitly
set +e

# Initialize variables
MODE="domain"
IS_DOMAIN_SUBDOMAIN=false
BASE_DOMAIN_CONF=""

# Helper: get WAN_IP - reads from the process environment first, then the settings file, falls back to curl, caches for system-wide access
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
    
    # Fetch WAN IP from external service
    WAN_IP=$(curl -s ifconfig.me)
    
    if [ -z "$WAN_IP" ]; then
        echo "Error: Failed to determine WAN IP" >&2
        return 1
    fi
    
    # Cache to the settings file for system-wide access (requires root)
    if [ "$(id -u)" -eq 0 ]; then
        if grep -q "^WAN_IP=" "$WAN_IP_SETTINGS_FILE" 2>/dev/null; then
            sed -i "s|^WAN_IP=.*|WAN_IP=\"$WAN_IP\"|" "$WAN_IP_SETTINGS_FILE"
        else
            echo "WAN_IP=\"$WAN_IP\"" >> "$WAN_IP_SETTINGS_FILE"
        fi
    fi
    
    export WAN_IP
    return 0
}
PROXY_PORT=""
SECURED=false
FQDN=""
SUBDOMAIN=""
FQDN_BASE=""
CERT_DOMAIN=""
REGISTRAR=""
NON_INTERACTIVE=false
STRICT_MODE=false
VERBOSE=false
SET_INIT_DNS=false
SET_INIT_DNS_OVERRIDE=false
SET_INIT_DNS_SYNC=false

# Verbose echo - only prints when VERBOSE=true
vecho() { [ "$VERBOSE" = true ] && echo "$@" || true; }

# Get next available config number for a given prefix (0 for swc, 1 for proxypass)
# Usage: get_next_config_number <prefix> <name>
# Returns the full filename: prefix-NNNN-name.conf
get_next_config_number() {
    local prefix="$1"
    local name="$2"
    local config_dir="/etc/apache2/sites-available"
    
    # Check if a config with this name already exists (any number)
    local existing=$(ls -1 "$config_dir"/${prefix}-????-${name}.conf 2>/dev/null | head -n1)
    if [ -n "$existing" ]; then
        # Return the existing filename (basename only)
        basename "$existing"
        return 0
    fi
    
    # Collect all existing numbers for this prefix
    declare -A used_numbers
    for file in "$config_dir"/${prefix}-????-*.conf; do
        [ -f "$file" ] || continue
        local num=$(basename "$file" | sed -E 's/^[0-9]-([0-9]{4})-.*\.conf$/\1/')
        if [[ "$num" =~ ^[0-9]{4}$ ]]; then
            used_numbers["$num"]=1
        fi
    done
    
    # Find the first available number (filling gaps)
    local next_num=0
    while [ $next_num -le 9999 ]; do
        local padded=$(printf "%04d" $next_num)
        if [ -z "${used_numbers[$padded]+x}" ]; then
            echo "${prefix}-${padded}-${name}.conf"
            return 0
        fi
        ((next_num++))
    done
    
    echo "Error: No available config numbers for prefix $prefix" >&2
    return 1
}

# helper functions
handle_fqdnmgr_error() {
    local exit_code="$1"
    local output="$2"
    local context="$3"
    
    case "$exit_code" in
        10)
            echo "Error: Credentials daemon not running (socket not found)." >&2
            echo "Please ensure fqdncredmgrd service is running: sudo systemctl start fqdncredmgrd" >&2
            exit 1
            ;;
        11)
            local provider=$(echo "$output" | grep -oE 'CREDS_ERROR:no_credentials:(.+)' | cut -d: -f3)
            echo "Error: No credentials found for provider '$provider'." >&2
            echo "Please add credentials: sudo fqdncredmgr add $provider <username> -p <api_key>" >&2
            exit 1
            ;;
        12)
            echo "Error: Credentials database not found." >&2
            echo "Please run the installer to initialize the database." >&2
            exit 1
            ;;
        13|14|15)
            local err_detail=$(echo "$output" | grep -oE 'CREDS_ERROR:(.+)' | cut -d: -f2-)
            echo "Error: Credential error during $context: $err_detail" >&2
            exit 1
            ;;
        *)
            return 1
            ;;
    esac
}

usage() {
    local exit_code="${1:-0}"
    cat "$SCRIPT_DIR/usage.txt"
    exit "$exit_code"
}
check_prerequisites() {
    # Check if Apache is installed
    if ! command -v apache2 >/dev/null 2>&1 ; then
        echo "Error: Apache is not installed" >&2
        exit 1
    fi
    
    # Check required Apache modules
    local required_modules="rewrite ssl"
    if [ "$MODE" = "proxypass" ]; then
        required_modules="$required_modules proxy proxy_http"
    fi
    
    # Get loaded modules list (may fail if Apache config has errors)
    local loaded_modules
    loaded_modules=$(apache2ctl -M 2>/dev/null)
    local modules_check_failed=$?
    
    if [ $modules_check_failed -ne 0 ] || [ -z "$loaded_modules" ]; then
        echo "Warning: Could not verify Apache modules (apache2ctl -M failed - likely a config error exists)" >&2
        echo "Run 'apache2ctl configtest' to diagnose configuration issues" >&2
    else
        for module in $required_modules; do
            if ! echo "$loaded_modules" | grep -q "${module}_module"; then
                echo "Warning: Apache module 'mod_$module' does not appear to be enabled" >&2
                echo "You may need to run: a2enmod $module" >&2
            fi
        done
    fi
}
render_from_template_to_path() {
    local tpl="$1"; local target="$2"; local timeout="${3:-10}"

    # If target exists, prompt once with the provided timeout.
    if [ -f "$target" ]; then
        vecho "Warning: $target already exists."
        if [ "$NON_INTERACTIVE" = true ]; then
            vecho "Non-interactive mode: auto-accepting default (overwrite)."
            overwrite="Y"
        else
            overwrite=$(getInput "Overwrite $target? [Y/n] (auto-accept in ${timeout}s)" "Y" "$timeout" visible false true true)
            overwrite=${overwrite:-Y}
        fi
        case "$overwrite" in
            [Nn]* )
                vecho "Keeping existing $target. Exiting."
                exit 0
                ;;
            * )
                vecho "Overwriting $target"
                ;;
        esac
    fi

    # General substitutions (available in all modes)
    sed \
        -e "s|{{FQDN}}|${FQDN:-}|g" \
        "$tpl" > "$target"

    # Mode-specific substitutions
    case "$MODE" in
        domain)
            sed -i \
                -e "s|{{CERT_DOMAIN}}|$CERT_DOMAIN|g" \
                -e "s|{{FQDN_BASE}}|${FQDN_BASE:-}|g" \
                "$target"
            ;;
        swc)
            sed -i \
                -e "s|{{SUBDOMAIN}}|$SUBDOMAIN|g" \
                "$target"
            ;;
        proxypass)
            sed -i \
                -e "s|{{SUBDOMAIN}}|$SUBDOMAIN|g" \
                -e "s|{{FQDN_BASE}}|${FQDN_BASE:-}|g" \
                -e "s|{{CERT_DOMAIN}}|$CERT_DOMAIN|g" \
                -e "s|{{ACTUAL_SERVER_NAME}}|$ACTUAL_SERVER_NAME|g" \
                -e "s|{{PROXY_PROTOCOL}}|$PROXY_PROTOCOL|g" \
                -e "s|{{PROXY_PORT}}|$PROXY_PORT|g" \
                "$target"
            ;;
    esac
}
do_config(){
    # 1) Standard mode
    if [ "$MODE" = "domain" ]; then
        if [ "$IS_DOMAIN_SUBDOMAIN" = true ]; then
            # For subdomains, keep files under the base-domain tree and update base conf.
            if [ ! -d "/var/www/$CERT_DOMAIN/$SUBDOMAIN/public_html" ]; then
                mkdir -p "/var/www/$CERT_DOMAIN/$SUBDOMAIN/public_html"
                mkdir -p "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log"
                chown -R www-data:www-data "/var/www/$CERT_DOMAIN"
            fi

            # If base config is missing, create it first via recursive domain-mode call.
            if [ ! -f "$BASE_DOMAIN_CONF" ]; then
                vecho "Base domain configuration not found at $BASE_DOMAIN_CONF"
                vecho "Creating base domain configuration for $CERT_DOMAIN first..."

                RECURSIVE_ARGS=("$CERT_DOMAIN" -m domain)
                [ -n "$REGISTRAR" ] && RECURSIVE_ARGS+=(-r "$REGISTRAR")
                [ "$NON_INTERACTIVE" = true ] && RECURSIVE_ARGS+=(-ni)
                [ "$STRICT_MODE" = true ] && RECURSIVE_ARGS+=(-c)
                [ "$VERBOSE" = true ] && RECURSIVE_ARGS+=(-v)
                [ "$SET_INIT_DNS" = true ] && RECURSIVE_ARGS+=(--setInitDNSRecords)
                [ "$SET_INIT_DNS_OVERRIDE" = true ] && RECURSIVE_ARGS+=(-o)
                [ "$SET_INIT_DNS_SYNC" = true ] && RECURSIVE_ARGS+=(--sync)

                if ! "$0" "${RECURSIVE_ARGS[@]}"; then
                    echo "Error: Failed to create base domain configuration for $CERT_DOMAIN" >&2
                    exit 1
                fi

                if [ ! -f "$BASE_DOMAIN_CONF" ]; then
                    echo "Error: Base domain configuration was not created at $BASE_DOMAIN_CONF" >&2
                    exit 1
                fi
            fi

            CONF="$BASE_DOMAIN_CONF"
        else
            # Apex domain uses its own config file.
            if [ ! -d "/var/www/$FQDN/public_html" ]; then
                mkdir -p "/var/www/$FQDN/public_html"
                mkdir -p "/var/www/$FQDN/log"
                chown -R www-data:www-data "/var/www/$FQDN"
            fi

            CONF="/etc/apache2/sites-available/${FQDN}.conf"
            render_from_template_to_path "$SCRIPT_DIR/init_standard.conf.tpl" "$CONF" 10
        fi

        # Only call a2wcrecalc-dms if Docker-Mailserver is installed
        if command -v a2wcrecalc-dms >/dev/null 2>&1 && [ -d "/opt/compose/docker-mailserver/docker-data/dms/config" ]; then
            vecho "Calling a2wcrecalc-dms..."
            a2wcrecalc-dms || true
        fi

        return 0
    fi

    # 2) Subdomain Wildcard (SWC) mode
    if [ "$MODE" = "swc" ]; then
        # Validate FQDN format: subdomain.*
        if [[ ! "$FQDN" =~ ^[a-zA-Z0-9-]+\.\*$ ]]; then
            echo "Error: In subdomain wildcard mode (--swc), FQDN must be in format 'subdomain.*' (e.g., 'api.*')" >&2
            exit 1
        fi

        SUBDOMAIN="${FQDN%.*}"

        if [ "$SECURED" = true ] || [ -n "$PROXY_PORT" ] || [ -n "$REGISTRAR" ]; then
            echo "Error: Options -s/-p/-r are not valid with subdomain wildcard mode (use -m swc)" >&2
            exit 1
        fi

        # Get config filename with 0-XXXX prefix for swc mode
        CONF_FILENAME=$(get_next_config_number "0" "$SUBDOMAIN")
        CONF="/etc/apache2/sites-available/${CONF_FILENAME}"
        render_from_template_to_path "$SCRIPT_DIR/swc_min.conf.tpl" "$CONF" 10

        vecho "Created subdomain wildcard config: $CONF"

        if command -v a2wcrecalc >/dev/null 2>&1; then
            vecho "Calling a2wcrecalc $SUBDOMAIN..."
            a2wcrecalc "$SUBDOMAIN.*" || true
        else
            echo "Warning: a2wcrecalc not found. Please run it manually: a2wcrecalc $SUBDOMAIN.*" >&2
        fi

        vecho "Subdomain wildcard configuration complete for $FQDN"
        exit 0
    fi

    # 3) ProxyPass mode
    if [ "$MODE" = "proxypass" ]; then
        # Ensure per-domain log directory exists for symlinks
        if [ ! -d "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log" ]; then
            mkdir -p "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log"
            chown -R www-data:www-data "/var/www/$CERT_DOMAIN"
        fi

        # Get config filename with 1-XXXX prefix for proxypass mode
        # Use full FQDN (e.g., n8n.example1.com) instead of just subdomain to avoid naming collisions
        CONF_FILENAME=$(get_next_config_number "1" "$FQDN")
        CONF="/etc/apache2/sites-available/${CONF_FILENAME}"
        render_from_template_to_path "$SCRIPT_DIR/init_proxypass.conf.tpl" "$CONF" 10
        return 0
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d=*|--fqdn=*)
            # Assigned-style: -d=example.com or --fqdn=example.com
            FQDN="${1#*=}"
            shift
            ;;
        -d|--fqdn)
            # Separate-arg style: -d example.com or --fqdn example.com
            FQDN="$2"
            shift 2
            ;;
        -m=*|--mode=*)
            # Assigned-style: -m=pp or --mode=proxypass
            MODE="${1#*=}"
            shift
            ;;
        -m|--mode)
            # Separate-arg style: -m pp or --mode proxypass
            MODE="$2"
            shift 2
            ;;
        -r=*|--registrar=*)
            # Assigned-style: -r=namecheap or --registrar=namecheap
            REGISTRAR="${1#*=}"
            shift
            ;;
        -r|--registrar)
            # Separate-arg style: -r namecheap or --registrar namecheap
            REGISTRAR="$2"
            shift 2
            ;;
        -s|--secured)
            # Use HTTPS for ProxyPass
            SECURED=true
            shift
            ;;
        -p=*|--port=*)
            # Assigned-style: -p=3000 or --port=3000
            PROXY_PORT="${1#*=}"
            shift
            ;;
        -p|--port)
            # Separate-arg style: -p 3000 or --port 3000
            PROXY_PORT="$2"
            shift 2
            ;;
        -ni|--non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        -c|--strict)
            STRICT_MODE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --setInitDNSRecords)
            SET_INIT_DNS=true
            shift
            ;;
        -o|--override)
            SET_INIT_DNS_OVERRIDE=true
            shift
            ;;
        --sync)
            SET_INIT_DNS_SYNC=true
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        -*)
            echo "Unknown option $1"
            usage 1
            ;;
        *)
            # Positional arguments
            if [ -z "$FQDN" ]; then
                FQDN="$1"
            else
                echo "Too many arguments"
                usage 1
            fi
            shift
            ;;
    esac
done
case "$MODE" in
    domain)
        MODE="domain"
        ;;
    pp|proxypass)
        MODE="proxypass"
        ;;
    swc|subdomainWildCard)
        MODE="swc"
        ;;
    *)
        echo "Error: Unknown mode: $MODE" >&2
        usage 1
        ;;
esac

# Resolve registrar names strictly via `fqdncredmgr list` (no fallbacks)
if [ -n "$REGISTRAR" ]; then
    # Require fqdncredmgr to be available — no local fallbacks or hardcoded mappings
    if ! command -v fqdncredmgr >/dev/null 2>&1; then
        echo "Error: Registrar resolution requires 'fqdncredmgr' but it was not found in PATH." >&2
        exit 1
    fi

    if [ "$VERBOSE" = true ]; then
        CRED_LIST=$(fqdncredmgr list -v 2>/dev/null || true)
    else
        CRED_LIST=$(fqdncredmgr list 2>/dev/null || true)
    fi
    if [ -z "$CRED_LIST" ]; then
        echo "Error: 'fqdncredmgr list' returned no credentials; cannot resolve registrar '$REGISTRAR'." >&2
        exit 1
    fi

    # If user provided a full hostname (contains a dot), require an exact match in the creds list
    if [[ "$REGISTRAR" == *.* ]]; then
        if echo "$CRED_LIST" | grep -qw -- "$REGISTRAR"; then
            : # exact match found, keep as-is
        else
            echo "Error: Registrar '$REGISTRAR' not found in fqdncredmgr credentials." >&2
            exit 1
        fi
    else
        # Short name provided: attempt to find a credential entry containing the short name
        MATCH=$(echo "$CRED_LIST" | grep -Eo "[A-Za-z0-9._-]*${REGISTRAR}[A-Za-z0-9._-]*" | head -n1 || true)
        if [ -n "$MATCH" ]; then
            REGISTRAR="$MATCH"
        else
            echo "Error: Registrar short-name '$REGISTRAR' could not be resolved from fqdncredmgr list." >&2
            exit 1
        fi
    fi

    # Final validation: resolved registrar must look like a hostname
    if [[ ! "$REGISTRAR" =~ \.[A-Za-z0-9] ]]; then
        echo "Error: Resolved registrar '$REGISTRAR' does not appear to be a hostname." >&2
        exit 1
    fi
fi

check_prerequisites

# Ensure centralized log directory exists
mkdir -p /var/log/apache-collector
chown root:adm /var/log/apache-collector
chmod 750 /var/log/apache-collector

# Validations
if [ -z "$FQDN" ]; then
    echo "Error: FQDN is required" >&2
    exit 1
fi

# Early validation and variable setup for all modes
if [ "$MODE" = "domain" ]; then
    # Validate general FQDN format
    if [[ ! "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        echo "Error: Invalid FQDN format: $FQDN" >&2
        exit 1
    fi

    # proxypass-only options are invalid for domain mode
    if [ "$SECURED" = true ]; then
        echo "Error: -s/--secured option is only valid with proxypass mode (use -m pp)" >&2
        exit 1
    fi
    if [ -n "$PROXY_PORT" ]; then
        echo "Error: -p/--port option is only valid with proxypass mode (use -m pp)" >&2
        exit 1
    fi

    CERT_DOMAIN="$FQDN"
    FQDN_BASE="${FQDN%%.*}"

    # Domain mode with subdomain: use base-domain cert/config (example.com.conf).
    if [[ "$FQDN" =~ ^([^.]+)\.(.+\..+)$ ]]; then
        IS_DOMAIN_SUBDOMAIN=true
        SUBDOMAIN="${BASH_REMATCH[1]}"
        CERT_DOMAIN="${BASH_REMATCH[2]}"
        BASE_DOMAIN_CONF="/etc/apache2/sites-available/${CERT_DOMAIN}.conf"
    else
        IS_DOMAIN_SUBDOMAIN=false
        BASE_DOMAIN_CONF="/etc/apache2/sites-available/${FQDN}.conf"
    fi

elif [ "$MODE" = "proxypass" ]; then
    # Validate FQDN for proxypass (should be subdomain.base)
    if [[ "$FQDN" =~ ^([^.]+)\.(.+)$ ]]; then
        SUBDOMAIN="${BASH_REMATCH[1]}"
        FQDN_BASE="$SUBDOMAIN"
        CERT_DOMAIN="${BASH_REMATCH[2]}"
    else
        echo "Error: In proxypass mode, FQDN must be a subdomain (e.g., something.example.com)" >&2
        exit 1
    fi

    # PROXY_PORT is required for proxypass mode
    if [ -z "$PROXY_PORT" ]; then
        echo "Error: Proxy port (-p/--port) is required when using proxypass mode (use -m pp)" >&2
        exit 1
    fi

    # Set proxypass-specific variables early for template rendering
    if [ "$SECURED" = true ]; then
        PROXY_PROTOCOL="https"
    else
        PROXY_PROTOCOL="http"
    fi
    ACTUAL_SERVER_NAME="$FQDN"
    
    # Check if base domain configuration exists; if not, create it first.
    BASE_DOMAIN_CONF="/etc/apache2/sites-available/${CERT_DOMAIN}.conf"
    if [ ! -f "$BASE_DOMAIN_CONF" ]; then
        vecho "Base domain configuration not found at $BASE_DOMAIN_CONF"
        vecho "Creating base domain configuration for $CERT_DOMAIN first..."
        # Call this script recursively for domain mode
        RECURSIVE_ARGS=(-d "$CERT_DOMAIN" -m domain)
        [ -n "$REGISTRAR" ] && RECURSIVE_ARGS+=(-r "$REGISTRAR")
        [ "$NON_INTERACTIVE" = true ] && RECURSIVE_ARGS+=(-ni)
        [ "$STRICT_MODE" = true ] && RECURSIVE_ARGS+=(-c)
        [ "$VERBOSE" = true ] && RECURSIVE_ARGS+=(-v)
        
        if ! "$0" "${RECURSIVE_ARGS[@]}"; then
            echo "Error: Failed to create base domain configuration for $CERT_DOMAIN" >&2
            exit 1
        fi
        vecho "Base domain configuration created. Continuing with proxypass setup..."
    fi
fi

# STEP 1: Determine domain status and handle purchase / availability
{
    if [ "$MODE" = "domain" ] || [ "$MODE" = "proxypass" ]; then
        TARGET_DOMAIN="$FQDN"
        if [ "$MODE" = "proxypass" ]; then
            TARGET_DOMAIN="$CERT_DOMAIN"
        elif [ "$MODE" = "domain" ] && [ "$IS_DOMAIN_SUBDOMAIN" = true ]; then
            TARGET_DOMAIN="$CERT_DOMAIN"
        elif [ "$MODE" = "domain" ] && [[ "$FQDN" =~ ^([^.]+)\.(.+\..+)$ ]]; then
            TARGET_DOMAIN="${BASH_REMATCH[2]}"
        fi

        DOMAIN_STATUS="unknown"

        # Use fqdnmgr as single source of truth for status
        if ! command -v fqdnmgr >/dev/null 2>&1; then
            echo "Warning: fqdnmgr not found; domain ownership cannot be checked automatically." >&2
            echo "Please ensure domain $TARGET_DOMAIN is registered and DNS is configured before proceeding." >&2
        else
            FQDNMGR_ARGS=(check "$TARGET_DOMAIN")
            if [ -n "$REGISTRAR" ]; then
                FQDNMGR_ARGS+=("$REGISTRAR")
            fi
            if [ "$STRICT_MODE" = true ]; then
                FQDNMGR_ARGS+=("--strict")
            fi
            if [ "$VERBOSE" = true ]; then
                FQDNMGR_ARGS+=("-v")
            fi

            # Run fqdnmgr and show any prompts to the user if possible; otherwise, run it quietly without waiting for input.
            if [ -c /dev/tty ]; then
                # Let fqdnmgr show prompts to the user and capture its output.
                FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" < /dev/tty 2>&1)
            elif [ -t 0 ]; then
                # stdin is a terminal (fd 0); allow interactive reads from it.
                FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" 2>&1)
            else
                # If not interactive, run fqdnmgr quietly so it doesn't wait for user input.                echo "debug: No interactive terminal available; running fqdnmgr non-interactively"
                FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" < /dev/null 2>&1)
            fi
            FQDNMGR_EXIT=$?

            if [ $FQDNMGR_EXIT -ne 0 ]; then
                if ! handle_fqdnmgr_error "$FQDNMGR_EXIT" "$FQDNMGR_OUTPUT" "domain status check"; then
                    echo "Warning: fqdnmgr status check failed: $FQDNMGR_OUTPUT" >&2
                fi
            else
                # Get status and registrar from fqdnmgr output (preserve newlines with quotes)
                vecho "$FQDNMGR_OUTPUT"
                STATUS_VAL=$(echo "$FQDNMGR_OUTPUT" | grep -oE 'status=[^ ]+' | cut -d= -f2)
                REGISTRAR_VAL=$(echo "$FQDNMGR_OUTPUT" | grep -oE 'registrar=[^ ]+' | cut -d= -f2)

                if [ -n "$REGISTRAR_VAL" ]; then
                    REGISTRAR="$REGISTRAR_VAL"
                fi

                if [ -n "$STATUS_VAL" ]; then
                    DOMAIN_STATUS="$STATUS_VAL"
                fi
            fi
        fi

        case "$DOMAIN_STATUS" in
            free)
                if [ -z "$REGISTRAR" ]; then
                    echo "Error: Domain $TARGET_DOMAIN is free but no registrar specified (-r/--registrar)" >&2
                    exit 1
                fi
                if [ "$NON_INTERACTIVE" = true ]; then
                    vecho "Domain $TARGET_DOMAIN appears to be free. Non-interactive mode: defaulting to not purchasing and exiting."
                    exit 0
                fi
                purchase_ans=$(getInput "Domain $TARGET_DOMAIN appears to be free. Purchase it now? [y/N] (timeout in 10s)" "N" 10 visible false true true)
                purchase_ans=${purchase_ans:-N}
                case "$purchase_ans" in
                    [Yy]*)
                        vecho "Attempting to purchase $TARGET_DOMAIN via $REGISTRAR..."
                        if [ "$VERBOSE" = true ]; then
                            PURCHASE_OUTPUT=$(fqdnmgr purchase "$REGISTRAR" "$TARGET_DOMAIN" -v 2>&1)
                        else
                            PURCHASE_OUTPUT=$(fqdnmgr purchase "$REGISTRAR" "$TARGET_DOMAIN" 2>&1)
                        fi
                        purchase_result=$?
                        if handle_fqdnmgr_error "$purchase_result" "$PURCHASE_OUTPUT" "domain purchase"; then
                            :
                        else
                            case $purchase_result in
                                0)
                                    vecho "Successfully purchased $TARGET_DOMAIN"
                                    ;;
                                1)
                                    echo "Error: Insufficient balance to purchase $TARGET_DOMAIN" >&2
                                    exit 1
                                    ;;
                                2)
                                    echo "Error: Failed to purchase $TARGET_DOMAIN (see /var/log/fqdnmgr/fqdnmgr.log for details)" >&2
                                    exit 1
                                    ;;
                                *)
                                    echo "Error: Unknown error purchasing $TARGET_DOMAIN (exit code: $purchase_result)" >&2
                                    exit 1
                                    ;;
                            esac
                        fi
                        ;;
                    *)
                        vecho "User declined to purchase $TARGET_DOMAIN. Exiting gracefully."
                        exit 0
                        ;;
                esac
                ;;
            owned)
                # Nothing special here yet; certificate existence will be checked later
                ;;
            taken)
                echo "Error: Domain $TARGET_DOMAIN is already taken by another owner." >&2
                exit 1
                ;;
            unavailable)
                echo "Error: Domain ownership for $TARGET_DOMAIN could not be determined (status=unavailable)." >&2
                echo "If you are sure you own it, please add it manually to the domains database and retry." >&2
                exit 1
                ;;
            *)
                # Unknown or not provided status: continue but warn the user
                echo "Warning: Unknown domain status for $TARGET_DOMAIN (status='$DOMAIN_STATUS'). Proceeding, but ensure you own the domain." >&2
                ;;
        esac
    fi
}

# STEP 2: Configure Apache site
do_config

# STEP 3: Set up SSL certificates (only if none exist yet)
{
    # only domain and proxypass modes reach this step, swc left the journey earlier
    CERT_PATH_BASE="/etc/letsencrypt/live/$CERT_DOMAIN"
    if [ -d "$CERT_PATH_BASE" ] && [ -f "$CERT_PATH_BASE/fullchain.pem" ] && [ -f "$CERT_PATH_BASE/privkey.pem" ]; then
        vecho "Existing certificates found for $CERT_DOMAIN at $CERT_PATH_BASE. Reusing them."
    else
        # Handle DNS record initialization
        if [ "$SET_INIT_DNS" = true ]; then
            # User requested setInitDNSRecords - call fqdnmgr to set them (it will check first internally)
            INIT_DNS_ARGS=(setInitDNSRecords -d "$CERT_DOMAIN")
            [ -n "$REGISTRAR" ] && INIT_DNS_ARGS+=(-r "$REGISTRAR")
            [ "$SET_INIT_DNS_OVERRIDE" = true ] && INIT_DNS_ARGS+=(-o)
            [ "$SET_INIT_DNS_SYNC" = true ] && INIT_DNS_ARGS+=(--sync)
            [ "$VERBOSE" = true ] && INIT_DNS_ARGS+=(-v)
            
            if [ -n "$REGISTRAR" ]; then
                vecho "Setting initial DNS records for $CERT_DOMAIN via $REGISTRAR..."
            else
                vecho "Setting initial DNS records for $CERT_DOMAIN (registrar will be auto-detected)..."
            fi
            
            if [ "$VERBOSE" = true ]; then
                fqdnmgr "${INIT_DNS_ARGS[@]}"
            else
                fqdnmgr "${INIT_DNS_ARGS[@]}" >/dev/null 2>&1
            fi
            INIT_DNS_EXIT=$?
            
            if [ $INIT_DNS_EXIT -ne 0 ]; then
                echo "Error: Failed to set initial DNS records for $CERT_DOMAIN" >&2
                exit 1
            fi
            vecho "Initial DNS records set for $CERT_DOMAIN."
        fi

        vecho "No existing certificates found for $CERT_DOMAIN. Requesting wildcard certificate..."
        if [ -z "$REGISTRAR" ]; then
            echo "Error: Registrar is required to request certificates. Please specify with -r or --registrar." >&2
            exit 1
        fi

        # Now request certificates
        CERTBOT_AUTH_HOOK="fqdnmgr certify $REGISTRAR"
        CERTBOT_CLEANUP_HOOK="fqdnmgr cleanup $REGISTRAR"
        if [ "$VERBOSE" = true ]; then
            CERTBOT_AUTH_HOOK="fqdnmgr certify $REGISTRAR -v"
            CERTBOT_CLEANUP_HOOK="fqdnmgr cleanup $REGISTRAR -v"
            # In verbose mode, let output flow through in real-time
            certbot -d "*.$CERT_DOMAIN" -d "$CERT_DOMAIN" \
                --manual \
                --preferred-challenges dns \
                --manual-auth-hook "$CERTBOT_AUTH_HOOK" \
                --manual-cleanup-hook "$CERTBOT_CLEANUP_HOOK" \
                --issuance-timeout 3600 \
                certonly
            CERTBOT_EXIT=$?
            CERTBOT_OUTPUT=""  # No captured output in verbose mode
        else
            # In non-verbose mode, capture output for error reporting
            CERTBOT_OUTPUT=$(certbot -d "*.$CERT_DOMAIN" -d "$CERT_DOMAIN" \
                --manual \
                --preferred-challenges dns \
                --manual-auth-hook "$CERTBOT_AUTH_HOOK" \
                --manual-cleanup-hook "$CERTBOT_CLEANUP_HOOK" \
                --issuance-timeout 600 \
                certonly 2>&1)
            CERTBOT_EXIT=$?
        fi
        if [ $CERTBOT_EXIT -ne 0 ]; then
            # In verbose mode, errors were already displayed; provide generic message
            if [ "$VERBOSE" = true ]; then
                echo "Error: certbot failed to obtain certificates for $CERT_DOMAIN (exit code: $CERTBOT_EXIT)" >&2
            else
                # Check if certbot failure was due to credential errors from fqdnmgr hooks
                if echo "$CERTBOT_OUTPUT" | grep -q "CREDS_ERROR:"; then
                    CREDS_ERR_LINE=$(echo "$CERTBOT_OUTPUT" | grep "CREDS_ERROR:" | head -1)
                    case "$CREDS_ERR_LINE" in
                        *no_credentials*)
                            provider=$(echo "$CREDS_ERR_LINE" | cut -d: -f3)
                            echo "Error: No credentials found for provider '$provider'." >&2
                            echo "Please add credentials: sudo fqdncredmgr add $provider <username> -p <api_key>" >&2
                            ;;
                        *socket_not_found*)
                            echo "Error: Credentials daemon not running (socket not found)." >&2
                            echo "Please ensure fqdncredmgrd service is running: sudo systemctl start fqdncredmgrd" >&2
                            ;;
                        *database_not_found*)
                            echo "Error: Credentials database not found." >&2
                            echo "Please run the installer to initialize the database." >&2
                            ;;
                        *)
                            echo "Error: Credential error during certificate request: $CREDS_ERR_LINE" >&2
                            ;;
                    esac
                else
                    echo "Error: certbot failed to obtain certificates for $CERT_DOMAIN" >&2
                    echo "$CERTBOT_OUTPUT" >&2
                fi
            fi
            exit 1
        fi
        
        # Certificate successfully issued - update cert_date in database
        CERT_ISSUE_DATE=$(date '+%Y-%m-%d')
        if [ -f "/etc/fqdntools/domains.db" ]; then
            sqlite3 /etc/fqdntools/domains.db \
                "INSERT OR REPLACE INTO domains (domain, status, registrar, cert_date) 
                 VALUES ('$CERT_DOMAIN', 'owned', '$REGISTRAR', '$CERT_ISSUE_DATE')
                 ON CONFLICT(domain) DO UPDATE SET cert_date = '$CERT_ISSUE_DATE';" 2>/dev/null || true
            vecho "Updated cert_date to $CERT_ISSUE_DATE for $CERT_DOMAIN"
        fi
    fi
}

# STEP 4: Finalize Apache configuration
{
    # Get config filename based on mode (CONF is set in do_config)
    CONF_BASENAME=$(basename "$CONF")
    
    if [ "$MODE" = "domain" ] && [ "$IS_DOMAIN_SUBDOMAIN" != true ]; then
        # Remove DocumentRoot line from apache config (keep ServerAlias for wildcard support)
        sed -i '/DocumentRoot/d' "$CONF"
        
        # Add HTTPS redirect after ServerAlias to keep ServerName at top
        sed -i '/ServerAlias/a\
    RewriteEngine On\
    RewriteCond %{HTTPS} !=on\
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]' "$CONF"
    elif [ "$MODE" = "proxypass" ]; then
        # For proxypass mode: Add HTTPS redirect after ServerName
        sed -i '/<VirtualHost \*:80>/,/<\/VirtualHost>/{/ServerName/a\
    RewriteEngine On\
    RewriteCond %{HTTPS} !=on\
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
}' "$CONF"
    fi
    
    # Add SSL VirtualHost directives
    if [ "$MODE" = "domain" ]; then
        if [ "$IS_DOMAIN_SUBDOMAIN" = true ]; then
            # Prepend subdomain SSL vhost inside existing mod_ssl section.
            if ! grep -q "ServerName $FQDN" "$CONF"; then
                SUBDOMAIN_SSL_BLOCK=$(cat <<EOF
    <VirtualHost *:443>
        ServerName $FQDN
        DocumentRoot /var/www/$CERT_DOMAIN/$SUBDOMAIN/public_html
        ErrorLog /var/log/apache-collector/${FQDN}_ssl_error.log
        CustomLog /var/log/apache-collector/${FQDN}_ssl_access.log combined
        SSLEngine on
        SSLCertificateFile /etc/letsencrypt/live/$CERT_DOMAIN/fullchain.pem
        SSLCertificateKeyFile /etc/letsencrypt/live/$CERT_DOMAIN/privkey.pem
    </VirtualHost>
EOF
)

                if grep -q '^<IfModule mod_ssl\.c>' "$CONF"; then
                    awk -v block="$SUBDOMAIN_SSL_BLOCK" '
                        /^<IfModule mod_ssl\.c>/ && !done {
                            print
                            print block
                            done=1
                            next
                        }
                        { print }
                    ' "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
                else
                    printf '\n<IfModule mod_ssl.c>\n%s\n</IfModule>\n' "$SUBDOMAIN_SSL_BLOCK" >> "$CONF"
                fi
            fi
        else
            # Use certificates for the specific apex domain
            sed \
                -e "s|{{FQDN}}|$FQDN|g" \
                -e "s|{{FQDN_BASE}}|$FQDN_BASE|g" \
                "$SCRIPT_DIR/ssl_standard.conf.tpl" >> "$CONF"
        fi
    elif [ "$MODE" = "proxypass" ]; then
        # Use wildcard certificates from base domain - no DocumentRoot for proxypass
        sed \
            -e "s|{{ACTUAL_SERVER_NAME}}|$ACTUAL_SERVER_NAME|g" \
            -e "s|{{SUBDOMAIN}}|$SUBDOMAIN|g" \
            -e "s|{{FQDN_BASE}}|$FQDN_BASE|g" \
            -e "s|{{CERT_DOMAIN}}|$CERT_DOMAIN|g" \
            -e "s|{{PROXY_PROTOCOL}}|$PROXY_PROTOCOL|g" \
            -e "s|{{PROXY_PORT}}|$PROXY_PORT|g" \
            "$SCRIPT_DIR/ssl_proxypass.conf.tpl" >> "$CONF"
    fi

    # Test Apache configuration before enabling (filter out harmless AH00558 warning)
    CONFIGTEST_OUTPUT=$(sudo apache2ctl configtest 2>&1 | grep -v "AH00558")
    CONFIGTEST_EXIT=${PIPESTATUS[0]}
    if [ $CONFIGTEST_EXIT -ne 0 ]; then
        echo "Error: Apache configuration test failed:" >&2
        echo "$CONFIGTEST_OUTPUT" >&2
        exit 1
    fi

    # Enable site and reload Apache with error handling
    if a2ensite "$CONF_BASENAME" >/dev/null 2>&1; then
        vecho "Successfully enabled site: $CONF_BASENAME"
    else
        echo "Error: Failed to enable site $CONF_BASENAME" >&2
        exit 1
    fi

    if systemctl reload apache2; then
        vecho "Successfully reloaded Apache"
        # Create symlinks from per-domain log dirs to centralized log files
        # (Apache creates the log files on reload, so symlinks must come after)
        if [ "$MODE" = "domain" ]; then
            if [ "$IS_DOMAIN_SUBDOMAIN" = true ]; then
                # Subdomains only have SSL vhosts - no non-SSL log files exist
                ln -sf "/var/log/apache-collector/${FQDN}_ssl_error.log" "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log/ssl_error.log"
                ln -sf "/var/log/apache-collector/${FQDN}_ssl_access.log" "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log/ssl_access.log"
            else
                ln -sf "/var/log/apache-collector/${FQDN}_error.log" "/var/www/$FQDN/log/error.log"
                ln -sf "/var/log/apache-collector/${FQDN}_access.log" "/var/www/$FQDN/log/access.log"
                ln -sf "/var/log/apache-collector/${FQDN}_ssl_error.log" "/var/www/$FQDN/log/ssl_error.log"
                ln -sf "/var/log/apache-collector/${FQDN}_ssl_access.log" "/var/www/$FQDN/log/ssl_access.log"
            fi
        elif [ "$MODE" = "proxypass" ]; then
            ln -sf "/var/log/apache-collector/${FQDN}_error.log" "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log/error.log"
            ln -sf "/var/log/apache-collector/${FQDN}_access.log" "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log/access.log"
            ln -sf "/var/log/apache-collector/${FQDN}_ssl_error.log" "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log/ssl_error.log"
            ln -sf "/var/log/apache-collector/${FQDN}_ssl_access.log" "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log/ssl_access.log"
        fi
    else
        echo "Error: Failed to reload Apache. Check configuration with: apache2ctl configtest" >&2
        exit 1
    fi
}

vecho "Apache configuration complete for $FQDN"
