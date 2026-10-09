#!/bin/bash
# Regenerates every icon from scripts/make-icon.swift:
#   app:       Support/AppIcon.icns (16–1024 px, @1x and @2x)
#   extension: extension/static/icons/icon-{16,32,48,128}.png
#   README:    docs/images/icon.png
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER=Support/AppIcon-1024.png
swift scripts/make-icon.swift "$MASTER"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Support/AppIcon.icns

for size in 16 32 48 128; do
  sips -z $size $size "$MASTER" --out "../extension/static/icons/icon-$size.png" >/dev/null
done
sips -z 256 256 "$MASTER" --out ../docs/images/icon.png >/dev/null
echo "Icons written."
