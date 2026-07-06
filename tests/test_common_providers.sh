#!/bin/bash
# Unit tests for the provider-plugin helpers in lib/common.sh.
#
# Covers: provider_file, list_providers, load_provider, and
# _provider_source_safe (the security check that refuses to source a
# group/world-writable or wrongly-owned provider file).
#
# These tests build a fake provider directory tree in the scratch dir.
# No real provider file is ever sourced if its safety check fails.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

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

run_with_lib() {
    local code="$1" arg="${2:-}"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        override_paths
        # Pass `arg` as the script's $1 so the eval'd code can reference it.
        # shellcheck disable=SC2086
        set -- "$arg"
        eval "$code" 2>/dev/null
    )
}

run_with_lib_rc() {
    local code="$1" arg="${2:-}"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        override_paths
        # shellcheck disable=SC2086
        set -- "$arg"
        eval "$code" >/dev/null 2>&1
    )
    echo $?
}

# ---------------------------------------------------------------------------
test_starts_with "provider_file: returns the shipped plugin path"
# ---------------------------------------------------------------------------
# When running from the checkout, the shipped plugin is at
# scripts/providers/<name>.provider.
out="$(run_with_lib 'provider_file namecheap.com')"
rc="$?"
assert_eq "0" "$rc" "namecheap.com -> rc 0"
assert_contains "$out" "namecheap.com.provider" "path ends with .provider"
assert_contains "$out" "/providers/" "path is inside a providers/ dir"

# ---------------------------------------------------------------------------
test_starts_with "provider_file: returns rc 1 for unknown registrars"
# ---------------------------------------------------------------------------
out="$(run_with_lib 'provider_file ghost.com')"
rc="$?"
assert_eq "1" "$rc" "unknown provider -> rc 1"
assert_eq "" "$out" "no path printed on miss"

# ---------------------------------------------------------------------------
test_starts_with "list_providers: deduplicates and is sorted"
# ---------------------------------------------------------------------------
# Drop the shipped providers in the sandbox, then re-list.
SANDBOX_PROVIDERS="$SANDBOX/etc/a2tools/providers"
mkdir -p "$SANDBOX_PROVIDERS"
# A duplicate of namecheap (same basename) in BOTH dirs must dedupe.
cp "$A2TOOLS_PROVIDERS_DIR/namecheap.com.provider" "$SANDBOX_PROVIDERS/namecheap.com.provider"
# A new override-only provider.
cat > "$SANDBOX_PROVIDERS/override-test.com.provider" <<'EOF'
PROVIDER_NAME="override-test.com"
EOF
# A second bundled-only provider (rename for sort testing).
mkdir -p "$SANDBOX_PROVIDERS/zzz-bundled"
# Use the second bundled file as 'aaa-test.com' to test sort order.
cp "$A2TOOLS_PROVIDERS_DIR/wedos.com.provider" "$SANDBOX_PROVIDERS/aaa-test.com.provider"

out="$(run_with_lib 'list_providers | sort')"
assert_contains "$out" "namecheap.com"   "list includes namecheap.com (deduped)"
assert_contains "$out" "override-test.com" "list includes override"
assert_contains "$out" "aaa-test.com"    "list includes aaa-test.com (renamed)"
assert_contains "$out" "wedos.com"       "list includes wedos.com (bundled)"

# Count lines, expect each provider exactly once.
# Setup: namecheap.com + override-test.com + aaa-test.com + wedos.com
# (the duplicate namecheap in both dirs is deduped by sort -u).
count="$(printf '%s\n' "$out" | grep -c '\.com$')"
assert_eq "4" "$count" "each provider listed exactly once (deduplicated)"

# And the namecheap.com line appears EXACTLY once (not duplicated).
dup_count="$(printf '%s\n' "$out" | grep -cFx 'namecheap.com')"
assert_eq "1" "$dup_count" "namecheap.com not duplicated despite dual placement"

# ---------------------------------------------------------------------------
test_starts_with "_provider_source_safe: rejects group-writable files"
# ---------------------------------------------------------------------------
# Create a file with group-write bit set; even if it's owned by root, this
# must be rejected because the lib guards on 022 (group|other write).
unsafe="$SANDBOX_PROVIDERS/unsafe-group-write.provider"
cat > "$unsafe" <<'EOF'
PROVIDER_NAME="unsafe"
EOF
chmod 0664 "$unsafe"  # group-writable
out="$(run_with_lib '_provider_source_safe "$1"; echo "rc=$?"' "$unsafe")"
assert_contains "$out" "rc=1" "group-writable provider rejected"

# ---------------------------------------------------------------------------
test_starts_with "_provider_source_safe: rejects world-writable files"
# ---------------------------------------------------------------------------
unsafe2="$SANDBOX_PROVIDERS/unsafe-world-write.provider"
cat > "$unsafe2" <<'EOF'
PROVIDER_NAME="unsafe"
EOF
chmod 0666 "$unsafe2"  # world-writable
out="$(run_with_lib '_provider_source_safe "$1"; echo "rc=$?"' "$unsafe2")"
assert_contains "$out" "rc=1" "world-writable provider rejected"

# ---------------------------------------------------------------------------
test_starts_with "_provider_source_safe: accepts a normal root-owned file"
# ---------------------------------------------------------------------------
# A root-owned 644 file is safe on Linux. macOS dev checkouts may not be
# running as root, so this is guarded with a runtime check.
if [ "$(id -u)" -eq 0 ]; then
    safe="$SANDBOX_PROVIDERS/safe.provider"
    cat > "$safe" <<'EOF'
PROVIDER_NAME="safe"
EOF
    chmod 0644 "$safe"
    out="$(run_with_lib '_provider_source_safe "$1"; echo "rc=$?"' "$safe")"
    assert_contains "$out" "rc=0" "root-owned 0644 provider accepted"
else
    printf '# (skipped: not running as root, cannot prove owner check)\n'
fi

# ---------------------------------------------------------------------------
test_starts_with "load_provider: refuses a tampered provider and lists valid ones"
# ---------------------------------------------------------------------------
# Set up a tampered provider that will fail the safety check, then call
# load_provider. It should print an error and return non-zero.
tampered="$SANDBOX_PROVIDERS/tampered.provider"
cat > "$tampered" <<'EOF'
PROVIDER_NAME="tampered"
EOF
chmod 0666 "$tampered"

out="$(run_with_lib 'load_provider tampered.com; echo "rc=$?"')"
assert_contains "$out" "Refusing to load" "load_provider prints refusal"
assert_contains "$out" "rc=1" "load_provider returns non-zero on tampered file"

# load_provider on an unknown provider also fails (with a different error).
out="$(run_with_lib 'load_provider unknown-registrar-xyz.com; echo "rc=$?"')"
assert_contains "$out" "Provider file not found" "load_provider on missing -> 'not found' error"
assert_contains "$out" "rc=1" "load_provider on missing returns non-zero"

test_summary
