// swift-tools-version: 6.0
import PackageDescription

// Apple builds use SQLite from their selected SDK. Host pkg-config paths can
// otherwise make an iPhoneOS or simulator build link a macOS Homebrew library.
#if os(Linux)
let sqliteTarget: Target = .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])])
#else
let sqliteTarget: Target = .systemLibrary(name: "CSQLite")
#endif

let package = Package(
    name: "AtlasCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AtlasCore", targets: ["AtlasCore"])],
    targets: [
        sqliteTarget,
        .target(name: "AtlasCore", dependencies: ["CSQLite"]),
        .testTarget(name: "AtlasCoreTests", dependencies: ["AtlasCore", "CSQLite"])
    ],
    swiftLanguageModes: [.v6]
)
