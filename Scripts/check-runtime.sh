#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]] || ! xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
  printf '%s\n' 'Runtime UI validation requires macOS and a full Xcode installation with an iOS Simulator runtime.' >&2
  exit 2
fi

launch_only=false
field_interactions_only=false
if [[ "${1:-}" == "--launch-only" ]]; then
  launch_only=true
elif [[ "${1:-}" == "--field-interactions-only" ]]; then
  field_interactions_only=true
elif [[ -n "${1:-}" ]]; then
  printf 'Unknown argument: %s\n' "$1" >&2
  exit 2
fi

artifacts="$repo_root/artifacts/runtime"
if "$field_interactions_only"; then
  # Keep a focused diagnostic separate from the complete release evidence.
  artifacts="$repo_root/artifacts/focused-fieldwork-runtime"
fi
derived_data="$artifacts/DerivedData"
screenshots="$artifacts/screenshots"
mkdir -p "$screenshots" "$artifacts/diagnostics"
python3 "$repo_root/Scripts/generate-xcode-project.py" --check
xcrun swift "$repo_root/Scripts/check-project.swift"
xcrun simctl list runtimes --json > "$artifacts/runtimes.json"
xcrun simctl list devicetypes --json > "$artifacts/device-types.json"

# Prefer the iOS 18.5/iPhone 16 generation used by our Xcode 16.4 CI runner.
# A newer installed runtime is a truthful fallback, recorded in the artifacts.
python3 - "$artifacts" > "$artifacts/simulator-identifiers.txt" <<'PY'
import json, os
from pathlib import Path
import sys
root = Path(sys.argv[1])
runtimes = [r for r in json.loads((root / 'runtimes.json').read_text())['runtimes']
            if r.get('isAvailable') and '.iOS-' in r['identifier']]
major = os.environ.get('ATLAS_RUNTIME_IOS_MAJOR', '')
if major:
    if not major.isdecimal():
        raise SystemExit('ATLAS_RUNTIME_IOS_MAJOR must be a decimal iOS version.')
    runtimes = [runtime for runtime in runtimes if runtime['version'].split('.')[0] == major]
if not runtimes:
    raise SystemExit(f'No available requested iOS {major or "any"} Simulator runtime; install one through Xcode settings.')
def version(runtime):
    return tuple(int(p) for p in runtime['version'].split('.'))
runtime = next((r for r in runtimes if r['version'] == '18.5'), max(runtimes, key=version))
types = json.loads((root / 'device-types.json').read_text())['devicetypes']
device = next((d for d in types if d['identifier'] == 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro'), None)
if device is None:
    device = next((d for d in types if d['identifier'] == 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'), None)
if device is None:
    device = next((d for d in reversed(types) if d.get('productFamily') == 'iPhone'), None)
if device is None:
    raise SystemExit('No iPhone Simulator device type installed.')
(root / 'simulator-selection.json').write_text(json.dumps({'runtime': runtime, 'deviceType': device}, indent=2) + '\n')
print(runtime['identifier'], device['identifier'])
PY
read -r runtime_id device_type < "$artifacts/simulator-identifiers.txt"

device_id="$(xcrun simctl create 'Atlas Runtime QA' "$device_type" "$runtime_id")"
printf '%s\n' "$device_id" > "$artifacts/simulator-udid.txt"
result_bundle="$artifacts/Atlas-Runtime-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"

cleanup() {
  local exit_status=$?
  set +e
  xcrun simctl io "$device_id" screenshot "$screenshots/final-state.png"
  xcrun simctl spawn "$device_id" log show --last 15m --style compact \
    --predicate 'process == "Atlas" OR process CONTAINS "AtlasUITests"' > "$artifacts/diagnostics/application.log" 2>&1
  if [[ -d "$result_bundle" ]]; then
    xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$screenshots/test-attachments" \
      > "$artifacts/diagnostics/attachment-export.log" 2>&1
    xcrun xcresulttool get test-results summary --path "$result_bundle" \
      > "$artifacts/diagnostics/test-summary.json" 2>&1
    xcrun xcresulttool export metrics --path "$result_bundle" --output-path "$artifacts/diagnostics/metrics" \
      > "$artifacts/diagnostics/metric-export.log" 2>&1
  fi
  if [[ -d "$HOME/Library/Logs/DiagnosticReports" ]]; then
    find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \
      -name 'Atlas*.ips' -exec cp {} "$artifacts/diagnostics/" \;
  fi
  xcrun simctl shutdown "$device_id" >/dev/null 2>&1
  xcrun simctl delete "$device_id" >/dev/null 2>&1
  exit "$exit_status"
}
trap cleanup EXIT

xcrun simctl boot "$device_id"

# Compilation needs the selected Simulator destination, not a running app.
# Let its initial boot proceed during the build, then await readiness before
# any install, appearance changes, screenshots, or UI-test operations.
xcodebuild -project "$repo_root/Atlas.xcodeproj" -scheme Atlas -configuration Debug \
  -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES build

xcrun simctl bootstatus "$device_id" -b
xcrun simctl ui "$device_id" appearance light
xcrun simctl status_bar "$device_id" override --time '9:41' --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100

app_path="$derived_data/Build/Products/Debug-iphonesimulator/Atlas.app"
xcrun simctl install "$device_id" "$app_path"
# Pre-grant privacy choices so system prompts cannot mask app controls. A grant
# does not provide physical camera/LiDAR hardware; fallback remains the expected
# Simulator behavior. Older simctl versions may not support camera grants.
xcrun simctl privacy "$device_id" grant location com.atlasfield.app || true
xcrun simctl privacy "$device_id" grant camera com.atlasfield.app || true
xcrun simctl privacy "$device_id" grant photos com.atlasfield.app || true
xcrun simctl launch --terminate-running-process "$device_id" com.atlasfield.app \
  -AppleLanguages '(ru)' -AppleLocale ru_RU
# This is only a baseline screenshot delay. UI tests use state-based waits.
sleep 3
xcrun simctl io "$device_id" screenshot "$screenshots/00-first-launch.png"

if "$launch_only"; then
  printf '%s\n' 'Real Simulator launch and baseline screenshot completed. No capture hardware or UI-test claim is made.'
  exit 0
fi

xcrun simctl terminate "$device_id" com.atlasfield.app || true
# The macOS system Bash 3.2 treats an empty array as unbound under set -u.
# Keep the default invocation nonempty and identical to the full test command.
focused_arguments=(test)
if "$field_interactions_only"; then
  focused_arguments=(
    -only-testing:AtlasUITests/AtlasUITests/testCandidateRejectionIsReversibleAndNeverConfirmsAnUnknownPerson
    -only-testing:AtlasUITests/AtlasUITests/testUnknownBurialInscriptionAndCommentsSurviveRestartWithoutInventingIdentity
    -only-testing:AtlasUITests/AtlasUITests/testTeamPlanCreatesFiveRealAssignmentsAndPersistsTheExplicitWorkerSelection
    test
  )
fi
xcodebuild -project "$repo_root/Atlas.xcodeproj" -scheme AtlasUITests -configuration Debug \
  -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES "${focused_arguments[@]}"

if "$field_interactions_only"; then
  printf 'Focused fieldwork interactions passed. This is not a complete release UI check. Results: %s\n' "$artifacts"
else
  printf 'Native UI tests passed in Simulator. Results and screenshots: %s\n' "$artifacts"
fi
