import CloudKit
import Foundation

private func intValue(from value: CKRecordValue?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let intValue = value as? Int { return intValue }
    return nil
}

private func boolValue(from value: CKRecordValue?) -> Bool? {
    guard let intValue = intValue(from: value) else { return nil }
    return intValue != 0
}

public enum RelayProviderKind: String, Codable, CaseIterable, Sendable {
    case local
    case ollama
    case lmstudio
    case http

    public var displayName: String {
        switch self {
        case .local: return "Local"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .http: return "HTTP"
        }
    }
}

public enum RelayEndpointKind: String, Codable, CaseIterable, Sendable {
    case ollama
    case lmstudio
    case openAICompatible = "openai-compatible"

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .openAICompatible: return "OpenAI-Compatible"
        }
    }
}

public enum RelayModelHealth: String, Codable, CaseIterable, Sendable {
    case available
    case missing
    case pulling
    case error
}

public enum RelayEndpointHealth: String, Codable, CaseIterable, Sendable {
    case up
    case down
}

public enum RelayHostStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case loading
    case running
    case error
}

public enum RelayCommandState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case failed
}

public struct RelayDeviceRecord: Sendable {
    public var recordID: CKRecord.ID
    public var hostDeviceID: String
    public var name: String
    public var lastSeen: Date
    public var capabilities: [String: String]
    public var catalogVersion: Int
    public var activeModelReference: CKRecord.Reference?
    public var status: RelayHostStatus

    public init(recordID: CKRecord.ID,
                hostDeviceID: String,
                name: String,
                lastSeen: Date,
                capabilities: [String: String],
                catalogVersion: Int,
                activeModelReference: CKRecord.Reference?,
                status: RelayHostStatus) {
        self.recordID = recordID
        self.hostDeviceID = hostDeviceID
        self.name = name
        self.lastSeen = lastSeen
        self.capabilities = capabilities
        self.catalogVersion = catalogVersion
        self.activeModelReference = activeModelReference
        self.status = status
    }

    public init?(record: CKRecord) {
        guard let hostDeviceID = record["hostDeviceID"] as? String,
              let name = record["name"] as? String,
              let lastSeen = record["lastSeen"] as? Date,
              let catalogVersion = intValue(from: record["catalogVersion"]),
              let statusRaw = record["status"] as? String,
              let status = RelayHostStatus(rawValue: statusRaw) else {
            return nil
        }
        self.recordID = record.recordID
        self.hostDeviceID = hostDeviceID
        self.name = name
        self.lastSeen = lastSeen
        if let data = record["capabilities"] as? Data,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.capabilities = decoded
        } else {
            self.capabilities = [:]
        }
        self.catalogVersion = catalogVersion
        self.activeModelReference = record["activeModelRef"] as? CKRecord.Reference
        self.status = status
    }

    public func apply(to record: CKRecord) throws {
        record["hostDeviceID"] = hostDeviceID as CKRecordValue
        record["name"] = name as CKRecordValue
        record["lastSeen"] = lastSeen as CKRecordValue
        let data = try JSONEncoder().encode(capabilities)
        record["capabilities"] = data as CKRecordValue
        record["catalogVersion"] = catalogVersion as CKRecordValue
        record["status"] = status.rawValue as CKRecordValue
        record["activeModelRef"] = activeModelReference
    }
}

public struct RelayModelRecord: Sendable {
    public var recordID: CKRecord.ID
    public var modelID: String
    public var hostDeviceID: String
    public var displayName: String
    public var provider: RelayProviderKind
    public var endpointID: String?
    public var identifier: String
    public var context: Int?
    public var quant: String?
    public var sizeBytes: Int64?
    public var tags: [String]
    public var exposed: Bool
    public var health: RelayModelHealth
    public var lastChecked: Date?
    public var version: Int
    /// Overfit (paged GGUF) advertisement. Optional and defaulted so records
    /// written by builds without these fields keep decoding unchanged.
    public var overfitClassification: String?
    public var overfitMeasuredGenerationRate: Double?

    public init(recordID: CKRecord.ID,
                modelID: String,
                hostDeviceID: String,
                displayName: String,
                provider: RelayProviderKind,
                endpointID: String?,
                identifier: String,
                context: Int?,
                quant: String?,
                sizeBytes: Int64?,
                tags: [String],
                exposed: Bool,
                health: RelayModelHealth,
                lastChecked: Date?,
                version: Int,
                overfitClassification: String? = nil,
                overfitMeasuredGenerationRate: Double? = nil) {
        self.recordID = recordID
        self.modelID = modelID
        self.hostDeviceID = hostDeviceID
        self.displayName = displayName
        self.provider = provider
        self.endpointID = endpointID
        self.identifier = identifier
        self.context = context
        self.quant = quant
        self.sizeBytes = sizeBytes
        self.tags = tags
        self.exposed = exposed
        self.health = health
        self.lastChecked = lastChecked
        self.version = version
        self.overfitClassification = overfitClassification
        self.overfitMeasuredGenerationRate = overfitMeasuredGenerationRate
    }

