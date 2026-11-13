// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meter",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MeterCore", targets: ["MeterCore"]),
        .library(name: "MeterUI", targets: ["MeterUI"]),
        .executable(name: "MeterApp", targets: ["MeterApp"]),
    ],
    targets: [
        .target(
            name: "MeterCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "MeterCoreTests",
            dependencies: ["MeterCore"],
            resources: [.copy("Fixtures")]
        ),
        .target(name: "MeterUI", dependencies: ["MeterCore"]),
        .executableTarget(name: "MeterApp", dependencies: ["MeterUI", "MeterCore"]),
        .testTarget(name: "MeterUITests", dependencies: ["MeterUI", "MeterCore"]),
    ]
)
