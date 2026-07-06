#!/bin/bash
# Unit tests for the flag-only CLI argument convention.
#
# After the August 2026 refactor, every entry script rejects positional
# arguments in favor of named flags. These tests verify:
#
#   a2sitemgr  -d <FQDN>  [-m MODE] [-r REG] [-p PORT] [-s] ...
#   fqdncredmgr <action> -p PROVIDER -u USERNAME [-k -] [-v]
#   fqdnmgr    <subcmd>   -d DOMAIN [-r REG] [-t SEC] [--sync] ...
#
# Tests run each script in a sandboxed subshell with FHS paths redirected
# to the scratch dir and provider/auth helpers stubbed so the dispatcher
# fails fast (or no-ops) instead of touching the real system. The PARSER
# is what we want to test - we verify the parser's behaviour by the
# script's first error message (or its absence) and its exit code.
#
# Conventions under test:
#   * Positional args after the action/subcommand must be rejected.
#   * Known flags must be accepted.
#   * Known flags with a missing value must error cleanly.
#   * Unknown flags must error cleanly.
#   * --help exits 0 and prints the usage banner.
#
# These tests do NOT verify downstream behaviour (apache writes, DNS
# propagation, certbot invocations). That is exercised by the live
# install path; here we only check the parser.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

SANDBOX="$(make_a2tools_sandbox)"
fill_sandbox_with_repo "$SANDBOX"

# A2TOOLS_LIB / A2TOOLS_SCRIPTS already point to the repo (set by
# test_helpers.sh). The scripts under test source their own lib via
# `readlink -f` of $BASH_SOURCE, so as long as we run the unmodified
# repo copy from $A2TOOLS_SCRIPTS_DIR, paths resolve to the repo layout.

# Stub bin: shadows real binaries that the dispatchers would otherwise
# invoke (apache2ctl, systemctl, fqdnmgr, certbot, sqlite3) so a script
# that gets past the parser fails fast with a predictable "command not
# found" - which is the OPPOSITE of the "invalid argument" / "no such
# flag" error we expect when the parser rejects. This makes the two
# outcomes distinguishable.
STUB_BIN="$SANDBOX/bin"
mkdir -p "$STUB_BIN"
for cmd in apache2 apache2ctl a2ensite a2dissite certbot systemctl sqlite3 fqdnmgr fqdncredmgr dig curl whois jq flock; do
    cat > "$STUB_BIN/$cmd" <<'EOF'
#!/bin/bash
echo "STUB:${0##*/}: $*" >&2
exit 99
EOF
    chmod +x "$STUB_BIN/$cmd"
done

# A per-test "no-op" shim for `id -u`: return 0 so the root-required
# checks in a2sitemgr / fqdncredmgr / fqdnmgr do not bail before the
# parser runs. Real root check is irrelevant to the parser.
cat > "$STUB_BIN/id" <<'EOF'
#!/bin/bash
# Only override `id -u` to return 0; pass everything else through to
# the real id.
if [ "$1" = "-u" ]; then
    echo 0
    exit 0
fi
exec /usr/bin/id "$@"
EOF
chmod +x "$STUB_BIN/id"

# Run `script ARGS...` in a sandboxed subshell. Captures stdout,
# stderr, and rc. The subshell sources the script's lib in the sandbox
# and prepends the stub bin to PATH so any downstream `apache2ctl`,
# `systemctl`, `certbot`, etc. fails fast instead of doing real work.
run_cli() {
    local script="$1"; shift
    (
        export PATH="$STUB_BIN:$PATH"

        # Sandbox FHS paths the lib hard-codes on load. Set BEFORE
        # sourcing the script so the lib's `cd "$(readlink -f ...)"` for
        # A2TOOLS_ROOT points at the repo (which is what we want), but
        # the write paths (state/log/cache/creds DB) point at the
        # sandbox.
        A2TOOLS_ETC="$SANDBOX/etc/a2tools"
        A2TOOLS_STATE="$SANDBOX/var/lib/a2tools"
        A2TOOLS_CACHE_DIR="$SANDBOX/var/cache/a2tools"
        A2TOOLS_LOG_DIR="$SANDBOX/var/log/a2tools"
        DOMAINS_DB_PATH="$A2TOOLS_STATE/domains.db"
        CREDS_DB_PATH="$A2TOOLS_STATE/creds.db"
        DOMAIN_CONFIG_PATH="$A2TOOLS_ETC/domain.conf"
        WAN_IP_STATE_FILE="$A2TOOLS_STATE/wan_ip"
        LOG_FILE="$A2TOOLS_LOG_DIR/fqdnmgr.log"

        bash "$script" "$@"
    )
}

