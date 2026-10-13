#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
core_root="$repo_root/Packages/AtlasCore"
swift_executable="${ATLAS_SWIFT_EXECUTABLE:-swift}"
swift_compiler="${ATLAS_SWIFT_COMPILER:-swiftc}"
build_args=(--package-path "$core_root")
if [[ -n "${ATLAS_CORE_SCRATCH_PATH:-}" ]]; then
  build_args+=(--scratch-path "$ATLAS_CORE_SCRATCH_PATH")
fi
"$swift_executable" build "${build_args[@]}"
build_path="$("$swift_executable" build "${build_args[@]}" --show-bin-path)"
checks_dir="$(mktemp -d -t terraview-collaboration-export.XXXXXX)"
trap 'rm -rf "$checks_dir"' EXIT
objects=("$build_path"/AtlasCore.build/*.swift.o)
"$swift_compiler" -swift-version 6 -strict-concurrency=complete \
  -I "$build_path/Modules" -I "$core_root/Sources/CSQLite" \
  "${objects[@]}" \
  "$repo_root/Apps/iOS/Adapters/ProjectJournalExport.swift" \
  "$repo_root/Apps/iOS/Adapters/CollaborativeSurveyStore.swift" \
  "$repo_root/Apps/iOS/Adapters/FragmentAssemblyStore.swift" \
  "$repo_root/Apps/iOS/Adapters/FieldDeliveryPassport.swift" \
  "$repo_root/Apps/iOS/Adapters/AssistantProjectPackage.swift" \
  "$repo_root/Apps/iOS/Adapters/Tests/CollaborationExportChecks.swift" \
  -lsqlite3 -o "$checks_dir/checks"
"$checks_dir/checks"
