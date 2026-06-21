// NoemaAppIntentEntities.swift
//
// App Intents nouns: installed models, downloaded datasets, app pages and
// other enums Siri can reason about. Entities are also indexed in Spotlight
// (IndexedEntity) so the new Siri AI and system search can find them by name.

import AppIntents
import Foundation
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

// MARK: - Installed model entity

struct NoemaModelEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Installed Model",
        numericFormat: "\(placeholder: .int) installed models"
    )
    static let defaultQuery = NoemaModelEntityQuery()

    /// Stable identifier: the model file path (same as `LocalModel.id`).
    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Format")
    var format: String

    @Property(title: "Quantization")
    var quant: String

    @Property(title: "Size (GB)")
    var sizeGB: Double

    @Property(title: "Multimodal")
    var isMultimodal: Bool

    @Property(title: "Tool Capable")
    var isToolCapable: Bool

    var displayRepresentation: DisplayRepresentation {
        let subtitleParts = [format, quant.isEmpty ? nil : quant, String(format: "%.1f GB", sizeGB)]
            .compactMap { $0 }
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitleParts.joined(separator: " · "))",
            image: .init(systemName: "cpu")
        )
    }

    init(model: LocalModel) {
        self.id = model.id
        self.name = model.displayName
        self.format = model.format.rawValue.uppercased()
        self.quant = model.quant
        self.sizeGB = model.sizeGB
        self.isMultimodal = model.isMultimodal
        self.isToolCapable = model.isToolCapable
    }
}

extension NoemaModelEntity: IndexedEntity {
#if canImport(CoreSpotlight)
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.contentDescription = "\(format) model · \(quant) · " + String(format: "%.1f GB", sizeGB)
        attributes.keywords = ["model", "LLM", "AI", format, quant, name].filter { !$0.isEmpty }
        return attributes
    }
#endif
}

struct NoemaModelEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    private func allModels() -> [LocalModel] {
        AppIntentDriver.shared.installedModels().filter(\.isDownloaded)
    }

    @MainActor
    func entities(for identifiers: [NoemaModelEntity.ID]) async throws -> [NoemaModelEntity] {
        let models = allModels()
        return identifiers.compactMap { id in
            models.first(where: { $0.id == id }).map(NoemaModelEntity.init)
        }
    }

    @MainActor
    func allEntities() async throws -> [NoemaModelEntity] {
        allModels().map(NoemaModelEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [NoemaModelEntity] {
        let models = allModels()
        let ranked = models.sorted { a, b in
            if a.isFavourite != b.isFavourite { return a.isFavourite }
            return (a.lastUsedDate ?? .distantPast) > (b.lastUsedDate ?? .distantPast)
        }
        return ranked.prefix(8).map(NoemaModelEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [NoemaModelEntity] {
        let needle = string.lowercased()
        return allModels().filter { model in
            model.displayName.lowercased().contains(needle)
                || model.name.lowercased().contains(needle)
                || model.modelID.lowercased().contains(needle)
                || model.quant.lowercased().contains(needle)
                || model.format.rawValue.lowercased().contains(needle)
        }.map(NoemaModelEntity.init)
    }
}

// MARK: - Dataset entity

struct NoemaDatasetEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Dataset",
        numericFormat: "\(placeholder: .int) datasets"
    )
    static let defaultQuery = NoemaDatasetEntityQuery()

    /// Stable identifier: `LocalDataset.datasetID` ("owner/name").
    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Source")
    var source: String

    @Property(title: "Ready for Chat")
    var isIndexed: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(source)\(isIndexed ? "" : " · needs indexing")",
            image: .init(systemName: "books.vertical")
        )
    }

    init(dataset: LocalDataset) {
        self.id = dataset.datasetID
        self.name = dataset.name
        self.source = dataset.source
        self.isIndexed = dataset.isIndexed
    }
}

extension NoemaDatasetEntity: IndexedEntity {
#if canImport(CoreSpotlight)
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.contentDescription = "Dataset · \(source)"
        attributes.keywords = ["dataset", "RAG", "documents", source, name]
        return attributes
    }
#endif
}

