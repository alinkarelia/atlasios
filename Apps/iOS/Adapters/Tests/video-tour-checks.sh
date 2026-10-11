#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_workspace="$(mktemp -d)"
trap 'rm -rf -- "$test_workspace"' EXIT
swift_compiler="${SWIFTC:-swiftc}"
"$swift_compiler" -swift-version 6 -strict-concurrency=complete \
  "$test_directory/../CaptureVideoDocument.swift" "$test_directory/../VideoTourPolicy.swift" \
  "$test_directory/VideoTourPolicyChecks.swift" -o "$test_workspace/video-tour-policy"
"$test_workspace/video-tour-policy"
if [[ "$(uname -s)" == "Darwin" ]]; then
  "$swift_compiler" -swift-version 6 -strict-concurrency=complete \
    "$test_directory/../CaptureVideoDocument.swift" "$test_directory/../CaptureVideoRecorder.swift" \
    "$test_directory/../VideoTourPolicy.swift" "$test_directory/../VideoTourImporter.swift" \
    "$test_directory/VideoTourImporterChecks.swift" -o "$test_workspace/video-tour-importer"
  "$test_workspace/video-tour-importer"
else
  printf '%s\n' 'Actual AVFoundation movie-to-tour integration checks require macOS; portable pose/source policy verified.'
fi
