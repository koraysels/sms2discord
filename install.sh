#!/usr/bin/env bash
# Install or update sms2discord on a GL.iNet router over SSH.
#
#   ./install.sh                      # root@192.168.8.1 (GL.iNet default)
#   HOST=root@10.0.0.1 ./install.sh
#   SSH_CONTROL=~/.ssh/my-socket ./install.sh     # reuse a specific SSH master socket
#   ./install.sh --keep-on-upgrade    # also keep files across firmware upgrades
set -euo pipefail
cd "$(dirname "$0")"

HOST="${HOST:-root@192.168.8.1}"
# one password prompt per run: the first connection becomes a shared master
SSH=(ssh -o LogLevel=ERROR -o ControlMaster=auto -o ControlPersist=60
	-o "ControlPath=${SSH_CONTROL:-$HOME/.ssh/cm-%r@%h:%p}")
KEEP=0
[ "${1:-}" = "--keep-on-upgrade" ] && KEEP=1

put() { # put <local> <remote> <mode>  (no scp: dropbear has no sftp-server)
	"${SSH[@]}" "$HOST" "cat > '$2.new' && chmod $3 '$2.new' && mv '$2.new' '$2'" < "$1"
}

echo "==> checking router"
"${SSH[@]}" "$HOST" 'test -x /usr/bin/smsd && { test -f /tmp/smstools.cfg || test -f /etc/smsd.conf; } && lua -e "require \"cjson\"" && command -v curl >/dev/null' \
	|| { echo "router is missing smsd, smstools config, lua-cjson or curl" >&2; exit 1; }

echo "==> self-test"
"${SSH[@]}" "$HOST" 'lua - selftest' < package/sms2discord/files/sms2discord.lua

echo "==> copying files"
"${SSH[@]}" "$HOST" 'mkdir -p /etc/sms2discord && chmod 700 /etc/sms2discord'
put package/sms2discord/files/sms2discord.lua /usr/bin/sms2discord 755
put package/sms2discord/files/sms2discord.init /etc/init.d/sms2discord 755

if [ "$KEEP" = 1 ]; then
	echo "==> adding to /etc/sysupgrade.conf"
	"${SSH[@]}" "$HOST" 'for f in /etc/sms2discord/ /usr/bin/sms2discord /etc/init.d/sms2discord; do grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf; done'
fi

echo "==> enabling service"
"${SSH[@]}" "$HOST" '/etc/init.d/sms2discord enable; if [ -s /etc/sms2discord/config ]; then /etc/init.d/sms2discord restart; echo started; else echo "not configured yet"; fi'

cat <<MSG

Done. If not configured yet, run in your own terminal (input stays local):
  ssh -t $HOST sms2discord setup
  ssh $HOST /etc/init.d/sms2discord restart
Status:
  ssh $HOST sms2discord status
MSG
