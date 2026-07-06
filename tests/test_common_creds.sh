#!/bin/bash
# Unit tests for the credentials DB helpers in lib/common.sh.
#
# These tests use a real SQLite database (sqlite3 is a runtime dep of a2tools)
# inside the scratch dir. They do NOT touch /var/lib/a2tools.
#
# Covers: creds_get return codes (0/11/12/15), has_creds_for, key extraction,
# empty-row handling, special-character SQL escaping.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

# A2TOOLS_SANDBOX creates a fake /var/lib/a2tools and other FHS paths inside
# the scratch dir. We then source common.sh with these paths baked in via
# overrides so it never touches the real install paths.
SANDBOX="$(make_a2tools_sandbox)"
fill_sandbox_with_repo "$SANDBOX"

# Path overrides for the lib. These must be set AFTER common.sh is sourced
# (the lib hard-codes the FHS paths on load).
override_paths() {
    A2TOOLS_ETC="$SANDBOX/etc/a2tools"
    A2TOOLS_STATE="$SANDBOX/var/lib/a2tools"
    A2TOOLS_CACHE_DIR="$SANDBOX/var/cache/a2tools"
    A2TOOLS_LOG_DIR="$SANDBOX/var/log/a2tools"
    DOMAINS_DB_PATH="$A2TOOLS_STATE/domains.db"
    CREDS_DB_PATH="$A2TOOLS_STATE/creds.db"
    DOMAIN_CONFIG_PATH="$A2TOOLS_ETC/domain.conf"
    WAN_IP_STATE_FILE="$A2TOOLS_STATE/wan_ip"
    LOG_FILE="$A2TOOLS_LOG_DIR/fqdnmgr.log"
}

# Initialize a creds DB with the production schema and seed data.
init_creds_db() {
    local db="$1"
    sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS creds (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL,
    key TEXT NOT NULL,
    provider TEXT NOT NULL UNIQUE
);
SQL
}

# Run `code` with the lib sourced and creds DB env wired to the sandbox.
# Captures stdout and rc; stderr is suppressed.
run_with_lib() {
    local code="$1" db="${2:-$SANDBOX/var/lib/a2tools/creds.db}"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        override_paths
        CREDS_DB_PATH="$db"
        eval "$code"
    ) 2>/dev/null
}

# run_with_lib_rc: like run_with_lib but discards stdout and prints only rc.
run_with_lib_rc() {
    local code="$1" db="${2:-$SANDBOX/var/lib/a2tools/creds.db}"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        override_paths
        CREDS_DB_PATH="$db"
        eval "$code" >/dev/null 2>&1
    )
    echo $?
}

# run_with_lib_stdout: like run_with_lib, prints stdout only.
run_with_lib_stdout() {
    local code="$1" db="${2:-$SANDBOX/var/lib/a2tools/creds.db}"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        override_paths
        CREDS_DB_PATH="$db"
        eval "$code" 2>/dev/null
    )
}

# ---------------------------------------------------------------------------
test_starts_with "creds_get: missing database returns rc 12"
# ---------------------------------------------------------------------------
# When the creds DB file does NOT exist, creds_get prints
#   CREDS_ERROR:database_not_found
# and returns 12.
out="$(run_with_lib_stdout 'creds_get namecheap.com' "/nonexistent/creds.db")"
rc="$?"
assert_eq "12" "$rc" "missing DB -> rc 12"
assert_contains "$out" "CREDS_ERROR:database_not_found" "missing DB -> CREDS_ERROR marker on stdout"

# ---------------------------------------------------------------------------
test_starts_with "creds_get: empty database returns rc 11"
# ---------------------------------------------------------------------------
empty_db="$SANDBOX/var/lib/a2tools/creds-empty.db"
init_creds_db "$empty_db"
out="$(run_with_lib_stdout 'creds_get namecheap.com' "$empty_db")"
rc="$?"
assert_eq "11" "$rc" "no matching row -> rc 11"
assert_contains "$out" "CREDS_ERROR:no_credentials:namecheap.com" \
    "no row -> machine-parsable error with provider name"

# ---------------------------------------------------------------------------
test_starts_with "creds_get: stores and retrieves a credential row"
# ---------------------------------------------------------------------------
db="$SANDBOX/var/lib/a2tools/creds.db"
init_creds_db "$db"
sqlite3 "$db" "INSERT INTO creds (username, key, provider) VALUES ('alice', 'sk-test-123', 'namecheap.com');"

