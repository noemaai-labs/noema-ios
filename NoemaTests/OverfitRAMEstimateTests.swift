import Foundation
import XCTest
import NoemaPackages
@testable import Noema

final class OverfitRAMEstimateTests: XCTestCase {

    private static let mib: Int64 = 1_048_576

    // MARK: - Fixtures

    /// Minimal valid qwen3moe paged package on disk (builder pattern from
    /// OverfitPlanResolverTests). The expert payload is a sparse file so the
    /// package total can dwarf every platform bank ceiling without writing
    /// gigabytes: only the first 96 record bytes are real, and structural
    /// validation checks names/sizes/bounds, never payload contents.
    private func makePagedPackage(
        residentBytes: Int,
        expertFileBytes: UInt64
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-ram-\(UUID().uuidString).noema-paged")
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
        precondition(expertFileBytes > UInt64(payload.count))

        let residentData = Data(count: residentBytes)
        try residentData.write(to: dir.appendingPathComponent("resident.gguf"))

        let expertsURL = dir.appendingPathComponent("experts-000.bin")
        FileManager.default.createFile(atPath: expertsURL.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: expertsURL)
            try handle.write(contentsOf: payload)
            try handle.truncate(atOffset: expertFileBytes)
            try handle.close()
        } catch {
            throw XCTSkip("filesystem does not support the sparse expert fixture: \(error)")
        }

        let residentSha = PagedSHA256.hexDigest(of: residentData)
        // Structural validation never hashes payload files; any stable digest
        // string keeps the fingerprint well-formed.
        let payloadSha = PagedSHA256.hexDigest(of: payload)
        let manifest = NoemaPagedPackageManifest(
            formatVersion: 1, createdBy: nil,
            source: .init(fileName: "s.gguf", ggufSizeBytes: 1, ggufSha256: "00"),
            model: .init(architecture: "qwen3moe", expertCount: 2, expertsUsedDefault: 1,
                         moeLayerCount: 1, totalLayerCount: 1, fusedGateUp: false),
            alignment: 8,
            resident: .init(path: "resident.gguf", sizeBytes: UInt64(residentData.count), sha256: residentSha),
            expertFiles: [.init(path: "experts-000.bin", sizeBytes: expertFileBytes, sha256: payloadSha)],
            records: records,
            fingerprint: NoemaPagedPackageManifest.computeFingerprint(
                residentSha256: residentSha, expertFileSha256s: [payloadSha]))
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    private func makePlainGGUF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-ram-plain-\(UUID().uuidString).gguf")
        try Data("GGUF".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Paged installs

    func testPagedEstimateFiguresMatchLaunchPlan() throws {
        let residentBytes = 4 * 1024 * 1024
        // 48 GiB of (sparse) experts: far above every platform bank ceiling,
        // so the package ceiling never binds and the strict upper bound below
        // has gigabytes of margin on any host.
        let package = try makePagedPackage(residentBytes: residentBytes,
                                           expertFileBytes: 48 << 30)
        let modelURL = package.appendingPathComponent("resident.gguf")

        guard case .paged(let parameters) = OverfitPlanResolver.plan(
            modelURL: modelURL,
            settings: ModelSettings.default(for: .gguf),
            purpose: .chat
        ) else {
            return XCTFail("fixture did not resolve to a paged plan")
        }

        let figures = try XCTUnwrap(
            ModelRAMAdvisor.pagedEstimateFigures(forModelPath: modelURL.path)
        )
        XCTAssertEqual(figures.residentBytes, Int64(residentBytes))
        XCTAssertEqual(figures.stagingBytes, ModelRAMAdvisor.pagedStagingEstimateBytes)
        XCTAssertEqual(figures.contextCapTokens, Int(parameters.contextCap))
        // Launch parity. On iOS-family hosts the bank derives from live
        // headroom, which can drift between the two plan resolutions, so the
        // comparison carries a small tolerance; the formula itself is exact.
        XCTAssertEqual(
            Double(figures.bankBudgetBytes),
            Double(Int64(parameters.bankBudgetMiB) * Self.mib),
            accuracy: Double(256 * Self.mib)
        )
        XCTAssertEqual(
            figures.weightBytes,
            figures.residentBytes + figures.bankBudgetBytes + figures.stagingBytes
        )

        // Strict bounds: more than the resident file alone, less than the
        // on-disk package total.
        let packageTotal = PagedPackageLocator.packageTotalBytes(package)
        XCTAssertGreaterThan(figures.weightBytes, Int64(residentBytes))
        XCTAssertLessThan(figures.weightBytes, packageTotal)
    }

    func testPagedHeuristicEstimateUsesResidentPlusBankPlusStaging() throws {
        let residentBytes = 4 * 1024 * 1024
        let package = try makePagedPackage(residentBytes: residentBytes,
                                           expertFileBytes: 48 << 30)
        let modelURL = package.appendingPathComponent("resident.gguf")
        let figures = try XCTUnwrap(
            ModelRAMAdvisor.pagedEstimateFigures(forModelPath: modelURL.path)
        )
        let packageTotal = PagedPackageLocator.packageTotalBytes(package)

        let runtime = ModelRAMAdvisor.RuntimeConfiguration(modelPath: modelURL.path)
        let breakdown = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf,
            sizeBytes: packageTotal, // what a naive surface would feed in
            contextLength: 4096,
            layerCount: nil,
            runtimeConfiguration: runtime
        )

        // Weights follow the paged runtime exactly: resident + bank + staging.
        XCTAssertEqual(breakdown.weights, figures.weightBytes)
        // The full working-set estimate stays strictly between resident-alone
        // and the package total.
        XCTAssertGreaterThan(breakdown.estimate, Int64(residentBytes))
        XCTAssertLessThan(breakdown.estimate, packageTotal)
    }

