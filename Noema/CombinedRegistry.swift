// CombinedRegistry.swift
import Foundation

/// Combines results from multiple registries for curated models.
/// Search and details fall back to the primary registry when others fail.
final class CombinedRegistry: ModelRegistry, @unchecked Sendable {
    private let primary: ModelRegistry
    private let extras: [ModelRegistry]
    private let afmRegistry = AppleFoundationModelRegistry()
    private let coreaiRegistry = CoreAIModelRegistry()

    init(primary: ModelRegistry, extras: [ModelRegistry]) {
        self.primary = primary
        self.extras = extras
    }

    func curated() async throws -> [ModelRecord] {

        var results: [ModelRecord] = []

        for reg in extras {
            do {
                results += try await reg.curated().filter { $0.id != AppleFoundationModelRegistry.modelID }
            } catch {}
        }
        // CoreAI is not browsable from Explore; its catalog entries are intentionally
        // not surfaced here. CoreAI models are side-loaded via Import instead.
        return results
    }


    func searchStream(query: String, page: Int, format: ModelFormat?, includeVisionModels: Bool, visionOnly: Bool) -> AsyncThrowingStream<ModelRecord, Error> {
        if format == .afm {
            return afmRegistry.searchStream(
                query: query,
                page: page,
                format: format,
                includeVisionModels: includeVisionModels,
                visionOnly: visionOnly
            )
        }
        // CoreAI searches go to Hugging Face restricted to repos tagged
        // "coreai" / "aimodel" (handled by the primary registry). The local
        // catalog registry remains only for previously cached `coreai/` ids.
        return primary.searchStream(query: query, page: page, format: format, includeVisionModels: includeVisionModels, visionOnly: visionOnly)
    }

    func details(for id: String) async throws -> ModelDetails {
        if id.hasPrefix("coreai/") {
            return try await coreaiRegistry.details(for: id)
        }
        for reg in extras {
            if let d = try? await reg.details(for: id) { return d }
        }
        return try await primary.details(for: id)
    }
}
