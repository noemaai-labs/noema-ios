// swift-tools-version: 6.0

// Trimmed vendored copy of https://github.com/apple/coreai-models (BSD-3-Clause,
// see LICENSE) with the coreai-model-zoo "extra-states" patch applied to
// CoreAIPipelinedEngine so hybrid-SSM exports (Qwen3.5 gated-deltanet) can ride
// the pipelined GPU engine. Kept: the CoreAILM engine stack (EngineFactory,
// engines, LanguageBundle, samplers). Dropped: guided generation (CXGrammar /
// xgrammar C++ dep), the high-level CoreAILanguageModel session, diffusion /
// segmentation / detection products, and the CLI tools.

import PackageDescription

let package = Package(
    name: "coreai-models",
    platforms: [.macOS("26.0"), .iOS("17.0")],
    products: [
        .library(
            name: "CoreAILM",
            targets: [
                "CoreAILanguageModels"
            ]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "CoreAILanguageModels",
            dependencies: [
                "CoreAIShared",
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "swift/Sources/CoreAILanguageModels",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
                // The per-token host loop dominates unoptimized: a Debug engine
                // measures ~3× slow (zoo knowledge/pipelined-engine.md). Keep
                // the engine optimized even in Debug app builds.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "CoreAIShared",
            dependencies: [],
            path: "swift/Sources/CoreAIShared",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
    ]
)
