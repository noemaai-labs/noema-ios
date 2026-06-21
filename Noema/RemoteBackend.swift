import Foundation
import CloudKit
import RelayKit
#if canImport(UIKit)
import UIKit
#endif

private func appLocale() -> Locale {
    LocalizationManager.preferredLocale()
}

struct RemoteBackend: Identifiable, Codable, Equatable {
    typealias ID = UUID

    enum EndpointType: String, Codable, CaseIterable, Identifiable {
        case openAI
        case openRouter
        case lmStudio
        case ollama
        case cloudRelay
        case noemaRelay

        var id: String { rawValue }

        static var remoteEndpointOptions: [EndpointType] {
            allCases.filter { $0 != .cloudRelay }
        }

        var displayName: String {
            switch self {
            case .openAI: return String(localized: "OpenAI API", locale: appLocale())
            case .openRouter: return String(localized: "OpenRouter", locale: appLocale())
            case .lmStudio: return String(localized: "LM Studio", locale: appLocale())
            case .ollama: return String(localized: "Ollama", locale: appLocale())
            case .cloudRelay: return String(localized: "Cloud Relay", locale: appLocale())
            case .noemaRelay: return String(localized: "Noema Relay", locale: appLocale())
            }
        }

        var symbolName: String {
            switch self {
            case .openAI: return "bolt.horizontal.circle.fill"
            case .openRouter: return "point.3.connected.trianglepath.dotted"
            case .lmStudio: return "macmini.fill"
            case .ollama: return "cube.fill"
            case .cloudRelay: return "icloud"
            case .noemaRelay: return "laptopcomputer.and.iphone"
            }
        }

        var description: String {
            switch self {
            case .openAI:
                return String(localized: "Compatible with OpenAI-style /v1 endpoints", locale: appLocale())
            case .openRouter:
                return String(localized: "Route across OpenRouter's provider network", locale: appLocale())
            case .lmStudio:
                return String(localized: "Connect to LM Studio's REST server", locale: appLocale())
            case .ollama:
                return String(localized: "Target an Ollama host for chat and pulls", locale: appLocale())
            case .cloudRelay:
                return String(localized: "Use Noema's Cloud Relay on macOS", locale: appLocale())
            case .noemaRelay:
                return String(localized: "Pair with your Mac over CloudKit", locale: appLocale())
            }
        }

        var defaultChatPath: String {
            switch self {
            case .openAI: return "/v1/chat/completions"
            case .openRouter: return "/api/v1/chat/completions"
            case .lmStudio: return "/api/v1/chat"
            case .ollama: return "/api/chat"
            case .cloudRelay: return ""
            case .noemaRelay: return ""
            }
        }

        var defaultModelsPath: String {
            switch self {
            case .openAI: return "/v1/models"
            case .openRouter: return "/api/v1/models/user"
            case .lmStudio: return "/api/v1/models"
            case .ollama: return "/api/tags"
            case .cloudRelay: return ""
            case .noemaRelay: return ""
            }
        }

        var isRelay: Bool {
            switch self {
            case .cloudRelay, .noemaRelay:
                return true
            default:
                return false
            }
        }

        var isOpenRouter: Bool { self == .openRouter }
    }

    struct ConnectionSummary: Codable, Equatable {
        enum Kind: String, Codable {
            case success
            case failure
        }

        var kind: Kind
        var statusCode: Int?
        var reason: String?
        var message: String?
        var timestamp: Date

        var displayLine: String {
            if let code = statusCode {
                let normalizedReason = (reason ?? RemoteBackend.normalizedStatusReason(for: code))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if normalizedReason.isEmpty {
                    return "HTTP \(code)"
                }
                return "HTTP \(code) \(normalizedReason)"
            }
            if let message, !message.isEmpty {
                return message
            }
            return kind == .success ? "Connection successful" : "No response recorded"
        }

        static func success(statusCode: Int, reason: String?, timestamp: Date = Date()) -> ConnectionSummary {
            ConnectionSummary(kind: .success,
                              statusCode: statusCode,
                              reason: reason,
                              message: nil,
                              timestamp: timestamp)
        }

        static func failure(statusCode: Int, reason: String?, timestamp: Date = Date()) -> ConnectionSummary {
            ConnectionSummary(kind: .failure,
                              statusCode: statusCode,
                              reason: reason,
                              message: nil,
                              timestamp: timestamp)
        }

        static func failure(message: String, timestamp: Date = Date()) -> ConnectionSummary {
            ConnectionSummary(kind: .failure,
                              statusCode: nil,
                              reason: nil,
                              message: message,
                              timestamp: timestamp)
        }
    }

    var id: UUID
    var name: String
    var baseURLString: String
    var chatPath: String
    var modelsPath: String
    var relayHostDeviceID: String?
    var relayEjectsOnDisconnect: Bool
    var authHeader: String?
    var customModelIDs: [String]
    var endpointType: EndpointType
    var relayLANURLString: String?
    var relayAPIToken: String?
    var relayWiFiSSID: String?
    var relayLANInterface: RelayLANInterface?
    var cachedModels: [RemoteModel]
    var lastFetched: Date?
    var lastError: String?
    var lastConnectionSummary: ConnectionSummary?
    var relayHostStatus: RelayHostStatus?

