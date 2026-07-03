#!/bin/bash
set -euo pipefail

CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"

if [[ -n "$CERTBOT_EMAIL" ]]; then
  if [[ ! -d "/etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory" ]] || \
     [[ -z "$(ls -A /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/ 2>/dev/null)" ]]; then
    echo "Registering certbot account with email: $CERTBOT_EMAIL"
    certbot register --email "$CERTBOT_EMAIL" --agree-tos --no-eff-email || true
  fi
fi

if [[ "${FQDNCREDMGR_ENABLED:-false}" == "true" ]]; then
  echo "Starting fqdncredmgrd daemon..."
  /usr/local/bin/fqdncredmgrd &
fi

exec "$@"
