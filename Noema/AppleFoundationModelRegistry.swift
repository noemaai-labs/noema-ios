import Foundation

enum AppleFoundationModelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case onDevice
    case privateCloudCompute

    static let privateCloudContextLimit = 32_768

    /// Which AFM variant is currently loaded in chat, persisted so the
    /// background-safe tool gates (web/python/memory) can tell the PCC server
    /// model — which calls FoundationModels tools natively — apart from the
    /// on-device model, which stays tool-free. Written on every successful
    /// `.afm` load; only consulted while `currentModelFormat == "afm"`.
    static let persistedCurrentKindKey = "currentAppleFoundationModelKind"

    static func persistedCurrentKind(_ defaults: UserDefaults = .standard) -> AppleFoundationModelKind {
        defaults.string(forKey: persistedCurrentKindKey)
            .flatMap(AppleFoundationModelKind.init(rawValue:)) ?? .onDevice
    }

    var modelID: String {
        switch self {
        case .onDevice: return "apple/system-foundation-model"
        case .privateCloudCompute: return "apple/private-cloud-compute"
        }
    }

    var modelName: String {
        switch self {
        case .onDevice: return "Apple Foundation Model"
        case .privateCloudCompute: return "Apple Private Cloud Compute"
        }
    }

    var quantLabel: String {
        switch self {
        case .onDevice: return "System"
        case .privateCloudCompute: return "Private Cloud"
        }
    }

    var parameterCountLabel: String {
        switch self {
        case .onDevice: return "3B params"
        case .privateCloudCompute: return "32K context"
        }
    }

    var summary: String {
        switch self {
        case .onDevice:
            return String(localized: "On-device Apple Foundation language model.")
        case .privateCloudCompute:
            return String(localized: "Apple's privacy-preserving server model with a 32K context window and extended reasoning.")
        }
    }

    var tags: [String] {
        switch self {
        case .onDevice:
            return ["on-device", "apple-intelligence"]
        case .privateCloudCompute:
            return ["private-cloud", "apple-intelligence", "reasoning", "32k-context"]
        }
    }

    var supportsVision: Bool {
        switch self {
        case .onDevice: return false
        case .privateCloudCompute: return true
        }
    }

    var downloadURL: URL {
        switch self {
        case .onDevice: return URL(string: "afm://system")!
        case .privateCloudCompute: return URL(string: "afm://private-cloud-compute")!
        }
    }

    static func resolve(modelID: String) -> AppleFoundationModelKind? {
        allCases.first { $0.modelID == modelID }
    }

    static func resolve(modelID: String?, url: URL?) -> AppleFoundationModelKind {
        if let modelID, let kind = resolve(modelID: modelID) {
            return kind
        }
        if let path = url?.standardizedFileURL.path,
           path.contains("/apple/private-cloud-compute") {
            return .privateCloudCompute
        }
        return .onDevice
    }
}

final class AppleFoundationModelRegistry: ModelRegistry, @unchecked Sendable {
    static let modelID = AppleFoundationModelKind.onDevice.modelID
    static let modelName = AppleFoundationModelKind.onDevice.modelName
    static let quantLabel = AppleFoundationModelKind.onDevice.quantLabel
    static let parameterCountLabel = AppleFoundationModelKind.onDevice.parameterCountLabel

    static let privateCloudModelID = AppleFoundationModelKind.privateCloudCompute.modelID
    static let privateCloudModelName = AppleFoundationModelKind.privateCloudCompute.modelName
    static let privateCloudQuantLabel = AppleFoundationModelKind.privateCloudCompute.quantLabel
    static let privateCloudParameterCountLabel = AppleFoundationModelKind.privateCloudCompute.parameterCountLabel

    static var availableKinds: [AppleFoundationModelKind] {
        var kinds: [AppleFoundationModelKind] = []
        if AppleFoundationModelAvailability.isSupportedDevice {
            kinds.append(.onDevice)
        }
        if ApplePrivateCloudComputeAvailability.isSelectable {
            kinds.append(.privateCloudCompute)
        }
        return kinds
    }

    private func record(for kind: AppleFoundationModelKind) -> ModelRecord {
        ModelRecord(
            id: kind.modelID,
            displayName: kind.modelName,
            publisher: "Apple",
            summary: kind.summary,
            parameterCountLabel: kind.parameterCountLabel,
            hasInstallableQuant: true,
            formats: [.afm],
            installed: true,
            tags: kind.tags,
            pipeline_tag: "text-generation",
            minRAMBytes: nil,
            recommendedETBackend: nil,
            supportsVision: kind.supportsVision
        )
    }

    private func details(for kind: AppleFoundationModelKind) -> ModelDetails {
        ModelDetails(
            id: kind.modelID,
            summary: kind.summary,
            parameterCountLabel: kind.parameterCountLabel,
            quants: [
                QuantInfo(
                    label: kind.quantLabel,
                    format: .afm,
                    sizeBytes: 0,
                    downloadURL: kind.downloadURL,
                    sha256: nil,
                    configURL: nil
                )
            ],
            promptTemplate: nil,
            minRAMBytes: nil
        )
    }

    func curated() async throws -> [ModelRecord] {
        Self.availableKinds.map(record)
    }

    func searchStream(
        query: String,
        page: Int,
        format: ModelFormat?,
        includeVisionModels: Bool,
        visionOnly: Bool
    ) -> AsyncThrowingStream<ModelRecord, Error> {
        AsyncThrowingStream { continuation in
            guard format == nil || format == .afm else {
                continuation.finish()
                return
            }

            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for kind in Self.availableKinds {
                let model = record(for: kind)
                if visionOnly && !model.supportsVision { continue }
                if !includeVisionModels && model.supportsVision { continue }
                if needle.isEmpty || matches(query: needle, record: model) {
                    continuation.yield(model)
                }
            }
            continuation.finish()
        }
    }

    func details(for id: String) async throws -> ModelDetails {
        guard let kind = AppleFoundationModelKind.resolve(modelID: id),
              Self.availableKinds.contains(kind) else {
            throw URLError(.badURL)
        }
        return details(for: kind)
    }

    private func matches(query: String, record: ModelRecord) -> Bool {
        if record.displayName.lowercased().contains(query) { return true }
        if record.id.lowercased().contains(query) { return true }
        if record.publisher.lowercased().contains(query) { return true }
        return false
    }
}
