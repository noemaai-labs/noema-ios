import Foundation
import XCTest
import NoemaPackages
@testable import Noema

final class OverfitFitAdvisorTests: XCTestCase {

    // MARK: - Fixture

    /// Minimal valid paged package on disk (mirrors the OverfitPlanResolverTests
    /// builder): 1 MoE layer x 3 families x `expertCount` experts of 16 bytes.
    private func makePackage(
        architecture: String = "qwen3moe",
        expertCount: UInt32 = 2,
        expertsUsedDefault: UInt32 = 1
    ) throws -> NoemaPagedPackage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-advisor-\(UUID().uuidString).noema-paged")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let recordLength: UInt64 = 16
        var payload = Data()
        var records: [NoemaPagedPackageManifest.Record] = []
        var offset: UInt64 = 0
        for layer in UInt32(0)..<1 {
            for family in [NoemaPagedPackageManifest.Family.gate, .up, .down] {
                for expert in UInt32(0)..<expertCount {
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
            model: .init(architecture: architecture, expertCount: expertCount,
                         expertsUsedDefault: expertsUsedDefault,
                         moeLayerCount: 1, totalLayerCount: 1, fusedGateUp: false),
            alignment: 8,
            resident: .init(path: "resident.gguf", sizeBytes: UInt64(residentData.count), sha256: residentSha),
            expertFiles: [.init(path: "experts-000.bin", sizeBytes: UInt64(payload.count), sha256: payloadSha)],
            records: records,
            fingerprint: NoemaPagedPackageManifest.computeFingerprint(
                residentSha256: residentSha, expertFileSha256s: [payloadSha]))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return try NoemaPagedPackage.load(at: dir)
    }

    private func makeEstimate(
        totalBytes: UInt64,
        bankBytes: UInt64 = 0,
        stagingBytes: UInt64 = 0
    ) -> LlamaServerBridge.MemoryEstimate {
        LlamaServerBridge.MemoryEstimate(
            modelBytes: totalBytes,
            contextBytes: 0,
            computeBytes: 0,
            projectorBytes: 0,
            speculativeBytes: 0,
            totalBytes: totalBytes,
            paged: LlamaServerBridge.PagedEstimate(
                bankBytes: bankBytes,
                stagingBytes: stagingBytes,
                slotsPerLayer: 8,
                moeLayerCount: 1
            )
        )
    }

    private func makeCanary(classification: OverfitFitClassification,
                            generationRate: Double) -> OverfitCanaryRecord {
        OverfitCanaryRecord(
            packageFingerprint: "fp",
            deviceModelIdentifier: "test-device",
            volumeIdentifier: "test-volume",
            nativeContractVersion: 4,
            appBuild: "1",
            completedAt: Date(timeIntervalSince1970: 1_780_000_000),
            storageAlignedReadMBps: 800,
            promptRate: 100,
            generationRate: generationRate,
            timeToFirstToken: 1.0,
            latency: nil,
            bankHitRate: 1.0,
            missesPerToken: 0,
            peakMemoryBytes: 1_000_000,
            thermalStateRaw: 0,
            classification: classification
        )
    }

    // MARK: - Worst-case miss math

    func testWorstCaseBytesMissedPerTokenSumsFamiliesTimesTopK() throws {
        // 1 layer x 3 families x 16 bytes = 48 per routed expert; k = 1.
        let k1 = try makePackage(expertCount: 2, expertsUsedDefault: 1)
        XCTAssertEqual(OverfitFitAdvisor.worstCaseBytesMissedPerToken(manifest: k1.manifest), 48)

        // Same geometry with k = 2 doubles the worst case.
        let k2 = try makePackage(expertCount: 2, expertsUsedDefault: 2)
        XCTAssertEqual(OverfitFitAdvisor.worstCaseBytesMissedPerToken(manifest: k2.manifest), 96)
    }

    // MARK: - Classification paths

    func testUnsupportedArchitectureShortCircuits() throws {
        let package = try makePackage(architecture: "mixtral")
        let assessment = OverfitFitAdvisor.assess(.init(
            package: package,
            memoryEstimate: makeEstimate(totalBytes: 1_000),
            availableMemoryBytes: 8 << 30,
            storageAlignedReadMBps: 1000,
            canary: nil,
            mode: .residentBank
        ))
        XCTAssertEqual(assessment.classification, .unsupported)
        XCTAssertNil(assessment.predictedFloorTokensPerSecond)
    }

    func testCanaryMeasurementWinsOverEveryPrediction() throws {
        let package = try makePackage()
        // Memory says it cannot fit, yet the measured canary wins.
        let assessment = OverfitFitAdvisor.assess(.init(
            package: package,
            memoryEstimate: makeEstimate(totalBytes: 64 << 30),
            availableMemoryBytes: 1 << 30,
            storageAlignedReadMBps: nil,
            canary: makeCanary(classification: .pagedSlow, generationRate: 3.5),
            mode: .streamed
        ))
        XCTAssertEqual(assessment.classification, .pagedSlow)
        XCTAssertEqual(assessment.predictedFloorTokensPerSecond, 3.5)
    }

    func testMemoryExceededResidentBankRecommendsRelay() throws {
        let package = try makePackage()
        let assessment = OverfitFitAdvisor.assess(.init(
            package: package,
            memoryEstimate: makeEstimate(totalBytes: 8 << 30),
            availableMemoryBytes: 1 << 30,
            storageAlignedReadMBps: 1000,
            canary: nil,
            mode: .residentBank
        ))
        XCTAssertEqual(assessment.classification, .relayRecommended)
    }

    func testMemoryExceededStreamedIsOfflineOnly() throws {
        let package = try makePackage()
        let assessment = OverfitFitAdvisor.assess(.init(
            package: package,
            memoryEstimate: makeEstimate(totalBytes: 8 << 30),
            availableMemoryBytes: 1 << 30,
            storageAlignedReadMBps: 1000,
            canary: nil,
            mode: .streamed
        ))
        XCTAssertEqual(assessment.classification, .offlineOnly)
    }

    func testSafetyReserveTipsABorderlineFit() throws {
        let package = try makePackage()
        let totalBytes: UInt64 = 4 << 30
        // Available covers the estimate but not the 512 MiB reserve.
        let assessment = OverfitFitAdvisor.assess(.init(
            package: package,
            memoryEstimate: makeEstimate(totalBytes: totalBytes),
            availableMemoryBytes: totalBytes + (256 << 20),
            storageAlignedReadMBps: nil,
            canary: nil,
            mode: .residentBank
        ))
        XCTAssertEqual(assessment.classification, .relayRecommended)
    }

    func testStreamedWithoutCalibrationDemandsCanary() throws {
        let package = try makePackage()
        let assessment = OverfitFitAdvisor.assess(.init(
            package: package,
            memoryEstimate: makeEstimate(totalBytes: 1 << 20),
            availableMemoryBytes: 8 << 30,
            storageAlignedReadMBps: nil,
            canary: nil,
            mode: .streamed
        ))
        XCTAssertEqual(assessment.classification, .pagedSlow)
        XCTAssertNil(assessment.predictedFloorTokensPerSecond)
        XCTAssertTrue(assessment.detail.contains("canary required"))
    }

    func testStreamedPredictedFloorSelectsEachBand() throws {
        let package = try makePackage()  // 48 worst-case bytes per token

        func assess(mbps: Double) -> OverfitFitAssessment {
            OverfitFitAdvisor.assess(.init(
                package: package,
                memoryEstimate: nil,
                availableMemoryBytes: 8 << 30,
                storageAlignedReadMBps: mbps,
                canary: nil,
                mode: .streamed
            ))
        }

        // floor = mbps * 1e6 / 48
        let interactive = assess(mbps: 0.001)           // ~20.8 tok/s
        XCTAssertEqual(interactive.classification, .pagedInteractive)
        XCTAssertEqual(try XCTUnwrap(interactive.predictedFloorTokensPerSecond),
                       1000.0 / 48.0, accuracy: 1e-9)

        let slow = assess(mbps: 0.0002)                 // ~4.2 tok/s
        XCTAssertEqual(slow.classification, .pagedSlow)

        let offline = assess(mbps: 0.00008)             // ~1.7 tok/s
        XCTAssertEqual(offline.classification, .offlineOnly)
    }

    func testResidentBankThatFitsIsInteractiveWithoutStorageDependence() throws {
        let package = try makePackage()
        let assessment = OverfitFitAdvisor.assess(.init(
            package: package,
            memoryEstimate: makeEstimate(totalBytes: 1 << 30, bankBytes: 1 << 20),
            availableMemoryBytes: 8 << 30,
            storageAlignedReadMBps: nil,
            canary: nil,
            mode: .residentBank
        ))
        XCTAssertEqual(assessment.classification, .pagedInteractive)
        XCTAssertNil(assessment.predictedFloorTokensPerSecond)
        XCTAssertEqual(assessment.bankBytes, 1 << 20)
    }

    // MARK: - Remote catalog estimates

    func testRemoteEstimateUsesPagedWorkingSetInsteadOfPackageDownloadSize() {
        let gib = UInt64(1_073_741_824)
        let manifestBytes: Int64 = 8 * 1_048_576
        let manifest = NoemaPagedPackageManifest(
            formatVersion: 1,
            createdBy: nil,
            source: .init(fileName: "source.gguf", ggufSizeBytes: 76 * gib, ggufSha256: "source"),
            model: .init(
                architecture: "qwen35moe",
                expertCount: 256,
                expertsUsedDefault: 8,
                moeLayerCount: 48,
                totalLayerCount: 48,
                fusedGateUp: false
            ),
            alignment: 4096,
            resident: .init(path: "resident.gguf", sizeBytes: 4 * gib, sha256: "resident"),
            expertFiles: [.init(path: "experts-000.bin", sizeBytes: 72 * gib, sha256: "experts")],
            records: [],
            fingerprint: "fingerprint"
        )

        let estimate = OverfitRemotePackageAdvisor.assess(
            manifest: manifest,
            manifestBytes: manifestBytes,
            physicalMemoryBytes: 16 * gib,
            availableHeadroomBytes: Int64(12 * gib),
            budgetBytes: Int64(64 * gib)
        )

        XCTAssertEqual(estimate.packageStorageBytes, Int64(76 * gib) + manifestBytes)
        XCTAssertEqual(estimate.residentBytes, Int64(4 * gib))
        XCTAssertGreaterThan(estimate.workingSetBytes, estimate.residentBytes)
        XCTAssertLessThan(estimate.workingSetBytes, estimate.packageStorageBytes)
        XCTAssertEqual(estimate.status, .works)
        XCTAssertTrue(estimate.architectureSupported)
#if os(macOS) || targetEnvironment(macCatalyst)
        XCTAssertEqual(estimate.expertBankBytes, Int64(8 * gib))
        XCTAssertEqual(estimate.contextCapTokens, 8192)
#else
        XCTAssertEqual(estimate.expertBankBytes, Int64(4 * gib))
        XCTAssertEqual(estimate.contextCapTokens, 4096)
#endif
    }

    func testRemoteEstimateHonorsDeviceBudgetAndArchitectureSupport() throws {
        let package = try makePackage()
        let tooSmall = OverfitRemotePackageAdvisor.assess(
            manifest: package.manifest,
            physicalMemoryBytes: 8 << 30,
            availableHeadroomBytes: 2 << 30,
            budgetBytes: 1
        )
        XCTAssertEqual(tooSmall.status, .unlikely)

        let unsupportedPackage = try makePackage(architecture: "mixtral")
        let unsupported = OverfitRemotePackageAdvisor.assess(
            manifest: unsupportedPackage.manifest,
            physicalMemoryBytes: 64 << 30,
            availableHeadroomBytes: 32 << 30,
            budgetBytes: 64 << 30
        )
        XCTAssertFalse(unsupported.architectureSupported)
        XCTAssertEqual(unsupported.status, .unlikely)
    }

    // MARK: - Paged launch power gate

    private func environment(
        thermal: ProcessInfo.ThermalState,
        lowPower: Bool = false
    ) -> GenerationPowerPolicy.Environment {
        GenerationPowerPolicy.Environment(
            thermalState: thermal,
            lowPowerMode: lowPower,
            activeProcessorCount: 8
        )
    }

    func testPagedLaunchGateBlocksCriticalThermal() {
        XCTAssertEqual(
            GenerationPowerPolicy.pagedLaunchGate(environment: environment(thermal: .critical)),
            .blocked(reason: .criticalThermal)
        )
        // Critical blocks even when low power would only have reduced.
        XCTAssertEqual(
            GenerationPowerPolicy.pagedLaunchGate(
                environment: environment(thermal: .critical, lowPower: true)
            ),
            .blocked(reason: .criticalThermal)
        )
    }

    func testPagedLaunchGateReducesForSeriousThermalOrLowPower() {
        XCTAssertEqual(
            GenerationPowerPolicy.pagedLaunchGate(environment: environment(thermal: .serious)),
            .allowedReduced(reasons: [.seriousThermal])
        )
        XCTAssertEqual(
            GenerationPowerPolicy.pagedLaunchGate(
                environment: environment(thermal: .nominal, lowPower: true)
            ),
            .allowedReduced(reasons: [.lowPowerMode])
        )
        XCTAssertEqual(
            GenerationPowerPolicy.pagedLaunchGate(
                environment: environment(thermal: .serious, lowPower: true)
            ),
            .allowedReduced(reasons: [.lowPowerMode, .seriousThermal])
        )
    }

    func testPagedLaunchGateAllowsNominalAndFair() {
        XCTAssertEqual(
            GenerationPowerPolicy.pagedLaunchGate(environment: environment(thermal: .nominal)),
            .allowed
        )
        XCTAssertEqual(
            GenerationPowerPolicy.pagedLaunchGate(environment: environment(thermal: .fair)),
            .allowed
        )
    }
}
