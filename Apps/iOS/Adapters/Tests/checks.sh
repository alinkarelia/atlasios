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
