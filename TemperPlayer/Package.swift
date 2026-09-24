// swift-tools-version: 5.9
import PackageDescription
import Foundation

let zigLibraryDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("zig-core/zig-out/lib").path

let package = Package(
    name: "TemperPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CTemperPlayer",
            path: "Sources/CTemperPlayer",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("temperplayer"),
                // Bundled apps resolve Frameworks first; source builds and tests use the Zig output.
                .unsafeFlags(["-L", zigLibraryDirectory,
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", zigLibraryDirectory])
            ]
        ),
        .executableTarget(
            name: "TemperPlayer",
            dependencies: ["CTemperPlayer"]
        ),
        .testTarget(
            name: "TemperPlayerTests",
            dependencies: ["TemperPlayer"]
        ),
    ]
)
