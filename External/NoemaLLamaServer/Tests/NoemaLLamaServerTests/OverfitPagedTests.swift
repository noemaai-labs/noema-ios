import Foundation
import Testing
@testable import NoemaLLamaServer

// Debug-only hooks appended to server_bridge.mm (NOEMA_LLAMA_SERVER_TEST_HOOKS).

@_silgen_name("noema_paged_xxh64_for_test")
private func noema_paged_xxh64_for_test(
    _ data: UnsafePointer<UInt8>?,
    _ len: Int,
    _ seed: UInt64
) -> UInt64

@_silgen_name("noema_paged_validate_package_for_test")
private func noema_paged_validate_package_for_test(
    _ manifestPath: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>?

private func xxh64(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
    if bytes.isEmpty {
        var dummy: UInt8 = 0
        return withUnsafePointer(to: &dummy) { noema_paged_xxh64_for_test($0, 0, seed) }
    }
    return bytes.withUnsafeBufferPointer {
        noema_paged_xxh64_for_test($0.baseAddress, $0.count, seed)
    }
}

// MARK: - XXH64 known answers

@Test func xxh64KnownAnswers() {
    #expect(xxh64([]) == 0xEF46_DB37_51D8_E999)
    #expect(xxh64(Array("abc".utf8)) == 0x44BC_2CF5_AD77_0999)
}

@Test func xxh64DeterministicAndSeedSensitive() {
    let buffer = (0..<100).map { UInt8($0 & 0xFF) }
    let first = xxh64(buffer)
    #expect(first == xxh64(buffer))
    #expect(xxh64(buffer, seed: 1) != first)
    var mutated = buffer
    mutated[57] ^= 0x01
    #expect(xxh64(mutated) != first)
}

// MARK: - Manifest fixture builder

// Minimal valid geometry: 1 MoE layer, families gate/up/down, F32 slices
// ne=[4,2] so every record length must be exactly 4*2*4 = 32 bytes.
// parse_and_validate reads only manifest.json (payload files are stat'd later
// by finalize_load), so fixtures never write payload files.
private let recordLength = 32

private func manifestWithGeometry(expertCount: Int, expertsUsed: Int) -> [String: Any] {
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
    return [
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
}

private func baseManifest() -> [String: Any] {
    manifestWithGeometry(expertCount: 2, expertsUsed: 1)
}

private func writeManifest(_ manifest: [String: Any]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noema-overfit-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    return url
}

private func validate(_ manifest: [String: Any]) throws -> String {
    let url = try writeManifest(manifest)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let error = url.path.withCString { noema_paged_validate_package_for_test($0) }
    return error.map { String(cString: $0) } ?? ""
}

private func mutatingRecord(
    _ manifest: [String: Any], _ index: Int, _ change: (inout [String: Any]) -> Void
) -> [String: Any] {
    var manifest = manifest
    var records = manifest["records"] as! [[String: Any]]
    change(&records[index])
    manifest["records"] = records
    return manifest
}

// MARK: - Manifest validation (fail-closed)

@Test func manifestValidCasePasses() throws {
    #expect(try validate(baseManifest()) == "")
}

@Test func manifestAcceptsGemma4Architecture() throws {
    var manifest = baseManifest()
    var model = manifest["model"] as! [String: Any]
    model["architecture"] = "gemma4"
    manifest["model"] = model
    #expect(try validate(manifest) == "")
}

@Test func manifestRejectsUnknownFormatVersion() throws {
    var manifest = baseManifest()
    manifest["formatVersion"] = 2
    #expect(try validate(manifest).contains("unsupported manifest formatVersion"))
}

@Test func manifestRejectsNonWhitelistedArchitecture() throws {
    var manifest = baseManifest()
    var model = manifest["model"] as! [String: Any]
    model["architecture"] = "llama"
    manifest["model"] = model
    #expect(try validate(manifest).contains("not paged-whitelisted"))
}

@Test func manifestRejectsMisalignedRecordOffset() throws {
    let manifest = mutatingRecord(baseManifest(), 0) { $0["offset"] = 4 }
    #expect(try validate(manifest).contains("record offset violates package alignment"))
}

@Test func manifestRejectsRecordRangePastFileSize() throws {
    // Aligned offset, but 168 + 32 = 200 > declared 192-byte payload.
    let manifest = mutatingRecord(baseManifest(), 5) { $0["offset"] = 168 }
    #expect(try validate(manifest).contains("record range exceeds payload file bounds"))
}

@Test func manifestRejectsOverlappingRecords() throws {
    // Record 1 moved from offset 32 to 16: aligned, in bounds, distinct
    // (layer, family, expert), but [16, 48) overlaps record 0's [0, 32).
    let manifest = mutatingRecord(baseManifest(), 1) { $0["offset"] = 16 }
    #expect(try validate(manifest).contains("records overlap inside a payload file"))
}

@Test func manifestRejectsDuplicateLayerFamilyExpert() throws {
    // Record 1 keeps its own byte range but repeats record 0's identity.
    let manifest = mutatingRecord(baseManifest(), 1) { $0["expert"] = 0 }
    #expect(try validate(manifest).contains("duplicate record for layer/family/expert"))
}

@Test func manifestRejectsMissingRecordCoverage() throws {
    var manifest = baseManifest()
    var records = manifest["records"] as! [[String: Any]]
    records.removeLast() // drop (layer 0, down, expert 1); family still present via expert 0
    manifest["records"] = records
    #expect(try validate(manifest).contains("missing expert record in a covered layer family"))
}

@Test func manifestRejectsZeroLengthRecord() throws {
    let manifest = mutatingRecord(baseManifest(), 0) { $0["length"] = 0 }
    #expect(try validate(manifest).contains("record has zero length"))
}

@Test func manifestRejectsResidentPathTraversal() throws {
    var manifest = baseManifest()
    var resident = manifest["resident"] as! [String: Any]
    resident["path"] = "../x"
    manifest["resident"] = resident
    #expect(try validate(manifest).contains("resident path is not a safe flat file name"))
}

@Test func manifestRejectsFusedGateUpFlagDisagreement() throws {
    var manifest = baseManifest()
    var model = manifest["model"] as! [String: Any]
    model["fusedGateUp"] = true // records declare separate gate/up/down families
    manifest["model"] = model
    #expect(try validate(manifest).contains("fusedGateUp flag disagrees with record families"))
}

@Test func manifestRejectsLengthDisagreeingWithQuantGeometry() throws {
    // F32 ne=[4,2] requires exactly 32 bytes; an off-by-4 length must fail.
    let manifest = mutatingRecord(baseManifest(), 0) { $0["length"] = recordLength + 4 }
    #expect(try validate(manifest).contains("record length disagrees with quant geometry"))
}

// MARK: - Streamed micro-batch clamp

@_silgen_name("noema_paged_max_ubatch_for_test")
private func noema_paged_max_ubatch_for_test(
    _ manifestPath: UnsafePointer<CChar>?,
    _ mode: Int32,
    _ slotsPerLayer: Int32
) -> Int32

@_silgen_name("noema_paged_max_draft_tokens_for_test")
private func noema_paged_max_draft_tokens_for_test(
    _ manifestPath: UnsafePointer<CChar>?,
    _ mode: Int32,
    _ slotsPerLayer: Int32
) -> Int32

// Planning-only configure + noema_paged_max_ubatch on the exact runtime math
// (manifest parse -> slot resolution -> clamp). Never boots a server.
private func maxUbatch(
    expertCount: Int, expertsUsed: Int, mode: Int32, slots: Int32
) throws -> Int32 {
    let url = try writeManifest(
        manifestWithGeometry(expertCount: expertCount, expertsUsed: expertsUsed))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return url.path.withCString { noema_paged_max_ubatch_for_test($0, mode, slots) }
}

private func maxDraftTokens(
    expertCount: Int, expertsUsed: Int, mode: Int32, slots: Int32
) throws -> Int32 {
    let url = try writeManifest(
        manifestWithGeometry(expertCount: expertCount, expertsUsed: expertsUsed))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return url.path.withCString {
        noema_paged_max_draft_tokens_for_test($0, mode, slots)
    }
}

@Test func maxUbatchClampMath() throws {
    // floor((n_slots - 2) / K), never below 1. The tiny parity fixtures share
    // the 8-expert K=2 geometry: 4 slots -> 1 token, full bank -> 3 tokens.
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 2, mode: 2, slots: 4) == 1)
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 2, mode: 2, slots: 5) == 1)
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 2, mode: 2, slots: 6) == 2)
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 2, mode: 2, slots: 7) == 2)
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 2, mode: 2, slots: 8) == 3)
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 1, mode: 2, slots: 8) == 6)
    // The configure floor (K + 2) always leaves room for one token.
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 6, mode: 2, slots: 8) == 1)
    // Modes without a streamed bank report 0: no clamp.
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 2, mode: 0, slots: 0) == 0)
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 2, mode: 1, slots: 0) == 0)
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 2, mode: 3, slots: 0) == 0)
    // Below the K + 2 floor configure refuses outright (-1 from the hook).
    #expect(try maxUbatch(expertCount: 8, expertsUsed: 2, mode: 2, slots: 3) == -1)
}

