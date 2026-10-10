#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_workspace="$(mktemp -d)"
trap 'rm -rf -- "$test_workspace"' EXIT
swift_compiler="${SWIFTC:-swiftc}"

if [[ "$(uname -s)" == "Linux" ]]; then
  # This shim compiles the real Foundation repository; it does not test Combine
  # observation. macOS uses Apple's real framework instead.
  cat > "$test_workspace/Combine.swift" <<'SWIFT'
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
public protocol ObservableObject: AnyObject {}
SWIFT
  "$swift_compiler" -emit-library -emit-module -module-name Combine \
    "$test_workspace/Combine.swift" -o "$test_workspace/libCombine.so"
  "$swift_compiler" -swift-version 6 -D ATLAS_BUSINESS_CHECKS \
    -I "$test_workspace" -L "$test_workspace" -lCombine \
    "$test_directory/../BusinessStore.swift" "$test_directory/BusinessStoreChecks.swift" \
    -o "$test_workspace/business-checks"
  LD_LIBRARY_PATH="$test_workspace${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$test_workspace/business-checks"
else
  "$swift_compiler" -swift-version 6 -D ATLAS_BUSINESS_CHECKS \
    "$test_directory/../BusinessStore.swift" "$test_directory/BusinessStoreChecks.swift" \
    -o "$test_workspace/business-checks"
  "$test_workspace/business-checks"
fi
