# shellcheck shell=bash
# Shared test helpers for the a2tools unit test suite.
#
# Sourced by every test_*.sh file. Provides:
#   - A bash 3.2 + 4+ compatible assertion library (assert_eq, assert_neq,
#     assert_true, assert_false, assert_rc, assert_contains, assert_file_exists)
#   - A per-test scratch dir (auto-cleaned on EXIT) rooted at $A2TOOLS_TEST_TMPDIR
#   - A counter-based TAP-style summary
#   - A `run_in_bash_subshell` helper for tests that need to source a script
#     in isolation (since the entry scripts mutate global state on load).
#
# Test files look like:
#
#   #!/bin/bash
#   . "$(dirname "$0")/lib/test_helpers.sh"
#
#   test_starts_with "is_valid_fqdn accepts a normal FQDN" ...
#
#   test_summary
#
# `test_summary` exits 0 if every assertion passed, 1 otherwise.

# --- Test root discovery ---------------------------------------------------
# Path to the a2tools source tree (one level up from this tests/ directory).
# Tests use it to source lib/common.sh and other files.
A2TOOLS_REPO_ROOT="${A2TOOLS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
A2TOOLS_SCRIPTS_DIR="$A2TOOLS_REPO_ROOT/scripts"
A2TOOLS_PROVIDERS_DIR="$A2TOOLS_SCRIPTS_DIR/providers"
A2TOOLS_SHARE_DIR="$A2TOOLS_SCRIPTS_DIR/share"
A2TOOLS_LIB_DIR="$A2TOOLS_SCRIPTS_DIR/lib"

# --- Counters --------------------------------------------------------------
_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0
_CURRENT_TEST_NAME=""

# --- Scratch space ---------------------------------------------------------
# Each test run gets a unique tmp dir under $TMPDIR (or /tmp). All scratch
# files (fake databases, mock /var/lib, etc.) go here and are removed on EXIT.
A2TOOLS_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/a2tools-test-XXXXXX")"
if [ ! -d "$A2TOOLS_TEST_TMPDIR" ]; then
    echo "FATAL: could not create scratch dir" >&2
    exit 2
fi
A2TOOLS_TEST_TMPDIR="$(cd "$A2TOOLS_TEST_TMPDIR" && pwd)"  # canonical absolute path

_cleanup_scratch() {
    [ -n "$A2TOOLS_TEST_TMPDIR" ] || return 0
    [ -d "$A2TOOLS_TEST_TMPDIR" ] || return 0
    rm -rf "$A2TOOLS_TEST_TMPDIR" 2>/dev/null || true
}
trap _cleanup_scratch EXIT

# --- TAP-style output -----------------------------------------------------
_tap_ok()    { printf 'ok %d - %s\n' "$1" "$2"; }
_tap_not_ok(){ printf 'not ok %d - %s\n' "$1" "$2"; }

# --- Low-level assertion helpers ------------------------------------------
# Each helper increments _TESTS_RUN, prints TAP, updates pass/fail counters.
# Tests do NOT exit on failure - the run continues so a single broken
# assertion doesn't mask downstream bugs.

_assert_pass() {
    local name="$1" desc="$2"
    _TESTS_RUN=$((_TESTS_RUN + 1))
    _TESTS_PASSED=$((_TESTS_PASSED + 1))
    _tap_ok "$_TESTS_RUN" "$name"
}

_assert_fail() {
    local name="$1" detail="$2"
    _TESTS_RUN=$((_TESTS_RUN + 1))
    _TESTS_FAILED=$((_TESTS_FAILED + 1))
    _tap_not_ok "$_TESTS_RUN" "$name"
    if [ -n "$detail" ]; then
        printf '  ---\n  %s\n  ...\n' "$detail" >&2
    fi
}

# Public assertion API -------------------------------------------------------

# assert_eq EXPECTED ACTUAL [MESSAGE]
assert_eq() {
    local expected="$1" actual="$2" message="${3:-assert_eq}"
    if [ "$expected" = "$actual" ]; then
        _assert_pass "$message" ""
    else
        _assert_fail "$message" "expected: $(printf %q "$expected") | actual: $(printf %q "$actual")"
    fi
}

# assert_neq NOT_EXPECTED ACTUAL [MESSAGE]
assert_neq() {
    local not_expected="$1" actual="$2" message="${3:-assert_neq}"
    if [ "$not_expected" != "$actual" ]; then
        _assert_pass "$message" ""
    else
        _assert_fail "$message" "value should differ from $(printf %q "$not_expected") but does not"
    fi
}

# assert_true VALUE [MESSAGE]  - true means exit 0 / non-empty / "true"
assert_true() {
    local value="$1" message="${2:-assert_true}"
    if [ "$value" = "true" ] || [ "$value" = "0" ]; then
        _assert_pass "$message" ""
    else
        _assert_fail "$message" "expected truthy, got $(printf %q "$value")"
    fi
}

# assert_false VALUE [MESSAGE]
assert_false() {
    local value="$1" message="${2:-assert_false}"
    if [ "$value" = "false" ] || [ "$value" = "1" ] || [ -z "$value" ]; then
        _assert_pass "$message" ""
    else
        _assert_fail "$message" "expected falsy, got $(printf %q "$value")"
    fi
}

