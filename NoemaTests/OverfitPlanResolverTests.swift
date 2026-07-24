import Foundation
import XCTest
import NoemaPackages
@testable import Noema

final class OverfitPlanResolverTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal valid qwen3moe paged package on disk (structure only; the
    /// resident GGUF is a placeholder because the plan resolver never parses it).
    private func makePagedPackage() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-plan-\(UUID().uuidString).noema-paged")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let recordLength: UInt64 = 16
        var payload = Data()
        var records: [NoemaPagedPackageManifest.Record] = []
        var offset: UInt64 = 0
        for layer in UInt32(0)..<1 {
            for family in [NoemaPagedPackageManifest.Family.gate, .up, .down] {
                for expert in UInt32(0)..<2 {
                    let chunk = Data((0..<recordLength).map { UInt8(($0 &+ UInt64(expert)) & 0xFF) })
                    records.append(.init(layer: layer, family: family, expert: expert, file: 0,
                                         offset: offset, length: recordLength,
                                         xxh64: String(format: "%016llx", PagedXXH64.hash(chunk)),
                                         ggmlType: 0, ne: [2, 2]))
                    payload.append(chunk)
                    offset += recordLength
                }
            }
        }
        let residentData = Data("placeholder".utf8)
        try residentData.write(to: dir.appendingPathComponent("resident.gguf"))
        try payload.write(to: dir.appendingPathComponent("experts-000.bin"))
        let residentSha = PagedSHA256.hexDigest(of: residentData)
        let payloadSha = PagedSHA256.hexDigest(of: payload)
        let manifest = NoemaPagedPackageManifest(
            formatVersion: 1, createdBy: nil,
            source: .init(fileName: "s.gguf", ggufSizeBytes: 1, ggufSha256: "00"),
            model: .init(architecture: "qwen3moe", expertCount: 2, expertsUsedDefault: 1,
                         moeLayerCount: 1, totalLayerCount: 1, fusedGateUp: false),
            alignment: 8,
            resident: .init(path: "resident.gguf", sizeBytes: UInt64(residentData.count), sha256: residentSha),
            expertFiles: [.init(path: "experts-000.bin", sizeBytes: UInt64(payload.count), sha256: payloadSha)],
            records: records,
            fingerprint: NoemaPagedPackageManifest.computeFingerprint(
                residentSha256: residentSha, expertFileSha256s: [payloadSha]))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    private func makePlainGGUF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-plain-\(UUID().uuidString).gguf")
        try Data("GGUF".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Resident path stays byte-identical

    @MainActor
    func testResolveWithPlanMatchesLegacyResolveForPlainGGUF() throws {
        let url = try makePlainGGUF()
        var settings = ModelSettings.default(for: .gguf)
        settings.contextLength = 4096

        let legacy = GGUFServerConfigurationResolver.resolve(
            modelURL: url, settings: settings, mmprojPath: nil, contextShiftEnabled: true)
        let (configuration, plan) = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: url, settings: settings, mmprojPath: nil, contextShiftEnabled: true)

        XCTAssertEqual(plan, .resident)
        XCTAssertEqual(configuration, legacy)
        XCTAssertEqual(configuration.pagedMode, .off)
        XCTAssertNil(configuration.pagedManifestPath)
    }

    // MARK: - Paged plan forces its runtime shape

    @MainActor
    func testPagedPlanForcesOverrides() throws {
        // Waves default ON for macOS streamed launches; pin the kill switch so
        // the single-token micro-batch assertions below hold on every platform.
        setenv("NOEMA_PAGED_WAVES", "0", 1)
        defer { unsetenv("NOEMA_PAGED_WAVES") }
        let package = try makePagedPackage()
        let modelURL = package.appendingPathComponent("resident.gguf")
        var settings = ModelSettings.default(for: .gguf)
        settings.contextLength = 65536
        settings.useMmap = true
        settings.keepInMemory = true
        settings.promptCacheEnabled = true
        settings.disableWarmup = false

        let (configuration, plan) = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: modelURL, settings: settings, mmprojPath: "/tmp/should-be-dropped.mmproj",
            contextShiftEnabled: true)

        guard case .paged(let parameters) = plan else {
            return XCTFail("expected a paged plan, got \(plan)")
        }
        XCTAssertEqual(parameters.mode, .streamed)
        XCTAssertGreaterThan(parameters.bankBudgetMiB, 0)
        // The fixture's expert payload is 1 layer x 3 families x 2 experts x 16 B
        // = 96 B, so the package ceiling must clamp the bank budget all the way
        // down to ceil(96 B / 1 MiB) = 1 MiB regardless of device RAM.
        let fixtureExpertBytes: Int64 = 1 * 3 * 2 * 16
        let mib: Int64 = 1024 * 1024
        let expertCapMiB = Int32((fixtureExpertBytes + mib - 1) / mib)
        XCTAssertLessThanOrEqual(parameters.bankBudgetMiB, expertCapMiB + 1)
#if os(macOS) || targetEnvironment(macCatalyst)
        XCTAssertEqual(parameters.contextCap, 8192)
#else
        XCTAssertEqual(parameters.contextCap, 4096)
#endif
        XCTAssertEqual(parameters.prefetch, !ProcessInfo.processInfo.isLowPowerModeEnabled)
        XCTAssertEqual(configuration.pagedMode, .streamed)
        XCTAssertEqual(configuration.ubatchSize, 1)
        XCTAssertFalse(configuration.pagedWaves)
        XCTAssertFalse(configuration.pagedExpertMajor)
        XCTAssertGreaterThan(configuration.pagedBankBudgetMiB, 0)
        XCTAssertEqual(configuration.pagedManifestPath,
                       package.appendingPathComponent("manifest.json").path)
        XCTAssertFalse(configuration.useMmap)
        XCTAssertFalse(configuration.useMlock)
        XCTAssertFalse(configuration.warmup)
        XCTAssertNil(configuration.mmprojPath)
        XCTAssertNil(configuration.speculativeType)
        XCTAssertEqual(configuration.parallelSlots, 1)
        XCTAssertEqual(configuration.cacheRamMiB, 0)
        // Hybrid architectures cannot roll a sequence back partially, so
        // streamed launches keep context checkpoints on (the only prefix-reuse
        // mechanism that works for them).
        XCTAssertEqual(configuration.ctxCheckpoints, OverfitPlanResolver.pagedCtxCheckpoints)
        XCTAssertLessThanOrEqual(configuration.contextSize, parameters.contextCap)
#if os(macOS) || targetEnvironment(macCatalyst)
        XCTAssertEqual(configuration.pagedIOThreads, 4)
        XCTAssertEqual(configuration.pagedIODepth, 12)
#else
        XCTAssertEqual(configuration.pagedIOThreads, 4)
        XCTAssertEqual(configuration.pagedIODepth, 8)
#endif
    }

    @MainActor
    func testPagedHelperMaxModeEnablesDynamicDraftController() throws {
        setenv("NOEMA_PAGED_WAVES", "0", 1)
        defer { unsetenv("NOEMA_PAGED_WAVES") }
        let package = try makePagedPackage()
        let targetURL = package.appendingPathComponent("resident.gguf")
        let helperURL = try makePlainGGUF()
        let helper = LocalModel(
            modelID: "fixture/helper-draft",
            name: "helper-draft",
            url: helperURL,
            quant: "F16",
            architecture: "qwen3moe",
            architectureFamily: "qwen",
            format: .gguf,
            sizeGB: 0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 1
        )
        var settings = ModelSettings.default(for: .gguf)
        settings.speculativeDecoding.selection = .helperDraftModel
        settings.speculativeDecoding.helperModelID = helper.modelID
        settings.speculativeDecoding.mode = .max
        settings.speculativeDecoding.value = 64

        let (dynamic, plan) = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: targetURL,
            settings: settings,
            mmprojPath: nil,
            contextShiftEnabled: true,
            downloadedModels: [helper]
        )
        guard case .paged = plan else {
            return XCTFail("expected a paged plan, got \(plan)")
        }
        XCTAssertEqual(dynamic.speculativeType, "draft-simple")
        XCTAssertEqual(dynamic.specDraftNMax, 8)
        XCTAssertTrue(dynamic.specDynamic)

        settings.speculativeDecoding.mode = .tokens
        let (fixed, _) = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: targetURL,
            settings: settings,
            mmprojPath: nil,
            contextShiftEnabled: true,
            downloadedModels: [helper]
        )
        XCTAssertFalse(fixed.specDynamic)
    }

    /// Wave-split prefill (NOEMA_PAGED_WAVES=1) needs multi-token prefill
    /// graphs — the native gate requires n_tokens > 1 — so the streamed
    /// micro-batch pin of 1 must lift to the resolved physical batch when the
    /// waves knob is set. The bridge stays the clamp authority: waves off →
    /// floor((slots − spare) / K); waves on → no clamp. Without this lift the
    /// waves opt-in is inert (every prefill graph is single-token and
    /// prefill_waves returns 0), which is exactly the measured "waves changed
    /// nothing" run.
    @MainActor
    func testWavesOptInLiftsStreamedMicroBatchPin() throws {
        let package = try makePagedPackage()
        let modelURL = package.appendingPathComponent("resident.gguf")
        let settings = ModelSettings.default(for: .gguf)

        setenv("NOEMA_PAGED_WAVES", "1", 1)
        defer { unsetenv("NOEMA_PAGED_WAVES") }
        let (configuration, plan) = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: modelURL, settings: settings, mmprojPath: nil, contextShiftEnabled: true)

        guard case .paged(let parameters) = plan else {
            return XCTFail("expected a paged plan, got \(plan)")
        }
        XCTAssertEqual(parameters.mode, .streamed)
        XCTAssertEqual(
            configuration.ubatchSize,
            OverfitPlanResolver.initialPagedWaveUbatch(
                requested: Int32(clamping: settings.resolvedPhysicalBatchSize),
                contextCap: parameters.contextCap
            )
        )
        XCTAssertGreaterThan(configuration.ubatchSize, 1,
                             "default waves left the streamed micro-batch pinned to one token")
        XCTAssertTrue(configuration.pagedWaves)
        XCTAssertTrue(configuration.pagedExpertMajor)
    }

    func testWaveUbatchCandidatesAreDescendingAndBounded() {
        XCTAssertEqual(
            OverfitPlanResolver.pagedWaveUbatchCandidates(contextCap: 4096),
            [1024, 512, 256, 128, 64, 32, 16, 8, 4, 2]
        )
        XCTAssertEqual(
            OverfitPlanResolver.pagedWaveUbatchCandidates(contextCap: 300),
            [300, 256, 128, 64, 32, 16, 8, 4, 2]
        )
        XCTAssertEqual(
            OverfitPlanResolver.pagedWaveUbatchCandidates(contextCap: 32),
            [32, 16, 8, 4, 2]
        )
        XCTAssertEqual(OverfitPlanResolver.pagedWaveUbatchCandidates(contextCap: 1), [1])
    }

    func testAdaptiveBankSpendsOnlyExactSizingSlackAboveReserve() {
        let current: Int32 = 1_992
        let required: Int64 = 4_916_359_432
        let available: Int64 = 6_267_926_064
        let expanded = OverfitPlanResolver.expandedPagedBankBudgetMiB(
            currentMiB: current,
            requiredBytes: required,
            availableBytes: available
        )
        let expectedGrowth = (available - required
            - OverfitPlanResolver.adaptivePagedBankReserveBytes) / 1_048_576
        XCTAssertEqual(expanded, current + Int32(clamping: expectedGrowth))
    }

    func testAdaptiveBankDoesNotGrowWithoutProvenSlack() {
        let current: Int32 = 2_048
        XCTAssertEqual(
            OverfitPlanResolver.expandedPagedBankBudgetMiB(
                currentMiB: current,
                requiredBytes: nil,
                availableBytes: nil
            ),
            current
        )
        XCTAssertEqual(
            OverfitPlanResolver.expandedPagedBankBudgetMiB(
                currentMiB: current,
                requiredBytes: 5_000_000_000,
                availableBytes: 5_000_000_000
                    + OverfitPlanResolver.adaptivePagedBankReserveBytes
            ),
            current
        )
    }

    // MARK: - Bank budget policy

    /// Pins the platform bounds of the pure budget policy. Package validation
    /// checks on-disk sizes against the manifest, so large-RAM shapes can only
    /// be exercised through the extracted helper, not a disk fixture.
    func testBankBudgetPolicyBoundsAndPackageCeiling() {
        let gib: UInt64 = 1 << 30
        let gibI: Int64 = 1 << 30
        // A package ceiling far above every platform ceiling, i.e. inert.
        let hugePackage: Int64 = 1 << 50

#if os(macOS) || targetEnvironment(macCatalyst)
        // Mac: physical/2, clamped [2048, 32768] MiB; headroom input is inert.
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 4 * gib, availableHeadroomBytes: 0,
            totalExpertBytes: hugePackage), 2048)
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 8 * gib, availableHeadroomBytes: 0,
            totalExpertBytes: hugePackage), 4096)
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 64 * gib, availableHeadroomBytes: 0,
            totalExpertBytes: hugePackage), 32_768)
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 192 * gib, availableHeadroomBytes: 0,
            totalExpertBytes: hugePackage), 32_768)
