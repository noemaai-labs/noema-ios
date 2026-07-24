import Foundation
import Testing
@testable import NoemaLLamaServer

// Noema Overfit wave-split expert-major prefill (streamed mode 2). Production
// boots carry the policy in the v4 contract; env knobs remain for A/B and
// forced-geometry tests. Waves split every eligible prefill MoE layer into G
// expert-group branches so at most ceil(n_expert / G) experts must be resident
// per branch, lifting the floor((n_slots - spare) / K) micro-batch clamp.
//
// All boots join the serialized start suite: the loopback server is a process
// singleton. Env knobs are read at configure time and the server runs in this
// process, so setenv/unsetenv around each boot is the established A/B pattern
// (see the coalescing and hot-protection tests).

private func withWaves<R>(forceG: Int32? = nil, _ body: () async throws -> R) async rethrows -> R {
    setenv("NOEMA_PAGED_WAVES", "1", 1)
    if let forceG {
        setenv("NOEMA_PAGED_WAVES_FORCE_G", String(forceG), 1)
    }
    defer {
        unsetenv("NOEMA_PAGED_WAVES")
        unsetenv("NOEMA_PAGED_WAVES_FORCE_G")
    }
    return try await body()
}

@_silgen_name("noema_paged_max_ubatch_for_test")
private func wave_max_ubatch_for_test(
    _ manifestPath: UnsafePointer<CChar>?,
    _ mode: Int32,
    _ slotsPerLayer: Int32
) -> Int32

@_silgen_name("noema_paged_max_draft_tokens_for_test")
private func wave_max_draft_for_test(
    _ manifestPath: UnsafePointer<CChar>?,
    _ mode: Int32,
    _ slotsPerLayer: Int32
) -> Int32

// Planning-only configure + clamp math, like OverfitPagedTests.maxUbatch but
// self-contained (that helper and its manifest builder are file-private).
private func overfitMaxClamps(
    expertCount: Int, expertsUsed: Int, mode: Int32, slots: Int32
) throws -> (ubatch: Int32, draft: Int32) {
    let recordLength = 32
    var records: [[String: Any]] = []
    var offset = 0
    for family in ["gate", "up", "down"] {
        for expert in 0..<expertCount {
            records.append([
                "layer": 0,
                "family": family,
                "expert": expert,
                "file": 0,
                "offset": offset,
                "length": recordLength,
                "xxh64": "00",
                "ggmlType": 0,
                "ne": [4, 2],
            ])
            offset += recordLength
        }
    }
    let manifest: [String: Any] = [
        "formatVersion": 1,
        "source": ["fileName": "s.gguf", "ggufSizeBytes": 1, "ggufSha256": "00"],
        "model": [
            "architecture": "qwen3moe",
            "expertCount": expertCount,
            "expertsUsedDefault": expertsUsed,
            "moeLayerCount": 1,
            "totalLayerCount": 1,
            "fusedGateUp": false,
        ],
        "alignment": 8,
        "resident": ["path": "resident.gguf", "sizeBytes": 192, "sha256": "00"],
        "expertFiles": [["path": "experts-000.bin", "sizeBytes": offset, "sha256": "00"]],
        "records": records,
        "fingerprint": "ab",
    ]
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noema-overfit-wave-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    return url.path.withCString {
        (wave_max_ubatch_for_test($0, mode, slots),
         wave_max_draft_for_test($0, mode, slots))
    }
}

