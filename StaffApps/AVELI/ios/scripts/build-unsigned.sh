#!/bin/bash
# Build on macOS with Xcode. AltStore or Sideloadly signs the resulting IPA.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  printf '%s\n' 'Usage: ./ios/scripts/build-unsigned.sh' '' \
    'Requires macOS and a full Xcode installation. No Apple Developer membership is needed.' \
    'Output: ios/build/artifacts/semeynyy-arkhiv-zhivaya-pamyat-aveli-1.0.4-b5-unsigned.ipa (not signed for direct installation).'
  exit 0
fi
if [[ "$#" -ne 0 ]]; then
  printf '%s\n' 'This command takes no arguments. Use --help for details.' >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'iOS compilation requires macOS with Xcode. Run the AVELI iOS IPA GitHub Actions workflow instead.' >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  printf '%s\n' 'Install Xcode and select it with xcode-select before building.' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="$REPO_ROOT/ios/AVELI.xcodeproj"
BUILD_DIR="$REPO_ROOT/ios/build"
DERIVED_DIR="$BUILD_DIR/DerivedData"
ARTIFACT_DIR="$BUILD_DIR/artifacts"
STAGING_DIR="$BUILD_DIR/ipa-staging"
PAYLOAD_DIR="$STAGING_DIR/Payload"
IPA_NAME="semeynyy-arkhiv-zhivaya-pamyat-aveli-1.0.4-b5-unsigned.ipa"
IPA_PATH="$ARTIFACT_DIR/$IPA_NAME"

# Remove only generated packaging output. Never package a stale IPA after a failed build.
mkdir -p "$BUILD_DIR"
rm -rf "$ARTIFACT_DIR" "$STAGING_DIR"
mkdir -p "$ARTIFACT_DIR" "$PAYLOAD_DIR"
python3 "$REPO_ROOT/ios/scripts/check-native-contract.py"
python3 "$REPO_ROOT/ios/scripts/generate-project.py"

xcodebuild \
  -project "$PROJECT" \
  -scheme AVELI \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build

APP_PATH="$DERIVED_DIR/Build/Products/Release-iphoneos/AVELI.app"
APP_PLIST="$APP_PATH/Info.plist"
if [[ ! -d "$APP_PATH" || ! -f "$APP_PLIST" ]]; then
  printf '%s\n' 'Xcode did not produce the expected iPhone device app.' >&2
  exit 1
fi
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PLIST")"
if [[ -z "$EXECUTABLE" || "$EXECUTABLE" == */* || "$EXECUTABLE" == *..* ]]; then
  printf '%s\n' 'The app contains an invalid executable name.' >&2
  exit 1
fi
APP_BINARY="$APP_PATH/$EXECUTABLE"
if [[ ! -s "$APP_BINARY" ]]; then
  printf '%s\n' 'The compiled app executable is missing or empty.' >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PLIST")" != ru.archiverf.aveli ]]; then
  printf '%s\n' 'The build has an unexpected bundle identifier.' >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$APP_PLIST")" != APPL ]]; then
  printf '%s\n' 'The product is not an iOS application bundle.' >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$APP_PLIST")" != iphoneos ]]; then
  printf '%s\n' 'The build targets a simulator instead of an iPhone.' >&2
  exit 1
fi
if [[ -e "$APP_PATH/WebApp" ]]; then
  printf '%s\n' 'Remote-only app unexpectedly contains the offline prototype.' >&2
  exit 1
fi
python3 - "$APP_PLIST" <<'PLIST_CHECK'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
assert p['CFBundleShortVersionString'] == '1.0.4' and p['CFBundleVersion'] == '5'
assert p['NSAppTransportSecurity'] == {'NSAllowsArbitraryLoads': False}
assert p['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['archiverf-aveli']
assert p['NSLocationWhenInUseUsageDescription']
assert not p.get('UIBackgroundModes')
assert 'NSLocationAlwaysUsageDescription' not in p and 'NSLocationAlwaysAndWhenInUseUsageDescription' not in p
PLIST_CHECK
file "$APP_BINARY" | /usr/bin/grep -q 'Mach-O'
xcrun lipo "$APP_BINARY" -verify_arch arm64
if [[ -e "$APP_PATH/embedded.mobileprovision" ]]; then
  printf '%s\n' 'Unexpected provisioning profile in this unsigned build.' >&2
  exit 1
fi

# Keep only the app beneath Payload; build logs and metadata stay outside the IPA.
/usr/bin/ditto "$APP_PATH" "$PAYLOAD_DIR/AVELI.app"
/usr/bin/ditto -c -k --norsrc --keepParent "$PAYLOAD_DIR" "$IPA_PATH"
/usr/bin/unzip -tq "$IPA_PATH"
if ! /usr/bin/unzip -Z1 "$IPA_PATH" | /usr/bin/awk -v executable="$EXECUTABLE" \
  '$0 == "Payload/AVELI.app/" executable { found = 1 } END { exit !found }'; then
  printf '%s\n' 'The IPA is missing its Payload app executable.' >&2
  rm -f "$IPA_PATH"
  exit 1
fi

SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$SOURCE_REVISION" ]]; then SOURCE_REVISION=unknown; fi
{
  printf '%s\n' 'Семейный архив: Живая память — AVELI iPhone device build' 'Signing: unsigned; AltStore or Sideloadly must sign before installation.'
  printf 'Built at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'Source revision: %s\n' "$SOURCE_REVISION"
  printf 'Bundle identifier: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PLIST")"
  printf 'Version: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
  printf 'Build: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST")"
  printf 'Minimum iOS: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_PLIST")"
  printf 'Architectures: %s\n' "$(xcrun lipo "$APP_BINARY" -archs)"
  printf 'SDK: %s\n' "$(xcrun --sdk iphoneos --show-sdk-version)"
  xcodebuild -version
} > "$ARTIFACT_DIR/semeynyy-arkhiv-zhivaya-pamyat-aveli-build-info.txt"
(
  cd "$ARTIFACT_DIR"
  shasum -a 256 "$IPA_NAME" > semeynyy-arkhiv-zhivaya-pamyat-aveli-SHA256SUMS.txt
)
printf '\nIPA ready: %s\n' "$IPA_PATH"
printf '%s\n' 'Open this IPA in AltStore or Sideloadly to sign and install it on your iPhone.'