    init(id: UUID = UUID(),
         name: String,
         baseURLString: String,
         chatPath: String,
        modelsPath: String,
        relayHostDeviceID: String? = nil,
        relayEjectsOnDisconnect: Bool = false,
        authHeader: String? = nil,
         relayLANURLString: String? = nil,
         relayAPIToken: String? = nil,
         relayWiFiSSID: String? = nil,
         relayLANInterface: RelayLANInterface? = nil,
         customModelIDs: [String] = [],
         endpointType: EndpointType,
         cachedModels: [RemoteModel] = [],
         lastFetched: Date? = nil,
         lastError: String? = nil,
         lastConnectionSummary: ConnectionSummary? = nil,
         relayHostStatus: RelayHostStatus? = nil) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.chatPath = chatPath
        self.modelsPath = modelsPath
        if let relayHostDeviceID {
            let trimmedHost = relayHostDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.relayHostDeviceID = trimmedHost.isEmpty ? nil : trimmedHost
        } else {
            self.relayHostDeviceID = nil
        }
        self.relayEjectsOnDisconnect = relayEjectsOnDisconnect
        self.authHeader = authHeader
        if let relayLANURLString {
            let trimmed = relayLANURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            self.relayLANURLString = trimmed.isEmpty ? nil : trimmed
        } else {
            self.relayLANURLString = nil
        }
        if let relayAPIToken {
            let trimmed = relayAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
            self.relayAPIToken = trimmed.isEmpty ? nil : trimmed
        } else {
            self.relayAPIToken = nil
        }
        if let relayWiFiSSID {
            let trimmed = relayWiFiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.relayWiFiSSID = trimmed.isEmpty ? nil : trimmed
        } else {
            self.relayWiFiSSID = nil
        }
        if let relayLANInterface {
            self.relayLANInterface = relayLANInterface
        } else if self.relayWiFiSSID != nil {
            self.relayLANInterface = .wifi
        } else {
            self.relayLANInterface = nil
        }
        self.customModelIDs = RemoteBackend.normalize(customModelIDs)
        self.endpointType = endpointType
        self.cachedModels = cachedModels
        self.lastFetched = lastFetched
        self.lastError = lastError
        self.lastConnectionSummary = lastConnectionSummary
        self.relayHostStatus = relayHostStatus
    }

    init(from draft: RemoteBackendDraft) throws {
        if draft.endpointType.isRelay {
            let containerID = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !containerID.isEmpty else {
                throw RemoteBackendError.validationFailed(String(localized: "Please provide the CloudKit container identifier.", locale: appLocale()))
            }
            var hostDeviceID: String?
            if draft.endpointType == .noemaRelay {
                let trimmedHost = draft.relayHostDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedHost.isEmpty else {
                    throw RemoteBackendError.validationFailed(String(localized: "Please provide the host device ID from the Mac relay.", locale: appLocale()))
                }
                hostDeviceID = trimmedHost
            }
            let lanURL = draft.relayLANURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiToken = draft.relayAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let wifiSSID = draft.relayWiFiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURLString: containerID,
                chatPath: "",
                modelsPath: "",
                relayHostDeviceID: hostDeviceID,
                relayEjectsOnDisconnect: false,
                authHeader: nil,
                relayLANURLString: lanURL.isEmpty ? nil : lanURL,
                relayAPIToken: apiToken.isEmpty ? nil : apiToken,
                relayWiFiSSID: wifiSSID.isEmpty ? nil : wifiSSID,
                relayLANInterface: wifiSSID.isEmpty ? nil : .wifi,
                customModelIDs: draft.sanitizedCustomModelIDs,
                endpointType: draft.endpointType
            )
            return
        }
        guard let baseURL = draft.validatedBaseURL() else {
            throw RemoteBackendError.invalidBaseURL
        }
        let trimmedAuth = draft.authHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedAuthHeader: String? = draft.endpointType == .openRouter ? nil : (trimmedAuth.isEmpty ? nil : trimmedAuth)
        self.init(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURLString: baseURL.absoluteString,
            chatPath: RemoteBackend.normalize(path: draft.chatPath,
                                             fallback: draft.endpointType.defaultChatPath),
            modelsPath: RemoteBackend.normalize(path: draft.modelsPath,
                                              fallback: draft.endpointType.defaultModelsPath),
            relayHostDeviceID: nil,
            relayEjectsOnDisconnect: false,
            authHeader: storedAuthHeader,
            relayLANURLString: nil,
            relayAPIToken: nil,
            relayWiFiSSID: nil,
            relayLANInterface: nil,
            customModelIDs: draft.sanitizedCustomModelIDs,
            endpointType: draft.endpointType
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURLString, chatPath, modelsPath, relayHostDeviceID, relayEjectsOnDisconnect, authHeader, relayLANURLString, relayAPIToken, relayWiFiSSID, relayLANInterface, customModelID, customModelIDs, endpointType, cachedModels, lastFetched, lastError, lastConnectionSummary, relayHostStatus
        // Legacy
        case legacyIsLMStudio = "isLMStudio"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURLString = try container.decode(String.self, forKey: .baseURLString)
        let decodedChatPath = try container.decode(String.self, forKey: .chatPath)
        let decodedModelsPath = try container.decode(String.self, forKey: .modelsPath)
        if let host = try container.decodeIfPresent(String.self, forKey: .relayHostDeviceID)?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            relayHostDeviceID = host
        } else {
            relayHostDeviceID = nil
        }
        relayEjectsOnDisconnect = try container.decodeIfPresent(Bool.self, forKey: .relayEjectsOnDisconnect) ?? false
        authHeader = try container.decodeIfPresent(String.self, forKey: .authHeader)
        if let lan = try container.decodeIfPresent(String.self, forKey: .relayLANURLString)?.trimmingCharacters(in: .whitespacesAndNewlines), !lan.isEmpty {
            relayLANURLString = lan
        } else {
            relayLANURLString = nil
        }
        if let token = try container.decodeIfPresent(String.self, forKey: .relayAPIToken)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            relayAPIToken = token
        } else {
            relayAPIToken = nil
        }
        if let ssid = try container.decodeIfPresent(String.self, forKey: .relayWiFiSSID)?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty {
            relayWiFiSSID = ssid
        } else {
            relayWiFiSSID = nil
        }
        if let identifiers = try container.decodeIfPresent([String].self, forKey: .customModelIDs) {
            customModelIDs = RemoteBackend.normalize(identifiers)
        } else if let legacyIdentifier = try container.decodeIfPresent(String.self, forKey: .customModelID) {
            customModelIDs = RemoteBackend.normalize([legacyIdentifier])
        } else {
            customModelIDs = []
        }
        if let type = try container.decodeIfPresent(EndpointType.self, forKey: .endpointType) {
            endpointType = type
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .legacyIsLMStudio) {
            endpointType = legacy ? .lmStudio : .openAI
        } else {
            endpointType = .openAI
        }
        let migratedPaths = RemoteBackend.migratedLegacyPathsIfNeeded(chatPath: decodedChatPath,
                                                                       modelsPath: decodedModelsPath,
                                                                       endpointType: endpointType)
        chatPath = migratedPaths.chatPath
        modelsPath = migratedPaths.modelsPath
        cachedModels = try container.decodeIfPresent([RemoteModel].self, forKey: .cachedModels) ?? []
        lastFetched = try container.decodeIfPresent(Date.self, forKey: .lastFetched)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastConnectionSummary = try container.decodeIfPresent(ConnectionSummary.self, forKey: .lastConnectionSummary)
        relayHostStatus = try container.decodeIfPresent(RelayHostStatus.self, forKey: .relayHostStatus)
        if let interfaceRaw = try container.decodeIfPresent(String.self, forKey: .relayLANInterface),
           let interface = RelayLANInterface(rawValue: interfaceRaw) {
            relayLANInterface = interface
        } else if relayWiFiSSID != nil {
            relayLANInterface = .wifi
        } else {
            relayLANInterface = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURLString, forKey: .baseURLString)
        try container.encode(chatPath, forKey: .chatPath)
        try container.encode(modelsPath, forKey: .modelsPath)
        try container.encodeIfPresent(relayHostDeviceID, forKey: .relayHostDeviceID)
        if relayEjectsOnDisconnect {
            try container.encode(true, forKey: .relayEjectsOnDisconnect)
        }
        try container.encodeIfPresent(authHeader, forKey: .authHeader)
        try container.encodeIfPresent(relayLANURLString, forKey: .relayLANURLString)
        try container.encodeIfPresent(relayAPIToken, forKey: .relayAPIToken)
        try container.encodeIfPresent(relayWiFiSSID, forKey: .relayWiFiSSID)
        try container.encodeIfPresent(relayLANInterface?.rawValue, forKey: .relayLANInterface)
        if !customModelIDs.isEmpty {
            try container.encode(customModelIDs, forKey: .customModelIDs)
        }
        try container.encode(endpointType, forKey: .endpointType)
        try container.encode(cachedModels, forKey: .cachedModels)
        try container.encodeIfPresent(lastFetched, forKey: .lastFetched)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(lastConnectionSummary, forKey: .lastConnectionSummary)
        try container.encodeIfPresent(relayHostStatus, forKey: .relayHostStatus)
    }

    static func normalize(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in identifiers {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        return ordered
    }

    var isLMStudio: Bool { endpointType == .lmStudio }
    var isOpenAI: Bool { endpointType == .openAI }
    var isOpenRouter: Bool { endpointType == .openRouter }
    var isOllama: Bool { endpointType == .ollama }
    var isCloudRelay: Bool { endpointType.isRelay }

    static let openRouterDefaultBaseURL = URL(string: "https://openrouter.ai")!
    static let openRouterReferer = "https://noemaai.com"
    static let openRouterTitle = "NoemaAI"

    var baseURL: URL? {
        guard !isCloudRelay else { return nil }
        return URL(string: baseURLString)
    }

    var relayLANBaseURL: URL? {
        guard let raw = relayLANURLString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: "http://\(raw)")
    }

    var normalizedChatPath: String {
        RemoteBackend.normalize(path: chatPath, fallback: endpointType.defaultChatPath)
    }

    var normalizedModelsPath: String {
        RemoteBackend.normalize(path: modelsPath, fallback: endpointType.defaultModelsPath)
    }

    var modelsEndpointURL: URL? {
        guard !isCloudRelay else { return nil }
        return absoluteURL(for: normalizedModelsPath)
    }

    var chatEndpointURL: URL? {
        guard !isCloudRelay else { return nil }
        return absoluteURL(for: normalizedChatPath)
    }

    var hasAuth: Bool { (try? resolvedAuthorizationHeader())?.isEmpty == false }

    func resolvedAuthorizationHeader() throws -> String? {
        if isOpenRouter {
            if let header = try RemoteBackendCredentialStore.openRouterAuthorizationHeader(for: id) {
                return header
            }
            guard let authHeader, !authHeader.isEmpty else { return nil }
            return authHeader
        }
        guard let authHeader, !authHeader.isEmpty else { return nil }
        return authHeader
    }

    var openRouterAttributionHeaders: [String: String] {
        guard isOpenRouter else { return [:] }
        return [
            "HTTP-Referer": Self.openRouterReferer,
            "X-OpenRouter-Title": Self.openRouterTitle
        ]
    }

    var relayAuthorizationHeader: String? {
        guard let token = relayAPIToken, !token.isEmpty else { return nil }
        if token.lowercased().hasPrefix("bearer ") {
            return token
        }
        return "Bearer \(token)"
    }

    func relayAbsoluteURL(for path: String) -> URL? {
        guard let base = relayLANBaseURL else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" {
            return base
        }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        return URL(string: prefixed, relativeTo: base)?.absoluteURL
    }

    var relayLANChatEndpointURL: URL? {
        relayAbsoluteURL(for: "/v1/chat/completions")
    }

    var relayLANModelsEndpointURL: URL? {
        relayAbsoluteURL(for: "/v1/models")
    }

    var relayLANHealthEndpointURL: URL? {
        relayAbsoluteURL(for: "/v1/health")
    }

    var hasCustomModels: Bool { !customModelIDs.isEmpty }

    var displayBaseHost: String {
        if isCloudRelay {
            return baseURLString
        }
        return baseURL?.host ?? baseURLString
    }

    var cloudKitContainerIdentifier: String? {
        guard isCloudRelay else { return nil }
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var usesLoopbackHost: Bool {
        guard let host = baseURL?.host?.lowercased(), !isCloudRelay else { return false }
        return Self.isLoopbackHost(host)
    }

    var usesLocalNetworkHost: Bool {
        guard let host = baseURL?.host?.lowercased(), !isCloudRelay else { return false }
        return Self.isLocalOrLANHost(host)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func isLocalOrLANHost(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return false }
        if isLoopbackHost(host) || host.hasSuffix(".local") { return true }

        let withoutZone = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        if isPrivateIPv4Host(withoutZone) { return true }
        if isLocalIPv6Host(withoutZone) { return true }
        return false
    }

    private static func isPrivateIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int(String($0)) }
        guard octets.count == 4,
              octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch octets[0] {
        case 10:
            return true
        case 127:
            return true
        case 169:
            return octets[1] == 254
        case 172:
            return (16...31).contains(octets[1])
        case 192:
            return octets[1] == 168
        default:
            return false
        }
    }

    private static func isLocalIPv6Host(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard trimmed.contains(":") else { return false }
        if trimmed == "::1" { return true }
        if trimmed.hasPrefix("fe80:") { return true } // Link-local unicast
        if trimmed.hasPrefix("fc") || trimmed.hasPrefix("fd") { return true } // Unique local addresses
        if trimmed.hasPrefix("::ffff:127.") { return true } // IPv4-mapped loopback
        return false
    }

    func absoluteURL(for path: String) -> URL? {
        if isCloudRelay { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return baseURL
        }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        guard let baseURL else { return nil }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        return URL(string: prefixed, relativeTo: baseURL)?.absoluteURL
    }

    func loadPathCandidates(for modelID: String) -> [String] {
        if isCloudRelay { return [] }
        let encodedID = modelID.addingPercentEncoding(withAllowedCharacters: .remoteModelIDAllowed) ?? modelID
        var candidates: [String] = []
        if isLMStudio {
            candidates.append("/api/v1/models/load")
        }
        let modelsPath = normalizedModelsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelsPath.isEmpty {
            let trimmed = modelsPath.hasSuffix("/") ? String(modelsPath.dropLast()) : modelsPath
            candidates.append("\(trimmed)/\(encodedID)/load")
            candidates.append("\(trimmed)/load")
        } else if isOpenAI {
            candidates.append("/v1/models/\(encodedID)/load")
            candidates.append("/v1/models/load")
        } else if isOllama {
            candidates.append("/api/generate")
        }
        if isLMStudio {
            candidates.append("/api/v0/models/load")
            candidates.append("/api/v0/models/\(encodedID)/load")
        }
        return Array(LinkedHashSet(candidates))
    }

    static func normalizedStatusReason(for statusCode: Int) -> String? {
        let localized = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        let trimmed = localized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased() == "ok" {
            return "OK"
        }
        let words = trimmed.split(separator: " ").map { word -> String in
            word.split(separator: "-").map { segment in
                segment.capitalized
            }.joined(separator: "-")
        }
        return words.joined(separator: " ")
    }

    static func statusErrorDescription(for statusCode: Int, reason: String?) -> String {
        let locale = appLocale()
        if let reason, !reason.isEmpty {
            return String.localizedStringWithFormat(
                String(localized: "Server responded with status code %d: %@", locale: locale),
                statusCode,
                reason
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "Server responded with status code %d.", locale: locale),
            statusCode
        )
    }

    /// Produces a user-facing, localized description for generic networking errors.
    static func localizedErrorDescription(for error: Error) -> String {
        let locale = appLocale()
        if let backendError = error as? RemoteBackendError {
            return backendError.errorDescription ?? String(localized: "Unknown error", locale: locale)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return String(localized: "No internet connection.", locale: locale)
            case .timedOut:
                return String(localized: "Request timed out. Please try again.", locale: locale)
            case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return String(localized: "Connection was lost. Please try again.", locale: locale)
            default:
                break
            }
        }
        let message = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = message.isEmpty
            ? String(localized: "Unknown error", locale: locale)
            : message
        return String.localizedStringWithFormat(
            String(localized: "Unexpected error: %@", locale: locale),
            fallback
        )
    }

    private static func normalize(path: String, fallback: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    private static func migratedLegacyPathsIfNeeded(chatPath: String,
                                                    modelsPath: String,
                                                    endpointType: EndpointType) -> (chatPath: String, modelsPath: String) {
        guard endpointType == .lmStudio else { return (chatPath, modelsPath) }

        let legacyChatDefault = "/api/v0/chat/completions"
        let legacyModelsDefault = "/api/v0/models"

        let migratedChatPath: String
        if pathMatches(path: chatPath, legacyDefault: legacyChatDefault) {
            migratedChatPath = endpointType.defaultChatPath
        } else {
            migratedChatPath = chatPath
        }

        let migratedModelsPath: String
        if pathMatches(path: modelsPath, legacyDefault: legacyModelsDefault) {
            migratedModelsPath = endpointType.defaultModelsPath
        } else {
            migratedModelsPath = modelsPath
        }

        return (migratedChatPath, migratedModelsPath)
    }

    private static func pathMatches(path: String, legacyDefault: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(legacyDefault) == .orderedSame {
            return true
        }
        let normalized = normalize(path: trimmed, fallback: legacyDefault)
        return normalized.caseInsensitiveCompare(legacyDefault) == .orderedSame
    }
}

