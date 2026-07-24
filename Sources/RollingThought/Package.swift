// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RollingThought",
    platforms: [
        .iOS(.v17),
        .visionOS(.v1),
        .macOS(.v12),
        .macCatalyst(.v13)
    ],
    products: [
        .library(name: "RollingThought", targets: ["RollingThought"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RollingThought",
            dependencies: [],
            path: ".",
            exclude: ["build"],
            sources: ["RollingThought.swift"]
        )
    ]
)