#else
        // iOS/visionOS: headroom/3, clamped [1024, 8192] MiB; physical RAM is inert.
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 4 * gib, availableHeadroomBytes: 0,
            totalExpertBytes: hugePackage), 1024)
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 4 * gib, availableHeadroomBytes: 2 * gibI,
            totalExpertBytes: hugePackage), 1024)
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 8 * gib, availableHeadroomBytes: 6 * gibI,
            totalExpertBytes: hugePackage), 2048)
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 16 * gib, availableHeadroomBytes: 12 * gibI,
            totalExpertBytes: hugePackage), 4096)
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 16 * gib, availableHeadroomBytes: 48 * gibI,
            totalExpertBytes: hugePackage), 8192)
#endif
        // The package ceiling binds on every platform: a 3 GiB expert payload
        // caps a budget that platform policy alone would set far higher.
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 192 * gib, availableHeadroomBytes: 48 * gibI,
            totalExpertBytes: 3 * gibI), 3 * 1024)
        // Sub-MiB payloads round up to a 1 MiB budget, never zero.
        XCTAssertEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 192 * gib, availableHeadroomBytes: 48 * gibI,
            totalExpertBytes: 96), 1)
        // A degenerate manifest with zero expert bytes leaves the platform
        // budget untouched rather than clamping to zero.
        XCTAssertGreaterThanOrEqual(OverfitPlanResolver.resolvedBankBudgetMiB(
            physicalMemoryBytes: 8 * gib, availableHeadroomBytes: 6 * gibI,
            totalExpertBytes: 0), 1024)
    }

    @MainActor
    func testModeOffRefusesPagedInstalls() throws {
        let package = try makePagedPackage()
        let modelURL = package.appendingPathComponent("resident.gguf")
        var settings = ModelSettings.default(for: .gguf)
        settings.overfitMode = .off

        let (_, plan) = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: modelURL, settings: settings, mmprojPath: nil, contextShiftEnabled: true)
        XCTAssertEqual(plan, .refused(.modeOff))
    }

    @MainActor
    func testUtilityPurposeRefusesPagedInstalls() throws {
        let package = try makePagedPackage()
        let modelURL = package.appendingPathComponent("resident.gguf")
        let settings = ModelSettings.default(for: .gguf)

        let (_, plan) = GGUFServerConfigurationResolver.resolveWithPlan(
            modelURL: modelURL, settings: settings, mmprojPath: nil,
            contextShiftEnabled: true, purpose: .utility)
        XCTAssertEqual(plan, .refused(.unsupportedPurpose))
    }

    // MARK: - Locator

    func testLocatorFindsEnclosingPackage() throws {
        let package = try makePagedPackage()
        let inner = package.appendingPathComponent("resident.gguf")
        XCTAssertEqual(PagedPackageLocator.enclosingPackage(for: inner)?.lastPathComponent,
                       package.lastPathComponent)
        XCTAssertTrue(PagedPackageLocator.isPagedInstall(inner))
        XCTAssertFalse(PagedPackageLocator.isPagedInstall(FileManager.default.temporaryDirectory))
        XCTAssertGreaterThan(PagedPackageLocator.packageTotalBytes(package), 0)
    }

    // MARK: - Settings persistence

    @MainActor
    func testOverfitModeDecodeToleratesLegacyAndUnknownValues() throws {
        // Legacy payload with no overfitMode key decodes to the default.
        let legacy = try JSONDecoder().decode(
            ModelSettings.self,
            from: try JSONEncoder().encode(LegacyModelSettingsShim()))
        XCTAssertEqual(legacy.overfitMode, .automatic)

        // Unknown raw values written by a newer build fall back, not throw.
        var encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(ModelSettings.default(for: .gguf))) as! [String: Any]
        encoded["overfitMode"] = "hyperPaged"
        let decoded = try JSONDecoder().decode(
            ModelSettings.self,
            from: try JSONSerialization.data(withJSONObject: encoded))
        XCTAssertEqual(decoded.overfitMode, .automatic)

        // Round-trip keeps an explicit choice.
        var settings = ModelSettings.default(for: .gguf)
        settings.overfitMode = .forceExperimental
        let roundTripped = try JSONDecoder().decode(
            ModelSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(roundTripped.overfitMode, .forceExperimental)
    }

    /// Encodes an empty object so decoding exercises every missing-key default.
    private struct LegacyModelSettingsShim: Encodable {}
}