# assert_rc EXPECTED_RC ACTUAL_RC [MESSAGE]
assert_rc() {
    local expected="$1" actual="$2" message="${3:-assert_rc}"
    if [ "$expected" = "$actual" ]; then
        _assert_pass "$message" ""
    else
        _assert_fail "$message" "expected rc $expected, got rc $actual"
    fi
}

# assert_contains HAYSTACK NEEDLE [MESSAGE]
assert_contains() {
    local haystack="$1" needle="$2" message="${3:-assert_contains}"
    case "$haystack" in
        *"$needle"*)
            _assert_pass "$message" ""
            ;;
        *)
            _assert_fail "$message" "needle $(printf %q "$needle") not found in $(printf %q "$haystack")"
            ;;
    esac
}

# assert_not_contains HAYSTACK NEEDLE [MESSAGE]
assert_not_contains() {
    local haystack="$1" needle="$2" message="${3:-assert_not_contains}"
    case "$haystack" in
        *"$needle"*)
            _assert_fail "$message" "needle $(printf %q "$needle") unexpectedly present"
            ;;
        *)
            _assert_pass "$message" ""
            ;;
    esac
}

# assert_file_exists PATH [MESSAGE]
assert_file_exists() {
    local path="$1" message="${2:-assert_file_exists: $1}"
    if [ -f "$path" ]; then
        _assert_pass "$message" ""
    else
        _assert_fail "$message" "expected file to exist: $path"
    fi
}

# assert_file_missing PATH [MESSAGE]
assert_file_missing() {
    local path="$1" message="${2:-assert_file_missing: $1}"
    if [ ! -e "$path" ]; then
        _assert_pass "$message" ""
    else
        _assert_fail "$message" "expected path to be absent: $path"
    fi
}

# assert_dir_exists PATH [MESSAGE]
assert_dir_exists() {
    local path="$1" message="${2:-assert_dir_exists: $1}"
    if [ -d "$path" ]; then
        _assert_pass "$message" ""
    else
        _assert_fail "$message" "expected dir to exist: $path"
    fi
}

# assert_matches VALUE REGEX [MESSAGE]  - bash regex =~ match
assert_matches() {
    local value="$1" regex="$2" message="${3:-assert_matches}"
    if [[ "$value" =~ $regex ]]; then
        _assert_pass "$message" ""
    else
        _assert_fail "$message" "value $(printf %q "$value") does not match regex $(printf %q "$regex")"
    fi
}

# --- Test naming / grouping ------------------------------------------------

# test_starts_with NAME: optional marker (mostly cosmetic; the next
# assertion's name in TAP is the real label). Useful for grouping.
test_starts_with() {
    _CURRENT_TEST_NAME="$1"
    printf '# %s\n' "$1"
}

# test_summary: print summary line, return 0 if all pass, 1 otherwise.
# Always call this at the end of a test_*.sh file.
test_summary() {
    printf '\n# tests run: %d | passed: %d | failed: %d\n' \
        "$_TESTS_RUN" "$_TESTS_PASSED" "$_TESTS_FAILED"
    if [ "$_TESTS_FAILED" -eq 0 ]; then
        return 0
    fi
    return 1
}

# --- Subshell helpers ------------------------------------------------------
# The a2tools entry scripts mutate globals when sourced (A2TOOLS_ROOT,
# A2TOOLS_STATE, etc.). To test functions in isolation we source the lib in
# a subshell with a sandboxed environment, run the function, and capture
# stdout / stderr / rc.

# A2TOOLS_SANDBOX_DIR: create a fresh dir tree that mimics the installed
# layout (/etc/a2tools, /var/lib/a2tools, /var/cache/a2tools, /var/log/a2tools)
# in the scratch space. The script-under-test can be told to look there
# instead of the real FHS paths.
make_a2tools_sandbox() {
    local prefix="${1:-$A2TOOLS_TEST_TMPDIR/sandbox}"
    mkdir -p \
        "$prefix/etc/a2tools/providers" \
        "$prefix/var/lib/a2tools" \
        "$prefix/var/cache/a2tools" \
        "$prefix/var/log/a2tools" \
        "$prefix/usr/share/a2tools/usage" \
        "$prefix/usr/share/a2tools/templates" \
        "$prefix/usr/share/a2tools/sql"
    printf '%s\n' "$prefix"
}

# fill_sandbox_with_repo: copy share/ files (templates/usage/sql) into a
# sandbox so scripts that load them can find them.
fill_sandbox_with_repo() {
    local sandbox="$1"
    cp -R "$A2TOOLS_SHARE_DIR/usage/."  "$sandbox/usr/share/a2tools/usage/"  2>/dev/null || true
    cp -R "$A2TOOLS_SHARE_DIR/templates/." "$sandbox/usr/share/a2tools/templates/" 2>/dev/null || true
    cp -R "$A2TOOLS_SHARE_DIR/sql/."      "$sandbox/usr/share/a2tools/sql/"      2>/dev/null || true
    cp -R "$A2TOOLS_PROVIDERS_DIR/."      "$sandbox/etc/a2tools/providers/"      2>/dev/null || true
}
