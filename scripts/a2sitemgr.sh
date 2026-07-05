#!/bin/bash
# a2sitemgr - opinionated Apache virtual-host manager.
#
# Modes:
#   domain     standard vhost (+ wildcard cert via certbot / fqdnmgr hooks)
#   proxypass  reverse-proxied subdomain (backed by the base domain's cert)
#   swc        subdomain wildcard (one subdomain served for all base domains)

A2TOOLS_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
. "$A2TOOLS_SELF_DIR/lib/common.sh"

TEMPLATES_DIR="$A2TOOLS_SHARE/templates"

# ask PROMPT DEFAULT
# Read one line with the bash builtin and echo the answer on stdout.
# Empty input (or EOF when stdin is not interactive) returns the default.
ask() {
    local prompt="$1" default="$2" ans=""
    read -r -p "$prompt " ans || true
    printf '%s\n' "${ans:-$default}"
}

# Initialize variables
MODE="domain"
IS_DOMAIN_SUBDOMAIN=false
BASE_DOMAIN_CONF=""
PROXY_PORT=""
SECURED=false
FQDN=""
SUBDOMAIN=""
FQDN_BASE=""
CERT_DOMAIN=""
REGISTRAR=""
NON_INTERACTIVE=false
STRICT_MODE=false
SET_INIT_DNS=false
SET_INIT_DNS_OVERRIDE=false
SET_INIT_DNS_SYNC=false

# Get next available config number for a given prefix (0 for swc, 1 for proxypass)
# Returns the full filename: prefix-NNNN-name.conf
get_next_config_number() {
    local prefix="$1"
    local name="$2"
    local config_dir="/etc/apache2/sites-available"

    # Reuse an existing config with this name (any number)
    local existing
    existing=$(ls -1 "$config_dir"/${prefix}-????-${name}.conf 2>/dev/null | head -n1)
    if [ -n "$existing" ]; then
        basename "$existing"
        return 0
    fi

    # Collect all existing numbers for this prefix
    declare -A used_numbers
    local file num
    for file in "$config_dir"/${prefix}-????-*.conf; do
        [ -f "$file" ] || continue
        num=$(basename "$file" | sed -E 's/^[0-9]-([0-9]{4})-.*\.conf$/\1/')
        [[ "$num" =~ ^[0-9]{4}$ ]] && used_numbers["$num"]=1
    done

    # First available number (filling gaps)
    local next_num=0 padded
    while [ $next_num -le 9999 ]; do
        padded=$(printf '%04d' $next_num)
        if [ -z "${used_numbers[$padded]+x}" ]; then
            echo "${prefix}-${padded}-${name}.conf"
            return 0
        fi
        ((next_num++))
    done

    echo "Error: No available config numbers for prefix $prefix" >&2
    return 1
}

# Map fqdnmgr/creds exit codes to actionable messages.
# Codes (from lib/common.sh creds_get): 11=no creds, 12=DB missing, 15=incomplete
handle_fqdnmgr_error() {
    local exit_code="$1"
    local output="$2"
    local context="$3"

    case "$exit_code" in
        11)
            local provider
            provider=$(echo "$output" | grep -oE 'CREDS_ERROR:no_credentials:(.+)' | cut -d: -f3)
            echo "Error: No credentials found for provider '$provider'." >&2
            echo "Please add credentials: sudo fqdncredmgr add $provider <username>" >&2
            exit 1
            ;;
        12)
            echo "Error: Credentials database not found." >&2
            echo "Reinstall a2tools to initialize the database." >&2
            exit 1
            ;;
        15)
            local err_detail
            err_detail=$(echo "$output" | grep -oE 'CREDS_ERROR:(.+)' | cut -d: -f2-)
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
    cat "$A2TOOLS_SHARE/usage/a2sitemgr.txt"
    exit "$exit_code"
}

