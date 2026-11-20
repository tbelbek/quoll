#!/bin/bash
# Regenerates resources/AppIcon.icns from resources/make-icon.swift.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swift "$DIR/make-icon.swift" "$TMP/icon.png" >/dev/null
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$TMP/icon.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$TMP/icon.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$DIR/AppIcon.icns"
echo "wrote $DIR/AppIcon.icns"
