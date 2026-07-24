import SwiftUI
import Foundation
import RelayKit
import Combine
import ImageIO
#if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
import CoreSpotlight
import UniformTypeIdentifiers
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
@_exported import Foundation

// Import RollingThought functionality through NoemaPackages
import NoemaPackages

// Removed LocalLLMClient MLX path in favor of mlx-swift/mlx-swift-examples integration
// Using our own llama.cpp implementation instead of LocalLLMClientLlama
#if canImport(MLX)
import MLX
#endif



func currentDeviceWidth() -> CGFloat {
#if os(visionOS)
    return 1024
#elseif canImport(UIKit)
    return UIScreen.main.bounds.width
#elseif canImport(AppKit)
    return NSScreen.main?.frame.width ?? 1024
#else
    return 1024
#endif
}

let noemaToolAnchorToken = "<noema_tool_anchor/>"


private enum ToolContinuationOutcome {
    case restartWithTool(resultJSON: String)
    case finishWithVisibleText(String)
}



private func appendingToolAnchor(to text: String) -> String {
    text + noemaToolAnchorToken
}

func visibleAssistantText(from text: String) -> String {
    AssistantOutputSanitizer.strippingTrailingControlMarkers(
        from: scrubVisibleToolArtifacts(from: text)
    )
}

