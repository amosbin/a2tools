#!/bin/bash

# fqdncredmgr daemon - serves credentials over Unix socket

SOCKET_PATH="/run/fqdncredmgr.sock"
DB_PATH="/etc/fqdntools/creds.db"

show_help() {
    cat << EOF
Usage: fqdncredmgrd [OPTIONS]

FQDN Credential Manager Daemon - serves DNS provider credentials over Unix socket

OPTIONS:
    -h, --help    Show this help message and exit

DESCRIPTION:
    This daemon listens on a Unix socket ($SOCKET_PATH) and serves
    DNS provider credentials stored in the database ($DB_PATH).
    
    The daemon handles GET_CREDS requests and returns username/API key pairs
    for the specified DNS provider.

EXAMPLES:
    # Start the daemon
    fqdncredmgrd

    # Query credentials (from another process)
    echo "GET_CREDS:namecheap.com" | socat - UNIX-CONNECT:$SOCKET_PATH

EOF
    exit 0
}

cleanup() {
    rm -f "$SOCKET_PATH"
    exit 0
}

trap cleanup SIGTERM SIGINT

escape_sql() {
    printf '%s' "$1" | sed "s/'/''/g"
}

handle_request() {
    local request="$1"
    
    case "$request" in
        GET_CREDS:*)
            local provider="${request#GET_CREDS:}"
            provider=$(echo "$provider" | tr -d '\r\n')
            
            if [ -z "$provider" ]; then
                echo "ERROR:provider required"
                return
            fi
            
            if [ ! -f "$DB_PATH" ]; then
                echo "ERROR:database not found"
                return
            fi
            
            local creds
            creds=$(sqlite3 "$DB_PATH" "SELECT username, key FROM creds WHERE provider='$(escape_sql "$provider")' LIMIT 1;" 2>/dev/null)
            
            if [ -z "$creds" ]; then
                echo "ERROR:no credentials for provider $provider"
                return
            fi
            
            local username key
            username=$(echo "$creds" | cut -d'|' -f1)
            key=$(echo "$creds" | cut -d'|' -f2)
            
            if [ -z "$username" ] || [ -z "$key" ]; then
                echo "ERROR:incomplete credentials"
                return
            fi
            
            echo "OK:${username}|${key}"
            ;;
        *)
            echo "ERROR:unknown command"
            ;;
    esac
}

main() {
    rm -f "$SOCKET_PATH"
    
    socat UNIX-LISTEN:"$SOCKET_PATH",fork,mode=0600,user=root,group=root SYSTEM:'read request && /usr/local/bin/fqdncredmgrd handle "$request"'
}

case "$1" in
    -h|--help)
        show_help
        ;;
    handle)
        shift
        handle_request "$*"
        ;;
    *)
        main
        ;;
esac
