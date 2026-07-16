#!/usr/bin/env bash
set -euo pipefail

# Toolchain: this machine's standalone CommandLineTools has a mismatched SwiftPM
# ManifestAPI (PackageDescription .swiftmodule newer than its .dylib), which breaks
# `swift build`. Xcode ships a consistent toolchain, so prefer it when available.
# Override by exporting DEVELOPER_DIR yourself, or make it permanent with:
#   sudo xcode-select -s /Applications/Xcode.app  (or update Command Line Tools).
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/FastMDReader"
APP="FastMDReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FastMDReader"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# bundle runtime resources (mermaid.min.js added in Task 5, etc.) — everything in Resources/ except
# build inputs that must not ship inside the bundle (Info.plist is placed above; entitlements are a
# signing input).
find Resources -type f ! -name 'Info.plist' ! -name '*.entitlements' -exec cp {} "$APP/Contents/Resources/" \;
# Ad-hoc sign so Gatekeeper allows local launch. Sign WITH the sandbox entitlements even for local
# builds: the App Store requires the sandbox, and a dev build that skips it would hide exactly the
# failures (file access, WKWebView) we need to catch before review.
codesign --force --sign - --entitlements Resources/FastMDReader.entitlements "$APP"
echo "Built $APP"
