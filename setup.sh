#!/bin/bash
cp -R ./scripts/* /usr/local/bin/

# List of commands to install
COMMANDS=(
    "getinput"
    "a2sitemgr"
    "fqdnmgr"
    "fqdncredmgr"
    "a2wcrecalc"
    "a2wcrecalc-dms"
    "a2certrenew"
)

# Create symlinks and set permissions for each command
for cmd in "${COMMANDS[@]}"; do
    ln -sfn /usr/local/bin/${cmd}.d/${cmd}.sh /usr/local/bin/${cmd}
    chmod  0550 /usr/local/bin/${cmd}.d
    chmod  0550 /usr/local/bin/${cmd}.d/*
    chmod +x /usr/local/bin/${cmd}
    chmod 0100 /usr/local/bin/${cmd}
    chown root:root /usr/local/bin/${cmd}
done

# fqdnmgr-specific: copy providers
mkdir -p /etc/fqdnmgr
cp -R ./scripts/fqdnmgr.d/providers /etc/fqdnmgr/
chmod 0750 /etc/fqdnmgr/providers
chown -R root:root /etc/fqdnmgr/providers
cp ./uninstall.sh /usr/local/bin/a2sitemgr.d/uninstall.sh
chmod 0550 /usr/local/bin/a2sitemgr.d/uninstall.sh
chown root:root /usr/local/bin/a2sitemgr.d/uninstall.sh

# fqdnmgr-specific: install domain registration config template
cp ./scripts/fqdnmgr.d/domain.conf.tpl /etc/fqdnmgr/domain.conf.tpl
chmod 0640 /etc/fqdnmgr/domain.conf.tpl
chown root:root /etc/fqdnmgr/domain.conf.tpl
# Create default config if it doesn't exist
if [ ! -f /etc/fqdnmgr/domain.conf ]; then
    cp /etc/fqdnmgr/domain.conf.tpl /etc/fqdnmgr/domain.conf
    chmod 0640 /etc/fqdnmgr/domain.conf
    chown root:root /etc/fqdnmgr/domain.conf
fi

# Validate DOMAIN_CLEANUP_DAYS format (must be number + 'D'), append default if missing
if [ -f /etc/fqdnmgr/domain.conf ]; then
    # shellcheck disable=SC1090
    . /etc/fqdnmgr/domain.conf || true
    if ! echo "${DOMAIN_CLEANUP_DAYS-}" | grep -qE '^[0-9]+D$'; then
        # ensure there is a single default entry
        sed -i.bak '/^DOMAIN_CLEANUP_DAYS=/d' /etc/fqdnmgr/domain.conf 2>/dev/null || true
        echo 'DOMAIN_CLEANUP_DAYS="7D"' >> /etc/fqdnmgr/domain.conf
        chmod 0640 /etc/fqdnmgr/domain.conf
        chown root:root /etc/fqdnmgr/domain.conf
    fi
fi

# Setup fqdntools databases
mkdir -p /etc/fqdntools
sqlite3 /etc/fqdntools/domains.db < /usr/local/bin/fqdnmgr.d/schema.sql
chown root:root /etc/fqdntools/domains.db
chmod 0640 /etc/fqdntools/domains.db
sqlite3 /etc/fqdntools/creds.db < /usr/local/bin/fqdncredmgr.d/schema.sql
chown root:root /etc/fqdntools/creds.db
chmod 0600 /etc/fqdntools/creds.db
chown -R root:root /etc/fqdntools
chmod 0750 /etc/fqdntools

# Install fqdncredmgr daemon
ln -sfn /usr/local/bin/fqdncredmgr.d/fqdncredmgrd.sh /usr/local/bin/fqdncredmgrd
chmod +x /usr/local/bin/fqdncredmgrd
chown root:root /usr/local/bin/fqdncredmgrd
cp /usr/local/bin/fqdncredmgr.d/fqdncredmgrd.service /etc/systemd/system/
chmod 0644 /etc/systemd/system/fqdncredmgrd.service
systemctl daemon-reload
systemctl enable fqdncredmgrd
systemctl start fqdncredmgrd

# Install weekly cleanup wrapper into system cron (Ubuntu: /etc/cron.weekly)
if [ -f /usr/local/bin/fqdnmgr.d/cron.fqdnmgr_domain_cleanup ]; then
    cp /usr/local/bin/fqdnmgr.d/cron.fqdnmgr_domain_cleanup /etc/cron.weekly/fqdnmgr_domain_cleanup 2>/dev/null || true
fi
if [ -f /etc/cron.weekly/fqdnmgr_domain_cleanup ]; then
    chmod 0755 /etc/cron.weekly/fqdnmgr_domain_cleanup || true
    chown root:root /etc/cron.weekly/fqdnmgr_domain_cleanup || true
fi

# Install daily certificate renewal cron job (Ubuntu: /etc/cron.daily)
if [ -f /usr/local/bin/a2certrenew.d/cron.a2certrenew ]; then
    cp /usr/local/bin/a2certrenew.d/cron.a2certrenew /etc/cron.daily/a2certrenew 2>/dev/null || true
fi
if [ -f /etc/cron.daily/a2certrenew ]; then
    chmod 0755 /etc/cron.daily/a2certrenew || true
    chown root:root /etc/cron.daily/a2certrenew || true
fi

# Install logrotate config for centralized apache logs
cp /usr/local/bin/a2sitemgr.d/apache-collector.logrotate /etc/logrotate.d/apache-collector
chmod 0644 /etc/logrotate.d/apache-collector
chown root:root /etc/logrotate.d/apache-collector