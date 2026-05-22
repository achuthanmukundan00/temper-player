// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TemperPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CTemperPlayer",
            path: "Sources/CTemperPlayer",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("temperplayer")]
        ),
        .executableTarget(
            name: "TemperPlayer",
            dependencies: ["CTemperPlayer"],
            swiftSettings: [
                .unsafeFlags(["-L", "$(PROJECT_DIR)/../zig-core/zig-out/lib"]),
            ]
        ),
    ]
)
