import Foundation
import Testing
@testable import NoemaLLamaServer

// Noema Overfit parity harness (manual, env-gated like manualMacOSLoopbackVerification):
//
//   NOEMA_OVERFIT_PARITY=1 swift test -c debug --filter pagedModeMatchesStockOutputs
//
// Runs once per fixture pair discovered under <repo-root>/.models/fixtures/
// (every <base>.gguf with a sibling <base>.noema-paged/ package — currently
// tiny-qwen3moe-f16 and tiny-qwen35moe-f16).
//
// Flow per fixture: boot stock twice (self-parity guard against
// nondeterminism, e.g. Metal scheduling), then boot paged mode 1 with tracing
// and require byte-identical completions plus a non-empty route trace.
// Streamed mode 2 clamps its micro-batch to floor((n_slots - 2) / K), so each
// streamed leg is anchored by a stock baseline at the SAME clamped ubatch:
// slots=4 -> ub 1 (this leg must additionally prove eviction ran: misses AND
// hits) and slots=8 (full bank) -> ub 3. Boots are sequential because the
// loopback server is a process singleton.

private let parityPrompts = [
    "The capital of France is",
    "1 + 1 =",
    "Write one short sentence about mountains.",
]

private func captureAll(port: Int32) async throws -> [CompletionCapture] {
    var captures: [CompletionCapture] = []
    for prompt in parityPrompts {
        captures.append(try await overfitRunCompletion(port: port, prompt: prompt))
    }
    return captures
}

// Joins the serialized start suite declared in OverfitPagedTests.swift — the
// loopback server is a process singleton, so boots must never overlap.
extension ServerStartSerializedTests {
    @Test func pagedModeMatchesStockOutputs() async throws {
        guard ProcessInfo.processInfo.environment["NOEMA_OVERFIT_PARITY"] == "1" else {
            return // manual harness; enable with NOEMA_OVERFIT_PARITY=1
        }
        var fixtures = OverfitFixture.locateAll()
        if let requested = ProcessInfo.processInfo.environment["NOEMA_OVERFIT_FIXTURE"],
           !requested.isEmpty {
            fixtures = fixtures.filter { $0.name == requested }
        }
        guard !fixtures.isEmpty else {
            print("[OverfitParity] no fixtures under \(overfitRepoRoot().path)/.models/fixtures — skipping")
            return
        }
        for fixture in fixtures {
            print("[OverfitParity] running 8-leg parity for \(fixture.name)")
            try await runParityLegs(fixture: fixture)
        }
    }

    private func runParityLegs(fixture: OverfitFixture) async throws {
        let name = fixture.name

        // (a) stock baseline
        let stockPort = overfitStartServer(modelPath: fixture.modelPath, pagedMode: 0, manifestPath: nil)
        #expect(stockPort > 0, "\(name): stock boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard stockPort > 0 else { return }
        let stock = try await captureAll(port: stockPort)
        noema_llama_server_stop()

        // (b) stock again — self-parity guards the harness itself
        let repeatPort = overfitStartServer(modelPath: fixture.modelPath, pagedMode: 0, manifestPath: nil)
        #expect(repeatPort > 0)
        guard repeatPort > 0 else { return }
        let stockRepeat = try await captureAll(port: repeatPort)
        noema_llama_server_stop()
        #expect(stockRepeat == stock, "\(name): stock boots disagree with each other; fix determinism before judging paged mode")

        // (c) paged mode 1 with tracing. The paged boot loads the package's
        // resident GGUF — routed experts are absent from its tensor table and
        // arrive from the sidecar through the bank preload.
        let pagedPort = overfitStartServer(
            modelPath: fixture.residentPath, pagedMode: 1,
            manifestPath: fixture.manifestPath, trace: true
        )
        #expect(pagedPort > 0, "\(name): paged boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard pagedPort > 0 else { return }
        let paged = try await captureAll(port: pagedPort)

        let traceRaw = noema_paged_trace_json_for_test().map { String(cString: $0) } ?? ""
        let residentStatsRaw = overfitPagedStatsJSON()
        noema_llama_server_stop()

        #expect(paged == stock, "\(name): paged completions diverge from stock")

        let traceData = traceRaw.data(using: .utf8) ?? Data()
        let traceJSON = (try? JSONSerialization.jsonObject(with: traceData)) as? [String: Any]
        let entries = traceJSON?["entries"] as? [[String: Any]] ?? []
        let residentStatsData = residentStatsRaw.data(using: .utf8) ?? Data()
        let residentStatsJSON = (try? JSONSerialization.jsonObject(with: residentStatsData)) as? [String: Any]
        let gpuRouteHitPath = residentStatsJSON?["gpuRouteHitPath"] as? Bool ?? false
        // The resident GPU all-hit path deliberately bypasses the CPU route
        // callback: logical expert ids are already identity-mapped to slots,
        // so an empty trace is expected there. With that optimization off,
        // the callback must still prove it executed.
        #expect(gpuRouteHitPath || !entries.isEmpty,
                "\(name): paged run recorded no route-trace entries: \(traceRaw)")

