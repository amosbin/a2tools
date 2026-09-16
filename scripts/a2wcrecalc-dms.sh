#!/bin/bash
#
# DMS_DIR, DMS_CONFIG_DIR and DMS_OWNER come from /etc/a2tools (see
# 00-defaults.conf). -d / --dir overrides DMS_DIR for one run, and then the
# config directory is taken as DMS_DIR/data/config (podmgr layout).

# Pick up a2tools.conf / a2tools.conf.d/*.conf so the user can set DMS_DIR
# (or other knobs) in /etc/a2tools/ without touching this script.
A2TOOLS_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$A2TOOLS_ROOT/lib/common.sh"

DMS_DIR_CLI=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir)
            [ $# -ge 2 ] || { echo "Error: -d/--dir requires a value (use --help)" >&2; exit 1; }
            DMS_DIR_CLI="$2"; shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: a2wcrecalc-dms -d DMS_DIR

Recalculate Apache configs and regenerate docker-mailserver SNI mapping files,
then let DMS_OWNER (root inside a rootless container) read each mapped
certificate.
DMS_DIR, DMS_CONFIG_DIR and DMS_OWNER are read from
/etc/a2tools/a2tools.conf (or *.conf under /etc/a2tools/a2tools.conf.d/).
Defaults: /srv/podmgr/compose/dms, its data/config, and dms.

Options:
  -d, --dir DMS_DIR   Use this stack directory instead of DMS_DIR
                      (config directory becomes DMS_DIR/data/config)
  -h, --help          Show this help
EOF
            exit 0
            ;;
        *)
            echo "Error: invalid argument '$1' (use --help)" >&2
            exit 1
            ;;
    esac
done

if [ -n "$DMS_DIR_CLI" ]; then
    DMS_DIR="$DMS_DIR_CLI"
    DMS_CONFIG_DIR="$DMS_DIR/data/config"
fi
if [ ! -d "${DMS_DIR:-}" ]; then
    echo "DMS directory not found: ${DMS_DIR:-<unset>}" >&2
    exit 1
fi
if [ ! -d "${DMS_CONFIG_DIR:-}" ]; then
    echo "Config directory not found: ${DMS_CONFIG_DIR:-<unset>}" >&2
    exit 1
fi

# Check if Apache sites-available directory exists
if [ ! -d "/etc/apache2/sites-available" ]; then
    echo "Apache sites-available directory not found: /etc/apache2/sites-available" >&2
    exit 1
fi

# Array to store unique ServerName entries
declare -A server_names

