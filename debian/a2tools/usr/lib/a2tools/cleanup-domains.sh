#!/bin/bash
# Prune stale rows from the a2tools domains DB.
#
# Deletes any rows whose status != 'owned' once the configured interval has
# elapsed. Scheduled by a2tools-domain-cleanup.timer (weekly); the interval in
# /etc/a2tools/domain.conf (DOMAIN_CLEANUP_DAYS, e.g. "7D") additionally gates
# how often the delete actually runs.
set -euo pipefail

A2TOOLS_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
. "$A2TOOLS_SELF_DIR/lib/common.sh"

LAST_RUN_FILE="$A2TOOLS_STATE/last_domain_cleanup"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# Read configured interval (e.g. 7D). Default to 7D if missing/invalid.
DOMAIN_CLEANUP_DAYS_VAL="7D"
if [ -f "$DOMAIN_CONFIG_PATH" ]; then
    # shellcheck disable=SC1090
    . "$DOMAIN_CONFIG_PATH" || true
    if [ -n "${DOMAIN_CLEANUP_DAYS-}" ]; then
        DOMAIN_CLEANUP_DAYS_VAL="$DOMAIN_CLEANUP_DAYS"
    fi
fi

if ! printf '%s' "$DOMAIN_CLEANUP_DAYS_VAL" | grep -qE '^[0-9]+D$'; then
    log "Invalid DOMAIN_CLEANUP_DAYS='$DOMAIN_CLEANUP_DAYS_VAL' - must be like '7D'. Using default '7D'."
    DOMAIN_CLEANUP_DAYS_VAL="7D"
fi

NUM_DAYS="${DOMAIN_CLEANUP_DAYS_VAL%D}"
INTERVAL_SECS=$(( NUM_DAYS * 86400 ))

mkdir -p "$A2TOOLS_STATE" 2>/dev/null || true

now=$(date +%s)
last_run=0
if [ -f "$LAST_RUN_FILE" ]; then
    last_run=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)
    case "$last_run" in (*[!0-9]*|'') last_run=0 ;; esac
fi

elapsed=$(( now - last_run ))
if [ "$elapsed" -lt "$INTERVAL_SECS" ]; then
    log "Skipping cleanup: only ${elapsed}s since last run (< ${INTERVAL_SECS}s)."
    exit 0
fi

if [ ! -f "$DOMAINS_DB_PATH" ]; then
    log "Domains DB not found: $DOMAINS_DB_PATH - nothing to do."
    date +%s > "$LAST_RUN_FILE" 2>/dev/null || true
    exit 0
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    log "sqlite3 not found; cannot clean up domains DB."
    exit 0
fi

log "Running domain cleanup: deleting rows where status != 'owned' from $DOMAINS_DB_PATH"
if ! db_domains "DELETE FROM domains WHERE status != 'owned';"; then
    log "sqlite3 command failed"
    exit 1
fi

date +%s > "$LAST_RUN_FILE" 2>/dev/null || true
log "Domain cleanup completed"
exit 0
