import Foundation

enum ModelBenchmarkResultStore {
    private static let key = "modelBenchmarkResults.v1"
    private static let exportSchema = "noema.model_benchmark_results"
    private static let exportSchemaVersion = 1

    struct StoredResult: Identifiable, Codable, Equatable {
        let modelID: String
        let modelName: String
        let modelPath: String
        let quant: String
        let sizeGB: Double
        let result: ModelBenchmarkResult

        var id: String { modelPath }
    }

    struct ExportEnvelope: Codable, Equatable {
        let schema: String
        let schemaVersion: Int
        let exportedAt: Date
        let records: [StoredResult]
    }

    enum ExportError: LocalizedError {
        case unsupportedSchema(schema: String, version: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let schema, let version):
                return "Unsupported benchmark export schema \(schema) v\(version)."
            }
        }
    }

    static func save(result: ModelBenchmarkResult, for model: LocalModel) {
        var all = loadAll()
        let record = StoredResult(
            modelID: model.modelID,
            modelName: model.name,
            modelPath: model.url.path,
            quant: model.quant,
            sizeGB: model.sizeGB,
            result: result
        )
        all[model.url.path] = record
        persist(all)
    }

    static func result(for model: LocalModel) -> StoredResult? {
        loadAll()[model.url.path]
    }

    static func loadAll() -> [String: StoredResult] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredResult].self, from: data)) ?? [:]
    }

    static func makeExportEnvelope(
        records: [String: StoredResult] = loadAll(),
        exportedAt: Date = Date()
    ) -> ExportEnvelope {
        ExportEnvelope(
            schema: exportSchema,
            schemaVersion: exportSchemaVersion,
            exportedAt: exportedAt,
            records: records.values.sorted { lhs, rhs in
                if lhs.modelID != rhs.modelID {
                    return lhs.modelID < rhs.modelID
                }
                return lhs.modelPath < rhs.modelPath
            }
        )
    }

    static func exportData(
        records: [String: StoredResult] = loadAll(),
        exportedAt: Date = Date()
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(makeExportEnvelope(records: records, exportedAt: exportedAt))
    }

    static func importedRecords(from data: Data) throws -> [String: StoredResult] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ExportEnvelope.self, from: data)
        guard envelope.schema == exportSchema, envelope.schemaVersion == exportSchemaVersion else {
            throw ExportError.unsupportedSchema(schema: envelope.schema, version: envelope.schemaVersion)
        }
        return Dictionary(envelope.records.map { ($0.modelPath, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    static func importData(_ data: Data, merge: Bool = true) throws {
        let imported = try importedRecords(from: data)
        if merge {
            persist(loadAll().merging(imported) { _, imported in imported })
        } else {
            persist(imported)
        }
    }

    private static func persist(_ records: [String: StoredResult]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
