#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd "$(dirname "$0")" && pwd)"
repository_directory="$(cd "$test_directory/../../../.." && pwd)"
checks_directory="$(mktemp -d -t terraview-collaborative-survey.XXXXXX)"
trap 'rm -rf "$checks_directory"' EXIT
swift_command="${SWIFT:-swift}"
python3 - "$checks_directory" "$repository_directory" <<'PY'
import json, pathlib, shutil, sys
scratch, repository = map(pathlib.Path, sys.argv[1:])
sources = scratch / 'Sources' / 'Checks'
sources.mkdir(parents=True)
dependency = json.dumps(str(repository / 'Packages' / 'AtlasCore'), ensure_ascii=False)
(scratch / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CollaborativeNativeChecks", platforms: [.macOS(.v14)], dependencies: [.package(path: ''' + dependency + ''')], targets: [.executableTarget(name: "Checks", dependencies: [.product(name: "AtlasCore", package: "AtlasCore")])], swiftLanguageModes: [.v6])
''')
for relative in [
    'Apps/iOS/Adapters/CollaborativeSurveyStore.swift',
    'Apps/iOS/Adapters/Tests/CollaborativeSurveyStoreChecks.swift',
]:
    shutil.copyfile(repository / relative, sources / pathlib.Path(relative).name)
(sources / 'Runner.swift').write_text('import Foundation\n@main enum Runner { static func main() async throws { try await CollaborativeSurveyStoreChecks.run() } }\n')
PY
"$swift_command" run --package-path "$checks_directory" --scratch-path "$checks_directory/build" Checks
