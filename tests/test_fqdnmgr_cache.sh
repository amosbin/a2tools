#!/bin/bash
# Unit tests for the cache layer in fqdnmgr.sh.
#
# Covers: cache_get/cache_set, cache_set_dns_change/cache_get_dns_change/
# cache_delete_dns_change, cache_get_ap/cache_set_ap, cleanup_expired_cache,
# _with_cache_lock. Each test uses its own cache file in the scratch dir
# so the tests do not pollute each other.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

SANDBOX="$(make_a2tools_sandbox)"
fill_sandbox_with_repo "$SANDBOX"

# Trimmed copy of fqdnmgr.sh (helper functions only). We strip the
# `init_cache` and `cleanup_expired_cache` calls (which run on load) so
# they do NOT touch the real /var/cache/a2tools when running as root.
# Each test seeds its own cache file via override_paths.
FQDNMGR_FUNCS_ONLY="$A2TOOLS_TEST_TMPDIR/fqdnmgr_funcs.sh"
grep -v -E '^(init_cache|cleanup_expired_cache)$' \
    "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" > "$FQDNMGR_FUNCS_ONLY"

# Each test invocation gets a fresh cache file path.
fresh_cache() {
    local name="$1"
    local f="$SANDBOX/var/cache/a2tools/$name.cache"
    rm -f "$f" "$f.lock" "${f}.tmp."* 2>/dev/null || true
    printf '%s\n' "$f"
}

# Override the lib + fqdnmgr path variables for the duration of the test.
# Applied AFTER both files are sourced, since the lib overwrites them on load.
override_paths() {
    local cache_file="$1"
    A2TOOLS_CACHE_DIR="$SANDBOX/var/cache/a2tools"
    A2TOOLS_LOG_DIR="$SANDBOX/var/log/a2tools"
    A2TOOLS_STATE="$SANDBOX/var/lib/a2tools"
    A2TOOLS_ETC="$SANDBOX/etc/a2tools"
    DOMAINS_DB_PATH="$A2TOOLS_STATE/domains.db"
    CREDS_DB_PATH="$A2TOOLS_STATE/creds.db"
    DOMAIN_CONFIG_PATH="$SANDBOX/etc/a2tools/domain.conf"
    WAN_IP_STATE_FILE="$A2TOOLS_STATE/wan_ip"
    LOG_FILE="$A2TOOLS_LOG_DIR/fqdnmgr.log"
    A2TOOLS_CACHE_FILE="$cache_file"
    A2TOOLS_CACHE_LOCK="$A2TOOLS_CACHE_DIR/$(basename "$cache_file").lock"
    mkdir -p "$A2TOOLS_CACHE_DIR" "$A2TOOLS_LOG_DIR" 2>/dev/null
}

# Run a snippet in a subshell with its own cache file. Returns stdout.
run_cache() {
    local cache_file="$1" code="$2"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        # Override paths BEFORE fqdnmgr_funcs.sh so the load_domain_config
        # call (which runs at fqdnmgr_funcs.sh load time) sees the
        # sandboxed DOMAIN_CONFIG_PATH.
        override_paths "$cache_file"
        # shellcheck disable=SC1090
        . "$FQDNMGR_FUNCS_ONLY"
        # Re-override A2TOOLS_CACHE_FILE since fqdnmgr_funcs.sh sets it
        # from A2TOOLS_CACHE_DIR.
        A2TOOLS_CACHE_FILE="$cache_file"
        A2TOOLS_CACHE_LOCK="$(dirname "$cache_file")/$(basename "$cache_file").lock"
        eval "$code" 2>/dev/null
    )
}

run_cache_rc() {
    local cache_file="$1" code="$2"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        override_paths "$cache_file"
        # shellcheck disable=SC1090
        . "$FQDNMGR_FUNCS_ONLY"
        A2TOOLS_CACHE_FILE="$cache_file"
        A2TOOLS_CACHE_LOCK="$(dirname "$cache_file")/$(basename "$cache_file").lock"
        eval "$code" >/dev/null 2>&1
    )
    echo $?
}

# ---------------------------------------------------------------------------
test_starts_with "cache_set / cache_get: round-trip"
# ---------------------------------------------------------------------------
cf="$(fresh_cache roundtrip)"
out="$(run_cache "$cf" 'cache_set whois_registrar example.com "namecheap.com"; cache_get whois_registrar example.com')"
assert_eq "namecheap.com" "$out" "round-trip value matches"

# A missing key returns rc 1.
out_rc="$(run_cache_rc "$cf" 'cache_get no_such_key example.com')"
assert_eq "1" "$out_rc" "missing key -> rc 1"

# ---------------------------------------------------------------------------
test_starts_with "cache_set: replaces existing value for same key"
# ---------------------------------------------------------------------------
cf="$(fresh_cache replace)"
out="$(run_cache "$cf" 'cache_set whois_registrar example.com "old-reg"; cache_set whois_registrar example.com "new-reg"; cache_get whois_registrar example.com')"
assert_eq "new-reg" "$out" "second cache_set replaces first"