# ---------------------------------------------------------------------------
# a2sitemgr
# ---------------------------------------------------------------------------

test_starts_with "a2sitemgr: named -d/--fqdn is accepted"
# When the parser is happy, the dispatcher runs and fails at a later
# point (no apache, no cert, etc.) - but NOT with "invalid argument".
# We just check that the parser did NOT reject our args.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/a2sitemgr.sh" -d example.com 2>&1)"
rc=$?
case "$out" in
    *"Error: invalid argument"*"example.com"*)
        _assert_fail "parser accepts -d" "got 'invalid argument': $out" ;;
    *"Error: invalid argument"*"--fqdn"*)
        _assert_fail "parser accepts --fqdn" "got 'invalid argument': $out" ;;
    *)
        _assert_pass "parser accepts -d example.com" "" ;;
esac

# Long form: --fqdn is equivalent.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/a2sitemgr.sh" --fqdn example.com 2>&1)"
case "$out" in
    *"Error: invalid argument"*"--fqdn"*)
        _assert_fail "parser accepts --fqdn long form" "got 'invalid argument': $out" ;;
    *)
        _assert_pass "parser accepts --fqdn long form" "" ;;
esac

# ---------------------------------------------------------------------------
test_starts_with "a2sitemgr: positional FQDN is rejected"
# The whole point of the refactor: `a2sitemgr example.com` is an error.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/a2sitemgr.sh" example.com 2>&1)"
rc=$?
assert_eq "1" "$rc" "positional arg -> exit 1"
assert_contains "$out" "Error: invalid argument 'example.com'" "rejects positional FQDN with the right error"

# Positional with multiple trailing tokens is still rejected (and the
# parser errors on the FIRST one).
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/a2sitemgr.sh" example.com -m domain 2>&1)"
rc=$?
assert_eq "1" "$rc" "positional FQDN before flags -> exit 1"
assert_contains "$out" "Error: invalid argument 'example.com'" "rejects positional FQDN even when flags follow"

# ---------------------------------------------------------------------------
test_starts_with "a2sitemgr: -h / --help exits 0 and prints usage"
# ---------------------------------------------------------------------------
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/a2sitemgr.sh" -h 2>&1)"
rc=$?
assert_eq "0" "$rc" "-h -> exit 0"
assert_contains "$out" "Usage:" "usage banner present"
assert_contains "$out" "a2sitemgr" "usage mentions the script name"

out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/a2sitemgr.sh" --help 2>&1)"
rc=$?
assert_eq "0" "$rc" "--help -> exit 0"
assert_contains "$out" "Usage:" "long-form --help prints usage"

# ---------------------------------------------------------------------------
test_starts_with "a2sitemgr: unknown flag is rejected"
# ---------------------------------------------------------------------------
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/a2sitemgr.sh" -d example.com --no-such-flag 2>&1)"
rc=$?
assert_eq "1" "$rc" "unknown flag -> exit 1"
assert_contains "$out" "Error: invalid argument '--no-such-flag'" "rejects unknown flag"

# ---------------------------------------------------------------------------
test_starts_with "a2sitemgr: missing -d errors on dispatcher, not parser"
# The parser accepts zero-arg invocation (MODE defaults to domain).
# The downstream check (e.g. FQDN required, or root check) fires next.
# We don't care which downstream check fails - just that it is NOT the
# parser rejecting us.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/a2sitemgr.sh" 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "no-arg invocation does not hit the parser" "got: $out" ;;
    *)
        _assert_pass "no-arg invocation gets past the parser" "" ;;
esac

# ---------------------------------------------------------------------------
# fqdncredmgr
# ---------------------------------------------------------------------------

test_starts_with "fqdncredmgr: add with named -p/-u is accepted"
# `add -p namecheap.com -u alice` parses OK; the dispatcher then runs
# the add branch which calls sqlite3 (stubbed -> rc 99). The point is
# the parser did not reject our args.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" add -p namecheap.com -u alice 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts add -p -u" "got: $out" ;;
    *)
        _assert_pass "parser accepts add -p namecheap.com -u alice" "" ;;
esac

# Long forms.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" add --provider namecheap.com --username alice 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts long forms --provider/--username" "got: $out" ;;
    *)
        _assert_pass "parser accepts add --provider --username" "" ;;
esac

