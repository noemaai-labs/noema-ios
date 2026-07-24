import Foundation
@testable import NoemaLLamaServer

// Shared Noema Overfit test plumbing: fixture discovery, server boots, tiny
// completions, and the debug-only native hooks (NOEMA_LLAMA_SERVER_TEST_HOOKS).

@_silgen_name("noema_paged_trace_json_for_test")
func noema_paged_trace_json_for_test() -> UnsafePointer<CChar>?

@_silgen_name("noema_paged_stats_json_for_test")
func noema_paged_stats_json_for_test() -> UnsafePointer<CChar>?

@_silgen_name("noema_paged_io_live_for_test")
func noema_paged_io_live_for_test() -> UnsafePointer<CChar>?

@_silgen_name("noema_paged_hot_protect_math_for_test")
func noema_paged_hot_protect_math_for_test() -> UnsafePointer<CChar>?

struct CompletionCapture: Equatable {
    /// Token-id sequence when the server returns one, else the raw text.
    let key: String
}

func overfitRepoRoot() -> URL {
    // <repo-root>/External/NoemaLLamaServer/Tests/NoemaLLamaServerTests/OverfitTestSupport.swift
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // NoemaLLamaServerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // NoemaLLamaServer
        .deletingLastPathComponent() // External
        .deletingLastPathComponent() // repo root
}

// Tiny MoE fixtures (2 layers x 8 experts, K = 2) plus their .noema-paged
// siblings. Discovery scans .models/fixtures for every <base>.noema-paged
// package with a complete <base>.gguf source next to it (tiny-qwen3moe,
// tiny-qwen35moe, ...).
struct OverfitFixture {
    let name: String
    let modelPath: String
    let manifestPath: String
    let residentPath: String

    /// The canonical tiny-qwen3moe pair. Tests that assert on this exact
    /// fixture geometry (e.g. streamed memory-estimate byte counts) must keep
    /// using this instead of locateAll().
    static func locate() -> OverfitFixture? {
        locateAll().first { $0.name == "tiny-qwen3moe-f16" }
    }

    /// Every complete fixture pair under .models/fixtures, sorted by name.
    static func locateAll() -> [OverfitFixture] {
        let fm = FileManager.default
        let fixtures = overfitRepoRoot().appendingPathComponent(".models/fixtures")
        let suffix = ".noema-paged"
        guard let entries = try? fm.contentsOfDirectory(atPath: fixtures.path) else {
            return []
        }
        return entries.filter { $0.hasSuffix(suffix) }.sorted().compactMap { dir in
            let base = String(dir.dropLast(suffix.count))
            let fixture = OverfitFixture(
                name: base,
                modelPath: fixtures.appendingPathComponent("\(base).gguf").path,
                manifestPath: fixtures.appendingPathComponent("\(dir)/manifest.json").path,
                residentPath: fixtures.appendingPathComponent("\(dir)/resident.gguf").path
            )
            guard fm.fileExists(atPath: fixture.modelPath),
                  fm.fileExists(atPath: fixture.manifestPath),
                  fm.fileExists(atPath: fixture.residentPath) else {
                return nil
            }
            return fixture
        }
    }
}

func overfitWithCStringOrNil<R>(
    _ string: String?, _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    if let string {
        return string.withCString { body($0) }
    }
    return body(nil)
}