@Test func maxDraftClampIncludesVerificationToken() throws {
    // Verification routes the sampled token plus N drafts, hence
    // floor((slots - 2) / K) - 1. Zero is a real "cannot speculate" result.
    #expect(try maxDraftTokens(expertCount: 8, expertsUsed: 2, mode: 2, slots: 4) == 0)
    #expect(try maxDraftTokens(expertCount: 8, expertsUsed: 2, mode: 2, slots: 6) == 1)
    #expect(try maxDraftTokens(expertCount: 8, expertsUsed: 2, mode: 2, slots: 8) == 2)
    #expect(try maxDraftTokens(expertCount: 8, expertsUsed: 1, mode: 2, slots: 8) == 5)
    #expect(try maxDraftTokens(expertCount: 8, expertsUsed: 6, mode: 2, slots: 8) == 0)
    #expect(try maxDraftTokens(expertCount: 8, expertsUsed: 2, mode: 1, slots: 0) == -1)
}

// MARK: - Configuration v4 (public API)

private func withCStringOrNil<R>(
    _ string: String?, _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    if let string {
        return string.withCString { body($0) }
    }
    return body(nil)
}

private struct StartAttempt {
    let port: Int32
    let diagnostics: String
    let options: String
}

private func attemptStart(
    version: UInt32,
    pagedMode: Int32,
    manifestPath: String?,
    cpuMoe: Int32 = 0,
    slotsPerLayer: Int32 = 0,
    speculativeType: String? = nil,
    draftModelPath: String? = nil,
    specDraftNMax: Int32 = 0,
    pagedWaves: Bool = false,
    pagedExpertMajor: Bool = false
) -> StartAttempt {
    let host = "127.0.0.1"
    let model = "/nonexistent/noema-overfit-config-test.gguf"
    let port = host.withCString { hostPointer in
        model.withCString { modelPointer in
            withCStringOrNil(manifestPath) { manifestPointer -> Int32 in
                withCStringOrNil(speculativeType) { specTypePointer -> Int32 in
                    withCStringOrNil(draftModelPath) { draftPointer -> Int32 in
                        var configuration = noema_llama_server_configuration()
                        configuration.version = version
                        configuration.size = UInt32(MemoryLayout<noema_llama_server_configuration>.size)
                        configuration.host = hostPointer
                        configuration.gguf_path = modelPointer
                        configuration.reasoning_budget = Int32.min
                        configuration.context_size = 512
                        configuration.threads = 2
                        configuration.threads_batch = 2
                        configuration.batch_size = 512
                        configuration.ubatch_size = 512
                        configuration.speculative_type = specTypePointer
                        configuration.draft_model_path = draftPointer
                        configuration.spec_draft_n_max = specDraftNMax
                        configuration.paged_mode = pagedMode
                        configuration.paged_manifest_path = manifestPointer
                        configuration.paged_slots_per_layer = slotsPerLayer
                        configuration.paged_waves = pagedWaves ? 1 : 0
                        configuration.paged_expert_major = pagedExpertMajor ? 1 : 0
                        configuration.cpu_moe = cpuMoe
                        return noema_llama_server_start_with_configuration(&configuration)
                    }
                }
            }
        }
    }
    return StartAttempt(
        port: port,
        diagnostics: String(cString: noema_llama_server_last_start_diagnostics_json()),
        options: String(cString: noema_llama_server_last_start_options_json())
    )
}