    public init?(record: CKRecord) {
        guard let modelID = record["modelID"] as? String,
              let hostDeviceID = record["hostDeviceID"] as? String,
              let displayName = record["displayName"] as? String,
              let providerRaw = record["provider"] as? String,
              let provider = RelayProviderKind(rawValue: providerRaw),
              let identifier = record["identifier"] as? String,
              let exposed = boolValue(from: record["exposed"]),
              let healthRaw = record["health"] as? String,
              let health = RelayModelHealth(rawValue: healthRaw),
              let version = intValue(from: record["version"]) else {
            return nil
        }
        self.recordID = record.recordID
        self.modelID = modelID
        self.hostDeviceID = hostDeviceID
        self.displayName = displayName
        self.provider = provider
        self.endpointID = record["endpointID"] as? String
        self.identifier = identifier
        self.context = intValue(from: record["context"])
        self.quant = record["quant"] as? String
        if let size = record["sizeBytes"] as? NSNumber {
            self.sizeBytes = size.int64Value
        } else {
            self.sizeBytes = nil
        }
        self.tags = record["tags"] as? [String] ?? []
        self.exposed = exposed
        self.health = health
        self.lastChecked = record["lastChecked"] as? Date
        self.version = version
        self.overfitClassification = record["overfitClassification"] as? String
        if let rate = record["overfitMeasuredGenerationRate"] as? NSNumber {
            self.overfitMeasuredGenerationRate = rate.doubleValue
        } else {
            self.overfitMeasuredGenerationRate = nil
        }
    }

    public func apply(to record: CKRecord) {
        record["modelID"] = modelID as CKRecordValue
        record["hostDeviceID"] = hostDeviceID as CKRecordValue
        record["displayName"] = displayName as CKRecordValue
        record["provider"] = provider.rawValue as CKRecordValue
        if let endpointID {
            record["endpointID"] = endpointID as CKRecordValue
        } else {
            record["endpointID"] = nil
        }
        record["identifier"] = identifier as CKRecordValue
        if let context {
            record["context"] = context as CKRecordValue
        } else {
            record["context"] = nil
        }
        if let quant {
            record["quant"] = quant as CKRecordValue
        } else {
            record["quant"] = nil
        }
        if let sizeBytes {
            record["sizeBytes"] = NSNumber(value: sizeBytes)
        } else {
            record["sizeBytes"] = nil
        }
        if tags.isEmpty {
            record["tags"] = nil
        } else {
            record["tags"] = tags as CKRecordValue
        }
        record["exposed"] = NSNumber(value: exposed ? 1 : 0)
        record["health"] = health.rawValue as CKRecordValue
        record["lastChecked"] = lastChecked
        record["version"] = version as CKRecordValue
        if let overfitClassification {
            record["overfitClassification"] = overfitClassification as CKRecordValue
        } else {
            record["overfitClassification"] = nil
        }
        if let overfitMeasuredGenerationRate {
            record["overfitMeasuredGenerationRate"] = NSNumber(value: overfitMeasuredGenerationRate)
        } else {
            record["overfitMeasuredGenerationRate"] = nil
        }
    }
}

public struct RelayEndpointRecord: Sendable {
    public var recordID: CKRecord.ID
    public var endpointID: String
    public var hostDeviceID: String
    public var kind: RelayEndpointKind
    public var baseURL: String
    public var authConfigured: Bool
    public var health: RelayEndpointHealth
    public var exposed: Bool

    public init(recordID: CKRecord.ID,
                endpointID: String,
                hostDeviceID: String,
                kind: RelayEndpointKind,
                baseURL: String,
                authConfigured: Bool,
                health: RelayEndpointHealth,
                exposed: Bool) {
        self.recordID = recordID
        self.endpointID = endpointID
        self.hostDeviceID = hostDeviceID
        self.kind = kind
        self.baseURL = baseURL
        self.authConfigured = authConfigured
        self.health = health
        self.exposed = exposed
    }

    public init?(record: CKRecord) {
        guard let endpointID = record["endpointID"] as? String,
              let hostDeviceID = record["hostDeviceID"] as? String,
              let kindRaw = record["kind"] as? String,
              let kind = RelayEndpointKind(rawValue: kindRaw),
              let baseURL = record["baseURL"] as? String,
              let authConfigured = boolValue(from: record["authConfigured"]),
              let healthRaw = record["health"] as? String,
              let health = RelayEndpointHealth(rawValue: healthRaw),
              let exposed = boolValue(from: record["exposed"]) else {
            return nil
        }
        self.recordID = record.recordID
        self.endpointID = endpointID
        self.hostDeviceID = hostDeviceID
        self.kind = kind
        self.baseURL = baseURL
        self.authConfigured = authConfigured
        self.health = health
        self.exposed = exposed
    }

    public func apply(to record: CKRecord) {
        record["endpointID"] = endpointID as CKRecordValue
        record["hostDeviceID"] = hostDeviceID as CKRecordValue
        record["kind"] = kind.rawValue as CKRecordValue
        record["baseURL"] = baseURL as CKRecordValue
        record["authConfigured"] = NSNumber(value: authConfigured ? 1 : 0)
        record["health"] = health.rawValue as CKRecordValue
        record["exposed"] = NSNumber(value: exposed ? 1 : 0)
    }
}

