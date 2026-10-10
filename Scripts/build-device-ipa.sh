#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'Device IPA compilation requires macOS and full Xcode. This script does not run on Windows or Linux.' >&2
  exit 2
fi
if ! command -v xcodebuild >/dev/null || ! command -v xcrun >/dev/null || ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  printf '%s\n' 'Select a full Xcode 16+ installation with xcode-select; the iPhoneOS SDK is required.' >&2
  exit 2
fi

# Use the checked-in project; fail rather than silently changing it for this build.
python3 "$repo_root/Scripts/generate-xcode-project.py" --check
plutil -lint "$repo_root/Apps/iOS/Info.plist" "$repo_root/Apps/iOS/Resources/PrivacyInfo.xcprivacy" "$repo_root/Atlas.xcodeproj/project.pbxproj"
xcrun swift "$repo_root/Scripts/check-project.swift"

artifacts="$repo_root/artifacts/device-preview"
derived_data="$artifacts/DerivedData"
result_bundle="$artifacts/Atlas-device-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
ipa_path="$artifacts/Atlas-unsigned.ipa"
mkdir -p "$artifacts"
# A failed new build must not leave an old IPA that appears to be its output.
rm -f -- "$ipa_path"

xcodebuild \
  -project "$repo_root/Atlas.xcodeproj" \
  -scheme Atlas \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  build

app_path="$derived_data/Build/Products/Release-iphoneos/Atlas.app"
if [[ ! -d "$app_path" || ! -f "$app_path/Info.plist" ]]; then
  printf '%s\n' 'The device build did not produce the expected Atlas.app. No IPA was created.' >&2
  exit 1
fi
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Info.plist")"
platform="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app_path/Info.plist")"
package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$app_path/Info.plist")"
if [[ -z "$executable_name" || "$executable_name" == */* || ! -f "$app_path/$executable_name" || "$platform" != "iPhoneOS" || "$package_type" != "APPL" ]]; then
  printf '%s\n' 'The build output is not a valid iPhoneOS application. No IPA was created.' >&2
  exit 1
fi
if ! xcrun lipo "$app_path/$executable_name" -verify_arch arm64; then
  printf '%s\n' 'The application has no arm64 device executable. No IPA was created.' >&2
  exit 1
fi

staging_root="$(mktemp -d "$artifacts/ipa-staging.XXXXXX")"
trap 'rm -rf -- "$staging_root"' EXIT
mkdir -p "$staging_root/Payload"
ditto "$app_path" "$staging_root/Payload/Atlas.app"
ditto -c -k --norsrc --noextattr --keepParent "$staging_root/Payload" "$ipa_path"
# Validate the ZIP structure and CRC, not just the existence of a file.
python3 - "$ipa_path" "$executable_name" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    required = {"Payload/Atlas.app/Info.plist", f"Payload/Atlas.app/{sys.argv[2]}"}
    if not required.issubset(archive.namelist()):
        raise SystemExit("IPA is missing its device application or executable.")
    damaged = archive.testzip()
    if damaged:
        raise SystemExit(f"IPA ZIP integrity check failed: {damaged}")
PY

printf 'Created unsigned device IPA: %s\n' "$ipa_path"
printf '%s\n' 'This file is not signed for installation or TestFlight. A personal Apple Account signing tool must sign it before installation on an iPhone.'
printf 'Native device build result: %s\n' "$result_bundle"
