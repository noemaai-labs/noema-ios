import Foundation

public enum RelayStatus: String, Codable, Equatable, Sendable {
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
        var sanitized = text

        // Remove complete reasoning blocks first, then hide any unfinished
        // block at the end of a streaming partial. Matching is case-insensitive
        // because remote backends do not consistently preserve tag casing.
        for pattern in [#"<think>[\s\S]*?</think>"#, #"<think>[\s\S]*$"#] {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) else { continue }
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        if let tagRegex = try? NSRegularExpression(pattern: #"</?think>"#, options: [.caseInsensitive]) {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = tagRegex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: ""
            )
        }
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

extension RelayEnvelope {
    /// Builds a partial streaming update without discarding inbound turns that
    /// arrived after generation began. Prior partial assistant messages are
    /// replaced by the latest accumulated partial.
    static func streamingPartial(
        base: RelayEnvelope,
        latest: RelayEnvelope?,
        partial: String,
        timestamp: Date
    ) -> RelayEnvelope {
        let assistant = RelayMessage(
            conversationID: base.conversationID,
            role: "assistant",
            text: RelayMessage.visibleText(from: partial),
            fullText: partial,
            createdAt: timestamp
        )

        var messages = base.messages + [assistant]
        var seenIdentifiers = Set(base.messages.map(\.id))
        seenIdentifiers.insert(assistant.id)

        if let latest {
            let inboundSuffix = latest.messages.filter {
                !seenIdentifiers.contains($0.id) && $0.role.lowercased() != "assistant"
            }
            messages.append(contentsOf: inboundSuffix)
        }

        return RelayEnvelope(
            conversationID: base.conversationID,
            messages: messages,
            needsResponse: true,
            parameters: latest?.parameters ?? base.parameters,
            status: .processing,
            statusUpdatedAt: timestamp,
            errorMessage: nil
        )
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
