#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_workspace="$(mktemp -d)"
trap 'rm -rf -- "$test_workspace"' EXIT
swift_compiler="${SWIFTC:-swiftc}"
bash "$test_directory/building-index-checks.sh"
"$swift_compiler" -swift-version 6 -D ATLAS_EMPTY_ROOM_CHECKS \
  "$test_directory/../../../Adapters/EmptyRoomDocument.swift" \
  "$test_directory/EmptyRoomGeometryChecks.swift" \
  -o "$test_workspace/empty-room-checks"
"$test_workspace/empty-room-checks"
"$swift_compiler" -swift-version 6 -D ATLAS_PLAN_DIMENSION_CHECKS \
  "$test_directory/../PlanDimensionLabelLayout.swift" \
  "$test_directory/PlanDimensionLayoutChecks.swift" \
  -o "$test_workspace/plan-dimension-checks"
"$test_workspace/plan-dimension-checks"
"$swift_compiler" -swift-version 6 -D ATLAS_EMPTY_ROOM_REVIEW_CHECKS \
  "$test_directory/../../../Adapters/EmptyRoomDocument.swift" \
  "$test_directory/../EmptyRoomSurfaceReview.swift" \
  "$test_directory/../EmptyRoomQuantities.swift" \
  "$test_directory/../EmptyRoomReviewPresentation.swift" \
  "$test_directory/EmptyRoomSurfaceReviewChecks.swift" \
  -o "$test_workspace/empty-room-review-checks"
"$test_workspace/empty-room-review-checks"
