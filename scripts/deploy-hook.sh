#!/bin/bash
# a2tools certbot deploy hook.
#
# Installed as a symlink at /etc/letsencrypt/renewal-hooks/deploy/a2tools, so
# it runs automatically after EVERY successful issuance/renewal performed by
# certbot (including the certbot systemd timer that ships with the certbot
# package - a2tools does not need its own renewal scheduler).
#
# certbot exports:
#   RENEWED_LINEAGE  - path like /etc/letsencrypt/live/<domain>
#   RENEWED_DOMAINS  - space-separated domains on the renewed cert

A2TOOLS_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
. "$A2TOOLS_SELF_DIR/lib/common.sh"

[ -n "${RENEWED_LINEAGE:-}" ] || exit 0

domain="$(basename "$RENEWED_LINEAGE")"

# Record the issue date so `fqdnmgr list` reporting stays accurate.
if [ -f "$DOMAINS_DB_PATH" ] && is_valid_fqdn "$domain"; then
    db_domains "UPDATE domains SET cert_date='$(date '+%Y-%m-%d')' WHERE domain='$(sql_escape "$domain")';" 2>/dev/null || true
fi

# Pick up the new certificate.
if systemctl reload apache2 2>/dev/null; then
    log_msg "deploy-hook: renewed $domain (${RENEWED_DOMAINS:-}); apache reloaded"
else
    log_msg "deploy-hook: renewed $domain but apache reload FAILED"
fi

# docker-mailserver: the renewal wrote new 0600 key files, so let
# a2wcrecalc-dms regenerate its mapping and re-grant DMS_OWNER read access.
if [ "${DMS_ENABLED:-false}" = true ] && command -v a2wcrecalc-dms >/dev/null 2>&1; then
    if a2wcrecalc-dms >/dev/null 2>&1; then
        log_msg "deploy-hook: a2wcrecalc-dms refreshed docker-mailserver for $domain"
    else
        log_msg "deploy-hook: a2wcrecalc-dms FAILED after renewing $domain"
    fi
fi

exit 0
