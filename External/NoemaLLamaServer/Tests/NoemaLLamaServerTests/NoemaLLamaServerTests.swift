import Foundation
import Testing
@testable import NoemaLLamaServer

@_silgen_name("noema_llama_server_normalize_cache_type_for_test")
private func noema_llama_server_normalize_cache_type_for_test(
    _ rawValue: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>?

@_silgen_name("noema_llama_server_effective_mtp_cap_for_test")
private func noema_llama_server_effective_mtp_cap_for_test(
    _ configured: Int32,
    _ round: Int32,
    _ heads: Int32,
    _ chained: Int32
) -> Int32

private struct StartDiagnostics: Decodable {
    let code: String
    let message: String
    let lastHTTPStatus: Int?
    let elapsedMs: Int
    let progress: Double
    let httpReady: Bool
}

private struct MemoryEstimateDiagnostics: Decodable {
    let status: String
    let message: String?
    let modelBytes: UInt64?
    let contextBytes: UInt64?
    let computeBytes: UInt64?
    let projectorBytes: UInt64?
    let speculativeBytes: UInt64?
    let totalBytes: UInt64?
}

private struct StartOptionsDiagnostics: Decodable {
    let contextSize: Int
    let threads: Int
    let batchSize: Int
    let ubatchSize: Int
    let useMmap: Bool
    let useMlock: Bool
    let unifiedKVCache: Bool
    let cacheTypeK: String
    let cacheTypeV: String
    let moeExpertCount: Int?
    let yarnScale: Double?
    let speculativeType: String
    let specDynamic: Bool?
    let cacheRamMiB: Int
    let ctxCheckpoints: Int
    let cpuNEON: Bool
    let cpuDotProduct: Bool
    let cpuI8MM: Bool
    let cpuRepack: Bool
    let argv: [String]
}

private func normalizeCacheType(_ rawValue: String?) -> String? {
    guard let rawValue else {
        return noema_llama_server_normalize_cache_type_for_test(nil).map {
            String(cString: $0)
        }
    }
    return rawValue.withCString { pointer in
        noema_llama_server_normalize_cache_type_for_test(pointer).map {
            String(cString: $0)
        }
    }
}

@Test func mtpCapHonorsRoundBudgetAndUsableHeads() {
    #expect(noema_llama_server_effective_mtp_cap_for_test(8, 1, 8, 0) == 1)
    #expect(noema_llama_server_effective_mtp_cap_for_test(8, 8, 3, 1) == 3)
    #expect(noema_llama_server_effective_mtp_cap_for_test(8, 1, 3, 1) == 1)
}

@Test func cacheTypeNormalizationLowercasesSupportedTokens() {
    #expect(normalizeCacheType("F16") == "f16")
    #expect(normalizeCacheType(" Q4_1\t") == "q4_1")
    #expect(normalizeCacheType("IQ4_NL") == "iq4_nl")
}

@Test func cacheTypeNormalizationRejectsBlankOrUnsupportedTokens() {
    #expect(normalizeCacheType(nil) == nil)
    #expect(normalizeCacheType("") == nil)
    #expect(normalizeCacheType("   ") == nil)
    #expect(normalizeCacheType("Q3_K_M") == nil)
}

// Start-based tests join the serialized suite declared in OverfitPagedTests.swift:
// the server (and its diagnostics JSON) is a process singleton, so concurrent
// starts from parallel suites race on it.
extension ServerStartSerializedTests {

@Test func startupFailureExposesDiagnostics() async throws {
    let host = "127.0.0.1"
    let model = "/tmp/does-not-exist.gguf"
    let draft = "/tmp/does-not-exist-draft.gguf"
    let cacheK = " Q4_0 "
    let cacheV = "Q8_0"
    let tensor = ".*\\.ffn_.*=CPU"
    let speculativeType = "draft-simple"
    let port = host.withCString { hostPointer in
        model.withCString { modelPointer in
            draft.withCString { draftPointer in
                cacheK.withCString { cacheKPointer in
                    cacheV.withCString { cacheVPointer in
                        tensor.withCString { tensorPointer in
                            speculativeType.withCString { speculativePointer in
                                var configuration = noema_llama_server_configuration()
                                configuration.version = UInt32(NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION)
                                configuration.size = UInt32(MemoryLayout<noema_llama_server_configuration>.size)
                                configuration.host = hostPointer
                                configuration.gguf_path = modelPointer
                                configuration.draft_model_path = draftPointer
                                configuration.reasoning_budget = Int32.min
                                configuration.use_jinja = 1
                                configuration.context_size = 8_192
                                configuration.context_shift = 0
                                configuration.gpu_layers = 48
                                configuration.threads = 6
                                configuration.threads_batch = 5
                                configuration.batch_size = 1_024
                                configuration.ubatch_size = 256
                                configuration.use_mmap = 0
                                configuration.use_mlock = 1
                                configuration.warmup = 0
                                configuration.kv_offload = 0
                                configuration.flash_attention = 1
                                configuration.cache_type_k = cacheKPointer
                                configuration.cache_type_v = cacheVPointer
                                configuration.parallel_slots = 2
                                configuration.tensor_override = tensorPointer
                                configuration.cpu_moe = 0
                                configuration.moe_expert_count = 4
                                configuration.yarn_scale = 2
                                configuration.yarn_original_context = 4_096
                                configuration.yarn_beta_fast = 32
                                configuration.yarn_beta_slow = 1
                                configuration.cache_ram_mib = 1_024
                                configuration.ctx_checkpoints = 4
                                configuration.speculative_type = speculativePointer
                                configuration.spec_draft_n_max = 8
                                configuration.spec_draft_n_min = 1
                                configuration.spec_draft_p_min = 0.8
                                configuration.spec_dynamic = 1
                                configuration.kv_unified = 1
                                return noema_llama_server_start_with_configuration(&configuration)
                            }
                        }
                    }
                }
            }
        }
    }
    #expect(port == 0)

    let raw = String(cString: noema_llama_server_last_start_diagnostics_json())
    #expect(!raw.isEmpty)

    let data = try #require(raw.data(using: .utf8))
    let diagnostics = try JSONDecoder().decode(StartDiagnostics.self, from: data)

    #expect([
        "port_allocation_failed",
        "listener_timeout",
        "ready_timeout",
        "http_init_failed",
        "model_load_failed",
        "server_exited_early"
    ].contains(diagnostics.code))
    #expect(!diagnostics.message.isEmpty)
    #expect(diagnostics.elapsedMs >= 0)
    #expect(diagnostics.progress >= 0)
    #expect(diagnostics.progress <= 1)

    let optionsRaw = String(cString: noema_llama_server_last_start_options_json())
    let optionsData = try #require(optionsRaw.data(using: .utf8))
    let options = try JSONDecoder().decode(StartOptionsDiagnostics.self, from: optionsData)
    #expect(options.contextSize == 8_192)
    #expect(options.threads == 6)
    #expect(options.batchSize == 1_024)
    #expect(options.ubatchSize == 256)
    #expect(options.useMmap == false)
    #expect(options.useMlock == true)
    #expect(options.unifiedKVCache == true)
    #expect(options.cacheTypeK == "q4_0")
    #expect(options.cacheTypeV == "q8_0")
    #expect(options.moeExpertCount == 4)
    #expect(options.yarnScale == 2)
    #expect(options.speculativeType == "draft-simple")
    #expect(options.specDynamic == true)
    #expect(options.cacheRamMiB == 1_024)
    #expect(options.ctxCheckpoints == 4)
    #expect(options.argv.contains("--no-mmap"))
    #expect(options.argv.contains("--mlock"))
    #expect(options.argv.contains("--kv-unified"))
    #expect(options.argv.contains("--spec-draft-model"))
    #expect(options.argv.contains("--override-kv"))
    #expect(options.argv.contains("--yarn-beta-fast"))
    #expect(options.cpuRepack == true)
    #expect(options.cpuI8MM == false)
    #if arch(arm64)
    #expect(options.cpuNEON == true)
    #if os(macOS) || os(visionOS)
    #expect(options.cpuDotProduct == true)
    #endif
    #endif
}

