#!/bin/bash
# Unit tests for the interval-parsing / validation logic in cleanup-domains.sh.
#
# The script's first job is to read DOMAIN_CLEANUP_DAYS from domain.conf,
# validate that it looks like "ND" (e.g. 7D), and compute the equivalent
# interval in seconds. We extract that logic and exercise it in isolation.
# We do NOT exercise the SQL DELETE (the script requires sqlite3 + a real
# domains DB and the DELETE itself is a single sqlite3 call - low value to
# unit-test).

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

SANDBOX="$(make_a2tools_sandbox)"
fill_sandbox_with_repo "$SANDBOX"

# Extract: pull the interval-parsing block out of cleanup-domains.sh so
# we can run it in isolation. The block is everything from "DOMAIN_CLEANUP_DAYS_VAL="
# to the "INTERVAL_SECS=..." assignment.
EXTRACT="$A2TOOLS_TEST_TMPDIR/cleanup-interval.sh"
awk '
    /DOMAIN_CLEANUP_DAYS_VAL="7D"/ { in_block=1 }
    in_block { print }
    in_block && /INTERVAL_SECS=\$\(\(.*NUM_DAYS/ { in_block=0; print; exit }
' "$A2TOOLS_SCRIPTS_DIR/cleanup-domains.sh" > "$EXTRACT"

if [ ! -s "$EXTRACT" ]; then
    echo "FATAL: failed to extract interval-parsing block" >&2
    exit 2
fi

# Compute the parsed interval given a domain.conf path. The extracted
# block reads DOMAIN_CONFIG_PATH (set after common.sh sources, since the
# lib hard-codes FHS paths on load), then prints INTERVAL_SECS.
parse_interval() {
    local conf="$1"
    local db="${2:-$SANDBOX/var/lib/a2tools/domains.db}"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        # Override the lib's hard-coded FHS paths to point at the sandbox.
        A2TOOLS_ETC="$SANDBOX/etc/a2tools"
        A2TOOLS_STATE="$SANDBOX/var/lib/a2tools"
        A2TOOLS_LOG_DIR="$SANDBOX/var/log/a2tools"
        A2TOOLS_CACHE_DIR="$SANDBOX/var/cache/a2tools"
        DOMAINS_DB_PATH="$db"
        CREDS_DB_PATH="$SANDBOX/var/lib/a2tools/creds.db"
        DOMAIN_CONFIG_PATH="$conf"
        WAN_IP_STATE_FILE="$A2TOOLS_STATE/wan_ip"
        LOG_FILE="$A2TOOLS_LOG_DIR/fqdnmgr.log"

        # shellcheck disable=SC1090
        . "$EXTRACT"
        printf '%s' "$INTERVAL_SECS"
    ) 2>/dev/null
}

# ---------------------------------------------------------------------------
test_starts_with "interval parser: default 7D when domain.conf missing"
# ---------------------------------------------------------------------------
# Point DOMAIN_CONFIG_PATH at a nonexistent file -> default 7D -> 604800s.
out="$(parse_interval "$SANDBOX/etc/a2tools/does-not-exist.conf")"
assert_eq "604800" "$out" "default 7D -> 604800s"

# ---------------------------------------------------------------------------
test_starts_with "interval parser: 1D -> 86400s"
# ---------------------------------------------------------------------------
conf1d="$SANDBOX/etc/a2tools/domain-1d.conf"
cat > "$conf1d" <<'EOF'
DOMAIN_CLEANUP_DAYS=1D
EOF
out="$(parse_interval "$conf1d")"
assert_eq "86400" "$out" "1D -> 86400s"

# ---------------------------------------------------------------------------
test_starts_with "interval parser: 30D -> 2592000s"
# ---------------------------------------------------------------------------
conf30d="$SANDBOX/etc/a2tools/domain-30d.conf"
cat > "$conf30d" <<'EOF'
DOMAIN_CLEANUP_DAYS=30D
EOF
out="$(parse_interval "$conf30d")"
assert_eq "2592000" "$out" "30D -> 2592000s"

# ---------------------------------------------------------------------------
test_starts_with "interval parser: malformed value -> falls back to 7D"
# ---------------------------------------------------------------------------
# No trailing 'D' -> invalid -> default 7D.
conf_bad="$SANDBOX/etc/a2tools/domain-bad.conf"
cat > "$conf_bad" <<'EOF'
DOMAIN_CLEANUP_DAYS=7
EOF
out="$(parse_interval "$conf_bad")"
assert_eq "604800" "$out" "missing D suffix -> default 7D"

# Empty value -> invalid -> default 7D.
conf_empty="$SANDBOX/etc/a2tools/domain-empty.conf"
cat > "$conf_empty" <<'EOF'
DOMAIN_CLEANUP_DAYS=
EOF
out="$(parse_interval "$conf_empty")"
assert_eq "604800" "$out" "empty value -> default 7D"

# Negative / non-numeric -> invalid -> default 7D.
conf_neg="$SANDBOX/etc/a2tools/domain-neg.conf"
cat > "$conf_neg" <<'EOF'
DOMAIN_CLEANUP_DAYS=-3D
EOF
out="$(parse_interval "$conf_neg")"
assert_eq "604800" "$out" "-3D rejected (regex disallows leading minus) -> default 7D"

# ---------------------------------------------------------------------------
test_starts_with "interval parser: large value (365D)"
# ---------------------------------------------------------------------------
conf_year="$SANDBOX/etc/a2tools/domain-year.conf"
cat > "$conf_year" <<'EOF'
DOMAIN_CLEANUP_DAYS=365D
EOF
out="$(parse_interval "$conf_year")"
assert_eq "31536000" "$out" "365D -> 31536000s"

# ---------------------------------------------------------------------------
test_starts_with "interval parser: domain.conf with extra comments"
# ---------------------------------------------------------------------------
# DOMAIN_CLEANUP_DAYS=14D surrounded by bash comments and other vars.
conf_mixed="$SANDBOX/etc/a2tools/domain-mixed.conf"
cat > "$conf_mixed" <<'EOF'
# a2tools domain config
AVG_PROPAGATION_TIME_namecheap_com=42
DOMAIN_CLEANUP_DAYS=14D
# trailing comment
EOF
out="$(parse_interval "$conf_mixed")"
assert_eq "1209600" "$out" "14D -> 1209600s"

test_summary
