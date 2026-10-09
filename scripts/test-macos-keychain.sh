#!/bin/bash
# Run only in a logged-in user context with a usable distribution identity.
set -euo pipefail
APP_PATH=$1
IDENTITY=$2
ENTITLEMENTS=$3
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/iris-keychain-probe.XXXXXX")
trap 'rm -r "$ROOT"' EXIT
PROBE="$ROOT/KeychainProbe.app"
mkdir -p "$PROBE/Contents/MacOS"
cp "$APP_PATH/Contents/Info.plist" "$PROBE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable KeychainProbe' "$PROBE/Contents/Info.plist"
if [[ -f "$APP_PATH/Contents/embedded.provisionprofile" ]]; then
  cp "$APP_PATH/Contents/embedded.provisionprofile" "$PROBE/Contents/embedded.provisionprofile"
fi
xcrun swiftc -parse-as-library \
  packages/IrisKit/Sources/IrisKit/HubCredentials.swift \
  scripts/macos-keychain-probe.swift -o "$PROBE/Contents/MacOS/KeychainProbe"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$PROBE"
codesign --verify --strict "$PROBE"
"$PROBE/Contents/MacOS/KeychainProbe"
