#!/bin/bash
# Unit tests for scripts/deploy-hook.sh.
#
# The deploy hook runs after every certbot renewal; certbot exports
# RENEWED_LINEAGE (the live dir of the renewed cert) and RENEWED_DOMAINS
# (space-separated SAN list). The hook must:
#   1. early-exit silently if RENEWED_LINEAGE is unset
#   2. extract the base domain from RENEWED_LINEAGE
#   3. UPDATE domains.db.cert_date for that domain
#   4. reload apache2
#   5. log the outcome to $LOG_FILE
#
# We can't reload apache2 in a unit test, so we stub systemctl + create a
# fake apache2 to verify the call. sqlite3 is real (it's a runtime dep).

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

SANDBOX="$(make_a2tools_sandbox)"
fill_sandbox_with_repo "$SANDBOX"

# Initialize a real domains DB with the production schema.
sqlite3 "$SANDBOX/var/lib/a2tools/domains.db" < "$A2TOOLS_SHARE_DIR/sql/domains.sql"
# Seed an existing row so the UPDATE has something to match.
sqlite3 "$SANDBOX/var/lib/a2tools/domains.db" \
    "INSERT INTO domains (domain, status, registrar) VALUES ('example.com', 'owned', 'namecheap.com');"

# Create a stub systemctl and a stub apache2ctl so the hook can be
# exercised without root or a real Apache. Place them on a PATH that
# the hook's PATH lookup will use.
STUB_BIN="$SANDBOX/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/systemctl" <<'EOF'
#!/bin/bash
# stub: log every call to /var/log/a2tools/systemctl.log
echo "$(date '+%Y-%m-%d %H:%M:%S') systemctl $*" >> "$STUB_LOG_FILE"
exit 0
EOF
chmod +x "$STUB_BIN/systemctl"

# The hook uses 'systemctl reload apache2'. The stub above handles any
# systemctl subcommand uniformly; nothing else to stub.

# Run the deploy hook in a subshell with the sandbox env + a faked PATH.
# The lib is sourced first, then we override its hard-coded FHS paths
# to point at the sandbox, THEN we source the deploy-hook script (which
# immediately runs its body and `exit 0`).
run_deploy_hook() {
    local renewed_lineage="$1" renewed_domains="$2"
    (
        # Stubs shadow real binaries.
        export PATH="$STUB_BIN:$PATH"
        export STUB_LOG_FILE="$SANDBOX/var/log/a2tools/systemctl.log"

        # certbot-supplied env (exported BEFORE sourcing the lib so the
        # hook body sees them when it runs).
        export RENEWED_LINEAGE="$renewed_lineage"
        export RENEWED_DOMAINS="$renewed_domains"

        # Source the lib first (it overwrites the FHS paths).
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"

        # Override the lib's hard-coded FHS paths to point at the sandbox.
        A2TOOLS_ETC="$SANDBOX/etc/a2tools"
        A2TOOLS_STATE="$SANDBOX/var/lib/a2tools"
        A2TOOLS_CACHE_DIR="$SANDBOX/var/cache/a2tools"
        A2TOOLS_LOG_DIR="$SANDBOX/var/log/a2tools"
        DOMAINS_DB_PATH="$A2TOOLS_STATE/domains.db"
        CREDS_DB_PATH="$A2TOOLS_STATE/creds.db"
        DOMAIN_CONFIG_PATH="$A2TOOLS_ETC/domain.conf"
        WAN_IP_STATE_FILE="$A2TOOLS_STATE/wan_ip"
        LOG_FILE="$A2TOOLS_LOG_DIR/fqdnmgr.log"

        # Source the deploy hook (runs its body, then exits the subshell).
        # shellcheck disable=SC1090
        . "$A2TOOLS_SCRIPTS_DIR/deploy-hook.sh"
    ) 2>/dev/null
}

# ---------------------------------------------------------------------------
test_starts_with "deploy-hook: no-op when RENEWED_LINEAGE is unset"
# ---------------------------------------------------------------------------
# If RENEWED_LINEAGE is empty, the hook exits 0 immediately without
# touching apache or the DB.
before_cert_date="$(sqlite3 "$SANDBOX/var/lib/a2tools/domains.db" "SELECT cert_date FROM domains WHERE domain='example.com';")"
out="$(run_deploy_hook "" "example.com" || true)"
after_cert_date="$(sqlite3 "$SANDBOX/var/lib/a2tools/domains.db" "SELECT cert_date FROM domains WHERE domain='example.com';")"
assert_eq "$before_cert_date" "$after_cert_date" "DB unchanged when RENEWED_LINEAGE empty"
assert_file_missing "$SANDBOX/var/log/a2tools/systemctl.log" "no systemctl call when RENEWED_LINEAGE empty"

# ---------------------------------------------------------------------------
test_starts_with "deploy-hook: renews the cert_date for the lineage domain"
# ---------------------------------------------------------------------------
lineage="$SANDBOX/etc/letsencrypt/live/example.com"
# The hook uses $(basename "$RENEWED_LINEAGE") so the path doesn't need
# to exist - only the basename matters.
out_rc="$(run_deploy_hook "$lineage" "example.com www.example.com")"
rc=$?
assert_eq "0" "$rc" "deploy-hook exits 0 on success"

# cert_date should now be today's date.
expected_today="$(date '+%Y-%m-%d')"
actual_cert_date="$(sqlite3 "$SANDBOX/var/lib/a2tools/domains.db" "SELECT cert_date FROM domains WHERE domain='example.com';")"
assert_eq "$expected_today" "$actual_cert_date" "cert_date updated to today"

# systemctl reload apache2 was called.
assert_file_exists "$SANDBOX/var/log/a2tools/systemctl.log" "systemctl was invoked"
assert_contains "$(cat "$SANDBOX/var/log/a2tools/systemctl.log")" "reload apache2" "apache2 was reloaded"

# ---------------------------------------------------------------------------
test_starts_with "deploy-hook: logs the renewal event"
# ---------------------------------------------------------------------------
log_contents="$(cat "$SANDBOX/var/log/a2tools/fqdnmgr.log" 2>/dev/null || true)"
assert_contains "$log_contents" "deploy-hook: renewed example.com" "log records the renewal"
assert_contains "$log_contents" "apache reloaded" "log records the reload"

# ---------------------------------------------------------------------------
test_starts_with "deploy-hook: rejects an invalid lineage basename"
# ---------------------------------------------------------------------------
# If the basename is not a valid FQDN (e.g. contains underscores), the
# is_valid_fqdn check should skip the DB UPDATE, but still attempt the
# apache reload.
lineage="$SANDBOX/etc/letsencrypt/live/INVALID_NAME"
# Clear the stub's log so we can prove THIS test's call to systemctl
# happened (not just a stale entry from a previous test).
rm -f "$SANDBOX/var/log/a2tools/systemctl.log"
before="$(sqlite3 "$SANDBOX/var/lib/a2tools/domains.db" "SELECT cert_date FROM domains WHERE domain='example.com';")"
out_rc="$(run_deploy_hook "$lineage" "INVALID_NAME")"
after="$(sqlite3 "$SANDBOX/var/lib/a2tools/domains.db" "SELECT cert_date FROM domains WHERE domain='example.com';")"
assert_eq "$before" "$after" "invalid lineage -> DB cert_date untouched"
# apache was still reloaded (the hook always tries to reload, even when
# the DB update is skipped).
assert_contains "$(cat "$SANDBOX/var/log/a2tools/systemctl.log")" "reload apache2" "apache2 reloaded even on invalid lineage"

test_summary
