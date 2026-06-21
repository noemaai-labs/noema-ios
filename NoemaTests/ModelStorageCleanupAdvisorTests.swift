import Foundation
import XCTest
@testable import Noema

final class ModelStorageCleanupAdvisorTests: XCTestCase {
    func testRanksByReclaimableSpaceBeforeStaleness() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let smallNeverLoaded = makeLocalModel(name: "Small Never", sizeGB: 2, lastUsedDate: nil)
        let largeRecentlyUsed = makeLocalModel(
            name: "Large Recent",
            sizeGB: 8,
            lastUsedDate: now.addingTimeInterval(-5 * 24 * 60 * 60)
        )

        let candidates = ModelStorageCleanupAdvisor.candidates(
            visibleModels: [smallNeverLoaded, largeRecentlyUsed],
            hiddenModels: [],
            loadedModelPath: nil,
            now: now
        )

        XCTAssertEqual(candidates.map(\.name), ["Large Recent", "Small Never"])
        XCTAssertEqual(candidates.first?.reclaimableBytes, 8 * 1_073_741_824)
    }

    func testUsesStalenessAsTieBreaker() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = makeLocalModel(
            name: "Stale",
            sizeGB: 4,
            lastUsedDate: now.addingTimeInterval(-60 * 24 * 60 * 60)
        )
        let neverLoaded = makeLocalModel(name: "Never Loaded", sizeGB: 4, lastUsedDate: nil)
        let recent = makeLocalModel(
            name: "Recent",
            sizeGB: 4,
            lastUsedDate: now.addingTimeInterval(-2 * 24 * 60 * 60)
        )

        let candidates = ModelStorageCleanupAdvisor.candidates(
            visibleModels: [recent, stale, neverLoaded],
            hiddenModels: [],
            loadedModelPath: nil,
            now: now
        )

        XCTAssertEqual(candidates.map(\.name), ["Never Loaded", "Stale", "Recent"])
        XCTAssertNil(candidates[0].lastUsedDays)
        XCTAssertEqual(candidates[1].lastUsedDays, 60)
        XCTAssertEqual(candidates[2].lastUsedDays, 2)
    }

    func testCurrentlyLoadedModelRanksAfterOtherCleanupCandidates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let loaded = makeLocalModel(name: "Loaded Huge", sizeGB: 10, lastUsedDate: nil)
        let unloaded = makeLocalModel(name: "Unloaded Medium", sizeGB: 4, lastUsedDate: nil)

        let candidates = ModelStorageCleanupAdvisor.candidates(
            visibleModels: [unloaded],
            hiddenModels: [loaded],
            loadedModelPath: loaded.url.path,
            now: now
        )

        XCTAssertEqual(candidates.map(\.name), ["Unloaded Medium", "Loaded Huge"])
        XCTAssertFalse(candidates[0].isLoaded)
        XCTAssertTrue(candidates[1].isLoaded)
    }

    func testExportIncludesReclaimableBytesAndLastUsedDays() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = makeLocalModel(
            name: "Exportable",
            sizeGB: 4,
            lastUsedDate: now.addingTimeInterval(-45 * 24 * 60 * 60)
        )

        let candidate = try XCTUnwrap(
            ModelStorageCleanupAdvisor.candidates(
                visibleModels: [model],
                hiddenModels: [],
                loadedModelPath: nil,
                now: now
            ).first
        )

        XCTAssertEqual(candidate.exportDictionary["reclaimableBytes"] as? Int64, 4 * 1_073_741_824)
        XCTAssertEqual(candidate.exportDictionary["lastUsedDays"] as? Int, 45)
    }

    private func makeLocalModel(
        name: String,
        sizeGB: Double,
        lastUsedDate: Date?,
        quant: String = "Q4_K_M"
    ) -> LocalModel {
        LocalModel(
            modelID: "cleanup-tests/\(name.replacingOccurrences(of: " ", with: "-"))",
            name: name,
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("cleanup-tests")
                .appendingPathComponent("\(name).gguf"),
            quant: quant,
            architecture: "",
            architectureFamily: "",
            format: .gguf,
            sizeGB: sizeGB,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedDate: lastUsedDate,
            totalLayers: 0
        )
    }
}
