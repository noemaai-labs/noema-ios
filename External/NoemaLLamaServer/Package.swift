// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoemaLLamaServer",
    platforms: [
        .iOS(.v17),
        .macOS(.v12),
        .visionOS(.v1),
        .macCatalyst(.v13)
    ],
    products: [
        // The app ships this as its single llama.cpp runtime. The dynamic library
        // provides both the public C API and the embedded loopback server.
        .library(name: "NoemaLLamaServer", type: .dynamic, targets: ["NoemaLLamaServer"])
    ],
    targets: [
        .target(
            name: "NoemaLLamaServer",
            path: "Sources/NoemaLLamaServer",
            exclude: [
                // previous vendored snapshot (kept for reference)
                "upstream_b7634",
                // compile server.cpp only via bridge/server_embed.cpp inclusion
                "upstream/tools/server/server.cpp",
                "upstream/tools/server/main.cpp",
                // exclude mtmd CLI entrypoints
                "upstream/tools/mtmd/mtmd-cli.cpp",
                "upstream/tools/mtmd/deprecation-warning.cpp",
                "upstream/tools/mtmd/debug",
                // exclude non-server tool binaries that define their own main()
                "upstream/tools/batched-bench",
                "upstream/tools/cli",
                "upstream/tools/completion",
                "upstream/tools/cvector-generator",
                "upstream/tools/export-lora",
                "upstream/tools/fit-params",
                "upstream/tools/gguf-split",
                "upstream/tools/imatrix",
                "upstream/tools/llama-bench",
                "upstream/tools/perplexity",
                "upstream/tools/parser",
                "upstream/tools/quantize",
                "upstream/tools/results",
                "upstream/tools/rpc",
                "upstream/tools/tokenize",
                "upstream/tools/tts",
                // upstream UI generator has its own main(); ui.cpp/ui.h are
                // generated once for this SwiftPM package and kept in-tree.
                "upstream/tools/ui/embed.cpp",
                // Keep the server's generated UI entry point, but exclude the
                // web app sources that SwiftPM would otherwise scan as resources.
                "upstream/tools/ui/src",
                "upstream/tools/ui/tests",
                // exclude backends we don't ship in the iOS loopback build
                "upstream/ggml/src/ggml-webgpu",
                "upstream/ggml/src/ggml-zendnn",
                "upstream/ggml/src/ggml-zdnn",
                "upstream/ggml/src/ggml-hexagon",
                "upstream/ggml/src/ggml-cuda",
                "upstream/ggml/src/ggml-opencl",
                "upstream/ggml/src/ggml-openvino",
                "upstream/ggml/src/ggml-vulkan",
                "upstream/ggml/src/ggml-cann",
                "upstream/ggml/src/ggml-et",
                "upstream/ggml/src/ggml-musa",
                "upstream/ggml/src/ggml-sycl",
                "upstream/ggml/src/ggml-hip",
                "upstream/ggml/src/ggml-rpc",
                "upstream/ggml/src/ggml-virtgpu",
                // CPU backend contains architecture-specific kernels not gated for non-target builds.
                "upstream/ggml/src/ggml-cpu/spacemit",
                // Optional dependency; only built when enabled via CMake + headers present.
                "upstream/ggml/src/ggml-cpu/kleidiai",
                // SwiftPM does not apply llama.cpp's per-architecture source
                // selection. Noema-owned wrappers below include only the active
                // architecture's quantization and repacking kernels.
                "upstream/ggml/src/ggml-cpu/arch",
                // We embed the Metal shader source via bridge/ggml_metal_embed.cpp.
                // Prevent SwiftPM/Xcode from trying to compile ggml-metal.metal directly.
                "upstream/ggml/src/ggml-metal/ggml-metal.metal"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("GGML_VERSION", to: "\"0.16.0\""),
                .define("GGML_COMMIT", to: "\"b10018\""),
                .define("LLAMA_USE_HTTPLIB", to: "1"),
                .define("LLAMA_SHARED", to: "1"),
                .define("GGML_USE_CPU", to: "1"),
                .define("GGML_USE_METAL", to: "1"),
                .define("GGML_METAL_EMBED_LIBRARY", to: "1"),
                .define("GGML_USE_ACCELERATE", to: "1"),
                .define("GGML_BLAS_USE_ACCELERATE", to: "1"),
                .define("GGML_USE_CPU_REPACK", to: "1"),
                .define("ACCELERATE_NEW_LAPACK", to: "1"),
                .define("ACCELERATE_LAPACK_ILP64", to: "1"),
                .define("NOEMA_LLAMA_SERVER_TEST_HOOKS", .when(configuration: .debug)),
                // ggml-metal sources are written for manual retain/release.
                .unsafeFlags([
                    "-fno-objc-arc",
                    // Hide implementation-only symbols while the llama.cpp public C API
                    // and Noema server bridge retain their declared export visibility.
                    "-fvisibility=hidden",
                    // Xcode coverage instrumentation does not link the profiling runtime
                    // for package framework products, so keep vendored llama.cpp uninstrumented.
                    "-fno-profile-instr-generate",
                    "-fno-coverage-mapping"
                ]),
                // iOS and Catalyst deliberately remain baseline arm64. Dot-product
                // is enabled only where Noema's deployment targets guarantee it.
                .unsafeFlags(
                    ["-Xarch_arm64", "-march=armv8.2-a+dotprod+fp16"],
                    .when(platforms: [.macOS, .visionOS])
                ),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/common"),
                .headerSearchPath("upstream/src"),
                .headerSearchPath("upstream/tools/server"),
                .headerSearchPath("upstream/vendor"),
                .headerSearchPath("upstream/vendor/cpp-httplib"),
                .headerSearchPath("upstream/vendor/nlohmann"),
                .headerSearchPath("upstream/vendor/miniaudio"),
                .headerSearchPath("upstream/vendor/sheredom"),
                .headerSearchPath("upstream/vendor/stb"),
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/ggml/include"),
                .headerSearchPath("upstream/ggml/src"),
                .headerSearchPath("upstream/ggml/src/ggml-cpu"),
                .headerSearchPath("upstream/ggml/src/ggml-metal"),
                .headerSearchPath("upstream/tools/mtmd"),
                .headerSearchPath("upstream/tools/ui"),
                .headerSearchPath("bridge/paged")
            ],
            cxxSettings: [
                .define("GGML_VERSION", to: "\"0.16.0\""),
                .define("GGML_COMMIT", to: "\"b10018\""),
                .define("LLAMA_USE_HTTPLIB", to: "1"),
                .define("LLAMA_SHARED", to: "1"),
                .define("GGML_USE_CPU", to: "1"),
                .define("GGML_USE_METAL", to: "1"),
                .define("GGML_METAL_EMBED_LIBRARY", to: "1"),
                .define("GGML_USE_ACCELERATE", to: "1"),
                .define("GGML_BLAS_USE_ACCELERATE", to: "1"),
                .define("GGML_USE_CPU_REPACK", to: "1"),
                .define("ACCELERATE_NEW_LAPACK", to: "1"),
                .define("ACCELERATE_LAPACK_ILP64", to: "1"),
                .define("NOEMA_LLAMA_SERVER_TEST_HOOKS", .when(configuration: .debug)),
                // Keep ObjC++ sources consistent with the ggml-metal (non-ARC) build.
                .unsafeFlags([
                    "-fno-objc-arc",
                    // Hide implementation-only symbols while the llama.cpp public C API
                    // and Noema server bridge retain their declared export visibility.
                    "-fvisibility=hidden",
                    "-fvisibility-inlines-hidden",
                    // Xcode coverage instrumentation does not link the profiling runtime
                    // for package framework products, so keep vendored llama.cpp uninstrumented.
                    "-fno-profile-instr-generate",
                    "-fno-coverage-mapping"
                ]),
                .unsafeFlags(
                    ["-Xarch_arm64", "-march=armv8.2-a+dotprod+fp16"],
                    .when(platforms: [.macOS, .visionOS])
                ),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/common"),
                .headerSearchPath("upstream/src"),
                .headerSearchPath("upstream/tools/server"),
                .headerSearchPath("upstream/vendor"),
                .headerSearchPath("upstream/vendor/cpp-httplib"),
                .headerSearchPath("upstream/vendor/nlohmann"),
                .headerSearchPath("upstream/vendor/miniaudio"),
                .headerSearchPath("upstream/vendor/sheredom"),
                .headerSearchPath("upstream/vendor/stb"),
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/ggml/include"),
                .headerSearchPath("upstream/ggml/src"),
                .headerSearchPath("upstream/ggml/src/ggml-cpu"),
                .headerSearchPath("upstream/ggml/src/ggml-metal"),
                .headerSearchPath("upstream/tools/mtmd"),
                .headerSearchPath("upstream/tools/ui"),
                .headerSearchPath("bridge/paged")
            ],
            linkerSettings: []
        ),
        .testTarget(
            name: "NoemaLLamaServerTests",
            dependencies: ["NoemaLLamaServer"]
        )
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .cxx17
)
