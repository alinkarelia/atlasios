#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_workspace="$(mktemp -d)"
trap 'rm -rf -- "$test_workspace"' EXIT
swift_compiler="${SWIFTC:-swiftc}"
"$swift_compiler" -swift-version 6 -D ATLAS_PHOTO_METADATA_CHECKS \
  "$test_directory/../PhotoGeoMetadata.swift" "$test_directory/PhotoGeoMetadataChecks.swift" \
  -o "$test_workspace/photo-geo-checks"
"$test_workspace/photo-geo-checks"
ATLAS_SWIFTC="$swift_compiler" python3 "$test_directory/check-mesh-processor.py"
bash "$test_directory/video-capture-checks.sh"
"$swift_compiler" -swift-version 6 \
  "$test_directory/../CaptureVisualAdmission.swift" "$test_directory/CaptureVisualAdmissionChecks.swift" \
  -o "$test_workspace/capture-visual-checks"
"$test_workspace/capture-visual-checks"
"$swift_compiler" -swift-version 6 \
  "$test_directory/../StaffIdentityPolicy.swift" "$test_directory/../StaffBrowserCompletion.swift" \
  "$test_directory/../StaffWorkLease.swift" "$test_directory/StaffIdentityChecks.swift" \
  -o "$test_workspace/staff-identity-checks"
"$test_workspace/staff-identity-checks"
ATLAS_SWIFTC="$swift_compiler" python3 "$test_directory/check-staff-location-session.py"
