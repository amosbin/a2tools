#!/bin/bash

# Manage FQDN provider credentials (add/update/delete/list)

VALID_PROVIDERS=()
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fqdncredmgr.d"
BASE_DIR="$(dirname "$DIR")"
USAGE_FILE="$DIR/usage.txt"
SCHEMA_FILE="$DIR/schema.sql"
DB_PATH="/etc/fqdntools/creds.db"
GETINPUT_SCRIPT="$BASE_DIR/getinput.d/getinput.sh"
VERBOSE=false

# Verbose echo - only prints when VERBOSE=true
vecho() { [ "$VERBOSE" = true ] && echo "$@" || true; }

PROVIDERS_DIR="/etc/fqdnmgr/providers"
if [ -d "$PROVIDERS_DIR" ]; then
    for f in "$PROVIDERS_DIR"/*.provider; do
        [ -e "$f" ] || continue
        fbase="$(basename "$f")"
        VALID_PROVIDERS+=("${fbase%.provider}")
    done
fi

# Ensure required files exist
[ -f "$USAGE_FILE" ] || { echo "Error: Missing $USAGE_FILE" >&2; exit 1; }
[ -f "$SCHEMA_FILE" ] || { echo "Error: Missing $SCHEMA_FILE" >&2; exit 1; }
[ -f "$GETINPUT_SCRIPT" ] || { echo "Error: Missing $GETINPUT_SCRIPT" >&2; exit 1; }

source "$GETINPUT_SCRIPT"
usage() { cat "$USAGE_FILE"; exit 1; }
init_db() { [ -f "$DB_PATH" ] || { echo "Error: Database $DB_PATH not found" >&2; exit 1; }; }

# needed when adding new creds
prompt_api_key() {
    local api_key
    api_key=$(getInput "Enter API key" "" 0 "dotted" "true" "true" "false")
    [ $? -eq 200 ] && { echo "Error: API key cannot be empty" >&2; exit 1; }
    printf "%s" "$api_key"
}

# for anything else than adding new creds
validate_provider() {
    local p="$1"
    for v in "${VALID_PROVIDERS[@]}"; do [ "$p" = "$v" ] && return 0; done
    return 1
}

# DB helpers and CRUD operations
add_creds() {
    local provider="${1:-}" username="${2:-}" api_key="${3:-}"
    escape_sql() { printf '%s' "$1" | sed "s/'/''/g"; }
    # Replace existing credentials for the provider (only one username per provider)
    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO creds (username, key, provider) VALUES ('$(escape_sql "$username")','$(escape_sql "$api_key")','$(escape_sql "$provider")');"
    [ $? -eq 0 ] && vecho "Credentials set for $provider with username $username" || { echo "Error: Failed to set credentials" >&2; exit 1; }
}

update_creds() {
    local provider="${1:-}" username="${2:-}" api_key="${3:-}"
    escape_sql() { printf '%s' "$1" | sed "s/'/''/g"; }
    local changes
    changes=$(sqlite3 "$DB_PATH" "UPDATE creds SET username = '$(escape_sql "$username")' , key = '$(escape_sql "$api_key")' WHERE provider = '$(escape_sql "$provider")'; SELECT changes();")
    if [ -n "$changes" ] && [ "$changes" -gt 0 ]; then
        vecho "Credentials updated for $provider with username $username"
    else
        echo "Error: Failed to update credentials" >&2
        exit 1
    fi
}

delete_creds() {
    local provider="${1:-}"
    escape_sql() { printf '%s' "$1" | sed "s/'/''/g"; }
    local changes
    changes=$(sqlite3 "$DB_PATH" "DELETE FROM creds WHERE provider = '$(escape_sql "$provider")'; SELECT changes();")
    if [ -n "$changes" ] && [ "$changes" -gt 0 ]; then
        vecho "Credentials deleted for provider $provider"
    else
        echo "Error: No matching credentials for provider '$provider'" >&2
        exit 1
    fi
}

# Mask usernames for listing
mask_username() {
    local u="$1"
    if [[ "$u" == *"@"* ]]; then
        local lp="${u%%@*}" dp="${u#*@}"
        local domain_label="${dp%%.*}" extension=""
        [[ "$dp" == *.* ]] && extension=".${dp#*.}"

        # mask local part (keep first and last when length>2, otherwise mask fully)
        local lp_len=${#lp}
        local lp_mask
        if [ $lp_len -le 2 ]; then
            lp_mask="$(printf '%*s' "$lp_len" '' | tr ' ' '*')"
        else
            lp_mask="${lp:0:1}$(printf '%*s' $((lp_len-2)) '' | tr ' ' '*')${lp: -1}"
        fi

        # show first letter of domain label then mask the rest, preserve full extension
        local dl_len=${#domain_label}
        local d_mask
        if [ $dl_len -le 2 ]; then
            d_mask="$(printf '%*s' "$dl_len" '' | tr ' ' '*')"
        else
            d_mask="${domain_label:0:1}$(printf '%*s' $((dl_len-1)) '' | tr ' ' '*')"
        fi
        printf "%s@%s%s" "$lp_mask" "$d_mask" "$extension"
    else
        local s="$u"
        local l=${#s}
        if [ $l -le 2 ]; then
            printf "%s" "$(printf '%*s' "$l" '' | tr ' ' '*')"
        else
            printf "%s%s%s" "${s:0:1}" "$(printf '%*s' $((l-2)) '' | tr ' ' '*')" "${s: -1}"
        fi
    fi
}

# Main script logic
# Check for -v flag first (can appear anywhere)
for arg in "$@"; do
    [ "$arg" = "-v" ] && VERBOSE=true
done
# Remove -v from args
set -- $(printf '%s\n' "$@" | grep -v '^-v$')

if [ $# -lt 1 ]; then
    echo "Error: Insufficient arguments" >&2
    usage
fi

ACTION="$1"
shift

case "$ACTION" in
    list)
        init_db
        sqlite3 -separator $'\t' "$DB_PATH" "SELECT provider, username FROM creds;" | \
        while IFS=$'\t' read -r provider username; do
            [ -z "$provider" ] && continue
            printf "%s\t%s\n" "$provider" "$(mask_username "$username")"
        done
        ;;
    add|update)
        [ $# -lt 1 ] && { echo "Error: PROVIDER required" >&2; usage; }
        PROVIDER="$1"; shift
        if ! validate_provider "$PROVIDER"; then
            echo "Error: Invalid provider '$PROVIDER'. Valid: ${VALID_PROVIDERS[*]}" >&2
            exit 1
        fi
        API_KEY="" USERNAME=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -p) [ $# -lt 2 ] && { echo "Error: -p requires argument" >&2; usage; }
                    API_KEY="${2:-}"; shift 2 ;;
                *)  [ -n "$USERNAME" ] && { echo "Error: Unexpected argument" >&2; usage; }
                    USERNAME="$1"; shift ;;
            esac
        done
        [ -z "$USERNAME" ] && { echo "Error: USERNAME required" >&2; usage; }
        init_db
        if [ "$ACTION" = "update" ]; then
            escape_sql_local() { printf '%s' "$1" | sed "s/'/''/g"; }
            exists=$(sqlite3 "$DB_PATH" "SELECT COUNT(1) FROM creds WHERE provider = '$(escape_sql_local "$PROVIDER")';")
            if [ -z "$exists" ] || [ "$exists" -eq 0 ]; then
                echo "Error: No matching credentials for provider $PROVIDER. Run 'sudo fqdncredmgr list' to see available entries." >&2
                exit 1
            fi
        fi
        [ -z "$API_KEY" ] && API_KEY=$(prompt_api_key)
        if [ "$ACTION" = "add" ]; then
            add_creds "$PROVIDER" "$USERNAME" "$API_KEY"
        else
            update_creds "$PROVIDER" "$USERNAME" "$API_KEY"
        fi
        ;;
    delete)
        [ $# -lt 1 ] && { echo "Error: PROVIDER required" >&2; usage; }
        PROVIDER="$1"
        if ! validate_provider "$PROVIDER"; then
            echo "Error: Invalid provider '$PROVIDER'. Valid: ${VALID_PROVIDERS[*]}" >&2
            exit 1
        fi
        init_db
        delete_creds "$PROVIDER"
        ;;
    *)
        echo "Error: Invalid action '$ACTION'" >&2
        usage
        ;;
esac