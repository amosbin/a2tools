#!/bin/bash
if [ $# -gt 0 ] && [ -d "$1" ]; then
    DMS_DIR="$1"
else
    # Default to standard path when no argument provided or invalid argument
    if [ -d "/opt/compose/docker-mailserver" ]; then
        DMS_DIR="/opt/compose/docker-mailserver"
    else
        echo "DMS directory not found." >&2
        exit 1
    fi
fi
if [ ! -d "$DMS_DIR/docker-data/dms/config/" ]; then
    echo "Config directory not found: $DMS_DIR/docker-data/dms/config/" >&2
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
output_file="$DMS_DIR/docker-data/dms/config/sni_cert_map"

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
dovecot_output_file="$DMS_DIR/docker-data/dms/config/99-sni.conf"

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
