#!/bin/bash
# Builds the SwiftPM executable and wraps it into "build/PiP Anywhere.app"
# (ad-hoc signed, for local use). Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/PiP Anywhere.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PiPAnywhere" "$APP/Contents/MacOS/PiPAnywhere"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SIGN_IDENTITY (e.g. an "Apple Development: …" certificate) keeps the signature
# stable across builds, so Screen Recording / Accessibility grants survive rebuilds.
# Without it the app is ad-hoc signed.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
