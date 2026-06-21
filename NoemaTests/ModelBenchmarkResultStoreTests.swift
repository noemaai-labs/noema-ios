import Foundation
import XCTest
@testable import Noema

final class ModelBenchmarkResultStoreTests: XCTestCase {
    func testBenchmarkResultExportSchemaRoundTripsRecords() throws {
        let exportedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let alpha = storedResult(
            modelID: "alpha/model",
            modelName: "Alpha",
            modelPath: "/models/b-alpha.gguf",
            completedAt: Date(timeIntervalSince1970: 1_770_000_100),
            generationRate: 42.5
        )
        let beta = storedResult(
            modelID: "beta/model",
            modelName: "Beta",
            modelPath: "/models/a-beta.gguf",
            completedAt: Date(timeIntervalSince1970: 1_770_000_200),
            generationRate: 18.25
        )
        let records = [
            beta.modelPath: beta,
            alpha.modelPath: alpha
        ]

        let data = try ModelBenchmarkResultStore.exportData(records: records, exportedAt: exportedAt)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let envelope = try JSONDecoder.noemaBenchmarkISO8601.decode(
            ModelBenchmarkResultStore.ExportEnvelope.self,
            from: data
        )
        let imported = try ModelBenchmarkResultStore.importedRecords(from: data)

        XCTAssertTrue(json.contains(#""schema" : "noema.model_benchmark_results""#))
        XCTAssertTrue(json.contains(#""schemaVersion" : 1"#))
        XCTAssertEqual(envelope.exportedAt, exportedAt)
        XCTAssertEqual(envelope.records.map(\.modelID), ["alpha/model", "beta/model"])
        XCTAssertEqual(imported, records)
    }

    func testBenchmarkResultImportRejectsUnsupportedSchemaVersion() throws {
        let envelope = ModelBenchmarkResultStore.ExportEnvelope(
            schema: "noema.model_benchmark_results",
            schemaVersion: 99,
            exportedAt: Date(timeIntervalSince1970: 1_780_000_000),
            records: []
        )
        let data = try JSONEncoder.noemaBenchmarkISO8601.encode(envelope)

        XCTAssertThrowsError(try ModelBenchmarkResultStore.importedRecords(from: data)) { error in
            guard case ModelBenchmarkResultStore.ExportError.unsupportedSchema(let schema, let version) = error else {
                XCTFail("Expected unsupportedSchema, got \(error)")
                return
            }
            XCTAssertEqual(schema, "noema.model_benchmark_results")
            XCTAssertEqual(version, 99)
        }
    }

    private func storedResult(
        modelID: String,
        modelName: String,
        modelPath: String,
        completedAt: Date,
        generationRate: Double
    ) -> ModelBenchmarkResultStore.StoredResult {
        var settings = ModelSettings()
        settings.contextLength = 8192
        settings.cpuThreads = 6
        settings.temperature = 0.2

        let result = ModelBenchmarkResult(
            id: UUID(uuidString: "8F0E0572-6F86-4C5A-B31E-BA2F27C5C1A0")!,
            format: .gguf,
            settings: settings,
            kvCacheOffloadActive: true,
            promptTokens: 64,
            promptRate: 120.5,
            generationTokens: 128,
            generationRate: generationRate,
            totalDuration: 5.25,
            timeToFirstToken: 0.45,
            peakMemoryBytes: 4_200_000_000,
            memoryDeltaBytes: 512_000_000,
            outputPreview: "Benchmark preview",
            completedAt: completedAt,
            speculativeTimings: LoopbackSpeculativeTimings(
                cacheN: 8,
                promptN: 64,
                promptMS: 250.0,
                promptPerSecond: 256.0,
                predictedN: 128,
                predictedMS: 3_000.0,
                predictedPerSecond: generationRate,
                draftN: 40,
                draftNAccepted: 20
            )
        )

        return ModelBenchmarkResultStore.StoredResult(
            modelID: modelID,
            modelName: modelName,
            modelPath: modelPath,
            quant: "Q4_K_M",
            sizeGB: 4.5,
            result: result
        )
    }
}

private extension JSONEncoder {
    static var noemaBenchmarkISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var noemaBenchmarkISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