check_prerequisites() {
    if ! command -v apache2 >/dev/null 2>&1; then
        echo "Error: Apache is not installed" >&2
        exit 1
    fi

    local required_modules="rewrite ssl"
    if [ "$MODE" = "proxypass" ]; then
        required_modules="$required_modules proxy proxy_http"
    fi

    local loaded_modules
    loaded_modules=$(apache2ctl -M 2>/dev/null)
    local modules_check_failed=$?

    if [ $modules_check_failed -ne 0 ] || [ -z "$loaded_modules" ]; then
        echo "Warning: Could not verify Apache modules (apache2ctl -M failed - likely a config error exists)" >&2
        echo "Run 'apache2ctl configtest' to diagnose configuration issues" >&2
    else
        local module
        for module in $required_modules; do
            if ! echo "$loaded_modules" | grep -q "${module}_module"; then
                echo "Warning: Apache module 'mod_$module' does not appear to be enabled" >&2
                echo "You may need to run: a2enmod $module" >&2
            fi
        done
    fi
}

render_from_template_to_path() {
    local tpl="$1" target="$2"

    # If the target exists, ask before overwriting.
    if [ -f "$target" ]; then
        local overwrite
        vecho "Warning: $target already exists."
        if [ "$NON_INTERACTIVE" = true ]; then
            vecho "Non-interactive mode: auto-accepting default (overwrite)."
            overwrite="Y"
        else
            overwrite=$(ask "Overwrite $target? [Y/n]:" "Y")
        fi
        case "$overwrite" in
            [Nn]*)
                vecho "Keeping existing $target. Exiting."
                exit 0
                ;;
            *)
                vecho "Overwriting $target"
                ;;
        esac
    fi

    # General substitutions (available in all modes)
    sed -e "s|{{FQDN}}|${FQDN:-}|g" "$tpl" > "$target"

    # Mode-specific substitutions
    case "$MODE" in
        domain)
            sed -i \
                -e "s|{{CERT_DOMAIN}}|$CERT_DOMAIN|g" \
                -e "s|{{FQDN_BASE}}|${FQDN_BASE:-}|g" \
                "$target"
            ;;
        swc)
            sed -i -e "s|{{SUBDOMAIN}}|$SUBDOMAIN|g" "$target"
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

do_config() {
    # 1) Standard mode
    if [ "$MODE" = "domain" ]; then
        if [ "$IS_DOMAIN_SUBDOMAIN" = true ]; then
            # Subdomains live under the base-domain tree; base conf is updated.
            if [ ! -d "/var/www/$CERT_DOMAIN/$SUBDOMAIN/public_html" ]; then
                mkdir -p "/var/www/$CERT_DOMAIN/$SUBDOMAIN/public_html"
                mkdir -p "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log"
                chown -R www-data:www-data "/var/www/$CERT_DOMAIN"
            fi

            # If the base config is missing, create it via recursive call.
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
            render_from_template_to_path "$TEMPLATES_DIR/init_standard.conf.tpl" "$CONF"
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
        if [[ ! "$FQDN" =~ ^[a-zA-Z0-9-]+\.\*$ ]]; then
            echo "Error: In subdomain wildcard mode (swc), FQDN must be in format 'subdomain.*' (e.g., 'api.*')" >&2
            exit 1
        fi

        SUBDOMAIN="${FQDN%.*}"

        if [ "$SECURED" = true ] || [ -n "$PROXY_PORT" ] || [ -n "$REGISTRAR" ]; then
            echo "Error: Options -s/-p/-r are not valid with subdomain wildcard mode (use -m swc)" >&2
            exit 1
        fi

        CONF_FILENAME=$(get_next_config_number "0" "$SUBDOMAIN")
        CONF="/etc/apache2/sites-available/${CONF_FILENAME}"
        render_from_template_to_path "$TEMPLATES_DIR/swc_min.conf.tpl" "$CONF"

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
        if [ ! -d "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log" ]; then
            mkdir -p "/var/www/$CERT_DOMAIN/$SUBDOMAIN/log"
            chown -R www-data:www-data "/var/www/$CERT_DOMAIN"
        fi

        # Full FQDN in the name avoids collisions between base domains.
        CONF_FILENAME=$(get_next_config_number "1" "$FQDN")
        CONF="/etc/apache2/sites-available/${CONF_FILENAME}"
        render_from_template_to_path "$TEMPLATES_DIR/init_proxypass.conf.tpl" "$CONF"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -d=*|--fqdn=*) FQDN="${1#*=}"; shift ;;
        -d|--fqdn)     FQDN="$2"; shift 2 ;;
        -m=*|--mode=*) MODE="${1#*=}"; shift ;;
        -m|--mode)     MODE="$2"; shift 2 ;;
        -r=*|--registrar=*) REGISTRAR="${1#*=}"; shift ;;
        -r|--registrar)     REGISTRAR="$2"; shift 2 ;;
        -s|--secured)  SECURED=true; shift ;;
        -p=*|--port=*) PROXY_PORT="${1#*=}"; shift ;;
        -p|--port)     PROXY_PORT="$2"; shift 2 ;;
        -ni|--non-interactive) NON_INTERACTIVE=true; shift ;;
        -c|--strict)   STRICT_MODE=true; shift ;;
        -v|--verbose)  VERBOSE=true; shift ;;
        --setInitDNSRecords) SET_INIT_DNS=true; shift ;;
        -o|--override) SET_INIT_DNS_OVERRIDE=true; shift ;;
        --sync)        SET_INIT_DNS_SYNC=true; shift ;;
        -h|--help)     usage 0 ;;
        -*)
            echo "Unknown option $1" >&2
            usage 1
            ;;
        *)
            if [ -z "$FQDN" ]; then
                FQDN="$1"
            else
                echo "Too many arguments" >&2
                usage 1
            fi
            shift
            ;;
    esac
