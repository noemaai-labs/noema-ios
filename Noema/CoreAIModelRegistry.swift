import Foundation

// MARK: - Catalog model

/// One model entry snapshotted from `apple/coreai-models` (`model_registry.py`).
/// These are *export recipes*, not downloadable artifacts: running a model
/// requires a side-loaded `.aimodel` produced with Apple's Core AI tooling.
struct CoreAICatalogEntry: Codable, Hashable, Sendable {
    struct Variant: Codable, Hashable, Sendable {
        let platform: String
        let compression: String
        let computePrecision: String?
        let maxContextLength: Int?
    }

    let shortName: String
    let hfId: String
    let family: String
    let type: String          // "llm" | "diffusion" | "utility"
    let task: String?
    let platforms: [String]
    let variants: [Variant]
    let notes: String?

    /// Catalog ids are namespaced so they never collide with Hugging Face repo ids.
    var modelID: String { "coreai/\(shortName)" }

    /// Only language models can be loaded as chat models in Noema today.
    var isChatModel: Bool { type == "llm" }

    /// Publisher inferred from the Hugging Face org component (e.g. "Qwen/..." -> "Qwen").
    var publisher: String {
        if let slash = hfId.firstIndex(of: "/") {
            return String(hfId[..<slash])
        }
        return family.capitalized
    }

    /// Best-effort parameter-count label parsed from the short name (e.g. "qwen3-0.6b" -> "0.6B").
    var parameterCountLabel: String? {
        let lowered = shortName.lowercased()
        // Matches tokens like 0.6b, 1.5b, 4b, 8x7b, 30b-a3b, 20b.
        if let range = lowered.range(of: #"(\d+x)?\d+(\.\d+)?b"#, options: .regularExpression) {
            return String(lowered[range]).uppercased()
        }
        return nil
    }

    var maxContextLength: Int? {
        // Prefer the iOS variant's context (on-device target), else the largest available.
        if let ios = variants.first(where: { $0.platform.lowercased() == "ios" })?.maxContextLength {
            return ios
        }
        return variants.compactMap { $0.maxContextLength }.max()
    }
}

struct CoreAIModelCatalog: Codable, Sendable {
    let version: Int
    let source: String
    let note: String?
    let models: [CoreAICatalogEntry]

    /// Loads and caches the bundled catalog snapshot.
    static let shared: CoreAIModelCatalog = load()

    private static func load() -> CoreAIModelCatalog {
        let empty = CoreAIModelCatalog(version: 0, source: "", note: nil, models: [])
        guard let url = Bundle.main.url(forResource: "CoreAIModelCatalog", withExtension: "json") else {
            return empty
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CoreAIModelCatalog.self, from: data)
        } catch {
            return empty
        }
    }

    func entry(forModelID id: String) -> CoreAICatalogEntry? {
        models.first { $0.modelID == id }
    }
}

// MARK: - Registry

/// Read-only Explore registry that surfaces the `apple/coreai-models` catalog.
/// Models are browse-only here: running one requires a side-loaded `.aimodel`
/// (see `CoreAIModelResolver` / `CoreAIBackend`).
final class CoreAIModelRegistry: ModelRegistry, @unchecked Sendable {
    static let sideLoadNotice = String(
        localized: "Core AI models aren't downloadable from this catalog. Export a .aimodel with Apple's Core AI tooling (macOS, Xcode 27+), then side-load it with Import."
    )

    private let catalog: CoreAIModelCatalog

    init(catalog: CoreAIModelCatalog = .shared) {
        self.catalog = catalog
    }

    func curated() async throws -> [ModelRecord] {
        // CoreAI models require OS 27+; surface nothing on older versions.
        guard ModelFormat.isCoreAIRuntimeAvailable else { return [] }
        return catalog.models.map(Self.record(from:))
    }

    func searchStream(
        query: String,
        page: Int,
        format: ModelFormat?,
        includeVisionModels: Bool,
        visionOnly: Bool
    ) -> AsyncThrowingStream<ModelRecord, Error> {
        AsyncThrowingStream { continuation in
            // CoreAI models require OS 27+; yield nothing on older versions.
            guard ModelFormat.isCoreAIRuntimeAvailable else {
                continuation.finish()
                return
            }
            if let format, format != .coreai {
                continuation.finish()
                return
            }
            // The CoreAI catalog has no vision *chat* models; honor a strict vision-only filter.
            guard !visionOnly else {
                continuation.finish()
                return
            }
            if page > 0 {
                continuation.finish()
                return
            }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for entry in catalog.models {
                if needle.isEmpty || Self.matches(query: needle, entry: entry) {
                    continuation.yield(Self.record(from: entry))
                }
            }
            continuation.finish()
        }
    }

