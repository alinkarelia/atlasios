#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_workspace="$(mktemp -d)"
trap 'rm -rf -- "$test_workspace"' EXIT
swift_compiler="${SWIFTC:-swiftc}"
"$swift_compiler" -swift-version 6 -D ATLAS_BUILDING_INDEX_CHECKS \
  "$test_directory/../BuildingPlanIndexStore.swift" \
  "$test_directory/BuildingPlanIndexChecks.swift" \
  -o "$test_workspace/building-index-checks"
"$test_workspace/building-index-checks"
