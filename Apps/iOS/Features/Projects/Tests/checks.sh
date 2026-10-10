#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_workspace="$(mktemp -d)"
trap 'rm -rf -- "$test_workspace"' EXIT
swift_compiler="${SWIFTC:-swiftc}"
"$swift_compiler" -swift-version 6 -D ATLAS_OBJ_PREVIEW_CHECKS \
  "$test_directory/../OBJPreviewLoader.swift" "$test_directory/OBJPreviewChecks.swift" \
  -o "$test_workspace/obj-checks"
"$test_workspace/obj-checks"