struct RemoteModel: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var author: String
    var owner: String?
    var type: String?
    var publisher: String?
    var architecture: String?
    var compatibilityType: String?
    var quantization: String?
    var state: String?
    var maxContextLength: Int?
    var isCustom: Bool
    var families: [String]?
    var parameterSize: String?
    var fileSizeBytes: Int?
    var digest: String?
    var parentModel: String?
    var modifiedAt: Date?
    var modifiedAtRaw: String?
    var relayRecordName: String?
    var supportedParameters: [String]?
    var defaultTemperature: Double?
    var defaultTopP: Double?
    var defaultTopK: Int?
    var defaultRepetitionPenalty: Double?
    var promptPricePerMillion: Double?
    var completionPricePerMillion: Double?
    var imagePricePerMillion: Double?
    var requestPrice: Double?
    var providerContextLength: Int?
    var maxCompletionTokens: Int?
    var isModerated: Bool?
    var expirationDateRaw: String?
    var descriptionText: String?

    init(id: String,
         name: String,
         author: String,
         owner: String? = nil,
         type: String? = nil,
         publisher: String? = nil,
         architecture: String? = nil,
         compatibilityType: String? = nil,
         quantization: String? = nil,
         state: String? = nil,
         maxContextLength: Int? = nil,
         isCustom: Bool = false,
         families: [String]? = nil,
         parameterSize: String? = nil,
         fileSizeBytes: Int? = nil,
         digest: String? = nil,
         parentModel: String? = nil,
         modifiedAt: Date? = nil,
         modifiedAtRaw: String? = nil,
         relayRecordName: String? = nil,
         supportedParameters: [String]? = nil,
         defaultTemperature: Double? = nil,
         defaultTopP: Double? = nil,
         defaultTopK: Int? = nil,
         defaultRepetitionPenalty: Double? = nil,
         promptPricePerMillion: Double? = nil,
         completionPricePerMillion: Double? = nil,
         imagePricePerMillion: Double? = nil,
         requestPrice: Double? = nil,
         providerContextLength: Int? = nil,
         maxCompletionTokens: Int? = nil,
         isModerated: Bool? = nil,
         expirationDateRaw: String? = nil,
         descriptionText: String? = nil) {
        self.id = id
        self.name = name
        self.author = author
        self.owner = owner
        self.type = type
        self.publisher = publisher
        self.architecture = architecture
        self.compatibilityType = compatibilityType
        self.quantization = quantization
        self.state = state
        self.maxContextLength = maxContextLength
        self.isCustom = isCustom
        self.families = families
        self.parameterSize = parameterSize
        self.fileSizeBytes = fileSizeBytes
        self.digest = digest
        self.parentModel = parentModel
        self.modifiedAt = modifiedAt
        self.modifiedAtRaw = modifiedAtRaw
        self.relayRecordName = relayRecordName
        self.supportedParameters = supportedParameters
        self.defaultTemperature = defaultTemperature
        self.defaultTopP = defaultTopP
        self.defaultTopK = defaultTopK
        self.defaultRepetitionPenalty = defaultRepetitionPenalty
        self.promptPricePerMillion = promptPricePerMillion
        self.completionPricePerMillion = completionPricePerMillion
        self.imagePricePerMillion = imagePricePerMillion
        self.requestPrice = requestPrice
        self.providerContextLength = providerContextLength
        self.maxCompletionTokens = maxCompletionTokens
        self.isModerated = isModerated
        self.expirationDateRaw = expirationDateRaw
        self.descriptionText = descriptionText
    }

    static func make(from openAIModel: OpenAIModel) -> RemoteModel {
        let (name, author) = RemoteModel.parseNameAndAuthor(from: openAIModel.id, fallbackAuthor: openAIModel.ownedBy)
        return RemoteModel(
            id: openAIModel.id,
            name: name,
            author: author,
            owner: openAIModel.ownedBy,
            isCustom: false
        )
    }

    static func make(from openRouterModel: OpenRouterModel) -> RemoteModel {
        let fallbackAuthor = openRouterModel.topProvider?.providerName ?? "OpenRouter"
        let (fallbackName, author) = parseNameAndAuthor(from: openRouterModel.id, fallbackAuthor: fallbackAuthor)
        let trimmedName = openRouterModel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? fallbackName : trimmedName
        let architectureParts = [
            openRouterModel.architecture?.tokenizer,
            openRouterModel.architecture?.modality,
            openRouterModel.architecture?.instructType
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seenArchitectureParts = Set<String>()
        let architecture = architectureParts.filter { seenArchitectureParts.insert($0.lowercased()).inserted }
            .joined(separator: " · ")
        let promptPricePerMillion = openRouterModel.pricing?.prompt.map { $0 * 1_000_000 }
        let completionPricePerMillion = openRouterModel.pricing?.completion.map { $0 * 1_000_000 }
        let imagePricePerMillion = openRouterModel.pricing?.image.map { $0 * 1_000_000 }
        return RemoteModel(
            id: openRouterModel.id,
            name: resolvedName,
            author: author,
            owner: openRouterModel.canonicalSlug,
            type: "openrouter",
            publisher: openRouterModel.topProvider?.providerName ?? "OpenRouter",
            architecture: architecture.isEmpty ? nil : architecture,
            compatibilityType: nil,
            quantization: nil,
            state: nil,
            maxContextLength: openRouterModel.contextLength.flatMap { Int($0) },
            isCustom: false,
            supportedParameters: openRouterModel.supportedParameters,
            defaultTemperature: openRouterModel.defaultParameters?.temperature,
            defaultTopP: openRouterModel.defaultParameters?.topP,
            defaultTopK: openRouterModel.defaultParameters?.topK,
            defaultRepetitionPenalty: openRouterModel.defaultParameters?.repetitionPenalty,
            promptPricePerMillion: promptPricePerMillion,
            completionPricePerMillion: completionPricePerMillion,
            imagePricePerMillion: imagePricePerMillion,
            requestPrice: openRouterModel.pricing?.request,
            providerContextLength: openRouterModel.topProvider?.contextLength.flatMap { Int($0) },
            maxCompletionTokens: openRouterModel.topProvider?.maxCompletionTokens.flatMap { Int($0) },
            isModerated: openRouterModel.topProvider?.isModerated,
            expirationDateRaw: openRouterModel.expirationDate,
            descriptionText: openRouterModel.description
        )
    }

    static func make(from lmStudioModel: LMStudioModel) -> RemoteModel {
        let (fallbackName, author) = RemoteModel.parseNameAndAuthor(from: lmStudioModel.id, fallbackAuthor: lmStudioModel.publisher)
        let displayName = lmStudioModel.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (displayName?.isEmpty == false) ? displayName! : fallbackName
        return RemoteModel(
            id: lmStudioModel.id,
            name: resolvedName,
            author: author,
            owner: lmStudioModel.publisher,
            type: lmStudioModel.type,
            publisher: lmStudioModel.publisher,
            architecture: lmStudioModel.architecture,
            compatibilityType: lmStudioModel.compatibilityType,
            quantization: lmStudioModel.quantization,
            state: lmStudioModel.state,
            maxContextLength: lmStudioModel.maxContextLength,
            isCustom: false,
            families: nil,
            parameterSize: lmStudioModel.paramsString,
            fileSizeBytes: lmStudioModel.sizeBytes,
            digest: nil,
            parentModel: nil,
            modifiedAt: nil,
            modifiedAtRaw: nil,
            relayRecordName: nil
        )
    }

    static func makeCustom(id: String) -> RemoteModel {
        let (name, author) = parseNameAndAuthor(from: id, fallbackAuthor: nil)
        return RemoteModel(id: id, name: name, author: author, owner: nil, isCustom: true)
    }

    static func make(from ollamaModel: OllamaTagsResponse.Model) -> RemoteModel {
        let identifier = ollamaModel.model.isEmpty ? ollamaModel.name : ollamaModel.model
        let (name, author) = parseNameAndAuthor(from: identifier, fallbackAuthor: nil)
        let format = ollamaModel.details?.format
        let compatibility = format?.isEmpty == false ? format : nil
        let architecture = ollamaModel.details?.family?.isEmpty == false ? ollamaModel.details?.family : nil
        let families = ollamaModel.details?.families?.isEmpty == false ? ollamaModel.details?.families : nil
        let quantization = ollamaModel.details?.quantizationLevel?.isEmpty == false ? ollamaModel.details?.quantizationLevel : nil
        let parameterSize = ollamaModel.details?.parameterSize?.isEmpty == false ? ollamaModel.details?.parameterSize : nil
        let parentModel = ollamaModel.details?.parentModel?.isEmpty == false ? ollamaModel.details?.parentModel : nil
        let modifiedAtDate = ollamaModel.modifiedAt.flatMap(RemoteModel.parseOllamaDate)
        return RemoteModel(
            id: identifier,
            name: name,
            author: author,
            owner: nil,
            type: "ollama",
            publisher: "Ollama",
            architecture: architecture,
            compatibilityType: compatibility,
            quantization: quantization,
            state: nil,
            maxContextLength: nil,
            isCustom: false,
            families: families,
            parameterSize: parameterSize,
            fileSizeBytes: ollamaModel.size,
            digest: ollamaModel.digest,
            parentModel: parentModel,
            modifiedAt: modifiedAtDate,
            modifiedAtRaw: ollamaModel.modifiedAt
        )
    }

    private static func parseNameAndAuthor(from identifier: String, fallbackAuthor: String?) -> (name: String, author: String) {
        let trimmedID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback = fallbackAuthor, !fallback.isEmpty {
            return (trimmedID.components(separatedBy: "/").last ?? trimmedID, fallback)
        }
        if let slashIndex = trimmedID.lastIndex(of: "/") {
            let name = String(trimmedID[trimmedID.index(after: slashIndex)...])
            let author = String(trimmedID[..<slashIndex])
            return (name, author)
        }
        return (trimmedID, "Unknown")
    }
}

