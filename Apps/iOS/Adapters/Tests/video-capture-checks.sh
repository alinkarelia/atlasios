#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_workspace="$(mktemp -d)"
trap 'rm -rf -- "$test_workspace"' EXIT
swift_compiler="${SWIFTC:-swiftc}"
"$swift_compiler" -swift-version 6 -strict-concurrency=complete \
  "$test_directory/../CaptureVideoDocument.swift" "$test_directory/CaptureVideoDocumentChecks.swift" \
  -o "$test_workspace/video-provenance"
"$test_workspace/video-provenance"
"$swift_compiler" -swift-version 6 -strict-concurrency=complete \
  "$test_directory/../CaptureContinuation.swift" "$test_directory/CaptureContinuationChecks.swift" \
  -o "$test_workspace/capture-continuation"
"$test_workspace/capture-continuation"
if [[ "$(uname -s)" == "Darwin" ]]; then
  "$swift_compiler" -swift-version 6 -strict-concurrency=complete \
    "$test_directory/../CaptureVideoDocument.swift" "$test_directory/../CaptureVideoRecorder.swift" \
    "$test_directory/CaptureVideoRecorderChecks.swift" -o "$test_workspace/video-recorder"
  "$test_workspace/video-recorder"
else
  printf '%s\n' 'Actual AVFoundation video encoder checks require macOS; portable provenance only.'
fi
