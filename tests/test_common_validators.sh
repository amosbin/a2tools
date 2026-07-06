#!/bin/bash
# Unit tests for lib/common.sh validation primitives.
#
# These tests do NOT exercise any installed binaries. They source the lib
# in a subshell and call its functions directly. Nothing here should need
# root, network, or a running a2tools install.
#
# Covers: is_valid_ipv4, is_valid_fqdn, sql_escape, A2TOOLS_ROOT discovery,
# A2TOOLS_HAS_TTY setup, A2TOOLS_PROVIDER_DIRS ordering.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

# A bash 3.2-compatible way to source common.sh in a subshell and call a
# function, capturing stdout. We do this many times so factor it out.
run_common() {
    local func_call="$1"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        eval "$func_call"
    )
}

run_common_rc() {
    local func_call="$1"
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        eval "$func_call"
    ) >/dev/null 2>&1
    echo $?
}

# ===========================================================================
# A2TOOLS_ROOT / path discovery
# ===========================================================================
test_starts_with "A2TOOLS_ROOT discovery"

# Sourcing the lib in a subshell exposes the resolved root. The root should
# be the absolute path of the scripts/ directory (containing common.sh's
# parent lib/).
_root="$(run_common 'printf "%s" "$A2TOOLS_ROOT"')"
assert_eq "$A2TOOLS_SCRIPTS_DIR" "$_root" "A2TOOLS_ROOT resolves to scripts dir"

_share="$(run_common 'printf "%s" "$A2TOOLS_SHARE"')"
# When the lib is sourced from the repo, A2TOOLS_SHARE should be the repo's
# share/ directory (next to the entry scripts, not /usr/share/a2tools).
assert_eq "$A2TOOLS_SHARE_DIR" "$_share" "A2TOOLS_SHARE resolves to repo share/ when running from checkout"

_state="$(run_common 'printf "%s" "$A2TOOLS_STATE"')"
assert_eq "/var/lib/a2tools" "$_state" "A2TOOLS_STATE is /var/lib/a2tools"

# ===========================================================================
# FD 3 (A2TOOLS_HAS_TTY) setup
# ===========================================================================
test_starts_with "FD 3 user-facing output channel"

# When common.sh is sourced, FD 3 must be open. The has-tty flag should be
# a known boolean.
_tty="$(run_common 'printf "%s" "$A2TOOLS_HAS_TTY"')"
case "$_tty" in
    true|false) _assert_pass "A2TOOLS_HAS_TTY is a known boolean (got: $_tty)" "" ;;
    *) _assert_fail "A2TOOLS_HAS_TTY is a known boolean" "got: $_tty" ;;
esac

# The ui() function must write to FD 3. We capture FD 3 by redirecting
# it to a file INSIDE the subshell where ui() runs.
_capture_file="$(mktemp)"
_ui_capture="$(
    (
        # shellcheck disable=SC1090
        . "$A2TOOLS_LIB_DIR/common.sh"
        exec 3>"$_capture_file"
        ui "hello-from-ui"
    ) 2>/dev/null
    cat "$_capture_file"
)"
rm -f "$_capture_file"
assert_contains "$_ui_capture" "hello-from-ui" "ui() writes to FD 3"

# ===========================================================================
# is_valid_ipv4
# ===========================================================================
test_starts_with "is_valid_ipv4"

assert_eq "0" "$(run_common_rc 'is_valid_ipv4 0.0.0.0')"   "0.0.0.0 is valid"
assert_eq "0" "$(run_common_rc 'is_valid_ipv4 1.2.3.4')"   "1.2.3.4 is valid"
assert_eq "0" "$(run_common_rc 'is_valid_ipv4 255.255.255.255')" "255.255.255.255 is valid"
assert_eq "0" "$(run_common_rc 'is_valid_ipv4 127.0.0.1')" "127.0.0.1 (loopback) is valid"
assert_eq "0" "$(run_common_rc 'is_valid_ipv4 192.168.1.1')" "RFC1918 192.168.1.1 is valid"

# Invalid
assert_eq "1" "$(run_common_rc 'is_valid_ipv4 ""')"        "empty string rejected"
assert_eq "1" "$(run_common_rc 'is_valid_ipv4 1.2.3')"     "3 octets rejected"
assert_eq "1" "$(run_common_rc 'is_valid_ipv4 1.2.3.4.5')" "5 octets rejected"
assert_eq "1" "$(run_common_rc 'is_valid_ipv4 1.2.3.4.')"  "trailing dot rejected"
assert_eq "1" "$(run_common_rc 'is_valid_ipv4 256.0.0.0')" "256 octet rejected"
assert_eq "1" "$(run_common_rc 'is_valid_ipv4 999.999.999.999')" "all-9s rejected"
assert_eq "1" "$(run_common_rc 'is_valid_ipv4 1.2.3.a')"  "non-digit octet rejected"
assert_eq "1" "$(run_common_rc 'is_valid_ipv4 "1.2.3.4 "')" "trailing space rejected"
assert_eq "1" "$(run_common_rc 'is_valid_ipv4 "::1"')"    "IPv6 literal rejected"
# Documented behavior: the lib does NOT reject leading zeros (e.g. "1.2.3.04")
# because the regex `^([0-9]{1,3}\.){3}[0-9]{1,3}$` matches "04" and each
# octet is checked <= 255. We do not assert anything here; the comment is
# the test (future maintainers who add a stricter check should also update
# this comment to assert the new behavior).