done

case "$MODE" in
    domain)                 MODE="domain" ;;
    pp|proxypass)           MODE="proxypass" ;;
    swc|subdomainWildCard)  MODE="swc" ;;
    *)
        echo "Error: Unknown mode: $MODE" >&2
        usage 1
        ;;
esac

# This tool writes to /etc/apache2, /var/www and /var/log - require root.
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: a2sitemgr must be run as root" >&2
    exit 1
fi

# Validate proxy port early
if [ -n "$PROXY_PORT" ] && { ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || [ "$PROXY_PORT" -lt 1 ] || [ "$PROXY_PORT" -gt 65535 ]; }; then
    echo "Error: Invalid port '$PROXY_PORT' (must be 1-65535)" >&2
    exit 1
fi

# Resolve registrar names strictly via `fqdncredmgr list` (no fallbacks)
if [ -n "$REGISTRAR" ]; then
    if ! command -v fqdncredmgr >/dev/null 2>&1; then
        echo "Error: Registrar resolution requires 'fqdncredmgr' but it was not found in PATH." >&2
        exit 1
    fi

    CRED_LIST=$(fqdncredmgr list 2>/dev/null || true)
    if [ -z "$CRED_LIST" ]; then
        echo "Error: 'fqdncredmgr list' returned no credentials; cannot resolve registrar '$REGISTRAR'." >&2
        exit 1
    fi

    if [[ "$REGISTRAR" == *.* ]]; then
        # Full hostname: require an exact match
        if ! echo "$CRED_LIST" | grep -qw -- "$REGISTRAR"; then
            echo "Error: Registrar '$REGISTRAR' not found in fqdncredmgr credentials." >&2
            exit 1
        fi
    else
        # Short name: find a credential entry containing it
        MATCH=$(echo "$CRED_LIST" | grep -Eo "[A-Za-z0-9._-]*${REGISTRAR}[A-Za-z0-9._-]*" | head -n1 || true)
        if [ -n "$MATCH" ]; then
            REGISTRAR="$MATCH"
        else
            echo "Error: Registrar short-name '$REGISTRAR' could not be resolved from fqdncredmgr list." >&2
            exit 1
        fi
    fi

    if [[ ! "$REGISTRAR" =~ \.[A-Za-z0-9] ]]; then
        echo "Error: Resolved registrar '$REGISTRAR' does not appear to be a hostname." >&2
        exit 1
    fi
fi

check_prerequisites

# Ensure the centralized log directory exists
mkdir -p /var/log/apache-collector
chown root:adm /var/log/apache-collector
chmod 750 /var/log/apache-collector

