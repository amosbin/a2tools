#!/bin/bash
# Certificate renewal script for a2tools
# Checks for certificates needing renewal (10 or less days left from 90-day period)
# Renews using ACME DNS challenge via fqdnmgr hooks

set -euo pipefail

# Configuration
DB_PATH="/etc/fqdntools/domains.db"
CERT_VALIDITY_DAYS=90
RENEWAL_THRESHOLD_DAYS=10
LOG_FILE="/var/log/a2certrenew.log"

# Logging function
log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE" 2>/dev/null || true
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root" >&2
    exit 1
fi

# Check if database exists
if [ ! -f "$DB_PATH" ]; then
    log "Database not found at $DB_PATH"
    exit 0
fi

# Check prerequisites
if ! command -v certbot >/dev/null 2>&1; then
    log "Error: certbot is not installed"
    exit 1
fi

if ! command -v fqdnmgr >/dev/null 2>&1; then
    log "Error: fqdnmgr is not installed"
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    log "Error: sqlite3 is not installed"
    exit 1
fi

log "Starting certificate renewal check..."

# Calculate the cutoff date (certificates issued more than 80 days ago need renewal)
# 90 days validity - 10 days threshold = 80 days
CUTOFF_DAYS=$((CERT_VALIDITY_DAYS - RENEWAL_THRESHOLD_DAYS))
CUTOFF_DATE=$(date -d "-${CUTOFF_DAYS} days" '+%Y-%m-%d' 2>/dev/null || date -v-${CUTOFF_DAYS}d '+%Y-%m-%d')

# Query domains with certificates that need renewal
# Select domains where:
# - cert_date is set (not NULL)
# - cert_date is older than the cutoff date
# - domain is owned (has valid status)
DOMAINS_TO_RENEW=$(sqlite3 "$DB_PATH" "SELECT domain, registrar, cert_date FROM domains WHERE cert_date IS NOT NULL AND cert_date <= '$CUTOFF_DATE' AND status = 'owned' AND registrar IS NOT NULL;" 2>/dev/null || true)

if [ -z "$DOMAINS_TO_RENEW" ]; then
    log "No certificates need renewal at this time."
    exit 0
fi

RENEWED_COUNT=0
FAILED_COUNT=0

# Process each domain
echo "$DOMAINS_TO_RENEW" | while IFS='|' read -r domain registrar cert_date; do
    [ -z "$domain" ] && continue
    
    log "Checking certificate for $domain (issued: $cert_date, registrar: $registrar)"
    
    # Calculate days since certificate was issued
    CERT_DATE_EPOCH=$(date -d "$cert_date" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d' "$cert_date" '+%s')
    NOW_EPOCH=$(date '+%s')
    DAYS_SINCE_ISSUE=$(( (NOW_EPOCH - CERT_DATE_EPOCH) / 86400 ))
    DAYS_REMAINING=$((CERT_VALIDITY_DAYS - DAYS_SINCE_ISSUE))
    
    log "Certificate for $domain: $DAYS_REMAINING days remaining"
    
    if [ "$DAYS_REMAINING" -le "$RENEWAL_THRESHOLD_DAYS" ]; then
        log "Renewing certificate for $domain..."
        
        # Construct certbot command with ACME DNS challenge
        CERTBOT_AUTH_HOOK="fqdnmgr certify $registrar"
        CERTBOT_CLEANUP_HOOK="fqdnmgr cleanup $registrar"
        
        # Run certbot renewal (non-verbose, capture output)
        CERTBOT_OUTPUT=$(certbot -d "*.$domain" -d "$domain" \
            --manual \
            --preferred-challenges dns \
            --manual-auth-hook "$CERTBOT_AUTH_HOOK" \
            --manual-cleanup-hook "$CERTBOT_CLEANUP_HOOK" \
            --issuance-timeout 600 \
            --force-renewal \
            certonly 2>&1)
        CERTBOT_EXIT=$?
        
        if [ $CERTBOT_EXIT -eq 0 ]; then
            log "Successfully renewed certificate for $domain"
            
            # Update cert_date in database
            NEW_CERT_DATE=$(date '+%Y-%m-%d')
            sqlite3 "$DB_PATH" "UPDATE domains SET cert_date = '$NEW_CERT_DATE' WHERE domain = '$domain';" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                log "Updated cert_date to $NEW_CERT_DATE for $domain"
            else
                log "Warning: Failed to update cert_date for $domain"
            fi
            
            # Reload Apache to use new certificate
            if systemctl reload apache2 2>/dev/null; then
                log "Apache reloaded successfully"
            else
                log "Warning: Failed to reload Apache"
            fi
            
            RENEWED_COUNT=$((RENEWED_COUNT + 1))
        else
            log "Failed to renew certificate for $domain: $CERTBOT_OUTPUT"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    fi
done

log "Certificate renewal check complete. Renewed: $RENEWED_COUNT, Failed: $FAILED_COUNT"
exit 0
