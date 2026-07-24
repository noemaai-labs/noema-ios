import Foundation
import XCTest
@testable import Noema

final class OverfitBenchmarkMetricsTests: XCTestCase {

    private func makeResult(paged: PagedBenchmarkMetrics?) -> ModelBenchmarkResult {
        var settings = ModelSettings()
        settings.contextLength = 4096
        settings.cpuThreads = 4
        return ModelBenchmarkResult(
            id: UUID(uuidString: "1B9E38A0-11D2-4C4B-8E7A-52D8B14BD001")!,
            format: .gguf,
            settings: settings,
            kvCacheOffloadActive: true,
            promptTokens: 32,
            promptRate: 210.0,
            generationTokens: 128,
            generationRate: 17.25,
            totalDuration: 9.5,
            timeToFirstToken: 0.6,
            peakMemoryBytes: 3_600_000_000,
            memoryDeltaBytes: 400_000_000,
            outputPreview: "preview",
            completedAt: Date(timeIntervalSince1970: 1_780_000_000),
            speculativeTimings: nil,
            paged: paged
        )
    }

    private func makePagedMetrics() -> PagedBenchmarkMetrics {
        PagedBenchmarkMetrics(
            bytesRead: 123_456_789,
            bankHits: 4096,
            bankMisses: 12,
            missesPerToken: 0.09375,
            stallMsTotal: 84.5,
            latency: OverfitLatencySample(
                p50Ms: 55, p95Ms: 140, p99Ms: 900, stallsPer128Tokens: 1, tokenCount: 127
            ),
            thermalStateRaw: 1,
            pressureInterventions: 2
        )
    }

    // MARK: - Codable compatibility