extension RemoteModel {
    enum OpenRouterBrowserFilter: String, CaseIterable, Codable, Identifiable {
        case all
        case tools
        case structuredOutputs
        case reasoning
        case vision
        case moderated
        case hasPricing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .tools: return "Tools"
            case .structuredOutputs: return "Structured Outputs"
            case .reasoning: return "Reasoning"
            case .vision: return "Vision"
            case .moderated: return "Moderated"
            case .hasPricing: return "Has Pricing"
            }
        }
    }

    enum OpenRouterBrowserSort: String, CaseIterable, Codable, Identifiable {
        case automatic
        case alphabetical
        case contextLength
        case promptPrice
        case completionPrice

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .alphabetical: return "Alphabetical"
            case .contextLength: return "Largest Context"
            case .promptPrice: return "Lowest Input Price"
            case .completionPrice: return "Lowest Output Price"
            }
        }
    }

    var isEmbedding: Bool {
        let loweredID = id.lowercased()
        let loweredName = name.lowercased()
        if loweredID.contains("embedding") || loweredID.contains("embed") { return true }
        if loweredName.contains("embedding") || loweredName.contains("embed") { return true }
        if let type = type?.lowercased(), type.contains("embedding") { return true }
        return false
    }

    private var normalizedState: String? {
        guard let state = state?.trimmingCharacters(in: .whitespacesAndNewlines), !state.isEmpty else {
            return nil
        }
        return state.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var isLoadedOnBackend: Bool {
        guard let normalizedState else { return false }
        if normalizedState == "loaded" { return true }
        if normalizedState == "running" { return true }
        if normalizedState == "active" { return true }
        if normalizedState.contains("loaded") {
            if normalizedState.contains("not") || normalizedState.contains("unloaded") { return false }
            return true
        }
        if normalizedState.contains("running") { return true }
        if normalizedState.contains("active") { return true }
        return false
    }

    var compatibilityFormat: ModelFormat? {
        guard let compat = compatibilityType?.lowercased() else { return nil }
        switch compat {
        case "gguf":
            return .gguf
        case "mlx":
            return .mlx
        default:
            return nil
        }
    }

    var displayFamilies: [String] {
        var output: [String] = []
        if let architecture, !architecture.isEmpty {
            output.append(architecture)
        }
        if let families {
            for family in families where !family.isEmpty {
                if !output.contains(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) {
                    output.append(family)
                }
            }
        }
        return output
    }

    var formattedParameterCount: String? {
        guard let parameterSize = parameterSize?.trimmingCharacters(in: .whitespacesAndNewlines), !parameterSize.isEmpty else {
            return nil
        }
        let compact = parameterSize.replacingOccurrences(
            of: #"(?i)\s*params?\b"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? nil : compact
    }

    var formattedFileSize: String? {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSizeBytes))
    }

    var modifiedAtRelativeDescription: String? {
        guard let modifiedAt else { return nil }
        return RemoteModel.makeRelativeDateFormatter().localizedString(for: modifiedAt, relativeTo: Date())
    }

    var modifiedAtDisplayString: String? {
        if let relative = modifiedAtRelativeDescription {
            return relative
        }
        if let modifiedAtRaw, !modifiedAtRaw.isEmpty {
            return modifiedAtRaw
        }
        return nil
    }

    var normalizedSupportedParameters: [String] {
        (supportedParameters ?? [])
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
            }
            .filter { !$0.isEmpty }
    }

    var supportsTools: Bool {
        normalizedSupportedParameters.contains("tools")
    }

    var supportsStructuredOutputs: Bool {
        normalizedSupportedParameters.contains("structured_outputs")
            || normalizedSupportedParameters.contains("response_format")
    }

    var supportsReasoning: Bool {
        normalizedSupportedParameters.contains("reasoning")
            || normalizedSupportedParameters.contains("reasoning_effort")
            || normalizedSupportedParameters.contains("include_reasoning")
    }

    var isVisionModel: Bool {
        let haystack = [architecture, descriptionText, id, name]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("image")
            || haystack.contains("vision")
            || haystack.contains("multimodal")
    }

    var hasOpenRouterPricing: Bool {
        [promptPricePerMillion, completionPricePerMillion, imagePricePerMillion, requestPrice]
            .contains { value in
                guard let value else { return false }
                return value > 0
            }
    }

    var trimmedDescriptionText: String? {
        guard let descriptionText else { return nil }
        let trimmed = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func matchesOpenRouterSearch(_ searchText: String) -> Bool {
        let normalizedQuery = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else { return true }
        let tokens = normalizedQuery
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return true }
        let haystack = [
            name,
            id,
            author,
            publisher,
            architecture,
            trimmedDescriptionText,
            normalizedSupportedParameters.joined(separator: " ")
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
        return tokens.allSatisfy { haystack.contains($0) }
    }

    func matchesOpenRouterFilter(_ filter: OpenRouterBrowserFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .tools:
            return supportsTools
        case .structuredOutputs:
            return supportsStructuredOutputs
        case .reasoning:
            return supportsReasoning
        case .vision:
            return isVisionModel
        case .moderated:
            return isModerated == true
        case .hasPricing:
            return hasOpenRouterPricing
        }
    }

    func matchesOpenRouterSupportedParameter(_ parameter: String?) -> Bool {
        guard let parameter = parameter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !parameter.isEmpty else { return true }
        return normalizedSupportedParameters.contains(parameter.replacingOccurrences(of: "-", with: "_"))
    }

    func openRouterSearchRank(for searchText: String) -> Int {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return 4 }
        let normalizedQuery = query.replacingOccurrences(of: "_", with: " ")
        let fields: [(String?, Int)] = [
            (name, 0),
            (id, 1),
            (publisher, 2),
            (author, 2),
            (architecture, 3),
            (trimmedDescriptionText, 4),
            (normalizedSupportedParameters.joined(separator: " "), 5)
        ]
        for (field, rank) in fields {
            let haystack = field?
                .lowercased()
                .replacingOccurrences(of: "_", with: " ") ?? ""
            if haystack.contains(normalizedQuery) {
                return rank
            }
        }
        return 10
    }

    func openRouterDefaultSettings(base: ModelSettings? = nil) -> ModelSettings? {
        guard defaultTemperature != nil
            || defaultTopP != nil
            || defaultTopK != nil
            || defaultRepetitionPenalty != nil else {
            return nil
        }
        var settings = base ?? ModelSettings.default(for: compatibilityFormat ?? .gguf)
        if let defaultTemperature {
            settings.temperature = defaultTemperature
        }
        if let defaultTopP {
            settings.topP = defaultTopP
        }
        if let defaultTopK {
            settings.topK = defaultTopK
        }
        if let defaultRepetitionPenalty {
            settings.repetitionPenalty = Float(defaultRepetitionPenalty)
        }
        return settings
    }

    static func parseOllamaDate(_ raw: String) -> Date? {
        let primaryFormatter = makeOllamaDateFormatter()
        let fallbackFormatter = makeOllamaFallbackDateFormatter()

        if let date = primaryFormatter.date(from: raw) {
            return date
        }
        if let trimmedSix = trimFractionalSeconds(in: raw, maxDigits: 6), let date = primaryFormatter.date(from: trimmedSix) {
            return date
        }
        if let trimmedThree = trimFractionalSeconds(in: raw, maxDigits: 3), let date = primaryFormatter.date(from: trimmedThree) {
            return date
        }
        if let trimmedNone = trimFractionalSeconds(in: raw, maxDigits: 0) {
            if let date = primaryFormatter.date(from: trimmedNone) {
                return date
            }
            return fallbackFormatter.date(from: trimmedNone)
        }
        return fallbackFormatter.date(from: raw)
    }

    private static func trimFractionalSeconds(in raw: String, maxDigits: Int) -> String? {
        guard let dotIndex = raw.firstIndex(of: ".") else { return nil }
        let fractionStart = raw.index(after: dotIndex)
        guard fractionStart < raw.endIndex else { return nil }
        let remainder = raw[fractionStart...]
        guard let zoneIndex = remainder.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return nil }
        let timezoneStart = zoneIndex
        let fraction = raw[fractionStart..<timezoneStart]
        if maxDigits == 0 {
            return String(raw[..<dotIndex]) + String(raw[timezoneStart...])
        }
        let limited = String(fraction.prefix(maxDigits))
        var padded = limited
        if padded.count < maxDigits {
            padded = padded.padding(toLength: maxDigits, withPad: "0", startingAt: 0)
        }
        return String(raw[..<dotIndex]) + "." + padded + String(raw[timezoneStart...])
    }

    private static func makeRelativeDateFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }

    private static func makeOllamaDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func makeOllamaFallbackDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModel]
}

struct OpenAIModel: Decodable {
    let id: String
    let object: String
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case ownedBy = "owned_by"
    }
}

struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterModel]
}

struct OpenRouterModel: Decodable {
    struct Pricing: Decodable {
        let prompt: Double?
        let completion: Double?
        let request: Double?
        let image: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prompt = Self.decodeFlexibleDouble(forKey: .prompt, in: container)
            completion = Self.decodeFlexibleDouble(forKey: .completion, in: container)
            request = Self.decodeFlexibleDouble(forKey: .request, in: container)
            image = Self.decodeFlexibleDouble(forKey: .image, in: container)
        }

        private enum CodingKeys: String, CodingKey {
            case prompt
            case completion
            case request
            case image
        }

        private static func decodeFlexibleDouble(forKey key: CodingKeys,
                                                 in container: KeyedDecodingContainer<CodingKeys>) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let stringValue = ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil) {
                return Double(stringValue)
            }
            return nil
        }
    }

    struct Architecture: Decodable {
        let modality: String?
        let tokenizer: String?
        let instructType: String?
        let inputModalities: [String]?
        let outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case modality
            case tokenizer
            case instructType = "instruct_type"
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
        }
    }

    struct TopProviderInfo: Decodable {
        let contextLength: Double?
        let maxCompletionTokens: Double?
        let isModerated: Bool?
        let providerName: String?

        enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
            case maxCompletionTokens = "max_completion_tokens"
            case isModerated = "is_moderated"
            case providerName = "provider_name"
        }
    }

    struct PerRequestLimits: Decodable {
        let promptTokens: Double?
        let completionTokens: Double?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    struct DefaultParameters: Decodable {
        let temperature: Double?
        let topP: Double?
        let topK: Int?
        let repetitionPenalty: Double?

        enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case topK = "top_k"
            case repetitionPenalty = "repetition_penalty"
        }
    }

    let id: String
    let canonicalSlug: String?
    let name: String
    let description: String?
    let pricing: Pricing?
    let contextLength: Double?
    let architecture: Architecture?
    let topProvider: TopProviderInfo?
    let perRequestLimits: PerRequestLimits?
    let supportedParameters: [String]
    let defaultParameters: DefaultParameters?
    let expirationDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalSlug = "canonical_slug"
        case name
        case description
        case pricing
        case contextLength = "context_length"
        case architecture
        case topProvider = "top_provider"
        case perRequestLimits = "per_request_limits"
        case supportedParameters = "supported_parameters"
        case defaultParameters = "default_parameters"
        case expirationDate = "expiration_date"
    }
}

struct OpenRouterKeyResponse: Decodable {
    let data: OpenRouterKeyInfo
}

struct OpenRouterKeyInfo: Decodable, Equatable {
    let label: String
    let limit: Double?
    let usage: Double
    let usageDaily: Double
    let usageWeekly: Double
    let usageMonthly: Double
    let byokUsage: Double
    let byokUsageDaily: Double
    let byokUsageWeekly: Double
    let byokUsageMonthly: Double
    let isFreeTier: Bool
    let isManagementKey: Bool
    let isProvisioningKey: Bool
    let limitRemaining: Double?
    let limitReset: String?
    let includeByokInLimit: Bool
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case label
        case limit
        case usage
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
        case byokUsage = "byok_usage"
        case byokUsageDaily = "byok_usage_daily"
        case byokUsageWeekly = "byok_usage_weekly"
        case byokUsageMonthly = "byok_usage_monthly"
        case isFreeTier = "is_free_tier"
        case isManagementKey = "is_management_key"
        case isProvisioningKey = "is_provisioning_key"
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case includeByokInLimit = "include_byok_in_limit"
        case expiresAt = "expires_at"
    }
}

