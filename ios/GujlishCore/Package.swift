// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GujlishCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GujlishCore", targets: ["GujlishCore"]),
    ],
    targets: [
        .target(
            name: "GujlishCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The tests read web/expected.json, web/golden.tsv and gujlish.db
        // from the repo root, the same files that pin the JavaScript port.
        .testTarget(name: "GujlishCoreTests", dependencies: ["GujlishCore"]),
    ]
)