    func testResultWithPagedMetricsRoundTrips() throws {
        let result = makeResult(paged: makePagedMetrics())
        let decoded = try JSONDecoder().decode(
            ModelBenchmarkResult.self,
            from: try JSONEncoder().encode(result)
        )
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.paged?.bankMisses, 12)
        XCTAssertEqual(decoded.paged?.latency?.p99Ms, 900)
    }

    func testNilPagedMetricsIsOmittedFromEncoding() throws {
        let data = try JSONEncoder().encode(makeResult(paged: nil))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Synthesized Codable must keep omitting the key so records written by
        // this build stay byte-compatible with the legacy shape below.
        XCTAssertFalse(json.contains("\"paged\""))
    }

    /// A record persisted before `paged` existed has no such key at all;
    /// decoding must succeed with `paged == nil` rather than throwing.
    func testLegacyRecordWithoutPagedFieldDecodes() throws {
        let legacyData = try JSONEncoder().encode(makeResult(paged: nil))
        XCTAssertFalse(try XCTUnwrap(String(data: legacyData, encoding: .utf8)).contains("\"paged\""))

        let decoded = try JSONDecoder().decode(ModelBenchmarkResult.self, from: legacyData)
        XCTAssertNil(decoded.paged)
        XCTAssertEqual(decoded.generationRate, 17.25)
    }

    func testStoreExportImportRoundTripsPagedMetrics() throws {
        let stored = ModelBenchmarkResultStore.StoredResult(
            modelID: "owner/model",
            modelName: "Model",
            modelPath: "/models/model.noema-paged/resident.gguf",
            quant: "F16",
            sizeGB: 1.5,
            result: makeResult(paged: makePagedMetrics())
        )
        let legacy = ModelBenchmarkResultStore.StoredResult(
            modelID: "owner/legacy",
            modelName: "Legacy",
            modelPath: "/models/legacy.gguf",
            quant: "Q4_K_M",
            sizeGB: 4.0,
            result: makeResult(paged: nil)
        )
        let records = [stored.modelPath: stored, legacy.modelPath: legacy]

        let data = try ModelBenchmarkResultStore.exportData(
            records: records,
            exportedAt: Date(timeIntervalSince1970: 1_780_000_100)
        )
        let imported = try ModelBenchmarkResultStore.importedRecords(from: data)

        XCTAssertEqual(imported, records)
        XCTAssertEqual(imported[stored.modelPath]?.result.paged, makePagedMetrics())
        XCTAssertNil(imported[legacy.modelPath]?.result.paged)
    }

    // MARK: - Stats JSON parsing

    func testParsesStageOneShapedStatsJSON() throws {
        // Stage 1 resident-bank telemetry: no hit/miss/IO counters yet.
        let json = """
        {"mode":1,"active":true,"architecture":"qwen3moe","nExpert":8,"nExpertUsed":2,
         "moeLayerCount":2,"routeCalls":24,"idsSeen":96,"oobIds":0,
         "preload":{"records":48,"bytes":786432,"ms":12},
         "checksumFailures":0,"traceDroppedIds":0,"poisoned":false,"pressureLevel":0}
        """
        let metrics = try XCTUnwrap(ModelBenchmarkService.pagedMetrics(
            fromStatsJSON: json,
            interTokenLatenciesMs: [100, 200, 300],
            generationTokens: 64,
            thermalStateRaw: 1
        ))
        XCTAssertEqual(metrics.bytesRead, 786_432)
        XCTAssertEqual(metrics.bankHits, 0)
        XCTAssertEqual(metrics.bankMisses, 0)
        XCTAssertEqual(metrics.missesPerToken, 0)
        XCTAssertEqual(metrics.stallMsTotal, 0)
        XCTAssertEqual(metrics.pressureInterventions, 0)
        XCTAssertEqual(metrics.thermalStateRaw, 1)
        XCTAssertEqual(metrics.latency?.p50Ms, 200)
        XCTAssertEqual(metrics.latency?.tokenCount, 3)
    }

    func testParsesStageTwoShapedStatsJSON() throws {
        let json = """
        {"mode":2,"active":true,
         "bank":{"hits":4000,"misses":128},
         "io":{"bytesRead":905969664,"stallMs":220.5},
         "pressureInterventions":3}
        """
        let metrics = try XCTUnwrap(ModelBenchmarkService.pagedMetrics(
            fromStatsJSON: json,
            interTokenLatenciesMs: [],
            generationTokens: 64,
            thermalStateRaw: 0
        ))
        XCTAssertEqual(metrics.bankHits, 4000)
        XCTAssertEqual(metrics.bankMisses, 128)
        XCTAssertEqual(metrics.bytesRead, 905_969_664)
        XCTAssertEqual(metrics.stallMsTotal, 220.5, accuracy: 1e-9)
        XCTAssertEqual(metrics.pressureInterventions, 3)
        XCTAssertEqual(metrics.missesPerToken, 2.0, accuracy: 1e-9)
        XCTAssertNil(metrics.latency)
    }

    func testExplicitMissesPerTokenWinsOverDerivedValue() throws {
        let json = """
        {"mode":2,"bank":{"hits":10,"misses":90},"missesPerToken":0.5}
        """
        let metrics = try XCTUnwrap(ModelBenchmarkService.pagedMetrics(
            fromStatsJSON: json,
            interTokenLatenciesMs: [],
            generationTokens: 9,
            thermalStateRaw: 0
        ))
        XCTAssertEqual(metrics.missesPerToken, 0.5)
    }

    func testOrdinaryDecodePhaseOverridesBootCumulativeStreamTotals() throws {
        let json = """
        {"mode":2,
         "stream":{"hits":6169,"misses":13484,"bytesRead":45123000000,"stallNs":19000000000},
         "phases":{"promptPrefill":{"hits":100,"misses":7000,"bytesRead":23511527424,"stallNs":12000000000},
                   "ordinaryDecode":{"hits":3200,"misses":1600,"bytesRead":5352652800,"stallNs":6400000000}},
         "missesPerToken":999}
        """
        let metrics = try XCTUnwrap(ModelBenchmarkService.pagedMetrics(
            fromStatsJSON: json,
            interTokenLatenciesMs: [],
            generationTokens: 64,
            thermalStateRaw: 0
        ))
        XCTAssertEqual(metrics.bankHits, 3_200)
        XCTAssertEqual(metrics.bankMisses, 1_600)
        XCTAssertEqual(metrics.bytesRead, 5_352_652_800)
        XCTAssertEqual(metrics.stallMsTotal, 6_400, accuracy: 1e-9)
        XCTAssertEqual(metrics.missesPerToken, 25, accuracy: 1e-9)
    }

    func testModeOffOrUnparseableStatsProduceNoMetrics() {
        XCTAssertNil(ModelBenchmarkService.pagedMetrics(
            fromStatsJSON: #"{"mode":0,"preload":{"bytes":1}}"#,
            interTokenLatenciesMs: [],
            generationTokens: 10,
            thermalStateRaw: 0
        ))
        XCTAssertNil(ModelBenchmarkService.pagedMetrics(
            fromStatsJSON: "not json at all",
            interTokenLatenciesMs: [],
            generationTokens: 10,
            thermalStateRaw: 0
        ))
        XCTAssertNil(ModelBenchmarkService.pagedMetrics(
            fromStatsJSON: #"{"active":true}"#,
            interTokenLatenciesMs: [],
            generationTokens: 10,
            thermalStateRaw: 0
        ))
        XCTAssertNil(ModelBenchmarkService.pagedMetrics(
            fromStatsJSON: "[1,2,3]",
            interTokenLatenciesMs: [],
            generationTokens: 10,
            thermalStateRaw: 0
        ))
    }

    func testZeroGenerationTokensDoesNotDivideByZero() throws {
        let json = #"{"mode":1,"bank":{"hits":1,"misses":7}}"#
        let metrics = try XCTUnwrap(ModelBenchmarkService.pagedMetrics(
            fromStatsJSON: json,
            interTokenLatenciesMs: [],
            generationTokens: 0,
            thermalStateRaw: 0
        ))
        XCTAssertEqual(metrics.missesPerToken, 0)
        XCTAssertEqual(metrics.bankMisses, 7)
    }
}
