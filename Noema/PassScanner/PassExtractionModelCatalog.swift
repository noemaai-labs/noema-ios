import Foundation
import NoemaPackages

enum PassExtractionModelCatalog {
    static let activeModelPathKey = "walletPassActiveExtractionModelPath"
    static let activeModelIDKey = "walletPassActiveExtractionModelID"
    static let activeModelQuantKey = "walletPassActiveExtractionModelQuant"
    static let activeModelFormatKey = "walletPassActiveExtractionModelFormat"
    static let activeModelNameKey = "walletPassActiveExtractionModelName"
    static let extractionThinkingEnabledKey = "walletPassExtractionThinkingEnabled"

    static func activeModel(from models: [LocalModel]) -> LocalModel? {
        let path = activeModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, let exactPathMatch = models.first(where: { $0.url.path == path }) {
            return exactPathMatch
        }

        let modelID = activeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let quant = activeModelQuant.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = activeModelFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return nil }

        return models.first { model in
            model.modelID == modelID
                && (quant.isEmpty || model.quant == quant)
                && (format.isEmpty || model.format.rawValue == format)
        }
    }

    static var activeModelPath: String {
        get {
            UserDefaults.standard.string(forKey: activeModelPathKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: activeModelPathKey)
            UserDefaults.standard.synchronize()
        }
    }

    static var activeModelID: String {
        UserDefaults.standard.string(forKey: activeModelIDKey) ?? ""
    }

    static var activeModelQuant: String {
        UserDefaults.standard.string(forKey: activeModelQuantKey) ?? ""
    }

    static var activeModelFormat: String {
        UserDefaults.standard.string(forKey: activeModelFormatKey) ?? ""
    }

    static var activeModelName: String {
        UserDefaults.standard.string(forKey: activeModelNameKey) ?? ""
    }

    static var extractionThinkingEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: extractionThinkingEnabledKey) != nil else { return false }
            return UserDefaults.standard.bool(forKey: extractionThinkingEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: extractionThinkingEnabledKey)
            UserDefaults.standard.synchronize()
        }
    }

    static func setActiveModel(_ model: LocalModel) {
        let defaults = UserDefaults.standard
        defaults.set(model.url.path, forKey: activeModelPathKey)
        defaults.set(model.modelID, forKey: activeModelIDKey)
        defaults.set(model.quant, forKey: activeModelQuantKey)
        defaults.set(model.format.rawValue, forKey: activeModelFormatKey)
        defaults.set(model.name, forKey: activeModelNameKey)
        defaults.synchronize()
    }

    static func isSelectedModelMissing(in models: [LocalModel]) -> Bool {
        let hasSelection = !activeModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !activeModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSelection else { return false }
        return activeModel(from: models) == nil
    }

    static func supportsExtractionThinking(_ model: LocalModel) -> Bool {
        TemplateDrivenModelSupport.isQwen35(modelID: model.modelID, modelURL: model.url)
            || model.isReasoningModel
    }

    static func compatibleModels(from models: [LocalModel]) -> [LocalModel] {
        models
            .filter(isCompatibleVisionModel)
            .sorted { lhs, rhs in
                if lhs.isFavourite != rhs.isFavourite {
                    return lhs.isFavourite && !rhs.isFavourite
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func isCompatibleVisionModel(_ model: LocalModel) -> Bool {
        guard model.isDownloaded else { return false }
        switch model.format {
        case .gguf:
            return model.isMultimodal
                || ProjectorLocator.hasProjectorFile(alongside: model.url)
                || GGUFMetadata.hasMultimodalProjector(at: model.url)
                || ModelVisionDetector.guessLlamaVisionModel(from: model.url)
        case .mlx:
            return model.isMultimodal || MLXBridge.isVLMModel(at: model.url)
        case .et:
            return model.isMultimodal
                || LeapCatalogService.isVisionQuantizationSlug(model.modelID)
                || LeapCatalogService.bundleLikelyVision(at: model.url)
        case .ane, .afm, .coreai:
            return false
        }
    }

    static let recommendedModelIDs: [String] = [
        "unsloth/Qwen3.5-2B-GGUF",
        "unsloth/gemma-3-4b-it-GGUF",
        "unsloth/gemma-4-E2B-it-GGUF"
    ]
}
