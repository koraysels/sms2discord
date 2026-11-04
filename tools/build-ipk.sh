#!/usr/bin/env bash
# Build dist/sms2discord_<version>_all.ipk without the OpenWrt SDK.
# The package is pure Lua + shell, so one .ipk fits every architecture.
# opkg's format: a gzipped tar of debian-binary, control.tar.gz, data.tar.gz.
set -euo pipefail
cd "$(dirname "$0")/.."

PKG=package/sms2discord
VERSION=$(sed -n 's/^PKG_VERSION:=//p' "$PKG/Makefile")-$(sed -n 's/^PKG_RELEASE:=//p' "$PKG/Makefile")
OUT="dist/sms2discord_${VERSION}_all.ipk"

if tar --version 2>/dev/null | grep -q GNU; then
	TAR=(tar --format=gnu --owner=0 --group=0 --numeric-owner)
else
	TAR=(tar --format=ustar --uid 0 --gid 0 --uname root --gname root --no-mac-metadata)
fi
export COPYFILE_DISABLE=1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/data/usr/bin" "$WORK/data/etc/init.d" "$WORK/control" "$WORK/pkg"
install -m 755 "$PKG/files/sms2discord.lua" "$WORK/data/usr/bin/sms2discord"
install -m 755 "$PKG/files/sms2discord.init" "$WORK/data/etc/init.d/sms2discord"

SIZE=$(du -sk "$WORK/data" | cut -f1)
cat > "$WORK/control/control" <<CONTROL
Package: sms2discord
Version: $VERSION
Depends: libc, smstools3, lua, lua-cjson, curl
Source: https://github.com/koraysels/sms2discord
SourceName: sms2discord
License: MIT
Section: utils
URL: https://github.com/koraysels/sms2discord
Maintainer: Koray Sels <koray.sels@gmail.com>
Architecture: all
Installed-Size: $((SIZE * 1024))
Description: Two-way SMS to Discord bridge for smstools3 (OpenWrt, GL.iNet 4.x)
CONTROL
# keep these in sync with Package/sms2discord/postinst and prerm in the Makefile
cat > "$WORK/control/postinst" <<'SCRIPT'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/sms2discord enable
/etc/init.d/sms2discord restart
exit 0
SCRIPT
cat > "$WORK/control/prerm" <<'SCRIPT'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/sms2discord stop
/etc/init.d/sms2discord disable
exit 0
SCRIPT
chmod 755 "$WORK/control/postinst" "$WORK/control/prerm"
echo "2.0" > "$WORK/pkg/debian-binary"

(cd "$WORK/control" && "${TAR[@]}" -czf "$WORK/pkg/control.tar.gz" ./control ./postinst ./prerm)
(cd "$WORK/data" && "${TAR[@]}" -czf "$WORK/pkg/data.tar.gz" ./usr ./etc)
mkdir -p dist
(cd "$WORK/pkg" && "${TAR[@]}" -czf "$OLDPWD/$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz)
echo "$OUT"