struct NoemaDatasetEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    private func allDatasets() -> [LocalDataset] {
        AppIntentDriver.shared.downloadedDatasets()
    }

    @MainActor
    func entities(for identifiers: [NoemaDatasetEntity.ID]) async throws -> [NoemaDatasetEntity] {
        let datasets = allDatasets()
        return identifiers.compactMap { id in
            datasets.first(where: { $0.datasetID == id }).map(NoemaDatasetEntity.init)
        }
    }

    @MainActor
    func allEntities() async throws -> [NoemaDatasetEntity] {
        allDatasets().map(NoemaDatasetEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [NoemaDatasetEntity] {
        let datasets = allDatasets().sorted {
            ($0.lastUsedDate ?? $0.downloadDate) > ($1.lastUsedDate ?? $1.downloadDate)
        }
        return datasets.prefix(8).map(NoemaDatasetEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [NoemaDatasetEntity] {
        let needle = string.lowercased()
        return allDatasets().filter {
            $0.name.lowercased().contains(needle) || $0.datasetID.lowercased().contains(needle)
        }.map(NoemaDatasetEntity.init)
    }
}

// MARK: - Enums

enum NoemaAppPage: String, AppEnum {
    case chat
    case stored
    case exploreModels
    case exploreDatasets
    case settings
    case downloads

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Noema Page")
    static let caseDisplayRepresentations: [NoemaAppPage: DisplayRepresentation] = [
        .chat: DisplayRepresentation(title: "Chat", image: .init(systemName: "message")),
        .stored: DisplayRepresentation(title: "Stored", subtitle: "Your models and datasets", image: .init(systemName: "externaldrive")),
        .exploreModels: DisplayRepresentation(title: "Explore Models", image: .init(systemName: "safari")),
        .exploreDatasets: DisplayRepresentation(title: "Explore Datasets", image: .init(systemName: "books.vertical")),
        .settings: DisplayRepresentation(title: "Settings", image: .init(systemName: "gearshape")),
        .downloads: DisplayRepresentation(title: "Downloads", image: .init(systemName: "arrow.down.circle"))
    ]
}

enum NoemaExploreScope: String, AppEnum {
    case models
    case datasets

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Explore Section")
    static let caseDisplayRepresentations: [NoemaExploreScope: DisplayRepresentation] = [
        .models: DisplayRepresentation(title: "Models"),
        .datasets: DisplayRepresentation(title: "Datasets")
    ]
}

enum NoemaOffGridMode: String, AppEnum {
    case on
    case off
    case toggle

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Off-Grid Mode")
    static let caseDisplayRepresentations: [NoemaOffGridMode: DisplayRepresentation] = [
        .on: DisplayRepresentation(title: "On"),
        .off: DisplayRepresentation(title: "Off"),
        .toggle: DisplayRepresentation(title: "Toggle")
    ]
}

// MARK: - Spotlight donation

/// Donates the model/dataset catalogs to Spotlight so Siri and system search
/// can resolve them by name, and refreshes App Shortcuts parameter values.
enum NoemaEntityIndexer {
    @MainActor private static var donationTask: Task<Void, Never>?

    @MainActor
    static func scheduleDonation() {
        donationTask?.cancel()
        donationTask = Task { @MainActor in
            // Small debounce: bind + load can both request a donation.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await donateNow()
        }
    }

    @MainActor
    static func donateNow() async {
        NoemaShortcuts.updateAppShortcutParameters()
#if canImport(CoreSpotlight) && !os(tvOS) && !os(watchOS)
        let models = AppIntentDriver.shared.installedModels()
            .filter(\.isDownloaded)
            .map(NoemaModelEntity.init)
        let datasets = AppIntentDriver.shared.downloadedDatasets()
            .map(NoemaDatasetEntity.init)
        do {
            if !models.isEmpty {
                try await CSSearchableIndex.default().indexAppEntities(models)
            }
            if !datasets.isEmpty {
                try await CSSearchableIndex.default().indexAppEntities(datasets)
            }
        } catch {
            // Spotlight indexing is best-effort; Siri still resolves entities
            // through the live queries.
        }
#endif
    }
}
