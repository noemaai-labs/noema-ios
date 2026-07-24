import Foundation
import RelayKit

enum RelayModelOrigin: Equatable {
    case local(modelID: String, quant: String)
    case remote(backendID: UUID, modelID: String)
}

struct RelayModelDescriptor: Identifiable, Equatable {
    enum Kind: Equatable {
        case local(LocalModel)
        case remote(RemoteBackend, RemoteModel)
    }

    let id: String
    let origin: RelayModelOrigin
    let kind: Kind
    let displayName: String
    let provider: RelayProviderKind
    let endpointID: String?
    let identifier: String
    let context: Int?
    let quant: String?
    let sizeBytes: Int64?
    let tags: [String]
    let settings: ModelSettings?
    // Overfit (paged GGUF) advertisement. Defaulted so the builders in
    // RelayManagementView stay source-compatible; the relay engine backfills
    // from the paged install's canary record.
    var overfitClassification: String? = nil
    var overfitMeasuredGenerationRate: Double? = nil

    var isLocal: Bool {
        if case .local = origin { return true }
        return false
    }

    var backend: RemoteBackend? {
        switch kind {
        case .local: return nil
        case .remote(let backend, _): return backend
        }
    }
}

struct RelayCatalogEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var modelID: String
    var originIdentifier: String
    var displayName: String
    var providerRaw: String
    var endpointID: String?
    var identifier: String
    var context: Int?
    var quant: String?
    var sizeBytes: Int64?
    var tags: [String]
    var exposed: Bool
    var health: RelayModelHealth
    var lastChecked: Date?
    // Optional so persisted catalogs from builds without Overfit decode as-is.
    var overfitClassification: String?
    var overfitMeasuredGenerationRate: Double?

    var provider: RelayProviderKind {
        RelayProviderKind(rawValue: providerRaw) ?? .local
    }

    init(id: UUID = UUID(),
         modelID: String,
         originIdentifier: String,
         displayName: String,
         provider: RelayProviderKind,
         endpointID: String? = nil,
         identifier: String,
         context: Int? = nil,
         quant: String? = nil,
         sizeBytes: Int64? = nil,
         tags: [String] = [],
         exposed: Bool = false,
         health: RelayModelHealth = .available,
         lastChecked: Date? = nil,
         overfitClassification: String? = nil,
         overfitMeasuredGenerationRate: Double? = nil) {
        self.id = id
        self.modelID = modelID
        self.originIdentifier = originIdentifier
        self.displayName = displayName
        self.providerRaw = provider.rawValue
        self.endpointID = endpointID
        self.identifier = identifier
        self.context = context
        self.quant = quant
        self.sizeBytes = sizeBytes
        self.tags = tags
        self.exposed = exposed
        self.health = health
        self.lastChecked = lastChecked
        self.overfitClassification = overfitClassification
        self.overfitMeasuredGenerationRate = overfitMeasuredGenerationRate
    }
}
