import Foundation

public enum RelayStatus: String, Codable, Sendable {
    case pending
    case acknowledged
    case processing
    case completed
    case failed
}

public struct RelayMessage: Codable, Equatable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let role: String
    public let text: String
    public let fullText: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: String,
        text: String,
        fullText: String? = nil,
        createdAt: Date = .init()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.fullText = fullText
        self.createdAt = createdAt
    }

    public static func visibleText(from text: String) -> String {
        guard text.contains("<think>") else {
            return text
        }
        let pattern = "<think>[\\s\\S]*?</think>"
        let range = NSRange(text.startIndex..., in: text)
        var sanitized = text
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "")
        }
        sanitized = sanitized.replacingOccurrences(of: "<think>", with: "")
        sanitized = sanitized.replacingOccurrences(of: "</think>", with: "")
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RelayEnvelope: Codable, Sendable {
    public let conversationID: UUID
    public let messages: [RelayMessage]
    public let needsResponse: Bool
    public let parameters: [String: String]
    public let status: RelayStatus
    public let statusUpdatedAt: Date?
    public let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case conversationID
        case messages
        case needsResponse
        case parameters
        case status
        case statusUpdatedAt
        case errorMessage
    }

    public init(
        conversationID: UUID,
        messages: [RelayMessage],
        needsResponse: Bool,
        parameters: [String: String],
        status: RelayStatus = .pending,
        statusUpdatedAt: Date? = Date(),
        errorMessage: String? = nil
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.needsResponse = needsResponse
        self.parameters = parameters
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.errorMessage = errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try container.decode(UUID.self, forKey: .conversationID)
        messages = try container.decode([RelayMessage].self, forKey: .messages)
        needsResponse = try container.decode(Bool.self, forKey: .needsResponse)
        parameters = try container.decode([String: String].self, forKey: .parameters)
        status = try container.decodeIfPresent(RelayStatus.self, forKey: .status) ?? .pending
        statusUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .statusUpdatedAt)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

public protocol InferenceProvider: Sendable {
    func generateReply(for envelope: RelayEnvelope) async throws -> String

    /// Streaming variant: produces the same final reply as `generateReply` but
    /// invokes `onPartial` with the accumulated text as it is generated, so the
    /// transport can surface incremental progress. Providers that cannot stream
    /// fall back to the default implementation, which simply returns the full
    /// reply once.
    func generateReplyStreaming(
        for envelope: RelayEnvelope,
        onPartial: @Sendable @escaping (String) async -> Void
    ) async throws -> String
}

public extension InferenceProvider {
    func generateReplyStreaming(
        for envelope: RelayEnvelope,
        onPartial: @Sendable @escaping (String) async -> Void
    ) async throws -> String {
        try await generateReply(for: envelope)
    }
}

public enum InferenceError: Error {
    case notConfigured
    case network(String)
    case decode
    case other(String)
}
