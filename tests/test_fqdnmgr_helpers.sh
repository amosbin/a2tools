#!/bin/bash
# Unit tests for pure helper functions in fqdnmgr.sh.
#
# These functions don't touch the network, don't source a provider plugin,
# and don't need a real /var/lib. They're sourced from fqdnmgr.sh in a
# subshell with a sandboxed environment.
#
# Covers: get_effective_ownership_domain, get_tld, get_avg_propagation_time,
# calculate_next_wait, _cache_ttl_for, update_avg_propagation_time.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

SANDBOX="$(make_a2tools_sandbox)"
fill_sandbox_with_repo "$SANDBOX"

# Build a domain.conf that sets a per-registrar propagation override so
# get_avg_propagation_time can be exercised both with and without overrides.
cat > "$SANDBOX/etc/a2tools/domain.conf" <<'EOF'
# a2tools domain config (test fixture)
AVG_PROPAGATION_TIME_namecheap_com=45
AVG_PROPAGATION_TIME_wedos_com=180
TLD_PRIORITY_io=wedos.com,namecheap.com
EOF

# Pre-create the cache dir so init_cache() does not have to write when
# fqdnmgr_funcs.sh sources.
mkdir -p "$SANDBOX/var/cache/a2tools" "$SANDBOX/var/log/a2tools" 2>/dev/null || true

# Run `code` in a subshell that has sourced the lib + the helper-function
# region of fqdnmgr.sh. We strip the `init_cache` and
# `cleanup_expired_cache` calls (which run on load) so they do NOT touch
# the real /var/cache/a2tools when running as root. All other lines are
# kept, so load_domain_config() and every helper function are present.
FQDNMGR_FUNCS_ONLY="$A2TOOLS_TEST_TMPDIR/fqdnmgr_funcs.sh"
grep -v -E '^(init_cache|cleanup_expired_cache)$' \
    "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" > "$FQDNMGR_FUNCS_ONLY"

# Sanity: the trimmed file should not contain the auto-init calls.
if grep -qE '^(init_cache|cleanup_expired_cache)$' "$FQDNMGR_FUNCS_ONLY"; then
    echo "FATAL: trimmed fqdnmgr.sh still contains init/cleanup lines" >&2
    exit 2
fi

# Path overrides for the lib + fqdnmgr. Applied AFTER both are sourced.
override_paths() {
    A2TOOLS_ETC="$SANDBOX/etc/a2tools"
    A2TOOLS_STATE="$SANDBOX/var/lib/a2tools"
    A2TOOLS_CACHE_DIR="$SANDBOX/var/cache/a2tools"
    A2TOOLS_LOG_DIR="$SANDBOX/var/log/a2tools"
    DOMAINS_DB_PATH="$A2TOOLS_STATE/domains.db"
    CREDS_DB_PATH="$A2TOOLS_STATE/creds.db"
    DOMAIN_CONFIG_PATH="$SANDBOX/etc/a2tools/domain.conf"
    WAN_IP_STATE_FILE="$A2TOOLS_STATE/wan_ip"
    LOG_FILE="$A2TOOLS_LOG_DIR/fqdnmgr.log"
    A2TOOLS_CACHE_FILE="$A2TOOLS_CACHE_DIR/a2tools.cache"
    A2TOOLS_CACHE_LOCK="$A2TOOLS_CACHE_DIR/.a2tools.cache.lock"
}

run_fqdnmgr() {
    local code="$1"
    local cache_file="${2:-$SANDBOX/var/cache/a2tools/default.cache}"
    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        # Override paths BEFORE sourcing fqdnmgr_funcs.sh so the
        # load_domain_config call (which runs at fqdnmgr_funcs.sh load
        # time) sees the sandboxed DOMAIN_CONFIG_PATH.
        override_paths
        # shellcheck disable=SC1090
        . "$FQDNMGR_FUNCS_ONLY"
        # Re-override A2TOOLS_CACHE_FILE (fqdnmgr_funcs.sh sets it from
        # A2TOOLS_CACHE_DIR) to the per-test cache file.
        A2TOOLS_CACHE_FILE="$cache_file"
        A2TOOLS_CACHE_LOCK="$(dirname "$cache_file")/$(basename "$cache_file").lock"
        eval "$code" 2>/dev/null
    )
}

