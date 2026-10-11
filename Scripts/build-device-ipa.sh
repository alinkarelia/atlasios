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
import json
import plistlib
import re
import struct
import sys
import zipfile


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def validate_app_icons(archive, app, info):
    """Check processed plist declarations against the actual packaged PNGs."""
    members = set(archive.namelist())
    catalog = app + 'Assets.car'
    require(catalog in members and archive.getinfo(catalog).file_size > 0,
            'Packaged application is missing its compiled Assets.car.')
    pngs = {name[len(app):]: name for name in members
            if name.startswith(app) and '/' not in name[len(app):] and name.endswith('.png')}

    def png_dimensions(name):
        require(0 < archive.getinfo(name).file_size <= 8 * 1024 * 1024,
                'Packaged AppIcon PNG has an invalid file size.')
        data = archive.read(name)
        require(data[:8] == b'\x89PNG\r\n\x1a\n', 'Packaged AppIcon resource is not a PNG.')
        offset = 8
        # Xcode can prefix an optimized iOS PNG with Apple's CgBI chunk.
        while offset + 12 <= len(data):
            length = struct.unpack_from('>I', data, offset)[0]
            kind = data[offset + 4:offset + 8]
            require(offset + 12 + length <= len(data), 'Truncated packaged AppIcon PNG chunk.')
            if kind == b'IHDR':
                require(length == 13, 'Invalid packaged AppIcon PNG dimensions header.')
                width, height = struct.unpack_from('>II', data, offset + 8)
                require(width > 0 and width == height, 'Packaged AppIcon PNG must be square.')
                return width, height
            require(kind == b'CgBI', 'Packaged AppIcon PNG is missing its dimensions header.')
            offset += length + 12
        raise SystemExit('Packaged AppIcon PNG is missing its dimensions header.')

    def primary_icons(key, idiom):
        icons = info.get(key)
        primary = icons.get('CFBundlePrimaryIcon') if isinstance(icons, dict) else None
        require(isinstance(primary, dict) and primary.get('CFBundleIconName') == 'AppIcon',
                f'Packaged application has no primary AppIcon declarations for {idiom}.')
        declared = primary.get('CFBundleIconFiles')
        require(isinstance(declared, list) and bool(declared),
                f'Packaged application declares no AppIcon PNG files for {idiom}.')
        found = {}
        for value in declared:
            require(isinstance(value, str) and value not in ('', '.', '..')
                    and '/' not in value and '\\' not in value,
                    'Invalid packaged AppIcon file declaration.')
            base = value[:-4] if value.endswith('.png') else value
            pattern = re.compile(re.escape(base) + r'(?:@[123]x)?(?:~(?:iphone|ipad))?\.png')
            opposite = '~ipad.png' if idiom == 'iPhone' else '~iphone.png'
            matches = [name for name in pngs if pattern.fullmatch(name) and not name.endswith(opposite)]
            require(bool(matches), f'An AppIcon file declared for {idiom} is missing from the package.')
            for name in matches:
                found[name] = png_dimensions(pngs[name])
        return found

    phone = primary_icons('CFBundleIcons', 'iPhone')
    require((180, 180) in phone.values(), 'Packaged application is missing its 180x180 iPhone AppIcon PNG.')
    tablet = primary_icons('CFBundleIcons~ipad', 'iPad') if 2 in info.get('UIDeviceFamily', []) else {}
    return {'asset': 'AppIcon', 'catalog': 'Assets.car',
            'iPhone_PNGs': {name: list(size) for name, size in sorted(phone.items())},
            'iPad_PNGs': {name: list(size) for name, size in sorted(tablet.items())}}


with zipfile.ZipFile(sys.argv[1]) as archive:
    required = {"Payload/Atlas.app/Info.plist", f"Payload/Atlas.app/{sys.argv[2]}"}
    if not required.issubset(archive.namelist()):
        raise SystemExit("IPA is missing its device application or executable.")
    damaged = archive.testzip()
    if damaged:
        raise SystemExit(f"IPA ZIP integrity check failed: {damaged}")
    info = plistlib.loads(archive.read('Payload/Atlas.app/Info.plist'))
    icons = validate_app_icons(archive, 'Payload/Atlas.app/', info)
    print('Packaged AppIcon validated: ' + json.dumps(icons, sort_keys=True))
PY

printf 'Created unsigned device IPA: %s\n' "$ipa_path"
printf '%s\n' 'This file is not signed for installation or TestFlight. A personal Apple Account signing tool must sign it before installation on an iPhone.'
printf 'Native device build result: %s\n' "$result_bundle"
