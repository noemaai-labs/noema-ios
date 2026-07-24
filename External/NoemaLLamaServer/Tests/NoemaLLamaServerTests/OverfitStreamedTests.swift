import Foundation
import Testing
@testable import NoemaLLamaServer

private struct OverfitPagedPhaseStats {
    let routeCalls: UInt64
    let bytesRead: UInt64
    let layers: [[String: Any]]
}

private func overfitPagedPhaseStats(
    _ raw: String, phase: String
) -> OverfitPagedPhaseStats? {
    guard let data = raw.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let phases = root["phases"] as? [String: Any],
          let value = phases[phase] as? [String: Any] else {
        return nil
    }
    return OverfitPagedPhaseStats(
        routeCalls: (value["routeCalls"] as? NSNumber)?.uint64Value ?? 0,
        bytesRead: (value["bytesRead"] as? NSNumber)?.uint64Value ?? 0,
        layers: value["layers"] as? [[String: Any]] ?? []
    )
}

// Noema Overfit streamed-mode (mode 2) boot and lifecycle coverage. Boots are
// real Metal loads of the tiny fixture (skipped when absent); the repeated
// start/stop and cancel cycles join the manual parity harness gate:
//
//   NOEMA_OVERFIT_PARITY=1 swift test -c debug
//
// All tests join the serialized start suite — the loopback server is a
// process singleton, so boots must never overlap.

// HOT-EXPERT PROTECTION MATH (no server boot). The debug hook drives the
// exact production functions on a synthetic 6-slot/8-expert bank:
// saturation, the max/4 threshold, the 4096-route-call halving, and the
// CLOCK livelock drill — with every slot hot, ref'd and unpinned, n_slots
// consecutive selects must still evict n_slots distinct victims, with grants
// capped at half the non-pinned slots and every grant spent by the end.
@Test func streamedHotProtectMathAndLivelockDrill() throws {
    let raw = try #require(
        noema_paged_hot_protect_math_for_test().map { String(cString: $0) })
    let data = try #require(raw.data(using: .utf8))
    let json = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any], "bad hook JSON: \(raw)")
    func num(_ key: String) -> Int {
        (json[key] as? NSNumber)?.intValue ?? -1
    }
    // uint16 counters saturate instead of wrapping; threshold = max / 4.
    #expect(num("saturated") == 65535)
    #expect(num("thresholdSaturated") == 16383)
    // Counters halve after exactly 4096 route calls; max is recomputed so the
    // threshold follows (32767 / 4 = 8191), and low counters halve too.
    #expect(num("ticksToDecay") == 4096)
    #expect(num("decayedHit") == 32767)
    #expect(num("decayedLow") == 50)
    #expect(num("decayedThreshold") == 8191)
    // Livelock drill: every select found a victim, all six slots were evicted
    // (each exactly once), grants stopped at the cap floor(6/2) = 3, and no
    // protected residue survived the sweep. The expected orders are exact:
    // protection defers the three capped hot slots one hand pass (victims
    // 3,4,5 evict first, then the protected 0,1,2 are spent on sight), while
    // the plain CLOCK evicts in hand order.
    #expect(json["victims"] as? [Int] == [3, 4, 5, 0, 1, 2])
    #expect(num("protectedSkips") == 3)
    #expect(num("protectedCountAfter") == 0)
    #expect(json["victimsNoProtect"] as? [Int] == [0, 1, 2, 3, 4, 5])
    #expect(num("noProtectSkips") == 0)
}

