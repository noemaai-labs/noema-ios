import SwiftUI

struct ModelBenchmarkRecommendationSummaryContent: View {
    @ObservedObject var modelManager: AppModelManager
    let openRecommendations: () -> Void

    private var snapshot: ModelBenchmarkRecommendationSnapshot {
        ModelBenchmarkRecommendationSnapshot(models: modelManager.downloadedModels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "speedometer")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(snapshot.hasBenchmarkData ? Color.green : Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Model Recommendations"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openRecommendations) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Model Recommendations"))
            }

            HStack(spacing: 8) {
                BenchmarkRecommendationCapsule(title: LocalizedStringKey("Benchmarked"), value: "\(snapshot.benchmarkedCount)")
                BenchmarkRecommendationCapsule(title: LocalizedStringKey("Fastest"), value: snapshot.fastestModelName)
                BenchmarkRecommendationCapsule(title: LocalizedStringKey("Efficient"), value: snapshot.efficientModelName)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openRecommendations)
    }

    private var summaryLine: String {
        if let best = snapshot.bestOverall {
            return String.localizedStringWithFormat(
                String(localized: "%@ is currently the best measured fit."),
                best.model.name
            )
        }
        if modelManager.downloadedModels.isEmpty {
            return String(localized: "Install models to rank them on this device.")
        }
        return String(localized: "Run benchmarks from model settings to unlock measured rankings.")
    }
}