// Memory sizing refuses to run while the server singleton is up
// (runtime_busy), so these must join the serialized suite: run in parallel
// they race any booted test server and flake.
@Test func memorySizingRequiresAModelPath() throws {
    let raw = String(cString: noema_llama_server_memory_estimate_json(
        "", "", "", 4_096, 2_048, 512, "f16", "f16",
        1_000_000, 1, 1, 1, "", 0, 0
    ))
    let data = try #require(raw.data(using: .utf8))
    let diagnostics = try JSONDecoder().decode(MemoryEstimateDiagnostics.self, from: data)
    #expect(diagnostics.status == "error")
    #expect(diagnostics.message == "missing_model_path")
}

@Test func manualNoAllocationMemorySizing() throws {
    guard ProcessInfo.processInfo.environment["NOEMA_MANUAL_MEMORY_VERIFY"] == "1" else {
        return
    }

    let modelPath = ProcessInfo.processInfo.environment["NOEMA_TEST_MODEL_PATH"] ?? "/path/to/model.gguf"
    guard FileManager.default.fileExists(atPath: modelPath) else {
        return
    }

    let raw = String(cString: noema_llama_server_memory_estimate_json(
        modelPath, "", "", 20_480, 2_048, 512, "f16", "f16",
        1_000_000, 1, 1, 1, "", 0, 0
    ))
    let data = try #require(raw.data(using: .utf8))
    let diagnostics = try JSONDecoder().decode(MemoryEstimateDiagnostics.self, from: data)
    #expect(diagnostics.status == "ok")
    let model = try #require(diagnostics.modelBytes)
    let context = try #require(diagnostics.contextBytes)
    let compute = try #require(diagnostics.computeBytes)
    let projector = try #require(diagnostics.projectorBytes)
    let speculative = try #require(diagnostics.speculativeBytes)
    let total = try #require(diagnostics.totalBytes)
    #expect(model > 0)
    #expect(context > 0)
    #expect(compute > 0)
    #expect(total == model + context + compute + projector + speculative)
}

}

extension ServerStartSerializedTests {

@Test func manualMacOSLoopbackVerification() async throws {
    guard ProcessInfo.processInfo.environment["NOEMA_MANUAL_LOOPBACK_VERIFY"] == "1" else {
        return
    }

    let modelPath = ProcessInfo.processInfo.environment["NOEMA_TEST_MODEL_PATH"] ?? "/path/to/model.gguf"
    guard FileManager.default.fileExists(atPath: modelPath) else {
        return
    }

    let port = noema_llama_server_start("127.0.0.1", 0, modelPath, "")
    #expect(port > 0)
    noema_llama_server_stop()
}

}
