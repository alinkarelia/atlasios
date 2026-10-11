#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_workspace="$(mktemp -d)"
trap 'rm -rf -- "$test_workspace"' EXIT
swift_compiler="${ATLAS_SWIFTC:-${SWIFTC:-swiftc}}"
"$swift_compiler" -swift-version 6 -strict-concurrency=complete \
  "$test_directory/../ExportFileNaming.swift" "$test_directory/../NamedSourceExport.swift" \
  "$test_directory/NamedSourceExportChecks.swift" -o "$test_workspace/named-source-export-checks"
"$test_workspace/named-source-export-checks"