extension ServerStartSerializedTests {
    // Default-suite leg: mode 2 with a valid manifest now boots, streams
    // expert groups on demand and evicts (4 slots < 8 experts, floor K+2=4).
    @Test func streamedModeBootsAndStreams() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitStreamed] fixture missing under \(overfitRepoRoot().path)/.models/fixtures — skipping")
            return
        }
        let port = overfitStartServer(
            modelPath: fixture.residentPath,
            pagedMode: 2,
            manifestPath: fixture.manifestPath,
            slotsPerLayer: 4
        )
        #expect(port > 0, "streamed boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard port > 0 else { return }

        let capture = try await overfitRunCompletion(
            port: port, prompt: "The capital of France is", nPredict: 16
        )
        #expect(!capture.key.isEmpty)
        let raw = overfitPagedStatsJSON() // read before stop: teardown resets stats
        let stats = overfitStreamStats()
        let promptPhase = overfitPagedPhaseStats(raw, phase: "promptPrefill")
        let decodePhase = overfitPagedPhaseStats(raw, phase: "ordinaryDecode")
        let verifyPhase = overfitPagedPhaseStats(raw, phase: "speculativeVerify")
        let root = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        noema_llama_server_stop()

        print("[OverfitStreamed] stats: \(raw)")
        let stream = try #require(stats, "streamed run exposed no stream stats")
        #expect(stream.misses > 0, "no bank misses recorded — the streaming path never engaged")
        #expect(stream.commits > 0, "no expert groups were committed into slots")
        #expect(stream.bytesRead > 0)
        #expect(stream.directIO, "direct-to-bank I/O was not enabled")
        #expect(stream.directBytes > 0,
                "verified demand reads never landed in final shared bank memory")
        #expect(stream.gpuRouteHitPath, "GPU all-hit route path was not enabled")
        #expect(stream.fusedDecode, "specialized MoE weighted reduction was not enabled")
        #expect(stream.layerExecutions > 0,
                "natural all-hit ceiling telemetry recorded no MoE layers")
        #expect(stream.allHitLayerExecutions <= stream.layerExecutions)
        let prompt = try #require(promptPhase, "prompt phase telemetry missing: \(raw)")
        let decode = try #require(decodePhase, "decode phase telemetry missing: \(raw)")
        let verify = try #require(verifyPhase, "verify phase telemetry missing: \(raw)")
        #expect(prompt.routeCalls > 0)
        #expect(prompt.bytesRead > 0)
        #expect(!prompt.layers.isEmpty, "prompt phase has no per-layer telemetry")
        #expect(decode.routeCalls > 0)
        #expect(!decode.layers.isEmpty, "decode phase has no per-layer telemetry")
        #expect(verify.routeCalls == 0,
                "plain decoding was misclassified as speculative verification")
        #expect(root?["executionPhase"] as? String == "unknown",
                "execution phase was not restored after completion: \(raw)")
        #expect(overfitIOLive() == OverfitIOLive(threads: 0, buffers: 0),
                "io threads/staging survived the stop")
    }

    // PREFILL SWEEP-PREFETCH A/B. Six slots clamp the prefill micro-batch to
    // floor((6 - 2) / 2) = 2, so a ~440-token prompt drives hundreds of
    // multi-token prefill route calls with real eviction (6 slots < 8
    // experts). The sweep (prefetch flag, prefill calls only) is one bounded
    // sequential pass per prefill, so sweep-on prefill reads must stay within
    // one sweep pass (n_expert x moe layers x group bytes) of the sweep-off
    // demand baseline — a regression here means the sweep started chasing its
    // own evictions. Outputs must be byte-identical: prefetch is performance
    // only, never correctness.
    @Test func streamedPrefillSweepKeepsPrefillReadsBounded() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitStreamed] fixture missing — skipping")
            return
        }
        // Stop the server on EVERY exit path: a live singleton would stall the
        // next boot in the serialized suite until its 60 s listen timeout.
        func run(prefetch: Bool) async throws -> (key: String, stats: OverfitStreamStats) {
            let port = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 6,
                prefetch: prefetch
            )
            #expect(port > 0, "sweep A/B boot (prefetch: \(prefetch)) failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitSweepAB", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "boot failed",
                ])
            }
            do {
                // ~37 fixture tokens per repetition; 12 repetitions plus 8
                // decode tokens stay inside the 512-token context.
                let prompt = Array(repeating: "mountains and rivers flow past stone", count: 12)
                    .joined(separator: " ")
                let capture = try await overfitRunCompletion(port: port, prompt: prompt, nPredict: 8)
                let stats = overfitStreamStats() // read before stop: teardown resets stats
                noema_llama_server_stop()
                return (capture.key, try #require(stats, "sweep A/B run exposed no stream stats"))
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        let off = try await run(prefetch: false)
        let on = try await run(prefetch: true)
        print("[OverfitSweepAB] prefillBytesRead off=\(off.stats.prefillBytesRead) on=\(on.stats.prefillBytesRead) sweepIssued=\(on.stats.sweepPrefetchIssued) totalBytes off=\(off.stats.bytesRead) on=\(on.stats.bytesRead)")

        #expect(on.key == off.key, "sweep prefetch changed generated tokens")

        #expect(off.stats.prefillBytesRead > 0, "long prompt produced no prefill reads")
        #expect(off.stats.bytesRead >= off.stats.prefillBytesRead)
        #expect(off.stats.sweepPrefetchIssued == 0, "sweep issued with the prefetch flag off")
        #expect(on.stats.sweepPrefetchIssued > 0, "prefill sweep never issued a request")
        #expect(on.stats.historyPredictions > 0,
                "ordinary decode never used previous-token same-layer routing history")
        #expect(on.stats.historyPredictionMatches <= on.stats.historyPredictions)
        #expect(on.stats.checksumVerifications > 0,
                "first reads did not verify immutable expert records")
        #expect(on.stats.checksumCacheHits > 0,
                "expert re-reads kept hashing records already verified this boot")

        // Fixture geometry: group = 3 families x 12,288 B, 8 experts, 2 MoE
        // layers -> one full sweep pass is at most 16 groups.
        let sweepPassBytes: UInt64 = 36_864 * 8 * 2
        #expect(on.stats.prefillBytesRead <= off.stats.prefillBytesRead + sweepPassBytes,
                "sweep-on prefill read \(on.stats.prefillBytesRead) B vs \(off.stats.prefillBytesRead) B sweep-off — sweep speculation is unbounded")
    }

    // READ COALESCING A/B. The converter lays records out family-major
    // (gate e0..eN, up e0..eN, ...), each aligned up, so records of
    // consecutive experts sit adjacent-or-near (gap <= alignment) in the
    // payload — proven from the manifest offsets below, not assumed. Demand
    // misses of one route call and sweep-prefetch passes submit as single io
    // batches, and whichever worker dequeues first gathers the whole
    // co-queued batch, so adjacent records merge into single preads
    // deterministically. Coalescing is I/O mechanics only: outputs must stay
    // byte-identical, and the merged run must issue strictly fewer payload
    // preads than the same run with NOEMA_PAGED_NO_COALESCE=1.
    @Test func streamedReadCoalescingMergesAdjacentRecords() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitCoalesce] fixture missing — skipping")
            return
        }

        // (1) Premise check from the manifest itself: every consecutive-expert
        // record pair within one (layer, family, file) is adjacent-or-near.
        struct Rec {
            let layer: Int, family: String, expert: Int, file: Int
            let offset: UInt64, length: UInt64
        }
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: fixture.manifestPath))
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let alignment = try #require((manifest["alignment"] as? NSNumber)?.uint64Value)
        let rawRecords = try #require(manifest["records"] as? [[String: Any]])
        let records = rawRecords.map { r in
            Rec(
                layer: (r["layer"] as? NSNumber)?.intValue ?? -1,
                family: r["family"] as? String ?? "?",
                expert: (r["expert"] as? NSNumber)?.intValue ?? -1,
                file: (r["file"] as? NSNumber)?.intValue ?? -1,
                offset: (r["offset"] as? NSNumber)?.uint64Value ?? 0,
                length: (r["length"] as? NSNumber)?.uint64Value ?? 0
            )
        }
        var adjacentPairs = 0
        let groups = Dictionary(grouping: records) { "\($0.layer)/\($0.family)/\($0.file)" }
        for group in groups.values {
            let sorted = group.sorted { $0.expert < $1.expert }
            for (a, b) in zip(sorted, sorted.dropFirst()) where b.expert == a.expert + 1 {
                let end = a.offset + a.length
                #expect(b.offset >= end, "manifest records overlap")
                #expect(b.offset - end <= alignment,
                        "experts \(a.expert)/\(b.expert) of layer \(a.layer) \(a.family) are not adjacent-or-near (gap \(b.offset - end) > alignment \(alignment))")
                adjacentPairs += 1
            }
        }
        #expect(adjacentPairs > 0, "fixture has no consecutive-expert record pairs — coalescing premise broken")

        // (2) A/B runs: identical boot and prompt, coalescing toggled via the
        // internal env knob (read at configure time; the server runs in this
        // process). Stop the server on EVERY exit path.
        func run(coalesce: Bool) async throws -> (key: String, stats: OverfitStreamStats) {
            if !coalesce { setenv("NOEMA_PAGED_NO_COALESCE", "1", 1) }
            defer { unsetenv("NOEMA_PAGED_NO_COALESCE") }
            let port = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 6,
                prefetch: true
            )
            #expect(port > 0, "coalesce A/B boot (coalesce: \(coalesce)) failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitCoalesceAB", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "boot failed",
                ])
            }
            do {
                // Long prompt: hundreds of prefill route calls with eviction
                // churn (6 slots < 8 experts) plus sweep passes — plenty of
                // co-queued adjacent-record batches.
                let prompt = Array(repeating: "mountains and rivers flow past stone", count: 12)
                    .joined(separator: " ")
                let capture = try await overfitRunCompletion(port: port, prompt: prompt, nPredict: 8)
                let stats = overfitStreamStats() // read before stop: teardown resets stats
                noema_llama_server_stop()
                return (capture.key, try #require(stats, "coalesce A/B run exposed no stream stats"))
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        let on = try await run(coalesce: true)
        let off = try await run(coalesce: false)
        print("[OverfitCoalesceAB] ioReads on=\(on.stats.ioReads) off=\(off.stats.ioReads) coalescedReads=\(on.stats.coalescedReads) coalescedBytes=\(on.stats.coalescedBytes) commits on=\(on.stats.commits) off=\(off.stats.commits)")

        #expect(on.key == off.key, "read coalescing changed generated tokens")
        #expect(off.stats.coalescedReads == 0, "NOEMA_PAGED_NO_COALESCE=1 still merged reads")
        #expect(off.stats.coalescedBytes == 0)
        #expect(on.stats.coalescedReads > 0, "adjacent expert records never coalesced into a merged pread")
        #expect(on.stats.coalescedBytes > 0)
        #expect(on.stats.ioReads > 0 && off.stats.ioReads > 0, "runs recorded no payload reads")
        #expect(on.stats.ioReads < off.stats.ioReads,
                "coalesced run issued \(on.stats.ioReads) payload reads vs \(off.stats.ioReads) without coalescing — merging saved nothing")
    }

    // F_NOCACHE ENV PLUMBING. The app decides per-launch — from measured
    // storage calibration — whether expert payload reads should bypass the
    // unified buffer cache, exporting NOEMA_PAGED_NOCACHE=1 before the boot.
    // The knob must be sampled at configure time (every start), not latched
    // at process start, so both states are exercised inside one process and
    // the top-level stats key ioNoCache must report the effective state each
    // time. F_NOCACHE is I/O mechanics only: outputs stay byte-identical.
    @Test func streamedStatsReportEffectiveNoCacheState() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitNoCache] fixture missing — skipping")
            return
        }

        // Stop the server on EVERY exit path.
        func run(nocache: Bool) async throws -> (key: String, ioNoCache: Bool?) {
            if nocache { setenv("NOEMA_PAGED_NOCACHE", "1", 1) }
            defer { unsetenv("NOEMA_PAGED_NOCACHE") }
            let port = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 6,
                prefetch: true
            )
            #expect(port > 0, "nocache A/B boot (nocache: \(nocache)) failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitNoCacheAB", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "boot failed",
                ])
            }
            do {
                let capture = try await overfitRunCompletion(
                    port: port, prompt: "mountains and rivers flow past stone", nPredict: 8)
                // Read before stop: teardown resets stats.
                let stats = (try? JSONSerialization.jsonObject(
                    with: Data(overfitPagedStatsJSON().utf8))) as? [String: Any]
                noema_llama_server_stop()
                return (capture.key, stats?["ioNoCache"] as? Bool)
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        let off = try await run(nocache: false)
        let on = try await run(nocache: true)
        print("[OverfitNoCacheAB] ioNoCache off=\(String(describing: off.ioNoCache)) on=\(String(describing: on.ioNoCache))")
        #expect(off.ioNoCache == false,
                "env unset reported ioNoCache=\(String(describing: off.ioNoCache)) — stale latch or missing stats key")
        #expect(on.ioNoCache == true,
                "NOEMA_PAGED_NOCACHE=1 reported ioNoCache=\(String(describing: on.ioNoCache)) — env latched before configure?")
        #expect(on.key == off.key, "F_NOCACHE changed generated tokens")
    }

    // HOT-EXPERT PROTECTION A/B. Same boot and long prompt with real eviction
    // churn (6 slots < 8 experts), protection toggled via the internal env
    // knob. Protection is eviction policy only, so outputs must stay
    // byte-identical, and giving hot experts one extra second-chance must
    // never cost hit rate beyond noise: on >= off - epsilon. The off run must
    // never skip a victim (grants gated on the knob); the on run must
    // actually exercise protection (deterministic on this fixture at temp 0).
    @Test func streamedHotProtectionABKeepsHitRateAndOutputs() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitHotProtect] fixture missing — skipping")
            return
        }
        // Stop the server on EVERY exit path: a live singleton would stall the
        // next boot in the serialized suite until its 60 s listen timeout.
        func run(protect: Bool) async throws -> (key: String, stats: OverfitStreamStats) {
            if !protect { setenv("NOEMA_PAGED_NO_HOT_PROTECT", "1", 1) }
            defer { unsetenv("NOEMA_PAGED_NO_HOT_PROTECT") }
            let port = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 6
            )
            #expect(port > 0, "hot-protect A/B boot (protect: \(protect)) failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitHotProtectAB", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "boot failed",
                ])
            }
            do {
                let prompt = Array(repeating: "mountains and rivers flow past stone", count: 12)
                    .joined(separator: " ")
                let capture = try await overfitRunCompletion(port: port, prompt: prompt, nPredict: 8)
                let stats = overfitStreamStats() // read before stop: teardown resets stats
                noema_llama_server_stop()
                return (capture.key, try #require(stats, "hot-protect A/B run exposed no stream stats"))
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        let on = try await run(protect: true)
        let off = try await run(protect: false)
        func hitRate(_ s: OverfitStreamStats) -> Double {
            let total = s.hits + s.misses
            return total > 0 ? Double(s.hits) / Double(total) : 0
        }
        print("[OverfitHotProtectAB] hitRate on=\(hitRate(on.stats)) off=\(hitRate(off.stats)) protectedSkips on=\(on.stats.protectedSkips) off=\(off.stats.protectedSkips) hotThreshold on=\(on.stats.hotThreshold) off=\(off.stats.hotThreshold)")

        #expect(on.key == off.key, "hot-expert protection changed generated tokens")
        #expect(off.stats.protectedSkips == 0, "NOEMA_PAGED_NO_HOT_PROTECT=1 still granted protection")
        #expect(on.stats.protectedSkips > 0, "protection never skipped a hot victim — the feature did not engage")
        // Hit counting runs in both legs (the knob gates eviction policy
        // only), so both report a live threshold once the trace warms up.
        #expect(on.stats.hotThreshold > 0)
        #expect(off.stats.hotThreshold > 0)
        #expect(on.stats.hits + on.stats.misses > 0 && off.stats.hits + off.stats.misses > 0,
                "A/B runs recorded no route traffic")
        #expect(hitRate(on.stats) >= hitRate(off.stats) - 0.05,
                "protection cost hit rate: on=\(hitRate(on.stats)) off=\(hitRate(off.stats))")
    }

    // HELPER-DRAFT SPECULATION UNDER THE STREAMED BANK. Target =
    // tiny-qwen35moe streamed with 6 slots (verification batch cap =
    // floor((6 - 2) / 2) = 2, so the N + 1-safe draft cap is one token);
    // draft = the tiny-qwen3moe FULL GGUF
    // loading resident beside it (different architecture on purpose — the
    // bank finalize latch and the tensor-identity route gate must keep the
    // draft's own MoE graphs out of the paged hooks). Both fixtures share
    // the 256-token GPT-2 byte tokenizer; the /tokenize cross-check proves
    // the ids drafting relies on map identically. At temperature 0 the output
    // must be token-identical to the non-speculative streamed run regardless
    // of acceptance, with response timings proving the draft actually
    // proposed and verified tokens.
    @Test func streamedDraftSimpleSpeculationMatchesNonSpeculative() async throws {
        let fixtures = OverfitFixture.locateAll()
        guard let target = fixtures.first(where: { $0.name == "tiny-qwen35moe-f16" }),
              let draft = fixtures.first(where: { $0.name == "tiny-qwen3moe-f16" }) else {
            print("[OverfitStreamedSpec] fixture pair missing under \(overfitRepoRoot().path)/.models/fixtures — skipping")
            return
        }
        let prompt = "The capital of France is"

        // (a) the draft model standalone: capture its token ids for the prompt.
        let draftPort = overfitStartServer(modelPath: draft.modelPath, pagedMode: 0, manifestPath: nil)
        #expect(draftPort > 0, "draft standalone boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard draftPort > 0 else { return }
        let draftIDs: [Int]
        do {
            draftIDs = try await overfitTokenize(port: draftPort, content: prompt)
            noema_llama_server_stop()
        } catch {
            noema_llama_server_stop()
            throw error
        }

        // (b) non-speculative streamed baseline + target-side token ids.
        func run(withDraft: Bool) async throws -> (
            key: String, ids: [Int], timings: [String: Any], statsJSON: String
        ) {
            let port = overfitStartServer(
                modelPath: target.residentPath,
                pagedMode: 2,
                manifestPath: target.manifestPath,
                slotsPerLayer: 6,
                speculativeType: withDraft ? "draft-simple" : nil,
                draftModelPath: withDraft ? draft.modelPath : nil,
                specDraftNMax: withDraft ? 8 : 0,
                specDynamic: withDraft
            )
            #expect(port > 0, "streamed boot (draft: \(withDraft)) failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitStreamedSpec", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "boot failed",
                ])
            }
            do {
                if withDraft {
                    let options = String(cString: noema_llama_server_last_start_options_json())
                    #expect(options.contains("\"speculativeType\":\"draft-simple\""),
                            "draft-simple missing from start options: \(options)")
                    #expect(options.contains("\"specDraftNMax\":1"),
                            "requested draft budget 8 was not clamped to the N + 1-safe bound: \(options)")
                    #expect(options.contains("\"specDynamic\":true"),
                            "paged helper launch dropped the dynamic controller flag: \(options)")
                }
                let ids = try await overfitTokenize(port: port, content: prompt)
                let out = try await overfitRunCompletionDetailed(port: port, prompt: prompt, nPredict: 16)
                let stats = overfitStreamStats() // read before stop: teardown resets stats
                let statsJSON = overfitPagedStatsJSON()
                noema_llama_server_stop()
                let stream = try #require(stats, "streamed run (draft: \(withDraft)) exposed no stream stats")
                #expect(stream.misses > 0, "the streaming path never engaged (draft: \(withDraft))")
                let timings = out.json["timings"] as? [String: Any] ?? [:]
                return (out.capture.key, ids, timings, statsJSON)
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        let plain = try await run(withDraft: false)
        #expect(!draftIDs.isEmpty)
        #expect(plain.ids == draftIDs,
                "target and draft tokenize the prompt differently — cross-model drafting is not legal for this pair")
        #expect(plain.timings["speculative_type"] == nil,
                "non-speculative run unexpectedly reported a speculative context")
        #expect(overfitPagedPhaseStats(plain.statsJSON, phase: "speculativeVerify")?.routeCalls == 0,
                "plain run was misclassified as speculative verification")

        // (c) same streamed run with the resident helper draft.
        let spec = try await run(withDraft: true)
        #expect(spec.key == plain.key,
                "helper-draft speculation changed generated tokens: \(spec.key) vs \(plain.key)")
        #expect(spec.key.hasPrefix("tokens:"), "completion returned no token ids")

        // The draft must have survived init (a vocab-incompat draft silently
        // falls back to plain decoding) and actually proposed tokens.
        let specType = spec.timings["speculative_type"] as? String ?? ""
        #expect(specType.contains("draft-simple"),
                "speculative context missing from response timings: \(spec.timings)")
        let draftN = (spec.timings["draft_n"] as? NSNumber)?.intValue ?? 0
        let draftAccepted = (spec.timings["draft_n_accepted"] as? NSNumber)?.intValue ?? -1
        #expect(draftN > 0, "the draft never proposed a token: \(spec.timings)")
        #expect(draftAccepted >= 0)
        #expect(draftAccepted < draftN,
                "the fixture must reject at least one draft token so recurrent rollback is exercised")
        #expect((spec.timings["draft_n_dyn"] as? NSNumber) != nil,
                "dynamic controller state missing from timings: \(spec.timings)")
        #expect(spec.timings["draft_rollback_ms"] is NSNumber,
                "rollback timing missing from speculative completion: \(spec.timings)")
        #expect(spec.timings["draft_accepted_per_position"] is [NSNumber],
                "per-position acceptance telemetry missing: \(spec.timings)")
        let verify = try #require(
            overfitPagedPhaseStats(spec.statsJSON, phase: "speculativeVerify"),
            "speculative phase telemetry missing: \(spec.statsJSON)")
        #expect(verify.routeCalls > 0,
                "N + 1 target verification was not attributed to speculativeVerify")
        #expect(!verify.layers.isEmpty, "speculative verification has no per-layer telemetry")
        print("[OverfitStreamedSpec] draft_n=\(draftN) accepted=\(draftAccepted) state=\(spec.timings["speculative_state"] ?? "?")")
    }

    // Unpaged helper-draft regression guard: the server mirrors verify
    // batches into the draft context, so the draft must reserve target +
    // speculative outputs (server-context.cpp load_model). Before that fix
    // the FIRST verify round of any helper-draft run — paged or not — died
    // on llama-context's n_outputs_max assert.
    @Test func residentHelperDraftSpeculationSurvivesVerifyRounds() async throws {
        let fixtures = OverfitFixture.locateAll()
        guard let target = fixtures.first(where: { $0.name == "tiny-qwen35moe-f16" }),
              let draft = fixtures.first(where: { $0.name == "tiny-qwen3moe-f16" }) else {
            print("[OverfitResidentSpec] fixture pair missing — skipping")
            return
        }
        let prompt = "The capital of France is"

        func run(withDraft: Bool) async throws -> (key: String, timings: [String: Any]) {
            let port = overfitStartServer(
                modelPath: target.modelPath,
                pagedMode: 0,
                manifestPath: nil,
                speculativeType: withDraft ? "draft-simple" : nil,
                draftModelPath: withDraft ? draft.modelPath : nil,
                specDraftNMax: withDraft ? 3 : 0
            )
            #expect(port > 0, "resident boot (draft: \(withDraft)) failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitResidentSpec", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "boot failed",
                ])
            }
            do {
                let out = try await overfitRunCompletionDetailed(port: port, prompt: prompt, nPredict: 16)
                noema_llama_server_stop()
                return (out.capture.key, out.json["timings"] as? [String: Any] ?? [:])
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        let plain = try await run(withDraft: false)
        let spec = try await run(withDraft: true)
        #expect(spec.key == plain.key,
                "resident helper-draft speculation changed generated tokens")
        let draftN = (spec.timings["draft_n"] as? NSNumber)?.intValue ?? 0
        #expect(draftN > 0, "the resident helper draft never proposed a token: \(spec.timings)")
    }

    // Regression for the production first-turn failure where a >1K-token
    // prompt followed by an eight-token helper draft aborted in
    // common_context_seq_rm while trimming rejected target tokens.
    @Test func residentHelperDraftRollsBackAfterLongPrefill() async throws {
        let fixtures = OverfitFixture.locateAll()
        guard let target = fixtures.first(where: { $0.name == "tiny-qwen35moe-f16" }) else {
            print("[OverfitResidentSpecLong] target fixture missing — skipping")
            return
        }

        // The tiny fixture is trained for 512 tokens, so reproduce the same
        // cross-ubatch shape at a proportionally smaller boundary.
        let prompt = String(repeating: "a", count: 480)
        let port = overfitStartServer(
            modelPath: target.modelPath,
            pagedMode: 0,
            manifestPath: nil,
            contextSize: 512,
            ubatchSize: 256,
            speculativeType: "draft-simple",
            // Use an identical helper for this rollback canary so it reliably
            // fills the entire eight-token draft window.
            draftModelPath: target.modelPath,
            specDraftNMax: 8
        )
        #expect(port > 0, "long-prompt resident helper boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard port > 0 else { return }

        do {
            let tokenized = try await overfitTokenize(port: port, content: prompt)
            #expect(tokenized.count > 256, "fixture prompt did not cross the test split boundary")
            let out = try await overfitRunCompletionDetailed(port: port, prompt: prompt, nPredict: 12)
            noema_llama_server_stop()

            let timings = out.json["timings"] as? [String: Any] ?? [:]
            #expect(((timings["draft_n"] as? NSNumber)?.intValue ?? 0) >= 8,
                    "long-prompt helper never drafted: \(timings)")
            #expect(timings["draft_rollback_ms"] is NSNumber,
                    "long-prompt rollback telemetry missing: \(timings)")
        } catch {
            noema_llama_server_stop()
            throw error
        }
    }

    // Mode-2 sizing with a helper draft: the estimate must carry the resident
    // draft model in speculativeBytes on top of the paged bank accounting.
    @Test func streamedMemoryEstimateIncludesResidentDraft() throws {
        let fixtures = OverfitFixture.locateAll()
        guard let target = fixtures.first(where: { $0.name == "tiny-qwen35moe-f16" }),
              let draft = fixtures.first(where: { $0.name == "tiny-qwen3moe-f16" }) else {
            print("[OverfitStreamed] fixture pair missing — skipping")
            return
        }
        func estimate(withDraft: Bool) -> (raw: String, json: [String: Any])? {
            let raw: String = target.residentPath.withCString { modelPointer in
                target.manifestPath.withCString { manifestPointer in
                    "draft-simple".withCString { specTypePointer in
                        draft.modelPath.withCString { draftPointer in
                            var configuration = noema_llama_server_configuration()
                            configuration.version = UInt32(NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION)
                            configuration.size = UInt32(MemoryLayout<noema_llama_server_configuration>.size)
                            configuration.gguf_path = modelPointer
                            configuration.context_size = 512
                            configuration.batch_size = 512
                            configuration.ubatch_size = 512
                            configuration.gpu_layers = 999
                            configuration.parallel_slots = 1
                            configuration.speculative_type = withDraft ? specTypePointer : nil
                            configuration.draft_model_path = withDraft ? draftPointer : nil
                            configuration.spec_draft_n_max = withDraft ? 8 : 0
                            configuration.paged_mode = 2
                            configuration.paged_manifest_path = manifestPointer
                            configuration.paged_slots_per_layer = 6
                            return String(cString: noema_llama_server_memory_estimate_json2(&configuration))
                        }
                    }
                }
            }
            guard let data = raw.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            return (raw, json)
        }
        let baseline = try #require(estimate(withDraft: false))
        let speculative = try #require(estimate(withDraft: true))
        #expect(baseline.json["status"] as? String == "ok", "estimate failed: \(baseline.raw)")
        #expect(speculative.json["status"] as? String == "ok", "estimate failed: \(speculative.raw)")
        #expect(speculative.json["paged"] is [String: Any],
                "estimate carries no paged accounting: \(speculative.raw)")
        #expect(((speculative.json["speculativeBytes"] as? NSNumber)?.uint64Value ?? 0) > 0,
                "mode-2 estimate ignored the resident helper draft: \(speculative.raw)")
        let baselineContext = (baseline.json["contextBytes"] as? NSNumber)?.uint64Value ?? 0
        let speculativeContext = (speculative.json["contextBytes"] as? NSNumber)?.uint64Value ?? 0
        #expect(speculativeContext > baselineContext,
                "helper drafting did not reserve target recurrent rollback sequences: baseline=\(baselineContext) speculative=\(speculativeContext)")
    }

    // The canary oracle: with oracle_all_hit set, the first bank miss poisons
    // the runtime, the decode loop converts that into a failed generation
    // (HTTP 500 naming noema_paged), and the server survives to serve again.
    @Test func streamedOracleMissFailsGenerationNotProcess() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitStreamed] fixture missing — skipping")
            return
        }
        let port = overfitStartServer(
            modelPath: fixture.residentPath,
            pagedMode: 2,
            manifestPath: fixture.manifestPath,
            slotsPerLayer: 4,
            oracleAllHit: true
        )
        #expect(port > 0, "streamed boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard port > 0 else { return }

        do {
            _ = try await overfitRunCompletion(port: port, prompt: "1 + 1 =", nPredict: 8)
            Issue.record("oracle-gated run with a cold bank must fail its generation")
        } catch {
            #expect(String(describing: error).contains("noema_paged"),
                    "generation failure did not surface the paged poison: \(error)")
        }
        noema_llama_server_stop()
        #expect(overfitIOLive() == OverfitIOLive(threads: 0, buffers: 0),
                "io resources leaked after the poisoned run")
    }

    // Planning path: memory_estimate_json2 for mode 2 must size the bank from
    // the resolved slot count (4 of 8 experts -> half the expert bytes) and
    // the staging pool from group bytes x io_depth, without touching the
    // process-global runtime.
    @Test func streamedMemoryEstimateReportsBankAccounting() throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitStreamed] fixture missing — skipping")
            return
        }
        let raw: String = fixture.residentPath.withCString { modelPointer in
            fixture.manifestPath.withCString { manifestPointer in
                var configuration = noema_llama_server_configuration()
                configuration.version = UInt32(NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION)
                configuration.size = UInt32(MemoryLayout<noema_llama_server_configuration>.size)
                configuration.gguf_path = modelPointer
                configuration.context_size = 512
                configuration.batch_size = 512
                configuration.ubatch_size = 512
                configuration.gpu_layers = 999
                configuration.parallel_slots = 1
                configuration.paged_mode = 2
                configuration.paged_manifest_path = manifestPointer
                configuration.paged_slots_per_layer = 4
                return String(cString: noema_llama_server_memory_estimate_json2(&configuration))
            }
        }
        let data = try #require(raw.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["status"] as? String == "ok", "estimate failed: \(raw)")
        let paged = try #require(json["paged"] as? [String: Any], "estimate carries no paged accounting: \(raw)")
        // Fixture geometry: group = 3 families x 12,288 B; 2 MoE layers.
        #expect((paged["bankBytes"] as? NSNumber)?.uint64Value == 4 * 36_864 * 2)
        // Staging = group x io_depth (default 4) + one merged-read coalescing
        // scratch per io worker (default 2 threads): scratch = min(io_depth,
        // n_expert) records + gaps = 4 x 12,288 + 3 x 16,384 = 98,304 B.
        #expect((paged["stagingBytes"] as? NSNumber)?.uint64Value == 36_864 * 4 + 98_304 * 2)
        #expect((paged["slotsPerLayer"] as? NSNumber)?.intValue == 4)
        #expect((paged["moeLayerCount"] as? NSNumber)?.intValue == 2)
        #expect(((json["modelBytes"] as? NSNumber)?.uint64Value ?? 0) > 0)
    }

    @Test func streamedLifecycleSurvivesRepeatedStartStop() async throws {
        guard ProcessInfo.processInfo.environment["NOEMA_OVERFIT_PARITY"] == "1" else {
            return // manual harness; enable with NOEMA_OVERFIT_PARITY=1
        }
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitStreamed] fixture missing — skipping")
            return
        }
        for cycle in 0..<10 {
            let port = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 4
            )
            #expect(port > 0, "cycle \(cycle) boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else { return }
            _ = try await overfitRunCompletion(port: port, prompt: "1 + 1 =", nPredict: 8)
            #expect(!overfitPagedStatsJSON().isEmpty, "live streamed run must expose stats (cycle \(cycle))")
            noema_llama_server_stop()

            // Teardown completeness: stats freeze at their reset state and no
            // io thread or staging buffer survives, cycle after cycle.
            let statsA = overfitPagedStatsJSON()
            let statsB = overfitPagedStatsJSON()
            #expect(statsA.isEmpty && statsA == statsB, "stats did not freeze after stop (cycle \(cycle))")
            #expect(overfitIOLive() == OverfitIOLive(threads: 0, buffers: 0),
                    "io resources leaked after stop (cycle \(cycle))")
        }
    }

    @Test func streamedLifecycleSurvivesMidGenerationCancel() async throws {
        guard ProcessInfo.processInfo.environment["NOEMA_OVERFIT_PARITY"] == "1" else {
            return // manual harness; enable with NOEMA_OVERFIT_PARITY=1
        }
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitStreamed] fixture missing — skipping")
            return
        }
        for cycle in 0..<5 {
            let port = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 4
            )
            #expect(port > 0, "cycle \(cycle) boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else { return }

            let fetch = Task {
                try? await overfitRunCompletion(
                    port: port,
                    prompt: "Write a very long story about mountains and rivers:",
                    nPredict: 512
                )
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            fetch.cancel() // aborts the URLSession task mid-generation
            _ = await fetch.value
            noema_llama_server_stop()

            #expect(overfitIOLive() == OverfitIOLive(threads: 0, buffers: 0),
                    "io resources leaked after cancel + stop (cycle \(cycle))")
        }
    }

    // App-initiated cancel: noema_llama_server_paged_cancel must fail the
    // in-flight streamed generation promptly (the HTTP request errors with the
    // paged poison), stop all paged reads, keep the io pool alive for the
    // server, and leave the runtime clean enough for the next generation to
    // succeed (cancel latch consumed, no orphaned in-flight slot markers).
    @Test func streamedPagedCancelFailsActiveGenerationAndRecovers() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitStreamed] fixture missing — skipping")
            return
        }
        let port = overfitStartServer(
            modelPath: fixture.residentPath,
            pagedMode: 2,
            manifestPath: fixture.manifestPath,
            slotsPerLayer: 4
        )
        #expect(port > 0, "streamed boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard port > 0 else { return }

        // Mode 2 clamps prefill to 1-token micro-batches here (4 slots, K = 2),
        // so a multi-hundred-token prompt keeps the route/IO path busy long
        // after its first bank miss — a wide, deterministic window to cancel
        // mid-generation. The fixture tokenizer emits ~37 tokens per
        // repetition; 10 repetitions stay well inside the 512-token context.
        let prompt = Array(repeating: "mountains and rivers flow past stone", count: 10)
            .joined(separator: " ")
        // Server warmup already produces bank misses, so gate on growth over
        // this baseline: only the fetched generation can add more.
        let baselineMisses = overfitStreamStats()?.misses ?? 0
        let fetch = Task { () -> String? in
            do {
                _ = try await overfitRunCompletion(port: port, prompt: prompt, nPredict: 64)
                return nil
            } catch {
                return String(describing: error)
            }
        }

        // Cancel only once the generation demonstrably engaged the streamed bank.
        var engaged = false
        for _ in 0..<250 {
            if (overfitStreamStats()?.misses ?? 0) > baselineMisses {
                engaged = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(engaged, "generation never engaged the streamed bank")

        let cancelStart = DispatchTime.now()
        noema_llama_server_paged_cancel()
        let failure = await fetch.value
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - cancelStart.uptimeNanoseconds) / 1_000_000
        #expect(elapsedMs < 2_000, "cancelled request took \(elapsedMs) ms to fail")
        let failureText = try #require(failure, "cancelled generation must fail its HTTP request")
        #expect(failureText.contains("noema_paged"),
                "failure did not surface the paged cancel poison: \(failureText)")

        // Paged reads must stop: after a 1 s settle the stream counters freeze
        // and the io pool stays exactly as it was (alive, nothing torn down).
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let statsA = overfitStreamStats()
        let liveA = overfitIOLive()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let statsB = overfitStreamStats()
        let liveB = overfitIOLive()
        #expect(statsA?.bytesRead == statsB?.bytesRead, "paged reads kept growing after cancel")
        #expect(statsA?.commits == statsB?.commits, "expert commits kept landing after cancel")
        #expect(liveA == liveB, "io threads/buffers changed while idle after cancel")

        // The cancel latch was consumed with the failed generation: the same
        // server must serve the next request cleanly, without inherited poison
        // and without stalling on slots the cancel left mid-load.
        let capture = try await overfitRunCompletion(
            port: port, prompt: "The capital of France is", nPredict: 16
        )
        #expect(!capture.key.isEmpty)
        noema_llama_server_stop()
        #expect(overfitIOLive() == OverfitIOLive(threads: 0, buffers: 0),
                "io resources leaked after cancel + stop")
    }

    // TURN-2 PREFIX REUSE. A paged chat session runs every turn through the
    // one slot with per-request cache_prompt=true while the checkpoint prompt
    // cache stays disabled (cache-ram 0 / ctx-checkpoints 0 — the paged
    // StartConfiguration shape). Slot-level longest-common-prefix reuse is a
    // separate, free mechanism: completion B, whose prompt extends A's
    // prompt + A's output, must only process the new suffix. The server's own
    // timings are the proof — prompt_n small, cache_n covering A's tokens. A
    // regression here re-prefills the entire transcript every turn, which on
    // a real overfit model turns each follow-up into minutes of TTFT.
    @Test func streamedTurnTwoReusesCommonPrefix() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitStreamed] fixture missing — skipping")
            return
        }
        let port = overfitStartServer(
            modelPath: fixture.residentPath,
            pagedMode: 2,
            manifestPath: fixture.manifestPath,
            slotsPerLayer: 4
        )
        #expect(port > 0, "streamed boot failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard port > 0 else { return }

        do {
            // ~37 fixture tokens per repetition; 6 repetitions + 8 generated
            // tokens + a short suffix stay well inside the 512-token context.
            let promptA = Array(repeating: "mountains and rivers flow past stone", count: 6)
                .joined(separator: " ")
            let turnA = try await overfitRunCompletionDetailed(
                port: port, prompt: promptA, nPredict: 8, cachePrompt: true
            )
            let contentA = turnA.json["content"] as? String ?? ""
            let promptB = promptA + contentA + " Then the storm arrived over the valley."
            let turnB = try await overfitRunCompletionDetailed(
                port: port, prompt: promptB, nPredict: 8, cachePrompt: true
            )

            let timings = try #require(turnB.json["timings"] as? [String: Any],
                                       "completion B returned no timings")
            let promptN = try #require((timings["prompt_n"] as? NSNumber)?.intValue)
            let cacheN = try #require((timings["cache_n"] as? NSNumber)?.intValue)
            let totalA = try await overfitTokenize(port: port, content: promptA).count
            let totalB = try await overfitTokenize(port: port, content: promptB).count
            print("[OverfitPrefixReuse] totalA=\(totalA) totalB=\(totalB) B.prompt_n=\(promptN) B.cache_n=\(cacheN)")
            #expect(totalB > totalA, "suffix added no tokens — test premise broken")

            // Slack covers tokenizer merges at the two join points plus the
            // server's mandatory ">= 1 token to evaluate" backstep.
            let slack = 8
            #expect(promptN <= (totalB - totalA) + slack,
                    "turn B reprocessed \(promptN) of \(totalB) prompt tokens — the common prefix (~\(totalA) tokens) was not reused")
            #expect(cacheN >= totalA - slack,
                    "turn B reused only \(cacheN) cached tokens of turn A's ~\(totalA)")

            // Control leg — the pre-fix app request shape. The app derived
            // cache_prompt from the checkpoint-cache toggle, so paged turns
            // could send false, and upstream's contract for that is n_past = 0:
            // the whole transcript reprocesses even though the slot still holds
            // it. This leg pins the mechanism the fix removes from the paged
            // path (NoemaLlamaClient now pins cache_prompt=true when
            // serverConfiguration.pagedMode != .off).
            let turnC = try await overfitRunCompletionDetailed(
                port: port, prompt: promptB, nPredict: 8, cachePrompt: false
            )
            let timingsC = try #require(turnC.json["timings"] as? [String: Any])
            let promptNC = try #require((timingsC["prompt_n"] as? NSNumber)?.intValue)
            print("[OverfitPrefixReuse] control cache_prompt=false C.prompt_n=\(promptNC)")
            #expect(promptNC >= totalB - slack,
                    "cache_prompt=false processed only \(promptNC) of \(totalB) tokens — upstream semantics changed; revisit the paged cache_prompt pin")
            noema_llama_server_stop()
        } catch {
            noema_llama_server_stop()
            throw error
        }
    }

    // HYBRID PREFIX REUSE = CHECKPOINT RESTORE. The test above runs on the
    // pure-attention qwen3moe fixture, where the context supports partial
    // sequence rollback and plain slot prefix reuse is free — which is exactly
    // why it stayed green while the real hybrid Qwen3.5 re-prefilled all 1049
    // turn-2 tokens at 0.976 prefix similarity (46 s TTFT). tiny-qwen35moe
    // interleaves a gated-delta-net (recurrent) layer ("the context does not
    // support partial sequence removal" at boot), and rollback is the crux:
    // when turn 2 extends the cached tokens EXACTLY, the recurrent state is
    // already positioned to continue and reuse is free even on a hybrid. The
    // production chat path never gets that luck — the template re-serializes
    // the assistant turn, so the new prompt DIVERGES from the raw cached
    // generation a few tokens before its end (the device run's 0.976
    // similarity), and continuing from the divergence point would need the
    // recurrent state rolled back — impossible, so the server resets n_past
    // to 0. Upstream's designed rescue is context checkpoints
    // (--ctx-checkpoints > 0): a snapshot of the non-rollback-able state taken
    // a few tokens before the prompt end, restored instead of the reset. The
    // turn-2 prompt here truncates the tail of turn 1's generation to force
    // that divergence.
    //
    // Leg 1 pins the failure mode this fork shipped with (ctx-checkpoints 0 —
    // the old paged launch shape): turn 2 reprocesses its ENTIRE prompt even
    // though the slot holds a ~97% common prefix. Leg 2 boots the same fixture
    // with checkpoints on — the new paged launch shape — and asserts turn 2
    // only prefills the delta past the restored checkpoint.
    @Test func streamedHybridTurnTwoNeedsCheckpointsToReusePrefix() async throws {
        guard let fixture = OverfitFixture.locateAll()
            .first(where: { $0.name == "tiny-qwen35moe-f16" }) else {
            print("[OverfitStreamed] hybrid fixture missing — skipping")
            return
        }
        // -lv 4 surfaces the created/restored checkpoint TRC lines, including
        // the per-checkpoint "size = X MiB" — the number that budgets the
        // real-model checkpoint counts (8 on Mac, 4 on phones).
        setenv("LLAMA_ARG_LOG_VERBOSITY", "4", 1)
        defer { unsetenv("LLAMA_ARG_LOG_VERBOSITY") }

        // ~37 fixture tokens per repetition; 6 repetitions + 8 generated
        // tokens + a short suffix stay well inside the 512-token context.
        let promptA = Array(repeating: "mountains and rivers flow past stone", count: 6)
            .joined(separator: " ")
        // Slack covers tokenizer merges at the two join points, the server's
        // mandatory ">= 1 token to evaluate" backstep, and the checkpoint's
        // 4-token pre-end placement.
        let slack = 12

        func runTwoTurns(ctxCheckpoints: Int32) async throws
            -> (promptN: Int, cacheN: Int, totalA: Int, totalB: Int) {
            let port = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 6,
                ctxCheckpoints: ctxCheckpoints
            )
            #expect(port > 0, "hybrid streamed boot (ctx_checkpoints \(ctxCheckpoints)) failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port > 0 else {
                throw NSError(domain: "OverfitHybridCheckpoint", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "boot failed",
                ])
            }
            do {
                let turnA = try await overfitRunCompletionDetailed(
                    port: port, prompt: promptA, nPredict: 8, cachePrompt: true
                )
                let contentA = turnA.json["content"] as? String ?? ""
                // Drop the generation's tail so the turn-2 prompt diverges
                // from the cached tokens BEFORE their end — the template
                // re-serialization effect that makes hybrid reuse need a
                // rollback. (Even an empty contentA diverges: the cached
                // sequence still ends in generated tokens the new prompt
                // replaces with the suffix.)
                let promptB = promptA + String(contentA.dropLast(4))
                    + " Then the storm arrived over the valley."
                let turnB = try await overfitRunCompletionDetailed(
                    port: port, prompt: promptB, nPredict: 8, cachePrompt: true
                )
                let timings = try #require(turnB.json["timings"] as? [String: Any],
                                           "turn 2 returned no timings")
                let promptN = try #require((timings["prompt_n"] as? NSNumber)?.intValue)
                let cacheN = try #require((timings["cache_n"] as? NSNumber)?.intValue)
                let totalA = try await overfitTokenize(port: port, content: promptA).count
                let totalB = try await overfitTokenize(port: port, content: promptB).count
                noema_llama_server_stop()
                print("[OverfitHybridCheckpoint] ctx_checkpoints=\(ctxCheckpoints) totalA=\(totalA) totalB=\(totalB) B.prompt_n=\(promptN) B.cache_n=\(cacheN)")
                #expect(totalB > totalA, "suffix added no tokens — test premise broken")
                return (promptN, cacheN, totalA, totalB)
            } catch {
                noema_llama_server_stop()
                throw error
            }
        }

        // Leg 1 — checkpoints off: the hybrid context cannot roll back, so the
        // server resets n_past to 0 and reprocesses everything. This is the
        // documented OLD behavior, not a wish: if it starts reusing the prefix
        // without checkpoints, upstream grew real hybrid rollback and the
        // paged checkpoint budget can be reconsidered.
        let off = try await runTwoTurns(ctxCheckpoints: 0)
        #expect(off.cacheN == 0,
                "hybrid fixture reused \(off.cacheN) tokens with checkpoints off — hybrid rollback semantics changed")
        #expect(off.promptN >= off.totalB - slack,
                "hybrid fixture reprocessed only \(off.promptN) of \(off.totalB) tokens with checkpoints off — hybrid rollback semantics changed")

        // Leg 2 — checkpoints on (the paged launch now passes 8 on Mac / 4 on
        // phones): turn 2 restores the checkpoint taken near turn 1's prompt
        // end and only prefills the suffix past it.
        let on = try await runTwoTurns(ctxCheckpoints: 8)
        #expect(on.promptN <= (on.totalB - on.totalA) + slack,
                "turn 2 reprocessed \(on.promptN) of \(on.totalB) prompt tokens — no checkpoint was restored (~\(on.totalA)-token prefix lost)")
        #expect(on.cacheN >= on.totalA - slack,
                "turn 2 reused only \(on.cacheN) cached tokens of turn 1's ~\(on.totalA)")
    }

    // WAVE-LIFT SIZING. With waves on, macOS paged launches lift batch and
    // ubatch to >= 1024 (one expert sweep per micro-batch instead of ~4 at
    // ubatch 256). The planning estimate for that shape must still resolve:
    // compute buffers grow with the micro-batch, and this pins that the
    // estimator keeps sizing the lifted configuration so the app-side RAM gate
    // can judge it before launch.
    @Test func streamedMemoryEstimateResolvesWaveLiftedUbatch() throws {
        guard let fixture = OverfitFixture.locateAll()
            .first(where: { $0.name == "tiny-qwen35moe-f16" }) else {
            print("[OverfitStreamed] hybrid fixture missing — skipping")
            return
        }
        // Without waves the paged normalization clamps the micro-batch to
        // floor((slots - spare) / K) inside the estimator too, flattening the
        // A/B. The lift only ships under waves, so size that shape.
        setenv("NOEMA_PAGED_WAVES", "1", 1)
        defer { unsetenv("NOEMA_PAGED_WAVES") }
        func estimate(batch: Int32, ubatch: Int32) throws -> (compute: UInt64, total: UInt64) {
            let raw: String = fixture.residentPath.withCString { modelPointer in
                fixture.manifestPath.withCString { manifestPointer in
                    var configuration = noema_llama_server_configuration()
                    configuration.version = UInt32(NOEMA_LLAMA_SERVER_CONFIGURATION_VERSION)
                    configuration.size = UInt32(MemoryLayout<noema_llama_server_configuration>.size)
                    configuration.gguf_path = modelPointer
                    configuration.context_size = 2048
                    configuration.batch_size = batch
                    configuration.ubatch_size = ubatch
                    configuration.gpu_layers = 999
                    configuration.parallel_slots = 1
                    configuration.paged_mode = 2
                    configuration.paged_manifest_path = manifestPointer
                    configuration.paged_slots_per_layer = 6
                    return String(cString: noema_llama_server_memory_estimate_json2(&configuration))
                }
            }
            let data = try #require(raw.data(using: .utf8))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["status"] as? String == "ok", "estimate failed: \(raw)")
            #expect(json["paged"] is [String: Any], "estimate lost paged accounting: \(raw)")
            return ((json["computeBytes"] as? NSNumber)?.uint64Value ?? 0,
                    (json["totalBytes"] as? NSNumber)?.uint64Value ?? 0)
        }
        let base = try estimate(batch: 512, ubatch: 256)
        let lifted = try estimate(batch: 1024, ubatch: 1024)
        print("[OverfitWaveLiftEstimate] ubatch256 compute=\(base.compute) total=\(base.total); ubatch1024 compute=\(lifted.compute) total=\(lifted.total)")
        #expect(base.compute > 0)
        #expect(lifted.compute >= base.compute,
                "compute sizing ignored the micro-batch: \(lifted.compute) < \(base.compute)")
    }

    // DISK-PERSISTED PROMPT KV. Paged boots pass --slot-save-path only when
    // NOEMA_PAGED_SLOT_SAVE_DIR names an existing directory (internal env
    // gate, no public-struct change). Completion A runs on boot 1, the slot
    // is saved to disk, the server fully stops, and a second boot restores
    // the file before any request: completion B (A's prompt + A's output +
    // a fresh suffix) must only prefill the suffix — the disk-restore
    // analogue of streamedTurnTwoReusesCommonPrefix. B succeeding at all
    // also pins that restore stays orthogonal to the paged decode poison
    // path: the restored KV feeds a normal streamed-bank decode.
    @Test func streamedSlotSaveRestoreSkipsPrefillAcrossBoots() async throws {
        guard let fixture = OverfitFixture.locate() else {
            print("[OverfitStreamed] fixture missing — skipping")
            return
        }
        let fm = FileManager.default
        let saveDir = fm.temporaryDirectory
            .appendingPathComponent("overfit-slot-save-\(UUID().uuidString)")
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        // The env var is read once per boot inside the argv build; clear it on
        // every exit so later boots in this process stay slot-save-free.
        setenv("NOEMA_PAGED_SLOT_SAVE_DIR", saveDir.path, 1)
        defer {
            unsetenv("NOEMA_PAGED_SLOT_SAVE_DIR")
            try? fm.removeItem(at: saveDir)
        }
        let filename = "prompt-state.noemaslot"
        // ~37 fixture tokens per repetition; 6 repetitions + 8 generated
        // tokens + a short suffix stay well inside the 512-token context.
        let promptA = Array(repeating: "mountains and rivers flow past stone", count: 6)
            .joined(separator: " ")

        // Boot 1: run A, persist the slot to disk, stop the server entirely.
        let port1 = overfitStartServer(
            modelPath: fixture.residentPath,
            pagedMode: 2,
            manifestPath: fixture.manifestPath,
            slotsPerLayer: 4
        )
        #expect(port1 > 0, "boot 1 failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard port1 > 0 else { return }
        var contentA = ""
        var savedTokens = 0
        do {
            let turnA = try await overfitRunCompletionDetailed(
                port: port1, prompt: promptA, nPredict: 8, cachePrompt: true
            )
            contentA = turnA.json["content"] as? String ?? ""
            let saved = try await overfitSlotAction(port: port1, action: "save", filename: filename)
            savedTokens = (saved["n_saved"] as? NSNumber)?.intValue ?? 0
            #expect(savedTokens > 0, "save persisted no tokens: \(saved)")
            #expect(((saved["n_written"] as? NSNumber)?.int64Value ?? 0) > 0,
                    "save wrote no bytes: \(saved)")
            #expect(fm.fileExists(atPath: saveDir.appendingPathComponent(filename).path),
                    "save reported success but no file landed in the save dir")
            noema_llama_server_stop()
        } catch {
            noema_llama_server_stop()
            throw error
        }

        // Boot 2: restore from disk BEFORE any completion, then extend A.
        let port2 = overfitStartServer(
            modelPath: fixture.residentPath,
            pagedMode: 2,
            manifestPath: fixture.manifestPath,
            slotsPerLayer: 4
        )
        #expect(port2 > 0, "boot 2 failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
        guard port2 > 0 else { return }
        do {
            let restored = try await overfitSlotAction(port: port2, action: "restore", filename: filename)
            let restoredTokens = (restored["n_restored"] as? NSNumber)?.intValue ?? 0
            #expect(restoredTokens == savedTokens,
                    "restore token count \(restoredTokens) != saved \(savedTokens): \(restored)")
            #expect(((restored["n_read"] as? NSNumber)?.int64Value ?? 0) > 0,
                    "restore read no bytes: \(restored)")

            let promptB = promptA + contentA + " Then the storm arrived over the valley."
            let turnB = try await overfitRunCompletionDetailed(
                port: port2, prompt: promptB, nPredict: 8, cachePrompt: true
            )
            #expect(!turnB.capture.key.isEmpty, "post-restore decode produced no output")
            let timings = try #require(turnB.json["timings"] as? [String: Any],
                                       "completion B returned no timings")
            let promptN = try #require((timings["prompt_n"] as? NSNumber)?.intValue)
            let cacheN = try #require((timings["cache_n"] as? NSNumber)?.intValue)
            let totalA = try await overfitTokenize(port: port2, content: promptA).count
            let totalB = try await overfitTokenize(port: port2, content: promptB).count
            print("[OverfitSlotSave] saved=\(savedTokens) restored=\(restoredTokens) totalA=\(totalA) totalB=\(totalB) B.prompt_n=\(promptN) B.cache_n=\(cacheN)")
            #expect(totalB > totalA, "suffix added no tokens — test premise broken")

            // Slack covers tokenizer merges at the two join points plus the
            // server's mandatory ">= 1 token to evaluate" backstep.
            let slack = 8
            #expect(promptN <= (totalB - totalA) + slack,
                    "turn B reprocessed \(promptN) of \(totalB) prompt tokens after a disk restore — the persisted prefix (~\(totalA) tokens) was not reused")
            #expect(cacheN >= totalA - slack,
                    "turn B reused only \(cacheN) cached tokens of the restored ~\(totalA)")
            let stats = overfitStreamStats()
            noema_llama_server_stop()
            let stream = try #require(stats, "boot 2 exposed no stream stats")
            #expect(stream.commits > 0,
                    "no expert groups streamed after restore — the paged path never engaged")
        } catch {
            noema_llama_server_stop()
            throw error
        }
    }

    // CROSS-BOOT SWA/HYBRID ROLLBACK. llama's sequence-state file does not
    // contain server_prompt.checkpoints. That omission is invisible on the
    // pure-attention fixture above, but after a restart it makes Gemma 4 SWA
    // and Qwen 3.5 recurrent memory accept the slot then reset n_past to zero
    // as soon as a re-serialized chat prompt diverges near the generated tail.
    // Noema's .noemackpt companion must survive the restart and preserve the
    // same rollback checkpoint that works during an in-process second turn.
    @Test func streamedSWAAndHybridSlotSaveRestorePreservesCheckpointsAcrossBoots() async throws {
        let fixturesByName = Dictionary(
            uniqueKeysWithValues: OverfitFixture.locateAll().map { ($0.name, $0) })
        let requested = ["tiny-gemma4-f16", "tiny-qwen35moe-f16"]
        guard requested.allSatisfy({ fixturesByName[$0] != nil }) else {
            print("[OverfitSlotCheckpoint] Gemma 4 or Qwen 3.5 fixture missing — skipping")
            return
        }

        let fm = FileManager.default
        let saveDir = fm.temporaryDirectory
            .appendingPathComponent("overfit-slot-checkpoint-\(UUID().uuidString)")
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        setenv("NOEMA_PAGED_SLOT_SAVE_DIR", saveDir.path, 1)
        defer {
            unsetenv("NOEMA_PAGED_SLOT_SAVE_DIR")
            try? fm.removeItem(at: saveDir)
        }

        let promptA = Array(repeating: "mountains and rivers flow past stone", count: 6)
            .joined(separator: " ")
        let slack = 12

        for name in requested {
            let fixture = try #require(fixturesByName[name])
            let filename = "\(name).noemaslot"
            let slotURL = saveDir.appendingPathComponent(filename)
            let checkpointURL = slotURL.appendingPathExtension("noemackpt")

            let port1 = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 6,
                ctxCheckpoints: 4
            )
            #expect(port1 > 0, "\(name) boot 1 failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port1 > 0 else { continue }

            var contentA = ""
            var savedTokens = 0
            do {
                let turnA = try await overfitRunCompletionDetailed(
                    port: port1, prompt: promptA, nPredict: 8, cachePrompt: true
                )
                contentA = turnA.json["content"] as? String ?? ""
                let saved = try await overfitSlotAction(
                    port: port1, action: "save", filename: filename)
                savedTokens = (saved["n_saved"] as? NSNumber)?.intValue ?? 0
                #expect(savedTokens > 0, "\(name) saved no tokens: \(saved)")
                #expect(fm.fileExists(atPath: slotURL.path),
                        "\(name) sequence state file is missing")
                #expect(fm.fileExists(atPath: checkpointURL.path),
                        "\(name) SWA/hybrid checkpoint companion is missing")
                let checkpointBytes = ((try? checkpointURL.resourceValues(
                    forKeys: [.fileSizeKey]))?.fileSize) ?? 0
                #expect(checkpointBytes > 0,
                        "\(name) checkpoint companion is empty")
                noema_llama_server_stop()
            } catch {
                noema_llama_server_stop()
                throw error
            }

            let port2 = overfitStartServer(
                modelPath: fixture.residentPath,
                pagedMode: 2,
                manifestPath: fixture.manifestPath,
                slotsPerLayer: 6,
                ctxCheckpoints: 4
            )
            #expect(port2 > 0, "\(name) boot 2 failed: \(String(cString: noema_llama_server_last_start_diagnostics_json()))")
            guard port2 > 0 else { continue }
            do {
                let restored = try await overfitSlotAction(
                    port: port2, action: "restore", filename: filename)
                let restoredTokens = (restored["n_restored"] as? NSNumber)?.intValue ?? 0
                #expect(restoredTokens == savedTokens,
                        "\(name) restored \(restoredTokens) tokens, expected \(savedTokens)")

                // Match the app's template re-serialization behavior: replace
                // the tail of the raw generated sequence rather than exactly
                // extending it. This requires SWA/recurrent rollback.
                let promptB = promptA + String(contentA.dropLast(4))
                    + " Then the storm arrived over the valley."
                let turnB = try await overfitRunCompletionDetailed(
                    port: port2, prompt: promptB, nPredict: 8, cachePrompt: true
                )
                let timings = try #require(turnB.json["timings"] as? [String: Any])
                let promptN = try #require((timings["prompt_n"] as? NSNumber)?.intValue)
                let cacheN = try #require((timings["cache_n"] as? NSNumber)?.intValue)
                let totalA = try await overfitTokenize(port: port2, content: promptA).count
                let totalB = try await overfitTokenize(port: port2, content: promptB).count
                print("[OverfitSlotCheckpoint] \(name) saved=\(savedTokens) totalA=\(totalA) totalB=\(totalB) B.prompt_n=\(promptN) B.cache_n=\(cacheN)")
                #expect(promptN <= (totalB - totalA) + slack,
                        "\(name) reprocessed \(promptN) of \(totalB) tokens after checkpoint restore")
                #expect(cacheN >= totalA - slack,
                        "\(name) reused only \(cacheN) of the restored ~\(totalA)-token prefix")
                noema_llama_server_stop()
            } catch {
                noema_llama_server_stop()
                throw error
            }

            // Migration safety: an old sequence-only Qwen save must fail
            // restore and clear its partially loaded state, not report a hit
            // that immediately falls back to a full prefill.
            if name == "tiny-qwen35moe-f16" {
                try fm.removeItem(at: checkpointURL)
                let port3 = overfitStartServer(
                    modelPath: fixture.residentPath,
                    pagedMode: 2,
                    manifestPath: fixture.manifestPath,
                    slotsPerLayer: 6,
                    ctxCheckpoints: 4
                )
                #expect(port3 > 0, "Qwen legacy-cache boot failed")
                guard port3 > 0 else { continue }
                var rejected = false
                do {
                    _ = try await overfitSlotAction(
                        port: port3, action: "restore", filename: filename)
                } catch {
                    rejected = true
                }
                #expect(rejected,
                        "Qwen hybrid restore accepted a sequence file with no checkpoint companion")
                noema_llama_server_stop()
            }
        }
    }
}