// The loopback server is a process singleton with process-global diagnostics
// JSON. Every test that calls noema_llama_server_start_* must be a member of
// this one serialized suite (extensions in other files join it), otherwise a
// concurrent start clobbers another test's diagnostics between start and read.
@Suite(.serialized) struct ServerStartSerializedTests {
    @Test func rejectsInvalidPagedMode() {
        let attempt = attemptStart(version: 3, pagedMode: 5, manifestPath: nil)
        #expect(attempt.port == 0)
        #expect(attempt.diagnostics.contains("invalid paged mode"))
    }

    @Test func rejectsPagedModeWithoutManifest() {
        let attempt = attemptStart(version: 3, pagedMode: 1, manifestPath: nil)
        #expect(attempt.port == 0)
        #expect(attempt.diagnostics.contains("requires a manifest"))
    }

    @Test func rejectsPagedModeWithCpuMoe() {
        let attempt = attemptStart(
            version: 3,
            pagedMode: 1,
            manifestPath: "/nonexistent/noema-overfit.noema-paged/manifest.json",
            cpuMoe: 1
        )
        #expect(attempt.port == 0)
        #expect(attempt.diagnostics.contains("cpu_moe conflicts"))
    }

    @Test func rejectsStreamedModeWithoutSlotsOrBudget() throws {
        // Mode 2 with neither paged_slots_per_layer nor paged_bank_budget_mib
        // must fail closed before any model load.
        let url = try writeManifest(baseManifest())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attempt = attemptStart(version: 3, pagedMode: 2, manifestPath: url.path)
        #expect(attempt.port == 0)
        #expect(attempt.diagnostics.contains("invalid_configuration"))
        #expect(attempt.diagnostics.contains("paged_slots_per_layer or paged_bank_budget_mib"))
    }