extension ServerStartSerializedTests {
    @Test func legacyPagedEngineFallbacksRemainSelectable() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitWaves] fixture missing — skipping")
            return
        }
        setenv("NOEMA_PAGED_NO_EXPERT_MAJOR", "1", 1)
        setenv("NOEMA_PAGED_NO_FUSED_DECODE", "1", 1)
        defer {
            unsetenv("NOEMA_PAGED_NO_EXPERT_MAJOR")
            unsetenv("NOEMA_PAGED_NO_FUSED_DECODE")
        }
        try await withWaves(forceG: 1) {
            let port = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 8,
                ubatchSize: 2
            )
            #expect(port > 0, "legacy fallback boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else { return }
            do {
                let capture = try await overfitRunCompletion(
                    port: port, prompt: "The capital of France is", nPredict: 4)
                let stats = try #require(overfitStreamStats())
                noema_llama_server_stop()
                #expect(!capture.key.isEmpty)
                #expect(!stats.expertMajor)
                #expect(!stats.fusedDecode)
                #expect(stats.waveCount > 0,
                        "legacy placeholder-wave graph did not execute")
                #expect(stats.expertMajorAssignments == 0)
                #expect(stats.expertMajorSkippedAssignments == 0)
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }
    }

    // CLAMP LIFT MATH (no server boot). With waves on the streamed bank
    // imposes no micro-batch clamp (0 = "no clamp"): per-wave residency is
    // bounded by the expert-group width, not the micro-batch. The configure
    // floor stays K + 2 — placeholder rows borrow regular slots per token
    // instead of reserving one.
    @Test func wavesLiftUbatchClamp() throws {
        // Waves off (baseline contract, unchanged): floor((slots - 2) / K).
        let baseline = try overfitMaxClamps(expertCount: 8, expertsUsed: 2, mode: 2, slots: 8)
        #expect(baseline.ubatch == 3)
        #expect(baseline.draft == 2)
        setenv("NOEMA_PAGED_WAVES", "1", 1)
        defer { unsetenv("NOEMA_PAGED_WAVES") }
        // Waves on: no clamp anywhere above the unchanged K + 2 floor.
        let waved = try overfitMaxClamps(expertCount: 8, expertsUsed: 2, mode: 2, slots: 8)
        #expect(waved.ubatch == 0)
        #expect(waved.draft == -1, "wave verification must not retain the no-wave N + 1 cap")
        #expect(try overfitMaxClamps(expertCount: 8, expertsUsed: 2, mode: 2, slots: 5).ubatch == 0)
        #expect(try overfitMaxClamps(expertCount: 8, expertsUsed: 2, mode: 2, slots: 4).ubatch == 0)
        // Below K + 2 the configure refuses outright (-1 from the hook).
        #expect(try overfitMaxClamps(expertCount: 8, expertsUsed: 2, mode: 2, slots: 3).ubatch == -1)
        // Non-streamed modes ignore the knob entirely.
        #expect(try overfitMaxClamps(expertCount: 8, expertsUsed: 2, mode: 1, slots: 0).ubatch == 0)
    }

    // G=1 BIT-EXACT REGRESSION GUARD. NOEMA_PAGED_WAVES_FORCE_G=1 builds the
    // full wave machinery — wave route node, mask custom node, weights x mask
    // multiply — with a single group covering every expert. The mask is
    // all-ones (x * 1.0 = x exactly) and no row ever borrows a placeholder
    // slot, so completions must be BYTE-IDENTICAL to stock at the same
    // micro-batch shape. Any divergence here is a bug in the wave plumbing
    // itself, before float ordering even enters the picture. ubatch 2 keeps
    // the whole-route residency demand (<= 4 unique experts) inside the
    // 8-slot bank's headroom (8 - 2 spare = 6).
    @Test func wavesForcedSingleGroupIsBitExactWithStock() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitWaves] fixture missing — skipping")
            return
        }
        let prompts = [
            "The capital of France is",
            "1 + 1 =",
            "Write one short sentence about mountains.",
        ]

        func stockRun() async throws -> [CompletionCapture] {
            let port = overfitStartServer(
                modelPath: fixture.modelPath, pagedMode: 0, manifestPath: nil, ubatchSize: 2
            )
            #expect(port > 0, "stock@ub2 boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitWaves", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "stock boot failed",
                ])
            }
            do {
                var captures: [CompletionCapture] = []
                for prompt in prompts {
                    captures.append(try await overfitRunCompletion(port: port, prompt: prompt))
                }
                noema_llama_server_stop()
                return captures
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        func wavedRun() async throws -> (captures: [CompletionCapture], stats: OverfitStreamStats) {
            try await withWaves(forceG: 1) {
                let port = overfitStartServer(
                    modelPath: fixture.residentPath,
                    pagedMode: 2,
                    manifestPath: fixture.manifestPath,
                    slotsPerLayer: 8,
                    ubatchSize: 2
                )
                #expect(port > 0, "waves G=1 boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
                guard port > 0 else {
                    throw NSError(domain: "OverfitWaves", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "waved boot failed",
                    ])
                }
                do {
                    var captures: [CompletionCapture] = []
                    for prompt in prompts {
                        captures.append(try await overfitRunCompletion(port: port, prompt: prompt))
                    }
                    let stats = overfitStreamStats() // read before stop: teardown resets stats
                    noema_llama_server_stop()
                    return (captures, try #require(stats, "waved run exposed no stream stats"))
                } catch {
                    noema_llama_server_stop()
                    throw error
                }
            }
        }

        let stock = try await stockRun()
        let waved = try await wavedRun()
        print("[OverfitWaves] G=1 stats: waveCount=\(waved.stats.waveCount) waveStalls=\(waved.stats.waveStalls) misses=\(waved.stats.misses) hits=\(waved.stats.hits)")

        #expect(waved.captures == stock,
                "forced single-group wave graph diverged from stock — the wave machinery itself is broken")
        #expect(waved.stats.waveCount > 0,
                "NOEMA_PAGED_WAVES_FORCE_G=1 never executed a wave route node — the wave graph was not built")
        #expect(waved.stats.misses > 0, "the streamed bank never engaged")
        #expect(waved.stats.wavesRejectedReason == "engaged",
                "wave telemetry disagrees with the executed graph: \(waved.stats.wavesRejectedReason)")
        #expect(waved.stats.expertMajor, "expert-major engine was not enabled")
        #expect(waved.stats.expertMajorAssignments > 0,
                "expert-major route produced no active assignments")
        #expect(waved.stats.expertMajorSkippedAssignments == 0,
                "G=1 should cover every assignment")
    }

    // MULTI-WAVE PREFILL EQUALITY. 5 slots leave per-route headroom 5 - 2 =
    // 3, so the natural grouping is G = ceil(8 / 3) = 3 waves — while the
    // lifted clamp lets the ~440-token prompt prefill in full 512-token
    // micro-batches (the whole point: without waves this bank would clamp to
    // ONE token per graph). Greedy tokens must match stock: group-summed
    // accumulation is float-order sensitive in principle (out-of-group rows
    // add exact zeros, but mul_mat_id row batching changes), so this leg is
    // the empirical guarantee — top-1 greedy equality on the fixtures — that
    // the report documents. waveCount must show the multi-wave structure.
    @Test func wavesMultiWavePrefillMatchesStockGreedyTokens() async throws {
        let fixtures = OverfitFixture.locateAll()
        guard !fixtures.isEmpty else {
            print("[OverfitWaves] fixtures missing — skipping")
            return
        }
        for fixture in fixtures {
            print("[OverfitWaves] multi-wave equality for \(fixture.name)")
            try await runMultiWaveLeg(fixture: fixture)
        }
    }

    private func runMultiWaveLeg(fixture: OverfitFixture) async throws {
        // ~37 fixture tokens per repetition; 12 repetitions + 8 decode tokens
        // stay inside the 512-token context and prefill as one micro-batch.
        let prompts = [
            // Keeps routed matmuls below Metal's matrix-path threshold and
            // exercises the sparse vector kernel's negative-id guard.
            "The capital of France is",
            // Exercises the expert-grouped matrix path in one 512-token graph.
            Array(repeating: "mountains and rivers flow past stone", count: 12)
                .joined(separator: " "),
        ]

        func stockRun() async throws -> [String] {
            let port = overfitStartServer(modelPath: fixture.modelPath, pagedMode: 0, manifestPath: nil)
            #expect(port > 0, "stock boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitWaves", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "stock boot failed",
                ])
            }
            do {
                var captures: [String] = []
                for prompt in prompts {
                    captures.append(try await overfitRunCompletion(
                        port: port, prompt: prompt, nPredict: 8).key)
                }
                noema_llama_server_stop()
                return captures
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        func wavedRun() async throws -> (keys: [String], stats: OverfitStreamStats) {
            let port = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 5,
                pagedWaves: true,
                pagedExpertMajor: true
            )
            #expect(port > 0, "multi-wave boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitWaves", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "waved boot failed",
                ])
            }
            do {
                let options = String(cString: noema_llama_server_last_start_options_json())
                #expect(options.contains("\"ubatchSize\":512"),
                        "waves did not lift the micro-batch clamp: \(options)")
                #expect(options.contains("\"pagedWaves\":true"))
                #expect(options.contains("\"pagedExpertMajor\":true"))
                var captures: [String] = []
                for prompt in prompts {
                    captures.append(try await overfitRunCompletion(
                        port: port, prompt: prompt, nPredict: 8).key)
                }
                let stats = overfitStreamStats() // read before stop: teardown resets stats
                noema_llama_server_stop()
                return (captures, try #require(stats, "waved run exposed no stream stats"))
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        let stock = try await stockRun()
        let waved = try await wavedRun()
        print("[OverfitWaves] multi-wave stats: waveCount=\(waved.stats.waveCount) waveStalls=\(waved.stats.waveStalls) prefillBytes=\(waved.stats.prefillBytesRead) totalBytes=\(waved.stats.bytesRead) misses=\(waved.stats.misses) hits=\(waved.stats.hits)")

        #expect(waved.keys == stock,
                "multi-wave prefill changed greedy tokens vs stock: \(waved.keys) vs \(stock)")
        // At least one full 3-wave set must have executed (per waved layer per
        // prefill chunk; decode is single-call). The exact total depends on
        // chunking and llama.cpp's last-layer output pruning, so assert the
        // structure engaged rather than a brittle exact number.
        #expect(waved.stats.waveCount >= 3,
                "expected >= 3 wave route executions (one G=3 wave set), got \(waved.stats.waveCount)")
        #expect(waved.stats.misses > 0, "the streamed bank never engaged")
        #expect(waved.stats.wavesRejectedReason == "engaged",
                "wave telemetry disagrees with the executed graph: \(waved.stats.wavesRejectedReason)")
        #expect(waved.stats.expertMajor, "expert-major engine was not enabled")
        #expect(waved.stats.expertMajorAssignments > 0)
        #expect(waved.stats.expertMajorSkippedAssignments > 0,
                "multi-wave execution did not skip any out-of-group assignments")
        #expect(waved.stats.fusedDecode,
                "specialized deterministic weighted reduction was not enabled")
    }

    // WAVE I/O A/B. Same boot (6 slots), same ~440-token prompt. Without
    // waves the clamp forces floor((6 - 2) / 2) = 2-token prefill graphs:
    // hundreds of route calls re-fault experts into a thrashing 6-slot bank.
    // With waves the whole prompt prefills in 512-token graphs and each
    // layer's expert union streams through once per graph — total prefill
    // bytes must undercut the no-wave run by at least 2x on this geometry
    // (measured headroom is far larger; the bound only guards the mechanism).
    // Outputs must stay token-identical between the two legs.
    @Test func wavesPrefillBytesReadUndercutNoWaveRun() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitWaves] fixture missing — skipping")
            return
        }
        let prompt = Array(repeating: "mountains and rivers flow past stone", count: 12)
            .joined(separator: " ")

        func run(waves: Bool) async throws -> (key: String, stats: OverfitStreamStats) {
            func boot() async throws -> (key: String, stats: OverfitStreamStats) {
                let port = overfitStartServer(
                    modelPath: fixture.residentPath,
                    pagedMode: 2,
                    manifestPath: fixture.manifestPath,
                    slotsPerLayer: 6
                )
                #expect(port > 0, "wave A/B boot (waves: \(waves)) failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
                guard port > 0 else {
                    throw NSError(domain: "OverfitWaveAB", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "boot failed",
                    ])
                }
                do {
                    let capture = try await overfitRunCompletion(port: port, prompt: prompt, nPredict: 8)
                    let stats = overfitStreamStats() // read before stop: teardown resets stats
                    noema_llama_server_stop()
                    return (capture.key, try #require(stats, "wave A/B run exposed no stream stats"))
                } catch {
                    noema_llama_server_stop()
                    throw error
                }
            }
            if waves {
                return try await withWaves { try await boot() }
            }
            return try await boot()
        }

        let off = try await run(waves: false)
        let on = try await run(waves: true)
        print("[OverfitWaveAB] prefillBytesRead off=\(off.stats.prefillBytesRead) on=\(on.stats.prefillBytesRead) totalBytes off=\(off.stats.bytesRead) on=\(on.stats.bytesRead) waveCount=\(on.stats.waveCount) waveStalls=\(on.stats.waveStalls)")

        #expect(on.key == off.key, "wave-split prefill changed generated tokens vs the clamped no-wave run")
        #expect(off.stats.waveCount == 0, "no-wave run executed wave route nodes")
        #expect(on.stats.waveCount > 0, "wave run never executed a wave route node")
        // The reason string is the app-facing "did waves engage, and why not"
        // diagnostic: multi-token prefill graphs without the env knob must
        // report wavesOff; the waved boot must report engaged.
        #expect(off.stats.wavesRejectedReason == "wavesOff",
                "no-wave multi-token prefill should report wavesOff, got \(off.stats.wavesRejectedReason)")
        #expect(on.stats.wavesRejectedReason == "engaged",
                "waved run should report engaged, got \(on.stats.wavesRejectedReason)")
        #expect(off.stats.prefillBytesRead > 0, "no-wave run recorded no prefill reads — A/B premise broken")
        #expect(on.stats.prefillBytesRead * 2 <= off.stats.prefillBytesRead,
                "wave prefill read \(on.stats.prefillBytesRead) B vs \(off.stats.prefillBytesRead) B without waves — expected at least a 2x cut")
    }
}
