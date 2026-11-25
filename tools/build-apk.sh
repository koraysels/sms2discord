#!/bin/bash
# Builds sms2discord + luci-app-sms2discord as OpenWrt 25+ .apk packages and a
# signed packages.adb index. Runs inside the openwrt/sdk image (apk-based release).
# Usage: build-apk.sh <repo-dir> <out-dir> <private-key.pem>
set -euo pipefail
SRC=$1 OUT=$2 KEY=$3
cd /builder
[ -f feeds.conf.default ] || bash setup.sh >/dev/null
[ -f feeds.conf ] || cp feeds.conf.default feeds.conf
./scripts/feeds update base packages luci >/dev/null
./scripts/feeds install lua-cjson smstools3 curl libuci-lua luci-base >/dev/null
cp "$KEY" private-key.pem # the SDK signs packages with this key
openssl ec -in private-key.pem -pubout -out public-key.pem 2>/dev/null
rm -rf package/sms2discord package/luci-app-sms2discord
cp -r "$SRC/package/sms2discord" "$SRC/package/luci-app-sms2discord" package/
make defconfig >/dev/null
for p in sms2discord luci-app-sms2discord; do
	make "package/$p/compile" V=s >"$OUT/$p.log" 2>&1 || { tail -40 "$OUT/$p.log"; exit 1; }
done
mkdir -p "$OUT/apk"
find bin -name '*sms2discord*.apk' -exec cp {} "$OUT/apk/" \;
APK=staging_dir/host/bin/apk
"$APK" mkndx --allow-untrusted --sign-key private-key.pem --output "$OUT/apk/packages.adb" "$OUT"/apk/*.apk \
	|| { "$APK" mkndx --help; exit 1; }
ls -l "$OUT/apk"