    @Test func rejectsStreamedModeWithTooFewSlots() throws {
        // baseManifest declares expertsUsedDefault = 1, so the streamed floor
        // is n_expert_used + 2 = 3 slots; 2 must be refused (fail closed).
        let url = try writeManifest(baseManifest())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attempt = attemptStart(version: 3, pagedMode: 2, manifestPath: url.path, slotsPerLayer: 2)
        #expect(attempt.port == 0)
        #expect(attempt.diagnostics.contains("invalid_configuration"))
        #expect(attempt.diagnostics.contains("at least 3 slots"))
    }

    @Test func rejectsPagedModeWithDraftMtp() {
        // The MTP block is MoE and untested under paging: draft-mtp stays
        // rejected in both paged modes, with a message naming the type.
        let attempt = attemptStart(
            version: 3,
            pagedMode: 2,
            manifestPath: "/nonexistent/noema-overfit.noema-paged/manifest.json",
            speculativeType: "draft-mtp",
            draftModelPath: "/nonexistent/mtp-sidecar.gguf"
        )
        #expect(attempt.port == 0)
        #expect(attempt.diagnostics.contains("draft-mtp speculative decoding conflicts"))
    }

    @Test func rejectsResidentBankModeWithDraftSimple() {
        // Mode 1 admits no speculation at all; draft-simple is streamed-only.
        let attempt = attemptStart(
            version: 3,
            pagedMode: 1,
            manifestPath: "/nonexistent/noema-overfit.noema-paged/manifest.json",
            speculativeType: "draft-simple",
            draftModelPath: "/nonexistent/draft.gguf"
        )
        #expect(attempt.port == 0)
        #expect(attempt.diagnostics.contains("speculative decoding conflicts with paged mode"))
    }

    @Test func rejectsStreamedModeDraftPathWithoutType() {
        // A bare draft path (no speculative_type) is not the admitted shape.
        let attempt = attemptStart(
            version: 3,
            pagedMode: 2,
            manifestPath: "/nonexistent/noema-overfit.noema-paged/manifest.json",
            draftModelPath: "/nonexistent/draft.gguf"
        )
        #expect(attempt.port == 0)
        #expect(attempt.diagnostics.contains("speculative decoding conflicts with paged mode"))
    }

