#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
core_root="$repo_root/Packages/AtlasCore"
swift_executable="${ATLAS_SWIFT_EXECUTABLE:-swift}"
swift_compiler="${ATLAS_SWIFT_COMPILER:-swiftc}"
"$swift_executable" build --package-path "$core_root"
build_path="$("$swift_executable" build --package-path "$core_root" --show-bin-path)"
checks_dir="$(mktemp -d -t atlas-object-checks.XXXXXX)"
trap 'rm -rf "$checks_dir"' EXIT
objects=("$build_path"/AtlasCore.build/*.swift.o)
"$swift_compiler" -swift-version 6 -strict-concurrency=complete \
  -I "$build_path/Modules" -I "$core_root/Sources/CSQLite" \
  "${objects[@]}" \
  "$repo_root/Apps/iOS/Adapters/FieldDeliveryPassport.swift" \
  "$repo_root/Apps/iOS/Adapters/PhotoGeoMetadata.swift" \
  "$repo_root/Apps/iOS/Adapters/ObjectCaptureManifest.swift" \
  "$repo_root/Apps/iOS/Adapters/Tests/ObjectCaptureStorageChecks.swift" \
  -lsqlite3 -o "$checks_dir/checks"
"$checks_dir/checks"