private func scrubVisibleToolArtifacts(from text: String) -> String {
    var output = text

    func findMatchingBrace(in text: String, startingFrom startIndex: String.Index) -> String.Index? {
        guard text[startIndex] == "{" else { return nil }
        var depth = 0
        var inString = false
        var escapeNext = false
        var idx = startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if escapeNext {
                escapeNext = false
                idx = text.index(after: idx)
                continue
            }
            if char == "\\" && inString {
                escapeNext = true
                idx = text.index(after: idx)
                continue
            }
            if char == "\"" { inString.toggle() }
            if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    func findMatchingBracket(in text: String, startingFrom startIndex: String.Index) -> String.Index? {
        guard text[startIndex] == "[" else { return nil }
        var depth = 0
        var inString = false
        var escapeNext = false
        var idx = startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if escapeNext {
                escapeNext = false
                idx = text.index(after: idx)
                continue
            }
            if char == "\\" && inString {
                escapeNext = true
                idx = text.index(after: idx)
                continue
            }
            if char == "\"" { inString.toggle() }
            if !inString {
                if char == "[" {
                    depth += 1
                } else if char == "]" {
                    depth -= 1
                    if depth == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    while let range = output.range(of: "<tool_call>") {
        if let end = output.range(of: "</tool_call>", range: range.upperBound..<output.endIndex) {
            output.removeSubrange(range.lowerBound..<end.upperBound)
        } else {
            output.removeSubrange(range.lowerBound..<output.endIndex)
        }
    }

    while let range = output.range(of: "TOOL_CALL:") {
        let after = output[range.upperBound...]
        if let nextBoundary = after.range(of: "TOOL_RESULT:")?.lowerBound
            ?? after.range(of: "<tool_response>")?.lowerBound
            ?? after.firstIndex(of: "\n") {
            output.removeSubrange(range.lowerBound..<nextBoundary)
        } else {
            output.removeSubrange(range.lowerBound..<output.endIndex)
        }
    }

    while let range = output.range(of: "<tool_response>") {
        if let end = output.range(of: "</tool_response>", range: range.upperBound..<output.endIndex) {
            output.removeSubrange(range.lowerBound..<end.upperBound)
        } else {
            output.removeSubrange(range.lowerBound..<output.endIndex)
        }
    }

    while let range = output.range(of: "TOOL_RESULT:") {
        let after = output[range.upperBound...]
        var removalEnd = output.endIndex
        if let firstNonWhitespace = after.firstIndex(where: { !$0.isWhitespace }) {
            if after[firstNonWhitespace] == "[",
               let close = findMatchingBracket(in: output, startingFrom: firstNonWhitespace) {
                removalEnd = output.index(after: close)
            } else if after[firstNonWhitespace] == "{",
                      let close = findMatchingBrace(in: output, startingFrom: firstNonWhitespace) {
                removalEnd = output.index(after: close)
            } else if let newline = after[firstNonWhitespace...].firstIndex(of: "\n") {
                removalEnd = newline
            }
        }
        output.removeSubrange(range.lowerBound..<removalEnd)
    }

    return output
}

@MainActor
func performMediumImpact() {
#if os(iOS)
    Haptics.impact(.medium)
#endif
}





#if canImport(UIKit) || os(macOS)

/// One-shot bridge between the unstructured router worker and the chat send.
/// Foundation Models may ignore Swift task cancellation until its service call
/// retires, so the chat must be able to stop waiting without waiting for that
/// worker to finish. Resolution is idempotent; a late AFM result is discarded.
@MainActor
final class AutoRoutingAwaiter {
    private var continuation: CheckedContinuation<AutoRoutingOutcome?, Never>?
    private var resolved = false
    private var result: AutoRoutingOutcome?
    var isResolved: Bool { resolved }

    func value() async -> AutoRoutingOutcome? {
        if resolved { return result }
        return await withCheckedContinuation { continuation in
            if resolved {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    @discardableResult
    func resolve(_ result: AutoRoutingOutcome?) -> Bool {
        guard !resolved else { return false }
        resolved = true
        self.result = result
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
        return true
    }
}

enum AutoRoutingWatchdog {
    /// Remote routers already have a two-second transport timeout. This larger
    /// safety net exists for local framework calls that can occasionally stop
    /// returning at all; it is deliberately long enough for AFM cold startup.
    static let timeoutNanoseconds: UInt64 = 20_000_000_000
}

// MARK: - Chat view model



    @MainActor final class ChatVM: ObservableObject {
    struct ETRepairCandidate: Equatable {
        let modelID: String
        let quantLabel: String
        let modelURL: URL
        let sourceRepoID: String?
    }

    // Progress tracker for model loading
    @Published var loadingProgressTracker = ModelLoadingProgressTracker()
    struct Msg: Identifiable, Equatable, Codable {
        struct Perf: Equatable, Codable {
            var tokenCount: Int
            var avgTokPerSec: Double
            var timeToFirst: Double
            /// Wall-clock seconds from the request being sent to the final token,
            /// i.e. time-to-first-token plus generation time. Surfaced as the
            /// "total" generation duration in the diagnostics footer.
            var totalDuration: Double
            var latencySamplesMs: [Double]
            /// Speculative decoding stats for this response (loopback GGUF only);
            /// nil when the model ran without a draft head.
            var draftTokens: Int?
            var draftAccepted: Int?
            var speculativeType: String?

            init(
                tokenCount: Int,
                avgTokPerSec: Double,
                timeToFirst: Double,
                totalDuration: Double = 0,
                latencySamplesMs: [Double] = [],
                draftTokens: Int? = nil,
                draftAccepted: Int? = nil,
                speculativeType: String? = nil
            ) {
                self.tokenCount = tokenCount
                self.avgTokPerSec = avgTokPerSec
                self.timeToFirst = timeToFirst
                self.totalDuration = totalDuration
                self.latencySamplesMs = latencySamplesMs
                self.draftTokens = draftTokens
                self.draftAccepted = draftAccepted
                self.speculativeType = speculativeType
            }

            var draftAcceptanceRate: Double? {
                guard let draftTokens, draftTokens > 0, let draftAccepted else { return nil }
                return Double(draftAccepted) / Double(draftTokens)
            }

            private enum CodingKeys: String, CodingKey {
                case tokenCount
                case avgTokPerSec
                case timeToFirst
                case totalDuration
                case latencySamplesMs
                case draftTokens
                case draftAccepted
                case speculativeType
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                tokenCount = try container.decode(Int.self, forKey: .tokenCount)
                avgTokPerSec = try container.decode(Double.self, forKey: .avgTokPerSec)
                timeToFirst = try container.decode(Double.self, forKey: .timeToFirst)
                totalDuration = try container.decodeIfPresent(Double.self, forKey: .totalDuration) ?? 0
                latencySamplesMs = try container.decodeIfPresent([Double].self, forKey: .latencySamplesMs) ?? []
                draftTokens = try container.decodeIfPresent(Int.self, forKey: .draftTokens)
                draftAccepted = try container.decodeIfPresent(Int.self, forKey: .draftAccepted)
                speculativeType = try container.decodeIfPresent(String.self, forKey: .speculativeType)
            }
        }

        struct PromptProcessingState: Equatable, Codable {
            var progress: Double
        }

        struct Citation: Equatable, Codable {
            let text: String
            let source: String?
            let score: Float?

            init(text: String, source: String?, score: Float? = nil) {
                self.text = text
                self.source = source
                self.score = score
            }
        }

        struct RAGInjectionInfo: Equatable, Codable {
            enum Stage: String, Equatable, Codable {
                case deciding
                case chosen
                case injected
            }

            enum Method: String, Equatable, Codable {
                case fullContent
                case rag
            }

            let datasetName: String
            let stage: Stage
            let method: Method?
            let requestedMaxChunks: Int
            let retrievedChunkCount: Int
            let injectedChunkCount: Int
            let trimmedChunkCount: Int
            let partialChunkInjected: Bool
            let fullContentEstimateTokens: Int?
            let configuredContextTokens: Int
            let reservedResponseTokens: Int
            let contextBudgetTokens: Int
            let injectedContextTokens: Int
            let decisionReason: String

            init(
                datasetName: String,
                stage: Stage,
                method: Method?,
                requestedMaxChunks: Int,
                retrievedChunkCount: Int,
                injectedChunkCount: Int,
                trimmedChunkCount: Int,
                partialChunkInjected: Bool,
                fullContentEstimateTokens: Int?,
                configuredContextTokens: Int,
                reservedResponseTokens: Int,
                contextBudgetTokens: Int,
                injectedContextTokens: Int,
                decisionReason: String
            ) {
                self.datasetName = datasetName
                self.stage = stage
                self.method = method
                self.requestedMaxChunks = requestedMaxChunks
                self.retrievedChunkCount = retrievedChunkCount
                self.injectedChunkCount = injectedChunkCount
                self.trimmedChunkCount = trimmedChunkCount
                self.partialChunkInjected = partialChunkInjected
                self.fullContentEstimateTokens = fullContentEstimateTokens
                self.configuredContextTokens = configuredContextTokens
                self.reservedResponseTokens = reservedResponseTokens
                self.contextBudgetTokens = contextBudgetTokens
                self.injectedContextTokens = injectedContextTokens
                self.decisionReason = decisionReason
            }

            enum CodingKeys: String, CodingKey {
                case datasetName
                case stage
                case method
                case requestedMaxChunks
                case retrievedChunkCount
                case injectedChunkCount
                case trimmedChunkCount
                case partialChunkInjected
                case fullContentEstimateTokens
                case configuredContextTokens
                case reservedResponseTokens
                case contextBudgetTokens
                case injectedContextTokens
                case decisionReason
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                datasetName = try container.decode(String.self, forKey: .datasetName)
                stage = try container.decode(Stage.self, forKey: .stage)
                method = try container.decodeIfPresent(Method.self, forKey: .method)
                requestedMaxChunks = try container.decode(Int.self, forKey: .requestedMaxChunks)
                retrievedChunkCount = try container.decode(Int.self, forKey: .retrievedChunkCount)
                injectedChunkCount = try container.decode(Int.self, forKey: .injectedChunkCount)
                trimmedChunkCount = try container.decode(Int.self, forKey: .trimmedChunkCount)
                partialChunkInjected = try container.decode(Bool.self, forKey: .partialChunkInjected)
                fullContentEstimateTokens = try container.decodeIfPresent(Int.self, forKey: .fullContentEstimateTokens)
                contextBudgetTokens = try container.decode(Int.self, forKey: .contextBudgetTokens)
                configuredContextTokens = try container.decodeIfPresent(Int.self, forKey: .configuredContextTokens)
                    ?? contextBudgetTokens
                reservedResponseTokens = try container.decodeIfPresent(Int.self, forKey: .reservedResponseTokens)
                    ?? max(0, configuredContextTokens - contextBudgetTokens)
                injectedContextTokens = try container.decode(Int.self, forKey: .injectedContextTokens)
                decisionReason = try container.decode(String.self, forKey: .decisionReason)
            }
        }

        // Web tool metadata captured from TOOL_RESULT output
        struct WebPassage: Equatable, Codable, Identifiable {
            let id: String
            let text: String
            let heading: String?
            let lineStart: Int?
            let lineEnd: Int?
            let page: Int?
            let relevance: Double?
        }

        struct WebHit: Equatable, Codable {
            let id: String
            let title: String
            let snippet: String
            let url: String
            let engine: String
            let score: Double
            let sourceRef: String?
            let canonicalURL: String?
            let domain: String?
            let engines: [String]?
            let author: String?
            let publishedAt: String?
            let fetchedAt: String?
            let contentType: String?
            let fetchStatus: String?
            let contentHash: String?
            let passages: [WebPassage]?
            let nextCursor: String?

            init(
                id: String,
                title: String,
                snippet: String,
                url: String,
                engine: String,
                score: Double,
                sourceRef: String? = nil,
                canonicalURL: String? = nil,
                domain: String? = nil,
                engines: [String]? = nil,
                author: String? = nil,
                publishedAt: String? = nil,
                fetchedAt: String? = nil,
                contentType: String? = nil,
                fetchStatus: String? = nil,
                contentHash: String? = nil,
                passages: [WebPassage]? = nil,
                nextCursor: String? = nil
            ) {
                self.id = id
                self.title = title
                self.snippet = snippet
                self.url = url
                self.engine = engine
                self.score = score
                self.sourceRef = sourceRef
                self.canonicalURL = canonicalURL
                self.domain = domain
                self.engines = engines
                self.author = author
                self.publishedAt = publishedAt
                self.fetchedAt = fetchedAt
                self.contentType = contentType
                self.fetchStatus = fetchStatus
                self.contentHash = contentHash
                self.passages = passages
                self.nextCursor = nextCursor
            }
        }

        enum ToolCallPhase: String, Equatable, Codable {
            case requesting
            case awaitingApproval
            case executing
            case running
            case completed
            case failed

            var isInFlight: Bool {
                self == .requesting || self == .awaitingApproval || self == .executing || self == .running
            }

            var isExecutingLike: Bool {
                self == .executing || self == .running
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let rawValue = try container.decode(String.self)
                switch rawValue {
                case Self.requesting.rawValue:
                    self = .requesting
                case Self.awaitingApproval.rawValue:
                    self = .awaitingApproval
                case Self.executing.rawValue, Self.running.rawValue:
                    self = .executing
                case Self.completed.rawValue:
                    self = .completed
                case Self.failed.rawValue:
                    self = .failed
                default:
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Unknown ToolCallPhase value: \(rawValue)"
                    )
                }
            }
        }

        // Generic tool call metadata for UI display
        struct ToolCall: Equatable, Codable, Identifiable {
            let id: UUID
            let toolName: String
            let displayName: String
            let iconName: String
            let requestParams: [String: AnyCodable]
            let phase: ToolCallPhase
            let externalToolCallID: String?
            let result: String?
            let error: String?
            let timestamp: Date
            /// Wall-clock moment the tool reached a terminal phase
            /// (`.completed`/`.failed`). `nil` while still in flight. Lets the UI
            /// freeze the elapsed-time readout once the tool stops running
            /// instead of counting up forever.
            let completedAt: Date?

            init(
                id: UUID = UUID(),
                toolName: String,
                displayName: String,
                iconName: String,
                requestParams: [String: AnyCodable],
                phase: ToolCallPhase = .executing,
                externalToolCallID: String? = nil,
                result: String? = nil,
                error: String? = nil,
                timestamp: Date = Date(),
                completedAt: Date? = nil
            ) {
                self.id = id
                self.toolName = toolName
                self.displayName = displayName
                self.iconName = iconName
                self.requestParams = requestParams
                self.phase = phase
                self.externalToolCallID = externalToolCallID
                self.result = result
                self.error = error
                self.timestamp = timestamp
                self.completedAt = completedAt
            }

            enum CodingKeys: String, CodingKey {
                case id, toolName, displayName, iconName, requestParams
                case phase, externalToolCallID, result, error, timestamp, completedAt
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(UUID.self, forKey: .id)
                toolName = try c.decode(String.self, forKey: .toolName)
                displayName = try c.decode(String.self, forKey: .displayName)
                iconName = try c.decode(String.self, forKey: .iconName)
                requestParams = (try? c.decode([String: AnyCodable].self, forKey: .requestParams)) ?? [:]
                externalToolCallID = try? c.decode(String.self, forKey: .externalToolCallID)
                result = try? c.decode(String.self, forKey: .result)
                let decodedError = try? c.decode(String.self, forKey: .error)
                timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
                let decodedCompletedAt = try? c.decode(Date.self, forKey: .completedAt)
                // A persisted call can never still be running — if the app quit or the
                // stream died mid-tool, an in-flight phase would otherwise reload as an
                // eternal spinner. Re-derive a terminal phase from what was recorded.
                let decodedPhase = try? c.decode(ToolCallPhase.self, forKey: .phase)
                if let decodedPhase, !decodedPhase.isInFlight {
                    phase = decodedPhase
                    error = decodedError
                } else if decodedError != nil {
                    phase = .failed
                    error = decodedError
                } else if result != nil {
                    phase = .completed
                    error = nil
                } else {
                    phase = .failed
                    error = "Interrupted — the app closed or the response was stopped before the tool finished."
                }
                completedAt = decodedCompletedAt ?? (phase.isInFlight ? nil : timestamp)
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(toolName, forKey: .toolName)
                try c.encode(displayName, forKey: .displayName)
                try c.encode(iconName, forKey: .iconName)
                try c.encode(requestParams, forKey: .requestParams)
                try c.encode(phase, forKey: .phase)
                try c.encodeIfPresent(externalToolCallID, forKey: .externalToolCallID)
                try c.encodeIfPresent(result, forKey: .result)
                try c.encodeIfPresent(error, forKey: .error)
                try c.encode(timestamp, forKey: .timestamp)
                try c.encodeIfPresent(completedAt, forKey: .completedAt)
            }
        }

        /// A model-facing context-window transition that happened while this
        /// assistant message was being generated. The event is anchored by a
        /// character offset in the visible answer, so the transcript can show
        /// exactly where generation paused without inserting control text into
        /// the model's answer.
        struct OutputContinuationEvent: Identifiable, Codable, Equatable {
            enum Phase: String, Codable {
                case preparing
                case continued
                case unavailable
            }

            let id: UUID
            let visibleCharacterOffset: Int
            let contextStrategyRaw: String
            let startedAt: Date
            var phase: Phase
            var completedAt: Date?

            init(
                id: UUID = UUID(),
                visibleCharacterOffset: Int,
                contextStrategyRaw: String,
                startedAt: Date = Date(),
                phase: Phase = .preparing,
                completedAt: Date? = nil
            ) {
                self.id = id
                self.visibleCharacterOffset = max(0, visibleCharacterOffset)
                self.contextStrategyRaw = contextStrategyRaw
                self.startedAt = startedAt
                self.phase = phase
                self.completedAt = completedAt
            }
        }

        let id: UUID
        let role: String
        var text: String
        var timestamp: Date
        var datasetID: String?
        var datasetName: String?
        var perf: Perf?
        var streaming: Bool = false
        var promptProcessing: PromptProcessingState?
        // Shows a post-tool-call waiting spinner in the UI until
        // the first continuation token arrives after a tool result.
        var postToolWaiting: Bool = false
        var retrievedContext: String?
        var citations: [Citation]?
        var ragInjectionInfo: RAGInjectionInfo?
        /// Independent document-access receipt. Unlike `route`, this can exist
        /// when Autopilot is completely disabled.
        var documentAccessDecision: DocumentAccessDecisionRecord?
        var usedWebSearch: Bool?
        var usedRemoteBackend: Bool?
        var remoteBackendName: String?
        var remoteModelName: String?
        /// True when this reply was produced (fully or via mid-turn handoff)
        /// by Apple's Private Cloud Compute rather than on-device AFM.
        var ranOnPrivateCloudCompute: Bool?
        var localModelName: String?
        /// Autopilot routing verdict for this reply.
        var route: RouteDecisionRecord?
        var webHits: [WebHit]?
        var webError: String?
        var imagePaths: [String]?
        var mediaAttachments: [ChatMediaAttachment]?
        var toolCalls: [ToolCall]?
        var outputContinuationEvents: [OutputContinuationEvent]?
        var isBookmarked: Bool = false

        var trimmedVisibleAssistantText: String {
            visibleAssistantText(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var hasVisibleAssistantText: Bool {
            !trimmedVisibleAssistantText.isEmpty
        }

        var shouldShowPromptProcessingCard: Bool {
            role == "🤖" && streaming && promptProcessing != nil
        }

        var shouldShowGenericLoadingIndicator: Bool {
            role == "🤖"
                && streaming
                && promptProcessing == nil
                && !postToolWaiting
                && !hasVisibleAssistantText
        }

        init(id: UUID = UUID(),
             role: String,
             text: String,
             timestamp: Date = Date(),
             datasetID: String? = nil,
             datasetName: String? = nil,
             perf: Perf? = nil,
             streaming: Bool = false,
             promptProcessing: PromptProcessingState? = nil,
             usedRemoteBackend: Bool? = nil,
             remoteBackendName: String? = nil,
             remoteModelName: String? = nil,
             localModelName: String? = nil,
             isBookmarked: Bool = false) {
            self.id = id
            self.role = role
            self.text = text
            self.timestamp = timestamp
            self.datasetID = datasetID
            self.datasetName = datasetName
            self.perf = perf
            self.streaming = streaming
            self.promptProcessing = promptProcessing
            self.usedRemoteBackend = usedRemoteBackend
            self.remoteBackendName = remoteBackendName
            self.remoteModelName = remoteModelName
            self.localModelName = localModelName
            self.isBookmarked = isBookmarked
        }

        enum CodingKeys: String, CodingKey { case id, role, text, timestamp, datasetID, datasetName, perf, promptProcessing, retrievedContext, citations, ragInjectionInfo, documentAccessDecision, usedWebSearch, usedRemoteBackend, remoteBackendName, remoteModelName, ranOnPrivateCloudCompute, localModelName, route, webHits, webError, imagePaths, mediaAttachments, toolCalls, outputContinuationEvents, isBookmarked }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            role = try c.decode(String.self, forKey: .role)
            text = try c.decode(String.self, forKey: .text)
            timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
            datasetID = try? c.decode(String.self, forKey: .datasetID)
            datasetName = try? c.decode(String.self, forKey: .datasetName)
            perf = try? c.decode(Perf.self, forKey: .perf)
            promptProcessing = try? c.decode(PromptProcessingState.self, forKey: .promptProcessing)
            retrievedContext = try? c.decode(String.self, forKey: .retrievedContext)
            citations = try? c.decode([Citation].self, forKey: .citations)
            ragInjectionInfo = try? c.decode(RAGInjectionInfo.self, forKey: .ragInjectionInfo)
            documentAccessDecision = try? c.decode(DocumentAccessDecisionRecord.self, forKey: .documentAccessDecision)
            usedWebSearch = try? c.decode(Bool.self, forKey: .usedWebSearch)
            usedRemoteBackend = try? c.decode(Bool.self, forKey: .usedRemoteBackend)
            remoteBackendName = try? c.decode(String.self, forKey: .remoteBackendName)
            remoteModelName = try? c.decode(String.self, forKey: .remoteModelName)
            ranOnPrivateCloudCompute = try? c.decode(Bool.self, forKey: .ranOnPrivateCloudCompute)
            localModelName = try? c.decode(String.self, forKey: .localModelName)
            route = try? c.decode(RouteDecisionRecord.self, forKey: .route)
            webHits = try? c.decode([WebHit].self, forKey: .webHits)
            webError = try? c.decode(String.self, forKey: .webError)
            imagePaths = try? c.decode([String].self, forKey: .imagePaths)
            mediaAttachments = try? c.decode([ChatMediaAttachment].self, forKey: .mediaAttachments)
            toolCalls = try? c.decode([ToolCall].self, forKey: .toolCalls)
            outputContinuationEvents = try? c.decode([OutputContinuationEvent].self, forKey: .outputContinuationEvents)
            isBookmarked = (try? c.decode(Bool.self, forKey: .isBookmarked)) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(role, forKey: .role)
            try c.encode(text, forKey: .text)
            try c.encode(timestamp, forKey: .timestamp)
            try c.encodeIfPresent(datasetID, forKey: .datasetID)
            try c.encodeIfPresent(datasetName, forKey: .datasetName)
            try c.encodeIfPresent(perf, forKey: .perf)
            try c.encodeIfPresent(promptProcessing, forKey: .promptProcessing)
            try c.encodeIfPresent(retrievedContext, forKey: .retrievedContext)
            try c.encode(citations, forKey: .citations)
            try c.encodeIfPresent(ragInjectionInfo, forKey: .ragInjectionInfo)
            try c.encodeIfPresent(documentAccessDecision, forKey: .documentAccessDecision)
            try c.encodeIfPresent(usedWebSearch, forKey: .usedWebSearch)
            try c.encodeIfPresent(usedRemoteBackend, forKey: .usedRemoteBackend)
            try c.encodeIfPresent(remoteBackendName, forKey: .remoteBackendName)
            try c.encodeIfPresent(remoteModelName, forKey: .remoteModelName)
            try c.encodeIfPresent(ranOnPrivateCloudCompute, forKey: .ranOnPrivateCloudCompute)
            try c.encodeIfPresent(localModelName, forKey: .localModelName)
            try c.encodeIfPresent(route, forKey: .route)
            try c.encodeIfPresent(webHits, forKey: .webHits)
            try c.encodeIfPresent(webError, forKey: .webError)
            try c.encodeIfPresent(imagePaths, forKey: .imagePaths)
            try c.encodeIfPresent(mediaAttachments, forKey: .mediaAttachments)
            try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
            try c.encodeIfPresent(outputContinuationEvents, forKey: .outputContinuationEvents)
            if isBookmarked {
                try c.encode(isBookmarked, forKey: .isBookmarked)
            }
        }
    }

    // Expose Msg.ToolCall as ChatVM.ToolCall for convenience
    typealias ToolCall = Msg.ToolCall

    struct ChatToolPermissions: Equatable, Codable {
        var webSearch: Bool
        var python: Bool
        var memory: Bool
        var datasetRetrieval: Bool
#if os(macOS)
        var selectedMCPServerIDs: Set<String>
#endif

        static var allEnabled: ChatToolPermissions {
#if os(macOS)
            ChatToolPermissions(webSearch: true, python: true, memory: true, datasetRetrieval: true, selectedMCPServerIDs: MCPChatDefaults.selectedServerIDs)
#else
            ChatToolPermissions(webSearch: true, python: true, memory: true, datasetRetrieval: true)
#endif
        }
        static var allDisabled: ChatToolPermissions { ChatToolPermissions(webSearch: false, python: false, memory: false, datasetRetrieval: false) }

        init(
            webSearch: Bool,
            python: Bool,
            memory: Bool,
            datasetRetrieval: Bool = true,
            selectedMCPServerIDs: Set<String> = []
        ) {
            self.webSearch = webSearch
            self.python = python
            self.memory = memory
            self.datasetRetrieval = datasetRetrieval
#if os(macOS)
            self.selectedMCPServerIDs = selectedMCPServerIDs
#endif
        }

        private enum CodingKeys: String, CodingKey {
            case webSearch
            case python
            case memory
            case datasetRetrieval
#if os(macOS)
            case selectedMCPServerIDs
#endif
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            webSearch = try container.decodeIfPresent(Bool.self, forKey: .webSearch) ?? true
            python = try container.decodeIfPresent(Bool.self, forKey: .python) ?? true
            memory = try container.decodeIfPresent(Bool.self, forKey: .memory) ?? true
            datasetRetrieval = try container.decodeIfPresent(Bool.self, forKey: .datasetRetrieval) ?? true
#if os(macOS)
            selectedMCPServerIDs = try container.decodeIfPresent(Set<String>.self, forKey: .selectedMCPServerIDs) ?? []
#endif
        }

        var enabledCount: Int {
            [webSearch, python, memory, datasetRetrieval].filter { $0 }.count
        }

        func filtered(
            _ availability: ToolAvailability,
            datasetSearchAllowed: Bool = true
        ) -> ToolAvailability {
            ToolAvailability(
                webSearch: availability.webSearch && webSearch,
                python: availability.python && python,
                memory: availability.memory && memory,
                calculator: availability.calculator,
                unitConverter: availability.unitConverter,
                // On-device tools are normally gated by their own master toggles. Dataset
                // search has one extra turn-scoped exception: an attached PDF with RAG off
                // is direct-navigation-only, so its caller withholds semantic search.
                datasetSearch: availability.datasetSearch && datasetSearchAllowed,
                pdfRead: availability.pdfRead,
                chartRender: availability.chartRender,
                calendar: availability.calendar
            )
        }

        func allows(toolName: String) -> Bool {
            switch toolName {
            case "noema.web.retrieve":
                return webSearch
            case "noema.python.execute":
                return python
            case "noema.memory":
                return memory
            default:
                return true
            }
        }
    }

    enum ChatToolPermissionKind {
        case webSearch
        case python
        case memory
        case datasetRetrieval
    }

    enum ChatMode: String, CaseIterable, Identifiable, Codable {
        case general
        case research
        case study
        case code
        case meetingPrep
        case travel
        case medicalNotes
        case legalReading
        case creativeDrafting

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .general: return "General Chat"
            case .research: return "Research Mode"
            case .study: return "Study Mode"
            case .code: return "Code Mode"
            case .meetingPrep: return "Meeting Prep Mode"
            case .travel: return "Travel Mode"
            case .medicalNotes: return "Medical Notes Mode"
            case .legalReading: return "Legal Reading Mode"
            case .creativeDrafting: return "Creative Drafting Mode"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "bubble.left.and.bubble.right"
            case .research: return "doc.text.magnifyingglass"
            case .study: return "book"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .meetingPrep: return "calendar.badge.clock"
            case .travel: return "airplane"
            case .medicalNotes: return "cross.case"
            case .legalReading: return "scroll"
            case .creativeDrafting: return "paintbrush"
            }
        }

        var promptGuidance: String? {
            switch self {
            case .general:
                return nil
            case .research:
                return "Chat mode: Research. Prioritize source-grounded synthesis, call out uncertainty, separate findings from assumptions, and preserve citations when retrieval or tools provide evidence."
            case .study:
                return "Chat mode: Study. Teach step by step, check understanding, create short examples, and prefer quizzes or summaries when they help the user learn."
            case .code:
                return "Chat mode: Code. Be precise about files, APIs, edge cases, and tests. Prefer minimal patches, explain tradeoffs, and avoid speculative implementation details."
            case .meetingPrep:
                return "Chat mode: Meeting Prep. Extract goals, decisions needed, risks, agenda items, and concrete follow-ups. Keep the result scannable."
            case .travel:
                return "Chat mode: Travel. Organize by time, place, constraints, confirmations, and contingencies. Highlight missing details and offline-relevant information."
            case .medicalNotes:
                return "Chat mode: Medical Notes. Summarize clearly, distinguish user-provided facts from interpretation, avoid diagnosis certainty, and recommend professional care for urgent or risky symptoms."
            case .legalReading:
                return "Chat mode: Legal Reading. Identify facts, issues, rules, analysis, caveats, and cited text. Avoid presenting legal conclusions as professional legal advice."
            case .creativeDrafting:
                return "Chat mode: Creative Drafting. Offer strong options, preserve the user's voice, make intentional style choices, and keep iterations easy to compare."
            }
        }
    }

    enum AnswerStyle: String, CaseIterable, Identifiable, Codable {
        case natural
        case terse
        case cited
        case stepByStep
        case socratic
        case executiveBrief
        case tableFirst

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .natural: return "Natural Style"
            case .terse: return "Terse"
            case .cited: return "Cited"
            case .stepByStep: return "Step-by-step"
            case .socratic: return "Socratic"
            case .executiveBrief: return "Executive Brief"
            case .tableFirst: return "Table-first"
            }
        }

        var promptGuidance: String? {
            switch self {
            case .natural:
                return nil
            case .terse:
                return "Answer style: Terse. Prefer concise direct answers, remove filler, and use bullets only when they improve clarity."
            case .cited:
                return "Answer style: Cited. Preserve citations and source labels when available; clearly separate uncited model knowledge from cited evidence."
            case .stepByStep:
                return "Answer style: Step-by-step. Explain the reasoning path as user-visible steps without exposing hidden chain-of-thought; summarize before details when useful."
            case .socratic:
                return "Answer style: Socratic. Ask one focused question at a time when teaching or debugging; guide the user toward the answer instead of dumping everything at once."
            case .executiveBrief:
                return "Answer style: Executive Brief. Lead with the decision, risks, and next actions; keep sections short and scan-friendly."
            case .tableFirst:
                return "Answer style: Table-first. Use a compact table for comparisons, options, or extracted facts before any prose summary."
            }
        }
    }

    struct Session: Identifiable, Equatable, Codable {
        let id: UUID
        var title: String
        var messages: [Msg]
        var isFavorite: Bool = false
        var date: Date
        var datasetID: String?
        var toolPermissions: ChatToolPermissions?
        var scratchpad: String?
        var chatMode: ChatMode?
        var answerStyle: AnswerStyle?
        var chatInstructions: String?
        /// Durable recap of complete older turns. Covered messages remain in
        /// `messages` for the transcript UI, but are replaced by this recap in
        /// model-facing prompts.
        var conversationCompaction: ConversationCompactionState?
        /// Tool kinds ("web"/"python"/"memory") whose definitions have already been
        /// committed to this conversation's running context (captured at the first —
        /// and every subsequent — send). The context meter counts these even after
        /// the user disables them mid-conversation, because their tokens are already
        /// baked into the model's context. `nil`/empty means nothing sent yet, so the
        /// meter can still track live toggles before the first prompt.
        var committedToolKinds: Set<String>?

        init(id: UUID = UUID(), title: String, messages: [Msg], isFavorite: Bool = false, date: Date, datasetID: String? = nil, toolPermissions: ChatToolPermissions? = .allEnabled, scratchpad: String? = nil, chatMode: ChatMode? = nil, answerStyle: AnswerStyle? = nil, chatInstructions: String? = nil, conversationCompaction: ConversationCompactionState? = nil, committedToolKinds: Set<String>? = nil) {
            self.id = id
            self.title = title
            self.messages = messages
            self.isFavorite = isFavorite
            self.date = date
            self.datasetID = datasetID
            self.toolPermissions = toolPermissions
            self.scratchpad = scratchpad
            self.chatMode = chatMode
            self.answerStyle = answerStyle
            self.chatInstructions = chatInstructions
            self.conversationCompaction = conversationCompaction
            self.committedToolKinds = committedToolKinds
        }
    }

    enum Piece: Identifiable {
        case text(String)
        case think(String, done: Bool)
        case code(String, language: String?)
        case tool(Int) // Index of the tool call in the message's toolCalls array
        case outputContinuation(Msg.OutputContinuationEvent)

        var id: UUID { UUID() }

        var isThink: Bool {
            if case .think = self { return true }
            return false
        }

        var isTool: Bool {
            if case .tool = self { return true }
            return false
        }
    }

    enum InjectionStage { case none, deciding, decided, processing, predicting }
    enum InjectionMethod { case full, rag }

    @Published var sessions: [Session] = [] {
        didSet { saveSessions() }
    }
    @Published var activeSessionID: Session.ID? {
        didSet {
            saveSessions()
            syncModelManagerDatasetForActiveSession()
            refreshSystemPromptForActiveSession()
#if os(macOS)
            syncActiveMCPToolSelection()
#endif
            // Recreate rolling thought view models when switching sessions
            DispatchQueue.main.async { [weak self] in
                self?.recreateRollingThoughtViewModels()
            }
            if let id = activeSessionID {
                Task { [weak self] in
                    guard let self else { return }
                    await self.remoteService?.updateConversationID(id)
                }
            }
        }
    }
    @Published var prompt: String = ""
    @Published var loading  = false {
        didSet {
            if !loading {
                loadingProgressTracker.completeLoading()
            }
        }
    }
    @Published var stillLoading = false
    @Published var loadError: String?
    var lastLoadBlockedByRAMSafety = false
    @Published var pendingETRepairCandidate: ETRepairCandidate?
    @Published var modelLoaded = false
    @Published var lastUnloadVerification: ModelUnloadMemoryVerificationResult?
    @Published var stopAfterParagraphRequested = false
    var canAcceptChatInput: Bool {
        (modelLoaded && client != nil && !loading && !stillLoading)
            || modelManager?.activeRemoteSession != nil
    }
    var hasActiveChatModel: Bool {
        canAcceptChatInput
            || modelManager?.loadedModel != nil
            || loadedURL != nil
            || loadedFormat != nil
    }
    @Published var injectionStage: InjectionStage = .none
    @Published var injectionMethod: InjectionMethod?
    /// Per-turn document plan chosen by AFM or the deterministic fallback before
    /// system-prompt rendering and retrieval begin.
    var currentDocumentAccessStrategy: DocumentAccessStrategy = .none
    @Published var supportsImageInput: Bool = false
    @Published var pendingImageURLs: [URL] = []
    @Published var pendingMediaAttachments: [ChatMediaAttachment] = []
    /// A document attached from the composer "+" menu (embedded on the spot and
    /// armed as this chat's retrieval source). See `ChatVM+AttachedDocument`.
    @Published var attachedDocument: AttachedDocumentState?
    @Published var isRecordingAudio: Bool = false
    @Published var audioRecordingError: String?
    @Published var audioRecordingStartedAt: Date?
    @Published var isDictating: Bool = false
    @Published var dictationError: String?
    /// Mic level for the composer waveform (dictation + voice notes). Not
    /// `@Published` on purpose — see `MicLevelMeter`.
    let micLevelMeter = MicLevelMeter()
    // In-memory thumbnails for pending attachments to avoid re-decoding on each keystroke.
    @Published var pendingThumbnails: [URL: UIImage] = [:]
    @Published var crossSessionSendBlocked: Bool = false
    @Published var spotlightMessageID: UUID?
    @Published var contextOverflowBanners: [Session.ID: ContextOverflowBannerState] = [:]
    @Published var memoryPromptBudgetStatus: MemoryPromptBudgetStatus = .inactive
    @Published var conversationCompactionInProgressSessionID: Session.ID?
    @Published var conversationCompactionFailureNotices: [Session.ID: String] = [:]
    var conversationCompactionFailureRecords: [Session.ID: ConversationCompactionFailureRecord] = [:]
    var conversationCompactionAttemptIDs: [Session.ID: UUID] = [:]

    var contextOverflowBanner: ContextOverflowBannerState? {
        guard let sessionID = activeSessionID else { return nil }
        return contextOverflowBanners[sessionID]
    }

    var memoryPromptBudgetNoticeText: String? {
        let status = memoryPromptBudgetStatus
        guard status.shouldDisplayNotice else { return nil }
        switch status.state {
        case .partiallyLoaded:
            return String.localizedStringWithFormat(
                String(localized: "Memory limited: %d of %d preloaded"),
                status.loadedCount,
                status.totalCount
            )
        case .notLoaded:
            return String(localized: "Memory not preloaded")
        case .inactive, .allLoaded:
            return nil
        }
    }

    var memoryPromptBudgetAlertTitle: String {
        switch memoryPromptBudgetStatus.state {
        case .partiallyLoaded:
            return String(localized: "Memory Limited")
        case .notLoaded:
            return String(localized: "Memory Not Preloaded")
        case .inactive, .allLoaded:
            return String(localized: "Memory")
        }
    }

    var memoryPromptBudgetAlertBody: String {
        let status = memoryPromptBudgetStatus
        switch status.state {
        case .partiallyLoaded:
            return String.localizedStringWithFormat(
                String(localized: "Only %d of %d saved memories were preloaded for this turn. The remaining memories were skipped so the current model stays within its context budget."),
                status.loadedCount,
                status.totalCount
            )
        case .notLoaded:
            return String(localized: "Saved memories were not preloaded for this turn because the current model's context budget is too small.")
        case .inactive, .allLoaded:
            return String(localized: "All saved memories fit within the current model's context budget.")
        }
    }

    struct ContextOverflowBannerState: Equatable {
        let strategy: ContextOverflowStrategy
        let promptTokens: Int?
        let contextTokens: Int?
        let timestamp: Date
    }

    struct ContextOverflowDetails {
        let promptTokens: Int?
        let contextTokens: Int?
        let rawMessage: String
    }

    struct ContextHistoryPlan {
        let history: [Msg]
        let initialEstimate: Int
        let finalEstimate: Int
        let trimmed: Bool
        let requiresStop: Bool
    }

    struct RAGPackedContext: Equatable {
        let injectedContext: String
        let injectedCitations: [Msg.Citation]
        let retrievedChunkCount: Int
        let injectedChunkCount: Int
        let trimmedChunkCount: Int
        let partialChunkInjected: Bool
        let contextTokenCount: Int
        let contextBudgetTokens: Int
    }

    struct ResolvedRAGContext {
        let injectedContext: String
        let citations: [Msg.Citation]
        let info: Msg.RAGInjectionInfo
    }

    struct PromptBudget: Equatable {
        let configuredContextTokens: Int
        let reservedResponseTokens: Int
        let usablePromptTokens: Int
    }

    struct FullContextFitResult: Equatable {
        let fullContextTokens: Int
        let promptTokens: Int
        let budget: PromptBudget

        var fits: Bool {
            promptTokens <= budget.usablePromptTokens
        }
    }

    private struct PendingPerfAccumulator {
        static let maxLatencySamples = 32

        var start: Date
        var firstToken: Date?
        var lastToken: Date?
        var tokenCount: Int
        var latencySamplesMs: [Double]
    }

    private var pendingPerfAccumulators: [UUID: PendingPerfAccumulator] = [:]

    private func beginPerfTracking(messageID: UUID, start: Date) {
        pendingPerfAccumulators[messageID] = PendingPerfAccumulator(
            start: start,
            firstToken: nil,
            lastToken: nil,
            tokenCount: 0,
            latencySamplesMs: []
        )
    }

    private func recordToken(messageID: UUID, timestamp: Date = Date()) {
        guard var acc = pendingPerfAccumulators[messageID] else { return }
        acc.tokenCount += 1
        if acc.firstToken == nil {
            acc.firstToken = timestamp
        }
        if let previous = acc.lastToken {
            let latencyMs = timestamp.timeIntervalSince(previous) * 1000
            if latencyMs.isFinite, latencyMs >= 0 {
                if acc.latencySamplesMs.count >= PendingPerfAccumulator.maxLatencySamples {
                    acc.latencySamplesMs.removeFirst(acc.latencySamplesMs.count - PendingPerfAccumulator.maxLatencySamples + 1)
                }
                acc.latencySamplesMs.append(latencyMs)
            }
        }
        acc.lastToken = timestamp
        pendingPerfAccumulators[messageID] = acc
    }

    private func finalizePerf(messageID: UUID, injectionOverhead: Int) -> Msg.Perf? {
        guard let acc = pendingPerfAccumulators.removeValue(forKey: messageID),
              let first = acc.firstToken,
              let last = acc.lastToken else { return nil }
        let duration = last.timeIntervalSince(first)
        let rate = duration > 0 ? Double(acc.tokenCount) / duration : 0
        let totalTokens = acc.tokenCount + max(0, injectionOverhead)
        let timeToFirst = first.timeIntervalSince(acc.start)
        let totalDuration = last.timeIntervalSince(acc.start)
        return Msg.Perf(
            tokenCount: totalTokens,
            avgTokPerSec: rate,
            timeToFirst: timeToFirst,
            totalDuration: totalDuration,
            latencySamplesMs: acc.latencySamplesMs
        )
    }

    private func cancelPerfTracking(messageID: UUID) {
        pendingPerfAccumulators.removeValue(forKey: messageID)
    }

    nonisolated static func diagnosticHash(for text: String) -> String {
        String(text.hashValue, radix: 16)
    }

    nonisolated static func systemPromptMetadataSummary(_ systemPrompt: String) -> String {
        "[ChatVM] SYSTEM PROMPT len=\(systemPrompt.count) hash=\(diagnosticHash(for: systemPrompt))"
    }

    nonisolated static func promptMetadataSummary(
        prompt: String,
        stops: [String],
        format: ModelFormat?,
        kind: ModelKind,
        hasTemplate: Bool
    ) -> String {
        let formatLabel = format?.displayName ?? "<none>"
        let templateLabel = hasTemplate ? "custom" : "default"
        return "len=\(prompt.count) stops=\(stops.count) hash=\(diagnosticHash(for: prompt)) format=\(formatLabel) kind=\(String(describing: kind)) template=\(templateLabel)"
    }

    nonisolated static func ragMetadataSummary(
        method: String,
        contextLength: Int,
        prompt: String
    ) -> String {
        "method=\(method) contextChars=\(contextLength) promptLen=\(prompt.count) promptHash=\(diagnosticHash(for: prompt))"
    }

    nonisolated static func promptBudget(for contextLimit: Double) -> PromptBudget {
        let configuredContextTokens = max(1, Int(contextLimit.rounded()))
        let reservedResponseTokens = min(4096, max(512, Int(Double(configuredContextTokens) * 0.05)))
        let usablePromptTokens = max(256, configuredContextTokens - reservedResponseTokens)
        return PromptBudget(
            configuredContextTokens: configuredContextTokens,
            reservedResponseTokens: reservedResponseTokens,
            usablePromptTokens: usablePromptTokens
        )
    }

    func currentPromptBudget() -> PromptBudget {
        Self.promptBudget(for: contextLimit)
    }

    func estimatedPromptTokens(for prompt: String) async -> Int {
        if loadedFormat == .gguf, let exact = await tokenCountViaServer(prompt) {
            return exact
        }
        if let exact = await client?.countTokens(in: prompt) {
            return exact
        }
        return estimateTokensSync(prompt)
    }

    nonisolated static func evaluateFullContextInjection(
        fullContext: String,
        contextLimit: Double,
        knownFullContextTokens: Int? = nil,
        promptBuilder: @escaping @Sendable (String) -> String,
        promptTokenCounter: @escaping @Sendable (String) async -> Int
    ) async -> FullContextFitResult {
        let budget = promptBudget(for: contextLimit)
        let trimmedContext = fullContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullContextTokens: Int
        if trimmedContext.isEmpty {
            fullContextTokens = 0
        } else if let knownFullContextTokens {
            fullContextTokens = max(0, knownFullContextTokens)
        } else {
            fullContextTokens = await promptTokenCounter(trimmedContext)
        }
        let promptTokens = await promptTokenCounter(promptBuilder(fullContext))
        return FullContextFitResult(
            fullContextTokens: fullContextTokens,
            promptTokens: promptTokens,
            budget: budget
        )
    }

    private func updateRAGInjectionInfo(messageIndex: Int, _ info: Msg.RAGInjectionInfo?) {
        guard streamMsgs.indices.contains(messageIndex) else { return }
        streamMsgs[messageIndex].ragInjectionInfo = info
    }

    private func clearRAGInjectionArtifacts(messageIndex: Int) {
        guard streamMsgs.indices.contains(messageIndex) else { return }
        streamMsgs[messageIndex].retrievedContext = nil
        streamMsgs[messageIndex].citations = nil
        streamMsgs[messageIndex].ragInjectionInfo = nil
    }

    private func updateStreamMessage(at messageIndex: Int, mutate: (inout Msg) -> Void) {
        guard streamMsgs.indices.contains(messageIndex) else { return }
        var messages = streamMsgs
        mutate(&messages[messageIndex])
        streamMsgs = messages
    }

    private func cachedFullDatasetContent(for dataset: LocalDataset) async -> String {
        if let cached = fullDatasetContentCache[dataset.datasetID] {
            return cached
        }
        let fullContent = await DatasetRetriever.shared.fetchAllContent(for: dataset)
        fullDatasetContentCache[dataset.datasetID] = fullContent
        return fullContent
    }

    nonisolated private static func formattedRAGChunk(index: Int, text: String, source: String?) -> String {
        let src = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if src.isEmpty {
            return "[\(index)] \(text)"
        }
        return "[\(index)] (\(src)) \(text)"
    }

    nonisolated private static func trimmedChunkPrefix(_ text: String, characterCount: Int) -> String {
        guard characterCount > 0 else { return "" }
        let rawPrefix = String(text.prefix(characterCount))
        let trimmed = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard characterCount < text.count else { return trimmed }

        if let lastWhitespace = trimmed.lastIndex(where: { $0.isWhitespace }),
           trimmed.distance(from: trimmed.startIndex, to: lastWhitespace) >= max(16, trimmed.count / 2) {
            return String(trimmed[..<lastWhitespace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    nonisolated static func packRAGContext(
        chunks: [(text: String, source: String?, score: Float?)],
        requestedMaxChunks: Int,
        usablePromptTokens: Int,
        promptTokenCounter: @escaping @Sendable (String) async -> Int,
        promptBuilder: @escaping @Sendable (String) -> String
    ) async -> RAGPackedContext {
        let retrievedChunks = Array(chunks.prefix(max(0, requestedMaxChunks)))
        let contextBudgetTokens = max(256, usablePromptTokens)
        guard requestedMaxChunks > 0, !retrievedChunks.isEmpty else {
            return RAGPackedContext(
                injectedContext: "",
                injectedCitations: [],
                retrievedChunkCount: retrievedChunks.count,
                injectedChunkCount: 0,
                trimmedChunkCount: 0,
                partialChunkInjected: false,
                contextTokenCount: 0,
                contextBudgetTokens: contextBudgetTokens
            )
        }

        var injectedBlocks: [String] = []
        var injectedCitations: [Msg.Citation] = []

        for chunk in retrievedChunks {
            let nextIndex = injectedBlocks.count + 1
            let formatted = formattedRAGChunk(index: nextIndex, text: chunk.text, source: chunk.source)
            let candidate = injectedBlocks.isEmpty ? formatted : injectedBlocks.joined(separator: "\n\n") + "\n\n" + formatted
            let tokenCount = await promptTokenCounter(promptBuilder(candidate))
            if tokenCount <= contextBudgetTokens {
                injectedBlocks.append(formatted)
                injectedCitations.append(Msg.Citation(text: chunk.text, source: chunk.source, score: chunk.score))
            } else {
                break
            }
        }

        var partialChunkInjected = false
        if injectedBlocks.isEmpty, let firstChunk = retrievedChunks.first {
            let firstText = firstChunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstText.isEmpty {
                var low = 1
                var high = firstText.count
                var bestText = ""

                while low <= high {
                    let mid = (low + high) / 2
                    let candidateText = trimmedChunkPrefix(firstText, characterCount: mid)
                    if candidateText.isEmpty {
                        low = mid + 1
                        continue
                    }

                    let formatted = formattedRAGChunk(index: 1, text: candidateText, source: firstChunk.source)
                    let tokenCount = await promptTokenCounter(promptBuilder(formatted))
                    if tokenCount <= contextBudgetTokens {
                        bestText = candidateText
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }

                if !bestText.isEmpty {
                    injectedBlocks = [formattedRAGChunk(index: 1, text: bestText, source: firstChunk.source)]
                    injectedCitations = [Msg.Citation(text: bestText, source: firstChunk.source, score: firstChunk.score)]
                    partialChunkInjected = bestText != firstText
                }
            }
        }

        let injectedContext = injectedBlocks.joined(separator: "\n\n")
        let contextTokenCount = injectedContext.isEmpty ? 0 : await promptTokenCounter(injectedContext)
        let injectedChunkCount = injectedCitations.count
        return RAGPackedContext(
            injectedContext: injectedContext,
            injectedCitations: injectedCitations,
            retrievedChunkCount: retrievedChunks.count,
            injectedChunkCount: injectedChunkCount,
            trimmedChunkCount: max(0, retrievedChunks.count - injectedChunkCount),
            partialChunkInjected: partialChunkInjected,
            contextTokenCount: contextTokenCount,
            contextBudgetTokens: contextBudgetTokens
        )
    }

    nonisolated private func logRAGInjectionInfo(_ info: Msg.RAGInjectionInfo) {
        let method = info.method?.rawValue ?? "pending"
        Task {
            await logger.log(
                "[Prompt][RAG] method=\(method) stage=\(info.stage.rawValue) configured=\(info.configuredContextTokens) reserved=\(info.reservedResponseTokens) usable=\(info.contextBudgetTokens) requested=\(info.requestedMaxChunks) retrieved=\(info.retrievedChunkCount) injected=\(info.injectedChunkCount) trimmed=\(info.trimmedChunkCount) partial=\(info.partialChunkInjected) injectedTokens=\(info.injectedContextTokens) reason=\(info.decisionReason)"
            )
        }
    }

    nonisolated static func shouldDiscardCancelledAssistantPlaceholder(_ message: Msg) -> Bool {
        let visibleText = message.trimmedVisibleAssistantText
        let hasToolCalls = !(message.toolCalls?.isEmpty ?? true)
        let hasWebHits = !(message.webHits?.isEmpty ?? true)
        let hasWebError = !(message.webError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return message.role == "🤖"
            && visibleText.isEmpty
            && !hasToolCalls
            && !hasWebHits
            && !hasWebError
    }

    nonisolated static func removingCancelledAssistantPlaceholder(from messages: [Msg]) -> [Msg] {
        guard let last = messages.last else { return messages }
        guard shouldDiscardCancelledAssistantPlaceholder(last) else { return messages }
        return Array(messages.dropLast())
    }

    /// A tool call still in flight when generation stops can never finish — freeze it
    /// as failed so the transcript doesn't keep an eternal spinner and later turns
    /// replay a concrete error instead of a half-open call.
    nonisolated static func markingInterruptedToolCalls(in messages: [Msg]) -> [Msg] {
        messages.map { message in
            var updated = message
            if let calls = message.toolCalls,
               calls.contains(where: { $0.phase.isInFlight }) {
                updated.toolCalls = calls.map { call in
                    guard call.phase.isInFlight else { return call }
                    return Msg.ToolCall(
                        id: call.id,
                        toolName: call.toolName,
                        displayName: call.displayName,
                        iconName: call.iconName,
                        requestParams: call.requestParams,
                        phase: .failed,
                        externalToolCallID: call.externalToolCallID,
                        result: call.result,
                        error: call.error ?? "Interrupted — generation was stopped before the tool finished.",
                        timestamp: call.timestamp,
                        completedAt: call.completedAt ?? Date()
                    )
                }
            }
            if var events = message.outputContinuationEvents,
               events.contains(where: { $0.phase == .preparing }) {
                let interruptedAt = Date()
                for index in events.indices where events[index].phase == .preparing {
                    events[index].phase = .unavailable
                    events[index].completedAt = interruptedAt
                }
                updated.outputContinuationEvents = events
            }
            return updated
        }
    }

    /// True when the active remote session is currently routing over Cloud
    /// Relay (CloudKit). In that mode the host does not forward incremental
    /// prompt-prefill progress to us, so the prompt-processing card would just
    /// sit at 0% — we show a plain spinner instead.
    var isCloudRelayTransportActive: Bool {
        guard let session = modelManager?.activeRemoteSession else { return false }
        if case .cloudRelay = session.transport { return true }
        return false
    }

    /// Whether the prompt-processing progress card should be used for the
    /// active run. Only on-device gguf/CoreAI runs report incremental
    /// prompt-prefill progress; Cloud Relay (CloudKit) sends none, so we fall
    /// back to the generic spinner there.
    var supportsPromptProcessingCard: Bool {
        (loadedFormat == .gguf || loadedFormat == .coreai) && !isCloudRelayTransportActive
    }

    func startPromptProcessing(for messageIndex: Int) {
        guard loadedFormat == .gguf, !isCloudRelayTransportActive else { return }
        updateStreamMessage(at: messageIndex) { message in
            message.promptProcessing = .init(progress: 0)
        }
    }

    private var lastPromptProgressUpdate: ContinuousClock.Instant?

    func updatePromptProcessingProgress(_ progress: Double, messageIndex: Int) {
        let clamped = min(1.0, max(0.0, progress))
        guard streamMsgs.indices.contains(messageIndex) else { return }
        let current = streamMsgs[messageIndex].promptProcessing?.progress ?? 0
        guard streamMsgs[messageIndex].streaming,
              streamMsgs[messageIndex].promptProcessing != nil,
              clamped >= current else { return }
        // Prompt-processing progress can arrive very frequently during prefill, and each update
        // mutates `sessions` → ChatVM.objectWillChange, which re-renders every ChatVM observer
        // (the whole TabView, ExploreView, …). Cap to ~4 Hz; always allow the final 1.0.
        let now = ContinuousClock().now
        if clamped < 1.0, let last = lastPromptProgressUpdate, now - last < .milliseconds(250) { return }
        lastPromptProgressUpdate = now
        updateStreamMessage(at: messageIndex) { message in
            message.promptProcessing = .init(progress: clamped)
        }
    }

    func clearPromptProcessing(for messageIndex: Int) {
        updateStreamMessage(at: messageIndex) { message in
            message.promptProcessing = nil
        }
    }

    private func finalizeAssistantStream(
        runID: Int,
        messageIndex: Int,
        cleanedText: String,
        pendingToolJSON: String?,
        perfResult: Msg.Perf?,
        tokenCount: Int,
        generationStart: Date,
        firstTokenTimestamp: Date?,
        isMLXFormat: Bool
    ) {
        guard runID == activeRunID,
              streamMsgs.indices.contains(messageIndex) else { return }

        let displayText: String
        if pendingToolJSON == nil {
            let normalized = finalizeVisibleAssistantText(
                cleanedText,
                toolCalls: streamMsgs[messageIndex].toolCalls
            )
            displayText = normalized.isEmpty ? "(no output)" : normalized
        } else if cleanedText.isEmpty {
            displayText = ""
        } else {
            displayText = finalizeVisibleAssistantText(
                cleanedText,
                toolCalls: streamMsgs[messageIndex].toolCalls
            )
        }

        streamMsgs[messageIndex].text = displayText
        streamMsgs[messageIndex].streaming = false
        streamMsgs[messageIndex].promptProcessing = nil
        // Streaming finished for this segment: stop rendering the bubble from the store so
        // it falls back to the committed `sessions` text. (A tool continuation re-begins it.)
        streamingStore.finish()
        clearStopAfterParagraphRequest()
        if var perfResult {
            if loadedFormat == .gguf,
               let timings = LoopbackLatestTimings.snapshot() {
                perfResult.speculativeType = timings.speculativeType
                if let drafted = timings.draftN, drafted > 0 {
                    perfResult.draftTokens = drafted
                    perfResult.draftAccepted = timings.draftNAccepted
                }
            }
            streamMsgs[messageIndex].perf = perfResult
        }
        // Autopilot tally: only completed turns count (tool continuations pass
        // pendingToolJSON and re-finalize later with the full perf).
        if pendingToolJSON == nil, let route = streamMsgs[messageIndex].route {
            let config = AutopilotConfigStore.load()
            let escalationModel = config.escalationSelection.flatMap { sel in
                modelManager?.remoteBackend(withID: sel.backendID)?.cachedModels.first(where: { $0.id == sel.modelID })
            }
            AutopilotLedger.shared.record(
                route: route,
                tokenCount: streamMsgs[messageIndex].perf?.tokenCount ?? tokenCount,
                durationSeconds: streamMsgs[messageIndex].perf?.totalDuration ?? Date().timeIntervalSince(generationStart),
                escalationPromptPricePerMillion: escalationModel?.promptPricePerMillion,
                escalationCompletionPricePerMillion: escalationModel?.completionPricePerMillion,
                promptTokenEstimate: nil
            )
        }

        // Persist the finished turn immediately, bypassing the streaming-save debounce, so a
        // completed response is never lost if the app is force-quit right after generation.
        // This is a single low-frequency encode+write per turn (not on the per-token hot path).
        flushSaveSessions()

        if pendingToolJSON == nil {
#if os(iOS)
            if strictFinalAnswerText(for: streamMsgs[messageIndex]) != nil {
                Haptics.successLight()
            }
#endif
            AccessibilityAnnouncer.announceLocalized("Response generated.")
            markRollingThoughtsInterrupted(forMessageAt: messageIndex)
            assistantTurnEvents.send(.completed(messageID: streamMsgs[messageIndex].id))
            recordPositiveTurnForReview(messageIndex: messageIndex)
        } else {
            assistantTurnEvents.send(.continuingWithTool(messageID: streamMsgs[messageIndex].id))
        }

        if verboseLogging {
            print("[ChatVM] BOT ✓ \(displayText.prefix(80))…")
        }

        let ttfbStr: String = {
            guard let firstTokenTimestamp else { return "n/a" }
            return String(format: "%.2fs", firstTokenTimestamp.timeIntervalSince(generationStart))
        }()
        let tokenRateStr: String = {
            guard let perfResult else { return "n/a" }
            return String(format: "%.2f tok/s", perfResult.avgTokPerSec)
        }()
        let loggedTokenCount = perfResult?.tokenCount ?? tokenCount

        let botText = streamMsgs[messageIndex].text
        let logPrefix = "[ChatVM] BOT ✓ tokens=\(loggedTokenCount) ttfb=\(ttfbStr) rate=\(tokenRateStr)"
        Task {
            if isMLXFormat {
                let logMessage = "\(logPrefix)\n\(botText)"
                await logger.log(logMessage, truncateConsole: false)
            } else {
                let previewLimit = 120
                let preview = String(botText.prefix(previewLimit))
                let suffix = botText.count > previewLimit ? "…" : ""
                let logMessage = "\(logPrefix) preview=\(preview)\(suffix)"
                await logger.log(logMessage)
            }
        }

        let clearDelay: TimeInterval = 2.0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(clearDelay * 1_000_000_000))
            if runID == self.activeRunID {
                self.injectionStage = .none
                self.injectionMethod = nil
            }
        }
    }

    private func recordPositiveTurnForReview(messageIndex: Int) {
        guard streamMsgs.indices.contains(messageIndex) else { return }
        let message = streamMsgs[messageIndex]
        let hasFailedToolCall = message.toolCalls?.contains { call in
            call.phase == .failed
                || !(call.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        } ?? false
        let signals = ReviewTurnSignals.positiveCompletion(
            answerText: strictFinalAnswerText(for: message),
            retrievedContext: message.retrievedContext,
            usedWebSearch: message.usedWebSearch == true,
            webResultCount: message.webHits?.count ?? 0,
            webError: message.webError,
            usedRemoteBackend: message.usedRemoteBackend == true,
            ranOnPrivateCloudCompute: message.ranOnPrivateCloudCompute == true,
            hasFailedToolCall: hasFailedToolCall
        )
        guard let signals else { return }
        ReviewPrompter.shared.recordPositiveTurn(signals, chatVM: self)
    }

    private func finalizeVisibleAssistantText(
        _ text: String,
        toolCalls: [Msg.ToolCall]?
    ) -> String {
        visibleAssistantText(from: text)
    }

    func resolvedVisiblePostToolFinalText(
        existingVisibleText: String,
        fallbackText: String,
        toolCalls: [Msg.ToolCall]?
    ) -> String {
        let sanitizedExistingVisibleText = visibleAssistantText(from: existingVisibleText)
        let trimmedExistingVisibleText = sanitizedExistingVisibleText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExistingVisibleText.isEmpty {
            return sanitizedExistingVisibleText
        }

        let fallbackVisibleText = finalizeVisibleAssistantText(
            fallbackText,
            toolCalls: toolCalls
        )
        let trimmedFallbackVisibleText = fallbackVisibleText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallbackVisibleText.isEmpty {
            return fallbackVisibleText
        }

        return sanitizedExistingVisibleText
    }

    private func scrubEmbeddedToolArtifactsWithoutDispatch(
        in text: String,
        messageIndex: Int?,
        maxPasses: Int = 4
    ) async -> String {
        var cleaned = text
        var pass = 0
        while pass < maxPasses,
              let result = await interceptEmbeddedToolCallIfPresent(
                in: cleaned,
                messageIndex: messageIndex,
                chatVM: self,
                handlingMode: .scrubOnly
              ) {
            cleaned = result.cleanedText
            pass += 1
        }
        return visibleAssistantText(from: cleaned)
    }

    func postToolContinuationNudge(toolName: String?, originalQuestion: String) -> String {
        let trimmedQuestion = originalQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        // This exists only for clients that cannot preserve a structured tool
        // transcript. Keep it terse and let the model decide whether the result
        // is sufficient; imposing a synthetic tool limit breaks document research.
        var lines = [
            "Continue the answer using the tool result above. Call another tool only if more evidence is needed."
        ]

        if normalizedToolName.contains("python") {
            lines[0] = "Continue the answer using the Python result above. Call another tool only if more evidence is needed."
        }

        if !trimmedQuestion.isEmpty {
            lines.append("Question: \(trimmedQuestion)")
        }

        return lines.joined(separator: " ")
    }

    /// Custom prompt template loaded from model configuration
    var promptTemplate: String?
    var promptTemplateSourceLabel: String = PromptTemplateSource.defaultTemplate.rawValue
    var inferenceBackendSummary: String?

    /// Rolling thought view models for active thinking boxes
    @Published var rollingThoughtViewModels: [String: RollingThoughtViewModel] = [:]

    @AppStorage("systemPreset") private var systemPresetRaw = SystemPreset.general.rawValue

    // Expose whether current model supports tool calling
    public var currentModelFormat: ModelFormat? { loadedFormat }
    var supportsToolsFlag: Bool {
        UserDefaults.standard.object(forKey: "currentModelSupportsFunctionCalling") as? Bool ?? false
    }
    var pendingAFMToolSummary: AFMToolExecutionSummary?
    /// Live Apple Foundation Models client while an `.afm` model is loaded.
    var activeAFMClient: AFMLLMClient?
    /// Distinguishes the system on-device model from the separately stored PCC model.
    var activeAppleFoundationModelKind: AppleFoundationModelKind?
    /// True while the loaded model is an AFM variant that cannot run chat tools.
    /// The PCC server model registers native FoundationModels tools (web,
    /// Python, memory); the on-device model stays tool-free. UI that used to
    /// blanket-exclude AFM gates on this instead.
    var afmChatToolsUnavailable: Bool {
        loadedFormat == .afm && activeAppleFoundationModelKind != .privateCloudCompute
    }
    var activeTurnScratchpadSnapshot: String?

    private func applyActiveAppleModelOrigin(to messageIndex: Int) {
        guard streamMsgs.indices.contains(messageIndex) else { return }
        if activeAppleFoundationModelKind == .privateCloudCompute {
            streamMsgs[messageIndex].ranOnPrivateCloudCompute = true
        }
    }

    func enqueueAFMToolSummary(_ summary: AFMToolExecutionSummary) {
        guard !summary.isEmpty else { return }
        if let pending = pendingAFMToolSummary {
            pendingAFMToolSummary = AFMToolExecutionSummary(calls: pending.calls + summary.calls)
        } else {
            pendingAFMToolSummary = summary
        }
    }

    /// Applies a native FoundationModels tool event to the active assistant
    /// message immediately. PCC awaits the callback before executing/returning
    /// the tool, so an `.executing` event becomes visible before the network or
    /// local work starts instead of arriving with the final answer.
    func handleAFMToolSummary(_ summary: AFMToolExecutionSummary) {
        guard !summary.isEmpty else { return }
        if let messageIndex = streamMsgs.lastIndex(where: {
            $0.streaming && ($0.role == "🤖" || $0.role.lowercased() == "assistant")
        }) {
            _ = applyAFMToolSummary(summary, to: messageIndex)
        } else {
            enqueueAFMToolSummary(summary)
        }
    }

    @discardableResult
    private func applyPendingAFMToolSummary(to messageIndex: Int) -> Bool {
        guard streamMsgs.indices.contains(messageIndex) else {
            pendingAFMToolSummary = nil
            return false
        }
        guard let summary = pendingAFMToolSummary, !summary.isEmpty else { return false }
        pendingAFMToolSummary = nil
        return applyAFMToolSummary(summary, to: messageIndex)
    }

    @discardableResult
    private func applyAFMToolSummary(
        _ summary: AFMToolExecutionSummary,
        to messageIndex: Int
    ) -> Bool {
        guard streamMsgs.indices.contains(messageIndex), !summary.isEmpty else { return false }
        let resolved = AFMToolExecutionMapper.resolve(summary)
        var toolCalls = streamMsgs[messageIndex].toolCalls ?? []
        var insertedCall = false
        var receivedTerminalEvent = false

        for call in resolved.calls {
            let phase: Msg.ToolCallPhase = {
                switch call.phase {
                case .executing: return .executing
                case .completed: return .completed
                case .failed: return .failed
                }
            }()
            let existingIndex = toolCalls.lastIndex { $0.externalToolCallID == call.id }
            let existing = existingIndex.map { toolCalls[$0] }
            if let existing,
               !existing.phase.isInFlight,
               phase.isInFlight {
                continue
            }

            let mapped = Msg.ToolCall(
                id: existing?.id ?? UUID(),
                toolName: call.toolName,
                displayName: call.displayName,
                iconName: call.iconName,
                requestParams: call.requestParams,
                phase: phase,
                externalToolCallID: call.id,
                result: call.result,
                error: call.error,
                timestamp: existing?.timestamp ?? call.timestamp,
                completedAt: phase.isInFlight
                    ? nil
                    : (existing?.completedAt ?? call.completedAt ?? Date())
            )
            if let existingIndex {
                toolCalls[existingIndex] = mapped
            } else {
                toolCalls.append(mapped)
                insertedCall = true
            }
            if !phase.isInFlight {
                receivedTerminalEvent = true
            }
        }
        streamMsgs[messageIndex].toolCalls = toolCalls
        if receivedTerminalEvent, streamMsgs[messageIndex].streaming {
            streamMsgs[messageIndex].postToolWaiting = true
        }

        if resolved.usedWebSearch {
            streamMsgs[messageIndex].usedWebSearch = true
        }
        if resolved.usedWebSearch, receivedTerminalEvent {
            // Prefer the v2 evidence envelope produced by the wrapped
            // WebRetrieveTool; fall back to the legacy [WebHit] payload for
            // summaries recorded by the old AFM search tool.
            var appliedEnvelope = false
            for call in resolved.calls where call.toolName == "noema.web.retrieve" {
                guard let result = call.result else { continue }
                let data = Data(result.utf8)
                if WebToolResultDecoder.envelope(from: data) != nil
                    || WebToolResultDecoder.error(from: data) != nil {
                    applyWebToolResult(data, messageIndex: messageIndex)
                    appliedEnvelope = true
                }
            }
            if !appliedEnvelope {
                streamMsgs[messageIndex].webHits = chatWebHits(from: resolved.webHits)
                streamMsgs[messageIndex].webError = resolved.webError
            }
        }
        return insertedCall
    }

    private func chatWebHits(from hits: [WebHit]?) -> [Msg.WebHit]? {
        guard let hits, !hits.isEmpty else { return nil }
        return hits.enumerated().map { index, hit in
            let engine = hit.engine.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedEngine = engine.isEmpty ? "searxng" : engine
            return Msg.WebHit(
                id: String(index + 1),
                title: hit.title,
                snippet: hit.snippet,
                url: hit.url,
                engine: resolvedEngine,
                score: hit.score ?? 0
            )
        }
    }

    private func normalizedDatasetID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func datasetID(for session: Session) -> String? {
        if session.datasetID != nil {
            // Session-level setting is authoritative; empty string means explicitly disabled.
            return normalizedDatasetID(session.datasetID)
        }
        if let inherited = session.messages.reversed().first(where: {
            let role = $0.role.lowercased()
            return role == "user" || role == "🧑‍💻"
        })?.datasetID {
            return normalizedDatasetID(inherited)
        }
        return nil
    }

    private func resolvedDataset(for datasetID: String?) -> LocalDataset? {
        guard let datasetID else { return nil }
        if let ds = datasetManager?.datasets.first(where: { $0.datasetID == datasetID }) {
            return ds
        }
        if let ds = modelManager?.downloadedDatasets.first(where: { $0.datasetID == datasetID }) {
            return ds
        }
        return nil
    }

    func datasetForSession(_ session: Session) -> LocalDataset? {
        resolvedDataset(for: datasetID(for: session))
    }

    var activeSessionDatasetAny: LocalDataset? {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return nil }
        return datasetForSession(sessions[idx])
    }

    var activeSessionDataset: LocalDataset? {
        activeSessionDatasetAny
    }

    private var activeSessionIndexedDataset: LocalDataset? {
        guard let ds = activeSessionDatasetAny,
              ds.isIndexed else { return nil }
        return ds
    }

    var activeSessionRetrievalDataset: LocalDataset? {
        guard activeToolPermissions.datasetRetrieval else { return nil }
        return activeSessionIndexedDataset
    }

    /// Direct PDF navigation still needs the selected dataset's scope and prompt
    /// guidance when automatic RAG context is disabled for the chat.
    var activeSessionPromptDataset: LocalDataset? {
        if currentDocumentAccessStrategy.usesPDFNavigation {
            return activeSessionIndexedDataset
        }
        return activeSessionRetrievalDataset
    }

    /// Turning off RAG for an attached PDF is a direct-navigation choice: keep
    /// the PDF reader, but withhold semantic dataset search for this chat.
    var isPDFOnlyDocumentAccess: Bool {
        let scope: (permissions: ChatToolPermissions, dataset: LocalDataset?) = {
            if let streamSessionIndex, sessions.indices.contains(streamSessionIndex) {
                let session = sessions[streamSessionIndex]
                return (session.toolPermissions ?? .allEnabled, datasetForSession(session))
            }
            return (activeToolPermissions, activeSessionIndexedDataset)
        }()
        guard !scope.permissions.datasetRetrieval,
              let dataset = scope.dataset,
              dataset.isIndexed else { return false }
        return !PDFDatasetAccess.pdfURLs(in: dataset.url).isEmpty
    }

    var effectiveEditableSystemPromptIntro: String? {
        let globalIntro = SystemPreset.resolvedEditableIntro(from: customSystemPromptIntro)
        guard let loadedSettings else { return globalIntro }

        switch loadedSettings.systemPromptMode {
        case .inheritGlobal:
            return globalIntro
        case .override:
            return SystemPreset.trimmedEditableIntro(from: loadedSettings.systemPromptOverride) ?? globalIntro
        case .excludeGlobal:
            return nil
        }
    }

    /// In-memory indexed dataset titles for the dataset-search tool guidance. Reads the
    /// already-policy-filtered published list (no disk scan) so it's safe in the per-turn
    /// and context-meter render paths.
    private func indexedDatasetTitlesForGuidance() -> [String] {
        (datasetManager?.datasets ?? [])
            .filter { $0.isIndexed && !$0.requiresReindex && EnterprisePolicyGate.allowsDataset(datasetID: $0.datasetID) }
            .map(\.name)
    }

    /// First non-marker lines of the active PDF dataset's extracted text, for a system-prompt
    /// preview. Reads the already-written `extracted.txt` (no second PDFKit pass).
    private func attachedPDFPreview(for dataset: LocalDataset, maxLines: Int = 12, maxChars: Int = 600) -> String? {
        let url = DatasetIndexIO.extractedURL(for: dataset.url)
        guard let text = DatasetTextReader.readString(from: url) else { return nil }
        var collected: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // Skip the <<<FILE: …>>> source markers the indexer writes ahead of the text.
            if DatasetSourceMarkers.sourcePath(fromLine: line.trimmingCharacters(in: .whitespaces)) != nil { continue }
            if collected.isEmpty && line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            collected.append(line)
            if collected.count >= maxLines { break }
        }
        let preview = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return nil }
        return preview.count > maxChars ? String(preview.prefix(maxChars)) + "…" : preview
    }

    /// Announces the active PDF scope and tells the answer model how the turn planner
    /// expects semantic context and direct navigation to work together.
    nonisolated static func activePDFGuidance(
        documentNames: [String],
        preview: String?,
        strategy: DocumentAccessStrategy,
        automaticContextAvailable: Bool
    ) -> String {
        let multi = documentNames.count > 1
        var text: String
        if multi {
            let list = documentNames.map { "\"\($0)\"" }.joined(separator: ", ")
            text = "ACTIVE PDFs: This chat's dataset contains \(documentNames.count) PDFs: \(list)."
        } else {
            text = "ACTIVE PDF: This chat has access to \"\(documentNames.first ?? "the document")\"."
        }
        if let preview, !preview.isEmpty {
            text += multi ? " First lines of the first document:\n\n\"\"\"\n\(preview)\n\"\"\"" : " Its first lines are:\n\n\"\"\"\n\(preview)\n\"\"\""
        }
        let docHint = multi ? "Set `document` to one of the names above, then " : ""
        switch strategy {
        case .navigate:
            text += "\n\nThis turn requires direct PDF navigation. Start with `noema.pdf.read`; \(docHint)use `grep` for exact text, numbers, names, or occurrences, then `lines` or `read` for the needed surrounding passage."
            if automaticContextAvailable {
                text += " Do not call `noema.rag.search` first."
            } else {
                text += " RAG is disabled for this chat; use only `noema.pdf.read` for this document and do not call `noema.rag.search`."
            }
        case .contextThenNavigate:
            text += "\n\nNoema supplies the complete document while the current context budget permits and selected semantic passages otherwise. Treat only document evidence present in this request as loaded; do not assume the complete PDF remains resident because it was available on an earlier turn. This turn also requires exact verification. Use `noema.pdf.read`; \(docHint)`grep` the relevant phrase or figure, then use `lines` or `read` before answering. Do not repeat semantic search unless the supplied context is empty."
        case .context:
            text += "\n\nNoema supplies the complete document while the current context budget permits and selected semantic passages otherwise. Treat only document evidence present in this request as loaded; do not assume the complete PDF remains resident because it was available on an earlier turn. Answer from the supplied evidence when sufficient. If an exact phrase, figure, page, or surrounding section is missing, use `noema.pdf.read` with `grep` followed by `lines` or `read`; do not repeat the same semantic search first."
        case .none:
            text += "\n\nThe current request does not require this PDF. Answer normally without claiming to have used it."
        }
        return text
    }
    func renderSystemPromptText(
        using dataset: LocalDataset?,
        toolAvailability: ToolAvailability,
        includeThinkRestriction: Bool,
        memorySnapshot: String?,
        scratchpadSnapshot: String?,
        editableIntro: String?
    ) -> String {
        let datasetTitles = toolAvailability.datasetSearch ? indexedDatasetTitlesForGuidance() : []
        // An active dataset normally uses the evidence-focused preset. A NONE
        // plan deliberately keeps the ordinary assistant preset for this turn.
        if let ds = dataset {
            // Ensure no accidental anti-reasoning directives like "/nothink" are present.
            var base = currentDocumentAccessStrategy == .none
                ? SystemPreset.generalText(editableIntro: editableIntro)
                : SystemPreset.ragText(editableIntro: editableIntro)
            base = sanitizeSystemPrompt(base)
            let rawDocumentTitle = ds.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ds.datasetID : ds.name
            let documentTitle = rawDocumentTitle
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch currentDocumentAccessStrategy {
            case .none:
                base += "\n\nA document titled \"\(documentTitle)\" is selected for this chat, but the current request does not require it. Answer normally and do not claim document evidence."
            case .navigate:
                base += "\n\nDirect document navigation for this turn: use results from the active document's tools as evidence. If the answer is not present in those results, say it is not in the document rather than answering from memory. The active document is titled \"\(documentTitle)\"."
            case .context, .contextThenNavigate:
                // Phrased to stay true whether retrieval returned passages or abstained.
                base += "\n\nDocument context for this turn: you have access to \"\(documentTitle)\". Noema keeps the complete dataset in context while it fits and transitions to selected passages as the conversation grows. Rely only on document evidence present in the current request or returned by a document tool; do not assume evidence loaded on an earlier turn is still resident. If no relevant evidence is present, say it is not in the document rather than answering from memory."
            }
            let pdfNames = PDFDatasetAccess.pdfURLs(in: ds.url).map(\.lastPathComponent)
            if toolAvailability.pdfRead, !pdfNames.isEmpty {
                base += "\n\n" + Self.activePDFGuidance(
                    documentNames: pdfNames,
                    preview: attachedPDFPreview(for: ds),
                    strategy: currentDocumentAccessStrategy,
                    automaticContextAvailable: activeToolPermissions.datasetRetrieval
                )
            }
            // Curated Knowledge Packs carry a dataset-level persona. Medical packs
            // additionally get a DETERMINISTIC safety disclaimer prepended here
            // (not left to model discretion), so it is present even if the persona
            // is ignored or retrieval abstains.
            if let pack = KnowledgePackCatalog.pack(forID: ds.datasetID) {
                if pack.disclaimerKey == "medical" {
                    base += "\n\nSAFETY: This is general reference information, not professional medical advice. For any injury, illness, or medication question, tell the user to seek qualified medical care or emergency services. Never present guidance as a diagnosis or a substitute for a clinician."
                }
                if let persona = pack.systemPrompt, !persona.isEmpty {
                    base += "\n\n\(persona)"
                }
            }
            // Vision guidance only when images ARE attached. The "no image is provided"
            // text-only guard was removed to stop pushing on the model's behavior.
            if supportsImageInput && !pendingImageURLs.isEmpty {
                let n = pendingImageURLs.count
                let plural = n == 1 ? "image" : "images"
                base += "\n\nVision: \(n) \(plural) attached. Use them to answer the question. Describe only what is actually present. If unsure, say you are unsure. Do not invent details."
            }
            if loadedFormat == .gguf || loadedFormat == .afm || remoteService != nil {
                // GGUF: native tools via request `tools` array — emit only context data.
                // AFM (PCC) registers FoundationModels tools on the session, so the
                // framework advertises schemas itself; prose guidance would teach the
                // loopback <tool_call> protocol nothing parses on that path.
                // Full remote sessions also send native `tools` (RemoteChatService), so
                // prose guidance would double-advertise. Escalated Autopilot turns are NOT
                // suppressed here: the session's stored system prompt renders without any
                // per-turn flag and ChatFormatter merges divergent system texts, so a
                // turn-scoped suppression would just duplicate the prompt.
                // MLX keeps prose guidance (its VLM processors can drop input.tools).
                SystemPromptResolver.appendToolContextData(
                    to: &base,
                    availability: toolAvailability,
                    memorySnapshot: memorySnapshot,
                    datasetTitles: datasetTitles
                )
            } else {
                SystemPromptResolver.appendToolGuidance(
                    to: &base,
                    availability: toolAvailability,
                    includeThinkRestriction: includeThinkRestriction,
                    memorySnapshot: memorySnapshot,
                    datasetTitles: datasetTitles
                )
            }
            appendChatBehaviorGuidance(to: &base)
            appendScratchpadGuidance(to: &base, scratchpadSnapshot: scratchpadSnapshot)
            return base
        }
        let attachedCount = supportsImageInput ? pendingImageURLs.count : 0
        let hasAttachedImages = supportsImageInput && attachedCount > 0
        var base = SystemPromptResolver.general(
            currentFormat: loadedFormat,
            isVisionCapable: supportsImageInput,
            hasAttachedImages: hasAttachedImages,
            attachedImageCount: hasAttachedImages ? attachedCount : nil,
            includeThinkRestriction: includeThinkRestriction,
            toolAvailabilityOverride: toolAvailability,
            memorySnapshot: memorySnapshot,
            datasetTitles: datasetTitles,
            // GGUF conveys tools natively via the server's Jinja `tools` array, and full
            // remote sessions via the request `tools` array. MLX does NOT: several
            // mlx-swift-lm VLM processors (e.g. Qwen35) drop input.tools, so the model
            // never sees the schema — MLX therefore keeps prose tool guidance and relies
            // on the text tool-call parser. Escalated Autopilot turns keep the session's
            // rendering (see the RAG branch note on ChatFormatter's system-text merge).
            useNativeTools: loadedFormat == .gguf || remoteService != nil,
            editableIntro: editableIntro,
            date: conversationStartDate
        )
        appendChatBehaviorGuidance(to: &base)
        appendScratchpadGuidance(to: &base, scratchpadSnapshot: scratchpadSnapshot)
        return base
    }

    private func appendChatBehaviorGuidance(to prompt: inout String) {
        if let guidance = activeChatMode.promptGuidance {
            prompt += "\n\n\(guidance)"
        }
        if let guidance = activeAnswerStyle.promptGuidance {
            prompt += "\n\n\(guidance)"
        }
        let instructions = activeChatInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            prompt += "\n\nPer-chat instructions: \(instructions)"
        }
    }

    private func appendScratchpadGuidance(to prompt: inout String, scratchpadSnapshot: String?) {
        guard let scratchpadSnapshot = scratchpadSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines),
              !scratchpadSnapshot.isEmpty else { return }
        prompt += """

        Referenced private scratchpad and pinned results:
        The user explicitly referenced saved, pinned, bookmarked, or scratchpad context for this turn. Use the following local chat notes as context. Do not mention this section unless it helps answer the user.

        \(scratchpadSnapshot)
        """
    }

    private func referencedScratchpadSnapshot(for userInput: String) -> String? {
        let snapshot = activeScratchpad.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.isEmpty else { return nil }
        let normalized = userInput.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let referenceTerms = [
            "scratchpad",
            "pinned",
            "saved note",
            "saved result",
            "bookmark",
            "bookmarked",
            "that result",
            "the result you saved"
        ]
        guard referenceTerms.contains(where: { normalized.contains($0) }) else { return nil }
        return snapshot
    }

    private func resolveMemoryPromptBudget(
        using dataset: LocalDataset?,
        history: [Msg]?,
        toolAvailability: ToolAvailability,
        includeThinkRestriction: Bool
    ) -> MemoryPromptBudgetPlan {
        let isActive = toolAvailability.memory && hasActiveChatModel
        let allEntries = MemoryStore.shared.entries
        guard isActive else { return MemoryPromptBudgetPlan(entries: [], status: .inactive) }

        let effectiveHistory = history ?? msgs
        let basePrompt = renderSystemPromptText(
            using: dataset,
            toolAvailability: toolAvailability,
            includeThinkRestriction: includeThinkRestriction,
            memorySnapshot: nil,
            scratchpadSnapshot: activeTurnScratchpadSnapshot,
            editableIntro: effectiveEditableSystemPromptIntro
        )
        let basePromptTokens = estimatedPromptTokens(
            for: effectiveHistory,
            systemPrompt: basePrompt
        )
        let promptLimit = contextSoftLimitTokens()

        return MemoryPromptBudgeter.plan(
            entries: allEntries,
            isActive: true,
            promptTokenLimit: promptLimit,
            basePromptTokens: basePromptTokens
        ) { candidateEntries in
            let snapshot = MemoryStore.promptSnapshot(entries: candidateEntries)
            let prompt = renderSystemPromptText(
                using: dataset,
                toolAvailability: toolAvailability,
                includeThinkRestriction: includeThinkRestriction,
                memorySnapshot: snapshot,
                scratchpadSnapshot: activeTurnScratchpadSnapshot,
                editableIntro: effectiveEditableSystemPromptIntro
            )
            return estimatedPromptTokens(for: effectiveHistory, systemPrompt: prompt)
        }
    }

    func resolvedSystemPromptContext(
        using dataset: LocalDataset?,
        history: [Msg]? = nil
    ) -> (text: String, memoryPlan: MemoryPromptBudgetPlan) {
        let rawToolAvailability = systemPromptToolAvailabilityOverride ?? ToolAvailability.current(currentFormat: loadedFormat)
        let toolAvailability = activeToolPermissions.filtered(
            rawToolAvailability,
            datasetSearchAllowed: !isPDFOnlyDocumentAccess
        )
        let includeThinkRestriction = activeRemoteBackendID == nil
        let memoryPlan = resolveMemoryPromptBudget(
            using: dataset,
            history: history,
            toolAvailability: toolAvailability,
            includeThinkRestriction: includeThinkRestriction
        )
        let text = renderSystemPromptText(
            using: dataset,
            toolAvailability: toolAvailability,
            includeThinkRestriction: includeThinkRestriction,
            memorySnapshot: memoryPlan.snapshot,
            scratchpadSnapshot: activeTurnScratchpadSnapshot,
            editableIntro: effectiveEditableSystemPromptIntro
        )
        return (text: text, memoryPlan: memoryPlan)
    }

    private func makeSystemPromptText(using dataset: LocalDataset?, history: [Msg]? = nil) -> String {
        resolvedSystemPromptContext(using: dataset, history: history).text
    }

    /// Returns the active system prompt text based on user settings.
    var systemPromptText: String {
        makeSystemPromptText(using: activeSessionPromptDataset)
    }

    var baselineSystemPromptText: String {
        makeSystemPromptText(using: nil)
    }

    /// Removes any accidental anti-reasoning directives such as "/nothink" from the system prompt
    /// while preserving the intended guidance (we rely on <think> tags to contain reasoning).
    private func sanitizeSystemPrompt(_ s: String) -> String {
        var t = s
        // Remove common variants of nothink flags if present
        let patterns = ["/nothink", "\\bnothink\\b", "no-think", "no think"]
        for p in patterns {
            if let rx = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: (t as NSString).length)
                t = rx.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
            } else {
                t = t.replacingOccurrences(of: p, with: "", options: .caseInsensitive)
            }
        }
        // Normalize whitespace after removals
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var currentKind: ModelKind = .other
    var usePrompt = true

    var gemmaAutoTemplated = false
    private var runCounter = 0
    private var activeRunID = 0
    var activeRunIDForAutopilot: Int { activeRunID }
    var currentAutoRoutingTask: Task<AutoRoutingOutcome?, Never>?
    private var currentAutoRoutingTaskID: UUID?
    private var currentAutoRoutingAwaiter: AutoRoutingAwaiter?
    private var deferredAutoRoutingFallback: (outcome: AutoRoutingOutcome, reason: String)?
    private var autoRoutingOutcomeProviderForTesting: (@MainActor () async -> AutoRoutingOutcome?)?
    // Persist the same model conversation across tool calls; no reset flags
    var currentStreamTask: Task<Void, Never>?
    var currentContextTask: Task<ResolvedRAGContext?, Never>?
    var titleTask: Task<Void, Never>?
    // J-Space lens counterfactual re-run (steered "what-if" of the last turn).
    @Published var jspaceCounterfactualRunning = false
    var jspaceCounterfactualTask: Task<Void, Never>?
    /// Latched synchronously the moment a normal send commits, before its first
    /// `await`, and cleared when `sendMessage` returns. Closes the window where a
    /// J-Space counterfactual could start during a send's async setup and drive the
    /// shared MLX client concurrently (the streaming placeholder — hence `isStreaming`
    /// — doesn't exist yet during that setup).
    private var sendInFlightID: UUID?
    var sendInFlight: Bool { sendInFlightID != nil }
    var idleUnloadGeneration: UUID?
    var idleUnloadInProgress: Bool { idleUnloadGeneration != nil }
    private var currentContinuationTask: Task<Void, Never>?
    private var currentContinuationTaskID: UUID?
    private var stopAfterParagraphBaselineCharacterCount: Int?
    private var lastTitledMessageID: UUID?
    private var lastTitledHash: Int?
    var loadedURL: URL?
    var loadedSettings: ModelSettings? {
        didSet {
            refreshSystemPromptForActiveSession()
        }
    }
    /// A per-chat seed for GGUF requests when the model has no explicit seed.
    /// Kept on the view model so it is request scoped instead of process global.
    var sessionGenerationSeed: Int?
    var loadedFormat: ModelFormat? {
        didSet {
            refreshSystemPromptForActiveSession()
        }
    }

    /// Whether the loaded model can act on the reasoning toggle (its runtime honors an
    /// enable/disable-thinking switch — see `ReasoningCapabilityDetector`). Drives
    /// visibility of the reasoning control in the chat context bar. Set at load; false
    /// when nothing is loaded or the active model is remote.
    @Published var currentModelSupportsReasoning: Bool = false

    /// Live reasoning preference for the loaded model. Mirrors
    /// `loadedSettings.reasoningEnabled` (which isn't `@Published`) so the context-bar
    /// toggle re-renders on change. Toggling it from the context bar auto-persists to
    /// the loaded model's durable settings; Model Settings edits its own draft instead.
    @Published var reasoningEnabled: Bool = true

    func invalidateActiveRun() {
        runCounter &+= 1
        activeRunID = runCounter
    }

    /// Cancels the pre-generation router request and clears its UI state. Some
    /// session/model teardown paths run before `currentStreamTask` exists, so
    /// they must stop this task independently of the response stream.
    @discardableResult
    func cancelAutoRoutingTask(
        invalidateRun: Bool = false,
        resolvingWith outcome: AutoRoutingOutcome? = nil
    ) -> Bool {
        if invalidateRun {
            invalidateActiveRun()
        }
        let awaiter = currentAutoRoutingAwaiter
        currentAutoRoutingTask?.cancel()
        currentAutoRoutingTask = nil
        currentAutoRoutingTaskID = nil
        currentAutoRoutingAwaiter = nil
        deferredAutoRoutingFallback = nil
        autoRoutingStage = .none
        return awaiter?.resolve(outcome) ?? false
    }

    /// Automatic lifecycle and memory-pressure handling must abandon only the
    /// AFM verdict, not the user's entire send. Resolve the router wait with an
    /// explicit local receipt while the canceled system request retires behind
    /// AFM's own single-flight gate.
    @discardableResult
    func cancelAutoRoutingAndContinueLocally(reason: String) -> Bool {
        guard autoRoutingStage == .deciding || currentAutoRoutingTask != nil else {
            return false
        }
        let fallback = localRoutingFallbackOutcome()
        let runID = activeRunID
        let didResolve = cancelAutoRoutingTask(resolvingWith: fallback)
        guard didResolve else { return false }
        Task {
            await logger.log("[Autopilot][LifecycleFallback] reason=\(reason) run=\(runID) action=continue-local")
        }
        return true
    }

    /// Entering the real background cancels the framework request but keeps the
    /// user's send suspended on its existing placeholder. Local inference only
    /// starts after the scene becomes active again.
    @discardableResult
    func deferAutoRoutingLocallyUntilActive(reason: String) -> Bool {
        guard autoRoutingStage == .deciding,
              let awaiter = currentAutoRoutingAwaiter,
              !awaiter.isResolved else { return false }
        currentAutoRoutingTask?.cancel()
        currentAutoRoutingTask = nil
        currentAutoRoutingTaskID = nil
        deferredAutoRoutingFallback = (localRoutingFallbackOutcome(), reason)
        Task {
            await logger.log(
                "[Autopilot][LifecycleFallback] reason=\(reason) action=defer-local-until-active"
            )
        }
        return true
    }

    @discardableResult
    func resumeDeferredAutoRoutingIfNeeded() -> Bool {
        guard let deferredAutoRoutingFallback,
              let awaiter = currentAutoRoutingAwaiter else { return false }
        self.deferredAutoRoutingFallback = nil
        currentAutoRoutingTask = nil
        currentAutoRoutingTaskID = nil
        currentAutoRoutingAwaiter = nil
        autoRoutingStage = .none
        let didResolve = awaiter.resolve(deferredAutoRoutingFallback.outcome)
        if didResolve {
            Task {
                await logger.log(
                    "[Autopilot][LifecycleFallback] reason=\(deferredAutoRoutingFallback.reason) action=resume-local"
                )
            }
        }
        return didResolve
    }

    private func localRoutingFallbackOutcome() -> AutoRoutingOutcome {
        let reasonKey = AutopilotReasonKey.routerUnreachable
        return AutoRoutingOutcome(
            decision: AutoRouteDecision(
                target: .local,
                confidence: 1,
                reason: AutopilotReasonKey.localized(reasonKey),
                reasonKey: reasonKey,
                category: .other,
                estDifficulty: 1,
                latencyMs: 0,
                decidedBy: .heuristic
            ),
            escalation: nil,
            escalationBackendName: nil,
            escalationModelName: nil,
            routerPromptTokens: nil,
            routerCompletionTokens: nil
        )
    }

    var loadedModelURL: URL? { loadedURL }
    var loadedModelSettings: ModelSettings? { loadedSettings }
    var loadedModelFormat: ModelFormat? { loadedFormat }
    var currentInjectedTokenOverhead: Int = 0

    func setLoadedStateForTesting(
        modelLoaded: Bool? = nil,
        loadedURL: URL? = nil,
        loadedFormat: ModelFormat? = nil,
        loadedSettings: ModelSettings? = nil
    ) {
        if let modelLoaded {
            self.modelLoaded = modelLoaded
        }
        self.loadedURL = loadedURL
        self.loadedFormat = loadedFormat
        if let loadedSettings {
            self.loadedSettings = loadedSettings.normalizedSystemPromptSettings()
        }
    }

    func setClientForTesting(
        _ client: AnyLLMClient?,
        modelLoaded: Bool? = nil,
        loadedURL: URL? = nil,
        loadedFormat: ModelFormat? = nil,
        loadedSettings: ModelSettings? = nil
    ) {
        self.client = client
        if let modelLoaded {
            self.modelLoaded = modelLoaded
        }
        self.loadedURL = loadedURL
        self.loadedFormat = loadedFormat
        if let loadedSettings {
            self.loadedSettings = loadedSettings.normalizedSystemPromptSettings()
        }
    }

    func setStreamSessionIndexForTesting(_ index: Int?) {
        streamSessionIndex = index
    }

    func setAutoRoutingLifecycleStateForTesting(sendInFlight: Bool, stage: AutoRoutingStage) {
        sendInFlightID = sendInFlight ? UUID() : nil
        autoRoutingStage = stage
    }

    func prepareAutoRoutingWaitForTesting(sendInFlight: Bool = true) -> AutoRoutingAwaiter {
        let awaiter = AutoRoutingAwaiter()
        currentAutoRoutingAwaiter = awaiter
        currentAutoRoutingTaskID = UUID()
        sendInFlightID = sendInFlight ? UUID() : nil
        autoRoutingStage = .deciding
        return awaiter
    }

    func setAutoRoutingOutcomeProviderForTesting(
        _ provider: (@MainActor () async -> AutoRoutingOutcome?)?
    ) {
        autoRoutingOutcomeProviderForTesting = provider
    }

    func syncActiveLocalModelPromptSettingsIfNeeded(model: LocalModel, settings: ModelSettings) {
        guard activeRemoteBackendID == nil,
              let loadedURL,
              let loadedFormat else { return }

        let normalizedLoadedURL = InstalledModelsStore.canonicalURL(for: loadedURL, format: loadedFormat)
        let normalizedModelURL = InstalledModelsStore.canonicalURL(for: model.url, format: model.format)
        guard normalizedLoadedURL == normalizedModelURL else { return }

        if loadedFormat == .gguf, settings.loadVisionProjector == false {
            if var activeSettings = loadedSettings {
                activeSettings.loadVisionProjector = false
                loadedSettings = activeSettings
            }
            supportsImageInput = false
            while !pendingImageURLs.isEmpty {
                removePendingImage(at: pendingImageURLs.count - 1)
            }
        }
        applyActivePromptSettings(settings)
    }

    /// Applies sampling edits from Chat's live sidebar to the resident model.
    /// Backends receive these values as request-scoped generation options, so
    /// changing a dial affects the next reply without forcing a model reload.
    func syncActiveLocalModelSamplingSettingsIfNeeded(model: LocalModel, settings: ModelSettings) {
        guard activeRemoteBackendID == nil,
              let loadedURL,
              let loadedFormat else { return }

        let normalizedLoadedURL = InstalledModelsStore.canonicalURL(for: loadedURL, format: loadedFormat)
        let normalizedModelURL = InstalledModelsStore.canonicalURL(for: model.url, format: model.format)
        guard normalizedLoadedURL == normalizedModelURL else { return }

        var updatedSettings = loadedSettings ?? settings
        updatedSettings.applySamplingSettings(from: settings)
        guard updatedSettings != loadedSettings else { return }
        loadedSettings = updatedSettings

        // GGUF sampling is injected into each request; the immutable running
        // server configuration is never mutated through process environment.
    }

    func syncActiveRemoteModelPromptSettingsIfNeeded(
        backendID: RemoteBackend.ID,
        modelID: String,
        settings: ModelSettings
    ) {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeRemoteBackendID == backendID,
              activeRemoteModelID == normalizedModelID else { return }

        applyActivePromptSettings(settings)
    }

    /// Toggles reasoning for the loaded model from the chat context bar. Unlike Model
    /// Settings (which edits a draft committed on Save/Load), this writes through
    /// immediately: it updates the in-memory `loadedSettings` so the next message honors
    /// it without a reload, and persists to the local model's durable settings.
    func setReasoningEnabled(_ enabled: Bool) {
        reasoningEnabled = enabled
        guard var settings = loadedSettings else { return }
        guard settings.reasoningEnabled != enabled else { return }
        settings.reasoningEnabled = enabled
        loadedSettings = settings
        // Auto-save to the loaded local model. Remote models don't carry per-model
        // ModelSettings here, so their toggle stays session-scoped.
        if activeRemoteBackendID == nil, let model = modelManager?.loadedModel {
            modelManager?.updateSettings(settings, for: model)
        }
    }

    /// Returns `input` with the active local model's live reasoning and sampling
    /// preferences applied as request-scoped generation options. Explicit caller
    /// overrides win. Remote/escalated turns manage their own options.
    func applyingLoadedReasoningPreference(to input: LLMInput) -> LLMInput {
        guard activeRemoteBackendID == nil,
              remoteService == nil,
              let settings = loadedSettings else {
            return input
        }
        var options = input.generationOptions
        if options.reasoningEnabled == nil { options.reasoningEnabled = settings.reasoningEnabled }
        if options.seed == nil { options.seed = settings.seed ?? sessionGenerationSeed }
        if options.temperature == nil { options.temperature = settings.temperature }
        if options.topK == nil { options.topK = settings.topK }
        if options.topP == nil { options.topP = settings.topP }
        if options.minP == nil { options.minP = settings.minP }
        if options.repeatPenalty == nil { options.repeatPenalty = Double(settings.repetitionPenalty) }
        if options.repeatLastN == nil { options.repeatLastN = settings.repeatLastN }
        if options.presencePenalty == nil { options.presencePenalty = Double(settings.presencePenalty) }
        if options.frequencyPenalty == nil { options.frequencyPenalty = Double(settings.frequencyPenalty) }
        if options.logitBias == nil { options.logitBias = settings.logitBias }
        if options.promptCache == nil { options.promptCache = settings.promptCacheEnabled }
        return LLMInput(input.content, generationOptions: options)
    }

    private func applyActivePromptSettings(_ settings: ModelSettings) {
        let normalized = settings.normalizedSystemPromptSettings()
        var updatedSettings = loadedSettings ?? normalized
        updatedSettings.systemPromptMode = normalized.systemPromptMode
        updatedSettings.systemPromptOverride = normalized.systemPromptOverride
        // Keep the reasoning toggle in sync when Model Settings is saved for the active
        // model, so the context bar and the next generation reflect the saved value.
        updatedSettings.reasoningEnabled = normalized.reasoningEnabled
        reasoningEnabled = normalized.reasoningEnabled
        loadedSettings = updatedSettings

        guard let client,
              loadedFormat == .et || loadedFormat == .ane || loadedFormat == .afm else {
            return
        }

        let prompt = systemPromptText
        Task {
            await client.syncSystemPrompt(prompt)
        }
    }

    /// Reference to the global model manager so the chat view model can access
    /// the currently selected dataset for RAG lookups.
    weak var modelManager: AppModelManager? {
        didSet {
            syncModelManagerDatasetForActiveSession()
        }
    }
    /// Dataset manager used to track indexing status while performing
    /// retrieval or injection. Held weakly since it is owned by the
    /// main view hierarchy.
    weak var datasetManager: DatasetManager?

    var client: AnyLLMClient? {
        didSet {
            etRuntimeSessionID = nil
            // A newly attached runtime supersedes any older teardown that may
            // still be awaiting a non-cooperative backend. Its eventual defer
            // must not block or clear policy ownership for the new client.
            if client != nil {
                idleUnloadGeneration = nil
            }
        }
    }
    /// Session whose turn history currently owns ExecuTorch's persistent KV
    /// cache. A nil value forces one complete compacted-history replay.
    var etRuntimeSessionID: Session.ID?
    var remoteService: RemoteChatService?
    var activeRemoteBackendID: RemoteBackend.ID?
    var activeRemoteModelID: String?
    var remoteLoadingPending = false
    /// Autopilot: non-nil while a per-turn router decision is in flight, so the
    /// status bar and ESCALATION row can show the deciding state.
    @Published var autoRoutingStage: AutoRoutingStage = .none
    /// Cancels the current turn's escalated RemoteChatService stream; the turn
    /// service is not `self.remoteService`, so `stop()` needs this extra hook.
    var currentTurnEscalationCancel: (() -> Void)?
    /// One-shot route pin set by "Redo On-Device"/"Redo on Cloud"; consumed by
    /// the next routing pass.
    var pendingForcedRoute: AutoRouteTarget?
    var toolSpecsCache: [ToolSpec] = []
    var systemPromptToolAvailabilityOverride: ToolAvailability?
    private var promptRefreshCancellables: Set<AnyCancellable> = []
#if canImport(AVFoundation)
    var audioRecorder: AVAudioRecorder?
    var audioRecordingURL: URL?
    var audioRecordingFriendlyName: String?
    var audioRecordingMeterTask: Task<Void, Never>?
#endif
    var liveDictationTranscriber: (any VoiceLiveTranscriber)?
    var dictationEventsTask: Task<Void, Never>?
    var dictationBaseText: String = ""
    var mediaTranscriptionTasks: [ChatMediaAttachment.ID: Task<Void, Never>] = [:]

    @AppStorage("verboseLogging") var verboseLogging = false
    @AppStorage("ragMaxChunks") private var ragMaxChunks = 5
    @AppStorage("ragMinScore") private var ragMinScore = 0.5
    @AppStorage("ragRetrievalMode") private var ragRetrievalModeRaw = DatasetRetrievalMode.defaultValue.rawValue
    @AppStorage("contextOverflowStrategy") var contextOverflowStrategyRaw = ContextOverflowStrategy.defaultValue.rawValue
    @AppStorage(ChatAttachmentCleanupPolicy.storageKey) var attachmentCleanupPolicyRaw = ChatAttachmentCleanupPolicy.defaultValue.rawValue
    @AppStorage(SystemPreset.customSystemPromptIntroKey) private var customSystemPromptIntro = SystemPreset.defaultEditableIntro

    private var fullDatasetContentCache: [String: String] = [:]
    private var lastResolvedSystemPromptIntro = SystemPreset.resolvedEditableIntro(userDefaults: .standard)

    init() {
        if let data = try? Data(contentsOf: Self.sessionsURL()),
           let decoded = try? JSONDecoder().decode([Session].self, from: data),
           !decoded.isEmpty {
            sessions = decoded
            activeSessionID = decoded.first?.id
        } else {
            let system = Msg(role: "system", text: systemPromptText, timestamp: Date())
            let first = Session(title: "New chat", messages: [system], date: Date(), datasetID: "")
            sessions = [first]
            activeSessionID = first.id
        }
        // Recreate rolling thought view models for loaded sessions
        recreateRollingThoughtViewModels()
        syncModelManagerDatasetForActiveSession()
        refreshSystemPromptForActiveSession()
        // Ensure tools are registered early so calls are executable during the first run
        initializeToolSystem()
        // Defer disk-bound, non-critical startup work off the first-paint path: legacy attachment
        // path migration (may full re-encode + write), attachment garbage collection (directory
        // walk), and Spotlight chat-title indexing. The session decode above stays synchronous so
        // the persisted history is never clobbered by the `sessions` didSet save before it loads.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.migrateLegacyAttachmentPathsIfNeeded() {
                self.saveSessions()
            }
            _ = self.garbageCollectAttachmentFilesIfNeeded(force: false)
            self.scheduleSpotlightChatTitleIndex()
        }
        NotificationCenter.default.publisher(for: .memoryStoreDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.toolSpecsCache = []
                    if let remoteService = self.remoteService {
                        let specs = PhoneAFriendGate.strippingHandoff(from: await self.fetchEnabledToolSpecs())
                        self.systemPromptToolAvailabilityOverride = self.toolAvailability(from: specs)
                        await remoteService.updateToolSpecs(specs)
                    } else {
                        self.systemPromptToolAvailabilityOverride = nil
                    }
                    self.refreshSystemPromptForActiveSession()
                    if let client = self.client,
                       self.loadedFormat == .et || self.loadedFormat == .ane || self.loadedFormat == .afm {
                        await client.syncSystemPrompt(self.systemPromptText)
                    }
                }
            }
            .store(in: &promptRefreshCancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let resolvedIntro = SystemPreset.resolvedEditableIntro(from: self.customSystemPromptIntro)
                    guard resolvedIntro != self.lastResolvedSystemPromptIntro else { return }
                    self.lastResolvedSystemPromptIntro = resolvedIntro
                    self.refreshSystemPromptForActiveSession()
                    if let client = self.client,
                       self.loadedFormat == .et || self.loadedFormat == .ane || self.loadedFormat == .afm {
                        await client.syncSystemPrompt(self.systemPromptText)
                    }
                }
            }
            .store(in: &promptRefreshCancellables)
