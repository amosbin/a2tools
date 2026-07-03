#!/bin/bash

# Check for optional domain argument (format: subdomain.* e.g., mail.*)
WILDCARD_DOMAIN="$1"

# Directory containing Apache site config files
CONFIG_DIR="/etc/apache2/sites-available"

# Arrays to hold unique server names
declare -a wildcard_servers
declare -a domain_servers

# Function to check if an element is in an array
contains() {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

# Get next available config number for swc prefix (0)
# Returns the full filename: 0-NNNN-name.conf
get_next_swc_config_number() {
    local name="$1"
    local prefix="0"
    
    # Check if a config with this name already exists (any number)
    local existing=$(ls -1 "$CONFIG_DIR"/${prefix}-????-${name}.conf 2>/dev/null | head -n1)
    if [ -n "$existing" ]; then
        basename "$existing"
        return 0
    fi
    
    # Collect all existing numbers for this prefix
    declare -A used_numbers
    for file in "$CONFIG_DIR"/${prefix}-????-*.conf; do
        [ -f "$file" ] || continue
        local num=$(basename "$file" | sed -E 's/^[0-9]-([0-9]{4})-.*\.conf$/\1/')
        if [[ "$num" =~ ^[0-9]{4}$ ]]; then
            used_numbers["$num"]=1
        fi
    done
    
    # Find the first available number (filling gaps)
    local next_num=0
    while [ $next_num -le 9999 ]; do
        local padded=$(printf "%04d" $next_num)
        if [[ ! -v used_numbers[$padded] ]]; then
            echo "${prefix}-${padded}-${name}.conf"
            return 0
        fi
        ((next_num++))
    done
    
    echo "Error: No available config numbers for prefix $prefix" >&2
    return 1
}

# Find existing config file for a subdomain (checks both old and new naming)
find_existing_swc_config() {
    local name="$1"
    
    # Check new naming pattern first: 0-XXXX-name.conf
    local new_pattern=$(ls -1 "$CONFIG_DIR"/0-????-${name}.conf 2>/dev/null | head -n1)
    if [ -n "$new_pattern" ]; then
        echo "$new_pattern"
        return 0
    fi
    
    # Check old naming pattern: name.conf
    if [ -f "$CONFIG_DIR/${name}.conf" ]; then
        echo "$CONFIG_DIR/${name}.conf"
        return 0
    fi
    
    return 1
}

# If a wildcard domain is specified, use only that domain
if [[ -n "$WILDCARD_DOMAIN" ]]; then
    wildcard_servers=("$WILDCARD_DOMAIN")
else
    # Loop through all config files to find wildcard domains (check both old and new naming patterns)
    for config_file in "$CONFIG_DIR"/*.conf; do
        if [[ -f "$config_file" ]]; then
            # Extract ServerName values (allow leading whitespace in config files)
            server_names=$(grep -iE '^\s*ServerName' "$config_file" | awk '{print $2}')
            for server_name in $server_names; do
                # Check for wildcard format: text.*
                if [[ "$server_name" =~ ^[a-zA-Z0-9-]+\.\*$ ]]; then
                    if ! contains "$server_name" "${wildcard_servers[@]}"; then
                        wildcard_servers+=("$server_name")
                    fi
                fi
            done
        fi
    done
fi

# Loop through all config files to find domain servers
for config_file in "$CONFIG_DIR"/*.conf; do
    if [[ -f "$config_file" ]]; then
        # Extract ServerName values (allow leading whitespace in config files)
        server_names=$(grep -iE '^\s*ServerName' "$config_file" | awk '{print $2}')
        for server_name in $server_names; do
            # Check for domain.extension format (e.g., example.com) - only base domains, not subdomains
            if [[ "$server_name" =~ ^[a-zA-Z0-9-]+\.[a-zA-Z]+$ ]]; then
                if ! contains "$server_name" "${domain_servers[@]}"; then
                    domain_servers+=("$server_name")
                fi
            fi
        done
    fi
done

# Output directory for new config files
OUTPUT_DIR="/etc/apache2/sites-available"

# Loop through each wildcard server
for wildcard in "${wildcard_servers[@]}"; do
    # Extract subdomain label from wildcard (e.g., "mail" from "mail.*")
    subdomain_label="${wildcard%%.*}"

    # If there are no non-wildcard domain servers delete the file if it exists and continue
    if [ "${#domain_servers[@]}" -gt 0 ]; then
        # First, always create :80 VirtualHost entries with HTTPS redirect
        config_content=""
        for domain in "${domain_servers[@]}"; do
            # Create per-domain log directory for symlinks
            log_dir="/var/www/${subdomain_label}/logs/${domain}"
            if [ ! -d "$log_dir" ]; then
                mkdir -p "$log_dir"
                chown -R www-data:www-data "/var/www/${subdomain_label}"
            fi
            
            swc_fqdn="${subdomain_label}.${domain}"
            config_content="${config_content}<VirtualHost *:80>\n"
            config_content="${config_content}    ServerName ${swc_fqdn}\n"
            config_content="${config_content}    RewriteEngine On\n"
            config_content="${config_content}    RewriteCond %{HTTPS} !=on\n"
            config_content="${config_content}    RewriteRule ^(.*)\$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]\n"
            config_content="${config_content}    ErrorLog /var/log/apache-collector/${swc_fqdn}_error.log\n"
            config_content="${config_content}    CustomLog /var/log/apache-collector/${swc_fqdn}_access.log combined\n"
            config_content="${config_content}</VirtualHost>\n\n"
        done

        # Then append SSL :443 VirtualHosts for domains that have certificates
        ssl_blocks=""
        for domain in "${domain_servers[@]}"; do
            if [ -d "/etc/letsencrypt/live/${domain}" ]; then
                swc_fqdn="${subdomain_label}.${domain}"
                ssl_blocks="${ssl_blocks}    <VirtualHost *:443>\n"
                ssl_blocks="${ssl_blocks}        ServerName ${swc_fqdn}\n"
                ssl_blocks="${ssl_blocks}        SSLEngine on\n"
                ssl_blocks="${ssl_blocks}        SSLCertificateFile /etc/letsencrypt/live/${domain}/fullchain.pem\n"
                ssl_blocks="${ssl_blocks}        SSLCertificateKeyFile /etc/letsencrypt/live/${domain}/privkey.pem\n"
                ssl_blocks="${ssl_blocks}        DocumentRoot /var/www/${subdomain_label}/public_html\n"
                ssl_blocks="${ssl_blocks}        ErrorLog /var/log/apache-collector/${swc_fqdn}_ssl_error.log\n"
                ssl_blocks="${ssl_blocks}        CustomLog /var/log/apache-collector/${swc_fqdn}_ssl_access.log combined\n"
                ssl_blocks="${ssl_blocks}    </VirtualHost>\n\n"
            fi
        done

        if [ -n "$ssl_blocks" ]; then
            config_content="${config_content}<IfModule mod_ssl.c>\n${ssl_blocks}</IfModule>\n"
        fi
        
        # Check for existing config file (old or new naming)
        existing_config=$(find_existing_swc_config "$subdomain_label")
        
        if [ -n "$existing_config" ]; then
            # Update existing config file
            echo -e "$config_content" > "$existing_config"
            config_basename=$(basename "$existing_config" .conf)
        else
            # Create new config file with 0-XXXX prefix
            config_filename=$(get_next_swc_config_number "$subdomain_label")
            echo -e "$config_content" > "${OUTPUT_DIR}/${config_filename}"
            config_basename="${config_filename%.conf}"
        fi
        
        # Enable the site configuration
        if command -v a2ensite >/dev/null 2>&1; then
            a2ensite "$config_basename" >/dev/null 2>&1 || true
        fi
    else
        # No domain servers found, remove existing config file if it exists (both old and new naming)
        existing_config=$(find_existing_swc_config "$subdomain_label")
        if [ -n "$existing_config" ] && [ -f "$existing_config" ]; then
            config_basename=$(basename "$existing_config" .conf)
            # Disable the site before removing
            if command -v a2dissite >/dev/null 2>&1; then
                a2dissite "$config_basename" >/dev/null 2>&1 || true
            fi
            rm -f "$existing_config"
        fi
    fi
done

# Reload Apache to apply changes if any configs were modified
if command -v systemctl >/dev/null 2>&1; then
    systemctl reload apache2 >/dev/null 2>&1 || true
fi

# Create symlinks from per-domain log dirs to centralized log files
# (must happen after reload since Apache creates log files on reload)
for wildcard in "${wildcard_servers[@]}"; do
    subdomain_label="${wildcard%%.*}"
    for domain in "${domain_servers[@]}"; do
        swc_fqdn="${subdomain_label}.${domain}"
        log_dir="/var/www/${subdomain_label}/logs/${domain}"
        [ -d "$log_dir" ] || continue
        ln -sf "/var/log/apache-collector/${swc_fqdn}_error.log" "${log_dir}/error.log"
        ln -sf "/var/log/apache-collector/${swc_fqdn}_access.log" "${log_dir}/access.log"
        ln -sf "/var/log/apache-collector/${swc_fqdn}_ssl_error.log" "${log_dir}/ssl_error.log"
        ln -sf "/var/log/apache-collector/${swc_fqdn}_ssl_access.log" "${log_dir}/ssl_access.log"
    done
done
