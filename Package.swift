// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NoemaPackages",
    platforms: [
        .iOS(.v17),
        .visionOS(.v1),
        .macOS(.v12),          // Align with SwiftUI APIs used in RollingThought
        .macCatalyst(.v13)
    ],
    products: [
        .library(name: "NoemaPackages", targets: ["NoemaPackages"]),
        .library(name: "RelayKit", targets: ["RelayKit"]),
    ],
    dependencies: [
        .package(path: "Sources/RollingThought"),
        .package(path: "External/NoemaLLamaServer"),
        .package(url: "https://github.com/pytorch/executorch.git", branch: "swiftpm-1.1.0"),
    ],
    targets: [
        .target(
            name: "NoemaPackages",
            dependencies: [
                "RollingThought",
                .product(name: "NoemaLLamaServer", package: "NoemaLLamaServer"),
                .product(name: "executorch", package: "executorch", condition: .when(platforms: [.iOS])),
                .product(name: "executorch_llm", package: "executorch", condition: .when(platforms: [.iOS])),
                .product(name: "backend_xnnpack", package: "executorch", condition: .when(platforms: [.iOS])),
                .product(name: "backend_coreml", package: "executorch", condition: .when(platforms: [.iOS])),
                .product(name: "backend_mps", package: "executorch", condition: .when(platforms: [.iOS])),
                .product(name: "kernels_optimized", package: "executorch", condition: .when(platforms: [.iOS])),
                .product(name: "kernels_quantized", package: "executorch", condition: .when(platforms: [.iOS])),
                .product(name: "kernels_llm", package: "executorch", condition: .when(platforms: [.iOS])),
                .product(name: "kernels_torchao", package: "executorch", condition: .when(platforms: [.iOS])),
            ],
            path: "Sources/NoemaPackages",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-all_load"]),
            ]
        ),
        .target(
            name: "RelayKit",
            dependencies: [],
            path: "Sources/RelayKit"
        ),
        .testTarget(
            name: "NoemaPackagesTests",
            dependencies: ["NoemaPackages"],
            path: "Tests/NoemaPackagesTests"
        ),
        .testTarget(
            name: "RelayKitTests",
            dependencies: ["RelayKit"],
            path: "Tests/RelayKitTests"
        )
    ]
)