#if os(macOS)
        syncActiveMCPToolSelection()
#endif
    }

    var lastSessionsSaveAt: ContinuousClock.Instant?
    var pendingSessionsSave = false
    func setScratchpadForActiveSession(_ text: String) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].scratchpad = trimmed.isEmpty ? nil : text
    }

    func pinMessageTextToActiveScratchpad(_ text: String, role: String, timestamp: Date) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let roleTitle: String
        if role == "🧑‍💻" || role.lowercased() == "user" {
            roleTitle = String(localized: "User")
        } else if role == "🤖" || role.lowercased() == "assistant" {
            roleTitle = String(localized: "Assistant")
        } else {
            roleTitle = String(localized: "Message")
        }
        let title = String.localizedStringWithFormat(String(localized: "Pinned %@ message"), roleTitle)
        let date = DateFormatter.localizedString(from: timestamp, dateStyle: .medium, timeStyle: .short)
        let block = "### \(title) - \(date)\n\(trimmed)"
        let existing = (sessions[idx].scratchpad ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].scratchpad = existing.isEmpty ? block : existing + "\n\n" + block
    }

    func pinToolCallToActiveScratchpad(_ toolCall: Msg.ToolCall) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }

        let resultText = toolCall.result?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = toolCall.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resultText?.isEmpty == false || errorText?.isEmpty == false else { return }

        let title = String.localizedStringWithFormat(String(localized: "Pinned %@ result"), toolCall.displayName)
        let date = DateFormatter.localizedString(from: toolCall.timestamp, dateStyle: .medium, timeStyle: .short)
        var sections = [
            "### \(title) - \(date)",
            "\(String(localized: "Tool")): \(toolCall.toolName)"
        ]
        if let resultText, !resultText.isEmpty {
            sections.append("\(String(localized: "Result")):\n\(ToolCallViewSupport.formatRawResult(resultText))")
        }
        if let errorText, !errorText.isEmpty {
            sections.append("\(String(localized: "Error")):\n\(errorText)")
        }
        let block = sections.joined(separator: "\n\n")
        let existing = (sessions[idx].scratchpad ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].scratchpad = existing.isEmpty ? block : existing + "\n\n" + block
    }

    func requestToolCallRepair(_ toolCall: Msg.ToolCall) async {
        guard canAcceptChatInput else { return }
        guard !isStreamingInAnotherSession else {
            crossSessionSendBlocked = true
            return
        }

        var details = [
            "\(String(localized: "Tool")): \(toolCall.toolName)"
        ]
        if !toolCall.requestParams.isEmpty {
            let params = toolCall.requestParams.keys.sorted().map { key in
                "\(key): \(ToolCallViewSupport.formatParameterValue(toolCall.requestParams[key]?.value))"
            }.joined(separator: "\n")
            details.append("\(String(localized: "Request Parameters")):\n\(params)")
        }
        if let error = toolCall.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            details.append("\(String(localized: "Error")):\n\(error)")
        }
        if let result = toolCall.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            details.append("\(String(localized: "Raw Response")):\n\(ToolCallViewSupport.formatRawResult(result))")
        }

        let prompt = String.localizedStringWithFormat(
            String(localized: "Repair this failed tool call. Explain what likely went wrong, propose corrected arguments, and rerun the tool only if it is safe and useful.\n\n%@"),
            details.joined(separator: "\n\n")
        )
        await sendMessage(prompt)
    }

    func setChatInstructionsForActiveSession(_ text: String) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].chatInstructions = trimmed.isEmpty ? nil : text
        refreshSystemPromptForActiveSession()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let client = self.client, self.modelLoaded {
                await client.syncSystemPrompt(self.systemPromptText)
            }
        }
    }

    func setChatModeForActiveSession(_ mode: ChatMode) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        sessions[idx].chatMode = mode == .general ? nil : mode
        refreshSystemPromptForActiveSession()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let client = self.client, self.modelLoaded {
                await client.syncSystemPrompt(self.systemPromptText)
            }
        }
    }

    func setAnswerStyleForActiveSession(_ style: AnswerStyle) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        sessions[idx].answerStyle = style == .natural ? nil : style
        refreshSystemPromptForActiveSession()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let client = self.client, self.modelLoaded {
                await client.syncSystemPrompt(self.systemPromptText)
            }
        }
    }

    func setToolPermissionForActiveSession(_ kind: ChatToolPermissionKind, enabled: Bool) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        var permissions = sessions[idx].toolPermissions ?? .allEnabled
        switch kind {
        case .webSearch:
            permissions.webSearch = enabled
        case .python:
            permissions.python = enabled
        case .memory:
            permissions.memory = enabled
        case .datasetRetrieval:
            permissions.datasetRetrieval = enabled
        }
        applyToolPermissionsToActiveSession(permissions)
    }

    func setAllToolPermissionsForActiveSession(enabled: Bool) {
        applyToolPermissionsToActiveSession(enabled ? .allEnabled : .allDisabled)
    }

