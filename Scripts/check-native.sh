#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'Native validation requires macOS and full Xcode. Linux can run the portable AtlasCore tests.' >&2
  exit 2
fi
if ! command -v xcodebuild >/dev/null || ! xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
  printf '%s\n' 'Select a full Xcode 16+ installation with xcode-select; Command Line Tools alone do not include the iOS SDK.' >&2
  exit 2
fi

python3 "$repo_root/Scripts/generate-xcode-project.py"
plutil -lint "$repo_root/Apps/iOS/Info.plist" "$repo_root/Apps/iOS/Resources/PrivacyInfo.xcprivacy" "$repo_root/Atlas.xcodeproj/project.pbxproj"
xcrun swift "$repo_root/Scripts/check-project.swift"

configuration="${ATLAS_NATIVE_CONFIGURATION:-Debug}"
destination="${ATLAS_NATIVE_DESTINATION:-generic/platform=iOS Simulator}"
artifacts="$repo_root/artifacts/native"
derived_data="${ATLAS_DERIVED_DATA:-$artifacts/DerivedData}"
result_bundle="$artifacts/Atlas-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
mkdir -p "$artifacts"

xcodebuild \
  -project "$repo_root/Atlas.xcodeproj" \
  -scheme Atlas \
  -configuration "$configuration" \
  -destination "$destination" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

printf 'Native simulator build passed. Result bundle: %s\n' "$result_bundle"