# ===========================================================================
# is_valid_fqdn
# ===========================================================================
test_starts_with "is_valid_fqdn"

# Valid
assert_eq "0" "$(run_common_rc 'is_valid_fqdn example.com')"        "example.com is valid"
assert_eq "0" "$(run_common_rc 'is_valid_fqdn sub.example.com')"    "sub.example.com is valid"
assert_eq "0" "$(run_common_rc 'is_valid_fqdn a.b.c.d.e.example.com')" "deeply nested is valid"
assert_eq "0" "$(run_common_rc 'is_valid_fqdn "my-site.example.com"')" "hyphen in label is valid"
assert_eq "0" "$(run_common_rc 'is_valid_fqdn "x-yz.example.org"')" "hyphen mid-label is valid"
assert_eq "0" "$(run_common_rc 'is_valid_fqdn "a.io"')"             "short TLD 'io' is valid"
assert_eq "0" "$(run_common_rc 'is_valid_fqdn "a1.example.com"')"   "digit in label is valid"

# Invalid: empty / missing dot
assert_eq "1" "$(run_common_rc 'is_valid_fqdn ""')"        "empty string rejected"
assert_eq "1" "$(run_common_rc 'is_valid_fqdn localhost')" "no dot rejected"

# Invalid: leading/trailing hyphen
assert_eq "1" "$(run_common_rc 'is_valid_fqdn "-bad.example.com"')" "leading hyphen rejected"
assert_eq "1" "$(run_common_rc 'is_valid_fqdn "bad-.example.com"')" "trailing hyphen rejected"

# Invalid: bad characters
assert_eq "1" "$(run_common_rc 'is_valid_fqdn "under_score.example.com"')" "underscore rejected"
assert_eq "1" "$(run_common_rc 'is_valid_fqdn "ex ample.com"')"             "space rejected"
assert_eq "1" "$(run_common_rc 'is_valid_fqdn "ex@mple.com"')"              "@ rejected"
assert_eq "1" "$(run_common_rc 'is_valid_fqdn "*.example.com"')"            "wildcard rejected"

# Invalid: TLD too short or non-alpha
#   1-char TLD is rejected (regex requires alphabetic >= 2).
assert_eq "1" "$(run_common_rc 'is_valid_fqdn "example.c"')"   "1-char TLD rejected"
assert_eq "1" "$(run_common_rc 'is_valid_fqdn "example.123"')" "numeric TLD rejected"

# Invalid: label too long (63+ chars)
_long_label="$(printf 'a%.0s' $(seq 1 64))"
assert_eq "1" "$(run_common_rc "is_valid_fqdn $_long_label.example.com")" "64-char label rejected"

# Invalid: total length > 253. The lib's check is `<= 253` (the
# DNS-imposed max). 250 a's + ".co" = 253 chars (boundary, accepted).
# 251 a's + ".co" = 254 chars (rejected).
_too_long="$(printf 'a%.0s' $(seq 1 251)).co"
assert_eq "1" "$(run_common_rc "is_valid_fqdn $_too_long")" "254-char FQDN rejected"

# ===========================================================================
# sql_escape
# ===========================================================================
test_starts_with "sql_escape"

assert_eq "hello"      "$(run_common 'sql_escape hello')"       "plain text untouched"
assert_eq "O''Brien"   "$(run_common "sql_escape \"O'Brien\"")"  "single quote doubled"
assert_eq "''"         "$(run_common "sql_escape \"'\"")"       "single quote -> doubled empty"
assert_eq "a''b''c"    "$(run_common "sql_escape \"a'b'c\"")"   "multiple single quotes doubled"
# Nothing else (no backslash, no double-quote) is touched by the escape.
# The single-quoted outer string is taken literally; the inner `\"` is
# the eval'd "double-quoted string containing one double quote". The
# `\\b` is the eval'd "double-quoted string with one literal backslash
# before the b" (in a double-quoted bash string, `\\` -> one backslash).
assert_eq 'a"b'        "$(run_common 'sql_escape "a\"b"')"      "double quote untouched"
assert_eq 'a\b'        "$(run_common 'sql_escape "a\\b"')"      "backslash untouched"

# ===========================================================================
# A2TOOLS_PROVIDER_DIRS ordering
# ===========================================================================
test_starts_with "A2TOOLS_PROVIDER_DIRS ordering"

# /etc/a2tools/providers must come before the bundled dir so local overrides
# win. The lib hard-codes this order.
_dirs="$(run_common 'printf "%s\n" "${A2TOOLS_PROVIDER_DIRS[@]}"')"
_first="$(printf '%s\n' "$_dirs" | sed -n 1p)"
_second="$(printf '%s\n' "$_dirs" | sed -n 2p)"
assert_eq "/etc/a2tools/providers" "$_first" "first provider dir is /etc (overrides)"
assert_contains "$_second" "/a2tools/providers" "second provider dir is bundled"
assert_neq "$_first" "$_second" "provider dirs are distinct"

test_summary
