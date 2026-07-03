#!/bin/bash
# this is not a package, but I hate it when you try to purge one, there are always leftovers behind
# let's make this world a tiny bit better but having a new habit/good practice by designing responsible uninstallers and make everyone's life easy.

set -euo pipefail
if [[ $(id -u) -ne 0 ]]; then
	printf "This script must be run as root. Exiting.\n" >&2
	exit 1
fi
COMMANDS=(
	"getinput"
	"a2sitemgr"
	"fqdnmgr"
	"fqdncredmgr"
	"a2wcrecalc"
	"a2wcrecalc-dms"
	"a2certrenew"
)
for cmd in "${COMMANDS[@]}"; do
	rm -dfr -- "/usr/local/bin/${cmd}" || true
	rm -dfr -- "/usr/local/bin/${cmd}.d" || true
done

# Stop and remove fqdncredmgr daemon
systemctl stop fqdncredmgrd 2>/dev/null || true
systemctl disable fqdncredmgrd 2>/dev/null || true
rm -f /etc/systemd/system/fqdncredmgrd.service || true
systemctl daemon-reload 2>/dev/null || true
rm -f /usr/local/bin/fqdncredmgrd || true
rm -f /run/fqdncredmgr.sock || true

rm -dfr -- /etc/fqdnmgr || true
rm -dfr -- /etc/fqdntools || true
rm -dfr -- /var/log/fqdnmgr || true
rm -dfr /etc/cron.weekly/fqdnmgr_domain_cleanup || true
rm -dfr /etc/cron.daily/a2certrenew || true
rm -dfr -- /var/log/a2certrenew.log || true
rm -dfr -- /tmp/a2tools.cache || true
exit 0
