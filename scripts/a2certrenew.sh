#!/bin/bash
# a2certrenew - renew a2tools-managed certificates on demand.
#
# Scheduling note: routine renewals do NOT go through this script. certbot
# persists the fqdnmgr auth/cleanup hooks in each certificate's renewal
# profile, and the certbot package's own systemd timer runs `certbot renew`
# twice daily. The a2tools deploy hook
# (/etc/letsencrypt/renewal-hooks/deploy/a2tools) reloads Apache and updates
# the domains DB after every successful renewal.
#
# This wrapper exists for manual/forced runs and for log visibility.

set -u

A2TOOLS_SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
. "$A2TOOLS_SELF_DIR/lib/common.sh"

RENEW_LOG="$A2TOOLS_LOG_DIR/a2certrenew.log"

rlog() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$RENEW_LOG" 2>/dev/null || true
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root" >&2
    exit 1
fi

if ! command -v certbot >/dev/null 2>&1; then
    echo "Error: certbot is not installed" >&2
    exit 1
fi

rlog "Manual renewal run started (args: $*)"

# `certbot renew` only renews certificates close to expiry; pass extra flags
# through (e.g. --force-renewal, --cert-name example.com, --dry-run).
if certbot renew "$@" 2>&1 | tee -a "$RENEW_LOG"; then
    rlog "Renewal run finished successfully"
    exit 0
else
    rc=$?
    rlog "Renewal run FAILED (exit $rc)"
    exit "$rc"
fi
