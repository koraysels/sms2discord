#!/usr/bin/env bash
# Remove sms2discord from the router. SMS in the inbox are never touched.
#
#   ./uninstall.sh           # keeps /etc/sms2discord (config + state)
#   ./uninstall.sh --purge   # also deletes config, webhook URL and bot token
set -euo pipefail

HOST="${HOST:-root@192.168.8.1}"
# one password prompt per run: the first connection becomes a shared master
SSH=(ssh -o LogLevel=ERROR -o ControlMaster=auto -o ControlPersist=60
	-o "ControlPath=${SSH_CONTROL:-$HOME/.ssh/cm-%r@%h:%p}")
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

"${SSH[@]}" "$HOST" "PURGE=$PURGE sh -s" <<'REMOTE'
[ -x /etc/init.d/sms2discord ] && { /etc/init.d/sms2discord stop; /etc/init.d/sms2discord disable; }
rm -f /etc/init.d/sms2discord /usr/bin/sms2discord
rm -rf /tmp/sms2discord
sed -i '\#^/etc/sms2discord/$#d;\#^/usr/bin/sms2discord$#d;\#^/etc/init.d/sms2discord$#d' /etc/sysupgrade.conf
if [ "$PURGE" = 1 ]; then rm -rf /etc/sms2discord; echo "removed, config purged"; else echo "removed, config kept in /etc/sms2discord"; fi
REMOTE
