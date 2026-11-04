#!/usr/bin/env bash
# Build dist/sms2discord_*.ipk and dist/luci-app-sms2discord_*.ipk without the
# OpenWrt SDK. Both packages are pure Lua/JS/shell, so they fit every architecture.
# opkg's format: a gzipped tar of debian-binary, control.tar.gz, data.tar.gz.
set -euo pipefail
cd "$(dirname "$0")/.."

if tar --version 2>/dev/null | grep -q GNU; then
	TAR=(tar --format=gnu --owner=0 --group=0 --numeric-owner)
else
	TAR=(tar --format=ustar --uid 0 --gid 0 --uname root --gname root --no-mac-metadata)
fi
export COPYFILE_DISABLE=1
mkdir -p dist

version() { # version <Makefile>
	echo "$(sed -n 's/^PKG_VERSION:=//p' "$1")-$(sed -n 's/^PKG_RELEASE:=//p' "$1")"
}

# build <name> <version> <depends> <description> <data dir> <control dir>
build() {
	local name=$1 ver=$2 deps=$3 desc=$4 data=$5 ctl=$6 pkg size out
	pkg=$(mktemp -d)
	size=$(du -sk "$data" | cut -f1)
	cat > "$ctl/control" <<CONTROL
Package: $name
Version: $ver
Depends: $deps
Source: https://github.com/koraysels/sms2discord
SourceName: $name
License: MIT
Section: $( [ "${name#luci-}" != "$name" ] && echo luci || echo utils )
URL: https://github.com/koraysels/sms2discord
Maintainer: Koray Sels <koray.sels@gmail.com>
Architecture: all
Installed-Size: $((size * 1024))
Description: $desc
CONTROL
	echo "2.0" > "$pkg/debian-binary"
	(cd "$ctl" && "${TAR[@]}" -czf "$pkg/control.tar.gz" .)
	(cd "$data" && "${TAR[@]}" -czf "$pkg/data.tar.gz" .)
	out="dist/${name}_${ver}_all.ipk"
	(cd "$pkg" && "${TAR[@]}" -czf "$OLDPWD/$out" ./debian-binary ./control.tar.gz ./data.tar.gz)
	rm -rf "$pkg"
	echo "$out"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- sms2discord (mirrors Package/sms2discord/install in its Makefile)
P=package/sms2discord
D=$WORK/d1 C=$WORK/c1
mkdir -p "$D/usr/bin" "$D/etc/init.d" "$D/etc/config" "$D/etc/uci-defaults" "$C"
install -m 755 "$P/files/sms2discord.lua" "$D/usr/bin/sms2discord"
install -m 755 "$P/files/sms2discord.init" "$D/etc/init.d/sms2discord"
install -m 600 "$P/files/sms2discord.config" "$D/etc/config/sms2discord"
install -m 755 "$P/files/sms2discord.uci-defaults" "$D/etc/uci-defaults/90-sms2discord"
echo "/etc/config/sms2discord" > "$C/conffiles"
# same steps as OpenWrt's default_postinst / default_prerm
cat > "$C/postinst" <<'SCRIPT'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
if [ -f /etc/uci-defaults/90-sms2discord ]; then
	( . /etc/uci-defaults/90-sms2discord ) && rm -f /etc/uci-defaults/90-sms2discord
fi
/etc/init.d/sms2discord enable
/etc/init.d/sms2discord restart
exit 0
SCRIPT
cat > "$C/prerm" <<'SCRIPT'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/sms2discord stop
/etc/init.d/sms2discord disable
exit 0
SCRIPT
chmod 755 "$C/postinst" "$C/prerm"
build sms2discord "$(version $P/Makefile)" "libc, smstools3, lua, lua-cjson, libuci-lua, curl" \
	"Two-way SMS to Discord bridge for smstools3 (OpenWrt, GL.iNet 4.x)" "$D" "$C"

# --- luci-app-sms2discord (mirrors what luci.mk installs)
P=package/luci-app-sms2discord
D=$WORK/d2 C=$WORK/c2
mkdir -p "$D/www" "$C"
cp -R "$P/htdocs/." "$D/www/"
cp -R "$P/root/." "$D/"
find "$D" -type d -exec chmod 755 {} + && find "$D" -type f -exec chmod 644 {} +
# same as luci.mk's postinst: drop LuCI caches, reload ACLs
cat > "$C/postinst" <<'SCRIPT'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
killall -HUP rpcd 2>/dev/null
exit 0
SCRIPT
cp "$C/postinst" "$C/postrm"
chmod 755 "$C/postinst" "$C/postrm"
build luci-app-sms2discord "$(version $P/Makefile)" "libc, luci-base, sms2discord" \
	"LuCI support for sms2discord" "$D" "$C"
