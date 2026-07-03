#!/bin/bash
# Weekly cleanup wrapper script (no per-row age checks)
# Deletes any rows from the domains DB whose status != 'owned' when the
# configured interval has elapsed. The interval is controlled by
# /etc/fqdnmgr/domain.conf: DOMAIN_CLEANUP_DAYS (format: N D, e.g. 7D).
set -euo pipefail

DOMAINS_DB_PATH="/etc/fqdntools/domains.db"
DOMAIN_CONF="/etc/fqdnmgr/domain.conf"
STATE_DIR="/var/lib/fqdnmgr"
LAST_RUN_FILE="$STATE_DIR/last_domain_cleanup"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# Read configured days (e.g. 7D). Default to 7D if missing/invalid.
DOMAIN_CLEANUP_DAYS_VAL="7D"
if [ -f "$DOMAIN_CONF" ]; then
    # shellcheck disable=SC1090
    . "$DOMAIN_CONF" || true
    if [ -n "${DOMAIN_CLEANUP_DAYS-}" ]; then
        DOMAIN_CLEANUP_DAYS_VAL="$DOMAIN_CLEANUP_DAYS"
    fi
fi

if ! echo "$DOMAIN_CLEANUP_DAYS_VAL" | grep -qE '^[0-9]+D$'; then
    log "Invalid DOMAIN_CLEANUP_DAYS='$DOMAIN_CLEANUP_DAYS_VAL' — must be like '7D'. Using default '7D'."
    DOMAIN_CLEANUP_DAYS_VAL="7D"
fi

NUM_DAYS=$(echo "$DOMAIN_CLEANUP_DAYS_VAL" | sed 's/D$//')
if ! echo "$NUM_DAYS" | grep -qE '^[0-9]+$'; then
    NUM_DAYS=7
fi

INTERVAL_SECS=$(( NUM_DAYS * 86400 ))

# Ensure state dir exists
if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    chown root:root "$STATE_DIR" 2>/dev/null || true
    chmod 0755 "$STATE_DIR" 2>/dev/null || true
fi

now=$(date +%s)
if [ -f "$LAST_RUN_FILE" ]; then
    last_run=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)
else
    last_run=0
fi

elapsed=$(( now - last_run ))
if [ "$elapsed" -lt "$INTERVAL_SECS" ]; then
    log "Skipping cleanup: only $elapsed seconds since last run (< ${INTERVAL_SECS})."
    exit 0
fi

if [ ! -f "$DOMAINS_DB_PATH" ]; then
    log "Domains DB not found: $DOMAINS_DB_PATH — nothing to do."
    # update last run so we don't spam
    date +%s > "$LAST_RUN_FILE" 2>/dev/null || true
    exit 0
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    log "sqlite3 not found; cannot cleanup domains DB."
    exit 0
fi

log "Running domain cleanup: deleting rows where status != 'owned' from $DOMAINS_DB_PATH"
sqlite3 "$DOMAINS_DB_PATH" "BEGIN TRANSACTION; DELETE FROM domains WHERE status != 'owned'; COMMIT;" 2>/dev/null || {
    log "sqlite3 command failed"
    exit 1
}

# record last run timestamp
date +%s > "$LAST_RUN_FILE" 2>/dev/null || true
log "Domain cleanup completed"

exit 0