#if os(macOS)
    func setMCPServerPermissionForActiveSession(_ serverID: String, enabled: Bool) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        var permissions = sessions[idx].toolPermissions ?? .allEnabled
        if enabled { permissions.selectedMCPServerIDs.insert(serverID) }
        else { permissions.selectedMCPServerIDs.remove(serverID) }
        // Context-bar MCP choices also define the default for future chats. Without
        // writing the disabled state here, a new chat would silently re-enable a
        // server from the last stored default even though the user had turned it off.
        MCPChatDefaults.setSelected(serverID, enabled: enabled)
        applyToolPermissionsToActiveSession(permissions)
    }
#endif

    private func applyToolPermissionsToActiveSession(_ permissions: ChatToolPermissions) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        sessions[idx].toolPermissions = permissions
#if os(macOS)
        syncActiveMCPToolSelection()
#endif
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshPDFToolPresence()
            self.toolSpecsCache = []
            self.systemPromptToolAvailabilityOverride = nil
            if let remoteService = self.remoteService {
                let specs = PhoneAFriendGate.strippingHandoff(from: await self.fetchEnabledToolSpecs())
                await remoteService.updateToolSpecs(specs)
                let availability = self.toolAvailability(from: specs)
                self.systemPromptToolAvailabilityOverride = availability.any ? availability : nil
            }
            self.refreshSystemPromptForActiveSession()
            if let client = self.client,
               self.loadedFormat == .et || self.loadedFormat == .ane || self.loadedFormat == .afm {
                await client.syncSystemPrompt(self.systemPromptText)
            }
        }
    }

#if os(macOS)
    private func syncActiveMCPToolSelection() {
        MCPServerManager.shared.setActiveChatSelection(
            serverIDs: activeToolPermissions.selectedMCPServerIDs
        )
    }
#endif

    var streamSessionIndex: Int?

    /// Live text of the in-flight assistant message. Token updates flow here instead of
    /// into `sessions` so they don't force every observer of `ChatVM` to re-render.
    /// Held as a plain `let` so updates don't trip `ChatVM.objectWillChange`.
    let streamingStore = StreamingMessageStore()

    /// Fires once per assistant-turn outcome; `.continuingWithTool` marks
    /// segment ends that will stream more (see `AssistantTurnEvent`).
    let assistantTurnEvents = PassthroughSubject<AssistantTurnEvent, Never>()

    var streamMsgs: [Msg] {
        get {
            if let idx = streamSessionIndex, sessions.indices.contains(idx) {
                return sessions[idx].messages
            }
            return msgs
        }
        set {
            if let idx = streamSessionIndex, sessions.indices.contains(idx) {
                sessions[idx].messages = newValue
            } else {
                msgs = newValue
            }
        }
    }

    var msgs: [Msg] {
        get { activeIndex.flatMap { sessions[$0].messages } ?? [] }
        set {
            if let idx = activeIndex { sessions[idx].messages = newValue }
        }
    }

    func toggleBookmark(messageID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { session in
            session.messages.contains(where: { $0.id == messageID })
        }),
        let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        sessions[sessionIndex].messages[messageIndex].isBookmarked.toggle()
    }

    func regenerateAssistantResponse(messageID: UUID) async {
        guard !isStreamingInAnotherSession else {
            crossSessionSendBlocked = true
            return
        }
        guard let sessionIndex = activeIndex,
              sessions.indices.contains(sessionIndex),
              let assistantIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        let message = sessions[sessionIndex].messages[assistantIndex]
        guard message.role == "🤖" || message.role.lowercased() == "assistant" else { return }
        guard let userIndex = sessions[sessionIndex].messages[..<assistantIndex].lastIndex(where: { candidate in
            candidate.role == "🧑‍💻" || candidate.role.lowercased() == "user"
        }) else { return }

        let userMessage = sessions[sessionIndex].messages[userIndex]
        let text = userMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        cancelAutoRoutingTask(invalidateRun: true)
        currentStreamTask?.cancel()
        cancelTurnScopedEscalationAndContinuation()
        streamSessionIndex = nil
        sessions[sessionIndex].messages = Array(sessions[sessionIndex].messages.prefix(userIndex))
        refreshSystemPromptForActiveSession()
        await sendMessage(text)
    }

    @discardableResult
    func prepareAskSamePromptWithAnotherModel(messageID: UUID) -> Bool {
        guard let sourceIndex = activeIndex,
              sessions.indices.contains(sourceIndex),
              let assistantIndex = sessions[sourceIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return false
        }

        let message = sessions[sourceIndex].messages[assistantIndex]
        guard message.role == "🤖" || message.role.lowercased() == "assistant" else { return false }
        guard let userIndex = sessions[sourceIndex].messages[..<assistantIndex].lastIndex(where: { candidate in
            candidate.role == "🧑‍💻" || candidate.role.lowercased() == "user"
        }) else { return false }

        let userMessage = sessions[sourceIndex].messages[userIndex]
        let text = userMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let source = sessions[sourceIndex]
        var branchedMessages = Array(source.messages.prefix(userIndex))
        if !branchedMessages.contains(where: { $0.role.lowercased() == "system" }) {
            branchedMessages.insert(Msg(role: "system", text: baselineSystemPromptText, timestamp: Date()), at: 0)
        }

        let sourceTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = Self.defaultTitle()
        let branchTitle = String.localizedStringWithFormat(
            String(localized: "Compare: %@"),
            sourceTitle.isEmpty ? fallbackTitle : sourceTitle
        )
        let branch = Session(
            title: branchTitle,
            messages: branchedMessages,
            date: Date(),
            datasetID: source.datasetID,
            toolPermissions: source.toolPermissions,
            scratchpad: source.scratchpad,
            chatMode: source.chatMode,
            answerStyle: source.answerStyle,
            chatInstructions: source.chatInstructions
        )

        sessions.insert(branch, at: 0)
        activeSessionID = branch.id
        prompt = text
        injectionStage = .none
        injectionMethod = nil
        refreshSystemPromptForActiveSession()
        return true
    }

    var isStreaming: Bool { msgs.last?.streaming == true }

    var isStreamingInAnotherSession: Bool {
        guard let streamIdx = streamSessionIndex else { return false }
        if let activeIdx = activeIndex, streamIdx == activeIdx { return false }
        guard sessions.indices.contains(streamIdx) else { return false }
        return sessions[streamIdx].messages.last?.streaming == true
    }

    var totalTokens: Int {
        var total = msgs.compactMap { $0.perf?.tokenCount }.reduce(into: 0) {
            $0 = Self.saturatingTokenAdd($0, max(0, $1))
        }
        // Include injected dataset token overhead
        total = Self.saturatingTokenAdd(total, max(0, currentInjectedTokenOverhead))
        // Include system prompt tokens (fast sync estimate)
        total = Self.saturatingTokenAdd(total, estimateTokensSync(systemPromptText))
        // Include all user prompt tokens (fast sync estimate)
        let userText = msgs.filter { $0.role == "🧑‍💻" || $0.role.lowercased() == "user" }.map { $0.text }.joined(separator: "\n")
        total = Self.saturatingTokenAdd(total, estimateTokensSync(userText))
        // Include web/tool result tokens (reinjected into prompt as <tool_response> blocks)
        let toolText = msgs.last?.toolCalls?
            .compactMap { $0.result }
            .joined(separator: "\n") ?? ""
        total = Self.saturatingTokenAdd(total, estimateTokensSync(toolText))
        // Include dataset RAG injected context tokens only when not already counted via full injection overhead
        if currentInjectedTokenOverhead == 0, let ctx = msgs.last?.retrievedContext, !ctx.isEmpty {
            total = Self.saturatingTokenAdd(total, estimateTokensSync(ctx))
        }
        return total
    }

    var toolSchemaTokenCostByName: [String: Int] = [:]
    var toolSchemaCostsLoaded = false
    var toolSchemaCostsLoading = false
    var promptOverheadCache: (key: String, system: Int, tools: Int)?

    /// Cancels work owned by a turn-scoped escalation. The exact turn token is
    /// intentionally released by the owning task's defer after generation has
    /// unwound, never synchronously at run invalidation.
    func cancelTurnScopedEscalationAndContinuation() {
        currentTurnEscalationCancel?()
        currentTurnEscalationCancel = nil
        currentContinuationTask?.cancel()
        currentContinuationTask = nil
        currentContinuationTaskID = nil
    }

    func stop() {
        // Proactively cancel backend generation (llama.cpp) and any in-flight tool calls
        invalidateActiveRun()
        stopAfterParagraphRequested = false
        stopAfterParagraphBaselineCharacterCount = nil
        conversationCompactionInProgressSessionID = nil
        client?.cancelActive()
        cancelTurnScopedEscalationAndContinuation()
        cancelAutoRoutingTask()
        currentContextTask?.cancel()
        currentContextTask = nil
        currentStreamTask?.cancel()
        currentStreamTask = nil
        cancelTurnScopedEscalationAndContinuation()
        titleTask?.cancel()
        titleTask = nil

        // Do not remove rolling thought boxes when stopping; finalize their state instead
        for viewModel in rollingThoughtViewModels.values {
            if viewModel.isLogicallyComplete {
                viewModel.finish()
            } else {
                viewModel.markInterrupted()
            }
        }
        persistRollingThoughtsNow()

        if let activeIdx = activeIndex, sessions.indices.contains(activeIdx) {
            var activeMessages = sessions[activeIdx].messages
            if let idx = activeMessages.indices.last {
                activeMessages[idx].streaming = false
                activeMessages[idx].promptProcessing = nil
            }
            activeMessages = Self.markingInterruptedToolCalls(in: activeMessages)
            sessions[activeIdx].messages = Self.removingCancelledAssistantPlaceholder(from: activeMessages)
        }
        // Also clear streaming flag in the session that was actually streaming
        // (may differ from the active session if the user switched tabs).
        if let sIdx = streamSessionIndex,
           sessions.indices.contains(sIdx) {
            var streamedMessages = sessions[sIdx].messages
            if let idx = streamedMessages.indices.last {
                streamedMessages[idx].streaming = false
                streamedMessages[idx].promptProcessing = nil
            }
            streamedMessages = Self.markingInterruptedToolCalls(in: streamedMessages)
            sessions[sIdx].messages = Self.removingCancelledAssistantPlaceholder(from: streamedMessages)
        }
        injectionStage = .none
        injectionMethod = nil
        streamSessionIndex = nil
        streamingStore.finish()
        assistantTurnEvents.send(.cancelled)
    }

    func requestStopAfterParagraph() {
        guard isStreaming else { return }
        stopAfterParagraphRequested = true
        let visibleText = msgs.last?.text ?? ""
        stopAfterParagraphBaselineCharacterCount = visibleText.count
    }

    private func clearStopAfterParagraphRequest() {
        stopAfterParagraphRequested = false
        stopAfterParagraphBaselineCharacterCount = nil
    }

    private func shouldStopAtRequestedParagraphBoundary(in visibleText: String) -> Bool {
        guard stopAfterParagraphRequested else { return false }
        let baseline = min(stopAfterParagraphBaselineCharacterCount ?? 0, visibleText.count)
        let suffix = String(visibleText.dropFirst(baseline))
        guard suffix.trimmingCharacters(in: .whitespacesAndNewlines).count >= 24 else { return false }
        return suffix.range(of: #"\n\s*\n"#, options: .regularExpression) != nil
    }

    private func markRollingThoughtsInterrupted(forMessageAt index: Int) {
        guard streamMsgs.indices.contains(index) else { return }
        let messageID = streamMsgs[index].id.uuidString
        let prefix = "message-\(messageID)-think-"
        for (key, viewModel) in rollingThoughtViewModels where key.hasPrefix(prefix) {
            if !viewModel.isLogicallyComplete && !viewModel.isPendingCompletion {
                viewModel.markInterrupted()
            }
        }
    }

    private func resetSession() async {
        invalidateActiveRun()
        cancelAutoRoutingTask()
        currentContextTask?.cancel()
        currentContextTask = nil
        currentStreamTask?.cancel()
        currentStreamTask = nil
        titleTask?.cancel()
        titleTask = nil
        client = nil
        modelLoaded = false
        guard let url = loadedURL else { return }
        try? await ensureClient(url: url, settings: loadedSettings, format: loadedFormat, forceReload: false)
        streamSessionIndex = nil
    }

    private func appendUser(_ text: String, purpose: RunPurpose) {
        precondition(purpose == .chat, "appendUser used for non-chat run")
        var m = msgs
        let datasetSnapshot: (id: String, name: String)? = {
            guard let ds = activeSessionRetrievalDataset else { return nil }
            return (ds.datasetID, ds.name)
        }()
        m.append(.init(role: "🧑‍💻",
                       text: text,
                       timestamp: Date(),
                       datasetID: datasetSnapshot?.id,
                       datasetName: datasetSnapshot?.name))
        msgs = m
    }

    private func appendAssistantPlaceholder(purpose: RunPurpose) -> Int {
        precondition(purpose == .chat, "appendAssistant used for non-chat run")
        var m = msgs
        let remoteSession = modelManager?.activeRemoteSession
        m.append(
            .init(
                role: "🤖",
                text: "",
                timestamp: Date(),
                streaming: true,
                promptProcessing: self.supportsPromptProcessingCard ? .init(progress: 0) : nil,
                usedRemoteBackend: remoteSession != nil,
                remoteBackendName: remoteSession?.backendName,
                remoteModelName: remoteSession?.modelName
            )
        )
        msgs = m
        return msgs.index(before: msgs.endIndex)
    }

    // UI callback (legacy) – forwards to sendMessage with captured prompt
    func send() async {
        await sendMessage(prompt)
    }

    /// New send variant that avoids races with UI clearing the prompt by accepting the text explicitly.
    func sendMessage(_ rawInput: String) async {
        clearStopAfterParagraphRequest()
        let visibleInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let completedMediaAttachments = pendingMediaAttachments.filter(\.hasCompletedTranscript)
        guard !visibleInput.isEmpty || !completedMediaAttachments.isEmpty else { return }
        // Latch synchronously before any `await` so a J-Space counterfactual can't
        // slip into this send's async setup and drive the shared MLX client at the
        // same time. Cleared on every exit; `isStreaming` covers the streaming phase
        // once the placeholder message exists.
        let sendID = UUID()
        sendInFlightID = sendID
        defer {
            if sendInFlightID == sendID {
                sendInFlightID = nil
            }
        }
        let input = visibleInput.isEmpty ? String(localized: "Transcribed media attached.") : visibleInput
        let modelInput = Self.promptText(
            userText: visibleInput,
            mediaAttachments: completedMediaAttachments
        )

        await logger.log("[ChatVM][SendAttempt] \(modelInput)")

        if isStreamingInAnotherSession {
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = input
            }
            crossSessionSendBlocked = true
            await logger.log("[ChatVM] Blocking send: another chat is still generating")
            return
        }

        if loading || stillLoading {
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = input
            }
            await logger.log("[ChatVM] Blocking send: model still loading")
            return
        }

        if isStreaming {
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = input
            }
            await logger.log("[ChatVM] Blocking send: current chat is still generating")
            return
        }

        if jspaceCounterfactualRunning {
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = input
            }
            await logger.log("[ChatVM] Blocking send: J-Space counterfactual is running")
            return
        }

        // Deleting the final chat leaves the desktop composer visible with no
        // active session. Treat its next submission as the first turn of a new
        // chat instead of clearing the draft and returning at the activeIndex
        // guard below.
        if activeIndex == nil {
            startNewSession()
        }

        prompt = ""
        activeTurnScratchpadSnapshot = referencedScratchpadSnapshot(for: input)

        let datasetSnapshot: (id: String, name: String)? = {
            guard let ds = activeSessionRetrievalDataset else { return nil }
            return (ds.datasetID, ds.name)
        }()

        if verboseLogging { print("[ChatVM] USER ▶︎ \(input)") }
        await logger.log("[ChatVM] USER ▶︎ \(input)")

        titleTask?.cancel()
        titleTask = nil

        cancelAutoRoutingTask()
        currentStreamTask?.cancel()
        invalidateActiveRun()
        let myID = activeRunID

        guard let sIdx = self.activeIndex else { return }
        streamSessionIndex = sIdx
        // The tools active at send time are now baked into the conversation's running
        // context. Latch them so the context meter keeps counting them even if the user
        // disables a tool later in this conversation.
        commitActiveToolsToContext()
#if os(iOS)
        Haptics.impact(.light)