        // (d) stock at ubatch=1 — the streamed bridge clamps the micro-batch
        // to floor((n_slots - 2) / K) = 1 for the 4-slot legs, so their
        // baseline must share that shape; divergence here is backend kernel
        // selection, not paging.
        let ub1Port = overfitStartServer(
            modelPath: fixture.modelPath, pagedMode: 0, manifestPath: nil, ubatchSize: 1
        )
        #expect(ub1Port > 0)
        guard ub1Port > 0 else { return }
        let stockUb1 = try await captureAll(port: ub1Port)
        noema_llama_server_stop()
        #expect(stockUb1 == stock, "\(name): stock ubatch=1 diverges from stock ubatch=512; fix backend determinism before judging streamed mode")

        // (e) streamed mode 2 — 4 slots of 8 experts forces real eviction.
        let streamedPort = overfitStartServer(
            modelPath: fixture.residentPath, pagedMode: 2,
            manifestPath: fixture.manifestPath, slotsPerLayer: 4
        )
        #expect(streamedPort > 0, "\(name): streamed boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard streamedPort > 0 else { return }
        let streamed = try await captureAll(port: streamedPort)
        let streamStats = overfitStreamStats()
        noema_llama_server_stop()

        #expect(streamed == stock, "\(name): streamed completions diverge from stock")
        #expect(streamed == stockUb1, "\(name): streamed completions diverge from the ubatch=1 stock baseline")
        let stats = try #require(streamStats, "\(name): streamed run exposed no stream stats")
        #expect(stats.misses > 0, "\(name): streamed run recorded no bank misses — eviction was not exercised")
        #expect(stats.hits > 0, "\(name): streamed run recorded no bank hits — eviction was not exercised")
        print("[OverfitParity] \(name) streamed stats: hits=\(stats.hits) misses=\(stats.misses) commits=\(stats.commits)")

        // (f) streamed mode 2 with temporal prefetch — slot placement changes,
        // outputs must not (prefetch is performance only, never correctness).
        let prefetchPort = overfitStartServer(
            modelPath: fixture.residentPath, pagedMode: 2,
            manifestPath: fixture.manifestPath, slotsPerLayer: 4, prefetch: true
        )
        #expect(prefetchPort > 0, "\(name): streamed+prefetch boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard prefetchPort > 0 else { return }
        let prefetched = try await captureAll(port: prefetchPort)
        let prefetchStats = overfitStreamStats()
        noema_llama_server_stop()

        #expect(prefetched == stock, "\(name): streamed+prefetch completions diverge from stock")
        let pf = try #require(prefetchStats, "\(name): streamed+prefetch run exposed no stream stats")
        #expect(pf.prefetchIssued > 0, "\(name): prefetch was enabled but never issued a request")
        print("[OverfitParity] \(name) prefetch stats: issued=\(pf.prefetchIssued) evicted=\(pf.prefetchEvicted) misses=\(pf.misses) hits=\(pf.hits)")

        // (g) stock at ubatch=3 — the clamped micro-batch of the full-bank
        // streamed leg below: max_ubatch = floor((8 - 2) / 2) = 3 for the
        // tiny fixture geometry (8 experts, K = 2).
        let ub3Port = overfitStartServer(
            modelPath: fixture.modelPath, pagedMode: 0, manifestPath: nil, ubatchSize: 3
        )
        #expect(ub3Port > 0)
        guard ub3Port > 0 else { return }
        let stockUb3 = try await captureAll(port: ub3Port)
        noema_llama_server_stop()
        #expect(stockUb3 == stock, "\(name): stock ubatch=3 diverges from stock ubatch=512; fix backend determinism before judging the clamped streamed leg")

        // (h) streamed mode 2 with the full 8-slot bank: the adaptive clamp
        // must turn the requested ubatch 512 into 3, and the run must match
        // the stock baseline at that exact micro-batch shape.
        let fullBankPort = overfitStartServer(
            modelPath: fixture.residentPath, pagedMode: 2,
            manifestPath: fixture.manifestPath, slotsPerLayer: 8
        )
        #expect(fullBankPort > 0, "\(name): full-bank streamed boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard fullBankPort > 0 else { return }
        let fullBankOptions = String(cString: noema_llama_server_last_start_options_json())
        #expect(fullBankOptions.contains("\"ubatchSize\":3"),
                "\(name): full-bank streamed run did not clamp ubatch 512 -> 3: \(fullBankOptions)")
        let fullBank = try await captureAll(port: fullBankPort)
        noema_llama_server_stop()

        #expect(fullBank == stockUb3, "\(name): streamed@ub3 completions diverge from stock@ub3")
        #expect(fullBank == stock, "\(name): streamed@ub3 completions diverge from stock")
    }
}
