// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SidebArc",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Library for bundler to use
        .library(name: "SidebArcCore", targets: ["SidebArcCore"]),
        // Executable for development/testing; Bundler.toml `product` points here
        .executable(name: "sidebarc", targets: ["SidebArcApp"])
    ],
    targets: [
        // Core library with all app logic
        .target(
            name: "SidebArcCore",
            resources: [.copy("NoteEditor")]
        ),
        // Minimal executable entry point
        .executableTarget(
            name: "SidebArcApp",
            dependencies: ["SidebArcCore"]
        ),
        .testTarget(
            name: "SidebArcTests",
            dependencies: ["SidebArcCore"]
        )
    ]
)