out="$(run_with_lib_stdout 'creds_get namecheap.com' "$db")"
rc="$?"
assert_eq "0" "$rc" "creds_get -> rc 0 on hit"
# On success creds_get exports PROVIDER_USERNAME and PROVIDER_API_KEY.
# Capture them via a sub-eval.
val="$(run_with_lib 'creds_get namecheap.com >/dev/null; printf "%s|%s" "$PROVIDER_USERNAME" "$PROVIDER_API_KEY"' "$db")"
assert_eq "alice|sk-test-123" "$val" "creds_get exports username and api key"

# ---------------------------------------------------------------------------
test_starts_with "creds_get: incomplete row returns rc 15"
# ---------------------------------------------------------------------------
# A row with an empty username or empty key must be flagged as incomplete.
db_inc="$SANDBOX/var/lib/a2tools/creds-incomplete.db"
init_creds_db "$db_inc"
sqlite3 "$db_inc" "INSERT INTO creds (username, key, provider) VALUES ('', 'sk-x', 'namecheap.com');"

out="$(run_with_lib_stdout 'creds_get namecheap.com' "$db_inc")"
rc="$?"
assert_eq "15" "$rc" "empty username -> rc 15"
assert_contains "$out" "CREDS_ERROR:incomplete_credentials:namecheap.com" \
    "incomplete row -> machine-parsable error"

# A row with an empty key is also incomplete.
sqlite3 "$db_inc" "DELETE FROM creds WHERE provider='namecheap.com';"
sqlite3 "$db_inc" "INSERT INTO creds (username, key, provider) VALUES ('bob', '', 'namecheap.com');"
rc="$(run_with_lib_rc 'creds_get namecheap.com' "$db_inc")"
assert_eq "15" "$rc" "empty key -> rc 15"

# ---------------------------------------------------------------------------
test_starts_with "creds_get: SQL-injection-safe provider name"
# ---------------------------------------------------------------------------
# The provider is interpolated into a SQL string via sql_escape. A name
# containing a single quote must not break out of the literal.
db_q="$SANDBOX/var/lib/a2tools/creds-quote.db"
init_creds_db "$db_q"
sqlite3 "$db_q" "INSERT INTO creds (username, key, provider) VALUES ('eve', 'k', \"weird'name.com\");"

rc="$(run_with_lib_rc "creds_get \"weird'name.com\"" "$db_q")"
assert_eq "0" "$rc" "provider name with apostrophe resolves correctly"

# ---------------------------------------------------------------------------
test_starts_with "has_creds_for"
# ---------------------------------------------------------------------------
db_h="$SANDBOX/var/lib/a2tools/creds-has.db"
init_creds_db "$db_h"

# Empty arg rejected
rc="$(run_with_lib_rc 'has_creds_for ""' "$db_h")"
assert_eq "1" "$rc" "empty provider -> false"

# No row -> false
rc="$(run_with_lib_rc 'has_creds_for namecheap.com' "$db_h")"
assert_eq "1" "$rc" "no row -> false"

# Add a row, then expect true
sqlite3 "$db_h" "INSERT INTO creds (username, key, provider) VALUES ('a', 'k', 'namecheap.com');"
rc="$(run_with_lib_rc 'has_creds_for namecheap.com' "$db_h")"
assert_eq "0" "$rc" "valid row -> true"

# A row with empty username is NOT a usable credential.
sqlite3 "$db_h" "DELETE FROM creds WHERE provider='emptyuser.com';"
sqlite3 "$db_h" "INSERT INTO creds (username, key, provider) VALUES ('', 'k', 'emptyuser.com');"
rc="$(run_with_lib_rc 'has_creds_for emptyuser.com' "$db_h")"
assert_eq "1" "$rc" "empty-username row -> false"

# A row with empty key is NOT a usable credential.
sqlite3 "$db_h" "DELETE FROM creds WHERE provider='emptykey.com';"
sqlite3 "$db_h" "INSERT INTO creds (username, key, provider) VALUES ('u', '', 'emptykey.com');"
rc="$(run_with_lib_rc 'has_creds_for emptykey.com' "$db_h")"
assert_eq "1" "$rc" "empty-key row -> false"

# has_creds_for returns false (rc 1) when the DB doesn't exist.
rc="$(run_with_lib_rc 'has_creds_for namecheap.com' "/nonexistent/creds.db")"
assert_eq "1" "$rc" "missing DB -> false"

test_summary
