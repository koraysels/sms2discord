#!/usr/bin/env bash
# Build the packages and install them on a router over SSH.
#
#   ./install.sh                      # root@192.168.8.1 (GL.iNet default)
#   HOST=root@10.0.0.1 ./install.sh
#   ./install.sh --no-luci            # daemon only
#   ./install.sh --keep-on-upgrade    # also keep the files across firmware upgrades
#   ./install.sh --reinstall          # reinstall even if the version didn't change
set -euo pipefail
cd "$(dirname "$0")"

HOST="${HOST:-root@192.168.8.1}"
# one password prompt per run: the first connection becomes a shared master
SSH=(ssh -o LogLevel=ERROR -o ControlMaster=auto -o ControlPersist=60
	-o "ControlPath=${SSH_CONTROL:-$HOME/.ssh/cm-%r@%h:%p}")
LUCI=1 KEEP=0 OPKG="opkg install"
for a in "$@"; do
	case "$a" in
		--no-luci) LUCI=0 ;;
		--keep-on-upgrade) KEEP=1 ;;
		--reinstall) OPKG="opkg install --force-reinstall" ;;
		*) echo "unknown option: $a" >&2; exit 2 ;;
	esac
done

echo "==> building packages"
pkgs=$(tools/build-ipk.sh)
[ "$LUCI" = 1 ] || pkgs=$(echo "$pkgs" | grep -v luci-app)

echo "==> checking router"
"${SSH[@]}" "$HOST" 'test -x /usr/bin/smsd && { test -f /tmp/smstools.cfg || test -f /etc/smsd.conf; }' \
	|| { echo "router has no smstools3 (smsd) set up" >&2; exit 1; }

echo "==> self-test"
"${SSH[@]}" "$HOST" 'lua - selftest' < package/sms2discord/files/sms2discord.lua

echo "==> installing"
remote=()
for p in $pkgs; do # daemon first: the LuCI app depends on it
	"${SSH[@]}" "$HOST" "cat > '/tmp/$(basename "$p")'" < "$p"
	remote+=("/tmp/$(basename "$p")")
done
"${SSH[@]}" "$HOST" "$OPKG ${remote[*]} || { opkg update && $OPKG ${remote[*]}; }; rm -f ${remote[*]}"

if [ "$KEEP" = 1 ]; then
	echo "==> adding to /etc/sysupgrade.conf"
	"${SSH[@]}" "$HOST" 'for f in /etc/sms2discord/ /usr/bin/sms2discord /etc/init.d/sms2discord \
		/www/luci-static/resources/view/sms2discord.js /usr/share/luci/menu.d/luci-app-sms2discord.json \
		/usr/share/rpcd/acl.d/luci-app-sms2discord.json; do
		[ -e "$f" ] && { grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf; }; done'
fi

cat <<MSG

Done. Configure in LuCI (Services → SMS to Discord) or in a terminal:
  ssh -t $HOST sms2discord setup
Status:
  ssh $HOST sms2discord status
MSG
