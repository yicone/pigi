// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PigiCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PigiCore", targets: ["PigiCore"]),
        .executable(name: "pigi-config", targets: ["PigiConfigCLI"]),
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
        .executableTarget(name: "PigiConfigCLI", dependencies: ["PigiCore"]),
        .testTarget(name: "AgentServiceTests", dependencies: ["PigiCore"], path: "Tests/AgentServiceTests"),
    ]
)