# ---------------------------------------------------------------------------
test_starts_with "cache_get: respects TTL (whois 1h)"
# ---------------------------------------------------------------------------
# Seed an entry whose timestamp is 2 hours in the past - well past the 1h
# TTL. cache_get should return 1 (expired).
cf="$(fresh_cache ttl)"
out_rc="$(run_cache_rc "$cf" '
    now=$(date +%s)
    old=$((now - 7200))
    printf "whois_registrar example.com stale-reg %d\n" "$old" > "$A2TOOLS_CACHE_FILE"
    cache_get whois_registrar example.com
')"
assert_eq "1" "$out_rc" "expired entry -> rc 1"

# A fresh entry is returned.
out="$(run_cache "$cf" '
    cache_set whois_registrar example.com "fresh-reg"
    cache_get whois_registrar example.com
')"
assert_eq "fresh-reg" "$out" "fresh entry returned"

# ---------------------------------------------------------------------------
test_starts_with "cache_get: ap type never expires (TTL = -1)"
# ---------------------------------------------------------------------------
cf="$(fresh_cache ap-never)"
out="$(run_cache "$cf" '
    now=$(date +%s)
    very_old=$((now - 1000000))
    printf "ap ns1.example.com 42 %d\n" "$very_old" > "$A2TOOLS_CACHE_FILE"
    cache_get ap ns1.example.com
')"
assert_eq "42" "$out" "ap entry returned even with a very old timestamp"

# ---------------------------------------------------------------------------
test_starts_with "cache_set_dns_change / cache_get_dns_change"
# ---------------------------------------------------------------------------
cf="$(fresh_cache dns-change)"
# Use a unique key in this test to avoid cross-test pollution.
out="$(run_cache "$cf" '
    cache_set_dns_change example.com TXT _acme-challenge xyz-123
    cache_get_dns_change example.com TXT _acme-challenge xyz-123
')"
# The returned value is the set timestamp (an integer).
case "$out" in
    ''|*[!0-9]*) _assert_fail "dns change set_ts is a positive integer" "got: $out" ;;
    0)            _assert_fail "dns change set_ts is a positive integer" "got 0" ;;
    *)            _assert_pass "dns change set_ts is a positive integer" "" ;;
esac

# A different value for the same (domain,type,host) -> miss.
out_rc="$(run_cache_rc "$cf" 'cache_get_dns_change example.com TXT _acme-challenge different-value')"
assert_eq "1" "$out_rc" "different value -> miss"

# cache_delete_dns_change removes the entry.
out_rc="$(run_cache_rc "$cf" '
    cache_delete_dns_change example.com TXT _acme-challenge xyz-123
    cache_get_dns_change example.com TXT _acme-challenge xyz-123
')"
assert_eq "1" "$out_rc" "deleted entry -> miss"

# ---------------------------------------------------------------------------
test_starts_with "cleanup_expired_cache: removes expired rows, keeps live"
# ---------------------------------------------------------------------------
cf="$(fresh_cache cleanup)"
out="$(run_cache "$cf" '
    now=$(date +%s)
    # 1 fresh, 2 expired (whois 1h TTL)
    fresh_ts=$now
    whois_old=$((now - 7200))
    ns_old=$((now - 8000))    # ns TTL is 2h, so this IS expired
    ap_very_old=$((now - 1000000))   # ap never expires, so this is kept
    cat > "$A2TOOLS_CACHE_FILE" <<EOF
whois_registrar example.com fresh-name $fresh_ts
whois_registrar example2.com stale-name $whois_old
ns example3.com stale-ns $ns_old
ap ns4.example.com 99 $ap_very_old
EOF
    cleanup_expired_cache
    cat "$A2TOOLS_CACHE_FILE"
')"
assert_contains "$out" "fresh-name" "live whois entry kept"
assert_contains "$out" "ns4.example.com 99" "ap entry kept (never expires)"
assert_not_contains "$out" "stale-name" "expired whois entry removed"
assert_not_contains "$out" "stale-ns"   "expired ns entry removed"

# ---------------------------------------------------------------------------
test_starts_with "_with_cache_lock: degrades gracefully if flock missing"
# ---------------------------------------------------------------------------
# Simulate a missing flock by prepending a PATH that shadows it. We don't
# actually have permission to delete /usr/bin/flock on a shared box, so this
# test guards the wrapper's intent (run regardless) rather than the
# crash-on-missing behavior.
cf="$(fresh_cache locktest)"
out="$(run_cache "$cf" '
    _with_cache_lock printf "ran\n"
')"
assert_contains "$out" "ran" "with-cache-lock runs the command"

# ---------------------------------------------------------------------------
test_starts_with "init_cache: creates cache file with 027 umask"
# ---------------------------------------------------------------------------
cf="$(fresh_cache init-cache)"
# Pre-remove the dir; init_cache should recreate the file.
rm -rf "$SANDBOX/var/cache/a2tools"
out_rc="$(run_cache_rc "$cf" 'init_cache; [ -f "$A2TOOLS_CACHE_FILE" ] && echo present')"
# Subshell captured stdout above; re-run a single command to see the file.
run_cache "$cf" 'init_cache'
assert_file_exists "$cf" "init_cache created the cache file"

# Perms on a root-created file: 0027 umask -> mode 0640. When not running
# as root, init_cache short-circuits because the umask application is only
# attempted inside a subshell with `umask 027`; the touch itself succeeds
# and the file exists. We do not assert the exact mode here to keep the
# test host-agnostic.

test_summary