    func testPagedEstimateClampsContextAtPlanCap() throws {
        let package = try makePagedPackage(residentBytes: 4 * 1024 * 1024,
                                           expertFileBytes: 48 << 30)
        let modelURL = package.appendingPathComponent("resident.gguf")
        let figures = try XCTUnwrap(
            ModelRAMAdvisor.pagedEstimateFigures(forModelPath: modelURL.path)
        )
        let runtime = ModelRAMAdvisor.RuntimeConfiguration(modelPath: modelURL.path)

        let atCap = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf, sizeBytes: 0, contextLength: figures.contextCapTokens,
            layerCount: 32, runtimeConfiguration: runtime
        )
        let farBeyondCap = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf, sizeBytes: 0, contextLength: 131_072,
            layerCount: 32, runtimeConfiguration: runtime
        )
        // The paged server clamps context at launch; the estimate must not
        // keep inflating KV/compute costs past the cap.
        XCTAssertEqual(atCap, farBeyondCap)
    }

    // MARK: - Plain GGUFs stay byte-identical

    func testPlainGGUFEstimatePathIsUnchanged() throws {
        let plainURL = try makePlainGGUF()
        XCTAssertNil(ModelRAMAdvisor.pagedEstimateFigures(forModelPath: plainURL.path))

        // Pinned resident value: 4 GiB × the long-standing 1.05 GGUF weights
        // multiplier. Any drift in the plain path trips this exact byte count.
        let sizeBytes: Int64 = 4_294_967_296
        let breakdown = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf,
            sizeBytes: sizeBytes,
            contextLength: 4096,
            layerCount: 32
        )
        XCTAssertEqual(breakdown.weights, 4_509_715_660)

        // Pointing the runtime at an on-disk *plain* GGUF must not change a
        // single byte of the breakdown — the paged hook is a strict no-op.
        let withPath = ModelRAMAdvisor.estimateBreakdown(
            format: .gguf,
            sizeBytes: sizeBytes,
            contextLength: 4096,
            layerCount: 32,
            runtimeConfiguration: ModelRAMAdvisor.RuntimeConfiguration(modelPath: plainURL.path)
        )
        XCTAssertEqual(breakdown, withPath)
    }
}