struct OpenRouterErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        let code: Int?
        let message: String
    }

    let error: ErrorBody
}

struct LMStudioModelsResponse: Decodable {
    let models: [LMStudioModel]

    enum CodingKeys: String, CodingKey {
        case models
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let models = try container.decodeIfPresent([LMStudioModel].self, forKey: .models) {
            self.models = models
            return
        }
        if let legacy = try container.decodeIfPresent([LMStudioModel].self, forKey: .data) {
            self.models = legacy
            return
        }
        self.models = []
    }
}

struct LMStudioModel: Decodable {
    let id: String
    let object: String?
    let type: String?
    let publisher: String?
    let displayName: String?
    let architecture: String?
    let compatibilityType: String?
    let quantization: String?
    let state: String?
    let maxContextLength: Int?
    let paramsString: String?
    let sizeBytes: Int?
    let loadedInstancesCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case object
        case type
        case publisher
        case displayName = "display_name"
        case architecture
        case arch
        case compatibilityType = "compatibility_type"
        case format
        case quantization
        case state
        case maxContextLength = "max_context_length"
        case paramsString = "params_string"
        case sizeBytes = "size_bytes"
        case loadedInstances = "loaded_instances"
    }

    // Backward compatibility for payloads using camelCase keys.
    private enum LegacyCodingKeys: String, CodingKey {
        case displayName
        case compatibilityType
        case maxContextLength
        case paramsString
        case sizeBytes
        case loadedInstances
    }

    private struct QuantizationInfo: Decodable {
        let name: String?
    }

    private struct LoadedInstance: Decodable {
        let id: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let key = try container.decodeIfPresent(String.self, forKey: .key), !key.isEmpty {
            id = key
        } else if let legacyID = try container.decodeIfPresent(String.self, forKey: .id), !legacyID.isEmpty {
            id = legacyID
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id,
                                                   in: container,
                                                   debugDescription: "Missing model identifier")
        }

        object = try container.decodeIfPresent(String.self, forKey: .object)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        displayName = try (container.decodeIfPresent(String.self, forKey: .displayName)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .displayName))
        architecture = try (container.decodeIfPresent(String.self, forKey: .architecture)
            ?? container.decodeIfPresent(String.self, forKey: .arch))
        compatibilityType = try (container.decodeIfPresent(String.self, forKey: .format)
            ?? container.decodeIfPresent(String.self, forKey: .compatibilityType)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .compatibilityType))

        if let quantInfo = (try? container.decode(QuantizationInfo.self, forKey: .quantization)),
           let quantName = quantInfo.name,
           !quantName.isEmpty {
            quantization = quantName
        } else {
            quantization = try? container.decode(String.self, forKey: .quantization)
        }

        let loadedInstances = try (container.decodeIfPresent([LoadedInstance].self, forKey: .loadedInstances)
            ?? legacyContainer.decodeIfPresent([LoadedInstance].self, forKey: .loadedInstances))
        if let loaded = loadedInstances {
            loadedInstancesCount = loaded.count
        } else {
            loadedInstancesCount = 0
        }

        let explicitState = try container.decodeIfPresent(String.self, forKey: .state)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitState, !explicitState.isEmpty {
            state = explicitState
        } else if loadedInstancesCount > 0 {
            state = "loaded"
        } else {
            state = nil
        }

        maxContextLength = try (container.decodeIfPresent(Int.self, forKey: .maxContextLength)
            ?? legacyContainer.decodeIfPresent(Int.self, forKey: .maxContextLength))
        paramsString = try (container.decodeIfPresent(String.self, forKey: .paramsString)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .paramsString))
        sizeBytes = try (container.decodeIfPresent(Int.self, forKey: .sizeBytes)
            ?? legacyContainer.decodeIfPresent(Int.self, forKey: .sizeBytes))
    }
}

struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let model: String
        let modifiedAt: String?
        let size: Int?
        let digest: String?
        let details: Details?

        struct Details: Decodable {
            let parentModel: String?
            let format: String?
            let family: String?
            let families: [String]?
            let parameterSize: String?
            let quantizationLevel: String?
        }
    }

    let models: [Model]
}

enum RemoteBackendError: LocalizedError {
    case invalidBaseURL
    case invalidEndpoint
    case invalidResponse
    case unexpectedStatus(Int, String)
    case decodingFailed
    case validationFailed(String)

    var errorDescription: String? {
        let locale = appLocale()
        switch self {
        case .invalidBaseURL:
            return String(localized: "The base URL looks invalid. Please include the host (e.g. http://127.0.0.1:1234).", locale: locale)
        case .invalidEndpoint:
            return String(localized: "Could not build the remote endpoint URL.", locale: locale)
        case .invalidResponse:
            return String(localized: "The server returned an unexpected response.", locale: locale)
        case .unexpectedStatus(let code, let body):
            if body.isEmpty {
                return String.localizedStringWithFormat(String(localized: "Server responded with status code %d.", locale: locale), code)
            }
            return String.localizedStringWithFormat(String(localized: "Server responded with status code %d: %@", locale: locale), code, body)
        case .decodingFailed:
            return String(localized: "Failed to decode server response.", locale: locale)
        case .validationFailed(let message):
            return message
        }
    }
}

enum RemoteBackendAPI {
    struct FetchModelsResult {
        let models: [RemoteModel]
        let statusCode: Int
        let reason: String?
        let relayEjectsOnDisconnect: Bool?
        let relayHostStatus: RelayHostStatus?
        let relayLANURL: String?
        let relayWiFiSSID: String?
        let relayAPIToken: String?
        let relayLANInterface: RelayLANInterface?
        let lanMetadataProvided: Bool
    }

