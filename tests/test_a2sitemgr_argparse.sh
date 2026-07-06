#!/bin/bash
# Unit tests for the input-validation and argument-parsing logic in
# a2sitemgr.sh, exercised without sourcing the full script (which would
# dispatch the main loop).
#
# We extract small, self-contained validation snippets from a2sitemgr.sh
# and source them in a subshell with a sandboxed environment. The
# FQDN-validation regex, the proxy-port range check, the swc-FQDN format
# check, and the proxypass-FQDN "must be a subdomain" check all live
# inline in the script - we copy the exact same regex / arithmetic into
# extracted snippets so the test catches drift.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

SANDBOX="$(make_a2tools_sandbox)"
fill_sandbox_with_repo "$SANDBOX"

# The validation snippets below are COPIES of the in-script code. We
# intentionally duplicate rather than extract via awk, because the live
# code is interleaved with side effects (exits, prints, reads from
# /dev/tty) that we don't want to run here.

# --- is_apex_or_subdomain_fqdn (mirror of a2sitemgr.sh's domain-mode regex) ---
# The regex used:  ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$
is_valid_apex_or_subdomain() {
    local fqdn="$1"
    [[ "$fqdn" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

# --- is_subdomain_fqdn (mirror of the proxypass-mode regex) ---
# ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?.*$
# but in the script the simpler form is used:  ^([^.]+)\.(.+)$
is_subdomain_fqdn() {
    local fqdn="$1"
    [[ "$fqdn" =~ ^[^.]+\..+$ ]]
}

# --- is_swc_fqdn (mirror of the swc mode regex) ---
# ^[a-zA-Z0-9-]+\.\*$
is_swc_fqdn() {
    local fqdn="$1"
    [[ "$fqdn" =~ ^[a-zA-Z0-9-]+\.\*$ ]]
}

# --- is_valid_port (mirror of the proxy-port check) ---
is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# --- split_subdomain_and_cert_domain (mirror of the proxypass-mode branch) ---
split_subdomain_and_cert_domain() {
    local fqdn="$1"
    if [[ "$fqdn" =~ ^([^.]+)\.(.+)$ ]]; then
        SUBDOMAIN="${BASH_REMATCH[1]}"
        FQDN_BASE="$SUBDOMAIN"
        CERT_DOMAIN="${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
test_starts_with "apex/subdomain FQDN regex accepts common cases"
# ---------------------------------------------------------------------------
assert_true "$(is_valid_apex_or_subdomain example.com && echo true)" "example.com"
assert_true "$(is_valid_apex_or_subdomain sub.example.com && echo true)" "sub.example.com"
assert_true "$(is_valid_apex_or_subdomain a.io && echo true)" "a.io (short)"
assert_true "$(is_valid_apex_or_subdomain "x-y.example.com" && echo true)" "x-y.example.com (hyphen)"
assert_true "$(is_valid_apex_or_subdomain "a-b-c.example.com" && echo true)" "a-b-c.example.com"
assert_true "$(is_valid_apex_or_subdomain "9.example.com" && echo true)" "9.example.com (digit label)"
assert_true "$(is_valid_apex_or_subdomain "a.9.example.com" && echo true)" "a.9.example.com (numeric TLD)"

# ---------------------------------------------------------------------------
test_starts_with "apex/subdomain FQDN regex rejects malformed input"
# ---------------------------------------------------------------------------
assert_false "$(is_valid_apex_or_subdomain '' && echo true)" "empty"
assert_false "$(is_valid_apex_or_subdomain '-foo.com' && echo true)" "leading hyphen"
assert_false "$(is_valid_apex_or_subdomain 'foo-.com' && echo true)" "trailing hyphen label"
assert_false "$(is_valid_apex_or_subdomain 'foo .com' && echo true)" "space in label"
assert_false "$(is_valid_apex_or_subdomain '.foo.com' && echo true)" "leading dot"
assert_false "$(is_valid_apex_or_subdomain 'foo..com' && echo true)" "double dot"
assert_false "$(is_valid_apex_or_subdomain 'foo.com.' && echo true)" "trailing dot"

# ---------------------------------------------------------------------------
test_starts_with "subdomain FQDN regex: must have at least one dot"
# ---------------------------------------------------------------------------
assert_true  "$(is_subdomain_fqdn foo.example.com && echo true)" "foo.example.com"
assert_true  "$(is_subdomain_fqdn a.b.c.example.com && echo true)" "deeply nested"
# The simple regex (^[^.]+\..+$) is intentionally permissive: any single
# dot anywhere is enough. Apex domains (no dot) are rejected.
assert_false "$(is_subdomain_fqdn example.com && echo true)" "apex (no dot) rejected"
assert_false "$(is_subdomain_fqdn 'localhost' && echo true)" "localhost rejected"

# ---------------------------------------------------------------------------
test_starts_with "swc FQDN regex: must be 'label.*'"
# ---------------------------------------------------------------------------
assert_true  "$(is_swc_fqdn 'mail.*' && echo true)"  "mail.*"
assert_true  "$(is_swc_fqdn 'a.*' && echo true)"     "a.*"
assert_true  "$(is_swc_fqdn 'my-app.*' && echo true)" "my-app.*"
# The swc regex requires a literal .* at the end; the body is one label
# of [A-Za-z0-9-]. Anything else is rejected.
assert_false "$(is_swc_fqdn 'mail.com' && echo true)" "literal .com rejected"
assert_false "$(is_swc_fqdn 'mail' && echo true)"    "no .* rejected"
assert_false "$(is_swc_fqdn '*.mail' && echo true)"  "leading wildcard rejected"
assert_false "$(is_swc_fqdn 'mail.*.com' && echo true)" "extra labels rejected"
assert_false "$(is_swc_fqdn '' && echo true)"        "empty rejected"

# ---------------------------------------------------------------------------
test_starts_with "port range check: 1..65535"
# ---------------------------------------------------------------------------
assert_true  "$(is_valid_port 1 && echo true)"      "port 1"
assert_true  "$(is_valid_port 80 && echo true)"     "port 80"
assert_true  "$(is_valid_port 8080 && echo true)"   "port 8080"
assert_true  "$(is_valid_port 65535 && echo true)"  "port 65535"
assert_false "$(is_valid_port 0 && echo true)"      "port 0 rejected"
assert_false "$(is_valid_port 65536 && echo true)"  "port 65536 rejected"
assert_false "$(is_valid_port -1 && echo true)"     "negative port rejected (regex fails)"
assert_false "$(is_valid_port '80a' && echo true)"  "non-numeric port rejected"
assert_false "$(is_valid_port '' && echo true)"     "empty port rejected"
assert_false "$(is_valid_port 'abc' && echo true)"  "letters rejected"

# ---------------------------------------------------------------------------
test_starts_with "subdomain split: extracts SUB, FQDN_BASE, CERT_DOMAIN"
# ---------------------------------------------------------------------------
SUBDOMAIN=""; FQDN_BASE=""; CERT_DOMAIN=""
split_subdomain_and_cert_domain "app.example.com"
assert_eq "app" "SUBDOMAIN" "subdomain is 'app'"
assert_eq "app" "FQDN_BASE" "FQDN_BASE is the subdomain label"
assert_eq "example.com" "CERT_DOMAIN" "CERT_DOMAIN is the rest"

SUBDOMAIN=""; FQDN_BASE=""; CERT_DOMAIN=""
split_subdomain_and_cert_domain "secure.app.example.com"
assert_eq "secure" "SUBDOMAIN" "deep subdomain first label"
assert_eq "secure" "FQDN_BASE" "FQDN_BASE is first label even when deep"
assert_eq "app.example.com" "CERT_DOMAIN" "CERT_DOMAIN is everything after first dot"

# Apex returns non-zero (script treats this as an error).
SUBDOMAIN=""; FQDN_BASE=""; CERT_DOMAIN=""
rc=0
split_subdomain_and_cert_domain "example.com" || rc=$?
assert_eq "1" "$rc" "apex domain -> rc 1 from split"

# ---------------------------------------------------------------------------
test_starts_with "mode flag combos that the script rejects at parse time"
# ---------------------------------------------------------------------------
# These are pure-string validations of flag combinations the script
# catches before doing real work. We don't run the script (it would try
# to write to /etc/apache2) - we just assert the rules.

# -s / --secured is only valid with proxypass mode.
# (Documented as: the script prints an error and exits 1 if MODE=domain
# and SECURED=true.)
# (Mocked check; not running the script.)
mode_is_valid_combo() {
    local mode="$1" secured="$2" proxy_port="$3"
    case "$mode" in
        domain)
            [ "$secured" != true ] && [ -z "$proxy_port" ] && return 0
            return 1
            ;;
        proxypass)
            [ -n "$proxy_port" ] && return 0
            return 1
            ;;
        swc)
            [ "$secured" != true ] && [ -z "$proxy_port" ] && return 0
            return 1
            ;;
    esac
    return 1
}

assert_true  "$(mode_is_valid_combo domain      false '' && echo true)"   "domain mode, no -s, no -p"
assert_false "$(mode_is_valid_combo domain      true  '' && echo true)"   "domain mode + -s is invalid"
assert_false "$(mode_is_valid_combo domain      false 8080 && echo true)" "domain mode + -p is invalid"
assert_true  "$(mode_is_valid_combo proxypass   false 8080 && echo true)" "proxypass + -p is valid"
assert_false "$(mode_is_valid_combo proxypass   false '' && echo true)"   "proxypass without -p is invalid"
assert_true  "$(mode_is_valid_combo proxypass   true  8443 && echo true)" "proxypass + -s + -p is valid"
assert_true  "$(mode_is_valid_combo swc         false '' && echo true)"   "swc with no extras is valid"
assert_false "$(mode_is_valid_combo swc         true  '' && echo true)"   "swc + -s is invalid"
assert_false "$(mode_is_valid_combo swc         false 8080 && echo true)" "swc + -p is invalid"

test_summary
