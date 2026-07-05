#!/bin/bash
# fqdncredmgr - manage DNS provider credentials (add/update/delete/list).
#
# Credentials are stored in a root-only SQLite database
# (/var/lib/a2tools/creds.db, mode 0600) and read directly by fqdnmgr via
# lib/common.sh. There is no daemon.
#
# Supplying the API key:
#   -p -        read the key from stdin (recommended for scripting; keeps the
#               secret out of argv and shell history)
#   (omitted)   prompt interactively with masked input
#
# Passing the key itself as a command-line argument is NOT supported: argv is
# visible to every local user via `ps` and lands in shell history.

A2TOOLS_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
. "$A2TOOLS_SELF_DIR/lib/common.sh"

USAGE_FILE="$A2TOOLS_SHARE/usage/fqdncredmgr.txt"

usage() { cat "$USAGE_FILE"; exit 1; }

require_db() {
    if [ ! -f "$CREDS_DB_PATH" ]; then
        echo "Error: Credentials database $CREDS_DB_PATH not found. Reinstall a2tools to initialize it." >&2
        exit 1
    fi
}

db_creds() { sqlite3 "$CREDS_DB_PATH" "$@"; }

validate_provider() {
    local p="$1" v
    while IFS= read -r v; do
        [ "$p" = "$v" ] && return 0
    done < <(list_providers)
    return 1
}

# Prompt for the API key interactively (masked, confirmed, no timeout).
# Prefers systemd-ask-password (masked '*' echo); falls back to the read
# builtin with echo disabled.
prompt_api_key() {
    local key="" confirm=""
    if command -v systemd-ask-password >/dev/null 2>&1; then
        key=$(systemd-ask-password --timeout=0 --echo=masked "Enter API key:") || return 1
        confirm=$(systemd-ask-password --timeout=0 --echo=masked "Confirm API key:") || return 1
    elif { : < /dev/tty; } 2>/dev/null; then
        IFS= read -r -s -p "Enter API key: " key < /dev/tty || return 1
        printf '\n' >&2
        IFS= read -r -s -p "Confirm API key: " confirm < /dev/tty || return 1
        printf '\n' >&2
    else
        echo "Error: No interactive terminal available; pipe the key via '-p -'" >&2
        return 1
    fi
    if [ -z "$key" ]; then
        echo "Error: API key cannot be empty" >&2
        return 1
    fi
    if [ "$key" != "$confirm" ]; then
        echo "Error: API keys do not match" >&2
        return 1
    fi
    printf '%s' "$key"
}

# Mask usernames for listing (never print stored usernames verbatim)
mask_username() {
    local u="$1"
    mask_part() {
        local s="$1" l=${#1}
        if [ "$l" -le 2 ]; then
            printf '%*s' "$l" '' | tr ' ' '*'
        else
            printf '%s%s%s' "${s:0:1}" "$(printf '%*s' $((l - 2)) '' | tr ' ' '*')" "${s: -1}"
        fi
    }
    if [[ "$u" == *"@"* ]]; then
        local lp="${u%%@*}" dp="${u#*@}"
        local domain_label="${dp%%.*}" extension=""
        [[ "$dp" == *.* ]] && extension=".${dp#*.}"
        local dl_len=${#domain_label} d_mask
        if [ "$dl_len" -le 2 ]; then
            d_mask="$(printf '%*s' "$dl_len" '' | tr ' ' '*')"
        else
            d_mask="${domain_label:0:1}$(printf '%*s' $((dl_len - 1)) '' | tr ' ' '*')"
        fi
        printf '%s@%s%s' "$(mask_part "$lp")" "$d_mask" "$extension"
    else
        mask_part "$u"
    fi
}

# --- argument parsing (order-independent -v, no word-splitting hacks) -------
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "-v" ]; then
        VERBOSE=true
    else
        ARGS+=("$arg")
    fi
done
set -- "${ARGS[@]}"

[ $# -ge 1 ] || { echo "Error: Insufficient arguments" >&2; usage; }

ACTION="$1"
shift

case "$ACTION" in
    list)
        require_db
        db_creds -separator $'\t' "SELECT provider, username FROM creds ORDER BY provider;" | \
        while IFS=$'\t' read -r provider username; do
            [ -z "$provider" ] && continue
            printf '%s\t%s\n' "$provider" "$(mask_username "$username")"
        done
        ;;

    add|update)
        [ $# -ge 1 ] || { echo "Error: PROVIDER required" >&2; usage; }
        PROVIDER="$1"; shift
        if ! validate_provider "$PROVIDER"; then
            echo "Error: Invalid provider '$PROVIDER'. Valid providers:" >&2
            list_providers >&2
            exit 1
        fi

        API_KEY="" USERNAME="" KEY_FROM_STDIN=false
        while [ $# -gt 0 ]; do
            case "$1" in
                -p)
                    if [ "${2:-}" = "-" ]; then
                        KEY_FROM_STDIN=true
                    else
                        echo "Error: API keys on the command line are not supported." >&2
                        echo "Use '-p -' to read the key from stdin, or omit -p to be prompted." >&2
                        exit 1
                    fi
                    shift 2
                    ;;
                *)
                    [ -n "$USERNAME" ] && { echo "Error: Unexpected argument '$1'" >&2; usage; }
                    USERNAME="$1"; shift
                    ;;
            esac
        done
        [ -n "$USERNAME" ] || { echo "Error: USERNAME required" >&2; usage; }

        require_db

        if [ "$ACTION" = "update" ]; then
            exists=$(db_creds "SELECT COUNT(1) FROM creds WHERE provider='$(sql_escape "$PROVIDER")';")
            if [ -z "$exists" ] || [ "$exists" -eq 0 ]; then
                echo "Error: No credentials stored for provider $PROVIDER. Run 'fqdncredmgr list' to see entries." >&2
                exit 1
            fi
        fi

        if [ "$KEY_FROM_STDIN" = true ]; then
            IFS= read -r API_KEY
            [ -n "$API_KEY" ] || { echo "Error: Empty API key on stdin" >&2; exit 1; }
        else
            API_KEY=$(prompt_api_key) || exit 1
        fi

        if db_creds "INSERT INTO creds (username, key, provider)
                     VALUES ('$(sql_escape "$USERNAME")', '$(sql_escape "$API_KEY")', '$(sql_escape "$PROVIDER")')
                     ON CONFLICT(provider) DO UPDATE SET username=excluded.username, key=excluded.key;"; then
            vecho "Credentials set for $PROVIDER with username $USERNAME"
        else
            echo "Error: Failed to store credentials" >&2
            exit 1
        fi
        ;;

    delete)
        [ $# -ge 1 ] || { echo "Error: PROVIDER required" >&2; usage; }
        PROVIDER="$1"
        if ! validate_provider "$PROVIDER"; then
            echo "Error: Invalid provider '$PROVIDER'. Valid providers:" >&2
            list_providers >&2
            exit 1
        fi
        require_db
        changes=$(db_creds "DELETE FROM creds WHERE provider='$(sql_escape "$PROVIDER")'; SELECT changes();")
        if [ -n "$changes" ] && [ "$changes" -gt 0 ]; then
            vecho "Credentials deleted for provider $PROVIDER"
        else
            echo "Error: No matching credentials for provider '$PROVIDER'" >&2
            exit 1
        fi
        ;;

    -h|--help)
        cat "$USAGE_FILE"
        exit 0
        ;;

    *)
        echo "Error: Invalid action '$ACTION'" >&2
        usage
        ;;
esac