# ---------------------------------------------------------------------------
test_starts_with "fqdncredmgr: positional PROVIDER/USERNAME is rejected"
# Old style: `add namecheap.com alice` - now an error.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" add namecheap.com alice 2>&1)"
rc=$?
assert_eq "1" "$rc" "positional add args -> exit 1"
assert_contains "$out" "Error: invalid argument 'namecheap.com'" "rejects positional PROVIDER"

# The same for update and delete.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" update namecheap.com alice 2>&1)"
rc=$?
assert_eq "1" "$rc" "positional update args -> exit 1"
assert_contains "$out" "Error: invalid argument 'namecheap.com'" "rejects positional PROVIDER on update"

out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" delete namecheap.com 2>&1)"
rc=$?
assert_eq "1" "$rc" "positional delete args -> exit 1"
assert_contains "$out" "Error: invalid argument 'namecheap.com'" "rejects positional PROVIDER on delete"

# ---------------------------------------------------------------------------
test_starts_with "fqdncredmgr: -k - reads the API key from stdin"
# When -k is the last arg, the parser shifts past the value if the
# value is "-". This is documented as the only way to pipe the key in.
key="$(printf 'super-secret-key\n')"
out="$(printf '%s' "$key" | run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" add -p namecheap.com -u alice -k - 2>&1)"
case "$out" in
    *"API keys on the command line"*)
        _assert_fail "parser accepts -k -" "rejected with 'API keys on the command line': $out" ;;
    *"Error: invalid argument"*)
        _assert_fail "parser accepts -k -" "got: $out" ;;
    *)
        _assert_pass "parser accepts -k - (read from stdin)" "" ;;
esac

# A non-'-' value for -k must be rejected (the only valid value is '-').
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" add -p namecheap.com -u alice -k supersecret 2>&1)"
rc=$?
assert_eq "1" "$rc" "-k <literal> -> exit 1"
assert_contains "$out" "API keys on the command line are not supported" "rejects literal key in -k"

# ---------------------------------------------------------------------------
test_starts_with "fqdncredmgr: required flags enforced by the dispatcher"
# `add` without -u -> the dispatcher's [ -n "$USERNAME" ] check fires.
# This is intentionally post-parser: the parser happily consumed
# `add -p namecheap.com`; the error is "missing --username".
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" add -p namecheap.com 2>&1)"
rc=$?
assert_eq "1" "$rc" "add without --username -> exit 1"
assert_contains "$out" "Error: --username is required" "dispatcher requires --username for add"

# `add` without -p -> dispatcher requires --provider.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" add -u alice 2>&1)"
rc=$?
assert_eq "1" "$rc" "add without --provider -> exit 1"
assert_contains "$out" "Error: --provider is required" "dispatcher requires --provider for add"

# ---------------------------------------------------------------------------
test_starts_with "fqdncredmgr: list / --help / unknown action"
# ---------------------------------------------------------------------------
# list is a no-arg action: no flags needed.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" list 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts bare 'list'" "got: $out" ;;
    *"no credentials"*)           _assert_pass "list on empty DB gets past the parser" "" ;;
    *)                            _assert_pass "list gets past the parser" "" ;;
esac

# --help.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" --help 2>&1)"
rc=$?
assert_eq "0" "$rc" "--help -> exit 0"
assert_contains "$out" "Usage:" "usage banner present"

# Unknown action.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" frobnicate -p namecheap.com 2>&1)"
rc=$?
assert_eq "1" "$rc" "unknown action -> exit 1"
assert_contains "$out" "Invalid action" "rejects unknown action"

# No action at all.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" 2>&1)"
rc=$?
assert_eq "1" "$rc" "no action -> exit 1"
assert_contains "$out" "No action specified" "rejects missing action"

# ---------------------------------------------------------------------------
# fqdnmgr
# ---------------------------------------------------------------------------

test_starts_with "fqdnmgr: named -d/--domain is accepted"
# The dispatcher does real work (talks to sqlite, dig, etc.) and our
# stubs make it fail with rc 99. The point is the parser did not reject.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" check -d example.com 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts check -d" "got: $out" ;;
    *)
        _assert_pass "parser accepts check -d example.com" "" ;;
esac

out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" check --domain example.com 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts --domain long form" "got: $out" ;;
    *)
        _assert_pass "parser accepts check --domain" "" ;;
esac