    @Test func streamedModeAcceptsDraftSimpleAndClampsBudget() throws {
        // Streamed mode admits draft-simple + draft model. The effective
        // --spec-draft-n-max is materialized and clamped to the streamed
        // micro-batch bound: 8 experts with expertsUsedDefault = 1 and 4
        // slots give floor((4 - 2) / 1) = 2 verification tokens, hence one
        // draft token after reserving the sampled token. The nonexistent GGUF then fails the model
        // load — but past every paged-conflict check, with the options
        // snapshot already recorded from the clamped configuration.
        let url = try writeManifest(manifestWithGeometry(expertCount: 8, expertsUsed: 1))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attempt = attemptStart(
            version: 3,
            pagedMode: 2,
            manifestPath: url.path,
            slotsPerLayer: 4,
            speculativeType: "draft-simple",
            draftModelPath: "/nonexistent/draft.gguf",
            specDraftNMax: 8
        )
        noema_llama_server_stop()
        #expect(attempt.port == 0)
        #expect(!attempt.diagnostics.contains("conflicts with paged mode"),
                "draft-simple was rejected under streamed mode: \(attempt.diagnostics)")
        #expect(attempt.options.contains("\"speculativeType\":\"draft-simple\""))
        #expect(attempt.options.contains("\"specDraftNMax\":1"),
                "requested draft budget 8 was not clamped to the N + 1-safe bound: \(attempt.options)")
        #expect(attempt.options.contains("--spec-draft-model"))
    }

    @Test func rejectsStreamedDraftWhenBankFitsOnlyVerificationToken() throws {
        let url = try writeManifest(manifestWithGeometry(expertCount: 8, expertsUsed: 2))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attempt = attemptStart(
            version: 3,
            pagedMode: 2,
            manifestPath: url.path,
            slotsPerLayer: 4,
            speculativeType: "draft-simple",
            draftModelPath: "/nonexistent/draft.gguf",
            specDraftNMax: 8
        )
        #expect(attempt.port == 0)
        #expect(attempt.diagnostics.contains("N + 1"))
    }

    @Test func version4CarriesExplicitWaveAndExpertMajorPolicy() throws {
        let url = try writeManifest(manifestWithGeometry(expertCount: 8, expertsUsed: 1))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attempt = attemptStart(
            version: 4,
            pagedMode: 2,
            manifestPath: url.path,
            slotsPerLayer: 4,
            pagedWaves: true,
            pagedExpertMajor: true
        )
        noema_llama_server_stop()
        #expect(attempt.port == 0)
        #expect(attempt.options.contains("\"pagedWaves\":true"))
        #expect(attempt.options.contains("\"pagedExpertMajor\":true"))
        #expect(attempt.options.contains("\"ubatchSize\":512"),
                "explicit waves did not lift the streamed micro-batch clamp: \(attempt.options)")
    }

    @Test func waveKillSwitchOverridesVersion4AndExpertMajorForce() throws {
        let url = try writeManifest(manifestWithGeometry(expertCount: 8, expertsUsed: 1))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        setenv("NOEMA_PAGED_WAVES", "0", 1)
        setenv("NOEMA_PAGED_EXPERT_MAJOR", "1", 1)
        defer {
            unsetenv("NOEMA_PAGED_WAVES")
            unsetenv("NOEMA_PAGED_EXPERT_MAJOR")
        }
        let attempt = attemptStart(
            version: 4,
            pagedMode: 2,
            manifestPath: url.path,
            slotsPerLayer: 4,
            pagedWaves: true,
            pagedExpertMajor: true
        )
        noema_llama_server_stop()
        #expect(attempt.port == 0)
        #expect(attempt.options.contains("\"ubatchSize\":2"),
                "NOEMA_PAGED_WAVES=0 did not restore the safe streamed clamp: \(attempt.options)")
    }

    @Test func version3CallersIgnoreVersion4WaveFields() throws {
        let url = try writeManifest(manifestWithGeometry(expertCount: 8, expertsUsed: 1))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attempt = attemptStart(
            version: 3,
            pagedMode: 2,
            manifestPath: url.path,
            slotsPerLayer: 4,
            pagedWaves: true,
            pagedExpertMajor: true
        )
        noema_llama_server_stop()
        #expect(attempt.port == 0)
        #expect(attempt.options.contains("\"pagedWaves\":false"))
        #expect(attempt.options.contains("\"pagedExpertMajor\":false"))
        #expect(attempt.options.contains("\"ubatchSize\":2"),
                "v3 caller unexpectedly bypassed the legacy streamed clamp: \(attempt.options)")
    }

    @Test func version2CallersIgnorePagedFields() {
        // A v2 caller's bytes stop at NOEMA_LLAMA_SERVER_CONFIGURATION_V2_SIZE;
        // the bridge must zero the paged tail, so garbage paged_mode never
        // becomes a paged validation failure. The start proceeds to a normal
        // model-load failure for the nonexistent gguf instead.
        let attempt = attemptStart(version: 2, pagedMode: 99, manifestPath: nil)
        #expect(attempt.port == 0)
        #expect(!attempt.diagnostics.isEmpty)
        #expect(!attempt.diagnostics.contains("paged"))
        #expect(!attempt.options.contains("pagedMode"))
    }
}
