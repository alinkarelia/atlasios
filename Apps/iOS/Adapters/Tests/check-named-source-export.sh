#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_workspace="$(mktemp -d)"
trap 'rm -rf -- "$test_workspace"' EXIT
swift_compiler="${ATLAS_SWIFTC:-${SWIFTC:-swiftc}}"
python3 - "$test_directory/../../../../Packages/AtlasCore/Sources/AtlasCore/FieldTransferDigest.swift" "$test_workspace/digest.swift" <<'PY'
import pathlib, sys
source=pathlib.Path(sys.argv[1]).read_text()
begin=source.index('    /// Asset descriptors retain')
end=source.index('\n}\n\nprivate struct SHA256State',begin)
# Compile the production Stream and portable SHA implementation unchanged;
# only the unrelated Core asset-descriptor convenience method is omitted.
pathlib.Path(sys.argv[2]).write_text(source[:begin]+source[end:])
PY
"$swift_compiler" -swift-version 6 -strict-concurrency=complete -D ATLAS_SOURCE_EXPORT_CHECKS \
  "$test_workspace/digest.swift" "$test_directory/../CaptureShareIndex.swift" \
  "$test_directory/../ExportFileNaming.swift" "$test_directory/../NamedSourceExport.swift" \
  "$test_directory/NamedSourceExportChecks.swift" -o "$test_workspace/named-source-export-checks"
"$test_workspace/named-source-export-checks"
