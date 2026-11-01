// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PigiCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PigiCore", targets: ["PigiCore"]),
    ],
    targets: [
        .target(
            name: "PigiCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
            ]
        ),
    ]
)
