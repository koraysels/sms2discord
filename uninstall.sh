#!/usr/bin/env bash
# Remove sms2discord from the router. SMS in the inbox are never touched.
#
#   ./uninstall.sh           # keeps /etc/config/sms2discord and /etc/sms2discord (state)
#   ./uninstall.sh --purge   # also deletes the config, webhook URL and bot token
set -euo pipefail

HOST="${HOST:-root@192.168.8.1}"
# one password prompt per run: the first connection becomes a shared master
SSH=(ssh -o LogLevel=ERROR -o ControlMaster=auto -o ControlPersist=60
	-o "ControlPath=${SSH_CONTROL:-$HOME/.ssh/cm-%r@%h:%p}")
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

"${SSH[@]}" "$HOST" "PURGE=$PURGE sh -s" <<'REMOTE'
opkg list-installed | grep -q '^luci-app-sms2discord ' && opkg remove luci-app-sms2discord
opkg list-installed | grep -q '^sms2discord ' && opkg remove sms2discord
# files from copy-based installs before v0.3
[ -x /etc/init.d/sms2discord ] && { /etc/init.d/sms2discord stop; /etc/init.d/sms2discord disable; }
rm -f /etc/init.d/sms2discord /usr/bin/sms2discord
rm -rf /tmp/sms2discord
sed -i '/sms2discord/d' /etc/sysupgrade.conf
if [ "$PURGE" = 1 ]; then
	rm -rf /etc/sms2discord /etc/config/sms2discord
	echo "removed, config and secrets purged"
else
	echo "removed, config kept in /etc/config/sms2discord"
fi
REMOTE