struct ModelBenchmarkRecommendationsView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var refreshedAt = Date()
    @State private var exportURL: URL?
    @State private var exportError: String?

    private var snapshot: ModelBenchmarkRecommendationSnapshot {
        ModelBenchmarkRecommendationSnapshot(models: modelManager.downloadedModels)
    }

    var body: some View {
        Form {
            if modelManager.downloadedModels.isEmpty {
                Section(LocalizedStringKey("Model Recommendations")) {
                    Label(LocalizedStringKey("No local models installed"), systemImage: "tray")
                    Text(LocalizedStringKey("Install local models and run benchmarks to see recommendations ranked for this device."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                overviewSection
                recommendationSection
                leaderboardSection
                benchmarkedSection
                unmeasuredSection
                exportSection
            }
        }
        .navigationTitle(LocalizedStringKey("Model Recommendations"))
    }

    private var overviewSection: some View {
        Section(LocalizedStringKey("Recommendation Overview")) {
            BenchmarkRecommendationValueRow(title: LocalizedStringKey("Installed Models"), value: "\(snapshot.installedCount)")
            BenchmarkRecommendationValueRow(title: LocalizedStringKey("Benchmarked Models"), value: "\(snapshot.benchmarkedCount)")
            BenchmarkRecommendationValueRow(title: LocalizedStringKey("Fastest Model"), value: snapshot.fastestModelName)
            BenchmarkRecommendationValueRow(title: LocalizedStringKey("Most Efficient"), value: snapshot.efficientModelName)
            BenchmarkRecommendationValueRow(title: LocalizedStringKey("Last Refreshed"), value: refreshedAt.formatted(date: .omitted, time: .standard))
            Button {
                refreshedAt = Date()
            } label: {
                Label(LocalizedStringKey("Refresh Rankings"), systemImage: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private var recommendationSection: some View {
        Section(LocalizedStringKey("Recommended Models")) {
            if snapshot.rankedModels.isEmpty {
                Label(LocalizedStringKey("No benchmark data yet"), systemImage: "speedometer")
                Text(LocalizedStringKey("Open a model's settings and run Benchmark. Results stay on this device and will rank models here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(snapshot.rankedModels.prefix(5).enumerated()), id: \.element.id) { index, recommendation in
                    BenchmarkRecommendationRow(rank: index + 1, recommendation: recommendation)
                }
            }
        }
    }

    @ViewBuilder
    private var leaderboardSection: some View {
        Section(LocalizedStringKey("Offline Leaderboard")) {
            if snapshot.leaderboardEntries.isEmpty {
                Label(LocalizedStringKey("No measured models yet"), systemImage: "chart.bar")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.leaderboardEntries) { entry in
                    BenchmarkLeaderboardRow(entry: entry)
                }
            }
        }
    }

    @ViewBuilder
    private var benchmarkedSection: some View {
        Section(LocalizedStringKey("Measured Results")) {
            if snapshot.rankedModels.isEmpty {
                BenchmarkRecommendationValueRow(title: LocalizedStringKey("Results"), value: String(localized: "None"))
            } else {
                ForEach(snapshot.rankedModels) { recommendation in
                    BenchmarkMeasuredResultRow(recommendation: recommendation)
                }
            }
        }
    }

    @ViewBuilder
    private var unmeasuredSection: some View {
        Section(LocalizedStringKey("Unmeasured Models")) {
            if snapshot.unmeasuredModels.isEmpty {
                Label(LocalizedStringKey("Every installed model has a benchmark"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(snapshot.unmeasuredModels.prefix(8), id: \.id) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: model.name)
                            .font(.body.weight(.medium))
                        Text(verbatim: "\(model.format.displayName) · \(model.quant) · \(formatSize(model))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var exportSection: some View {
        Section(LocalizedStringKey("Recommendation Export")) {
            Button {
                generateExport()
            } label: {
                Label(LocalizedStringKey("Generate Recommendations JSON"), systemImage: "doc.badge.gearshape")
            }

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label(LocalizedStringKey("Share Recommendations JSON"), systemImage: "square.and.arrow.up")
                }
                BenchmarkRecommendationValueRow(title: LocalizedStringKey("Report File"), value: exportURL.lastPathComponent)
            }

            if let exportError {
                BenchmarkRecommendationValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
            }
        }
    }

    private func generateExport() {
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "installedCount": snapshot.installedCount,
            "benchmarkedCount": snapshot.benchmarkedCount,
            "recommendations": snapshot.rankedModels.map { recommendation in
                [
                    "modelID": recommendation.model.modelID,
                    "name": recommendation.model.name,
                    "format": recommendation.model.format.rawValue,
                    "quant": recommendation.model.quant,
                    "sizeGB": recommendation.model.sizeGB,
                    "score": recommendation.score,
                    "generationTokensPerSecond": recommendation.result.generationRate,
                    "promptTokensPerSecond": recommendation.result.promptRate,
                    "timeToFirstToken": recommendation.result.timeToFirstToken,
                    "peakMemoryBytes": recommendation.result.peakMemoryBytes,
                    "completedAt": ISO8601DateFormatter().string(from: recommendation.result.completedAt),
                    "reason": recommendation.reason
                ] as [String: Any]
            },
            "unmeasured": snapshot.unmeasuredModels.map { model in
                [
                    "modelID": model.modelID,
                    "name": model.name,
                    "format": model.format.rawValue,
                    "quant": model.quant,
                    "sizeGB": model.sizeGB
                ] as [String: Any]
            }
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("noema-model-recommendations-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private func formatSize(_ model: LocalModel) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(model.sizeGB * 1_073_741_824.0), countStyle: .file)
    }
}

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
        return Dictionary(uniqueKeysWithValues: envelope.records.map { ($0.modelPath, $0) })
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

private struct ModelBenchmarkRecommendationSnapshot {
    let models: [LocalModel]
    let records: [String: ModelBenchmarkResultStore.StoredResult]

    init(models: [LocalModel]) {
        self.models = models
        self.records = ModelBenchmarkResultStore.loadAll()
    }

    var installedCount: Int { models.count }

    var benchmarkedCount: Int {
        rankedModels.count
    }

    var hasBenchmarkData: Bool {
        benchmarkedCount > 0
    }

    var rankedModels: [ModelBenchmarkRecommendation] {
        models.compactMap { model in
            guard let stored = records[model.url.path] else { return nil }
            return ModelBenchmarkRecommendation(model: model, stored: stored)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.model.name < rhs.model.name }
            return lhs.score > rhs.score
        }
    }

    var unmeasuredModels: [LocalModel] {
        models
            .filter { records[$0.url.path] == nil }
            .sorted { lhs, rhs in
                if lhs.format == rhs.format { return lhs.name < rhs.name }
                return lhs.format.displayName < rhs.format.displayName
            }
    }

    var bestOverall: ModelBenchmarkRecommendation? {
        rankedModels.first
    }

    var leaderboardEntries: [BenchmarkLeaderboardEntry] {
        let ranked = rankedModels
        guard !ranked.isEmpty else { return [] }

        var entries: [BenchmarkLeaderboardEntry] = []
        if let best = ranked.first {
            entries.append(.init(
                title: LocalizedStringKey("Best Overall"),
                modelName: best.model.name,
                metric: String.localizedStringWithFormat(String(localized: "%.0f score"), best.score * 100),
                icon: "rosette"
            ))
        }
        if let fastest = ranked.max(by: { $0.result.generationRate < $1.result.generationRate }) {
            entries.append(.init(
                title: LocalizedStringKey("Fastest Generation"),
                modelName: fastest.model.name,
                metric: String.localizedStringWithFormat(String(localized: "%.1f tok/s"), fastest.result.generationRate),
                icon: "bolt.fill"
            ))
        }
        if let quickest = ranked.min(by: { $0.result.timeToFirstToken < $1.result.timeToFirstToken }) {
            entries.append(.init(
                title: LocalizedStringKey("Fastest First Token"),
                modelName: quickest.model.name,
                metric: String.localizedStringWithFormat(String(localized: "%.2fs"), quickest.result.timeToFirstToken),
                icon: "timer"
            ))
        }
        if let lowestMemory = ranked.min(by: { $0.result.peakMemoryBytes < $1.result.peakMemoryBytes }) {
            entries.append(.init(
                title: LocalizedStringKey("Lowest Memory"),
                modelName: lowestMemory.model.name,
                metric: ByteCountFormatter.string(fromByteCount: lowestMemory.result.peakMemoryBytes, countStyle: .memory),
                icon: "memorychip"
            ))
        }
        if let bestGGUF = ranked.filter({ $0.model.format == .gguf }).first {
            entries.append(.init(
                title: LocalizedStringKey("Best GGUF"),
                modelName: bestGGUF.model.name,
                metric: String.localizedStringWithFormat(String(localized: "%.0f score"), bestGGUF.score * 100),
                icon: "shippingbox"
            ))
        }
        if let bestToolModel = ranked.filter({ $0.model.isToolCapable }).first {
            entries.append(.init(
                title: LocalizedStringKey("Best Tool Model"),
                modelName: bestToolModel.model.name,
                metric: String.localizedStringWithFormat(String(localized: "%.0f score"), bestToolModel.score * 100),
                icon: "wrench.and.screwdriver"
            ))
        }
        if let bestVisionModel = ranked.filter({ $0.model.isMultimodal }).first {
            entries.append(.init(
                title: LocalizedStringKey("Best Vision Model"),
                modelName: bestVisionModel.model.name,
                metric: String.localizedStringWithFormat(String(localized: "%.0f score"), bestVisionModel.score * 100),
                icon: "eye"
            ))
        }
        return entries
    }

    var fastestModelName: String {
        rankedModels.max { lhs, rhs in lhs.result.generationRate < rhs.result.generationRate }?.model.name
            ?? String(localized: "No data")
    }

    var efficientModelName: String {
        rankedModels.max { lhs, rhs in lhs.efficiencyScore < rhs.efficiencyScore }?.model.name
            ?? String(localized: "No data")
    }
}

private struct ModelBenchmarkRecommendation: Identifiable {
    let model: LocalModel
    let stored: ModelBenchmarkResultStore.StoredResult

    var id: String { model.id }
    var result: ModelBenchmarkResult { stored.result }

    var score: Double {
        let generation = min(max(result.generationRate, 0), 120) / 120
        let prompt = min(max(result.promptRate, 0), 400) / 400
        let latency = 1 / max(1, result.timeToFirstToken)
        let memoryGB = Double(max(result.peakMemoryBytes, 1)) / 1_073_741_824.0
        let memory = 1 / max(1, memoryGB / 6)
        return generation * 0.58 + prompt * 0.16 + latency * 0.14 + memory * 0.12
    }

    var efficiencyScore: Double {
        result.generationRate / max(0.5, Double(max(result.peakMemoryBytes, 1)) / 1_073_741_824.0)
    }

    var reason: String {
        let speed = String.localizedStringWithFormat(String(localized: "%.1f tok/s generation"), result.generationRate)
        let latency = String.localizedStringWithFormat(String(localized: "%.2fs first token"), result.timeToFirstToken)
        let memory = ByteCountFormatter.string(fromByteCount: result.peakMemoryBytes, countStyle: .memory)
        return "\(speed) · \(latency) · \(memory)"
    }

    var roleLabel: String {
        if model.isMultimodal { return String(localized: "Vision") }
        if model.isToolCapable { return String(localized: "Tools") }
        if model.sizeGB <= 3 { return String(localized: "Fast Local") }
        return String(localized: "General")
    }
}

private struct BenchmarkLeaderboardEntry: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let modelName: String
    let metric: String
    let icon: String
}

private struct BenchmarkRecommendationCapsule: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct BenchmarkRecommendationValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct BenchmarkRecommendationRow: View {
    let rank: Int
    let recommendation: ModelBenchmarkRecommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: "#\(rank)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: recommendation.model.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(verbatim: recommendation.roleLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(verbatim: String(format: "%.0f", recommendation.score * 100))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.green)
            }
            Text(verbatim: recommendation.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

private struct BenchmarkLeaderboardRow: View {
    let entry: BenchmarkLeaderboardEntry

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: entry.modelName)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.trailing)
                Text(verbatim: entry.metric)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label(entry.title, systemImage: entry.icon)
                .foregroundStyle(.green)
        }
        .padding(.vertical, 2)
    }
}

private struct BenchmarkMeasuredResultRow: View {
    let recommendation: ModelBenchmarkRecommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: recommendation.model.name)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(verbatim: String.localizedStringWithFormat(String(localized: "%.1f tok/s"), recommendation.result.generationRate))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                smallMetric(LocalizedStringKey("Prompt"), String.localizedStringWithFormat(String(localized: "%.1f"), recommendation.result.promptRate))
                smallMetric(LocalizedStringKey("First"), String.localizedStringWithFormat(String(localized: "%.2fs"), recommendation.result.timeToFirstToken))
                smallMetric(LocalizedStringKey("Memory"), ByteCountFormatter.string(fromByteCount: recommendation.result.peakMemoryBytes, countStyle: .memory))
            }
            Text(recommendation.result.completedAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func smallMetric(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