    func details(for id: String) async throws -> ModelDetails {
        guard let entry = catalog.entry(forModelID: id) else {
            throw URLError(.badURL)
        }
        return Self.details(from: entry)
    }

    // MARK: - Mapping

    private static func matches(query: String, entry: CoreAICatalogEntry) -> Bool {
        if entry.shortName.lowercased().contains(query) { return true }
        if entry.hfId.lowercased().contains(query) { return true }
        if entry.family.lowercased().contains(query) { return true }
        if let task = entry.task?.lowercased(), task.contains(query) { return true }
        if entry.publisher.lowercased().contains(query) { return true }
        return false
    }

    private static func record(from entry: CoreAICatalogEntry) -> ModelRecord {
        var tags: [String] = [entry.family, entry.type]
        if let task = entry.task { tags.append(task) }
        tags.append(contentsOf: entry.platforms.map { "platform:\($0)" })

        return ModelRecord(
            id: entry.modelID,
            displayName: entry.shortName,
            publisher: entry.publisher,
            summary: summary(for: entry),
            parameterCountLabel: entry.parameterCountLabel,
            hasInstallableQuant: true,
            formats: [.coreai],
            installed: false,
            tags: tags,
            pipeline_tag: entry.type == "llm" ? "text-generation" : (entry.task ?? entry.type),
            minRAMBytes: nil,
            recommendedETBackend: nil,
            supportsVision: false
        )
    }

    private static func summary(for entry: CoreAICatalogEntry) -> String {
        var parts: [String] = []
        parts.append("Core AI export recipe • \(entry.family)")
        if let task = entry.task { parts.append(task) }
        parts.append("source: \(entry.hfId)")
        if let ctx = entry.maxContextLength {
            parts.append("ctx \(ctx)")
        }
        parts.append(entry.platforms.joined(separator: "/"))
        return parts.joined(separator: " • ")
    }

    private static func details(from entry: CoreAICatalogEntry) -> ModelDetails {
        // A single sentinel "quant" per platform variant. The download URL is a
        // non-fetchable sentinel; the Explore download path intercepts `.coreai`
        // and shows side-load guidance instead.
        let quants: [QuantInfo]
        if entry.variants.isEmpty {
            quants = [
                QuantInfo(
                    label: "Side-load (.aimodel)",
                    format: .coreai,
                    sizeBytes: 0,
                    downloadURL: URL(string: "coreai://catalog/\(entry.shortName)")!,
                    sha256: nil,
                    configURL: nil
                )
            ]
        } else {
            quants = entry.variants.map { variant in
                let ctx = variant.maxContextLength.map { " • ctx \($0)" } ?? ""
                return QuantInfo(
                    label: "\(variant.platform) • \(variant.compression)\(ctx)",
                    format: .coreai,
                    sizeBytes: 0,
                    downloadURL: URL(string: "coreai://catalog/\(entry.shortName)/\(variant.platform)")!,
                    sha256: nil,
                    configURL: nil
                )
            }
        }

        var summaryLines = [summary(from: entry)]
        summaryLines.append(sideLoadNotice)

        return ModelDetails(
            id: entry.modelID,
            summary: summaryLines.joined(separator: "\n\n"),
            parameterCountLabel: entry.parameterCountLabel,
            quants: quants,
            promptTemplate: nil,
            minRAMBytes: nil
        )
    }

    private static func summary(from entry: CoreAICatalogEntry) -> String {
        var lines = ["Hugging Face source: \(entry.hfId)", "Family: \(entry.family)", "Type: \(entry.type)"]
        if let task = entry.task { lines.append("Task: \(task)") }
        lines.append("Platforms: \(entry.platforms.joined(separator: ", "))")
        for variant in entry.variants {
            let ctx = variant.maxContextLength.map { ", ctx \($0)" } ?? ""
            let precision = variant.computePrecision.map { ", \($0)" } ?? ""
            lines.append("• \(variant.platform): \(variant.compression)\(precision)\(ctx)")
        }
        if let notes = entry.notes { lines.append(notes) }
        return lines.joined(separator: "\n")
    }
}