#endif
        AccessibilityAnnouncer.announceLocalized("Prompt submitted.")
        var didLaunchStreamTask = false
        var turnEscalation: TurnEscalation? = nil
        defer {
            if !didLaunchStreamTask {
                releaseLocalEscalationTurn(turnEscalation)
                streamSessionIndex = nil
            }
        }
        var m = self.streamMsgs
        m.append(.init(role: "🧑‍💻",
                       text: input,
                       timestamp: Date(),
                       datasetID: datasetSnapshot?.id,
                       datasetName: datasetSnapshot?.name))
        self.streamMsgs = m
        // Snapshot attachments at send time so UI can clear the input tray immediately
        // Track which image file paths this specific run uses, so prior/next runs
        // cannot accidentally clear attachments they don't own.
        var usedImagePathsForThisRun: [String] = []
        let attachments = pendingImageURLs.map { $0.path }
        if !attachments.isEmpty {
            m = self.streamMsgs
            let idx = m.index(before: m.endIndex)
            m[idx].imagePaths = attachments
            self.streamMsgs = m
            // Mark these specific paths as the attachments for this run
            usedImagePathsForThisRun = attachments
            // Immediately remove used attachments from the input tray to avoid
            // showing them while generation is in progress. The sent images remain
            // visible on the user message via msg.imagePaths.
            for path in attachments {
                let url = URL(fileURLWithPath: path)
                if let i = pendingImageURLs.firstIndex(of: url) { pendingImageURLs.remove(at: i) }
                pendingThumbnails.removeValue(forKey: url)
            }
        }
        if !completedMediaAttachments.isEmpty {
            m = self.streamMsgs
            let idx = m.index(before: m.endIndex)
            m[idx].mediaAttachments = completedMediaAttachments
            self.streamMsgs = m
            let sentIDs = Set(completedMediaAttachments.map(\.id))
            pendingMediaAttachments.removeAll { sentIDs.contains($0.id) }
        }
        m = self.streamMsgs
        let remoteSession = modelManager?.activeRemoteSession
        m.append(
            .init(
                role: "🤖",
                text: "",
                timestamp: Date(),
                streaming: true,
                promptProcessing: self.supportsPromptProcessingCard ? .init(progress: 0) : nil,
                usedRemoteBackend: remoteSession != nil,
                remoteBackendName: remoteSession?.backendName,
                remoteModelName: remoteSession?.modelName,
                localModelName: remoteSession == nil ? modelManager?.loadedModel?.name : nil
            )
        )
        self.streamMsgs = m
        let outIdx = self.streamMsgs.index(before: self.streamMsgs.endIndex)
        self.pendingAFMToolSummary = nil
        self.applyActiveAppleModelOrigin(to: outIdx)
        let fullHistory = self.streamMsgs
        let modelHistory = Self.modelFacingHistory(visibleHistory: fullHistory, modelInput: modelInput)
        let messageID = self.streamMsgs[outIdx].id
        // Begin streaming into the narrow store; the live bubble renders from it so token
        // updates don't republish ChatVM (and thus every tab) on every token.
        self.streamingStore.begin(id: messageID)
        var history = modelHistory

        // Decide how this turn should use its active dataset before either routing
        // or retrieval. AFM refines the decision where available; every failure and
        // unsupported device falls straight back to the deterministic classifier.
        refreshPDFToolPresence()
        let autopilotTurnConfig = isAutoRoutingActive ? AutopilotConfigStore.load() : nil
        let documentContext = documentAccessContext(autopilotConfig: autopilotTurnConfig)
        let previousUserForPlanning = modelHistory.filter { $0.role == "🧑‍💻" || $0.role.lowercased() == "user" }
            .dropLast().last?.text
        var turnDocumentAccessStrategy = DocumentAccessPlanner.deterministic(
            userMessage: modelInput,
            previousUserMessage: previousUserForPlanning,
            context: documentContext
        )
        var turnDocumentAccessDecidedBy = DocumentAccessDecisionRecord.DecidedBy.rulesFallback
        if documentContext.hasActiveDataset,
           loadedFormat != .afm,
           AutopilotAFMBrain.isAvailableNow {
            do {
                let plan = try await AutopilotAFMBrain.planDocumentAccess(
                    context: documentContext,
                    userMessage: modelInput,
                    previousUserMessage: previousUserForPlanning
                )
                turnDocumentAccessStrategy = plan.strategy
                if plan.usedAFMDecision {
                    turnDocumentAccessDecidedBy = .appleFoundationModel
                }
            } catch is CancellationError {
                guard myID == activeRunID, !Task.isCancelled else { return }
            } catch {
                Task { await logger.log("[DocumentPlan][AFM] unavailable; using deterministic fallback") }
            }
        }

        // Autopilot: decide this turn's route before the prompt is built. The
        // placeholder already exists, so the ESCALATION row can render the deciding
        // state while the router call runs.
        self.currentTurnEscalationCancel = nil
        // Phone-a-friend: no pre-turn router — the local model calls the
        // handoff tool mid-stream. Only a user redo ("Redo On-Device"/"Redo
        // with Stronger Model") is resolved up front here.
        var allowPhoneAFriendHandoff = true
        let phoneAFriendActive = autopilotTurnConfig?.system == .phoneAFriend
            && autopilotTurnConfig?.isReadyToArm == true
            && autoRoutingOutcomeProviderForTesting == nil
        if phoneAFriendActive, let forced = pendingForcedRoute {
            pendingForcedRoute = nil
            if forced == .cloud {
                if let esc = await preparePhoneAFriendEscalation(reason: "") {
                    var decision = esc.decision
                    decision.decidedBy = .forced
                    decision.reasonKey = AutopilotReasonKey.userOverride
                    decision.reason = AutopilotReasonKey.localized(AutopilotReasonKey.userOverride)
                    turnEscalation = TurnEscalation(
                        service: esc.service,
                        client: esc.client,
                        backend: esc.backend,
                        modelID: esc.modelID,
                        modelName: esc.modelName,
                        model: esc.model,
                        decision: decision,
                        remoteKind: esc.remoteKind,
                        settings: esc.settings,
                        hasExplicitRemoteSettings: esc.hasExplicitRemoteSettings,
                        isLocalTarget: esc.isLocalTarget,
                        isPrivateCloudComputeTarget: esc.isPrivateCloudComputeTarget,
                        localTurnToken: esc.localTurnToken
                    )
                    allowPhoneAFriendHandoff = false
                } else if self.streamMsgs.indices.contains(outIdx) {
                    var d = AutoRouteDecision.forced(.local, reasonKey: AutopilotReasonKey.phoneAFriendUnavailable)
                    d.reason = AutopilotReasonKey.localized(AutopilotReasonKey.phoneAFriendUnavailable)
                    self.streamMsgs[outIdx].route = RouteDecisionRecord(decision: d, userOverride: true)
                }
            } else {
                // Pinned local: suppress the handoff tool for this turn.
                allowPhoneAFriendHandoff = false
                if self.streamMsgs.indices.contains(outIdx) {
                    var d = AutoRouteDecision.forced(.local, reasonKey: AutopilotReasonKey.userOverride)
                    d.reason = AutopilotReasonKey.localized(AutopilotReasonKey.userOverride)
                    self.streamMsgs[outIdx].route = RouteDecisionRecord(decision: d, userOverride: true)
                }
            }
            if let esc = turnEscalation {
                let record = RouteDecisionRecord(
                    decision: esc.decision,
                    escalationBackendName: esc.backend?.name,
                    escalationModelName: esc.modelName,
                    userOverride: true,
                    escalationIsLocal: esc.isLocalTarget,
                    escalationUsesPrivateCloudCompute: esc.isPrivateCloudComputeTarget
                )
                if self.streamMsgs.indices.contains(outIdx) {
                    self.streamMsgs[outIdx].route = record
                    if esc.isLocalTarget {
                        self.streamMsgs[outIdx].localModelName = esc.modelName
                    } else if esc.isPrivateCloudComputeTarget {
                        self.streamMsgs[outIdx].ranOnPrivateCloudCompute = true
                        self.streamMsgs[outIdx].usedRemoteBackend = false
                        self.streamMsgs[outIdx].remoteBackendName = nil
                        self.streamMsgs[outIdx].remoteModelName = esc.modelName
                        self.streamMsgs[outIdx].localModelName = nil
                    } else {
                        self.streamMsgs[outIdx].usedRemoteBackend = true
                        self.streamMsgs[outIdx].remoteBackendName = esc.backend?.name
                        self.streamMsgs[outIdx].remoteModelName = esc.modelName
                        self.streamMsgs[outIdx].localModelName = nil
                    }
                }
                self.currentTurnEscalationCancel = { esc.client.cancelActive() }
            }
        }
        if (isAutoRoutingActive && !phoneAFriendActive) || autoRoutingOutcomeProviderForTesting != nil {
            autoRoutingStage = .deciding
            let routingTaskID = UUID()
            let routingAwaiter = AutoRoutingAwaiter()
            currentAutoRoutingTaskID = routingTaskID
            currentAutoRoutingAwaiter = routingAwaiter
            let routingTask: Task<AutoRoutingOutcome?, Never> = Task { [weak self] in
                guard let self else {
                    routingAwaiter.resolve(nil)
                    return nil
                }
                let outcome: AutoRoutingOutcome?
                if let provider = self.autoRoutingOutcomeProviderForTesting {
                    outcome = await provider()
                } else {
                    outcome = await self.routeCurrentTurnIfNeeded(
                        userMessage: modelInput,
                        history: modelHistory,
                        imageCount: usedImagePathsForThisRun.count,
                        documentCount: completedMediaAttachments.count,
                        documentAccess: documentContext
                    )
                }
                if self.currentAutoRoutingTaskID == routingTaskID {
                    routingAwaiter.resolve(outcome)
                } else {
                    // The watchdog/Stop already abandoned this routing task.
                    // Retire any local turn token its late result acquired.
                    self.releaseLocalEscalationTurn(outcome?.escalation)
                }
                return outcome
            }
            currentAutoRoutingTask = routingTask
            let routingWatchdog = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: AutoRoutingWatchdog.timeoutNanoseconds)
                } catch {
                    return
                }
                guard let self,
                      self.currentAutoRoutingTaskID == routingTaskID else { return }
                _ = self.cancelAutoRoutingAndContinueLocally(reason: "router-watchdog")
            }
            let outcome = await routingAwaiter.value()
            routingWatchdog.cancel()
            guard myID == self.activeRunID else {
                self.releaseLocalEscalationTurn(outcome?.escalation)
                if currentAutoRoutingTaskID == routingTaskID {
                    currentAutoRoutingTask = nil
                    currentAutoRoutingTaskID = nil
                    currentAutoRoutingAwaiter = nil
                    autoRoutingStage = .none
                }
                return
            }
            if currentAutoRoutingTaskID == routingTaskID {
                currentAutoRoutingTask = nil
                currentAutoRoutingTaskID = nil
                currentAutoRoutingAwaiter = nil
            }
            autoRoutingStage = .none
            if let outcome {
                turnEscalation = outcome.escalation
                let record = RouteDecisionRecord(
                    decision: outcome.decision,
                    escalationBackendName: outcome.escalation != nil ? outcome.escalationBackendName : nil,
                    escalationModelName: outcome.escalation != nil ? outcome.escalationModelName : nil,
                    userOverride: outcome.decision.reasonKey == AutopilotReasonKey.userOverride,
                    escalationIsLocal: outcome.escalation?.isLocalTarget == true,
                    escalationUsesPrivateCloudCompute: outcome.escalation?.isPrivateCloudComputeTarget == true
                )
                if self.streamMsgs.indices.contains(outIdx) {
                    self.streamMsgs[outIdx].route = record
                    if let esc = turnEscalation {
                        if esc.isLocalTarget {
                            // The stronger model is local: the turn stays
                            // "on-device", just on a different resident model.
                            self.streamMsgs[outIdx].localModelName = esc.modelName
                        } else if esc.isPrivateCloudComputeTarget {
                            self.streamMsgs[outIdx].ranOnPrivateCloudCompute = true
                            self.streamMsgs[outIdx].usedRemoteBackend = false
                            self.streamMsgs[outIdx].remoteBackendName = nil
                            self.streamMsgs[outIdx].remoteModelName = esc.modelName
                            self.streamMsgs[outIdx].localModelName = nil
                        } else {
                            self.streamMsgs[outIdx].usedRemoteBackend = true
                            self.streamMsgs[outIdx].remoteBackendName = esc.backend?.name
                            self.streamMsgs[outIdx].remoteModelName = esc.modelName
                            self.streamMsgs[outIdx].localModelName = nil
                        }
                    }
                }
                if let esc = turnEscalation {
                    self.currentTurnEscalationCancel = { esc.client.cancelActive() }
                }
                Task { await logger.log("[Autopilot] route=\(outcome.decision.target.rawValue) decidedBy=\(outcome.decision.decidedBy.rawValue) latency=\(outcome.decision.latencyMs)ms reason=\(outcome.decision.reasonKey ?? outcome.decision.reason)") }
            }
        }
        let answerRoute = self.streamMsgs.indices.contains(outIdx)
            ? self.streamMsgs[outIdx].route?.target
            : nil
        let requestedDocumentAccessStrategy = turnDocumentAccessStrategy
        currentDocumentAccessStrategy = DocumentAccessPlanner.constrained(
            turnDocumentAccessStrategy,
            context: documentContext,
            route: answerRoute
        )
        if documentContext.hasActiveDataset, self.streamMsgs.indices.contains(outIdx) {
            let datasetName = documentContext.datasetTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let documentDatasetName = datasetName.flatMap { $0.isEmpty ? nil : $0 } ?? "Dataset"
            self.streamMsgs[outIdx].documentAccessDecision = DocumentAccessDecisionRecord(
                datasetName: documentDatasetName,
                requestedStrategy: requestedDocumentAccessStrategy,
                effectiveStrategy: currentDocumentAccessStrategy,
                decidedBy: turnDocumentAccessDecidedBy
            )
        }
        let loggedDocumentAccessStrategy = currentDocumentAccessStrategy
        let loggedDocumentDecisionSource = turnDocumentAccessDecidedBy
        Task {
            await logger.log(
                "[DocumentPlan] strategy=\(loggedDocumentAccessStrategy.rawValue) source=\(loggedDocumentDecisionSource.rawValue) pdf=\(documentContext.isPDF)"
            )
        }
        refreshSystemPromptForActiveSession(historyOverride: fullHistory)
        // Resolve the immutable full-document payload once for this turn, before
        // conversation compaction. Its exact text stays out of the recap, but its
        // token cost must participate in the pressure calculation so compacting
        // old chat turns can preserve complete-document access when feasible.
        var plannedFullDocumentContext: String?
        var plannedFullDocumentTokens: Int?
        if let dataset = activeSessionRetrievalDataset,
           currentDocumentAccessStrategy.usesAutomaticContext {
            let fullContext = await cachedFullDatasetContent(for: dataset)
            plannedFullDocumentContext = fullContext
            let trimmedContext = fullContext.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedContext.isEmpty {
                plannedFullDocumentTokens = 0
            } else {
                plannedFullDocumentTokens = await estimatedPromptTokens(for: trimmedContext)
            }
            guard myID == activeRunID, !Task.isCancelled else { return }
        }
        let compactionBaseSystemPrompt = resolvedSystemPromptContext(
            using: activeSessionPromptDataset,
            history: modelHistory
        ).text
        let compactionResult = await compactConversationIfNeeded(
            sessionIndex: sIdx,
            history: modelHistory,
            baseSystemPrompt: compactionBaseSystemPrompt,
            protectedPromptTokens: plannedFullDocumentTokens ?? 0,
            allowGeneration: turnEscalation == nil,
            runID: myID
        )
        guard myID == activeRunID,
              !Task.isCancelled,
              sessions.indices.contains(sIdx) else { return }
        history = compactionResult.history
        let contextPlan = planHistoryForContextOverflow(
            history: history,
            systemPrompt: compactionResult.systemPrompt
        )
        history = contextPlan.history
        // Context overflow handling:
        // - stopAtLimit: show error and return (intentional user choice)
        // - truncateMiddle / rollingWindow: register the informational banner
        //   and continue with the compacted request. GGUF performs a second,
        //   server-exact fit check; AFM uses a fresh framework session so an
        //   overflow never poisons the next turn.
        if contextPlan.requiresStop && contextOverflowStrategy == .stopAtLimit {
            let details = ContextOverflowDetails(
                promptTokens: contextPlan.initialEstimate,
                contextTokens: currentPromptBudget().usablePromptTokens,
                rawMessage: "preflight-stop"
            )
            registerContextOverflow(strategy: contextOverflowStrategy, details: details)
            let message = contextStopMessage(details: details)
            await MainActor.run {
                guard self.streamMsgs.indices.contains(outIdx) else { return }
                self.streamMsgs[outIdx].text = "⚠️ " + message
                self.streamMsgs[outIdx].streaming = false
                self.streamMsgs[outIdx].promptProcessing = nil
                self.streamingStore.finish()
                self.injectionStage = .none
                self.injectionMethod = nil
            }
            return
        }
        if contextPlan.initialEstimate > contextSoftLimitTokens() {
            let details = ContextOverflowDetails(
                promptTokens: contextPlan.initialEstimate,
                contextTokens: currentPromptBudget().usablePromptTokens,
                rawMessage: contextPlan.requiresStop ? "preflight-overflow" : "preflight-trimmed"
            )
            registerContextOverflow(strategy: contextOverflowStrategy, details: details)
        } else {
            // This turn fits again — retire any stale overflow pill so it
            // always describes the most recent send.
            clearContextOverflowForCurrentStream()
        }

        systemPromptToolAvailabilityOverride = nil
        var remoteToolsAllowedOverride = ToolAvailability.none
        if let remoteService = self.remoteService {
            // Remote sessions never get the phone-a-friend tool — it exists
            // solely for the resident local model.
            let specs = PhoneAFriendGate.strippingHandoff(from: await self.fetchEnabledToolSpecs())
            await remoteService.updateToolSpecs(specs)
            remoteToolsAllowedOverride = self.toolAvailability(from: specs)
        } else if let esc = turnEscalation, !esc.isLocalTarget {
            // The turn-scoped escalation service received its specs in
            // prepareTurnEscalation; without this branch includeTools stays
            // false and the cloud model gets no native tools at all.
            remoteToolsAllowedOverride = self.toolAvailability(
                from: PhoneAFriendGate.strippingHandoff(from: await self.fetchEnabledToolSpecs())
            )
        }
        // Keep resident-model tool guidance out of local escalation prompts.
        if turnEscalation?.isLocalTarget == true {
            systemPromptToolAvailabilityOverride = ToolAvailability.none
        } else {
            systemPromptToolAvailabilityOverride = remoteToolsAllowedOverride.any ? remoteToolsAllowedOverride : nil
        }
        refreshSystemPromptForActiveSession(historyOverride: history)
        // Freeze one exact system prompt for the entire generation + tool loop.
        // Re-resolving it after a tool call can select a different memory snapshot
        // because the live transcript grew, which breaks longest-prefix KV reuse.
        let baseTurnSystemPrompt = resolvedSystemPromptContext(
            using: activeSessionPromptDataset,
            history: history
        ).text
        let turnSystemPrompt = systemPromptWithConversationCompaction(
            baseTurnSystemPrompt,
            sessionIndex: sIdx
        )

        let shouldReplayETConversation = loadedFormat == .et
            && etRuntimeSessionID != sessions[sIdx].id
        if shouldReplayETConversation {
            await client?.reset()
        }

        // Use local backends only.
        if (loadedFormat == .et || loadedFormat == .ane || loadedFormat == .afm || loadedFormat == .coreai), let client = self.client {
            await client.syncSystemPrompt(turnSystemPrompt)
        }

        var promptStr: String
        var stops: [String]
        var llmInput: LLMInput
        // Escalated turns keep the local-format prompt around: it is the
        // payload for the transparent pre-first-token local retry.
        var localFallbackPrompt: String? = nil
        var localFallbackStops: [String] = []

        if loadedFormat == .et {
            promptStr = modelInput
            stops = loadedSettings?.stopSequences ?? []
            let userMessage = ChatMessage(role: "user", content: modelInput)
            llmInput = LLMInput(.messages([userMessage]))
        } else {
            let (basePrompt, s, _) = self.buildPrompt(
                kind: currentKind,
                history: history,
                systemPromptOverride: turnSystemPrompt
            )
            var mergedStops = s
            if mergedStops.isEmpty {
                if let overrideStops = (loadedSettings?.stopSequences ?? nil), !overrideStops.isEmpty {
                    mergedStops = overrideStops
                }
            }
            if let esc = turnEscalation {
                localFallbackPrompt = basePrompt
                localFallbackStops = mergedStops
                let (remotePrompt, remoteStops, _) = self.buildPromptForEscalatedTurn(kind: esc.remoteKind, history: history)
                promptStr = remotePrompt
                stops = remoteStops
            } else {
                promptStr = basePrompt
                stops = mergedStops
            }
            llmInput = LLMInput(.plain("") ) // will assign after final prompt computed
        }
        let isMLXFormat = (self.loadedFormat == .mlx)
        // Log prompt summary to the app log for diagnostics
        do {
            let templateSource = self.promptTemplateSourceLabel
            let promptMetadata = Self.promptMetadataSummary(
                prompt: promptStr,
                stops: stops,
                format: self.loadedFormat,
                kind: self.currentKind,
                hasTemplate: self.promptTemplate != nil
            )
            Task {
                await logger.log("[Prompt][Template] source=\(templateSource)")
                await logger.log("[ChatVM] Prompt built " + promptMetadata)
            }
        }

        // CONTEXT plans decide whether to inject the full dataset or fall back to
        // semantic RAG. NAVIGATE plans deliberately skip this pre-generation work
        // so the model can begin with PDF info/grep/read instead of waiting for a
        // redundant embedding query.
        if let ds = activeSessionRetrievalDataset,
           currentDocumentAccessStrategy.usesAutomaticContext {
            let requestedMaxChunks = max(1, ragMaxChunks)
            let datasetDisplayName = ds.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ds.datasetID : ds.name
            let promptBudget = Self.promptBudget(for: contextLimit)
            let promptTemplateKind = templateKind()
            let currentKind = self.currentKind
            injectionStage = .deciding
            injectionMethod = nil
            clearRAGInjectionArtifacts(messageIndex: outIdx)
            let decidingInfo = Msg.RAGInjectionInfo(
                datasetName: datasetDisplayName,
                stage: .deciding,
                method: nil,
                requestedMaxChunks: requestedMaxChunks,
                retrievedChunkCount: 0,
                injectedChunkCount: 0,
                trimmedChunkCount: 0,
                partialChunkInjected: false,
                fullContentEstimateTokens: nil,
                configuredContextTokens: promptBudget.configuredContextTokens,
                reservedResponseTokens: promptBudget.reservedResponseTokens,
                contextBudgetTokens: promptBudget.usablePromptTokens,
                injectedContextTokens: 0,
                decisionReason: "Choosing between full document injection and smart retrieval."
            )
            updateRAGInjectionInfo(messageIndex: outIdx, decidingInfo)
            logRAGInjectionInfo(decidingInfo)
            currentContextTask = Task { [weak self, requestedMaxChunks, datasetDisplayName, promptBudget, promptTemplateKind, currentKind, promptStr, plannedFullDocumentContext, plannedFullDocumentTokens, verboseLogging = self.verboseLogging, ragMinScore = self.ragMinScore, ragRetrievalModeRaw = self.ragRetrievalModeRaw] in
                guard let self else { return nil }
                let ragRetrievalMode = DatasetRetrievalMode.from(ragRetrievalModeRaw)

                func makeInfo(
                    stage: Msg.RAGInjectionInfo.Stage,
                    method: Msg.RAGInjectionInfo.Method?,
                    retrievedChunkCount: Int,
                    injectedChunkCount: Int,
                    trimmedChunkCount: Int,
                    partialChunkInjected: Bool,
                    fullContentEstimateTokens: Int?,
                    contextBudgetTokens: Int,
                    injectedContextTokens: Int,
                    decisionReason: String
                ) -> Msg.RAGInjectionInfo {
                    Msg.RAGInjectionInfo(
                        datasetName: datasetDisplayName,
                        stage: stage,
                        method: method,
                        requestedMaxChunks: requestedMaxChunks,
                        retrievedChunkCount: retrievedChunkCount,
                        injectedChunkCount: injectedChunkCount,
                        trimmedChunkCount: trimmedChunkCount,
                        partialChunkInjected: partialChunkInjected,
                        fullContentEstimateTokens: fullContentEstimateTokens,
                        configuredContextTokens: promptBudget.configuredContextTokens,
                        reservedResponseTokens: promptBudget.reservedResponseTokens,
                        contextBudgetTokens: contextBudgetTokens,
                        injectedContextTokens: injectedContextTokens,
                        decisionReason: decisionReason
                    )
                }

                func publish(
                    _ info: Msg.RAGInjectionInfo,
                    method: InjectionMethod?,
                    stage: InjectionStage
                ) async {
                    await MainActor.run {
                        self.injectionMethod = method
                        self.injectionStage = stage
                        self.updateRAGInjectionInfo(messageIndex: outIdx, info)
                    }
                    self.logRAGInjectionInfo(info)
                }

                let promptWithInjectedContext: @Sendable (String) -> String = { context in
                    Self.injectContextIntoPrompt(
                        original: promptStr,
                        context: context,
                        kind: currentKind,
                        templateKind: promptTemplateKind
                    )
                }

                func fetchDetailedContext() async -> [(text: String, source: String?, score: Float?)] {
                    await EmbeddingModel.shared.ensureModel()
                    if !(await EmbeddingModel.shared.isReady()) {
                        await EmbeddingModel.shared.warmUp()
                    }
                    if verboseLogging {
                        print("[ChatVM] Embed ready: \(await EmbeddingModel.shared.isReady())")
                    }
                    return await DatasetRetriever.shared.fetchContextDetailed(
                        for: input,
                        dataset: ds,
                        maxChunks: requestedMaxChunks,
                        minScore: Float(ragMinScore),
                        mode: ragRetrievalMode
                    ) { status in
                        Task { @MainActor in
                            self.datasetManager?.processingStatus[ds.datasetID] = status
                            if let dc = self.datasetManager?.downloadController {
                                dc.showOverlay = status.stage != .completed && status.stage != .failed
                            }
                        }
                    }
                }

                func resolvePackedRAGContext(
                    from detailed: [(text: String, source: String?, score: Float?)],
                    fullContentEstimateTokens: Int?,
                    baseReason: String
                ) async -> ResolvedRAGContext {
                    let packed = await Self.packRAGContext(
                        chunks: detailed,
                        requestedMaxChunks: requestedMaxChunks,
                        usablePromptTokens: promptBudget.usablePromptTokens,
                        promptTokenCounter: { text in
                            await self.estimatedPromptTokens(for: text)
                        },
                        promptBuilder: { context in
                            promptWithInjectedContext(context)
                        }
                    )
                    let finalReason: String = {
                        if packed.retrievedChunkCount == 0 {
                            return baseReason + " No chunks were retrieved."
                        }
                        if packed.injectedChunkCount == 0 {
                            return baseReason + " Retrieved passages did not fit in the prompt budget."
                        }
                        if packed.partialChunkInjected {
                            return baseReason + " Only a partial excerpt of the top chunk fit in the prompt budget."
                        }
                        if packed.injectedChunkCount < packed.retrievedChunkCount {
                            return baseReason + " \(packed.injectedChunkCount) of \(packed.retrievedChunkCount) chunks fit in the prompt budget."
                        }
                        return baseReason
                    }()
                    let injectedInfo = makeInfo(
                        stage: .injected,
                        method: .rag,
                        retrievedChunkCount: packed.retrievedChunkCount,
                        injectedChunkCount: packed.injectedChunkCount,
                        trimmedChunkCount: packed.trimmedChunkCount,
                        partialChunkInjected: packed.partialChunkInjected,
                        fullContentEstimateTokens: fullContentEstimateTokens,
                        contextBudgetTokens: packed.contextBudgetTokens,
                        injectedContextTokens: packed.contextTokenCount,
                        decisionReason: finalReason
                    )
                    await publish(injectedInfo, method: .rag, stage: .processing)
                    await MainActor.run {
                        self.currentInjectedTokenOverhead = 0
                    }
                    return ResolvedRAGContext(
                        injectedContext: packed.injectedContext,
                        citations: packed.injectedCitations,
                        info: injectedInfo
                    )
                }

                let fullContext: String
                if let plannedFullDocumentContext {
                    fullContext = plannedFullDocumentContext
                } else {
                    fullContext = await self.cachedFullDatasetContent(for: ds)
                }
                let trimmedFullContext = fullContext.trimmingCharacters(in: .whitespacesAndNewlines)
                let fullContextDecision = await Self.evaluateFullContextInjection(
                    fullContext: fullContext,
                    contextLimit: Double(promptBudget.configuredContextTokens),
                    knownFullContextTokens: plannedFullDocumentTokens,
                    promptBuilder: { context in
                        promptWithInjectedContext(context)
                    },
                    promptTokenCounter: { text in
                        await self.estimatedPromptTokens(for: text)
                    }
                )
                if Task.isCancelled { return nil }

                if !trimmedFullContext.isEmpty, fullContextDecision.fits {
                    let chosenInfo = makeInfo(
                        stage: .chosen,
                        method: .fullContent,
                        retrievedChunkCount: 0,
                        injectedChunkCount: 0,
                        trimmedChunkCount: 0,
                        partialChunkInjected: false,
                        fullContentEstimateTokens: fullContextDecision.fullContextTokens,
                        contextBudgetTokens: promptBudget.usablePromptTokens,
                        injectedContextTokens: 0,
                        decisionReason: "Full document passed the initial budget check."
                    )
                    await publish(chosenInfo, method: .full, stage: .decided)
                    await MainActor.run {
                        self.currentInjectedTokenOverhead = fullContextDecision.fullContextTokens
                    }
                    let injectedInfo = makeInfo(
                        stage: .injected,
                        method: .fullContent,
                        retrievedChunkCount: 0,
                        injectedChunkCount: 0,
                        trimmedChunkCount: 0,
                        partialChunkInjected: false,
                        fullContentEstimateTokens: fullContextDecision.fullContextTokens,
                        contextBudgetTokens: promptBudget.usablePromptTokens,
                        injectedContextTokens: fullContextDecision.fullContextTokens,
                        decisionReason: "Using the full document. Retrieval previews are hidden because the model received the entire dataset."
                    )
                    await publish(injectedInfo, method: .full, stage: .decided)
                    return ResolvedRAGContext(
                        injectedContext: fullContext,
                        citations: [],
                        info: injectedInfo
                    )
                }

                await MainActor.run {
                    self.currentInjectedTokenOverhead = 0
                }
                let ragReason = trimmedFullContext.isEmpty
                    ? "Full document was empty, so smart retrieval was used."
                    : "The complete document could not be retained within the current context budget, so this turn transitioned to selected semantic passages. The active dataset remains available through its document tools."
                let chosenInfo = makeInfo(
                    stage: .chosen,
                    method: .rag,
                    retrievedChunkCount: 0,
                    injectedChunkCount: 0,
                    trimmedChunkCount: 0,
                    partialChunkInjected: false,
                    fullContentEstimateTokens: trimmedFullContext.isEmpty ? nil : fullContextDecision.fullContextTokens,
                    contextBudgetTokens: promptBudget.usablePromptTokens,
                    injectedContextTokens: 0,
                    decisionReason: ragReason
                )
                await publish(chosenInfo, method: .rag, stage: .processing)
                let detailed = await fetchDetailedContext()
                return await resolvePackedRAGContext(
                    from: detailed,
                    fullContentEstimateTokens: trimmedFullContext.isEmpty ? nil : fullContextDecision.fullContextTokens,
                    baseReason: ragReason
                )
            }
            let resolvedContext = await currentContextTask?.value
            currentContextTask = nil
            if let resolvedContext {
                self.streamMsgs[outIdx].retrievedContext = resolvedContext.injectedContext
                self.streamMsgs[outIdx].citations = resolvedContext.citations
                self.streamMsgs[outIdx].ragInjectionInfo = resolvedContext.info
                if !resolvedContext.injectedContext.isEmpty {
                    if resolvedContext.info.method == .fullContent, self.loadedFormat != .et {
                        // Full-document injection: rebuild the prompt with the document as a
                        // stable leading system prefix so the KV cache reuses it across turns
                        // instead of reprocessing the whole document every turn. (ET keeps the
                        // legacy user-turn injection since it doesn't build via buildPrompt.)
                        let (rebuilt, rebuiltStops, _) = self.buildPrompt(
                            kind: self.currentKind,
                            history: history,
                            systemPromptOverride: self.systemPromptWithFullDocument(
                                resolvedContext.injectedContext,
                                baseSystemPrompt: turnSystemPrompt
                            )
                        )
                        promptStr = rebuilt
                        if !rebuiltStops.isEmpty { stops = rebuiltStops }
                        Task { await logger.log("[Prompt][RAG] full document placed as stable system prefix (KV-cacheable across turns)") }
                    } else {
                        // RAG chunks (and ET) stay inside the user section of the template —
                        // they change per query, so they can't be prefix-cached anyway.
                        promptStr = injectContextIntoPrompt(
                            original: promptStr,
                            context: resolvedContext.injectedContext,
                            kind: self.currentKind
                        )
                    }
                }
                if verboseLogging {
                    print("[ChatVM] Retrieved context (\(resolvedContext.injectedContext.count) chars): \(resolvedContext.injectedContext.prefix(200))...")
                }
            }
            if client == nil, let url = loadedURL {
                try? await ensureClient(url: url, settings: loadedSettings, format: loadedFormat, forceReload: false)
            }
        } else {
            injectionStage = .none
            injectionMethod = nil
            currentInjectedTokenOverhead = 0
            clearRAGInjectionArtifacts(messageIndex: outIdx)
            if activeSessionRetrievalDataset != nil {
                Task {
                    await logger.log(
                        "[Prompt][DocumentPlan] automatic context skipped for \(self.currentDocumentAccessStrategy.rawValue)"
                    )
                }
            }
        }

        let promptMetadata = Self.promptMetadataSummary(
            prompt: promptStr,
            stops: stops,
            format: self.loadedFormat,
            kind: self.currentKind,
            hasTemplate: self.promptTemplate != nil
        )
        Task { await logger.log("[Prompt] " + promptMetadata) }
        if injectionStage != .none {
            let methodStr: String = {
                switch injectionMethod {
                case .some(.full): return "full"
                case .some(.rag):  return "rag"
                case .none:        return "unknown"
                }
            }()
            let contextLength = self.streamMsgs.indices.contains(outIdx) ? (self.streamMsgs[outIdx].retrievedContext?.count ?? 0) : 0
            let ragMetadata = Self.ragMetadataSummary(
                method: methodStr,
                contextLength: contextLength,
                prompt: promptStr
            )
            Task {
                let message = "[Prompt][RAG] Context injected: " + ragMetadata
                await logger.log(message)
            }
        } else {
            Task { await logger.log("[Prompt][RAG] No context injected") }
        }
        Task { await logger.log("[Params] stops: \(stops)") }

        // Server-verified context trim: call /tokenize for exact token count and trim
        // history until the prompt fits within the shared usable prompt budget.
        // Skipped for escalated turns: the local server's budget doesn't apply to
        // the cloud model (the router escalates on local-context overflow), and
        // rebuilding here would re-apply the local template to a remote prompt.
        if loadedFormat == .gguf, contextOverflowStrategy != .stopAtLimit, turnEscalation == nil {
            let tokenLimit = currentPromptBudget().usablePromptTokens
            var firstOverflowTokens: Int? = nil
            var lastVerifiedTokens: Int? = nil
            var trimIteration = 0
            while trimIteration < 64 {
                guard let tokenCount = await tokenCountViaServer(promptStr) else { break }
                lastVerifiedTokens = tokenCount
                guard tokenCount >= tokenLimit else { break }
                if firstOverflowTokens == nil { firstOverflowTokens = tokenCount }

                let candidates = removableHistoryTurnRanges(for: history)
                if !candidates.isEmpty {
                    let removalRange: Range<Int>
                    switch contextOverflowStrategy {
                    case .truncateMiddle: removalRange = candidates[candidates.count / 2]
                    case .rollingWindow, .stopAtLimit: removalRange = candidates[0]
                    }
                    history.removeSubrange(removalRange)
                } else if !shrinkOversizedMessageForContext(
                    &history,
                    strategy: contextOverflowStrategy,
                    promptTokens: tokenCount,
                    tokenLimit: tokenLimit
                ) {
                    break
                }

                let safeCtx = self.streamMsgs[outIdx].retrievedContext
                let fullDocContext: String? = (self.streamMsgs[outIdx].ragInjectionInfo?.method == .fullContent)
                    ? safeCtx.flatMap { $0.isEmpty ? nil : $0 }
                    : nil
                // Full-document context stays in the system prefix while trimming so its
                // KV reuse survives; RAG chunks are re-injected into the user turn.
                let (newPrompt, newStops, _) = buildPrompt(
                    kind: currentKind,
                    history: history,
                    systemPromptOverride: fullDocContext.map {
                        self.systemPromptWithFullDocument($0, baseSystemPrompt: turnSystemPrompt)
                    } ?? turnSystemPrompt
                )
                promptStr = newPrompt
                if !newStops.isEmpty { stops = newStops }

                if fullDocContext == nil, let safeCtx, !safeCtx.isEmpty {
                    promptStr = injectContextIntoPrompt(original: promptStr, context: safeCtx, kind: self.currentKind)
                }

                Task { await logger.log("[ContextTrim] iteration=\(trimIteration) tokens=\(tokenCount) limit=\(tokenLimit) remaining_turns=\(history.count)") }
                trimIteration += 1
            }

            if let firstOverflowTokens {
                // The prompt genuinely overflowed; surface the pill even when the
                // cheap preflight estimate thought it would fit.
                registerContextOverflow(
                    strategy: contextOverflowStrategy,
                    details: ContextOverflowDetails(
                        promptTokens: firstOverflowTokens,
                        contextTokens: tokenLimit,
                        rawMessage: "verified-trim"
                    )
                )
            }
            if let lastVerifiedTokens, lastVerifiedTokens >= tokenLimit,
               ((await tokenCountViaServer(promptStr)) ?? lastVerifiedTokens) >= tokenLimit {
                // Even after exhausting every trim the prompt cannot fit; the server
                // would reject it with a 400, so stop here with a clear message.
                let message = contextFallbackMessage(for: contextOverflowStrategy)
                Task { await logger.log("[ContextTrim] giving up tokens=\(lastVerifiedTokens) limit=\(tokenLimit)") }
                await MainActor.run {
                    guard self.streamMsgs.indices.contains(outIdx) else { return }
                    self.streamMsgs[outIdx].text = "⚠️ " + message
                    self.streamMsgs[outIdx].streaming = false
                    self.streamMsgs[outIdx].promptProcessing = nil
                    self.streamingStore.finish()
                    self.injectionStage = .none
                    self.injectionMethod = nil
                }
                return
            }
        }

        didLaunchStreamTask = true
        let streamTask: Task<Void, Never> = Task(priority: nil) { [weak self, sessionIndex = sIdx, messageID] in
            guard let self else { return }
            await self.runInitialStreamTask(
                runID: myID,
                messageIndex: outIdx,
                promptStr: promptStr,
                stops: stops,
                history: history,
                input: input,
                initialLLMInput: llmInput,
                initialUsedImagePathsForThisRun: usedImagePathsForThisRun,
                remoteToolsAllowedOverride: remoteToolsAllowedOverride,
                sessionIndex: sessionIndex,
                messageID: messageID,
                isMLXFormat: isMLXFormat,
                turnSystemPrompt: turnSystemPrompt,
                turnEscalation: turnEscalation,
                localFallbackPrompt: localFallbackPrompt,
                localFallbackStops: localFallbackStops,
                allowPhoneAFriendHandoff: allowPhoneAFriendHandoff
            )
        }
        currentStreamTask = streamTask
        // Do not immediately clear the banner here; allow the delayed clear above
        currentInjectedTokenOverhead = 0
        // Only clear images actually used by THIS run to avoid races.
        var removedCount = 0
        if !usedImagePathsForThisRun.isEmpty {
            let usedSet = Set(usedImagePathsForThisRun)
            // Map paths to URLs and remove if still pending
            for path in usedSet {
                let url = URL(fileURLWithPath: path)
                if let idx = pendingImageURLs.firstIndex(of: url) {
                    pendingImageURLs.remove(at: idx)
                    pendingThumbnails.removeValue(forKey: url)
                    removedCount += 1
                }
            }
        }
        if removedCount > 0 {
            Task { await logger.log("[Images][Clear] cleared=\(removedCount)") }
        }
    }

    private func runInitialStreamTask(
        runID myID: Int,
        messageIndex outIdx: Int,
        promptStr: String,
        stops: [String],
        history: [Msg],
        input: String,
        initialLLMInput: LLMInput,
        initialUsedImagePathsForThisRun: [String],
        remoteToolsAllowedOverride: ToolAvailability,
        sessionIndex: Int,
        messageID: UUID,
        isMLXFormat: Bool,
        turnSystemPrompt: String? = nil,
        turnEscalation: TurnEscalation? = nil,
        localFallbackPrompt: String? = nil,
        localFallbackStops: [String] = [],
        allowPhoneAFriendHandoff: Bool = false
    ) async {
        var llmInput = initialLLMInput
        var usedImagePathsForThisRun = initialUsedImagePathsForThisRun
        var transfersLocalEscalationTurn = false
        let stableSystemPrompt = turnSystemPrompt ?? self.systemPromptText

        defer {
            if !transfersLocalEscalationTurn {
                releaseLocalEscalationTurn(turnEscalation)
            }
            Task { @MainActor in
                if self.activeRunID == myID,
                   self.currentContinuationTask == nil,
                   self.streamSessionIndex == sessionIndex {
                    self.streamSessionIndex = nil
                }
            }
        }
        guard myID == activeRunID, !Task.isCancelled else { return }

            // Give ET a brief moment after any cancellation to avoid
            // triggering an immediate prefill race on the next turn.
            if self.loadedFormat == .et {
                try? await Task.sleep(nanoseconds: 80_000_000) // ~80ms
            }
            if (!self.modelLoaded || self.client == nil), let url = self.loadedURL {
                do {
                    try await self.ensureClient(
                        url: url,
                        settings: self.loadedSettings,
                        format: self.loadedFormat,
                        forceReload: false
                    )
                } catch {
                    let displayedError = UserFacingErrorFormatter.message(
                        for: error,
                        context: .localModel
                    )
                    await MainActor.run {
                        guard myID == self.activeRunID,
                              self.streamMsgs.indices.contains(outIdx) else { return }
                        self.streamMsgs[outIdx].streaming = false
                        self.streamMsgs[outIdx].promptProcessing = nil
                        self.streamMsgs[outIdx].text = "⚠️ " + displayedError
                        self.streamingStore.finish()
                    }
                    await self.cancelPerfTracking(messageID: messageID)
                    return
                }
            }
            guard self.modelLoaded, let c = turnEscalation?.client ?? self.client else {
                await MainActor.run {
                    guard myID == self.activeRunID,
                          self.streamMsgs.indices.contains(outIdx) else { return }
                    self.streamMsgs[outIdx].streaming = false
                    self.streamMsgs[outIdx].promptProcessing = nil
                    self.streamMsgs[outIdx].text = "⚠️ Model is not ready. Please wait for loading to complete, then try again."
                    self.streamingStore.finish()
                }
                await self.cancelPerfTracking(messageID: messageID)
                return
            }
            AccessibilityAnnouncer.announceLocalized("Generating response…")
            let start = Date()
            await self.beginPerfTracking(messageID: messageID, start: start)
            var firstTok: Date?
            var count = 0
            var raw = ""
            var streamChunkMerger = StreamChunkMerger()
            var generationPassMergedText = ""
            var continuationBoundaryFilter: OutputContinuationBoundaryFilter?
            var activeOutputContinuationEventID: UUID?
            var didProcessEmbeddedToolCall = false
            var pendingToolJSON: String? = nil
            var pendingAssistantText: String? = nil
            // Phone-a-friend: set when the local model calls the handoff tool;
            // after the (cancelled) stream unwinds, the escalation run starts.
            var pendingPhoneAFriendReason: String? = nil
            var didTriggerFinalAnswerStartHaptic = false
            // Coalesce UI updates: push the live bubble text into the narrow store at ~30 Hz,
            // and checkpoint into `sessions` (which republishes ChatVM) only ~10 Hz. This keeps
            // the whole app fluid during fast token generation while leaving the streamed text
            // current enough for copy/readbacks/finalize.
            var lastStoreFlush: ContinuousClock.Instant?
            var lastSessionFlush: ContinuousClock.Instant?
            let storeFlushInterval: Duration = .milliseconds(33)
            // Checkpointing the live text into `sessions` trips `ChatVM.objectWillChange`, which
            // re-renders EVERY view observing ChatVM via @EnvironmentObject — including the whole
            // TabView and ExploreView. At 10 Hz that was an app-wide re-render storm during
            // generation (the live bubble itself reads the narrow `streamingStore`, so it does not
            // need this). Keep only an occasional crash-safety/copy checkpoint; the final text is
            // committed by the trailing flush + finalize.
            let sessionCheckpointInterval: Duration = .milliseconds(2000)
            // Throttle the expensive per-token full-buffer scans (rolling-thought reparse,
            // embedded tool-call detection) to the same ~30 Hz cadence as the store flush.
            // These previously ran on every token over the growing `raw` buffer (O(n) per
            // token → O(n²) per response) on the MainActor. A final flush after the loop
            // captures the last delta; a post-stream safety net re-checks for tool calls.
            var lastHeavyScan: ContinuousClock.Instant?
            let heavyScanInterval: Duration = .milliseconds(33)
            // Seed a visible <think> box for any prompt that pre-opens a think section
            // (DeepSeek-R1, Qwen3 *-Thinking, etc.). When the built prompt already ends
            // in an open <think>, the model continues that block and never emits its own
            // opening tag, so seeding here is double-wrap-safe and gives the live box a
            // token-by-token reasoning stream instead of snapping in only at </think>.
            //
            // Gate on the reasoning toggle: `promptStr` is a client-side artifact that
            // always ends in <think> for thinking templates, but template-driven GGUF
            // sends structured messages and the server honors `enable_thinking`. With
            // reasoning OFF the server opens no think block, so seeding one here would
            // trap the plain answer inside an unclosed <think> and render it as reasoning.
            if self.reasoningEnabled,
               promptStr.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>") {
                raw = "<think>"
                await MainActor.run {
                    if self.streamMsgs.indices.contains(outIdx) {
                        self.streamingStore.update(visibleAssistantText(from: raw))
                        self.streamMsgs[outIdx].text = visibleAssistantText(from: raw)
                    }
                }
                await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
            }

            var shouldRestartWithToolResult = false
            var didCancelInitialStreamForToolRestart = false
            do {
                // Build stop sequences. Avoid adding "Step N:" stops for CoT/ET models to not truncate reasoning-only streams.
                let isCotTemplate = (self.promptTemplate?.contains("<think>") == true)
                let defaultStopsBase = ["</s>", "<|im_end|>", "<|eot_id|>", "<end_of_turn>", "<eos>", "<｜User｜>", "<|User|>"]
                let defaultStops: [String] = {
                    if isCotTemplate || self.loadedFormat == .et || (self.activeSessionRetrievalDataset != nil) { return defaultStopsBase }
                    return defaultStopsBase + ["Step 1:", "Step 2:"]
                }()
                let stopSeqs = stops.isEmpty ? defaultStops : stops
                let locallyEnforcedStopSeqs = AssistantOutputSanitizer
                    .locallyEnforcedStopSequences(including: stopSeqs)
                // Use the attachments snapshot from send time; do not consult
                // pendingImageURLs here because we clear them when the message is sent.
                let imagePaths = usedImagePathsForThisRun
                let useImages: Bool
                if turnEscalation != nil {
                    // Escalated turns judge vision on the CLOUD model, not the
                    // resident local one; RemoteChatService ships the images
                    // as OpenAI content parts.
                    useImages = !imagePaths.isEmpty && (turnEscalation?.isVisionCapable ?? false)
                } else {
                    useImages = self.supportsImageInput && !imagePaths.isEmpty
                        && (self.remoteService != nil || self.loadedFormat == .mlx || self.loadedFormat == .gguf || self.loadedFormat == .et || self.loadedFormat == .afm)
                }
                // Preserve the snapshot if images are allowed; otherwise mark empty.
                usedImagePathsForThisRun = useImages ? imagePaths : []
                if !imagePaths.isEmpty {
                    if useImages {
                        let names = imagePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                        Task { await logger.log("[Images][Use] yes format=\(String(describing: self.loadedFormat)) remote=\(self.remoteService != nil || turnEscalation != nil) count=\(imagePaths.count) names=\(names.joined(separator: ", "))") }
                    } else {
                        var reasons: [String] = []
                        if turnEscalation != nil {
                            reasons.append("escalation model lacks vision")
                        } else {
                            if !self.supportsImageInput { reasons.append("supportsImageInput=false") }
                            if !(self.remoteService != nil || self.loadedFormat == .mlx || self.loadedFormat == .gguf || self.loadedFormat == .et) {
                                reasons.append("format=\(String(describing: self.loadedFormat)) unsupported")
                            }
                        }
                        Task { await logger.log("[Images][Use] no reasons=\(reasons.joined(separator: ",")) count=\(imagePaths.count)") }
                    }
                }
                // If images are present and supported, inject image placeholders only for llama.cpp or MLX templates
                // For ET, do NOT inject placeholders; send raw text plus image binaries via multimodal
                let finalPrompt = promptStr
                let retrievedContext = self.streamMsgs.indices.contains(outIdx)
                    ? self.streamMsgs[outIdx].retrievedContext
                    : nil
                let isFullDocumentContext = self.streamMsgs.indices.contains(outIdx)
                    && self.streamMsgs[outIdx].ragInjectionInfo?.method == .fullContent
                if let esc = turnEscalation, esc.isLocalTarget {
                    // Local escalation model (MLX or GGUF): hand over role-tagged
                    // messages so the stronger model's own chat template
                    // formats the conversation, instead of a template-free
                    // prompt string meant for a server-side renderer.
                    llmInput = LLMInput(.messages(self.escalationChatMessages(
                        history: history,
                        systemPrompt: stableSystemPrompt,
                        retrievedContext: retrievedContext
                    )))
                } else if turnEscalation != nil {
                    // Preserve roles for remote escalation. Flattening this history
                    // and then wrapping it in one user message makes literal "User:"
                    // labels and post-tool nudges part of the text the model imitates.
                    let remoteMessages = self.escalationChatMessages(
                        history: history,
                        systemPrompt: stableSystemPrompt,
                        retrievedContext: retrievedContext
                    )
                    llmInput = useImages
                        ? LLMInput.multimodal(messages: remoteMessages, imagePaths: imagePaths)
                        : LLMInput(.messages(remoteMessages))
                } else if self.loadedFormat == .et {
                    let needsHistoryReplay = !self.sessions.indices.contains(sessionIndex)
                        || self.etRuntimeSessionID != self.sessions[sessionIndex].id
                    if needsHistoryReplay {
                        let replayMessages = self.escalationChatMessages(
                            history: history,
                            systemPrompt: stableSystemPrompt,
                            retrievedContext: retrievedContext
                        )
                        llmInput = useImages
                            ? LLMInput.multimodal(messages: replayMessages, imagePaths: imagePaths)
                            : LLMInput(.messages(replayMessages))
                    } else {
                        llmInput = useImages
                            ? LLMInput.multimodal(text: finalPrompt, imagePaths: imagePaths)
                            : LLMInput(.messages([ChatMessage(role: "user", content: finalPrompt)]))
                    }
                } else if self.loadedFormat == .afm {
                    // AFM owns the system instructions on its LanguageModelSession.
                    // Send one complete role-tagged conversation to a fresh session
                    // for this request, excluding the duplicate system message.
                    let afmMessages = self.escalationChatMessages(
                        history: history,
                        systemPrompt: "",
                        retrievedContext: retrievedContext
                    )
                    llmInput = useImages
                        ? LLMInput.multimodal(messages: afmMessages, imagePaths: imagePaths)
                        : LLMInput(.messages(afmMessages))
                } else {
                    let nativeTools = await self.nativeToolSpecs()
                    if useImages,
                       let structuredInput = self.structuredLoopbackMultimodalInput(
                            for: history,
                            imagePaths: imagePaths,
                            retrievedContext: retrievedContext,
                            tools: nativeTools,
                            fullDocumentPlacement: isFullDocumentContext,
                            systemPromptOverride: stableSystemPrompt
                        ) {
                        llmInput = structuredInput
                        Task {
                            await logger.log(
                                "[Loopback] structured_input=true multimodal=true qwen35=\(TemplateDrivenModelSupport.isQwen35(modelURL: self.loadedURL))"
                            )
                        }
                    } else if !useImages,
                              let structuredInput = self.structuredLoopbackInput(
                                for: history,
                                retrievedContext: retrievedContext,
                                tools: nativeTools,
                                fullDocumentPlacement: isFullDocumentContext,
                                systemPromptOverride: stableSystemPrompt
                            ) {
                        llmInput = structuredInput
                        Task {
                            await logger.log(
                                "[Loopback] structured_input=true multimodal=false qwen35=\(TemplateDrivenModelSupport.isQwen35(modelURL: self.loadedURL))"
                            )
                        }
                    } else {
                        llmInput = useImages
                            ? LLMInput.multimodal(text: finalPrompt, imagePaths: imagePaths)
                            : LLMInput(.plain(finalPrompt))
                    }
                }
                if let remoteService = turnEscalation?.service ?? self.remoteService {
                    let redactionResult = SensitiveDataDetector.redactedForRemote(
                        finalPrompt,
                        enabled: UserDefaults.standard.bool(forKey: "redactSensitiveDataForRemoteBackends")
                    )
                    let sensitiveSummary = redactionResult.summary
                    if !sensitiveSummary.isEmpty {
                        await logger.log(
                            "[Privacy][RemoteSensitivity] findings=\(sensitiveSummary.logSummary) total=\(sensitiveSummary.totalCount)"
                        )
                    }
                    if redactionResult.redacted {
                        await logger.log("[Privacy][RemoteRedaction] applied=true findings=\(sensitiveSummary.logSummary)")
                        llmInput = useImages
                            ? LLMInput.multimodal(text: redactionResult.text, imagePaths: imagePaths)
                            : LLMInput(.plain(redactionResult.text))
                    }
                    let allowTools = remoteToolsAllowedOverride.any
                    let activeRemoteSession = self.modelManager?.activeRemoteSession
                    let activeRemoteBackend = turnEscalation?.backend ?? activeRemoteSession.flatMap { session in
                        self.modelManager?.remoteBackend(withID: session.backendID)
                    }
                    let hasExplicitRemoteSettings: Bool = turnEscalation?.hasExplicitRemoteSettings ?? {
                        guard let session = activeRemoteSession else { return false }
                        return self.modelManager?.hasSavedRemoteSettings(for: session.backendID, modelID: session.modelID) == true
                    }()
                    let effectiveSettings = turnEscalation?.settings ?? self.loadedSettings
                    let isOpenRouterRemote = activeRemoteBackend?.isOpenRouter == true
                    let forwardedStops = isOpenRouterRemote ? [] : stopSeqs
                    let temperature = (isOpenRouterRemote && !hasExplicitRemoteSettings)
                        ? nil
                        : (effectiveSettings?.temperature ?? 0.7)
                    let contextLength = effectiveSettings?.contextLength
                    let topP = (isOpenRouterRemote && !hasExplicitRemoteSettings) ? nil : effectiveSettings?.topP
                    let topK = (isOpenRouterRemote && !hasExplicitRemoteSettings) ? nil : effectiveSettings?.topK
                    let minP = (isOpenRouterRemote && !hasExplicitRemoteSettings) ? nil : effectiveSettings?.minP
                    let repeatPenalty = (isOpenRouterRemote && !hasExplicitRemoteSettings)
                        ? nil
                        : effectiveSettings.map { Double($0.repetitionPenalty) }
                    await remoteService.updateOptions(
                        stops: forwardedStops,
                        temperature: temperature,
                        contextLength: contextLength,
                        topP: topP,
                        topK: topK,
                        minP: minP,
                        repeatPenalty: repeatPenalty,
                        includeTools: allowTools
                    )
                }
                // For remote sessions, show a brief loading indicator when starting
                // the first stream, instead of on model selection.
                if (turnEscalation != nil || self.remoteService != nil) && self.remoteLoadingPending == false {
                    self.remoteLoadingPending = true
                }
                if self.remoteLoadingPending {
                    await MainActor.run {
                        let format = self.loadedFormat ?? .gguf
                        self.loadingProgressTracker.startLoading(for: format)
                    }
                }
                // Emit a start log for this generation
                let inferenceSummary = self.inferenceBackendSummary
                Task {
                    let suffix = inferenceSummary.map { " inference=\($0)" } ?? ""
                    await logger.log("[ChatVM] ▶︎ Starting generation (format=\(String(describing: self.loadedFormat)), kind=\(self.currentKind), images=\(useImages ? imagePaths.count : 0))\(suffix)")
                    if let inferenceSummary, self.loadedFormat == .ane, inferenceSummary.contains("prefillMode=compat-single-query") {
                        await logger.log("[ChatVM][Perf][CML] note=stateful prefill is compat-single-query, so prompt tokens are processed one-by-one before the first generated token.")
                    }
                }
                let promptProgressHandler: (@Sendable (Double) -> Void)?
                if self.supportsPromptProcessingCard {
                    promptProgressHandler = { progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  myID == self.activeRunID,
                                  self.streamMsgs.indices.contains(outIdx) else { return }
                            self.updatePromptProcessingProgress(progress, messageIndex: outIdx)
                        }
                    }
                } else {
                    promptProgressHandler = nil
                }
                // Apply the loaded model's reasoning toggle for local, non-escalated turns.
                if turnEscalation == nil {
                    llmInput = self.applyingLoadedReasoningPreference(to: llmInput)
                }
                var activeGenerationInput = llmInput
                var generationPassStartCharacterCount = raw.count
                generationPassLoop: while true {
                // Flip to Predicting when first token arrives
                for try await tok in try await c.textStream(from: activeGenerationInput, onPromptProgress: promptProgressHandler) {
                    // FoundationModels runs native tools inside this same stream.
                    // Tool lifecycle callbacks normally update the live message
                    // immediately. Drain only a rare pre-stream race here; the
                    // renderer places out-of-band calls before answer text.
                    if self.loadedFormat == .afm {
                        self.applyPendingAFMToolSummary(to: outIdx)
                        if self.streamMsgs.indices.contains(outIdx),
                           self.streamMsgs[outIdx].postToolWaiting {
                            self.streamMsgs[outIdx].postToolWaiting = false
                        }
                    }
                    let trimmedTok = tok.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Handle in-band tool calls emitted as tokens
                    if trimmedTok.hasPrefix("TOOL_CALL:") {
                        // Skip tool calls that occur inside <think> chain-of-thought
                        let inThink: Bool = {
                            if let open = raw.range(of: "<think>", options: .backwards) {
                                if let close = raw.range(of: "</think>", options: .backwards) { return open.lowerBound > close.lowerBound }
                                return true
                            }
                            return false
                        }()
                        if inThink && turnEscalation == nil && self.remoteService == nil { continue }
                        // Phone-a-friend: divert the handoff call to the escalation
                        // path before the execute-and-restart machinery. Image turns
                        // stay local (the stronger model wouldn't see the images),
                        // and escalated/remote turns can never re-hand-off.
                        if turnEscalation == nil, self.remoteService == nil,
                           allowPhoneAFriendHandoff,
                           usedImagePathsForThisRun.isEmpty,
                           let peek = peekToolCallTarget(trimmedTok),
                           peek.tool == PhoneAFriendTool.toolName {
                            let reason = (peek.arguments["reason"] as? String)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if self.phoneAFriendHandoffAllowedNow(reason: reason) {
                                await MainActor.run {
                                    recordPhoneAFriendHandoffCall(
                                        messageIndex: outIdx,
                                        chatVM: self,
                                        reason: reason,
                                        phase: .executing
                                    )
                                }
                                Task { await logger.log("[Autopilot][PhoneAFriend] handoff requested reason=\(reason.prefix(120))") }
                                pendingPhoneAFriendReason = reason
                                shouldRestartWithToolResult = true
                                didCancelInitialStreamForToolRestart = true
                                c.cancelActive()
                                break
                            }
                        }
                        if let (handled, trailing) = await interceptToolCallIfPresent(trimmedTok, messageIndex: outIdx, chatVM: self) {
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx),
                                   self.streamMsgs[outIdx].toolCalls?.last?.toolName == "noema.web.retrieve" {
                                    self.streamMsgs[outIdx].usedWebSearch = true
                                }
                            }
                            // Preserve the assistant text prior to the tool call so we can
                            // reinject it when continuing after tool execution.
                            let anchoredRaw = appendingToolAnchor(to: scrubVisibleToolArtifacts(from: raw))
                            pendingAssistantText = anchoredRaw
                            raw = anchoredRaw
                            // Do not inject TOOL_RESULT payloads into visible transcript text.
                            // ToolCallView is driven by `msg.toolCalls` + `msg.webHits/webError`.
                            if let trailing, !trailing.isEmpty {
                                raw += trailing
                                await MainActor.run {
                                    if self.streamMsgs.indices.contains(outIdx) {
                                        self.streamingStore.update(visibleAssistantText(from: raw))
                                        self.streamMsgs[outIdx].text = visibleAssistantText(from: raw)
                                    }
                                }
                            }
                            await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
                            // Capture tool result and restart generation with it injected
                            let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            pendingToolJSON = json
                            didProcessEmbeddedToolCall = true
                            shouldRestartWithToolResult = true
                            didCancelInitialStreamForToolRestart = true
                            c.cancelActive()
                            break
                        }
                    }
                    if Task.isCancelled { break }
                    // Intercept tool-calls emitted by the model and surface UI hints
                    if trimmedTok.hasPrefix("TOOL_RESULT:") || trimmedTok.hasPrefix("TOOL_CALL:") {
                        if trimmedTok.hasPrefix("TOOL_RESULT:") {
                            let json = trimmedTok.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await logger.log("[Tool][Stream] TOOL_RESULT raw: \(json)") }
                            if let data = json.data(using: .utf8) {
                                await MainActor.run { self.applyWebToolResult(data, messageIndex: outIdx) }
                            }
                            // Store the tool result and restart to continue the thought even on error
                            let anchoredRaw = appendingToolAnchor(to: scrubVisibleToolArtifacts(from: raw))
                            pendingAssistantText = anchoredRaw
                            raw = anchoredRaw
                            pendingToolJSON = json
                            shouldRestartWithToolResult = true
                            didCancelInitialStreamForToolRestart = true
                            c.cancelActive()
                            break
                        } else if trimmedTok.hasPrefix("TOOL_CALL:") {
                            Task { await logger.log("[Tool][Stream] TOOL_CALL token: \(trimmedTok)") }
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx),
                                   self.streamMsgs[outIdx].toolCalls?.last?.toolName == "noema.web.retrieve" {
                                    self.streamMsgs[outIdx].usedWebSearch = true
                                }
                            }
                        }
                    }
                    if firstTok == nil {
                        firstTok = Date()
                        if self.remoteLoadingPending {
                            await MainActor.run {
                                self.loadingProgressTracker.completeLoading()
                            }
                            self.remoteLoadingPending = false
                        }
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.clearPromptProcessing(for: outIdx)
                        }
                        if self.injectionStage != .none { self.injectionStage = .predicting }
                    }
                        if self.currentKind == .gemma && !self.gemmaAutoTemplated {
                            let t = trimmedTok
                            if !t.hasPrefix("<|") { self.gemmaAutoTemplated = true }
                        }
                        // Keep the decision banner visible until streaming completes to improve UX feedback
                        Task { await logger.log("[ChatVM] First token received") }
                    }
                    count += 1
                    await self.recordToken(messageID: messageID)
                    let passDelta = streamChunkMerger.append(tok, to: &generationPassMergedText)
                    let appendChunk: String
                    if var boundaryFilter = continuationBoundaryFilter {
                        appendChunk = boundaryFilter.append(passDelta)
                        continuationBoundaryFilter = boundaryFilter
                    } else {
                        appendChunk = passDelta
                    }
                    raw += appendChunk
                    if !appendChunk.isEmpty,
                       let eventID = activeOutputContinuationEventID {
                        await MainActor.run {
                            self.resolveAutomaticOutputContinuation(
                                messageIndex: outIdx,
                                eventID: eventID,
                                phase: .continued
                            )
                        }
                        activeOutputContinuationEventID = nil
                    }

                    // Throttle the heavy full-buffer scans below to ~30 Hz (see declaration).
                    let nowScan = ContinuousClock().now
                    let shouldHeavyScan = lastHeavyScan.map { nowScan - $0 >= heavyScanInterval } ?? true
                    if shouldHeavyScan { lastHeavyScan = nowScan }

                    // Handle rolling thoughts for <think> tags (throttled; final state flushed after the loop)
                    if shouldHeavyScan, !appendChunk.isEmpty {
                        await handleRollingThoughts(raw: raw, messageIndex: outIdx)
                    }

                    // Check for embedded <tool_call>…</tool_call> or bare JSON tool call (throttled; a
                    // post-stream safety net re-checks after the loop for end-of-stream tool calls)
                    if shouldHeavyScan, !didProcessEmbeddedToolCall {
                        // Phone-a-friend on the prose path (MLX and other
                        // non-native-tools locals): divert before dispatch.
                        if turnEscalation == nil, self.remoteService == nil,
                           allowPhoneAFriendHandoff,
                           usedImagePathsForThisRun.isEmpty,
                           let peek = peekEmbeddedToolCallTarget(in: raw),
                           peek.tool == PhoneAFriendTool.toolName {
                            let reason = (peek.arguments["reason"] as? String)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if self.phoneAFriendHandoffAllowedNow(reason: reason) {
                                await MainActor.run {
                                    recordPhoneAFriendHandoffCall(
                                        messageIndex: outIdx,
                                        chatVM: self,
                                        reason: reason,
                                        phase: .executing
                                    )
                                }
                                Task { await logger.log("[Autopilot][PhoneAFriend] embedded handoff requested reason=\(reason.prefix(120))") }
                                pendingPhoneAFriendReason = reason
                                didProcessEmbeddedToolCall = true
                                shouldRestartWithToolResult = true
                                didCancelInitialStreamForToolRestart = true
                                c.cancelActive()
                                break
                            }
                        }
                        if let result = await interceptEmbeddedToolCallIfPresent(in: raw, messageIndex: outIdx, chatVM: self),
                           let handled = result.token {
                            Task { await logger.log("[Tool][ChatVM] Embedded tool call detected and dispatched") }
                            // Preserve assistant text prior to tool result injection for prompt rebuilding
                            let anchoredCleaned = result.cleanedText
                            pendingAssistantText = anchoredCleaned
                            raw = anchoredCleaned
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx) {
                                    if self.streamMsgs[outIdx].toolCalls?.last?.toolName == "noema.web.retrieve" {
                                        self.streamMsgs[outIdx].usedWebSearch = true
                                    }
                                    self.streamingStore.update(visibleAssistantText(from: anchoredCleaned))
                                    self.streamMsgs[outIdx].text = visibleAssistantText(from: anchoredCleaned)
                                }
                            }
                            await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
                            let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            pendingToolJSON = json
                            didProcessEmbeddedToolCall = true
                            shouldRestartWithToolResult = true
                            didCancelInitialStreamForToolRestart = true
                            c.cancelActive()
                            Task { await logger.log("[Tool][ChatVM] Generation cancelled to resume after tool result") }
                            break
                        }
                    }
                    // Let the model run freely; rely on backend context limits
                    if self.currentKind == .gemma && !self.gemmaAutoTemplated, let r = raw.range(of: "<|im_end|>") {
                        raw = String(raw[..<r.lowerBound])
                        break
                    }
                    // Enforce stop sequences for all backends (including MLX) using suffix check.
                    // Do not apply stop if we are inside an open <think>…</think> block, so CoT isn't cut off.
                    if let stop = AssistantOutputSanitizer.strippingTrailingStopSequence(
                        from: raw,
                        stopSequences: locallyEnforcedStopSeqs
                    ) {
                        let lastOpen = raw.range(of: "<think>", options: .backwards)
                        let lastClose = raw.range(of: "</think>", options: .backwards)
                        let insideThink = {
                            if let o = lastOpen {
                                if let c = lastClose { return o.lowerBound > c.lowerBound }
                                return true
                            }
                            return false
                        }()
                        if !insideThink {
                            raw = stop.text
                            break
                        }
                    }
                    let now = ContinuousClock().now
                    let shouldFlushStore = lastStoreFlush.map { now - $0 >= storeFlushInterval } ?? true
                    let shouldCheckpointSession = lastSessionFlush.map { now - $0 >= sessionCheckpointInterval } ?? true
                    if shouldFlushStore { lastStoreFlush = now }
                    if shouldFlushStore, shouldCheckpointSession { lastSessionFlush = now }
                    let streamUpdate: (triggerHaptic: Bool, stopAfterParagraph: Bool) = shouldFlushStore
                        ? await MainActor.run { () -> (triggerHaptic: Bool, stopAfterParagraph: Bool) in
                            guard myID == self.activeRunID,
                                  self.streamMsgs.indices.contains(outIdx),
                                  self.streamMsgs[outIdx].streaming else { return (false, false) }
                            let visibleText = visibleAssistantText(from: raw)
                            // High-frequency: live bubble + auto-scroll (narrow observable).
                            self.streamingStore.update(visibleText)
                            // Low-frequency: checkpoint into sessions for copy/readbacks/finalize.
                            if shouldCheckpointSession {
                                self.streamMsgs[outIdx].text = visibleText
                            }
                            let shouldStopAfterParagraph = self.shouldStopAtRequestedParagraphBoundary(in: visibleText)
                            if didTriggerFinalAnswerStartHaptic {
                                return (false, shouldStopAfterParagraph)
                            }
                            return (self.strictFinalAnswerText(forText: visibleText, toolCalls: self.streamMsgs[outIdx].toolCalls) != nil, shouldStopAfterParagraph)
                        }
                        : (false, false)
                    if streamUpdate.stopAfterParagraph {
                        await logger.log("[ChatVM] Stop-after-paragraph boundary reached")
                        await MainActor.run {
                            self.clearStopAfterParagraphRequest()
                        }
                        c.cancelActive()
                        break
                    }
                    if streamUpdate.triggerHaptic {
#if os(iOS)
                        Haptics.impact(.medium)
#endif
                        didTriggerFinalAnswerStartHaptic = true
                    }
                    if shouldRestartWithToolResult { break }
                }

                if var boundaryFilter = continuationBoundaryFilter {
                    let finalBoundaryText = boundaryFilter.finish()
                    continuationBoundaryFilter = boundaryFilter
                    if !finalBoundaryText.isEmpty {
                        raw += finalBoundaryText
                        if let eventID = activeOutputContinuationEventID {
                            await MainActor.run {
                                self.resolveAutomaticOutputContinuation(
                                    messageIndex: outIdx,
                                    eventID: eventID,
                                    phase: .continued
                                )
                            }
                            activeOutputContinuationEventID = nil
                        }
                        await MainActor.run {
                            guard self.streamMsgs.indices.contains(outIdx) else { return }
                            let visibleText = visibleAssistantText(from: raw)
                            self.streamingStore.update(visibleText)
                            self.streamMsgs[outIdx].text = visibleText
                        }
                    }
                }

                let endedAtContextLimit = c.mostRecentFinishReason()?.lowercased() == "length"
                let canResumeAcrossContextLimit = endedAtContextLimit
                    && self.loadedFormat == .gguf
                    && turnEscalation == nil
                    && self.remoteService == nil
                    && self.contextOverflowStrategy != .stopAtLimit
                    && !shouldRestartWithToolResult
                    && pendingToolJSON == nil
                    && raw.count > generationPassStartCharacterCount
                    && myID == self.activeRunID
                    && !Task.isCancelled

                if canResumeAcrossContextLimit {
                    let closedCheckpoint = AssistantOutputSanitizer
                        .closingUnterminatedReasoningBlocks(in: raw)
                    raw = OutputContinuationTextCoordinator.checkpoint(from: closedCheckpoint)
                    let checkpointVisibleText = visibleAssistantText(from: raw)
                    await MainActor.run {
                        guard self.streamMsgs.indices.contains(outIdx) else { return }
                        self.streamingStore.update(checkpointVisibleText)
                        self.streamMsgs[outIdx].text = checkpointVisibleText
                    }
                    await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)

                    let continuationEventID = await MainActor.run {
                        self.beginAutomaticOutputContinuation(
                            messageIndex: outIdx,
                            visibleText: checkpointVisibleText
                        )
                    }

                    if let continuationInput = await self.automaticOutputContinuationInput(
                        history: history,
                        assistantMessageID: messageID,
                        partialAssistantText: raw,
                        systemPrompt: stableSystemPrompt
                    ) {
                        self.registerContextOverflow(
                            strategy: self.contextOverflowStrategy,
                            details: ContextOverflowDetails(
                                promptTokens: nil,
                                contextTokens: Int(self.contextLimit.rounded()),
                                rawMessage: "output-length-auto-continue"
                            )
                        )
                        await logger.log(
                            "[ContextContinue] finish_reason=length chars=\(raw.count) mode=answer_checkpoint tools=off reasoning=off strategy=\(self.contextOverflowStrategy.rawValue)"
                        )
                        // Explicit continuation overrides (reasoning/tools off) win;
                        // retain the user's remaining sampling and cache settings.
                        activeGenerationInput = self.applyingLoadedReasoningPreference(to: continuationInput)
                        generationPassStartCharacterCount = raw.count
                        generationPassMergedText = ""
                        streamChunkMerger = StreamChunkMerger()
                        continuationBoundaryFilter = OutputContinuationBoundaryFilter(
                            checkpoint: AssistantOutputSanitizer.strippingReasoningBlocks(
                                from: checkpointVisibleText
                            )
                        )
                        activeOutputContinuationEventID = continuationEventID
                        continue generationPassLoop
                    }
                    if let continuationEventID {
                        await MainActor.run {
                            self.resolveAutomaticOutputContinuation(
                                messageIndex: outIdx,
                                eventID: continuationEventID,
                                phase: .unavailable
                            )
                        }
                    }
                }
                if let eventID = activeOutputContinuationEventID {
                    await MainActor.run {
                        self.resolveAutomaticOutputContinuation(
                            messageIndex: outIdx,
                            eventID: eventID,
                            phase: .unavailable
                        )
                    }
                    activeOutputContinuationEventID = nil
                }
                break generationPassLoop
                }
                // Capture the final reasoning state once after streaming. The loop updates
                // rolling thoughts at ~30 Hz, so the last token's delta may not have flushed.
                await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
                if self.loadedFormat == .et,
                   self.sessions.indices.contains(sessionIndex) {
                    self.etRuntimeSessionID = self.sessions[sessionIndex].id
                }
            } catch {
                let wasCancellation = (error as? CancellationError) != nil
                    || (error as? URLError)?.code == .cancelled
                if activeOutputContinuationEventID != nil {
                    await MainActor.run {
                        self.resolvePreparingOutputContinuationsAsUnavailable(messageIndex: outIdx)
                    }
                    activeOutputContinuationEventID = nil
                }
                let intentionalToolRestartCancellation = wasCancellation && didCancelInitialStreamForToolRestart
                if intentionalToolRestartCancellation {
                    await logger.log("[Tool][ChatVM] Ignoring intentional cancellation during tool restart")
                }
                // Autopilot: a cloud escalation that failed before producing any
                // token retries locally, transparently, exactly once. Never after
                // the first token (partial cloud output + local retry would
                // double-bill and splice models), and never on user cancellation.
                if turnEscalation != nil, firstTok == nil, !wasCancellation, !intentionalToolRestartCancellation,
                   let fallbackPrompt = localFallbackPrompt, myID == self.activeRunID {
                    await logger.log("[Autopilot] Cloud escalation failed pre-first-token (\(error.localizedDescription)); retrying on-device")
                    await self.cancelPerfTracking(messageID: messageID)
                    await MainActor.run {
                        self.currentTurnEscalationCancel = nil
                        guard self.streamMsgs.indices.contains(outIdx) else { return }
                        self.streamMsgs[outIdx].usedRemoteBackend = false
                        self.streamMsgs[outIdx].ranOnPrivateCloudCompute = false
                        self.streamMsgs[outIdx].remoteBackendName = nil
                        self.streamMsgs[outIdx].remoteModelName = nil
                        self.streamMsgs[outIdx].localModelName = self.modelManager?.loadedModel?.name
                        if var record = self.streamMsgs[outIdx].route {
                            record.fellBackToLocal = true
                            let failKey = turnEscalation?.isLocalTarget == true
                                ? AutopilotReasonKey.phoneAFriendUnavailable
                                : AutopilotReasonKey.cloudFailed
                            record.reasonKey = failKey
                            record.reason = AutopilotReasonKey.localized(failKey)
                            self.streamMsgs[outIdx].route = record
                        }
                        self.streamMsgs[outIdx].text = ""
                        self.streamingStore.update("")
                    }
                    if self.remoteLoadingPending {
                        await MainActor.run { self.loadingProgressTracker.completeLoading() }
                        self.remoteLoadingPending = false
                    }
                    // The retry runs on the resident client. Release the exact
                    // stronger-model lease before recursively starting it.
                    self.releaseLocalEscalationTurn(turnEscalation)
                    await self.runInitialStreamTask(
                        runID: myID,
                        messageIndex: outIdx,
                        promptStr: fallbackPrompt,
                        stops: localFallbackStops,
                        history: history,
                        input: input,
                        initialLLMInput: LLMInput(.plain("")),
                        initialUsedImagePathsForThisRun: initialUsedImagePathsForThisRun,
                        remoteToolsAllowedOverride: remoteToolsAllowedOverride,
                        sessionIndex: sessionIndex,
                        messageID: messageID,
                        isMLXFormat: isMLXFormat,
                        turnSystemPrompt: stableSystemPrompt
                    )
                    return
                }
                let errorContext: UserFacingModelErrorContext = {
                    if let turnEscalation {
                        return turnEscalation.isLocalTarget ? .localModel : .remoteModel
                    }
                    return self.remoteService == nil ? .localModel : .remoteModel
                }()
                let displayedError = UserFacingErrorFormatter.message(
                    for: error,
                    context: errorContext
                )
                await MainActor.run {
                    guard myID == self.activeRunID,
                          self.streamMsgs.indices.contains(outIdx) else { return }
                    if !intentionalToolRestartCancellation {
                        // Commit any partial streamed text (loop only checkpointed periodically)
                        // and stop rendering the bubble from the store.
                        self.streamMsgs[outIdx].text = visibleAssistantText(from: raw)
                        self.streamingStore.finish()
                        self.streamMsgs[outIdx].streaming = false
                        if turnEscalation != nil, !wasCancellation, var record = self.streamMsgs[outIdx].route {
                            record.failedMidStream = true
                            self.streamMsgs[outIdx].route = record
                        }
                    }
                    self.clearPromptProcessing(for: outIdx)
                    if !wasCancellation {
                        let diagnosticMessage = error.localizedDescription
                        if let overflow = self.parseContextOverflowDetails(from: diagnosticMessage) {
                            self.registerContextOverflow(strategy: self.contextOverflowStrategy, details: overflow)
                            if self.contextOverflowStrategy == .stopAtLimit {
                                self.streamMsgs[outIdx].text = "⚠️ " + self.contextStopMessage(details: overflow)
                            } else {
                                let promptStr = overflow.promptTokens.map { "\($0)" } ?? "?"
                                let ctxStr = overflow.contextTokens.map { "\($0)" } ?? "?"
                                self.streamMsgs[outIdx].text = "⚠️ " + self.contextFallbackMessage(for: self.contextOverflowStrategy) + " (\(promptStr)/\(ctxStr) tokens)"
                            }
                        } else {
                            let lower = diagnosticMessage.lowercased()
                            if !lower.contains("decode") {
                                self.streamMsgs[outIdx].text = "⚠️ " + displayedError
                            }
                        }
                    }
                }
                if !wasCancellation {
                    self.markRollingThoughtsInterrupted(forMessageAt: outIdx)
                }
                if self.loadedFormat == .afm && !intentionalToolRestartCancellation {
                    self.applyPendingAFMToolSummary(to: outIdx)
                }
                if self.remoteLoadingPending {
                    await MainActor.run {
                        self.loadingProgressTracker.completeLoading()
                    }
                    self.remoteLoadingPending = false
                }
                if intentionalToolRestartCancellation {
                    didCancelInitialStreamForToolRestart = false
                } else {
                    if !wasCancellation {
                        await MainActor.run { self.assistantTurnEvents.send(.failed(messageID: messageID)) }
                    }
                    await self.cancelPerfTracking(messageID: messageID)
                    return
                }
            }
            if pendingToolJSON == nil, let remoteService = turnEscalation?.service ?? self.remoteService {
                let bufferedTokens = await remoteService.drainBufferedToolTokens()
                if !bufferedTokens.isEmpty {
                    for token in bufferedTokens {
                        if Task.isCancelled { break }
                        if shouldRestartWithToolResult { break }
                        let trimmedTok = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedTok.isEmpty else { continue }
                        if trimmedTok.hasPrefix("TOOL_RESULT:") {
                            let json = trimmedTok.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await logger.log("[Tool][Stream][Buffered] TOOL_RESULT raw: \(json)") }
                            if let data = json.data(using: .utf8) {
                                await MainActor.run { self.applyWebToolResult(data, messageIndex: outIdx) }
                            }
                            let anchoredRaw = appendingToolAnchor(to: scrubVisibleToolArtifacts(from: raw))
                            pendingAssistantText = anchoredRaw
                            raw = anchoredRaw
                            pendingToolJSON = json
                            shouldRestartWithToolResult = true
                            didCancelInitialStreamForToolRestart = true
                            c.cancelActive()
                            break
                        } else if trimmedTok.hasPrefix("TOOL_CALL:") {
                            Task { await logger.log("[Tool][Stream][Buffered] TOOL_CALL token: \(trimmedTok)") }
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx),
                                   self.streamMsgs[outIdx].toolCalls?.last?.toolName == "noema.web.retrieve" {
                                    self.streamMsgs[outIdx].usedWebSearch = true
                                }
                            }
                            if let (handled, trailing) = await interceptToolCallIfPresent(trimmedTok, messageIndex: outIdx, chatVM: self) {
                                let anchoredRaw = appendingToolAnchor(to: raw)
                                pendingAssistantText = anchoredRaw
                                raw = anchoredRaw
                                if let trailing, !trailing.isEmpty {
                                raw += trailing
                                await MainActor.run {
                                    if self.streamMsgs.indices.contains(outIdx) {
                                            self.streamingStore.update(visibleAssistantText(from: raw))
                                            self.streamMsgs[outIdx].text = visibleAssistantText(from: raw)
                                    }
                                }
                            }
                                await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
                                let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                                pendingToolJSON = json
                                didProcessEmbeddedToolCall = true
                                shouldRestartWithToolResult = true
                                didCancelInitialStreamForToolRestart = true
                                c.cancelActive()
                                break
                            }
                        }
                    }
                }
            }
            // Phone-a-friend safety net: a hand-off call emitted right at the
            // end of the stream must divert to the escalation path, NOT be
            // executed as a normal tool (which returns "unavailable" and
            // cancels the hand-off). Mirror the mid-loop divert.
            if !didProcessEmbeddedToolCall, pendingToolJSON == nil,
               pendingPhoneAFriendReason == nil,
               turnEscalation == nil, self.remoteService == nil,
               allowPhoneAFriendHandoff,
               usedImagePathsForThisRun.isEmpty,
               let peek = peekEmbeddedToolCallTarget(in: raw),
               peek.tool == PhoneAFriendTool.toolName {
                let reason = (peek.arguments["reason"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if self.phoneAFriendHandoffAllowedNow(reason: reason) {
                    await MainActor.run {
                        recordPhoneAFriendHandoffCall(
                            messageIndex: outIdx,
                            chatVM: self,
                            reason: reason,
                            phase: .executing
                        )
                    }
                    Task { await logger.log("[Autopilot][PhoneAFriend] post-stream handoff requested reason=\(reason.prefix(120))") }
                    pendingPhoneAFriendReason = reason
                    didProcessEmbeddedToolCall = true
                }
            }
            // Final safety net: if the model emitted a <tool_call> or bare JSON tool call
            // right at the end of the stream and we didn't process it mid-stream, detect
            // and dispatch it now so the conversation reliably continues.
            if !didProcessEmbeddedToolCall, pendingToolJSON == nil, pendingPhoneAFriendReason == nil {
                if let result = await interceptEmbeddedToolCallIfPresent(in: raw, messageIndex: outIdx, chatVM: self),
                   let handled = result.token {
                    Task { await logger.log("[Tool][ChatVM] Post-stream embedded tool call detected and dispatched") }
                    // Preserve assistant text prior to the tool call
                    let anchoredCleaned = result.cleanedText
                    pendingAssistantText = anchoredCleaned
                    raw = anchoredCleaned
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            if self.streamMsgs[outIdx].toolCalls?.last?.toolName == "noema.web.retrieve" {
                                self.streamMsgs[outIdx].usedWebSearch = true
                            }
                            self.streamingStore.update(visibleAssistantText(from: anchoredCleaned))
                            self.streamMsgs[outIdx].text = visibleAssistantText(from: anchoredCleaned)
                        }
                    }
                    await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
                    let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingToolJSON = json
                    didProcessEmbeddedToolCall = true
                }
            }

            if self.remoteLoadingPending {
                await MainActor.run {
                    self.loadingProgressTracker.completeLoading()
                }
                self.remoteLoadingPending = false
            }

            // Do not hide or alter chain-of-thought: preserve full model output including <think> sections.
            // Avoid transforming enumerations (e.g., "Step 1:") to keep original thinking intact.
            let cleanedBase = self.cleanOutput(raw, kind: self.currentKind)
            var cleaned = pendingToolJSON == nil
                ? await self.scrubEmbeddedToolArtifactsWithoutDispatch(in: cleanedBase, messageIndex: outIdx)
                : cleanedBase
            if pendingToolJSON == nil {
                cleaned = await pruneDanglingPlaceholderToolCalls(
                    messageIndex: outIdx,
                    chatVM: self,
                    preferredText: cleaned
                ) ?? cleaned
            }
            // A phone-a-friend handoff behaves like a tool continuation for
            // finalize purposes: the turn is not complete, no ledger tally yet.
            let finalizePendingToolJSON = pendingPhoneAFriendReason != nil
                ? "{\"tool\":\"\(PhoneAFriendTool.toolName)\"}"
                : pendingToolJSON
            // Trailing flush: commit the final visible text into `sessions` so finalize sees
            // the complete output (the per-token loop only checkpointed periodically).
            if finalizePendingToolJSON == nil {
                await MainActor.run {
                    if myID == self.activeRunID,
                       self.streamMsgs.indices.contains(outIdx),
                       self.streamMsgs[outIdx].streaming {
                        self.streamMsgs[outIdx].text = visibleAssistantText(from: cleaned)
                    }
                }
            }
            let injectionOverhead = (self.injectionMethod == .full && self.currentInjectedTokenOverhead > 0) ? self.currentInjectedTokenOverhead : 0
            let perfResult: Msg.Perf? = shouldRestartWithToolResult ? nil : await self.finalizePerf(messageID: messageID, injectionOverhead: injectionOverhead)
            await self.finalizeAssistantStream(
                runID: myID,
                messageIndex: outIdx,
                cleanedText: cleaned,
                pendingToolJSON: finalizePendingToolJSON,
                perfResult: perfResult,
                tokenCount: count,
                generationStart: start,
                firstTokenTimestamp: firstTok,
                isMLXFormat: isMLXFormat
            )
            if self.loadedFormat == .afm {
                self.applyPendingAFMToolSummary(to: outIdx)
            }
            // Set session title from first user query with a sensible word cap
            if let sIdx = self.streamSessionIndex,
               self.sessions.indices.contains(sIdx),
               self.sessions[sIdx].title.isEmpty || self.sessions[sIdx].title == "New chat" {
                let normalized = input
                    .replacingOccurrences(of: "[\n\r]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Remove surrounding quotes if present
                let unquoted: String = {
                    if normalized.hasPrefix("\"") && normalized.hasSuffix("\"") && normalized.count > 2 {
                        return String(normalized.dropFirst().dropLast())
                    }
                    if normalized.hasPrefix("'") && normalized.hasSuffix("'") && normalized.count > 2 {
                        return String(normalized.dropFirst().dropLast())
                    }
                    return normalized
                }()
                // Limit to a sensible word count (e.g., 8 words)
                let words = unquoted.split { $0.isWhitespace }
                let capped = words.prefix(8).joined(separator: " ")
                let cleaned = capped.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
                self.sessions[sIdx].title = cleaned.isEmpty ? Self.defaultTitle(date: Date()) : cleaned
            }
            // Phone-a-friend: the local model asked for the handoff — run the
            // rest of the turn on the escalation model in a follow-up task.
            if let handoffReason = pendingPhoneAFriendReason {
                let handoffPrompt = promptStr
                let handoffStops = stops
                // Keep the message in-flight across the bridge: finalize above
                // set streaming=false, which would unblock the composer and let
                // a new send bump activeRunID while preparePhoneAFriendEscalation
                // (a possibly-slow MLX load) is still awaiting. Re-arm so the
                // Stop button stays and sendMessage's isStreaming gate holds.
                await MainActor.run {
                    guard myID == self.activeRunID,
                          self.streamMsgs.indices.contains(outIdx) else { return }
                    self.streamMsgs[outIdx].streaming = true
                    self.streamingStore.begin(id: messageID)
                }
                let continuationTaskID = UUID()
                let handoffTask: Task<Void, Never> = Task { [weak self] in
                    guard let self else { return }
                    await self.runPhoneAFriendHandoff(
                        continuationTaskID: continuationTaskID,
                        reason: handoffReason,
                        runID: myID,
                        messageIndex: outIdx,
                        history: history,
                        input: input,
                        sessionIndex: sessionIndex,
                        messageID: messageID,
                        isMLXFormat: isMLXFormat,
                        localFallbackPrompt: handoffPrompt,
                        localFallbackStops: handoffStops
                    )
                }
                self.currentContinuationTaskID = continuationTaskID
                self.currentContinuationTask = handoffTask
            }
            // If a tool was called mid-stream
            else if let toolJSON = pendingToolJSON {
                // For ET models: do NOT append any visible user message.
                // We'll continue by sending a hidden user nudge (not shown in UI) so the
                // assistant continues streaming into the same bubble.
                if self.loadedFormat == .et {
                    // Fall through to continuation task, which will stream the assistant's
                    // reply into the SAME assistant box (outIdx) using a hidden postToolInput.
                }
                // Non-ET: continue in place with hidden tool context
                transfersLocalEscalationTurn = turnEscalation?.localTurnToken != nil
                let continuationTaskID = UUID()
                let continuationTask: Task<Void, Never> = Task { [weak self] in
                    guard let self else { return }
                    // Escalated turns continue on the SAME turn-scoped cloud client;
                    // re-reading self.client here would splice the tool loop back
                    // onto the local model mid-turn.
                    guard let client = turnEscalation?.client ?? self.client else {
                        self.releaseLocalEscalationTurn(turnEscalation)
                        await self.cancelPerfTracking(messageID: messageID)
                        return
                    }
                    await self.runToolContinuation(
                        continuationTaskID: continuationTaskID,
                        runID: myID,
                        client: client,
                        initialPendingAssistantText: pendingAssistantText,
                        sessionIndex: sessionIndex,
                        messageID: messageID,
                        history: history,
                        outIdx: outIdx,
                        toolJSON: toolJSON,
                        streamChunkMergeMode: streamChunkMerger.mode,
                        usedImagePathsForThisRun: usedImagePathsForThisRun,
                        turnSystemPrompt: stableSystemPrompt,
                        turnEscalation: turnEscalation
                    )
                }
                self.currentContinuationTaskID = continuationTaskID
                self.currentContinuationTask = continuationTask
            }
    }

    // maybeAutoTitle removed in favor of using the first user query as title

    /// Runs the escalated remainder of a phone-a-friend turn: prepares the
    /// stronger model (cloud or local on macOS), rewrites the message's
    /// provenance + route record, and re-enters the streaming pipeline with a
    /// turn-scoped escalation. If no escalation is possible the turn restarts
    /// on-device with the handoff tool suppressed, mirroring the router's
    /// pre-first-token cloud fallback.
    private func runPhoneAFriendHandoff(
        continuationTaskID: UUID,
        reason: String,
        runID myID: Int,
        messageIndex outIdx: Int,
        history: [Msg],
        input: String,
        sessionIndex: Int,
        messageID: UUID,
        isMLXFormat: Bool,
        localFallbackPrompt: String,
        localFallbackStops: [String]
    ) async {
        defer {
            if currentContinuationTaskID == continuationTaskID {
                currentContinuationTask = nil
                currentContinuationTaskID = nil
                if streamSessionIndex == sessionIndex {
                    streamSessionIndex = nil
                }
            }
        }
        guard myID == self.activeRunID, !Task.isCancelled else { return }

        func restartLocally(failNote: String) async {
            // A newer send may have started while we awaited the escalation
            // prepare: never rewrite this (now-stale) message or hijack the
            // live-text store from the newer run.
            guard myID == self.activeRunID, !Task.isCancelled else { return }
            await logger.log("[Autopilot][PhoneAFriend] handoff unavailable (\(failNote)); continuing on-device")
            await MainActor.run {
                guard myID == self.activeRunID,
                      self.streamMsgs.indices.contains(outIdx) else { return }
                recordPhoneAFriendHandoffCall(
                    messageIndex: outIdx,
                    chatVM: self,
                    reason: reason,
                    phase: .failed,
                    error: AutopilotReasonKey.localized(AutopilotReasonKey.phoneAFriendUnavailable)
                )
                let decision = AutoRouteDecision(
                    target: .local,
                    confidence: 1.0,
                    reason: AutopilotReasonKey.localized(AutopilotReasonKey.phoneAFriendUnavailable),
                    reasonKey: AutopilotReasonKey.phoneAFriendUnavailable,
                    category: nil,
                    estDifficulty: 1,
                    latencyMs: 0,
                    decidedBy: .phoneAFriend
                )
                self.streamMsgs[outIdx].route = RouteDecisionRecord(decision: decision, fellBackToLocal: true)
                self.streamMsgs[outIdx].streaming = true
                self.streamMsgs[outIdx].text = ""
                self.streamingStore.begin(id: messageID)
            }
            await self.runInitialStreamTask(
                runID: myID,
                messageIndex: outIdx,
                promptStr: localFallbackPrompt,
                stops: localFallbackStops,
                history: history,
                input: input,
                initialLLMInput: LLMInput(.plain("")),
                initialUsedImagePathsForThisRun: [],
                remoteToolsAllowedOverride: .none,
                sessionIndex: sessionIndex,
                messageID: messageID,
                isMLXFormat: isMLXFormat,
                allowPhoneAFriendHandoff: false
            )
        }

        guard let esc = await self.preparePhoneAFriendEscalation(reason: reason) else {
            await restartLocally(failNote: "target unavailable")
            return
        }
        guard myID == self.activeRunID, !Task.isCancelled else {
            self.releaseLocalEscalationTurn(esc)
            return
        }

        await MainActor.run {
            recordPhoneAFriendHandoffCall(messageIndex: outIdx, chatVM: self, reason: reason, phase: .completed)
            guard self.streamMsgs.indices.contains(outIdx) else { return }
            let record = RouteDecisionRecord(
                decision: esc.decision,
                escalationBackendName: esc.backend?.name,
                escalationModelName: esc.modelName,
                escalationIsLocal: esc.isLocalTarget,
                escalationUsesPrivateCloudCompute: esc.isPrivateCloudComputeTarget
            )
            self.streamMsgs[outIdx].route = record
            if esc.isLocalTarget {
                self.streamMsgs[outIdx].localModelName = esc.modelName
            } else if esc.isPrivateCloudComputeTarget {
                self.streamMsgs[outIdx].ranOnPrivateCloudCompute = true
                self.streamMsgs[outIdx].usedRemoteBackend = false
                self.streamMsgs[outIdx].remoteBackendName = nil
                self.streamMsgs[outIdx].remoteModelName = esc.modelName
                self.streamMsgs[outIdx].localModelName = nil
            } else {
                self.streamMsgs[outIdx].usedRemoteBackend = true
                self.streamMsgs[outIdx].remoteBackendName = esc.backend?.name
                self.streamMsgs[outIdx].remoteModelName = esc.modelName
                self.streamMsgs[outIdx].localModelName = nil
            }
            // The stronger model owns the whole answer; drop the partial local text.
            self.streamMsgs[outIdx].text = ""
            self.streamMsgs[outIdx].streaming = true
            self.streamingStore.begin(id: messageID)
            self.currentTurnEscalationCancel = { esc.client.cancelActive() }
        }

        // Tool hygiene for the stronger model: cloud escalations keep the
        // (handoff-stripped) tool set; local escalations run tool-free so the
        // resident model's guidance never leaks into their prompt.
        var remoteTools = ToolAvailability.none
        if esc.service != nil {
            remoteTools = self.toolAvailability(
                from: PhoneAFriendGate.strippingHandoff(from: await self.fetchEnabledToolSpecs())
            )
        }
        self.systemPromptToolAvailabilityOverride = remoteTools.any ? remoteTools : ToolAvailability.none

        // Preserve the RAG / full-document context the local model had: the
        // stronger model must answer the SAME grounded question, or it answers
        // a document question with no document.
        let retrievedContext = self.streamMsgs.indices.contains(outIdx)
            ? self.streamMsgs[outIdx].retrievedContext
            : nil
        let isFullDocumentContext = self.streamMsgs.indices.contains(outIdx)
            && self.streamMsgs[outIdx].ragInjectionInfo?.method == .fullContent

        let escInput: LLMInput
        let escPrompt: String
        let escStops: [String]
        if esc.isLocalTarget {
            // Local MLX/GGUF escalation self-templates role-tagged messages
            // (RAG context injected into the final user turn).
            self.refreshSystemPromptForActiveSession(historyOverride: history)
            let (p, s, _) = self.buildPromptForEscalatedTurn(kind: esc.remoteKind, history: history)
            escPrompt = p
            escStops = s
            escInput = LLMInput(.messages(self.escalationChatMessages(
                history: history,
                systemPrompt: self.systemPromptText,
                retrievedContext: retrievedContext
            )))
        } else if isFullDocumentContext,
                  let ctx = retrievedContext,
                  !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Full-document context rides the system prompt (stable prefix).
            self.refreshSystemPromptForActiveSession(historyOverride: history)
            let (p, s, _) = self.buildPromptForEscalatedTurn(
                kind: esc.remoteKind,
                history: history,
                systemPromptOverride: self.systemPromptWithFullDocument(ctx)
            )
            escPrompt = p
            escStops = s
            escInput = LLMInput(.plain(p))
        } else {
            self.refreshSystemPromptForActiveSession(historyOverride: history)
            var (p, s, _) = self.buildPromptForEscalatedTurn(kind: esc.remoteKind, history: history)
            if let ctx = retrievedContext,
               !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                p = self.injectContextIntoPrompt(original: p, context: ctx, kind: esc.remoteKind)
            }
            escPrompt = p
            escStops = s
            escInput = LLMInput(.plain(p))
        }
        Task { await logger.log("[Autopilot][PhoneAFriend] handing off to \(esc.modelName) (\(esc.isLocalTarget ? "local" : "cloud"))") }

        await self.runInitialStreamTask(
            runID: myID,
            messageIndex: outIdx,
            promptStr: escPrompt,
            stops: escStops,
            history: history,
            input: input,
            initialLLMInput: escInput,
            initialUsedImagePathsForThisRun: [],
            remoteToolsAllowedOverride: remoteTools,
            sessionIndex: sessionIndex,
            messageID: messageID,
            isMLXFormat: isMLXFormat,
            turnEscalation: esc,
            localFallbackPrompt: localFallbackPrompt,
            localFallbackStops: localFallbackStops,
            allowPhoneAFriendHandoff: false
        )
    }

    private func runToolContinuation(
        continuationTaskID: UUID,
        runID myID: Int,
        client: AnyLLMClient,
        initialPendingAssistantText: String?,
        sessionIndex: Int,
        messageID: UUID,
        history: [ChatVM.Msg],
        outIdx: Int,
        toolJSON: String,
        streamChunkMergeMode: StreamChunkMergeMode,
        usedImagePathsForThisRun: [String],
        turnSystemPrompt: String,
        turnEscalation: TurnEscalation? = nil
    ) async {
        defer {
            releaseLocalEscalationTurn(turnEscalation)
            Task { @MainActor in
                if self.currentContinuationTaskID == continuationTaskID {
                    self.currentContinuationTask = nil
                    self.currentContinuationTaskID = nil
                    if self.streamSessionIndex == sessionIndex {
                        self.streamSessionIndex = nil
                    }
                }
            }
        }
        guard myID == activeRunID, !Task.isCancelled else {
            client.cancelActive()
            return
        }

        // Hidden assistant transcript used only for continuation prompt rebuilding.
        var pendingAssistantText = initialPendingAssistantText

        let originalQuestion = history.last(where: {
            let role = $0.role.lowercased()
            return role == "user" || $0.role == "🧑‍💻"
        })?.text ?? ""

        let liveToolCalls = self.streamMsgs.indices.contains(outIdx)
            ? self.streamMsgs[outIdx].toolCalls
            : nil
        // `outIdx` indexes the live session. Context-window trimming can remove
        // earlier messages from `history`, so find this assistant by identity
        // before mutating the compacted continuation transcript.
        let assistantHistoryIndex = history.firstIndex(where: { $0.id == messageID })
            ?? history.lastIndex(where: {
                let role = $0.role.lowercased()
                return role == "assistant" || role == "🤖"
            })
            ?? outIdx
        let continuationHistory = self.historyForToolContinuation(
            from: history,
            assistantIndex: assistantHistoryIndex,
            assistantText: pendingAssistantText ?? "",
            assistantToolCalls: liveToolCalls,
            toolResult: toolJSON
        )

        var localHistory = continuationHistory
        var continuationChunkMerger = StreamChunkMerger(mode: streamChunkMergeMode)
        var didTriggerFinalAnswerStartHaptic = false
        // Same coalescing policy as the initial stream loop (see notes there).
        var lastStoreFlush: ContinuousClock.Instant?
        var lastSessionFlush: ContinuousClock.Instant?
        let storeFlushInterval: Duration = .milliseconds(33)
        // See initial-loop note: a frequent `sessions` checkpoint trips ChatVM.objectWillChange
        // and re-renders the whole TabView/ExploreView. Keep it occasional.
        let sessionCheckpointInterval: Duration = .milliseconds(2000)
        // Throttle the per-token rolling-thought reparse to ~30 Hz (see initial-loop notes).
        var lastHeavyScan: ContinuousClock.Instant?
        let heavyScanInterval: Duration = .milliseconds(33)

        await MainActor.run {
            if self.streamMsgs.indices.contains(outIdx) {
                self.streamMsgs[outIdx].streaming = true
                // Re-arm the narrow store for the post-tool continuation, seeding it with the
                // text already on screen so the bubble doesn't flash empty.
                self.streamingStore.begin(id: self.streamMsgs[outIdx].id, initialText: self.streamMsgs[outIdx].text)
                if self.supportsPromptProcessingCard {
                    self.startPromptProcessing(for: outIdx)
                    self.streamMsgs[outIdx].postToolWaiting = false
                } else {
                    self.clearPromptProcessing(for: outIdx)
                    self.streamMsgs[outIdx].postToolWaiting = true
                }
                AccessibilityAnnouncer.announceLocalized("Generating response…")
            }
        }

        var prefillRetryAttempts = 0
        let maxPrefillRetries = 3
        continuationLoop: while true {
            guard myID == activeRunID, !Task.isCancelled else {
                client.cancelActive()
                return
            }
            var postToolInput: LLMInput? = nil
            await MainActor.run {
                if self.streamMsgs.indices.contains(outIdx) {
                    if self.supportsPromptProcessingCard {
                        self.startPromptProcessing(for: outIdx)
                        self.streamMsgs[outIdx].postToolWaiting = false
                    } else {
                        self.clearPromptProcessing(for: outIdx)
                        self.streamMsgs[outIdx].postToolWaiting = true
                    }
                }
            }
            if self.loadedFormat == .et {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if localHistory.indices.contains(assistantHistoryIndex) {
                let latestAssistantText: String
                if let preserved = pendingAssistantText {
                    latestAssistantText = preserved
                } else {
                    latestAssistantText = await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            return self.streamMsgs[outIdx].text
                        } else {
                            return localHistory[assistantHistoryIndex].text
                        }
                    }
                }
                localHistory[assistantHistoryIndex].text = latestAssistantText
                let preservedToolCalls = localHistory[assistantHistoryIndex].toolCalls
                let latestToolCalls = await MainActor.run {
                    self.streamMsgs.indices.contains(outIdx)
                        ? self.streamMsgs[outIdx].toolCalls
                        : preservedToolCalls
                }
                localHistory[assistantHistoryIndex].toolCalls = latestToolCalls
            }
            // Do NOT inject the post-tool nudge as a user turn here. localHistory
            // already ends with the assistant's tool_calls message + the role:"tool"
            // result, which structured models below render as a proper tool-calling
            // transcript and continue from directly. A synthetic user-role nudge made
            // small models quote and meta-reason about it instead of answering. The
            // nudge is re-added ONLY on the non-structured buildPrompt fallback (which
            // has no tool-transcript framing), and the .et path builds its own below.
            var promptHistory: [ChatVM.Msg] = localHistory
            // Tool results (web pages, search dumps) can blow past the context
            // budget mid-conversation; apply the same overflow plan as the
            // initial send so the continuation doesn't 400 with a raw error.
            if self.loadedFormat != .et {
                let continuationPlan = self.planHistoryForContextOverflow(history: promptHistory)
                if continuationPlan.initialEstimate > self.contextSoftLimitTokens() {
                    self.registerContextOverflow(
                        strategy: self.contextOverflowStrategy,
                        details: ContextOverflowDetails(
                            promptTokens: continuationPlan.initialEstimate,
                            contextTokens: self.currentPromptBudget().usablePromptTokens,
                            rawMessage: "continuation-overflow"
                        )
                    )
                }
                if continuationPlan.requiresStop && self.contextOverflowStrategy == .stopAtLimit {
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.clearPromptProcessing(for: outIdx)
                            let stopNote = self.contextStopMessage(details: nil)
                            let partialText = localHistory.indices.contains(assistantHistoryIndex)
                                ? visibleAssistantText(from: localHistory[assistantHistoryIndex].text)
                                : ""
                            self.streamMsgs[outIdx].text = partialText + "\n⚠️ " + stopNote
                            self.streamMsgs[outIdx].postToolWaiting = false
                            self.streamingStore.finish()
                        }
                    }
                    break continuationLoop
                }
                promptHistory = continuationPlan.history
            }
            let (_, continuationStops, _) = turnEscalation.map { esc in
                self.buildPromptForEscalatedTurn(kind: esc.remoteKind, history: promptHistory)
            } ?? self.buildPrompt(kind: self.currentKind, history: promptHistory)
            let locallyEnforcedContinuationStops = AssistantOutputSanitizer
                .locallyEnforcedStopSequences(including: continuationStops)
            if let esc = turnEscalation {
                let ctx = self.streamMsgs.indices.contains(outIdx)
                    ? self.streamMsgs[outIdx].retrievedContext
                    : nil
                let messages = self.escalationChatMessages(
                    history: promptHistory,
                    systemPrompt: turnSystemPrompt,
                    retrievedContext: ctx
                )
                if esc.isLocalTarget {
                    // Local MLX/GGUF escalation self-templates the role-tagged
                    // transcript, including the native tool call/result pair.
                    postToolInput = LLMInput(.messages(messages))
                } else {
                    // Cloud escalation must retain those same roles. The remote
                    // service serializes them directly into the chat request and
                    // attaches approved images to the final user turn.
                    postToolInput = usedImagePathsForThisRun.isEmpty
                        ? LLMInput(.messages(messages))
                        : LLMInput.multimodal(messages: messages, imagePaths: usedImagePathsForThisRun)
                }
            } else if self.loadedFormat == .et {
                let previousUser = history.last(where: { $0.role.lowercased() == "user" || $0.role == "🧑‍💻" })?.text ?? ""
                let trimmedQuestion = previousUser.trimmingCharacters(in: .whitespacesAndNewlines)
                let nudgeBody: String = {
                    if trimmedQuestion.isEmpty {
                        return "Continue your earlier response using these search results. Search again only if more evidence is needed."
                    }
                    return "Use these search results to answer: \(trimmedQuestion). Search again only if more evidence is needed."
                }()
                let toolPayload: String = (localHistory.last { $0.role == "tool" })?.text ?? toolJSON
                let toolMsg = ChatMessage(role: "tool", content: toolPayload)
                let userMsg = ChatMessage(role: "user", content: nudgeBody)
                postToolInput = LLMInput(.messages([toolMsg, userMsg]))
            } else {
                let retrievedContext = self.streamMsgs.indices.contains(outIdx)
                    ? self.streamMsgs[outIdx].retrievedContext
                    : nil
                let isFullDocumentContext = self.streamMsgs.indices.contains(outIdx)
                    && self.streamMsgs[outIdx].ragInjectionInfo?.method == .fullContent
                let nativeTools = await self.nativeToolSpecs()
                if !usedImagePathsForThisRun.isEmpty,
                   let structuredInput = self.structuredLoopbackMultimodalInput(
                    for: promptHistory,
                    imagePaths: usedImagePathsForThisRun,
                    retrievedContext: retrievedContext,
                    tools: nativeTools,
                    fullDocumentPlacement: isFullDocumentContext,
                    systemPromptOverride: turnSystemPrompt
                ) {
                    postToolInput = structuredInput
                } else if let structuredInput = self.structuredLoopbackInput(
                    for: promptHistory,
                    retrievedContext: retrievedContext,
                    tools: nativeTools,
                    fullDocumentPlacement: isFullDocumentContext,
                    systemPromptOverride: turnSystemPrompt
                ) {
                    postToolInput = structuredInput
                } else {
                    // Non-structured models get a flat concatenated prompt with no
                    // tool-call transcript framing, so a terse nudge is still needed to
                    // tell them to answer from the tool result.
                    let latestToolName = self.streamMsgs.indices.contains(outIdx)
                        ? self.streamMsgs[outIdx].toolCalls?.last?.toolName
                        : nil
                    var nudgedHistory = promptHistory
                    nudgedHistory.append(
                        ChatVM.Msg(
                            role: "user",
                            text: self.postToolContinuationNudge(
                                toolName: latestToolName,
                                originalQuestion: originalQuestion
                            ),
                            timestamp: Date()
                        )
                    )
                    let continuationPrompt = self.plainToolContinuationPrompt(
                        history: nudgedHistory,
                        retrievedContext: retrievedContext,
                        fullDocumentPlacement: isFullDocumentContext,
                        systemPromptOverride: turnSystemPrompt
                    )
                    // Full remote sessions land here (structured inputs are
                    // loopback-only); keep the turn's approved images attached.
                    postToolInput = usedImagePathsForThisRun.isEmpty
                        ? LLMInput.plain(continuationPrompt)
                        : LLMInput.multimodal(text: continuationPrompt, imagePaths: usedImagePathsForThisRun)
                }
            }

            let baseAssistantText = localHistory.indices.contains(assistantHistoryIndex)
                ? localHistory[assistantHistoryIndex].text
                : ""
            let baseVisibleAssistantText = visibleAssistantText(from: baseAssistantText)
            var continuation = ""
            // MLX only: seed a visible <think> for the post-tool continuation the way the
            // initial stream does (~3573). MLX has no server to separate reasoning from the
            // answer (GGUF's llama.cpp server does that via reasoning_format), and its
            // continuation prompt doesn't re-open a think block, so the model's analysis of
            // the tool result otherwise streams as plain answer text. Self-healed after the
            // loop if the model never closes </think>, so a direct answer is never trapped.
            let seedContinuationThink = (loadedFormat == .mlx) && baseVisibleAssistantText.contains("<think>")
            if seedContinuationThink { continuation = "<think>" }
            var continuationPassMergedText = ""
            var outputContinuationBoundaryFilter: OutputContinuationBoundaryFilter?
            var activeOutputContinuationEventID: UUID?
            var nextToolJSON: String? = nil
            var didCancelContinuationForToolRestart = false
            var didCancelContinuationForToolResult = false
            var contTokCount = 0
            var resolvedFinalContinuationText: String? = nil
            do {
                guard let rawInput = postToolInput else { break }
                // Carry the reasoning toggle into the post-tool continuation too, so a
                // "no reasoning" turn doesn't start thinking when answering after a tool.
                var activeContinuationInput = self.applyingLoadedReasoningPreference(to: rawInput)
                var continuationPassStartCharacterCount = continuation.count
                let continuationPromptProgressHandler: (@Sendable (Double) -> Void)?
                if self.supportsPromptProcessingCard {
                    continuationPromptProgressHandler = { progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.streamMsgs.indices.contains(outIdx) else { return }
                            self.updatePromptProcessingProgress(progress, messageIndex: outIdx)
                        }
                    }
                } else {
                    continuationPromptProgressHandler = nil
                }
                outputContinuationLoop: while true {
                for try await t in try await client.textStream(
                    from: activeContinuationInput,
                    onPromptProgress: continuationPromptProgressHandler
                ) {
                    if Task.isCancelled || myID != self.activeRunID {
                        client.cancelActive()
                        return
                    }
                    await self.recordToken(messageID: messageID)
                    let trimmedT = t.trimmingCharacters(in: .whitespacesAndNewlines)

                    if trimmedT.hasPrefix("TOOL_CALL:") {
                        // Mirror the initial-stream guard (Noema.swift ~3722) and
                        // interceptEmbeddedToolCallIfPresent: never dispatch a tool call while
                        // the model is still inside an unclosed <think> block. Dispatching here
                        // appends the tool anchor mid-reasoning, which desyncs the two think-block
                        // parsers (render vs rolling-thought) and produces duplicate REASONING rows.
                        let insideThink: Bool = {
                            let scanned = baseVisibleAssistantText + continuation
                            guard let open = scanned.range(of: "<think>", options: .backwards) else { return false }
                            if let close = scanned.range(of: "</think>", options: .backwards) {
                                return open.lowerBound > close.lowerBound
                            }
                            return true
                        }()
                        if insideThink && turnEscalation == nil && self.remoteService == nil { continue }
                        if let (handled, trailing) = await interceptToolCallIfPresent(trimmedT, messageIndex: outIdx, chatVM: self) {
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx),
                                   self.streamMsgs[outIdx].toolCalls?.last?.toolName == "noema.web.retrieve" {
                                    self.streamMsgs[outIdx].usedWebSearch = true
                                }
                            }
                            let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            nextToolJSON = json
                            continuation = appendingToolAnchor(to: scrubVisibleToolArtifacts(from: continuation))
                            pendingAssistantText = baseAssistantText + continuation
                            if let trailing, !trailing.isEmpty {
                                continuation += trailing
                            }
                            let continuationText = baseVisibleAssistantText + visibleAssistantText(from: continuation)
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx) {
                                    self.streamingStore.update(continuationText)
                                    self.streamMsgs[outIdx].text = continuationText
                                }
                            }
                            await self.handleRollingThoughts(raw: continuationText, messageIndex: outIdx)
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx) {
                                    self.streamMsgs[outIdx].postToolWaiting = true
                                }
                            }
                            didCancelContinuationForToolRestart = true
                            client.cancelActive()
                            break
                        }
                    }
                    if trimmedT.hasPrefix("TOOL_RESULT:") {
                        let json = trimmedT.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        pendingAssistantText = baseAssistantText + appendingToolAnchor(to: scrubVisibleToolArtifacts(from: continuation))
                        nextToolJSON = json
                        didCancelContinuationForToolResult = true
                        client.cancelActive()
                        break
                    }

                    let passDelta = continuationChunkMerger.append(t, to: &continuationPassMergedText)
                    let appendChunk: String
                    if var boundaryFilter = outputContinuationBoundaryFilter {
                        appendChunk = boundaryFilter.append(passDelta)
                        outputContinuationBoundaryFilter = boundaryFilter
                    } else {
                        appendChunk = passDelta
                    }
                    continuation += appendChunk
                    if !appendChunk.isEmpty,
                       let eventID = activeOutputContinuationEventID {
                        await MainActor.run {
                            self.resolveAutomaticOutputContinuation(
                                messageIndex: outIdx,
                                eventID: eventID,
                                phase: .continued
                            )
                        }
                        activeOutputContinuationEventID = nil
                    }
                    contTokCount += 1

                    if contTokCount == 1 {
                        await MainActor.run {
                            if self.streamMsgs.indices.contains(outIdx) {
                                self.clearPromptProcessing(for: outIdx)
                                self.streamMsgs[outIdx].postToolWaiting = false
                            }
                        }
                    }

                    let visibleContinuation = baseVisibleAssistantText + visibleAssistantText(from: continuation)
                    let now = ContinuousClock().now
                    let shouldFlushStore = lastStoreFlush.map { now - $0 >= storeFlushInterval } ?? true
                    let shouldCheckpointSession = lastSessionFlush.map { now - $0 >= sessionCheckpointInterval } ?? true
                    if shouldFlushStore { lastStoreFlush = now }
                    if shouldFlushStore, shouldCheckpointSession { lastSessionFlush = now }
                    if shouldFlushStore {
                        let shouldTriggerFinalAnswerHaptic = await MainActor.run { () -> Bool in
                            guard self.streamMsgs.indices.contains(outIdx) else { return false }
                            // High-frequency: live bubble + auto-scroll (narrow observable).
                            self.streamingStore.update(visibleContinuation)
                            // Low-frequency: checkpoint into sessions for copy/readbacks/finalize.
                            if shouldCheckpointSession {
                                self.streamMsgs[outIdx].text = visibleContinuation
                            }
                            if didTriggerFinalAnswerStartHaptic { return false }
                            return self.strictFinalAnswerText(forText: visibleContinuation, toolCalls: self.streamMsgs[outIdx].toolCalls) != nil
                        }
                        if shouldTriggerFinalAnswerHaptic {
#if os(iOS)
                            Haptics.impact(.medium)
#endif
                            didTriggerFinalAnswerStartHaptic = true
                        }
                    }
                    let fullText = visibleContinuation
                    // Throttle the per-token rolling-thought reparse to ~30 Hz; the trailing
                    // flush after the loop captures the final state.
                    let nowScan = ContinuousClock().now
                    let shouldHeavyScan = lastHeavyScan.map { nowScan - $0 >= heavyScanInterval } ?? true
                    if shouldHeavyScan {
                        lastHeavyScan = nowScan
                        await self.handleRollingThoughts(raw: fullText, messageIndex: outIdx)
                    }

                    if let stop = AssistantOutputSanitizer.strippingTrailingStopSequence(
                        from: continuation,
                        stopSequences: locallyEnforcedContinuationStops
                    ) {
                        let lastOpen = fullText.range(of: "<think>", options: .backwards)
                        let lastClose = fullText.range(of: "</think>", options: .backwards)
                        let insideThink = {
                            if let o = lastOpen {
                                if let c = lastClose { return o.lowerBound > c.lowerBound }
                                return true
                            }
                            return false
                        }()
                        if !insideThink {
                            continuation = stop.text
                            break
                        }
                    }
                }

                if var boundaryFilter = outputContinuationBoundaryFilter {
                    let finalBoundaryText = boundaryFilter.finish()
                    outputContinuationBoundaryFilter = boundaryFilter
                    if !finalBoundaryText.isEmpty {
                        continuation += finalBoundaryText
                        if let eventID = activeOutputContinuationEventID {
                            await MainActor.run {
                                self.resolveAutomaticOutputContinuation(
                                    messageIndex: outIdx,
                                    eventID: eventID,
                                    phase: .continued
                                )
                            }
                            activeOutputContinuationEventID = nil
                        }
                        let visibleContinuation = baseVisibleAssistantText
                            + visibleAssistantText(from: continuation)
                        await MainActor.run {
                            guard self.streamMsgs.indices.contains(outIdx) else { return }
                            self.streamingStore.update(visibleContinuation)
                            self.streamMsgs[outIdx].text = visibleContinuation
                        }
                    }
                }

                let endedAtContextLimit = client.mostRecentFinishReason()?.lowercased() == "length"
                let canResumeAcrossContextLimit = endedAtContextLimit
                    && self.loadedFormat == .gguf
                    && turnEscalation == nil
                    && self.remoteService == nil
                    && self.contextOverflowStrategy != .stopAtLimit
                    && nextToolJSON == nil
                    && continuation.count > continuationPassStartCharacterCount
                    && myID == self.activeRunID
                    && !Task.isCancelled

                if canResumeAcrossContextLimit {
                    continuation = AssistantOutputSanitizer
                        .closingUnterminatedReasoningBlocks(in: continuation)
                    continuation = OutputContinuationTextCoordinator.checkpoint(from: continuation)
                    let checkpointVisibleText = baseVisibleAssistantText
                        + visibleAssistantText(from: continuation)
                    await MainActor.run {
                        guard self.streamMsgs.indices.contains(outIdx) else { return }
                        self.streamingStore.update(checkpointVisibleText)
                        self.streamMsgs[outIdx].text = checkpointVisibleText
                    }
                    await self.handleRollingThoughts(
                        raw: checkpointVisibleText,
                        messageIndex: outIdx
                    )
                    let continuationEventID = await MainActor.run {
                        self.beginAutomaticOutputContinuation(
                            messageIndex: outIdx,
                            visibleText: checkpointVisibleText
                        )
                    }
                    if let nextInput = await self.automaticOutputContinuationInput(
                        history: promptHistory,
                        assistantMessageID: messageID,
                        partialAssistantText: baseAssistantText + continuation,
                        systemPrompt: turnSystemPrompt
                    ) {
                        self.registerContextOverflow(
                            strategy: self.contextOverflowStrategy,
                            details: ContextOverflowDetails(
                                promptTokens: nil,
                                contextTokens: Int(self.contextLimit.rounded()),
                                rawMessage: "post-tool-output-length-auto-continue"
                            )
                        )
                        await logger.log(
                            "[ContextContinue][Tool] finish_reason=length chars=\(continuation.count) mode=answer_checkpoint tools=off reasoning=off strategy=\(self.contextOverflowStrategy.rawValue)"
                        )
                        activeContinuationInput = self.applyingLoadedReasoningPreference(to: nextInput)
                        continuationPassStartCharacterCount = continuation.count
                        continuationPassMergedText = ""
                        continuationChunkMerger = StreamChunkMerger()
                        outputContinuationBoundaryFilter = OutputContinuationBoundaryFilter(
                            checkpoint: AssistantOutputSanitizer.strippingReasoningBlocks(
                                from: checkpointVisibleText
                            )
                        )
                        activeOutputContinuationEventID = continuationEventID
                        continue outputContinuationLoop
                    }
                    if let continuationEventID {
                        await MainActor.run {
                            self.resolveAutomaticOutputContinuation(
                                messageIndex: outIdx,
                                eventID: continuationEventID,
                                phase: .unavailable
                            )
                        }
                    }
                }
                if let eventID = activeOutputContinuationEventID {
                    await MainActor.run {
                        self.resolveAutomaticOutputContinuation(
                            messageIndex: outIdx,
                            eventID: eventID,
                            phase: .unavailable
                        )
                    }
                    activeOutputContinuationEventID = nil
                }
                break outputContinuationLoop
                }
                // Self-heal the seeded <think>: if the model produced a direct answer with no
                // reasoning close, drop the seed so the answer isn't trapped in a reasoning box
                // (falls back to exactly the pre-seed behavior — no regression).
                if seedContinuationThink,
                   continuation.hasPrefix("<think>"),
                   !continuation.contains("</think>") {
                    continuation.removeFirst("<think>".count)
                }
                // Trailing flush on successful completion: commit the final visible text
                // (the loop only checkpointed periodically) into both the store and sessions.
                await MainActor.run {
                    if self.streamMsgs.indices.contains(outIdx) {
                        let finalVisible = baseVisibleAssistantText + visibleAssistantText(from: continuation)
                        self.streamingStore.update(finalVisible)
                        self.streamMsgs[outIdx].text = finalVisible
                    }
                }
                // Capture the final reasoning state (rolling thoughts are now throttled to ~30 Hz).
                await self.handleRollingThoughts(
                    raw: baseVisibleAssistantText + visibleAssistantText(from: continuation),
                    messageIndex: outIdx
                )
            } catch {
                if activeOutputContinuationEventID != nil {
                    await MainActor.run {
                        self.resolvePreparingOutputContinuationsAsUnavailable(messageIndex: outIdx)
                    }
                    activeOutputContinuationEventID = nil
                }
                if Task.isCancelled || myID != self.activeRunID {
                    client.cancelActive()
                    return
                }
                let wasCancellation = (error as? CancellationError) != nil
                    || (error as? URLError)?.code == .cancelled
                let intentionalContinuationCancellation = wasCancellation &&
                    (didCancelContinuationForToolRestart || didCancelContinuationForToolResult)
                if intentionalContinuationCancellation {
                    await logger.log("[Tool][Continuation] Ignoring intentional cancellation during restart")
                }
                let lower = error.localizedDescription.lowercased()
                if self.loadedFormat == .et && (lower.contains("prefill aborted") || lower.contains("interrupted")) {
                    if prefillRetryAttempts < maxPrefillRetries {
                        let attempt = prefillRetryAttempts
                        prefillRetryAttempts += 1
                        let backoff = UInt64(250_000_000 * Int(pow(2.0, Double(attempt))))
                        await logger.log("[ChatVM] Prefill aborted. Retrying in \(backoff / 1_000_000)ms (attempt \(attempt + 1)/\(maxPrefillRetries)).")
                        try? await Task.sleep(nanoseconds: backoff)
                        continue continuationLoop
                    } else {
                        await logger.log("[ChatVM] Prefill aborted after \(maxPrefillRetries) retries. Failing.")
                    }
                }
                if !intentionalContinuationCancellation {
                    let overflow = self.parseContextOverflowDetails(from: error.localizedDescription)
                    if let overflow {
                        self.registerContextOverflow(strategy: self.contextOverflowStrategy, details: overflow)
                    }
                    let errorContext: UserFacingModelErrorContext = {
                        if let turnEscalation {
                            return turnEscalation.isLocalTarget ? .localModel : .remoteModel
                        }
                        return self.remoteService == nil ? .localModel : .remoteModel
                    }()
                    let displayedError = overflow != nil
                        ? self.contextFallbackMessage(for: self.contextOverflowStrategy)
                        : UserFacingErrorFormatter.message(for: error, context: errorContext)
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.clearPromptProcessing(for: outIdx)
                            // Commit the full partial continuation (the loop only checkpointed
                            // periodically) before appending the error.
                            self.streamMsgs[outIdx].text = baseVisibleAssistantText + visibleAssistantText(from: continuation) + "\n⚠️ " + displayedError
                            self.streamMsgs[outIdx].postToolWaiting = false
                        }
                    }
                } else {
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.clearPromptProcessing(for: outIdx)
                        }
                    }
                }
            }

            if nextToolJSON == nil {
                let combinedText = baseAssistantText + continuation
                if let result = await interceptEmbeddedToolCallIfPresent(
                    in: combinedText,
                    messageIndex: outIdx,
                    chatVM: self
                   ), let handled = result.token {
                    let nextJSON = handled
                        .replacingOccurrences(of: "TOOL_RESULT:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    nextToolJSON = nextJSON
                    let updatedText = result.cleanedText
                    pendingAssistantText = updatedText
                    let appendedPortion: String = {
                        if updatedText.count >= baseAssistantText.count {
                            let startIndex = updatedText.index(updatedText.startIndex, offsetBy: baseAssistantText.count)
                            return String(updatedText[startIndex...])
                        }
                        return updatedText
                    }()
                    continuation = appendedPortion

                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.streamingStore.update(visibleAssistantText(from: updatedText))
                            self.streamMsgs[outIdx].text = visibleAssistantText(from: updatedText)
                            if let toolName = self.streamMsgs[outIdx].toolCalls?.last?.toolName,
                               toolName == "noema.web.retrieve" {
                                self.streamMsgs[outIdx].usedWebSearch = true
                            }
                        }
                    }
                    await self.handleRollingThoughts(raw: updatedText, messageIndex: outIdx)
                }
                if nextToolJSON == nil {
                    await pruneDanglingPlaceholderToolCalls(
                        messageIndex: outIdx,
                        chatVM: self
                    )
                }
            }

            if self.loadedFormat == .et && continuation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && nextToolJSON == nil {
                if prefillRetryAttempts < maxPrefillRetries {
                    let attempt = prefillRetryAttempts
                    prefillRetryAttempts += 1
                    let backoff = UInt64(150_000_000 * Int(pow(2.0, Double(attempt))))
                    await logger.log("[ChatVM] Empty continuation. Retrying in \(backoff / 1_000_000)ms (attempt \(attempt + 1)/\(maxPrefillRetries)).")
                    try? await Task.sleep(nanoseconds: backoff)
                    continue continuationLoop
                }
            }

            let continuationOutcome: ToolContinuationOutcome = {
                if let json = nextToolJSON {
                    return .restartWithTool(resultJSON: json)
                }
                return .finishWithVisibleText(
                    resolvedFinalContinuationText ?? (baseAssistantText + continuation)
                )
            }()

            switch continuationOutcome {
            case .restartWithTool(let json):
                let toolMsg = ChatVM.Msg(role: "tool", text: json, timestamp: Date())
                localHistory.append(toolMsg)
                continue continuationLoop
            case .finishWithVisibleText(_):
                await MainActor.run {
                    if self.streamMsgs.indices.contains(outIdx) {
                        // Final text was already committed (success: end of stream `do`;
                        // error: in the catch). Just stop rendering the bubble from the store.
                        self.streamingStore.finish()
                        self.clearPromptProcessing(for: outIdx)
                        self.streamMsgs[outIdx].postToolWaiting = false
                    }
                }
                break continuationLoop
            }
        }

        let continuationOverhead = (self.injectionMethod == .full && self.currentInjectedTokenOverhead > 0) ? self.currentInjectedTokenOverhead : 0
        let finalPerf = await self.finalizePerf(messageID: messageID, injectionOverhead: continuationOverhead)
        await MainActor.run {
            if self.streamMsgs.indices.contains(outIdx) {
                self.streamMsgs[outIdx].streaming = false
                self.clearPromptProcessing(for: outIdx)
                self.streamMsgs[outIdx].postToolWaiting = false
                if let perf = finalPerf {
                    self.streamMsgs[outIdx].perf = perf
                }
#if os(iOS)
                if self.strictFinalAnswerText(for: self.streamMsgs[outIdx]) != nil {
                    Haptics.successLight()
                }
#endif
                AccessibilityAnnouncer.announceLocalized("Response generated.")
                self.assistantTurnEvents.send(.completed(messageID: self.streamMsgs[outIdx].id))
                self.recordPositiveTurnForReview(messageIndex: outIdx)
            }
        }
        self.markRollingThoughtsInterrupted(forMessageAt: outIdx)
    }

}



#endif