if [ -z "$FQDN" ]; then
    echo "Error: FQDN is required" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Early validation and variable setup
# ---------------------------------------------------------------------------
if [ "$MODE" = "domain" ]; then
    if [[ ! "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        echo "Error: Invalid FQDN format: $FQDN" >&2
        exit 1
    fi

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

    # Domain mode with a subdomain uses the base-domain cert/config.
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
    if [[ "$FQDN" =~ ^([^.]+)\.(.+)$ ]]; then
        SUBDOMAIN="${BASH_REMATCH[1]}"
        FQDN_BASE="$SUBDOMAIN"
        CERT_DOMAIN="${BASH_REMATCH[2]}"
    else
        echo "Error: In proxypass mode, FQDN must be a subdomain (e.g., something.example.com)" >&2
        exit 1
    fi

    if [ -z "$PROXY_PORT" ]; then
        echo "Error: Proxy port (-p/--port) is required when using proxypass mode (use -m pp)" >&2
        exit 1
    fi

    if [ "$SECURED" = true ]; then
        PROXY_PROTOCOL="https"
    else
        PROXY_PROTOCOL="http"
    fi
    ACTUAL_SERVER_NAME="$FQDN"

    # Create the base domain configuration first if it's missing.
    BASE_DOMAIN_CONF="/etc/apache2/sites-available/${CERT_DOMAIN}.conf"
    if [ ! -f "$BASE_DOMAIN_CONF" ]; then
        vecho "Base domain configuration not found at $BASE_DOMAIN_CONF"
        vecho "Creating base domain configuration for $CERT_DOMAIN first..."
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

# ---------------------------------------------------------------------------
# STEP 1: Determine domain status and handle purchase / availability
# ---------------------------------------------------------------------------
if [ "$MODE" = "domain" ] || [ "$MODE" = "proxypass" ]; then
    TARGET_DOMAIN="$FQDN"
    if [ "$MODE" = "proxypass" ]; then
        TARGET_DOMAIN="$CERT_DOMAIN"
    elif [ "$IS_DOMAIN_SUBDOMAIN" = true ]; then
        TARGET_DOMAIN="$CERT_DOMAIN"
    fi

    DOMAIN_STATUS="unknown"

    if ! command -v fqdnmgr >/dev/null 2>&1; then
        echo "Warning: fqdnmgr not found; domain ownership cannot be checked automatically." >&2
        echo "Please ensure domain $TARGET_DOMAIN is registered and DNS is configured before proceeding." >&2
    else
        FQDNMGR_ARGS=(check "$TARGET_DOMAIN")
        [ -n "$REGISTRAR" ] && FQDNMGR_ARGS+=("$REGISTRAR")
        [ "$STRICT_MODE" = true ] && FQDNMGR_ARGS+=("--strict")
        [ "$VERBOSE" = true ] && FQDNMGR_ARGS+=("-v")

        # Show fqdnmgr prompts to the user when possible; otherwise run quietly.
        if [ -c /dev/tty ]; then
            FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" < /dev/tty 2>&1)
        elif [ -t 0 ]; then
            FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" 2>&1)
        else
            FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" < /dev/null 2>&1)
        fi
        FQDNMGR_EXIT=$?

        if [ $FQDNMGR_EXIT -ne 0 ]; then
            if ! handle_fqdnmgr_error "$FQDNMGR_EXIT" "$FQDNMGR_OUTPUT" "domain status check"; then
                echo "Warning: fqdnmgr status check failed: $FQDNMGR_OUTPUT" >&2
            fi
        else
            vecho "$FQDNMGR_OUTPUT"
            STATUS_VAL=$(echo "$FQDNMGR_OUTPUT" | grep -oE 'status=[^ ]+' | cut -d= -f2)
            REGISTRAR_VAL=$(echo "$FQDNMGR_OUTPUT" | grep -oE 'registrar=[^ ]+' | cut -d= -f2)

            [ -n "$REGISTRAR_VAL" ] && REGISTRAR="$REGISTRAR_VAL"
            [ -n "$STATUS_VAL" ] && DOMAIN_STATUS="$STATUS_VAL"
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
            purchase_ans=$(ask "Domain $TARGET_DOMAIN appears to be free. Purchase it now? [y/N]:" "N")
            case "$purchase_ans" in
                [Yy]*)
                    vecho "Attempting to purchase $TARGET_DOMAIN via $REGISTRAR..."
                    if [ "$VERBOSE" = true ]; then
                        PURCHASE_OUTPUT=$(fqdnmgr purchase "$TARGET_DOMAIN" "$REGISTRAR" -v 2>&1)
                    else
                        PURCHASE_OUTPUT=$(fqdnmgr purchase "$TARGET_DOMAIN" "$REGISTRAR" 2>&1)
                    fi
                    purchase_result=$?
                    if handle_fqdnmgr_error "$purchase_result" "$PURCHASE_OUTPUT" "domain purchase"; then
                        :
                    else
                        case $purchase_result in
                            0) vecho "Successfully purchased $TARGET_DOMAIN" ;;
                            1)
                                echo "Error: Insufficient balance to purchase $TARGET_DOMAIN" >&2
                                exit 1
                                ;;
                            2)
                                echo "Error: Failed to purchase $TARGET_DOMAIN (see $LOG_FILE for details)" >&2
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
            # Certificate existence will be checked later
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
            echo "Warning: Unknown domain status for $TARGET_DOMAIN (status='$DOMAIN_STATUS'). Proceeding, but ensure you own the domain." >&2
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# STEP 2: Configure Apache site
# ---------------------------------------------------------------------------
do_config

