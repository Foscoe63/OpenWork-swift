#!/usr/bin/env bash
# Build, sign, notarise and staple SwiftOpenWork.app, and produce the zip that goes on a release.
#
# Requires, for a real release:
#   - a "Developer ID Application" certificate in the login keychain
#   - an App Store Connect API key
#
# Usage:
#   export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
#   export APPLE_API_KEY_ID=...
#   export APPLE_API_ISSUER=...
#   export APPLE_API_KEY_PATH=$HOME/AuthKey_XXXX.p8
#   Scripts/notarize-release.sh [path/to/SwiftOpenWork.app]
#
# With no app path it builds Release itself. Output: build/release/SwiftOpenWork.zip.
#
#   SIGN_ONLY=1 DEVELOPER_ID_APP="SwiftOpenWork Local Signing" Scripts/notarize-release.sh
# runs everything up to submission with any identity, so the signing half can be checked on a
# machine that has no Developer ID. It does not produce something Gatekeeper will accept.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/Scripts/SwiftOpenWork-release.entitlements"
OUT="$ROOT/build/release"
SIGN_ONLY="${SIGN_ONLY:-0}"

: "${DEVELOPER_ID_APP:?Set DEVELOPER_ID_APP to your Developer ID Application identity}"
if [[ "$SIGN_ONLY" != "1" ]]; then
  : "${APPLE_API_KEY_ID:?Set APPLE_API_KEY_ID}"
  : "${APPLE_API_ISSUER:?Set APPLE_API_ISSUER}"
  : "${APPLE_API_KEY_PATH:?Set APPLE_API_KEY_PATH to the .p8 key file}"
fi

mkdir -p "$OUT"
APP_PATH="${1:-}"
if [[ -z "$APP_PATH" ]]; then
  echo "Building Release…"
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  xcodebuild build \
    -project "$ROOT/SwiftOpenWork.xcodeproj" \
    -scheme SwiftOpenWork \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$OUT/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' || true
  APP_PATH="$OUT/DerivedData/Build/Products/Release/SwiftOpenWork.app"
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "No app at $APP_PATH" >&2
  exit 1
fi

# Sign inside-out. `codesign --deep` is not supported for distribution: it applies the app's
# entitlements to every nested binary and misses code in resource bundles.
sign() {
  codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APP" "$@"
}
echo "Signing nested code…"
while IFS= read -r -d '' item; do
  sign "$item"
done < <(find "$APP_PATH/Contents" \( -name '*.dylib' -o -name '*.so' \) -type f -print0)
while IFS= read -r -d '' item; do
  sign "$item"
done < <(find "$APP_PATH/Contents" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -type d -print0)

echo "Signing the app…"
sign --entitlements "$ENTITLEMENTS" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q 'device.audio-input' \
  || { echo "The app lost its entitlements while signing." >&2; exit 1; }

if [[ "$SIGN_ONLY" == "1" ]]; then
  echo "SIGN_ONLY: signed and verified with '$DEVELOPER_ID_APP'. Not submitted."
  exit 0
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto -c -k --keepParent "$APP_PATH" "$STAGING/submit.zip"

echo "Submitting for notarisation…"
xcrun notarytool submit "$STAGING/submit.zip" \
  --key "$APPLE_API_KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER" \
  --wait

echo "Stapling…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

# Zip after stapling. The zip submitted above predates the ticket, so shipping it would make
# first launch depend on Gatekeeper reaching Apple — which is the case stapling exists for.
rm -f "$OUT/SwiftOpenWork.zip"
ditto -c -k --keepParent "$APP_PATH" "$OUT/SwiftOpenWork.zip"
echo "Done: $OUT/SwiftOpenWork.zip"