func overfitStartServer(
    modelPath: String,
    pagedMode: Int32,
    manifestPath: String?,
    contextSize: Int32 = 512,
    trace: Bool = false,
    slotsPerLayer: Int32 = 0,
    ubatchSize: Int32 = 512,
    prefetch: Bool = false,
    oracleAllHit: Bool = false,
    speculativeType: String? = nil,
    draftModelPath: String? = nil,
    specDraftNMax: Int32 = 0,
    specDynamic: Bool = false,
    ctxCheckpoints: Int32 = 0,
    pagedWaves: Bool = false,
    pagedExpertMajor: Bool = false
) -> Int32 {
    let host = "127.0.0.1"
    return host.withCString { hostPointer in
        modelPath.withCString { modelPointer in
            overfitWithCStringOrNil(manifestPath) { manifestPointer -> Int32 in
                overfitWithCStringOrNil(speculativeType) { specTypePointer -> Int32 in
                    overfitWithCStringOrNil(draftModelPath) { draftPointer -> Int32 in
                        var configuration = noema_llama_server_configuration()
                        configuration.version = UInt32(NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION)
                        configuration.size = UInt32(MemoryLayout<noema_llama_server_configuration>.size)
                        configuration.host = hostPointer
                        configuration.preferred_port = 0
                        configuration.gguf_path = modelPointer
                        configuration.reasoning_budget = Int32.min
                        configuration.context_size = contextSize
                        configuration.threads = 2
                        configuration.threads_batch = 2
                        configuration.batch_size = 512
                        configuration.ubatch_size = ubatchSize
                        // Default GPU offload: parity must hold on the shipping Metal
                        // path. If Metal ever proves nondeterministic here the stock
                        // self-parity leg fails first and names the culprit.
                        configuration.gpu_layers = 999
                        configuration.parallel_slots = 1
                        configuration.speculative_type = specTypePointer
                        configuration.draft_model_path = draftPointer
                        configuration.spec_draft_n_max = specDraftNMax
                        configuration.spec_dynamic = specDynamic ? 1 : 0
                        configuration.ctx_checkpoints = ctxCheckpoints
                        configuration.paged_mode = pagedMode
                        configuration.paged_manifest_path = manifestPointer
                        configuration.paged_slots_per_layer = slotsPerLayer
                        configuration.paged_prefetch = prefetch ? 1 : 0
                        configuration.paged_oracle_all_hit = oracleAllHit ? 1 : 0
                        configuration.paged_trace = trace ? 1 : 0
                        configuration.paged_verify_checksums = 1
                        configuration.paged_waves = pagedWaves ? 1 : 0
                        configuration.paged_expert_major = pagedExpertMajor ? 1 : 0
                        return noema_llama_server_start_with_configuration(&configuration)
                    }
                }
            }
        }
    }
}

func overfitRunCompletion(
    port: Int32, prompt: String, nPredict: Int = 32
) async throws -> CompletionCapture {
    try await overfitRunCompletionDetailed(port: port, prompt: prompt, nPredict: nPredict).capture
}

/// Like `overfitRunCompletion`, but also surfaces the raw response JSON so
/// callers can assert on server-side evidence (e.g. speculative timings).
/// `cachePrompt` defaults to false because the parity legs must reprocess the
/// full prompt every run; the prefix-reuse regression test passes true — the
/// production chat path's per-request value.
func overfitRunCompletionDetailed(
    port: Int32, prompt: String, nPredict: Int = 32, cachePrompt: Bool = false
) async throws -> (capture: CompletionCapture, json: [String: Any]) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/completion")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "prompt": prompt,
        "n_predict": nPredict,
        "temperature": 0,
        "top_k": 1,
        "seed": 42,
        "cache_prompt": cachePrompt,
        "return_tokens": true,
        // The random-weight fixture's greedy tokens are arbitrary bytes, and
        // this fork parses even /completion output as a chat message — invalid
        // UTF-8 would 500. Constrain sampling to printable ASCII; stock and
        // paged runs share the identical mask, so parity semantics hold.
        "grammar": "root ::= [ -~]*",
    ] as [String: Any])

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard status == 200 else {
        throw NSError(domain: "OverfitParity", code: status, userInfo: [
            NSLocalizedDescriptionKey:
                "completion HTTP \(status): \(String(data: data, encoding: .utf8) ?? "<binary>")",
        ])
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    if let tokens = json["tokens"] as? [Int], !tokens.isEmpty {
        return (CompletionCapture(key: "tokens:" + tokens.map(String.init).joined(separator: ",")), json)
    }
    let content = json["content"] as? String ?? ""
    return (CompletionCapture(key: "text:" + content), json)
}