# ---------------------------------------------------------------------------
# STEP 3: Set up SSL certificates (only if none exist yet)
# ---------------------------------------------------------------------------
# Only domain and proxypass modes reach this step (swc exits in do_config).
CERT_PATH_BASE="/etc/letsencrypt/live/$CERT_DOMAIN"
if [ -d "$CERT_PATH_BASE" ] && [ -f "$CERT_PATH_BASE/fullchain.pem" ] && [ -f "$CERT_PATH_BASE/privkey.pem" ]; then
    vecho "Existing certificates found for $CERT_DOMAIN at $CERT_PATH_BASE. Reusing them."
else
    # Handle DNS record initialization
    if [ "$SET_INIT_DNS" = true ]; then
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

    CERTBOT_AUTH_HOOK="fqdnmgr certify $REGISTRAR"
    CERTBOT_CLEANUP_HOOK="fqdnmgr cleanup $REGISTRAR"
    if [ "$VERBOSE" = true ]; then
        CERTBOT_AUTH_HOOK="fqdnmgr certify $REGISTRAR -v"
        CERTBOT_CLEANUP_HOOK="fqdnmgr cleanup $REGISTRAR -v"
        # Verbose: let output flow through in real time
        certbot -d "*.$CERT_DOMAIN" -d "$CERT_DOMAIN" \
            --manual \
            --preferred-challenges dns \
            --manual-auth-hook "$CERTBOT_AUTH_HOOK" \
            --manual-cleanup-hook "$CERTBOT_CLEANUP_HOOK" \
            --issuance-timeout 3600 \
            certonly
        CERTBOT_EXIT=$?
        CERTBOT_OUTPUT=""
    else
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
        if [ "$VERBOSE" = true ]; then
            echo "Error: certbot failed to obtain certificates for $CERT_DOMAIN (exit code: $CERTBOT_EXIT)" >&2
        else
            if echo "$CERTBOT_OUTPUT" | grep -q "CREDS_ERROR:"; then
                CREDS_ERR_LINE=$(echo "$CERTBOT_OUTPUT" | grep "CREDS_ERROR:" | head -1)
                case "$CREDS_ERR_LINE" in
                    *no_credentials*)
                        provider=$(echo "$CREDS_ERR_LINE" | cut -d: -f3)
                        echo "Error: No credentials found for provider '$provider'." >&2
                        echo "Please add credentials: sudo fqdncredmgr add $provider <username>" >&2
                        ;;
                    *database_not_found*)
                        echo "Error: Credentials database not found." >&2
                        echo "Reinstall a2tools to initialize the database." >&2
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

    # Certificate issued - record cert_date in the domains DB
    CERT_ISSUE_DATE=$(date '+%Y-%m-%d')
    if [ -f "$DOMAINS_DB_PATH" ]; then
        sqlite3 "$DOMAINS_DB_PATH" \
            "INSERT INTO domains (domain, status, registrar, cert_date)
             VALUES ('$(sql_escape "$CERT_DOMAIN")', 'owned', '$(sql_escape "$REGISTRAR")', '$CERT_ISSUE_DATE')
             ON CONFLICT(domain) DO UPDATE SET cert_date='$CERT_ISSUE_DATE';" 2>/dev/null || true
        vecho "Updated cert_date to $CERT_ISSUE_DATE for $CERT_DOMAIN"
    fi
