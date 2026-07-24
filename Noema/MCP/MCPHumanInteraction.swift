#if os(macOS)
import AppKit
import Foundation

struct MCPSamplingRequest: Identifiable, Sendable {
    let id: UUID
    let serverID: String
    let prompt: String
    let maxTokens: Int
    let temperature: Double?
}

struct MCPElicitationRequest: Identifiable, Sendable {
    enum Mode: Sendable { case form(schema: JSONValue); case url(URL) }
    let id: UUID
    let serverID: String
    let message: String
    let mode: Mode
}

enum MCPElicitationDecision: Sendable {
    case accept([String: JSONValue])
    case decline
    case cancel
}

/// The UI-visible gate for server-to-client requests. A request cannot proceed
/// until the user acts, and unresolved continuations are cancelled on Off-Grid.
@MainActor
final class MCPHumanInteractionCenter: ObservableObject {
    static let shared = MCPHumanInteractionCenter()

    @Published private(set) var samplingRequest: MCPSamplingRequest?
    @Published private(set) var elicitationRequest: MCPElicitationRequest?

    private var samplingContinuation: CheckedContinuation<String, Error>?
    private var elicitationContinuation: CheckedContinuation<MCPElicitationDecision, Error>?
    private var samplingTimestamps: [String: [Date]] = [:]
    private var samplingExecutionInFlight = false

    var samplingProvider: (@Sendable (String, Int, Double?) async throws -> String)?

    func sample(serverID: String, prompt: String, maxTokens: Int, temperature: Double?) async throws -> String {
        let now = Date()
        let recent = (samplingTimestamps[serverID] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < 3 else { throw ToolError.executionFailed(String(localized: "Sampling rate limit reached.")) }
        guard samplingRequest == nil, !samplingExecutionInFlight else { throw ToolError.executionFailed(String(localized: "Another sampling request is awaiting approval.")) }
        let boundedTokens = min(max(maxTokens, 1), 1_024)
        samplingTimestamps[serverID] = recent + [now]
        samplingRequest = .init(id: UUID(), serverID: serverID, prompt: prompt, maxTokens: boundedTokens, temperature: temperature)
        return try await withCheckedThrowingContinuation { samplingContinuation = $0 }
    }

    func approveSampling() {
        guard let request = samplingRequest, let continuation = samplingContinuation else { return }
        samplingRequest = nil; samplingContinuation = nil
        guard let provider = samplingProvider else {
            continuation.resume(throwing: ToolError.executionFailed(String(localized: "Load an on-device model before allowing MCP sampling.")))
            return
        }
        samplingExecutionInFlight = true
        Task {
            do { continuation.resume(returning: try await provider(request.prompt, request.maxTokens, request.temperature)) }
            catch { continuation.resume(throwing: error) }
            await MainActor.run { self.samplingExecutionInFlight = false }
        }
    }

    func denySampling() {
        samplingRequest = nil
        samplingContinuation?.resume(throwing: CancellationError())
        samplingContinuation = nil
    }

    func elicit(serverID: String, message: String, mode: MCPElicitationRequest.Mode) async throws -> MCPElicitationDecision {
        guard elicitationRequest == nil else { throw ToolError.executionFailed(String(localized: "Another request is awaiting your response.")) }
        elicitationRequest = .init(id: UUID(), serverID: serverID, message: message, mode: mode)
        return try await withCheckedThrowingContinuation { elicitationContinuation = $0 }
    }

    func answerElicitation(_ decision: MCPElicitationDecision) {
        if case .accept = decision, case .url(let url) = elicitationRequest?.mode { NSWorkspace.shared.open(url) }
        elicitationRequest = nil
        elicitationContinuation?.resume(returning: decision)
        elicitationContinuation = nil
    }

    func cancelAll() {
        denySampling()
        elicitationRequest = nil
        elicitationContinuation?.resume(throwing: CancellationError())
        elicitationContinuation = nil
    }
}

extension ChatVM {
    func markMCPToolExecuting(alias: String) {
        for messageIndex in streamMsgs.indices {
            guard var calls = streamMsgs[messageIndex].toolCalls else { continue }
            var changed = false
            for callIndex in calls.indices where
                (calls[callIndex].toolName == alias || calls[callIndex].toolName == MCPCallTool.toolName)
                    && calls[callIndex].phase == .awaitingApproval {
                let call = calls[callIndex]
                calls[callIndex] = Msg.ToolCall(
                    id: call.id, toolName: call.toolName, displayName: call.displayName, iconName: call.iconName,
                    requestParams: call.requestParams, phase: .executing, externalToolCallID: call.externalToolCallID,
                    result: call.result, error: call.error, timestamp: call.timestamp, completedAt: nil
                )
                changed = true
            }
            if changed { streamMsgs[messageIndex].toolCalls = calls }
        }
    }

    /// Connect MCP sampling to the currently loaded local model. This is a
    /// request-scoped, tool-free generation and never falls through to a remote
    /// backend or mutates the chat transcript.
    func installMCPSamplingProvider() {
        MCPHumanInteractionCenter.shared.samplingProvider = { [weak self] prompt, maxTokens, temperature in
            let localClient: AnyLLMClient = try await MainActor.run {
                guard let self, let client = self.client, self.remoteService == nil,
                      !self.loading, !self.stillLoading else {
                    throw ToolError.executionFailed(String(localized: "Load an idle on-device model before allowing MCP sampling."))
                }
                return client
            }
            let messages = [
                ChatMessage(role: "system", content: "Answer this MCP sampling request using the on-device model only. Do not call tools."),
                ChatMessage(role: "user", content: prompt)
            ]
            let options = LLMGenerationOptions(
                reasoningEnabled: false,
                maxOutputTokens: min(max(maxTokens, 1), 1_024),
                temperature: temperature,
                tools: nil
            )
            return try await localClient.text(from: LLMInput(.messages(messages), generationOptions: options))
        }
    }
}
#endif