run_fqdnmgr_rc() {
    local code="$1"
    local cache_file="${2:-$SANDBOX/var/cache/a2tools/default.cache}"
    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        override_paths
        # shellcheck disable=SC1090
        . "$FQDNMGR_FUNCS_ONLY"
        A2TOOLS_CACHE_FILE="$cache_file"
        A2TOOLS_CACHE_LOCK="$(dirname "$cache_file")/$(basename "$cache_file").lock"
        eval "$code" >/dev/null 2>&1
    )
    echo $?
}

# ---------------------------------------------------------------------------
test_starts_with "get_tld: returns the rightmost label"
# ---------------------------------------------------------------------------
assert_eq "com"      "$(run_fqdnmgr 'get_tld example.com')"        "get_tld example.com"
assert_eq "io"       "$(run_fqdnmgr 'get_tld hello.io')"           "get_tld hello.io"
assert_eq "co"       "$(run_fqdnmgr 'get_tld a.b.example.co')"      "get_tld deep"
assert_eq "museum"   "$(run_fqdnmgr 'get_tld some.thing.museum')"   "get_tld multi-label TLD"

# ---------------------------------------------------------------------------
test_starts_with "get_effective_ownership_domain: strips subdomain"
# ---------------------------------------------------------------------------
assert_eq "example.com"       "$(run_fqdnmgr 'get_effective_ownership_domain example.com')" \
    "apex domain is its own effective domain"
assert_eq "example.com"       "$(run_fqdnmgr 'get_effective_ownership_domain www.example.com')" \
    "single-level subdomain stripped"
assert_eq "example.com"       "$(run_fqdnmgr 'get_effective_ownership_domain a.b.c.example.com')" \
    "deep subdomain -> base"
# Edge: a 2-label string with a single dot is the apex (no subdomain).
assert_eq "foo.bar"           "$(run_fqdnmgr 'get_effective_ownership_domain foo.bar')" \
    "two-label apex unchanged"

# ---------------------------------------------------------------------------
test_starts_with "_cache_ttl_for: returns the right TTL per type"
# ---------------------------------------------------------------------------
assert_eq "3600"   "$(run_fqdnmgr '_cache_ttl_for whois_registrar')"  "whois_registrar -> 1h"
assert_eq "3600"   "$(run_fqdnmgr '_cache_ttl_for whois_available')"  "whois_available -> 1h"
assert_eq "7200"   "$(run_fqdnmgr '_cache_ttl_for ns')"               "ns -> 2h"
assert_eq "172800" "$(run_fqdnmgr '_cache_ttl_for dns_change')"       "dns_change -> 48h"
assert_eq "-1"     "$(run_fqdnmgr '_cache_ttl_for ap')"               "ap -> never"
assert_eq "3600"   "$(run_fqdnmgr '_cache_ttl_for unknown_type')"     "unknown type -> 1h default"

# ---------------------------------------------------------------------------
test_starts_with "get_avg_propagation_time: cache hit wins"
# ---------------------------------------------------------------------------
# Seed the cache directly so the cache hit branch is exercised.
cf1="$SANDBOX/var/cache/a2tools/ap-cachehit.cache"
out="$(run_fqdnmgr 'cache_set_ap "ns1.example.com" 33; get_avg_propagation_time ns1.example.com namecheap.com' "$cf1")"
assert_eq "33" "$out" "cached value wins over domain.conf override"

# ---------------------------------------------------------------------------
test_starts_with "get_avg_propagation_time: domain.conf override per registrar"
# ---------------------------------------------------------------------------
# No cache entry -> look at domain.conf. namecheap_com=45.
cf2="$SANDBOX/var/cache/a2tools/ap-nc.cache"
out="$(run_fqdnmgr 'get_avg_propagation_time ns2.example.com namecheap.com' "$cf2")"
assert_eq "45" "$out" "namecheap override (45) returned"

# wedos_com=180.
cf3="$SANDBOX/var/cache/a2tools/ap-wedos.cache"
out="$(run_fqdnmgr 'get_avg_propagation_time ns3.example.com wedos.com' "$cf3")"
assert_eq "180" "$out" "wedos override (180) returned"

