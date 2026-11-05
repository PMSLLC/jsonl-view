#!/bin/bash
# Builds a Developer ID signed, notarized and stapled JSONLView.app and zips it into dist/.
# Needs the "Developer ID Application" certificate for team 997DW79YCR in the login keychain and an
# App Store Connect API key: ASC_KEY_ID and ASC_ISSUER_ID in ~/.env (or the environment), with the
# key at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
# Usage: scripts/release.sh   (version comes from App/Info.plist CFBundleShortVersionString)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean; commit first so the release matches a commit." >&2
  exit 1
fi

# Read ASC_* from ~/.env without `source`, so a `$` in a value is never expanded.
if [[ -f "$HOME/.env" ]]; then
  while IFS='=' read -r k v; do
    k="${k#export }"
    case "$k" in
      ASC_KEY_ID) : "${ASC_KEY_ID:=$v}" ;;
      ASC_ISSUER_ID) : "${ASC_ISSUER_ID:=$v}" ;;
    esac
  done < "$HOME/.env"
fi
KEY_ID="${ASC_KEY_ID:?set ASC_KEY_ID}"
ISSUER="${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
[[ -f "$KEY_PATH" ]] || { echo "API key not found at $KEY_PATH" >&2; exit 1; }

# Two "Developer ID Application: John Brahy" certificates are in the keychain, so sign by SHA-1
# (the newer one, valid to 2027-02-01). Override with DEVID_IDENTITY.
IDENTITY="${DEVID_IDENTITY:-D46BD6FADEBC7C1307B5E226F4779A27C3CCA42F}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist)"
DERIVED="$PWD/build-release"
APP="$DERIVED/Build/Products/Release/JSONLView.app"
DIST="$PWD/dist"
ZIP="$DIST/JSONLView-$VERSION.zip"

xcodegen generate
xcodebuild -project JSONLView.xcodeproj -scheme JSONLView -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM=997DW79YCR PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  clean build

codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$DIST"
rm -f -- "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Re-zip so the download carries the stapled ticket.
rm -f -- "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "Release zip: $ZIP"
