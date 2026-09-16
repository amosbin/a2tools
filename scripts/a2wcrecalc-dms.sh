#!/bin/bash
#
# -d / --dir selects the docker-mailserver directory (overrides $DMS_DIR and
# the built-in /opt/compose/docker-mailserver default).

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
then let the stack's owner (the rootless container's root) read each mapped
certificate.
DMS_DIR resolution order: -d/--dir flag, then \$DMS_DIR env, then
DMS_DIR from /etc/a2tools/a2tools.conf (or *.conf under
/etc/a2tools/a2tools.conf.d/), then /srv/podmgr/compose/dms, then
/opt/compose/docker-mailserver. The mapping files go to DMS_DIR/config or,
in the podmgr layout, DMS_DIR/data/config.

Options:
  -d, --dir DMS_DIR   Path to the docker-mailserver mount directory
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

if ! DMS_DIR="$(dms_resolve_dir "$DMS_DIR_CLI")"; then
    echo "DMS directory not found." >&2
    exit 1
fi
if ! DMS_CONFIG_DIR="$(dms_config_dir "$DMS_DIR")"; then
    echo "Config directory not found: $DMS_DIR/config/ or $DMS_DIR/data/config/" >&2
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
# root-only. Let the stack owner (root inside a rootless container) read
# exactly the certificates that were mapped.
dms_user="$(dms_owner "$DMS_DIR")"
if [ -z "$dms_user" ]; then
    echo "Warning: cannot tell who owns $DMS_DIR/compose.yaml; certificate read access not granted." >&2
elif [ "$dms_user" != root ]; then
    for fqdn in "${!server_names[@]}"; do
        [ -f "/etc/letsencrypt/live/$fqdn/privkey.pem" ] || continue
        if dms_grant_cert_access "$dms_user" "$fqdn"; then
            echo "Certificate read access for $dms_user: $fqdn"
        else
            echo "Warning: could not grant $dms_user read access to $fqdn" >&2
        fi
    done
fi