# Parse all Apache config files in sites-available
for config_file in /etc/apache2/sites-available/*.conf; do
    [ -f "$config_file" ] || continue
    
    # Extract ServerName entries, excluding wildcards
    while IFS= read -r line; do
        # Remove leading/trailing whitespace and get ServerName value
        server_name=$(echo "$line" | awk '{print $2}')
        
        # Skip if empty, contains wildcard, or is a subdomain (more than one dot)
        dot_count=$(echo "$server_name" | tr -cd '.' | wc -c)
        if [ -n "$server_name" ] && [[ ! "$server_name" =~ \* ]] && [ "$dot_count" -eq 1 ]; then
            server_names["$server_name"]=1
        fi
    done < <(grep -i "^[[:space:]]*ServerName" "$config_file")
done

# Build the SNI certificate map content
sni_map_content=""

for fqdn in "${!server_names[@]}"; do
    # Define certificate paths
    privkey_path="/etc/letsencrypt/live/$fqdn/privkey.pem"
    fullchain_path="/etc/letsencrypt/live/$fqdn/fullchain.pem"
    
    # Check if the private key exists before adding to map
    if [ -f "$privkey_path" ]; then
        # Add entry in the format: mail.$FQDN /path/to/privkey.pem /path/to/fullchain.pem
        sni_map_content+="mail.$fqdn $privkey_path $fullchain_path"$'\n'
    else
        echo "Warning: Certificate not found for $fqdn (skipping)" >&2
    fi
done

# Save the SNI certificate map to the DMS config directory
output_file="$DMS_CONFIG_DIR/sni_cert_map"

if [ -n "$sni_map_content" ]; then
    echo "$sni_map_content" > "$output_file"
    
    # Match ownership to compose.yaml if it exists
    if [ -f "$DMS_DIR/compose.yaml" ]; then
        compose_owner=$(stat -c '%U:%G' "$DMS_DIR/compose.yaml" 2>/dev/null || stat -f '%Su:%Sg' "$DMS_DIR/compose.yaml" 2>/dev/null)
        if [ -n "$compose_owner" ]; then
            chown "$compose_owner" "$output_file"
        fi
    fi
    
    echo "SNI certificate map saved to: $output_file"
    count=$(printf '%s' "$sni_map_content" | grep -cve '^[[:space:]]*$')
    echo "Total domains mapped: $count"
else
    echo "No valid domains found with certificates."
    exit 0
fi

# Build the Dovecot SNI configuration content
dovecot_sni_content=""

for fqdn in "${!server_names[@]}"; do
    # Define certificate paths
    privkey_path="/etc/letsencrypt/live/$fqdn/privkey.pem"
    fullchain_path="/etc/letsencrypt/live/$fqdn/fullchain.pem"
    
    # Check if the private key exists before adding to config
    if [ -f "$privkey_path" ]; then
        # Add entry in Dovecot SNI format
        dovecot_sni_content+="local_name mail.$fqdn {"$'\n'
        dovecot_sni_content+="  ssl_key = <$privkey_path"$'\n'
        dovecot_sni_content+="  ssl_cert = <$fullchain_path"$'\n'
        dovecot_sni_content+="}"$'\n'
        dovecot_sni_content+=$'\n'
    fi
done

# Save the Dovecot SNI configuration
dovecot_output_file="$DMS_CONFIG_DIR/99-sni.conf"

if [ -n "$dovecot_sni_content" ]; then
    echo "$dovecot_sni_content" > "$dovecot_output_file"
    
    # Match ownership to compose.yaml if it exists
    if [ -f "$DMS_DIR/compose.yaml" ]; then
        compose_owner=$(stat -c '%U:%G' "$DMS_DIR/compose.yaml" 2>/dev/null || stat -f '%Su:%Sg' "$DMS_DIR/compose.yaml" 2>/dev/null)
        if [ -n "$compose_owner" ]; then
            chown "$compose_owner" "$dovecot_output_file"
        fi
    fi
    
    echo "Dovecot SNI configuration saved to: $dovecot_output_file"
else
    echo "Warning: No Dovecot SNI configuration generated." >&2
fi

# The files above point the mailserver at /etc/letsencrypt, which is
# root-only. Let DMS_OWNER (root inside a rootless container) read exactly
# the certificates that were mapped: traverse on the tree, read on the
# domain's live/ and archive/ entries.
#
# Re-run after every renewal (the a2tools deploy hook does): certbot writes
# new private keys 0600, whose ACL mask hides any named entry, so a default
# ACL alone would not survive.
grant_cert_access() {
    local user="$1" fqdn="$2" le=/etc/letsencrypt d
    setfacl -m "u:$user:x" "$le" "$le/live" "$le/archive" || return 1
    for d in "$le/live/$fqdn" "$le/archive/$fqdn"; do
        [ -d "$d" ] || continue
        setfacl -m "u:$user:rx" "$d" || return 1
    done
    if [ -d "$le/archive/$fqdn" ]; then
        find "$le/archive/$fqdn" -type f -exec setfacl -m "u:$user:r" -m "m::r" {} + || return 1
    fi
}

if [ -n "${DMS_OWNER:-}" ] && [ "$DMS_OWNER" != root ]; then
    if ! command -v setfacl >/dev/null 2>&1; then
        echo "Error: setfacl not installed; $DMS_OWNER cannot read the certificates." >&2
        exit 1
    fi
    if ! id -u "$DMS_OWNER" >/dev/null 2>&1; then
        echo "Error: DMS_OWNER '$DMS_OWNER' is not a user on this host." >&2
        exit 1
    fi
    for fqdn in "${!server_names[@]}"; do
        [ -f "/etc/letsencrypt/live/$fqdn/privkey.pem" ] || continue
        if grant_cert_access "$DMS_OWNER" "$fqdn"; then
            echo "Certificate read access for $DMS_OWNER: $fqdn"
        else
            echo "Warning: could not grant $DMS_OWNER read access to $fqdn" >&2
        fi
    done
fi
