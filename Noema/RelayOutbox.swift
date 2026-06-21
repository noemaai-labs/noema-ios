import Foundation
import RelayKit

#if os(iOS) || os(visionOS)
actor RelayOutbox {
    private var configuredContainerID: String?
    private let pollIntervalNanoseconds: UInt64 = 750_000_000 // 0.75s
    private let timeout: TimeInterval = 180

    func sendAndAwaitReply(
        containerID: String,
        conversationID: UUID,
        history: [(role: String, text: String, fullText: String?)],
        parameters: [String: String]
    ) async throws -> RelayEnvelope {
        let baselineCount = try await post(containerID: containerID,
                                           conversationID: conversationID,
                                           history: history,
                                           parameters: parameters)
        return try await waitForReply(conversationID: conversationID, baselineCount: baselineCount)
    }

    /// Posts the request and streams the reply back incrementally: `onDelta` is
    /// called with each new chunk of assistant text as the host writes throttled
    /// partial updates. Returns the final envelope once the conversation
    /// completes.
    func sendAndStreamReply(
        containerID: String,
        conversationID: UUID,
        history: [(role: String, text: String, fullText: String?)],
        parameters: [String: String],
        onDelta: @Sendable (String) async -> Void
    ) async throws -> RelayEnvelope {
        let baselineCount = try await post(containerID: containerID,
                                           conversationID: conversationID,
                                           history: history,
                                           parameters: parameters)
        return try await streamReply(conversationID: conversationID,
                                     baselineCount: baselineCount,
                                     onDelta: onDelta)
    }

    /// Posts the outbound envelope and returns the baseline message count.
    private func post(
        containerID: String,
        conversationID: UUID,
        history: [(role: String, text: String, fullText: String?)],
        parameters: [String: String]
    ) async throws -> Int {
        guard !containerID.isEmpty else {
            throw InferenceError.notConfigured
        }
        if configuredContainerID != containerID {
            CloudKitRelay.shared.configure(containerIdentifier: containerID, provider: nil)
            configuredContainerID = containerID
        }
        let messages = history.map { entry in
            let visible = RelayMessage.visibleText(from: entry.text)
            let full = entry.fullText ?? entry.text
            return RelayMessage(conversationID: conversationID,
                                role: entry.role,
                                text: visible,
                                fullText: full)
        }
        let envelope = RelayEnvelope(
            conversationID: conversationID,
            messages: messages,
            needsResponse: true,
            parameters: parameters
        )
        try await CloudKitRelay.shared.postFromiOS(envelope)
        return messages.count
    }

    /// Returns the latest assistant message's streaming text (raw, including any
    /// reasoning markup) so deltas can be computed across partial writes.
    private func latestAssistantText(in envelope: RelayEnvelope, baselineCount: Int) -> String? {
        guard envelope.messages.count > baselineCount else { return nil }
        guard let assistant = envelope.messages.last(where: { $0.role.lowercased() == "assistant" }) else {
            return nil
        }
        return assistant.fullText ?? assistant.text
    }

    private func streamReply(conversationID: UUID,
                             baselineCount: Int,
                             onDelta: @Sendable (String) async -> Void) async throws -> RelayEnvelope {
        var deadline = Date().addingTimeInterval(timeout)
        var lastStatus: RelayStatus?
        var yielded = ""
        while Date() < deadline {
            try Task.checkCancellation()
            if let envelope = try await CloudKitRelay.shared.fetchEnvelope(conversationID: conversationID) {
                let status = envelope.status
                if status == .failed {
                    throw InferenceError.other(envelope.errorMessage ?? "Relay processing failed")
                }
                if (status == .acknowledged || status == .processing), status != lastStatus {
                    deadline = Date().addingTimeInterval(timeout)
                }
                lastStatus = status

                if let latest = latestAssistantText(in: envelope, baselineCount: baselineCount),
                   latest.count > yielded.count,
                   latest.hasPrefix(yielded) {
                    let delta = String(latest.dropFirst(yielded.count))
                    if !delta.isEmpty { await onDelta(delta) }
                    yielded = latest
                }

                if (!envelope.needsResponse && envelope.messages.count > baselineCount) || status == .completed {
                    // Flush any remainder the final write added beyond the last partial.
                    if let latest = latestAssistantText(in: envelope, baselineCount: baselineCount),
                       latest.count > yielded.count,
                       latest.hasPrefix(yielded) {
                        let delta = String(latest.dropFirst(yielded.count))
                        if !delta.isEmpty { await onDelta(delta) }
                    }
                    return envelope
                }
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw InferenceError.other("Timed out waiting for relay response")
    }

    private func waitForReply(conversationID: UUID, baselineCount: Int) async throws -> RelayEnvelope {
        var deadline = Date().addingTimeInterval(timeout)
        var lastStatus: RelayStatus?
        while Date() < deadline {
            try Task.checkCancellation()
            if let envelope = try await CloudKitRelay.shared.fetchEnvelope(conversationID: conversationID) {
                let status = envelope.status
                if status == .failed {
                    throw InferenceError.other(envelope.errorMessage ?? "Relay processing failed")
                }
                if (status == .acknowledged || status == .processing),
                   status != lastStatus {
                    deadline = Date().addingTimeInterval(timeout)
                }
                lastStatus = status

                if (!envelope.needsResponse && envelope.messages.count > baselineCount) || status == .completed {
                    return envelope
                }
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw InferenceError.other("Timed out waiting for relay response")
    }
}
#endif
