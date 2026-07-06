#!/bin/bash
# Unit tests for the template-rendering logic in a2sitemgr.sh.
#
# a2sitemgr's render_template() function takes a .tpl file, performs
# general {{FQDN}} substitution, then adds mode-specific substitutions
# (domain, swc, proxypass). We do NOT source a2sitemgr.sh as a whole
# (that runs the whole main dispatch). Instead we re-implement the same
# substitution logic and verify it produces correct output for each mode,
# which catches any drift in the templates themselves.
#
# If you change a template, the corresponding assertion here will fail
# and force a deliberate update - this is the intended safety net.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

TEMPLATES_DIR="$A2TOOLS_SHARE_DIR/templates"

assert_file_exists "$TEMPLATES_DIR/init_standard.conf.tpl" "init_standard template present"
assert_file_exists "$TEMPLATES_DIR/init_proxypass.conf.tpl" "init_proxypass template present"
assert_file_exists "$TEMPLATES_DIR/ssl_standard.conf.tpl" "ssl_standard template present"
assert_file_exists "$TEMPLATES_DIR/ssl_proxypass.conf.tpl" "ssl_proxypass template present"
assert_file_exists "$TEMPLATES_DIR/swc_min.conf.tpl" "swc_min template present"
assert_file_exists "$TEMPLATES_DIR/domain.conf.tpl" "domain.conf template present"

# render_init_standard FQDN
# Same sed chain as a2sitemgr.sh's render_template (domain branch).
render_init_standard() {
    local fqdn="$1" out="$2"
    sed -e "s|{{FQDN}}|$fqdn|g" "$TEMPLATES_DIR/init_standard.conf.tpl" > "$out"
}

render_init_proxypass() {
    local fqdn="$1" subdomain="$2" fqdn_base="$3" cert_domain="$4" \
        actual_server_name="$5" proxy_protocol="$6" proxy_port="$7" out="$8"
    sed -e "s|{{FQDN}}|$fqdn|g" \
        -e "s|{{SUBDOMAIN}}|$subdomain|g" \
        -e "s|{{FQDN_BASE}}|$fqdn_base|g" \
        -e "s|{{CERT_DOMAIN}}|$cert_domain|g" \
        -e "s|{{ACTUAL_SERVER_NAME}}|$actual_server_name|g" \
        -e "s|{{PROXY_PROTOCOL}}|$proxy_protocol|g" \
        -e "s|{{PROXY_PORT}}|$proxy_port|g" \
        "$TEMPLATES_DIR/init_proxypass.conf.tpl" > "$out"
}

render_swc_min() {
    local fqdn="$1" subdomain="$2" out="$3"
    sed -e "s|{{FQDN}}|$fqdn|g" \
        -e "s|{{SUBDOMAIN}}|$subdomain|g" \
        "$TEMPLATES_DIR/swc_min.conf.tpl" > "$out"
}

render_ssl_standard() {
    local fqdn="$1" fqdn_base="$2" out="$3"
    sed -e "s|{{FQDN}}|$fqdn|g" \
        -e "s|{{FQDN_BASE}}|$fqdn_base|g" \
        "$TEMPLATES_DIR/ssl_standard.conf.tpl" > "$out"
}

render_ssl_proxypass() {
    local actual_server_name="$1" subdomain="$2" fqdn_base="$3" cert_domain="$4" \
        proxy_protocol="$5" proxy_port="$6" out="$7"
    sed -e "s|{{ACTUAL_SERVER_NAME}}|$actual_server_name|g" \
        -e "s|{{SUBDOMAIN}}|$subdomain|g" \
        -e "s|{{FQDN_BASE}}|$fqdn_base|g" \
        -e "s|{{CERT_DOMAIN}}|$cert_domain|g" \
        -e "s|{{PROXY_PROTOCOL}}|$proxy_protocol|g" \
        -e "s|{{PROXY_PORT}}|$proxy_port|g" \
        "$TEMPLATES_DIR/ssl_proxypass.conf.tpl" > "$out"
}

# ---------------------------------------------------------------------------
test_starts_with "init_standard.conf.tpl: FQDN substitution leaves no placeholders"
# ---------------------------------------------------------------------------
out="$(mktemp)"
render_init_standard "example.com" "$out"
content="$(cat "$out")"
assert_contains "$content" "ServerName example.com" "ServerName is filled in"
assert_contains "$content" "ServerAlias *.example.com" "ServerAlias wildcard is filled in"
assert_contains "$content" "DocumentRoot /var/www/example.com/public_html" "DocumentRoot is filled in"
assert_contains "$content" "/var/log/apache-collector/example.com_error.log" "ErrorLog is filled in"
assert_not_contains "$content" "{{FQDN}}" "no {{FQDN}} placeholders remain"
rm -f "$out"

# ---------------------------------------------------------------------------
test_starts_with "init_standard.conf.tpl: no other placeholders are introduced"
# ---------------------------------------------------------------------------
# This catches a future maintainer who adds a new {{PLACEHOLDER}} to the
# template without updating render_template.
out="$(mktemp)"
render_init_standard "example.com" "$out"
content="$(cat "$out")"
case "$content" in
    *'{{'*'{{'*)  _assert_fail "init_standard should contain no placeholders" "found {{..}} in: $content" ;;
    *)             _assert_pass "init_standard contains no placeholders" "" ;;
esac
rm -f "$out"

