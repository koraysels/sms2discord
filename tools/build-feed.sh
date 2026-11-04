#!/usr/bin/env bash
# Turn dist/*.ipk into an opkg feed in dist/feed/ (Packages, Packages.gz, *.ipk).
# Add it on the router as:  src/gz sms2discord https://koraysels.github.io/sms2discord/packages
set -euo pipefail
cd "$(dirname "$0")/.."

FEED=dist/feed
rm -rf "$FEED"
mkdir -p "$FEED"
: > "$FEED/Packages"
for ipk in dist/*_all.ipk; do
	case "$ipk" in *-[0-9]*_all.ipk) ;; *) continue ;; esac # skip the unversioned aliases
	cp "$ipk" "$FEED/"
	name=$(basename "$ipk")
	tar -xzOf "$ipk" ./control.tar.gz | tar -xzOf - ./control | sed '/^$/d' >> "$FEED/Packages"
	{
		echo "Filename: $name"
		echo "Size: $(wc -c < "$ipk" | tr -d ' ')"
		echo "SHA256sum: $(shasum -a 256 "$ipk" 2>/dev/null | cut -d' ' -f1 || sha256sum "$ipk" | cut -d' ' -f1)"
		echo
	} >> "$FEED/Packages"
done
gzip -9nc "$FEED/Packages" > "$FEED/Packages.gz"
echo "$FEED"