fi

# ---------------------------------------------------------------------------
# STEP 4: Finalize Apache configuration
# ---------------------------------------------------------------------------
CONF_BASENAME=$(basename "$CONF")

if [ "$MODE" = "domain" ] && [ "$IS_DOMAIN_SUBDOMAIN" != true ]; then
    # Remove DocumentRoot from the :80 vhost (keep ServerAlias for wildcard)
    sed -i '/DocumentRoot/d' "$CONF"

    # Add HTTPS redirect after ServerAlias to keep ServerName at top
    sed -i '/ServerAlias/a\
    RewriteEngine On\
    RewriteCond %{HTTPS} !=on\
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]' "$CONF"
elif [ "$MODE" = "proxypass" ]; then
    # Add HTTPS redirect after ServerName inside the :80 vhost
    sed -i '/<VirtualHost \*:80>/,/<\/VirtualHost>/{/ServerName/a\
    RewriteEngine On\
    RewriteCond %{HTTPS} !=on\
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
}' "$CONF"
fi

# Add SSL VirtualHost directives
if [ "$MODE" = "domain" ]; then
    if [ "$IS_DOMAIN_SUBDOMAIN" = true ]; then
        # Prepend the subdomain SSL vhost inside the existing mod_ssl section.
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
        sed \
            -e "s|{{FQDN}}|$FQDN|g" \
            -e "s|{{FQDN_BASE}}|$FQDN_BASE|g" \
            "$TEMPLATES_DIR/ssl_standard.conf.tpl" >> "$CONF"
    fi
elif [ "$MODE" = "proxypass" ]; then
    sed \
        -e "s|{{ACTUAL_SERVER_NAME}}|$ACTUAL_SERVER_NAME|g" \
        -e "s|{{SUBDOMAIN}}|$SUBDOMAIN|g" \
        -e "s|{{FQDN_BASE}}|$FQDN_BASE|g" \
        -e "s|{{CERT_DOMAIN}}|$CERT_DOMAIN|g" \
        -e "s|{{PROXY_PROTOCOL}}|$PROXY_PROTOCOL|g" \
        -e "s|{{PROXY_PORT}}|$PROXY_PORT|g" \
        "$TEMPLATES_DIR/ssl_proxypass.conf.tpl" >> "$CONF"
fi

# Test Apache configuration before enabling (filter harmless AH00558 warning)
CONFIGTEST_OUTPUT=$(apache2ctl configtest 2>&1 | grep -v "AH00558")
CONFIGTEST_EXIT=${PIPESTATUS[0]}
if [ $CONFIGTEST_EXIT -ne 0 ]; then
    echo "Error: Apache configuration test failed:" >&2
    echo "$CONFIGTEST_OUTPUT" >&2
    exit 1
fi

if a2ensite "$CONF_BASENAME" >/dev/null 2>&1; then
    vecho "Successfully enabled site: $CONF_BASENAME"
else
    echo "Error: Failed to enable site $CONF_BASENAME" >&2
    exit 1
fi

if systemctl reload apache2; then
    vecho "Successfully reloaded Apache"
    # Symlink per-domain log dirs to centralized log files
    # (Apache creates the log files on reload, so symlinks come after)
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

vecho "Apache configuration complete for $FQDN"