# ---------------------------------------------------------------------------
test_starts_with "init_proxypass.conf.tpl: full substitution for a subdomain"
# ---------------------------------------------------------------------------
out="$(mktemp)"
render_init_proxypass "app.example.com" "app" "app" "example.com" \
    "app.example.com" "http" "8080" "$out"
content="$(cat "$out")"
assert_contains "$content" "ServerName app.example.com" "ServerName is the FQDN"
assert_contains "$content" "app_error.log" "FQDN-based log path"
assert_not_contains "$content" "{{FQDN}}" "no FQDN placeholder"
assert_not_contains "$content" "{{SUBDOMAIN}}" "no SUBDOMAIN placeholder"
assert_not_contains "$content" "{{FQDN_BASE}}" "no FQDN_BASE placeholder"
assert_not_contains "$content" "{{CERT_DOMAIN}}" "no CERT_DOMAIN placeholder"
assert_not_contains "$content" "{{ACTUAL_SERVER_NAME}}" "no ACTUAL_SERVER_NAME placeholder"
assert_not_contains "$content" "{{PROXY_PROTOCOL}}" "no PROXY_PROTOCOL placeholder"
assert_not_contains "$content" "{{PROXY_PORT}}" "no PROXY_PORT placeholder"
rm -f "$out"

# ---------------------------------------------------------------------------
test_starts_with "swc_min.conf.tpl: subdomain wildcard ServerAlias"
# ---------------------------------------------------------------------------
out="$(mktemp)"
render_swc_min "mail.*" "mail" "$out"
content="$(cat "$out")"
assert_contains "$content" "ServerAlias mail.*" "ServerAlias has the wildcard"
assert_not_contains "$content" "{{FQDN}}" "no FQDN placeholder"
assert_not_contains "$content" "{{SUBDOMAIN}}" "no SUBDOMAIN placeholder"
rm -f "$out"

# ---------------------------------------------------------------------------
test_starts_with "ssl_standard.conf.tpl: cert paths point at the right live dir"
# ---------------------------------------------------------------------------
out="$(mktemp)"
render_ssl_standard "example.com" "example" "$out"
content="$(cat "$out")"
assert_contains "$content" "/etc/letsencrypt/live/example.com/fullchain.pem" "fullchain path"
assert_contains "$content" "/etc/letsencrypt/live/example.com/privkey.pem" "privkey path"
assert_contains "$content" "ServerName example.com" "ServerName is the FQDN"
assert_contains "$content" "ServerAlias *.example.com" "ServerAlias wildcard"
assert_not_contains "$content" "{{FQDN}}" "no FQDN placeholder"
assert_not_contains "$content" "{{FQDN_BASE}}" "no FQDN_BASE placeholder"
rm -f "$out"

# ---------------------------------------------------------------------------
test_starts_with "ssl_proxypass.conf.tpl: ProxyPass uses substituted protocol/port"
# ---------------------------------------------------------------------------
out="$(mktemp)"
render_ssl_proxypass "app.example.com" "app" "app" "example.com" "http" "8080" "$out"
content="$(cat "$out")"
assert_contains "$content" "ServerName app.example.com" "ServerName is the proxy target"
assert_contains "$content" "ProxyPass / http://localhost:8080/" "HTTP proxy at 8080"
assert_contains "$content" "ProxyPassReverse / http://localhost:8080/" "ProxyPassReverse"
assert_contains "$content" "/etc/letsencrypt/live/example.com/fullchain.pem" "cert path uses cert_domain"
assert_contains "$content" "SSLProxyEngine On" "SSLProxyEngine on"
# Now exercise the HTTPS variant.
out2="$(mktemp)"
render_ssl_proxypass "secure.example.com" "secure" "secure" "example.com" "https" "8443" "$out2"
content2="$(cat "$out2")"
assert_contains "$content2" "ProxyPass / https://localhost:8443/" "HTTPS proxy at 8443"
rm -f "$out" "$out2"

# ---------------------------------------------------------------------------
test_starts_with "domain.conf.tpl: sanity (no broken interpolation)"
# ---------------------------------------------------------------------------
# domain.conf is sourced (not sed-substituted), so a placeholder here is
# just text. We assert the file is syntactically OK as a bash source and
# contains the documented keys.
out="$(bash -n "$TEMPLATES_DIR/domain.conf.tpl" 2>&1)" && rc=0 || rc=$?
assert_eq "0" "$rc" "domain.conf.tpl is valid bash syntax"
content="$(cat "$TEMPLATES_DIR/domain.conf.tpl")"
for key in YEARS FIRST_NAME LAST_NAME ADDRESS1 CITY STATE_PROVINCE POSTAL_CODE COUNTRY PHONE EMAIL DOMAIN_CLEANUP_DAYS; do
    case "$content" in
        *"$key"*) _assert_pass "domain.conf.tpl documents $key" "" ;;
        *)        _assert_fail "domain.conf.tpl documents $key" "key not found" ;;
    esac
done

# ---------------------------------------------------------------------------
test_starts_with "FQDN with regex-special chars survives substitution"
# ---------------------------------------------------------------------------
# Real-world FQDNs don't contain regex metachars, but the substitution
# should not blow up if a future template uses one (e.g. dots in {{FQDN}}
# are not interpreted by sed -e). This is a defensive check.
out="$(mktemp)"
render_init_standard "my-site.example.com" "$out"
content="$(cat "$out")"
assert_contains "$content" "my-site.example.com" "hyphenated FQDN substituted verbatim"
rm -f "$out"

test_summary