public struct RelayHostStateRecord: Sendable {
    public var recordID: CKRecord.ID
    public var hostDeviceID: String
    public var activeModelReference: CKRecord.Reference?
    public var status: RelayHostStatus
    public var tokensPerSecond: Double?
    public var context: Int?
    public var stateVersion: Int
    public var lastChangedBy: String
    public var lastUpdated: Date

    public init(recordID: CKRecord.ID,
                hostDeviceID: String,
                activeModelReference: CKRecord.Reference?,
                status: RelayHostStatus,
                tokensPerSecond: Double?,
                context: Int?,
                stateVersion: Int,
                lastChangedBy: String,
                lastUpdated: Date) {
        self.recordID = recordID
        self.hostDeviceID = hostDeviceID
        self.activeModelReference = activeModelReference
        self.status = status
        self.tokensPerSecond = tokensPerSecond
        self.context = context
        self.stateVersion = stateVersion
        self.lastChangedBy = lastChangedBy
        self.lastUpdated = lastUpdated
    }

    public init?(record: CKRecord) {
        guard let hostDeviceID = record["hostDeviceID"] as? String,
              let statusRaw = record["status"] as? String,
              let status = RelayHostStatus(rawValue: statusRaw),
              let stateVersion = intValue(from: record["stateVersion"]),
              let lastChangedBy = record["lastChangedBy"] as? String,
              let lastUpdated = record["lastUpdated"] as? Date else {
            return nil
        }
        self.recordID = record.recordID
        self.hostDeviceID = hostDeviceID
        self.activeModelReference = record["activeModelRef"] as? CKRecord.Reference
        self.status = status
        if let tps = record["tps"] as? NSNumber {
            self.tokensPerSecond = tps.doubleValue
        } else {
            self.tokensPerSecond = nil
        }
        self.context = intValue(from: record["context"])
        self.stateVersion = stateVersion
        self.lastChangedBy = lastChangedBy
        self.lastUpdated = lastUpdated
    }

    public func apply(to record: CKRecord) {
        record["hostDeviceID"] = hostDeviceID as CKRecordValue
        record["status"] = status.rawValue as CKRecordValue
        record["stateVersion"] = stateVersion as CKRecordValue
        record["lastChangedBy"] = lastChangedBy as CKRecordValue
        record["lastUpdated"] = lastUpdated as CKRecordValue
        if let tokensPerSecond {
            record["tps"] = NSNumber(value: tokensPerSecond)
        } else {
            record["tps"] = nil
        }
        if let context {
            record["context"] = context as CKRecordValue
        } else {
            record["context"] = nil
        }
        record["activeModelRef"] = activeModelReference
    }
}

public struct RelayCommandRecord: Sendable {
    public var recordID: CKRecord.ID
    public var hostDeviceID: String
    public var verb: String
    public var path: String
    public var body: Data?
    public var state: RelayCommandState
    public var statusCode: Int?
    public var result: Data?
    public var leaseOwner: String?
    public var leaseUntil: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var idempotencyKey: String?

    public init?(record: CKRecord) {
        guard let hostDeviceID = record["hostDeviceID"] as? String,
              let verb = record["verb"] as? String,
              let path = record["path"] as? String,
              let stateRaw = record["state"] as? String,
              let state = RelayCommandState(rawValue: stateRaw),
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }
        self.recordID = record.recordID
        self.hostDeviceID = hostDeviceID
        self.verb = verb
        self.path = path
        self.body = record["body"] as? Data
        self.state = state
        if let status = record["statusCode"] as? NSNumber {
            self.statusCode = status.intValue
        }
        self.result = record["result"] as? Data
        self.leaseOwner = record["leaseOwner"] as? String
        self.leaseUntil = record["leaseUntil"] as? Date
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.idempotencyKey = record["idempotencyKey"] as? String
    }

    public func apply(to record: CKRecord) {
        record["hostDeviceID"] = hostDeviceID as CKRecordValue
        record["verb"] = verb as CKRecordValue
        record["path"] = path as CKRecordValue
        record["state"] = state.rawValue as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
        if let body {
            record["body"] = body as CKRecordValue
        } else {
            record["body"] = nil
        }
        if let statusCode {
            record["statusCode"] = NSNumber(value: statusCode)
        } else {
            record["statusCode"] = nil
        }
        if let result {
            record["result"] = result as CKRecordValue
        } else {
            record["result"] = nil
        }
        record["leaseOwner"] = leaseOwner as CKRecordValue?
        record["leaseUntil"] = leaseUntil as CKRecordValue?
        record["idempotencyKey"] = idempotencyKey as CKRecordValue?
    }
}

public enum RelayCatalogRecordType: String, Sendable {
    case device = "Device"
    case model = "Model"
    case endpoint = "Endpoint"
    case hostState = "HostState"
    case command = "Command"
}

private extension CKRecordValue {
    static func fromOptional(_ value: CKRecordValue?) -> CKRecordValue? { value }
}
