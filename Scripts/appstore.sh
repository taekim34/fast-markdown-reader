#!/usr/bin/env bash
set -euo pipefail

# Build and upload the Mac App Store package: release build -> embed the provisioning profile ->
# sign with Apple Distribution -> wrap in a signed .pkg -> validate/upload to App Store Connect.
#
# This is the App Store track and is SEPARATE from Scripts/notarize.sh (the Developer ID track for
# handing a zip to someone directly). The store does its own notarization during review, so nothing
# here talks to notarytool.
#
# Usage:
#   ./Scripts/appstore.sh            # build + validate only (safe; does not submit)
#   ./Scripts/appstore.sh --upload   # build + validate + upload to App Store Connect
#
# Signing material lives OUTSIDE this repo, in a dedicated keychain:
#   ~/Documents/DEV/ww-w-ai/.keychains/   (see docs/NOTARIZATION.md)

KEYCHAIN_DIR="${KEYCHAIN_DIR:-$HOME/Documents/DEV/ww-w-ai/.keychains}"
KEYCHAIN="$KEYCHAIN_DIR/ww-w-signing.keychain-db"
PROFILE="${PROVISION_PROFILE:-$KEYCHAIN_DIR/Fast_Markdown_Reader_MAS.provisionprofile}"
APP_IDENTITY="${APP_IDENTITY:-Apple Distribution: DubDubDub Corp. (GTX7V638TX)}"
PKG_IDENTITY="${PKG_IDENTITY:-3rd Party Mac Developer Installer: DubDubDub Corp. (GTX7V638TX)}"
API_KEY_ID="${API_KEY_ID:-REDACTED-KEY-ID}"
API_ISSUER="${API_ISSUER:-REDACTED-ISSUER}"
APP="FastMDReader.app"
PKG="FastMDReader.pkg"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

echo "==> Unlocking the signing keychain"
KC_PW="$(security find-generic-password -a ww-w-signing -s ww-w-signing-keychain -w)"
security unlock-keychain -p "$KC_PW" "$KEYCHAIN"

echo "==> Building release"
./Scripts/make-app.sh release

echo "==> Embedding the provisioning profile"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "==> Signing with Apple Distribution (App Store entitlements)"
# Hardened runtime is not required for the store (the sandbox is), and --deep is deprecated —
# the bundle is a single binary anyway.
codesign --force --timestamp --keychain "$KEYCHAIN" \
  --entitlements Resources/FastMDReader-mas.entitlements \
  --sign "$APP_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Building the signed installer package"
rm -f "$PKG"
productbuild --component "$APP" /Applications \
  --keychain "$KEYCHAIN" --sign "$PKG_IDENTITY" "$PKG"

ACTION="--validate-app"
[[ "${1:-}" == "--upload" ]] && ACTION="--upload-app"
echo "==> Running altool $ACTION (this is the step that proves an SPM-built, hand-signed"
echo "    package is acceptable to App Store Connect)"
xcrun altool "$ACTION" -f "$PKG" -t macos \
  --apiKey "$API_KEY_ID" --apiIssuer "$API_ISSUER"

echo
if [[ "$ACTION" == "--validate-app" ]]; then
  echo "Validation passed. Re-run with --upload to submit: ./Scripts/appstore.sh --upload"
else
  echo "Uploaded. Check App Store Connect — the build takes a few minutes to finish processing."
fi
