// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "melody-engine",
    platforms: [.macOS(.v13)],
    targets: [
        // Talking to melodyd: no AppKit, so it is tested without a menu bar.
        .target(name: "MelodyEngineCore"),
        .executableTarget(
            name: "MelodyEngine",
            dependencies: ["MelodyEngineCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "MelodyEngineCoreTests", dependencies: ["MelodyEngineCore"]),
    ]
)