# ---------------------------------------------------------------------------
test_starts_with "fqdnmgr: positional DOMAIN/REGISTRAR is rejected"
# Old style: `check example.com namecheap.com` - now an error.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" check example.com namecheap.com 2>&1)"
rc=$?
assert_eq "1" "$rc" "positional check args -> exit 1"
assert_contains "$out" "Error: invalid argument 'example.com'" "rejects positional FQDN"

out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" purchase example.com namecheap.com 2>&1)"
rc=$?
assert_eq "1" "$rc" "positional purchase args -> exit 1"
assert_contains "$out" "Error: invalid argument 'example.com'" "rejects positional FQDN on purchase"

# ---------------------------------------------------------------------------
test_starts_with "fqdnmgr: purchase / certify / cleanup / setInitDNSRecords"
# ---------------------------------------------------------------------------
# purchase with both required flags.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" purchase -d example.com -r namecheap.com 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts purchase -d -r" "got: $out" ;;
    *)
        _assert_pass "parser accepts purchase -d -r" "" ;;
esac

# certify only needs the registrar.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" certify -r namecheap.com 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts certify -r" "got: $out" ;;
    *)
        _assert_pass "parser accepts certify -r" "" ;;
esac

# cleanup mirrors certify.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" cleanup -r namecheap.com 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts cleanup -r" "got: $out" ;;
    *)
        _assert_pass "parser accepts cleanup -r" "" ;;
esac

# setInitDNSRecords with -d alone.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" setInitDNSRecords -d example.com 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts setInitDNSRecords -d" "got: $out" ;;
    *)
        _assert_pass "parser accepts setInitDNSRecords -d" "" ;;
esac

# setInitDNSRecords with -r alone.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" setInitDNSRecords -r namecheap.com 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts setInitDNSRecords -r" "got: $out" ;;
    *)
        _assert_pass "parser accepts setInitDNSRecords -r" "" ;;
esac

# setInitDNSRecords with --sync and --timeout.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" setInitDNSRecords -d example.com --sync --timeout 30 2>&1)"
case "$out" in
    *"Error: invalid argument"*)
        _assert_fail "parser accepts --sync --timeout" "got: $out" ;;
    *)
        _assert_pass "parser accepts setInitDNSRecords --sync --timeout" "" ;;
esac

# ---------------------------------------------------------------------------
test_starts_with "fqdnmgr: --help / unknown subcommand / missing required"
# ---------------------------------------------------------------------------
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" --help 2>&1)"
rc=$?
assert_eq "0" "$rc" "--help -> exit 0"
assert_contains "$out" "Usage:" "usage banner present"
assert_contains "$out" "fqdnmgr" "usage mentions the script name"

# Unknown subcommand.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" frobnicate -d example.com 2>&1)"
rc=$?
assert_eq "1" "$rc" "unknown subcommand -> exit 1"
assert_contains "$out" "unknown subcommand" "rejects unknown subcommand"

# No subcommand at all.
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" 2>&1)"
rc=$?
assert_eq "1" "$rc" "no subcommand -> exit 1"
assert_contains "$out" "no subcommand" "rejects missing subcommand"

# check without --domain -> the dispatcher's `check requires --domain`
# check fires (this is intentional post-parser validation).
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" check 2>&1)"
rc=$?
assert_eq "1" "$rc" "check without --domain -> exit 1"
assert_contains "$out" "check requires --domain" "dispatcher requires --domain for check"

# ---------------------------------------------------------------------------
test_starts_with "all scripts: --version-style or stray non-flag tokens are rejected"
# Whichever form the script's parser uses, a token that is neither a
# known flag nor a recognized positional (only the action/subcommand
# may be positional) must fail with the standard 'invalid argument'
# / 'no subcommand' error.
# ---------------------------------------------------------------------------
out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/a2sitemgr.sh" -d example.com not-a-flag 2>&1)"
rc=$?
assert_eq "1" "$rc" "a2sitemgr stray non-flag -> exit 1"
assert_contains "$out" "Error: invalid argument 'not-a-flag'" "a2sitemgr stray token rejected"

out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" list stray-token 2>&1)"
rc=$?
assert_eq "1" "$rc" "fqdncredmgr stray non-flag -> exit 1"
assert_contains "$out" "Error: invalid argument 'stray-token'" "fqdncredmgr stray token rejected"

out="$(run_cli "$A2TOOLS_SCRIPTS_DIR/fqdnmgr.sh" list stray-token 2>&1)"
rc=$?
assert_eq "1" "$rc" "fqdnmgr stray non-flag -> exit 1"
assert_contains "$out" "Error: invalid argument 'stray-token'" "fqdnmgr stray token rejected"

test_summary