    enum LMStudioDownloadStatus: String, Codable, Sendable {
        case downloading
        case paused
        case completed
        case failed
        case alreadyDownloaded = "already_downloaded"

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = (try? container.decode(String.self))?.lowercased() ?? ""
            switch rawValue {
            case "downloading":
                self = .downloading
            case "paused":
                self = .paused
            case "completed":
                self = .completed
            case "already_downloaded":
                self = .alreadyDownloaded
            case "failed":
                self = .failed
            default:
                self = .failed
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .alreadyDownloaded:
                return true
            case .downloading, .paused:
                return false
            }
        }
    }

    struct LMStudioDownloadJobStatus: Codable, Sendable {
        let jobID: String?
        let status: LMStudioDownloadStatus
        let bytesPerSecond: Double?
        let estimatedCompletion: String?
        let completedAt: String?
        let totalSizeBytes: Int64?
        let downloadedBytes: Int64?
        let startedAt: String?

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id"
            case status
            case bytesPerSecond = "bytes_per_second"
            case estimatedCompletion = "estimated_completion"
            case completedAt = "completed_at"
            case totalSizeBytes = "total_size_bytes"
            case downloadedBytes = "downloaded_bytes"
            case startedAt = "started_at"
        }

        var progress: Double? {
            guard let downloadedBytes, let totalSizeBytes, totalSizeBytes > 0 else { return nil }
            return min(1, max(0, Double(downloadedBytes) / Double(totalSizeBytes)))
        }
    }

    struct LMStudioDownloadRequest: Codable, Sendable {
        let model: String
        let quantization: String?
    }

    static func fetchModels(for backend: RemoteBackend) async throws -> FetchModelsResult {
        if backend.endpointType == .noemaRelay {
            return try await fetchNoemaRelayModels(for: backend)
        }
        if backend.isCloudRelay {
            return FetchModelsResult(models: backend.cachedModels,
                                     statusCode: 200,
                                     reason: "Relay",
                                     relayEjectsOnDisconnect: nil,
                                     relayHostStatus: nil,
                                     relayLANURL: nil,
                                     relayWiFiSSID: nil,
                                     relayAPIToken: nil,
                                     relayLANInterface: nil,
                                     lanMetadataProvided: false)
        }
        guard let endpoint = backend.modelsEndpointURL else { throw RemoteBackendError.invalidEndpoint }
        let localEndpoint = backend.usesLocalNetworkHost
        let requestTimeout: TimeInterval = localEndpoint ? 60 : 20
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = try backend.resolvedAuthorizationHeader(), !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        for (key, value) in backend.openRouterAttributionHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        await logger.log("[RemoteBackendAPI] ⇢ Fetch models request for backend=\(backend.name) type=\(backend.endpointType.rawValue) localEndpoint=\(localEndpoint)\n\(describe(request: request))")
        let (data, response): (Data, URLResponse)
        do {
            if localEndpoint {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = requestTimeout
                configuration.timeoutIntervalForResource = requestTimeout
                configuration.waitsForConnectivity = false
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.urlCache = nil
                configuration.connectionProxyDictionary = [AnyHashable: Any]()
                let session = URLSession(configuration: configuration)
                NetworkKillSwitch.track(session: session)
                defer { session.finishTasksAndInvalidate() }
                (data, response) = try await session.data(for: request)
            } else {
                NetworkKillSwitch.track(session: URLSession.shared)
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch {
            if backend.endpointType == .ollama {
                if let urlError = error as? URLError {
                    let cannotReachHost: Bool
                    switch urlError.code {
                    case .cannotConnectToHost, .networkConnectionLost, .timedOut, .notConnectedToInternet:
                        cannotReachHost = true
                    default:
                        cannotReachHost = false
                    }
                    if cannotReachHost {
                        let locale = appLocale()
                        let advisory: String
                        if backend.usesLoopbackHost {
                            advisory = String(localized: "Could not connect to Ollama at localhost. When connecting from another device, replace \"localhost\" with your computer's IP address or hostname and start Ollama with `OLLAMA_HOST=0.0.0.0` so it can accept remote connections.", locale: locale)
                        } else {
                            advisory = String.localizedStringWithFormat(
                                String(localized: "Could not connect to the Ollama server. Make sure Ollama is running on %@ and is configured to accept connections from this device (for example by launching it with `OLLAMA_HOST=0.0.0.0`).", locale: locale),
                                backend.displayBaseHost
                            )
                        }
                        await logger.log("[RemoteBackendAPI] ❌ Ollama connection advisory: \(advisory)")
                        throw RemoteBackendError.validationFailed(advisory)
                    }
                }
            }
            await logger.log("[RemoteBackendAPI] ❌ Fetch models request failed: \(error.localizedDescription)")
            throw RemoteBackendError.validationFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RemoteBackendError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = extractErrorMessage(from: data)
            await logger.log("[RemoteBackendAPI] ⚠️ Fetch models response status=\(http.statusCode)\nBody: \(body)")
            throw RemoteBackendError.unexpectedStatus(http.statusCode, body)
        }
        await logger.log("[RemoteBackendAPI] ⇠ Fetch models response status=\(http.statusCode) size=\(data.count)B\nBody: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
        let statusCode = http.statusCode
        let reason = RemoteBackend.normalizedStatusReason(for: statusCode)
        switch backend.endpointType {
        case .openRouter:
            let decoder = JSONDecoder()
            guard let response = try? decoder.decode(OpenRouterModelsResponse.self, from: data) else {
                await logger.log("[RemoteBackendAPI] ❌ Failed to decode OpenRouter models response")
                throw RemoteBackendError.decodingFailed
            }
            let models = response.data
                .map(RemoteModel.make)
                .filter { !$0.isEmbedding }
            await logger.log("[RemoteBackendAPI] ✅ Decoded \(models.count) OpenRouter models")
            return FetchModelsResult(models: models,
                                     statusCode: statusCode,
                                     reason: reason,
                                     relayEjectsOnDisconnect: nil,
                                     relayHostStatus: nil,
                                     relayLANURL: nil,
                                     relayWiFiSSID: nil,
                                     relayAPIToken: nil,
                                     relayLANInterface: nil,
                                     lanMetadataProvided: false)
        case .lmStudio:
            let decoder = JSONDecoder()
            guard let response = try? decoder.decode(LMStudioModelsResponse.self, from: data) else {
                await logger.log("[RemoteBackendAPI] ❌ Failed to decode LM Studio models response")
                throw RemoteBackendError.decodingFailed
            }
            let models = response.models
                .map(RemoteModel.make)
                .filter { !$0.isEmbedding }
            await logger.log("[RemoteBackendAPI] ✅ Decoded \(models.count) LM Studio models")
                return FetchModelsResult(models: models,
                                         statusCode: statusCode,
                                         reason: reason,
                                         relayEjectsOnDisconnect: nil,
                                         relayHostStatus: nil,
                                         relayLANURL: nil,
                                         relayWiFiSSID: nil,
                                         relayAPIToken: nil,
                                         relayLANInterface: nil,
                                         lanMetadataProvided: false)
        case .ollama:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let response = try? decoder.decode(OllamaTagsResponse.self, from: data) else {
                await logger.log("[RemoteBackendAPI] ❌ Failed to decode Ollama tags response")
                throw RemoteBackendError.decodingFailed
            }
            let models = response.models
                .map(RemoteModel.make)
                .filter { !$0.isEmbedding }
            await logger.log("[RemoteBackendAPI] ✅ Decoded \(models.count) Ollama models")
            return FetchModelsResult(models: models,
                                     statusCode: statusCode,
                                     reason: reason,
                                     relayEjectsOnDisconnect: nil,
                                     relayHostStatus: nil,
                                     relayLANURL: nil,
                                     relayWiFiSSID: nil,
                                     relayAPIToken: nil,
                                     relayLANInterface: nil,
                                     lanMetadataProvided: false)
        case .openAI:
            let decoder = JSONDecoder()
            guard let response = try? decoder.decode(OpenAIModelsResponse.self, from: data) else {
                await logger.log("[RemoteBackendAPI] ❌ Failed to decode OpenAI models response")
                throw RemoteBackendError.decodingFailed
            }
            let models = response.data
                .map(RemoteModel.make)
                .filter { !$0.isEmbedding }
            await logger.log("[RemoteBackendAPI] ✅ Decoded \(models.count) OpenAI models")
            return FetchModelsResult(models: models,
                                     statusCode: statusCode,
                                     reason: reason,
                                     relayEjectsOnDisconnect: nil,
                                     relayHostStatus: nil,
                                     relayLANURL: nil,
                                     relayWiFiSSID: nil,
                                     relayAPIToken: nil,
                                     relayLANInterface: nil,
                                     lanMetadataProvided: false)
        case .cloudRelay:
            await logger.log("[RemoteBackendAPI] ✅ Using cached models for Noema Cloud Relay backend")
            return FetchModelsResult(models: backend.cachedModels,
                                     statusCode: statusCode,
                                     reason: reason,
                                     relayEjectsOnDisconnect: nil,
                                     relayHostStatus: nil,
                                     relayLANURL: nil,
                                     relayWiFiSSID: nil,
                                     relayAPIToken: nil,
                                     relayLANInterface: nil,
                                     lanMetadataProvided: false)
        case .noemaRelay:
            await logger.log("[RemoteBackendAPI] ✅ Using cached models for Noema Relay backend")
            return FetchModelsResult(models: backend.cachedModels,
                                     statusCode: statusCode,
                                     reason: reason,
                                     relayEjectsOnDisconnect: nil,
                                     relayHostStatus: nil,
                                     relayLANURL: nil,
                                     relayWiFiSSID: nil,
                                     relayAPIToken: nil,
                                     relayLANInterface: nil,
                                     lanMetadataProvided: false)
        }
    }

    static func verifyOpenRouterAPIKey(_ apiKey: String,
                                       backendID: RemoteBackend.ID? = nil) async throws -> OpenRouterKeyInfo {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteBackendError.validationFailed(String(localized: "Please provide an OpenRouter API key.", locale: appLocale()))
        }
        guard let url = URL(string: "/api/v1/key", relativeTo: RemoteBackend.openRouterDefaultBaseURL)?.absoluteURL else {
            throw RemoteBackendError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if trimmed.lowercased().hasPrefix("bearer ") {
            request.setValue(trimmed, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(RemoteBackend.openRouterReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(RemoteBackend.openRouterTitle, forHTTPHeaderField: "X-OpenRouter-Title")

        await logger.log("[RemoteBackendAPI] ⇢ Verifying OpenRouter API key backendID=\(backendID?.uuidString ?? "new")\n\(describe(request: request))")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteBackendError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data)
            await logger.log("[RemoteBackendAPI] ⚠️ OpenRouter key verification failed status=\(http.statusCode)\nBody: \(message)")
            throw RemoteBackendError.unexpectedStatus(http.statusCode, message)
        }

        guard let decoded = try? JSONDecoder().decode(OpenRouterKeyResponse.self, from: data) else {
            await logger.log("[RemoteBackendAPI] ❌ Failed to decode OpenRouter key response")
            throw RemoteBackendError.decodingFailed
        }
        await logger.log("[RemoteBackendAPI] ✅ Verified OpenRouter API key label=\(decoded.data.label)")
        return decoded.data
    }

    private static func fetchNoemaRelayModels(for backend: RemoteBackend) async throws -> FetchModelsResult {
#if os(iOS) || os(visionOS)
        // iOS fast path: ask the Mac via CloudKit conversation for the exposed models,
        // then augment with LAN metadata by reading the catalog snapshot (capabilities).
        if let containerID = backend.cloudKitContainerIdentifier,
           let hostDeviceID = backend.relayHostDeviceID,
           !containerID.isEmpty {
            await logger.log("[RemoteBackendAPI] ⇢ Requesting Noema Relay catalog via CloudKit conversation")
            let outbox = RelayOutbox()
            var parameters: [String: String] = [
                "backend": backend.endpointType.rawValue,
                "backendName": backend.name,
                "relayAction": "catalog",
                "hostDeviceID": hostDeviceID,
                "transport": "cloud"
            ]
            parameters.merge(RemoteBackend.clientIdentityParameters()) { current, _ in current }
            var conversationModels: [RemoteModel]? = nil
            do {
                let envelope = try await outbox.sendAndAwaitReply(
                    containerID: containerID,
                    conversationID: UUID(),
                    history: [(role: "system", text: "noema-relay catalog request", fullText: "noema-relay catalog request")],
                    parameters: parameters
                )
                if let assistant = envelope.messages.last(where: { $0.role.lowercased() == "assistant" }) {
                    let data = Data(assistant.text.utf8)
                    let decoder = JSONDecoder()
                    let response = try decoder.decode(RelayCatalogResponsePayload.self, from: data)
                    conversationModels = response.models.map { makeRemoteModel(from: $0) }
                    await logger.log("[RemoteBackendAPI] ✅ Received \(conversationModels?.count ?? 0) model(s) from Noema Relay conversation")
                } else {
                    await logger.log("[RemoteBackendAPI] ❌ No assistant reply found in Noema Relay catalog response")
                }
            } catch {
                await logger.log("[RemoteBackendAPI] ❌ CloudKit conversation catalog request failed: \(error.localizedDescription)")
            }

            // Regardless of whether the conversation succeeded, attempt to read the
            // catalog snapshot to obtain capabilities like lanURL, wifiSSID, apiToken.
            do {
                let snapshot = try await RelayCatalogClient.shared.fetchCatalog(containerIdentifier: containerID,
                                                                                hostDeviceID: hostDeviceID)
                let records = snapshot.models.filter { $0.exposed }
                let snapshotModels = records.map { makeRemoteModel(from: $0) }
                let models = conversationModels ?? snapshotModels
                let reason = snapshot.device?.name ?? backend.name
                let ejectPreference = parseBooleanCapability(snapshot.device?.capabilities["ejectsOnDisconnect"]) ?? backend.relayEjectsOnDisconnect
                let hostStatus = snapshot.hostState?.status
                let capabilities = snapshot.device?.capabilities ?? [:]
                await logger.log("[RemoteBackendAPI] [LAN] Capabilities snapshot for \(backend.name): \(capabilities)")
                let lanURL = parseStringCapability(capabilities["lanURL"])
                let wifiSSID = parseStringCapability(capabilities["wifiSSID"])
                let apiToken = parseStringCapability(capabilities["apiToken"])
                let interface: RelayLANInterface?
                if let wifiSSID, !wifiSSID.isEmpty {
                    interface = .wifi
                } else if lanURL != nil {
                    interface = .ethernet
                } else {
                    interface = nil
                }
                await logger.log("[RemoteBackendAPI] ✅ Retrieved \(models.count) model(s) with LAN metadata from Relay catalog")
                return FetchModelsResult(models: models,
                                         statusCode: 200,
                                         reason: reason,
                                         relayEjectsOnDisconnect: ejectPreference,
                                         relayHostStatus: hostStatus,
                                         relayLANURL: lanURL,
                                         relayWiFiSSID: wifiSSID,
                                         relayAPIToken: apiToken,
                                         relayLANInterface: interface,
                                         lanMetadataProvided: capabilities["lanURL"] != nil || capabilities["wifiSSID"] != nil)
            } catch {
                // If the catalog snapshot isn't available yet, fall back to the conversation result
                // without LAN metadata to avoid failing the entire refresh.
                if let models = conversationModels {
                    await logger.log("[RemoteBackendAPI] ⚠️ Relay catalog snapshot unavailable (\(error.localizedDescription)); using conversation models without LAN metadata")
                    return FetchModelsResult(models: models,
                                             statusCode: 200,
                                             reason: backend.name,
                                             relayEjectsOnDisconnect: backend.relayEjectsOnDisconnect,
                                             relayHostStatus: nil,
                                             relayLANURL: nil,
                                             relayWiFiSSID: nil,
                                             relayAPIToken: nil,
                                             relayLANInterface: nil,
                                             lanMetadataProvided: false)
                }
                // Otherwise drop through to the cross‑platform path below.
            }
        }
#endif
        guard let rawHostDeviceID = backend.relayHostDeviceID else {
            throw RemoteBackendError.validationFailed(String(localized: "Missing host device ID for Noema Relay.", locale: appLocale()))
        }
        let hostDeviceID = rawHostDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostDeviceID.isEmpty else {
            throw RemoteBackendError.validationFailed(String(localized: "Missing host device ID for Noema Relay.", locale: appLocale()))
        }
        let containerID = backend.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerID.isEmpty else {
            throw RemoteBackendError.validationFailed(String(localized: "Missing CloudKit container identifier.", locale: appLocale()))
        }
        // A refresh nudges the host to republish, but it's only an optimization:
        // if the command times out or the host is momentarily offline we still
        // serve whatever snapshot was last published rather than failing the
        // whole model list.
        do {
            try await requestRelayCatalogRefreshIfNeeded(for: backend,
                                                         containerID: containerID,
                                                         hostDeviceID: hostDeviceID)
        } catch {
            await logger.log("[RemoteBackendAPI] ⚠️ Relay catalog refresh request failed (\(error.localizedDescription)); falling back to last published snapshot")
        }
        await logger.log("[RemoteBackendAPI] ⇢ Fetching Noema Relay catalog for backend=\(backend.name)")
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                let snapshot = try await RelayCatalogClient.shared.fetchCatalog(containerIdentifier: containerID,
                                                                                hostDeviceID: hostDeviceID)
                let records = snapshot.models.filter { $0.exposed }
                let models = records.map { makeRemoteModel(from: $0) }
                let reason = snapshot.device?.name ?? "Relay Catalog"
                let ejectPreference = parseBooleanCapability(snapshot.device?.capabilities["ejectsOnDisconnect"])
                let hostStatus = snapshot.hostState?.status
                let capabilities = snapshot.device?.capabilities ?? [:]
                let lanURL = parseStringCapability(capabilities["lanURL"])
                let wifiSSID = parseStringCapability(capabilities["wifiSSID"])
                let apiToken = parseStringCapability(capabilities["apiToken"])
                let interface: RelayLANInterface?
                if let wifiSSID, !wifiSSID.isEmpty {
                    interface = .wifi
                } else if lanURL != nil {
                    interface = .ethernet
                } else {
                    interface = nil
                }
                await logger.log("[RemoteBackendAPI] ✅ Retrieved \(models.count) models from Noema Relay catalog")
                return FetchModelsResult(models: models,
                                         statusCode: 200,
                                         reason: reason,
                                         relayEjectsOnDisconnect: ejectPreference,
                                         relayHostStatus: hostStatus,
                                         relayLANURL: lanURL,
                                         relayWiFiSSID: wifiSSID,
                                         relayAPIToken: apiToken,
                                         relayLANInterface: interface,
                                         lanMetadataProvided: capabilities["lanURL"] != nil || capabilities["wifiSSID"] != nil)
            } catch {
                lastError = error
                let friendlyMessage = relayCatalogErrorMessage(from: error)
                await logger.log("[RemoteBackendAPI] ❌ Relay catalog fetch attempt \(attempt + 1) failed: \(error.localizedDescription)")
                if shouldRetryRelayCatalogFetch(error), attempt < maxAttempts - 1 {
                    let delay = UInt64(Double(attempt + 1) * 0.8 * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                    continue
                }
                throw RemoteBackendError.validationFailed(friendlyMessage)
            }
        }
        let fallbackMessage = relayCatalogErrorMessage(from: lastError ?? RemoteBackendError.validationFailed(String(localized: "Relay catalog unavailable.", locale: appLocale())))
        throw RemoteBackendError.validationFailed(fallbackMessage)
    }

    private static func requestRelayCatalogRefreshIfNeeded(for backend: RemoteBackend,
                                                           containerID: String,
                                                           hostDeviceID: String) async throws {
        await logger.log("[RemoteBackendAPI] ⇢ Requesting relay catalog refresh for backend=\(backend.name)")
        let command = try await RelayCatalogClient.shared.createCommand(containerIdentifier: containerID,
                                                                        hostDeviceID: hostDeviceID,
                                                                        verb: "POST",
                                                                        path: "/catalog/refresh",
                                                                        body: nil)
        let result = try await RelayCatalogClient.shared.waitForCommand(containerIdentifier: containerID,
                                                                        commandID: command.recordID,
                                                                        timeout: 90)
        guard result.state == .succeeded else {
            let message = relayCommandFailureMessage(from: result.result) ?? "Relay catalog refresh failed."
            await logger.log("[RemoteBackendAPI] ❌ Relay catalog refresh failed: \(message)")
            throw RemoteBackendError.validationFailed(message)
        }
        await logger.log("[RemoteBackendAPI] ✅ Relay catalog refresh complete")
    }

    private static func relayCommandFailureMessage(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["error"] as? String else {
            return nil
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseBooleanCapability(_ value: String?) -> Bool? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lowered = raw.lowercased()
        if ["true", "yes", "1", "on"].contains(lowered) { return true }
        if ["false", "no", "0", "off"].contains(lowered) { return false }
        return nil
    }

    private static func parseStringCapability(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func shouldRetryRelayCatalogFetch(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        switch ckError.code {
        case .unknownItem, .serverRejectedRequest, .zoneNotFound:
            return containsRecordTypeMissingMessage(ckError)
        case .partialFailure:
            if let partials = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                return partials.values.contains { shouldRetryRelayCatalogFetch($0) }
            }
            return false
        case .requestRateLimited, .networkUnavailable, .serviceUnavailable, .networkFailure:
            return true
        default:
            return false
        }
    }

    private static func relayCatalogErrorMessage(from error: Error) -> String {
        let locale = appLocale()
        if let backendError = error as? RemoteBackendError {
            return backendError.errorDescription ?? String(localized: "Relay catalog unavailable.", locale: locale)
        }
        if let ckError = error as? CKError, containsRecordTypeMissingMessage(ckError) {
            return String(localized: "Relay catalog is still syncing. Open the Mac relay, ensure it is signed into iCloud, then try again in a moment.", locale: locale)
        }
        let nsError = error as NSError
        if let reason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            return reason
        }
        return error.localizedDescription
    }

    private static func containsRecordTypeMissingMessage(_ error: Error) -> Bool {
        let nsError = error as NSError
        let messages = [
            nsError.userInfo[NSLocalizedDescriptionKey] as? String,
            nsError.userInfo["CKErrorLocalizedDescriptionKey"] as? String,
            nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String
        ]
        return messages
            .compactMap { $0?.lowercased() }
            .contains { message in
                message.contains("did not find record type") || message.contains("record type: model")
            }
    }

    private static func makeRemoteModel(from record: RelayModelRecord) -> RemoteModel {
        let fileSize = record.sizeBytes.flatMap { Int($0) }
        let families = record.tags.isEmpty ? nil : record.tags
        return RemoteModel(id: record.identifier,
                           name: record.displayName,
                           author: record.provider.displayName,
                           owner: record.provider.rawValue,
                           type: record.provider.rawValue,
                           publisher: record.provider.displayName,
                           architecture: nil,
                           compatibilityType: record.provider.rawValue,
                           quantization: record.quant,
                           state: record.health.rawValue,
                           maxContextLength: record.context,
                           isCustom: false,
                           families: families,
                           parameterSize: nil,
                           fileSizeBytes: fileSize,
                           digest: nil,
                           parentModel: nil,
                           modifiedAt: record.lastChecked,
                           modifiedAtRaw: nil,
                           relayRecordName: record.recordID.recordName)
    }

#if os(iOS) || os(visionOS)
    private struct RelayCatalogResponsePayload: Decodable {
        struct Model: Decodable {
            let modelID: String
            let identifier: String
            let displayName: String
            let provider: String
            let providerDisplayName: String
            let endpointID: String?
            let context: Int?
            let quant: String?
            let sizeBytes: Int?
            let tags: [String]
            let health: String
            let recordName: String
        }

        let models: [Model]
    }

    private static func makeRemoteModel(from payload: RelayCatalogResponsePayload.Model) -> RemoteModel {
        let families = payload.tags.isEmpty ? nil : payload.tags
        return RemoteModel(id: payload.identifier,
                           name: payload.displayName,
                           author: payload.providerDisplayName,
                           owner: payload.provider,
                           type: payload.provider,
                           publisher: payload.providerDisplayName,
                           architecture: nil,
                           compatibilityType: payload.provider,
                           quantization: payload.quant,
                           state: payload.health,
                           maxContextLength: payload.context,
                           isCustom: false,
                           families: families,
                           parameterSize: nil,
                           fileSizeBytes: payload.sizeBytes,
                           digest: nil,
                           parentModel: nil,
                           modifiedAt: nil,
                           modifiedAtRaw: nil,
                           relayRecordName: payload.recordName)
    }
#endif

    static func requestLoad(for backend: RemoteBackend, modelID: String, settings: ModelSettings? = nil) async throws {
        if backend.isCloudRelay {
            return
        }
        if backend.endpointType == .ollama {
            try await requestOllamaLoad(for: backend, modelID: modelID)
            return
        }

        let normalizedModelID = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if backend.endpointType == .lmStudio && !normalizedModelID.isEmpty {
            do {
                let models = try await fetchModels(for: backend).models
                let alreadyLoaded = models.contains { candidate in
                    candidate.id
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == normalizedModelID && candidate.isLoadedOnBackend
                }
                if alreadyLoaded {
                    await logger.log("[RemoteBackendAPI] ↩︎ Skipping load request for '\(modelID)' because LM Studio already reports it as loaded.")
                    return
                }
            } catch {
                await logger.log("[RemoteBackendAPI] ℹ️ Could not verify existing LM Studio loaded instance before load: \(error.localizedDescription)")
            }
        }

        let candidates = backend.loadPathCandidates(for: modelID)
        var lastError: Error = RemoteBackendError.invalidEndpoint
        for path in candidates {
            guard let url = backend.absoluteURL(for: path) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let auth = try backend.resolvedAuthorizationHeader(), !auth.isEmpty {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
            for (key, value) in backend.openRouterAttributionHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            var payload: [String: Any] = ["model": modelID]
            if backend.endpointType == .lmStudio, let settings {
                payload["context_length"] = max(1, Int(settings.contextLength.rounded()))
                payload["flash_attention"] = settings.flashAttention
                payload["offload_kv_cache_to_gpu"] = settings.kvCacheOffload
                if let experts = settings.moeActiveExperts, experts > 0 {
                    payload["num_experts"] = experts
                }
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])
            await logger.log("[RemoteBackendAPI] ⇢ Requesting load for model=\(modelID) backend=\(backend.name) path=\(path)\n\(describe(request: request))")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw RemoteBackendError.invalidResponse }
                guard (200...299).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    await logger.log("[RemoteBackendAPI] ⚠️ Load request failed status=\(http.statusCode) path=\(path)\nBody: \(body)")
                    lastError = RemoteBackendError.unexpectedStatus(http.statusCode, body)
                    continue
                }
                await logger.log("[RemoteBackendAPI] ⇠ Load request succeeded status=\(http.statusCode) path=\(path)")
                return
            } catch {
                await logger.log("[RemoteBackendAPI] ❌ Load request error path=\(path): \(error.localizedDescription)")
                lastError = error
                continue
            }
        }
        if let backendError = lastError as? RemoteBackendError {
            throw backendError
        } else {
            throw RemoteBackendError.validationFailed(lastError.localizedDescription)
        }
    }

    static func startLMStudioDownload(for backend: RemoteBackend,
                                      model: String,
                                      quantization: String?) async throws -> LMStudioDownloadJobStatus {
        guard backend.endpointType == .lmStudio else {
            throw RemoteBackendError.validationFailed(String(localized: "Remote model downloads are only supported for LM Studio endpoints.", locale: appLocale()))
        }
        guard let url = backend.absoluteURL(for: "/api/v1/models/download") else {
            throw RemoteBackendError.invalidEndpoint
        }

        let payload = LMStudioDownloadRequest(model: model, quantization: quantization)
        let body = try JSONEncoder().encode(payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = try backend.resolvedAuthorizationHeader(), !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        for (key, value) in backend.openRouterAttributionHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        await logger.log("[RemoteBackendAPI] ⇢ Requesting LM Studio download backend=\(backend.name)\n\(describe(request: request))")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteBackendError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data)
            await logger.log("[RemoteBackendAPI] ⚠️ LM Studio download request failed status=\(http.statusCode)\nBody: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
            throw RemoteBackendError.unexpectedStatus(http.statusCode, message)
        }

        await logger.log("[RemoteBackendAPI] ⇠ LM Studio download request status=\(http.statusCode)\nBody: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
        do {
            let status = try JSONDecoder().decode(LMStudioDownloadJobStatus.self, from: data)
            return status
        } catch {
            throw RemoteBackendError.decodingFailed
        }
    }

    static func fetchLMStudioDownloadStatus(for backend: RemoteBackend,
                                            jobID: String) async throws -> LMStudioDownloadJobStatus {
        guard backend.endpointType == .lmStudio else {
            throw RemoteBackendError.validationFailed(String(localized: "Remote model downloads are only supported for LM Studio endpoints.", locale: appLocale()))
        }
        let encodedJobID = jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobID
        guard let url = backend.absoluteURL(for: "/api/v1/models/download/status/\(encodedJobID)") else {
            throw RemoteBackendError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = try backend.resolvedAuthorizationHeader(), !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        for (key, value) in backend.openRouterAttributionHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        await logger.log("[RemoteBackendAPI] ⇢ Requesting LM Studio download status backend=\(backend.name) job=\(jobID)\n\(describe(request: request))")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteBackendError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data)
            await logger.log("[RemoteBackendAPI] ⚠️ LM Studio download status failed status=\(http.statusCode)\nBody: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
            throw RemoteBackendError.unexpectedStatus(http.statusCode, message)
        }
        await logger.log("[RemoteBackendAPI] ⇠ LM Studio download status response status=\(http.statusCode)\nBody: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")

        do {
            let status = try JSONDecoder().decode(LMStudioDownloadJobStatus.self, from: data)
            return status
        } catch {
            throw RemoteBackendError.decodingFailed
        }
    }

    private static func requestOllamaLoad(for backend: RemoteBackend, modelID: String) async throws {
        guard let url = backend.absoluteURL(for: "/api/generate") else {
            throw RemoteBackendError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = try backend.resolvedAuthorizationHeader(), !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        for (key, value) in backend.openRouterAttributionHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let payload: [String: Any] = [
            "model": modelID,
            "prompt": "",
            "stream": false,
            "keep_alive": "5m"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        await logger.log("[RemoteBackendAPI] ⇢ Requesting Ollama load for model=\(modelID) backend=\(backend.name)\n\(describe(request: request))")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteBackendError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            await logger.log("[RemoteBackendAPI] ⚠️ Ollama load failed status=\(http.statusCode)\nBody: \(body)")
            throw RemoteBackendError.unexpectedStatus(http.statusCode, body)
        }
        await logger.log("[RemoteBackendAPI] ⇠ Ollama load succeeded status=\(http.statusCode)")
    }

    private static func describe(request: URLRequest) -> String {
        let method = request.httpMethod ?? "<unknown>"
        let urlString = request.url?.absoluteString ?? "<no url>"
        let headers = sanitizedHeaders(from: request.allHTTPHeaderFields)
        let headerLines = headers.map { "\($0): \($1)" }.sorted().joined(separator: "\n")
        let body: String
        if let data = request.httpBody, !data.isEmpty {
            body = String(data: data, encoding: .utf8) ?? "<binary body size=\(data.count)>"
        } else {
            body = "<empty>"
        }
        return "\(method) \(urlString)\nHeaders:\n\(headerLines.isEmpty ? "<none>" : headerLines)\nBody:\n\(body)"
    }

    private static func sanitizedHeaders(from headers: [String: String]?) -> [String: String] {
        guard let headers else { return [:] }
        var sanitized: [String: String] = [:]
        for (key, value) in headers {
            if key.caseInsensitiveCompare("Authorization") == .orderedSame {
                sanitized[key] = "<redacted>"
            } else {
                sanitized[key] = value
            }
        }
        return sanitized
    }

    private static func extractErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
           let dictionary = json as? [String: Any] {
            if let message = dictionary["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let error = dictionary["error"] as? String,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return error
            }
            if let error = dictionary["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

#if os(iOS) || os(visionOS)
private extension RemoteBackend {
    static func clientIdentityParameters() -> [String: String] {
#if canImport(UIKit)
        let device = UIDevice.current
        let name = device.name
        let model = device.model
        let idiom = device.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let platform = "\(idiom) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let identifier = SystemTimeProvider().currentIDFV() ?? UUID().uuidString
        return [
            "clientId": identifier,
            "clientName": name,
            "clientModel": model,
            "clientPlatform": platform
        ]
#else
        return [:]
#endif
    }
}
#else
private extension RemoteBackend {
    static func clientIdentityParameters() -> [String: String] { [:] }
}
#endif

enum RemoteBackendsStore {
    private static let storageKey = "remoteBackends.v1"

    static func load() -> [RemoteBackend] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([RemoteBackend].self, from: data) {
            return decoded
        }
        return []
    }

    static func save(_ backends: [RemoteBackend]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(backends) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

enum RemoteBackendCredentialStore {
    private static let service = "Noema.RemoteBackendCredentials"

    static func openRouterAPIKey(for backendID: RemoteBackend.ID) throws -> String? {
        guard let data = try KeychainStore.read(service: service, account: openRouterAccount(for: backendID)),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func setOpenRouterAPIKey(_ apiKey: String, for backendID: RemoteBackend.ID) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = try KeychainStore.delete(service: service, account: openRouterAccount(for: backendID))
            return
        }
        guard let data = trimmed.data(using: .utf8) else { return }
        try KeychainStore.write(service: service, account: openRouterAccount(for: backendID), data: data)
    }

    @discardableResult
    static func removeOpenRouterAPIKey(for backendID: RemoteBackend.ID) throws -> Bool {
        try KeychainStore.delete(service: service, account: openRouterAccount(for: backendID))
    }

    static func openRouterAuthorizationHeader(for backendID: RemoteBackend.ID) throws -> String? {
        guard let key = try openRouterAPIKey(for: backendID) else { return nil }
        if key.lowercased().hasPrefix("bearer ") {
            return key
        }
        return "Bearer \(key)"
    }

    private static func openRouterAccount(for backendID: RemoteBackend.ID) -> String {
        "remote-backend.openrouter.\(backendID.uuidString).apiKey"
    }
}

struct RemoteBackendDraft {
    var name: String = ""
    var baseURL: String = ""
    var endpointType: RemoteBackend.EndpointType = .openAI
    var chatPath: String
    var modelsPath: String
    var authHeader: String = ""
    var openRouterAPIKey: String = ""
    var customModelIDs: [String] = [""]
    var relayHostDeviceID: String = ""
    var relayLANURL: String = ""
    var relayAPIToken: String = ""
    var relayWiFiSSID: String = ""

    init() {
        chatPath = endpointType.defaultChatPath
        modelsPath = endpointType.defaultModelsPath
    }

    init(from backend: RemoteBackend) {
        name = backend.name
        baseURL = backend.baseURLString
        chatPath = backend.chatPath
        modelsPath = backend.modelsPath
        authHeader = backend.authHeader ?? ""
        openRouterAPIKey = (try? RemoteBackendCredentialStore.openRouterAPIKey(for: backend.id)) ?? ""
        customModelIDs = backend.customModelIDs.isEmpty ? [""] : backend.customModelIDs
        endpointType = backend.endpointType
        relayHostDeviceID = backend.relayHostDeviceID ?? ""
        relayLANURL = backend.relayLANURLString ?? ""
        relayAPIToken = backend.relayAPIToken ?? ""
        relayWiFiSSID = backend.relayWiFiSSID ?? ""
    }

    func validatedBaseURL() -> URL? {
        if endpointType.isRelay {
            return nil
        }
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        if trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }

    var usesLoopbackHost: Bool {
        if endpointType.isRelay { return false }
        guard let host = validatedBaseURL()?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

extension RemoteBackendDraft {
    var sanitizedCustomModelIDs: [String] {
        RemoteBackend.normalize(customModelIDs)
    }

    mutating func appendCustomModelSlot() {
        customModelIDs.append("")
    }

    mutating func removeCustomModel(at index: Int) {
        guard customModelIDs.indices.contains(index) else { return }
        customModelIDs.remove(at: index)
        if customModelIDs.isEmpty {
            customModelIDs = [""]
        }
    }
}

extension RemoteBackend {
    func updating(from draft: RemoteBackendDraft) throws -> RemoteBackend {
        var updated = try RemoteBackend(from: draft)
        updated.id = id
        updated.cachedModels = cachedModels
        updated.lastFetched = lastFetched
        updated.lastError = lastError
        updated.lastConnectionSummary = lastConnectionSummary
        updated.relayEjectsOnDisconnect = relayEjectsOnDisconnect
        if relayLANInterface != nil && updated.relayLANInterface == nil {
            updated.relayLANInterface = relayLANInterface
        }
        return updated
    }
}

enum RemoteSessionTransport: Equatable {
    case cloudRelay
    case lan(ssid: String)
    case direct

    var label: String {
        let locale = appLocale()
        switch self {
        case .cloudRelay:
            return String(localized: "Cloud Relay", locale: locale)
        case .lan(let ssid):
            if ssid.isEmpty {
                return String(localized: "Local Network", locale: locale)
            }
            return String.localizedStringWithFormat(String(localized: "LAN · %@", locale: locale), ssid)
        case .direct:
            return String(localized: "Direct", locale: locale)
        }
    }

    var symbolName: String {
        switch self {
        case .cloudRelay:
            return "icloud"
        case .lan:
            return "wifi.router"
        case .direct:
            return "bolt.horizontal"
        }
    }
}

struct ActiveRemoteSession: Equatable {
    let backendID: RemoteBackend.ID
    let backendName: String
    let modelID: String
    let modelName: String
    let endpointType: RemoteBackend.EndpointType
    var transport: RemoteSessionTransport
    var streamingEnabled: Bool
}

private struct LinkedHashSet<Element: Hashable>: Sequence {
    private var ordered: [Element] = []
    private var seen: Set<Element> = []

    init(_ elements: [Element]) {
        for element in elements {
            if !seen.contains(element) {
                seen.insert(element)
                ordered.append(element)
            }
        }
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        ordered.makeIterator()
    }

    var array: [Element] { ordered }
}

private extension Array where Element: Hashable {
    init(_ set: LinkedHashSet<Element>) {
        self = set.array
    }
}

private extension CharacterSet {
    static let remoteModelIDAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.@")
        return set
    }()
}