/// Token ids the server's model assigns to `content` (POST /tokenize).
func overfitTokenize(port: Int32, content: String) async throws -> [Int] {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tokenize")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 60
    request.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard status == 200 else {
        throw NSError(domain: "OverfitParity", code: status, userInfo: [
            NSLocalizedDescriptionKey:
                "tokenize HTTP \(status): \(String(data: data, encoding: .utf8) ?? "<binary>")",
        ])
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return json["tokens"] as? [Int] ?? []
}

func overfitPagedStatsJSON() -> String {
    noema_paged_stats_json_for_test().map { String(cString: $0) } ?? ""
}

struct OverfitStreamStats {
    let hits: UInt64
    let misses: UInt64
    let commits: UInt64
    let bytesRead: UInt64
    let prefillBytesRead: UInt64
    let prefetchIssued: UInt64
    let prefetchEvicted: UInt64
    let historyPredictions: UInt64
    let historyPredictionMatches: UInt64
    let sweepPrefetchIssued: UInt64
    let ioReads: UInt64
    let coalescedReads: UInt64
    let coalescedBytes: UInt64
    let protectedSkips: UInt64
    let hotThreshold: UInt64
    let waveCount: UInt64
    let waveStalls: UInt64
    let directReads: UInt64
    let directBytes: UInt64
    let checksumVerifications: UInt64
    let checksumCacheHits: UInt64
    let layerExecutions: UInt64
    let allHitLayerExecutions: UInt64
    let expertMajorAssignments: UInt64
    let expertMajorSkippedAssignments: UInt64
    let directIO: Bool
    let gpuRouteHitPath: Bool
    let fusedDecode: Bool
    let expertMajor: Bool
    /// Latest wave-gate verdict for a multi-token prefill layer ("engaged",
    /// "fitsSingleCall", "wavesOff", "biases", ... — see wave_reason in
    /// noema_paged_runtime.cpp); "none" before any multi-token routed graph.
    let wavesRejectedReason: String
}

func overfitStreamStats() -> OverfitStreamStats? {
    guard let data = overfitPagedStatsJSON().data(using: .utf8),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let stream = json["stream"] as? [String: Any] else {
        return nil
    }
    func u64(_ key: String) -> UInt64 {
        (stream[key] as? NSNumber)?.uint64Value ?? 0
    }
    return OverfitStreamStats(
        hits: u64("hits"),
        misses: u64("misses"),
        commits: u64("commits"),
        bytesRead: u64("bytesRead"),
        prefillBytesRead: u64("prefillBytesRead"),
        prefetchIssued: u64("prefetchIssued"),
        prefetchEvicted: u64("prefetchEvicted"),
        historyPredictions: u64("historyPredictions"),
        historyPredictionMatches: u64("historyPredictionMatches"),
        sweepPrefetchIssued: u64("sweepPrefetchIssued"),
        ioReads: u64("ioReads"),
        coalescedReads: u64("coalescedReads"),
        coalescedBytes: u64("coalescedBytes"),
        protectedSkips: u64("protectedSkips"),
        hotThreshold: u64("hotThreshold"),
        waveCount: u64("waveCount"),
        waveStalls: u64("waveStalls"),
        directReads: u64("directReads"),
        directBytes: u64("directBytes"),
        checksumVerifications: u64("checksumVerifications"),
        checksumCacheHits: u64("checksumCacheHits"),
        layerExecutions: u64("layerExecutions"),
        allHitLayerExecutions: u64("allHitLayerExecutions"),
        expertMajorAssignments: u64("expertMajorAssignments"),
        expertMajorSkippedAssignments: u64("expertMajorSkippedAssignments"),
        directIO: (json["directIO"] as? Bool) ?? false,
        gpuRouteHitPath: (json["gpuRouteHitPath"] as? Bool) ?? false,
        fusedDecode: (json["fusedDecode"] as? Bool) ?? false,
        expertMajor: (json["expertMajor"] as? Bool) ?? false,
        wavesRejectedReason: (stream["wavesRejectedReason"] as? String) ?? "none"
    )
}

/// POST /slots/0?action=save|restore|erase with the given filename. Requires
/// a server started with --slot-save-path (paged boots gate that on the
/// NOEMA_PAGED_SLOT_SAVE_DIR env var). Returns the response JSON, e.g.
/// {n_saved, n_written} for save and {n_restored, n_read} for restore.
func overfitSlotAction(
    port: Int32, action: String, filename: String
) async throws -> [String: Any] {
    var request = URLRequest(
        url: URL(string: "http://127.0.0.1:\(port)/slots/0?action=\(action)")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120
    request.httpBody = try JSONSerialization.data(withJSONObject: ["filename": filename])
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard status == 200 else {
        throw NSError(domain: "OverfitSlotAction", code: status, userInfo: [
            NSLocalizedDescriptionKey:
                "slot \(action) HTTP \(status): \(String(data: data, encoding: .utf8) ?? "<binary>")",
        ])
    }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

// Teardown-completeness oracle: after a stop both counts must read 0.
struct OverfitIOLive: Equatable {
    let threads: Int
    let buffers: Int
}

func overfitIOLive() -> OverfitIOLive {
    guard let raw = noema_paged_io_live_for_test().map({ String(cString: $0) }),
          let data = raw.data(using: .utf8),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return OverfitIOLive(threads: -1, buffers: -1)
    }
    return OverfitIOLive(
        threads: (json["threads"] as? NSNumber)?.intValue ?? -1,
        buffers: (json["buffers"] as? NSNumber)?.intValue ?? -1
    )
}