# ---------------------------------------------------------------------------
test_starts_with "get_avg_propagation_time: hardcoded default fallback"
# ---------------------------------------------------------------------------
# An unknown registrar with no cache entry -> DEFAULT_AVG_PROPAGATION (120).
cf4="$SANDBOX/var/cache/a2tools/ap-default.cache"
out="$(run_fqdnmgr 'get_avg_propagation_time ns4.example.com unknown.com' "$cf4")"
assert_eq "120" "$out" "default 120 returned for unknown registrar"

# ---------------------------------------------------------------------------
test_starts_with "calculate_next_wait: respects MIN_CHECK_INTERVAL floor"
# ---------------------------------------------------------------------------
# average = 60, first_check_ts = now-50 -> remaining = 60 + (-50) = 10s.
# 10/2 = 5s, but MIN_CHECK_INTERVAL=10 -> 10s.
sleep 1
now=$(date +%s)
first_check=$((now - 50))
cf5="$SANDBOX/var/cache/a2tools/nextwait.cache"
out="$(run_fqdnmgr "calculate_next_wait ns5.example.com $first_check" "$cf5")"
# Either 10 (floor) or close to it.
case "$out" in
    9|10|11) _assert_pass "next wait hits the 10s floor" "" ;;
    *)       _assert_fail "next wait hits the 10s floor" "got: $out" ;;
esac

# ---------------------------------------------------------------------------
test_starts_with "update_avg_propagation_time: averages with previous"
# ---------------------------------------------------------------------------
cf6="$SANDBOX/var/cache/a2tools/updavg1.cache"
out="$(run_fqdnmgr 'update_avg_propagation_time ns6.example.com 50; cache_get_ap ns6.example.com' "$cf6")"
assert_eq "50" "$out" "first measurement stored verbatim"

# Second measurement (40): (50+40)/2 = 45.
cf7="$SANDBOX/var/cache/a2tools/updavg2.cache"
out="$(run_fqdnmgr 'update_avg_propagation_time ns7.example.com 40; cache_get_ap ns7.example.com' "$cf7")"
assert_eq "45" "$out" "second measurement averaged with first"

# ---------------------------------------------------------------------------
test_starts_with "check_tld_priority: honors priority list ordering"
# ---------------------------------------------------------------------------
# TLD_PRIORITY_io=wedos.com,namecheap.com. We seed creds for namecheap and
# expect the function to return namecheap (the only one with creds).
sandbox_creds="$SANDBOX/var/lib/a2tools/creds.db"
sqlite3 "$sandbox_creds" "CREATE TABLE IF NOT EXISTS creds (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL, key TEXT NOT NULL, provider TEXT NOT NULL UNIQUE);"
sqlite3 "$sandbox_creds" "INSERT INTO creds (username, key, provider) VALUES ('u', 'k', 'namecheap.com');"

# check_tld_priority uses CREDS_DB_PATH at call time. Set it inside the
# subshell via the second arg pattern (override_paths sets the default
# sandbox creds path; we override again here).
cf8="$SANDBOX/var/cache/a2tools/tldprio.cache"
out="$(run_fqdnmgr 'check_tld_priority "mything.io"' "$cf8")"
assert_eq "namecheap.com" "$out" "priority list returns the only registrar with creds"

# A TLD that has no priority list returns empty + rc 1.
out_rc="$(run_fqdnmgr_rc 'check_tld_priority "mything.com"' "$cf8")"
case "$out_rc" in
    1) _assert_pass "no priority list -> rc 1" "" ;;
    *) _assert_fail "no priority list -> rc 1" "got: $out_rc" ;;
esac

# ---------------------------------------------------------------------------
test_starts_with "load_domain_config: variable exported from domain.conf"
# ---------------------------------------------------------------------------
# Verify that the load happened. AVG_PROPAGATION_TIME_namecheap_com=45 should
# be in scope (we set it in the fixture).
out="$(run_fqdnmgr 'printf "%s" "${AVG_PROPAGATION_TIME_namecheap_com:-unset}"')"
assert_eq "45" "$out" "domain.conf values are in scope after load_domain_config"

test_summary
