import SwiftUI
import Combine
import NoemaPackages
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(UIKit) || os(macOS)
/// Renders a single message. Any text between `<think>` tags is wrapped in a
/// collapsible box with rounded corners.
struct MessageView: View {
    let msg: ChatVM.Msg
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var tabRouter: TabRouter
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedThinkIndices: Set<Int> = []
    @State private var showCopyPopup = false
    @State private var copiedMessage = false
    @State private var pinnedToScratchpad = false
    @State private var expandedImagePath: String? = nil
    @State private var showEvidenceSheet = false
    @State private var transcriptSaveFeedback: [ChatMediaAttachment.ID: TranscriptSaveFeedback] = [:]
    @State private var transcriptReviewAttachment: ChatMediaAttachment?
    @State private var existingDatasetSaveAttachment: ChatMediaAttachment?
#if os(macOS)
    @State private var hoverCopyVisible = false
    @State private var suppressHoverCopy = false
#endif
#if os(visionOS)
    @EnvironmentObject private var pinnedStore: VisionPinnedNoteStore
    @Environment(\.openWindow) private var openWindow
    @State private var hoverActive = false
    @State private var showInteractionOptions = false
    @GestureState private var isPressingMessage = false
#endif

    private struct PrivacyBadgeDescriptor {
        let title: LocalizedStringKey
        let accessibilityLabel: LocalizedStringKey
        let iconName: String
        let tint: Color
    }

    /// A bubble is safe to collapse into one VoiceOver element only when it is
    /// finished plain prose: no streaming, tool cards, code blocks, reasoning
    /// disclosures, in-flight loading UI, or markdown tables (those carry their
    /// own controls / structure and must stay individually navigable). Combining
    /// finished prose stops a multi-paragraph reply from exposing one element
    /// per paragraph, which is what let VoiceOver focus bounce between them.
    private var bubbleShouldCombineForAccessibility: Bool {
        guard !msg.streaming else { return false }
        if msg.toolCalls?.isEmpty == false { return false }
        if msg.shouldShowPromptProcessingCard { return false }
        if msg.shouldShowGenericLoadingIndicator { return false }
        if msg.postToolWaiting { return false }
        if msg.outputContinuationEvents?.isEmpty == false { return false }
        let t = msg.text
        if t.contains("```") { return false }
        if t.contains("<think>") { return false }
        // Markdown table separator row, e.g. "|---|---|".
        if t.contains("|-") || t.contains("| -") { return false }
        return true
    }

    private var datasetDisplayName: String? {
        if let stored = msg.datasetName, !stored.isEmpty { return stored }
        if let id = msg.datasetID,
           let ds = vm.datasetManager?.datasets.first(where: { $0.datasetID == id }) {
            return ds.name
        }
        return nil
    }

    private var retrievedContextChunks: [String] {
        (msg.retrievedContext ?? "")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var ragChunkCount: Int {
        // RAG surfaces the same retrieved chunks three ways: one citation per
        // chunk, the joined `retrievedContext` string, and the `ragInjectionInfo`
        // summary. They're the same evidence, so count them once — as the number
        // of chunks. (e.g. 2 chunks must read as 2, not 2 + 2 + 1 = 5.)
        msg.citations?.count ?? retrievedContextChunks.count
    }

    /// Chunks returned by on-demand dataset-search (`noema.rag.search`) tool calls. Each
    /// chunk is a citation, so the call is counted by its chunk count (like web search by its
    /// hits) rather than as a single tool call.
    private var datasetToolChunkCount: Int {
        (msg.toolCalls ?? []).reduce(0) { total, call in
            guard call.toolName == "noema.rag.search", let result = call.result,
                  let payload = ToolCallViewSupport.parseDatasetSearchResult(from: result) else { return total }
            return total + payload.citations.count
        }
    }

    private var evidenceItemCount: Int {
        var count = 0
        count += ragChunkCount
        count += datasetToolChunkCount
        // Web and dataset search are tool calls whose results are already counted (by their
        // hits / chunks). Counting the call itself would double-count, so exclude both; every
        // other tool call counts as one evidence point.
        count += msg.toolCalls?.filter { $0.toolName != "noema.web.retrieve" && $0.toolName != "noema.rag.search" }.count ?? 0
        count += msg.webHits?.count ?? 0
        count += msg.imagePaths?.count ?? 0
        count += msg.mediaAttachments?.count ?? 0
        return count
    }

    private var hasEvidenceReceipt: Bool {
        msg.role != "🧑‍💻" && evidenceItemCount > 0
    }

    private var privacyBadgeDescriptor: PrivacyBadgeDescriptor? {
        guard msg.role != "🧑‍💻" else { return nil }
        if msg.route?.answerTarget == .cloud {
            return PrivacyBadgeDescriptor(
                title: "Auto · Cloud",
                accessibilityLabel: "Autopilot Cloud Answer",
                iconName: "arrow.triangle.branch",
                tint: .purple
            )
        }
        // Like "Local Only" below, the expected local verdict is diagnostic
        // detail — Advanced mode only.
        if msg.route?.answerTarget == .local, isAdvancedMode {
            return PrivacyBadgeDescriptor(
                title: "Auto · Local",
                accessibilityLabel: "Autopilot Local Answer",
                iconName: "arrow.triangle.branch",
                tint: .green
            )
        }
        if msg.usedRemoteBackend == true {
            return PrivacyBadgeDescriptor(
                title: "Remote",
                accessibilityLabel: "Remote Answer",
                iconName: "antenna.radiowaves.left.and.right",
                tint: .purple
            )
        }
        if msg.ranOnPrivateCloudCompute == true {
            return PrivacyBadgeDescriptor(
                title: "Private Cloud",
                accessibilityLabel: "Answered with Apple Private Cloud Compute",
                iconName: "lock.icloud",
                tint: .indigo
            )
        }
        if msg.usedWebSearch == true || msg.webHits?.isEmpty == false {
            return PrivacyBadgeDescriptor(
                title: "Network",
                accessibilityLabel: "Network-Assisted Answer",
                iconName: "globe",
                tint: .blue
            )
        }
        // "Local Only" is the expected default for a local-first app, so it only
        // appears as a diagnostic detail — the toolbar status dot carries the
        // local/private signal in normal use.
        if msg.usedRemoteBackend == false, isAdvancedMode {
            return PrivacyBadgeDescriptor(
                title: "Local Only",
                accessibilityLabel: "Local-Only Answer",
                iconName: "lock.shield",
                tint: .green
            )
        }
        return nil
    }

    private var hasReceiptBadges: Bool {
        privacyBadgeDescriptor != nil
            || hasEvidenceReceipt
            || (isAdvancedMode && (shouldNudgeForMissingEvidence || shouldShowModelOnlyUncertainty))
    }

    private var isCompletedAssistantAnswer: Bool {
        (msg.role == "🤖" || msg.role.lowercased() == "assistant")
            && !msg.streaming
            && !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var expectedGroundingWithoutEvidence: Bool {
        guard isCompletedAssistantAnswer, evidenceItemCount == 0 else { return false }
        let trimmedText = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !msg.streaming else { return false }
        return msg.datasetID != nil
            || msg.datasetName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || msg.usedWebSearch == true
            || msg.webError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var shouldNudgeForMissingEvidence: Bool {
        canAuditMessage && expectedGroundingWithoutEvidence
    }

    private var shouldShowModelOnlyUncertainty: Bool {
        isCompletedAssistantAnswer && evidenceItemCount == 0 && !expectedGroundingWithoutEvidence
    }

    /// Memoized: the result depends only on the text and the tool-call count
    /// (pieces store indices into the calls array, not the calls themselves),
    /// verified against `parseUncached`'s body which reads nothing else.
    private static let parsedPiecesCache = TextComputationCache<[ChatVM.Piece]>()

    private func parse(
        _ text: String,
        toolCalls: [ChatVM.Msg.ToolCall]? = nil,
        outputContinuationEvents: [ChatVM.Msg.OutputContinuationEvent]? = nil
    ) -> [ChatVM.Piece] {
        let countTag = toolCalls.map { String($0.count) } ?? "-"
        let eventTag = outputContinuationEvents?.map {
            "\($0.id.uuidString):\($0.phase.rawValue):\($0.visibleCharacterOffset)"
        }.joined(separator: ",") ?? "-"
        return Self.parsedPiecesCache.value(for: "\(countTag)\u{1}\(eventTag)\u{1}\(text)") {
            parseUncached(
                text,
                toolCalls: toolCalls,
                outputContinuationEvents: outputContinuationEvents
            )
        }
    }

    private func parseUncached(
        _ text: String,
        toolCalls: [ChatVM.Msg.ToolCall]? = nil,
        outputContinuationEvents: [ChatVM.Msg.OutputContinuationEvent]? = nil
    ) -> [ChatVM.Piece] {
        let codeBlocks = splitOutputContinuationMarkers(
            in: ChatVM.parseCodeBlocks(text),
            events: outputContinuationEvents ?? []
        )

        // Then parse think tags within each text piece
        var finalPieces: [ChatVM.Piece] = []
        var toolCallIndex = 0 // Track which tool call we're currently processing

        for piece in codeBlocks {
            switch piece {
            case .code(let code, let lang):
                // Detect tool-call JSON/XML inside fenced code blocks and surface a tool placeholder instead
                var insertedToolFromCodeBlock = false
                let codeSub = code[...]
                var tmp = codeSub
                // 1) XML-style <tool_call> blocks inside code fences
                while let callTag = tmp.range(of: "<tool_call>") {
                    tmp = tmp[callTag.upperBound...]
                    if let end = tmp.range(of: "</tool_call>") {
                        tmp = tmp[end.upperBound...]
                    } else {
                        tmp = tmp[tmp.endIndex...]
                    }
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                    insertedToolFromCodeBlock = true
                }
                // 2) TOOL_CALL:/TOOL_RESULT markers inside code fences
                tmp = codeSub
                while let callRange = tmp.range(of: "TOOL_CALL:") {
                    tmp = tmp[callRange.upperBound...]
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                    insertedToolFromCodeBlock = true
                }
                // 3) Bare JSON tool-call object inside code fences
                tmp = codeSub
                var searchStart = tmp.startIndex
                scanJSONInCode: while let braceStart = tmp[searchStart...].firstIndex(of: "{") {
                    if let braceEnd = findMatchingBrace(in: tmp, startingFrom: braceStart) {
                        let candidate = tmp[braceStart...braceEnd]
                        if (candidate.contains("\"tool_name\"") || candidate.contains("\"name\"") || candidate.contains("\"tool\"")) &&
                            (candidate.contains("\"arguments\"") || candidate.contains("\"args\"")) {
                            finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                            if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                            insertedToolFromCodeBlock = true
                            // Continue after this JSON object in case of multiple
                            searchStart = tmp.index(after: braceEnd)
                            continue scanJSONInCode
                        }
                        searchStart = tmp.index(after: braceEnd)
                        continue scanJSONInCode
                    } else {
                        break scanJSONInCode
                    }
                }
                if !insertedToolFromCodeBlock {
                    finalPieces.append(ChatVM.Piece.code(code, language: lang))
                }
            case .text(let t):
                // Parse think tags in text
                var rest = t[...]
                // Emit a reasoning piece only when it carries text. An empty <think>
                // block must not consume a think-ordinal: render ordinals here are
                // keyed 1:1 against ChatVM.parseThinkBlocks (which owns the rolling-
                // thought view models). If the two indexings drift, a later block's
                // view model surfaces at the wrong slot and its text renders twice as
                // duplicate REASONING rows. Keeping both dense over non-empty blocks
                // keeps the keys aligned.
                func appendThinkPiece(_ content: String, done: Bool) {
                    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    finalPieces.append(ChatVM.Piece.think(content, done: done))
                }
                // Detect multiple inline tool_call blocks
                func appendTextWithThinks(_ segment: Substring) {
                    var tmp = segment
                    // Implicit-open reasoning: templates that pre-open <think> in the
                    // prompt (DeepSeek-R1, Qwen3 *-Thinking) stream only the reasoning
                    // body plus a lone </think>; synthesize the opening block here.
                    if let close = tmp.range(of: "</think>"),
                       tmp.range(of: "<think>").map({ close.lowerBound < $0.lowerBound }) ?? true {
                        let inner = String(tmp[..<close.lowerBound])
                            .replacingOccurrences(of: "<think>", with: "")
                            .replacingOccurrences(of: "</think>", with: "")
                        appendThinkPiece(inner, done: true)
                        tmp = tmp[close.upperBound...]
                    }
                    while let s = tmp.range(of: "<think>") {
                        if s.lowerBound > tmp.startIndex {
                            // Strip any stray closing tags in plain text
                            let beforeText = String(tmp[..<s.lowerBound]).replacingOccurrences(of: "</think>", with: "")
                            finalPieces.append(ChatVM.Piece.text(beforeText))
                        }
                        tmp = tmp[s.upperBound...]
                        if let e = tmp.range(of: "</think>") {
                            let inner = String(tmp[..<e.lowerBound])
                            // Sanitize nested or stray think markers inside the box content
                            let sanitizedInner = inner
                                .replacingOccurrences(of: "<think>", with: "")
                                .replacingOccurrences(of: "</think>", with: "")
                            appendThinkPiece(sanitizedInner, done: true)
                            tmp = tmp[e.upperBound...]
                        } else {
                            let partial = String(tmp)
                                .replacingOccurrences(of: "<think>", with: "")
                                .replacingOccurrences(of: "</think>", with: "")
                            appendThinkPiece(partial, done: false)
                            tmp = tmp[tmp.endIndex...]
                        }
                    }
                    if !tmp.isEmpty {
                        let trailingText = String(tmp).replacingOccurrences(of: "</think>", with: "")
                        finalPieces.append(ChatVM.Piece.text(trailingText))
                    }
                }
                while let anchorRange = rest.range(of: noemaToolAnchorToken) {
                    if anchorRange.lowerBound > rest.startIndex { appendTextWithThinks(rest[..<anchorRange.lowerBound]) }
                    rest = rest[anchorRange.upperBound...]
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                while let callTag = rest.range(of: "<tool_call>") {
                    if callTag.lowerBound > rest.startIndex { appendTextWithThinks(rest[..<callTag.lowerBound]) }
                    rest = rest[callTag.upperBound...]
                    if let end = rest.range(of: "</tool_call>") {
                        rest = rest[end.upperBound...]
                    } else {
                        rest = rest[rest.endIndex...]
                    }
                    // Use the current tool call index and increment for next one
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                // Detect multiple TOOL_CALL markers
                while let callRange = rest.range(of: "TOOL_CALL:") {
                    if callRange.lowerBound > rest.startIndex { appendTextWithThinks(rest[..<callRange.lowerBound]) }
                    var after = rest[callRange.upperBound...]
                    if let nextResp = (after.range(of: "<tool_response>") ?? after.range(of: "TOOL_RESULT:")) {
                        rest = after[nextResp.lowerBound...]
                    } else if let nl = after.firstIndex(of: "\n") {
                        rest = after[nl...]
                    } else {
                        rest = rest[rest.endIndex...]
                    }
                    // Use the current tool call index and increment for next one
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }

                // Detect bare JSON tool call objects and hide them inline
                // Looks for a JSON object containing either "tool_name" or legacy "name" along with "arguments"
                var searchStart = rest.startIndex
                scanJSON: while let braceStart = rest[searchStart...].firstIndex(of: "{") {
                    let maybeEnd = findMatchingBrace(in: rest, startingFrom: braceStart)
                    if let braceEnd = maybeEnd {
                        let candidate = rest[braceStart...braceEnd]
                        if (candidate.contains("\"tool_name\"") || candidate.contains("\"name\"")) && candidate.contains("\"arguments\"") {
                            // Emit text before the JSON block
                            if braceStart > rest.startIndex { appendTextWithThinks(rest[..<braceStart]) }
                            // Skip over the JSON block and insert a tool box placeholder
                            let afterEnd = rest.index(after: braceEnd)
                            rest = rest[afterEnd...]
                            finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                            if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                                toolCallIndex += 1
                            }
                            // Restart search at beginning of updated remainder
                            searchStart = rest.startIndex
                            continue scanJSON
                        }
                    } else {
                        // Incomplete JSON; if it looks like a tool call, show placeholder and hide the partial content
                        let hasNameKey = rest.range(of: "\"name\"")
                        let hasToolNameKey = rest.range(of: "\"tool_name\"")
                        let hasArgsKey = rest.range(of: "\"arguments\"")
                        if (hasNameKey != nil || hasToolNameKey != nil), let argsRange = hasArgsKey {
                            if (hasNameKey?.lowerBound ?? braceStart) >= braceStart || argsRange.lowerBound >= braceStart {
                                if braceStart > rest.startIndex { appendTextWithThinks(rest[..<braceStart]) }
                                rest = rest[rest.endIndex...]
                                finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                                if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                                    toolCallIndex += 1
                                }
                                break scanJSON
                            }
                        }
                        // Continue searching after this opening brace
                        searchStart = rest.index(after: braceStart)
                        continue scanJSON
                    }
                    // Continue searching after this opening brace if not matched
                    searchStart = rest.index(after: braceStart)
                }
                // Hide multiple tool_response blocks
                toolLoop: while let toolRange = rest.range(of: "<tool_response>") ?? rest.range(of: "TOOL_RESULT:") {
                    if toolRange.lowerBound > rest.startIndex { appendTextWithThinks(rest[..<toolRange.lowerBound]) }

                    let markerSlice = rest[toolRange]
                    var remainder = rest[toolRange.upperBound...]
                    var consumedPayload = false

                    if markerSlice.hasPrefix("<tool_response>") {
                        if let end = remainder.range(of: "</tool_response>") {
                            remainder = remainder[end.upperBound...]
                            consumedPayload = true
                        }
                    } else {
                        // TOOL_RESULT payload can be a JSON object or array; skip entire structure
                        var idx = remainder.startIndex
                        while idx < remainder.endIndex && remainder[idx].isWhitespace {
                            idx = remainder.index(after: idx)
                        }
                        if idx < remainder.endIndex {
                            if remainder[idx] == "[" {
                                if let close = findMatchingBracket(in: remainder, startingFrom: idx) {
                                    remainder = remainder[remainder.index(after: close)...]
                                    consumedPayload = true
                                }
                            } else if remainder[idx] == "{" {
                                if let close = findMatchingBrace(in: remainder, startingFrom: idx) {
                                    remainder = remainder[remainder.index(after: close)...]
                                    consumedPayload = true
                                }
                            } else {
                                if let newline = remainder[idx...].firstIndex(of: "\n") {
                                    remainder = remainder[newline...]
                                } else {
                                    remainder = remainder[remainder.endIndex...]
                                }
                                consumedPayload = true
                            }
                        } else {
                            remainder = remainder[idx...]
                            consumedPayload = true
                        }
                    }
                    // Tool response doesn't increment the index since it's for the same tool call
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    rest = remainder
                    if !consumedPayload { break toolLoop }
                }
                // Implicit-open reasoning: templates that pre-open <think> in the prompt
                // (DeepSeek-R1, Qwen3 *-Thinking) stream only the reasoning body plus a
                // lone </think>; synthesize the opening block before scanning the rest.
                if let close = rest.range(of: "</think>"),
                   rest.range(of: "<think>").map({ close.lowerBound < $0.lowerBound }) ?? true {
                    let inner = String(rest[..<close.lowerBound])
                        .replacingOccurrences(of: "<think>", with: "")
                        .replacingOccurrences(of: "</think>", with: "")
                    appendThinkPiece(inner, done: true)
                    rest = rest[close.upperBound...]
                }
                // Preserve all think blocks (and sanitize inner content)
                while let s = rest.range(of: "<think>") {
                    if s.lowerBound > rest.startIndex {
                        let before = String(rest[..<s.lowerBound]).replacingOccurrences(of: "</think>", with: "")
                        finalPieces.append(ChatVM.Piece.text(before))
                    }

                    rest = rest[s.upperBound...]
                    if let e = rest.range(of: "</think>") {
                        let inner = String(rest[..<e.lowerBound])
                            .replacingOccurrences(of: "<think>", with: "")
                            .replacingOccurrences(of: "</think>", with: "")
                        appendThinkPiece(inner, done: true)
                        rest = rest[e.upperBound...]
                    } else {
                        let partial = String(rest)
                            .replacingOccurrences(of: "<think>", with: "")
                            .replacingOccurrences(of: "</think>", with: "")
                        appendThinkPiece(partial, done: false)
                        rest = rest[rest.endIndex...]
                    }
                }
                if !rest.isEmpty {
                    let tail = String(rest).replacingOccurrences(of: "</think>", with: "")
                    finalPieces.append(ChatVM.Piece.text(tail))
                }
            case .think:
                // This shouldn't happen from parseCodeBlocks
                finalPieces.append(piece)
            case .tool(_):
                // Render-time handled via ToolCallView; skip here
                break
            case .outputContinuation:
                finalPieces.append(piece)
            }
        }

        return finalPieces
    }

    private func outputContinuationMarker(
        for event: ChatVM.Msg.OutputContinuationEvent
    ) -> String {
        "\u{F8FF}NOEMA-CONTINUE-\(event.id.uuidString)-\(event.phase.rawValue)\u{F8FE}"
    }

    private func insertingOutputContinuationMarkers(
        into text: String,
        events: [ChatVM.Msg.OutputContinuationEvent]
    ) -> String {
        var marked = text
        let ordered = events.sorted {
            if $0.visibleCharacterOffset == $1.visibleCharacterOffset {
                return $0.startedAt > $1.startedAt
            }
            return $0.visibleCharacterOffset > $1.visibleCharacterOffset
        }
        for event in ordered {
            let clampedOffset = min(max(0, event.visibleCharacterOffset), marked.count)
            let index = marked.index(marked.startIndex, offsetBy: clampedOffset)
            // Keep the marker on its own line so a seam immediately after a
            // fenced code block cannot be swallowed as part of the closing ```.
            marked.insert(
                contentsOf: "\n" + outputContinuationMarker(for: event) + "\n",
                at: index
            )
        }
        return marked
    }

    private func splitOutputContinuationMarkers(
        in pieces: [ChatVM.Piece],
        events: [ChatVM.Msg.OutputContinuationEvent]
    ) -> [ChatVM.Piece] {
        guard !events.isEmpty else { return pieces }
        let markers = events.map { (marker: outputContinuationMarker(for: $0), event: $0) }

        func split(
            _ payload: String,
            makePiece: (String) -> ChatVM.Piece
        ) -> [ChatVM.Piece] {
            var result: [ChatVM.Piece] = []
            var remaining = payload[...]
            while !remaining.isEmpty {
                let next = markers.compactMap { entry -> (Range<Substring.Index>, ChatVM.Msg.OutputContinuationEvent)? in
                    guard let range = remaining.range(of: entry.marker) else { return nil }
                    return (range, entry.event)
                }.min { $0.0.lowerBound < $1.0.lowerBound }

                guard let next else {
                    result.append(makePiece(String(remaining)))
                    break
                }
                if next.0.lowerBound > remaining.startIndex {
                    result.append(makePiece(String(remaining[..<next.0.lowerBound])))
                }
                result.append(.outputContinuation(next.1))
                remaining = remaining[next.0.upperBound...]
            }
            return result
        }

        return pieces.flatMap { piece in
            switch piece {
            case .text(let text):
                return split(text, makePiece: ChatVM.Piece.text)
            case .code(let code, let language):
                return split(code) { ChatVM.Piece.code($0, language: language) }
            case .think, .tool, .outputContinuation:
                return [piece]
            }
        }
    }


    // MARK: - Text or List rendering

    /// Cached output of the line-parsing + render-planning passes; pure
    /// function of the raw text, so safe to memoize across re-renders.
    private struct TextRenderPlan {
        let entries: [TextLineEntry]
        let units: [ChatMarkdownRenderUnit]
    }

    private static let renderPlanCache = TextComputationCache<TextRenderPlan>()

    private func renderPlan(for t: String) -> TextRenderPlan {
        Self.renderPlanCache.value(for: t) {
            let text = normalizeListFormatting(t)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return TextRenderPlan(entries: [], units: [])
            }
            let entries = parseTextEntries(from: text)
            let plannerEntries = entries.map { entry in
                switch entry {
                case .blank:
                    return ChatMarkdownPlannerEntry.blank
                case .thematicBreak:
                    return .thematicBreak
                case .heading(let level, let content):
                    return .heading(level: level, content: content)
                case .bullet(let marker, let content):
                    return .bullet(marker: marker, content: content)
                case .mathBlock(let source):
                    return .mathBlock(source)
                case .table:
                    return .table
                case .text(let line):
                    return .text(line)
                }
            }
#if os(macOS)
            let units = ChatMarkdownRenderPlanner.renderUnits(for: plannerEntries, isMacOS: true)
#else
            let units = ChatMarkdownRenderPlanner.renderUnits(for: plannerEntries, isMacOS: false)
#endif
            return TextRenderPlan(entries: entries, units: units)
        }
    }

    @ViewBuilder
    private func renderTextOrList(_ t: String) -> some View {
        // Enhanced rendering:
        // - Headings: lines starting with "# ", "## ", "### ", etc. get larger fonts
        // - Bullets: single-character markers ('-', '*', '+', '•') render with a leading dot
        // - Math/text runs are grouped into larger MathRichText blocks for smoother selection
        let plan = renderPlan(for: t)
        if plan.units.isEmpty {
            EmptyView()
        } else {
            let entries = plan.entries
            let units = plan.units
            let chatBlockMathStyle = BlockMathStyle.chat(bodyFontSize: preferredFontSize(.body))

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                    switch unit {
                    case .bulletBlock(let block):
                        MathRichText(source: block, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                            .font(chatBodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .textMathBlock(let block):
                        MathRichText(source: block, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                            .font(chatBodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .entryIndex(let idx):
                        switch entries[idx] {
                        case .blank:
                            Text("")
                        case .thematicBreak:
                            Divider()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        case .heading(let level, let content):
                            MathRichText(source: content, bodyFont: headingFont(for: level), bodyPointSize: headingPointSize(for: level), bodyWeight: .bold, blockMathStyle: chatBlockMathStyle)
                                .font(headingFont(for: level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .mathBlock(let source):
                            MathRichText(source: source, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                                .font(chatBodyFont)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .table(let headers, let alignments, let rows):
                            tableView(headers: headers, alignments: alignments, rows: rows)
                        case .text(let line):
                            MathRichText(source: line, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                                .font(chatBodyFont)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .bullet:
                            // Should not appear as individual entries because bullets are grouped.
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    private enum TextLineEntry {
        case blank
        case thematicBreak
        case heading(level: Int, content: String)
        case bullet(marker: String, content: String)
        case mathBlock(String)
        case table(headers: [String], alignments: [TableColumnAlignment], rows: [[String]])
        case text(String)
    }

    private enum TextBlockDelimiter {
        case doubleDollar
        case bracket
    }

    private enum TableColumnAlignment {
        case leading
        case center
        case trailing

        var gridAlignment: Alignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }

        var frameAlignment: Alignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }

        var textAlignment: TextAlignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
    }

    private func parseTextEntries(from text: String) -> [TextLineEntry] {
        func startDelimiter(for trimmed: String) -> TextBlockDelimiter? {
            switch trimmed {
            case "$$": return .doubleDollar
            case "\\[": return .bracket
            default: return nil
            }
        }

        func closes(_ trimmed: String, matching delimiter: TextBlockDelimiter) -> Bool {
            switch delimiter {
            case .doubleDollar: return trimmed == "$$"
            case .bracket: return trimmed == "\\]"
            }
        }

        let lines = text.components(separatedBy: .newlines)
        var entries: [TextLineEntry] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                entries.append(.blank)
                index += 1
                continue
            }

            if let table = parseTableBlock(startingAt: index, in: lines) {
                entries.append(.table(headers: table.headers, alignments: table.alignments, rows: table.rows))
                index += table.consumed
                continue
            }

            if let delimiter = startDelimiter(for: trimmed) {
                var blockLines: [String] = [line]
                var cursor = index + 1
                while cursor < lines.count {
                    let nextLine = lines[cursor]
                    blockLines.append(nextLine)
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if closes(nextTrimmed, matching: delimiter) {
                        cursor += 1
                        break
                    }
                    cursor += 1
                }
                entries.append(.mathBlock(blockLines.joined(separator: "\n")))
                index = cursor
                continue
            }

            if isThematicBreakLine(trimmed) {
                entries.append(.thematicBreak)
                index += 1
                continue
            }

            if let level = headingLevel(for: trimmed) {
                let content = String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
                entries.append(.heading(level: level, content: content))
                index += 1
                continue
            }

            if let (marker, content) = parseBulletLine(line) {
                entries.append(.bullet(marker: marker, content: content))
                index += 1
                continue
            }

            entries.append(.text(line))
            index += 1
        }

        return entries
    }

    private func isThematicBreakLine(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first else { return false }
        guard first == "-" || first == "_" || first == "*" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    @ViewBuilder
    private func tableView(headers: [String], alignments: [TableColumnAlignment], rows: [[String]]) -> some View {
        let columns: [GridItem] = alignments.map { alignment in
            GridItem(.flexible(), spacing: 12, alignment: alignment.gridAlignment)
        }
        let chatBlockMathStyle = BlockMathStyle.chat(bodyFontSize: preferredFontSize(.body))

        VStack(spacing: 0) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    MathRichText(source: header, bodyFont: tableHeaderFont, bodyPointSize: 15, bodyWeight: .semibold, blockMathStyle: chatBlockMathStyle)
                        .font(tableHeaderFont)
                        .multilineTextAlignment(alignments[index].textAlignment)
                        .frame(maxWidth: .infinity, alignment: alignments[index].frameAlignment)
                }
            }
            .padding(.bottom, rows.isEmpty ? 0 : 10)

            if !rows.isEmpty {
                Divider()
                    .padding(.bottom, 10)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, value in
                        MathRichText(source: value, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                            .font(chatBodyFont)
                            .multilineTextAlignment(alignments[columnIndex].textAlignment)
                            .frame(maxWidth: .infinity, alignment: alignments[columnIndex].frameAlignment)
                    }
                }
                if rowIndex < rows.count - 1 {
                    Divider()
                        .padding(.vertical, 10)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tableBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tableBorderColor, lineWidth: 0.5)
        )
    }

    private func parseTableBlock(startingAt startIndex: Int, in lines: [String]) -> (consumed: Int, headers: [String], alignments: [TableColumnAlignment], rows: [[String]])? {
        guard let headerCells = parseTableRow(lines[startIndex]) else { return nil }
        let separatorIndex = startIndex + 1
        guard separatorIndex < lines.count,
              let alignments = parseTableAlignments(lines[separatorIndex], expectedCount: headerCells.count) else {
            return nil
        }

        var rows: [[String]] = []
        var cursor = separatorIndex + 1

        while cursor < lines.count {
            let candidate = lines[cursor]
            if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            guard let cells = parseTableRow(candidate), cells.count == headerCells.count else {
                break
            }
            rows.append(cells)
            cursor += 1
        }

        let consumed = 1 + 1 + rows.count
        return (consumed, headerCells, alignments, rows)
    }

    private func parseTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var segments = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { segment in
            segment.trimmingCharacters(in: .whitespaces)
        }

        if let first = segments.first, first.isEmpty { segments.removeFirst() }
        if let last = segments.last, last.isEmpty { segments.removeLast() }

        guard segments.count >= 2 else { return nil }

        // Require at least one non-empty column so we don't treat inline pipes as tables
        guard segments.contains(where: { !$0.isEmpty }) else { return nil }

        return segments
    }

    private func parseTableAlignments(_ line: String, expectedCount: Int) -> [TableColumnAlignment]? {
        guard let rawColumns = parseTableRow(line), rawColumns.count == expectedCount else { return nil }

        var alignments: [TableColumnAlignment] = []
        for column in rawColumns {
            let trimmed = column.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("-") else { return nil }

            let leadingColon = trimmed.hasPrefix(":")
            let trailingColon = trimmed.hasSuffix(":")
            let dashPortion = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashPortion.isEmpty, dashPortion.allSatisfy({ $0 == "-" }) else { return nil }

            let alignment: TableColumnAlignment
            if leadingColon && trailingColon {
                alignment = .center
            } else if trailingColon {
                alignment = .trailing
            } else {
                alignment = .leading
            }
            alignments.append(alignment)
        }

        return alignments
    }

    private func headingLevel(for line: String) -> Int? {
        // Recognize ATX-style headings: '#', '##', '###', up to 6
        guard line.first == "#" else { return nil }
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        // Must have a space after hashes to be a heading
        if count >= 1 && count <= 6 {
            let idx = line.index(line.startIndex, offsetBy: count)
            if idx < line.endIndex && line[idx].isWhitespace { return count }
        }
        return nil
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .largeTitle
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }

    /// Point size matching `headingFont(for:)`, plumbed to the macOS renderer.
    private func headingPointSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return preferredFontSize(.largeTitle)
        case 2: return preferredFontSize(.title2)
        case 3: return preferredFontSize(.title3)
        default: return preferredFontSize(.headline)
        }
    }

    // Normalizes inline lists like " ...  1. Item  2. Item ..." to place each
    // item on its own line. Our rich text engine preserves paragraph breaks
    // only for double newlines, so we emit "\n\n" here.
    private func normalizeListFormatting(_ text: String) -> String {
        var s = text
        func replace(_ pattern: String, _ template: String) {
            if let rx = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = rx.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
            }
        }
        // Insert paragraph break before inline numbered items like "  2.", "  3)" or "  4]".
        // After ":"/";" the marker must be whitespace-separated, otherwise ratios
        // ("1:2. Then") and emphasis closers ("*Checks:*") get torn apart.
        replace(#"(?:(?<=^)|(?<=\n))\s*(?=\d{1,3}[\.\)\]]\s)"#, "\n\n")
        replace(#"(?<=[:;])\s+(?=\d{1,3}[\.\)\]]\s)"#, "\n\n")
        // Insert paragraph break before inline bullet markers like " - ", " * ", " + ", or " • "
        replace(#"(?:(?<=^)|(?<=\n))\s*(?=[\-\*\+•]\s)"#, "\n\n")
        replace(#"(?<=[:;])\s+(?=[\-\*\+•]\s)"#, "\n\n")
        // Ensure a single newline before a list marker becomes a paragraph break
        replace(#"\n(?=\s*(?:\d{1,3}[\.\)\]]\s|[\-\*\+•]\s))"#, "\n\n")
        // If a list follows a colon, break the line after the colon
        replace(#":\s+(?=(?:\d{1,3}[\.\)\]]\s|[\-\*\+•]\s))"#, ":\n\n")
        // Collapse any 3+ consecutive newlines into a double newline
        replace(#"\n{3,}"#, "\n\n")
        return s
    }

    // MARK: - List parsing helpers
    private struct TextBlock {
        let content: String
        let isList: Bool
        let marker: String?
    }

    private func parseTextBlocks(_ text: String) -> [TextBlock] {
        var blocks: [TextBlock] = []
        let lines = text.components(separatedBy: .newlines)
        var currentTextBlock = ""

        for line in lines {
            if let (marker, content) = parseBulletLine(line) {
                if !currentTextBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(TextBlock(content: currentTextBlock, isList: false, marker: nil))
                    currentTextBlock = ""
                }
                blocks.append(TextBlock(content: content, isList: true, marker: marker))
            } else {
                currentTextBlock += (currentTextBlock.isEmpty ? "" : "\n") + line
            }
        }

        if !currentTextBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(TextBlock(content: currentTextBlock, isList: false, marker: nil))
        }

        return blocks
    }

    private func parseListItems(_ text: String) -> [(marker: String, content: String)] {
        var items: [(String, String)] = []
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            if let item = parseBulletLine(line) {
                items.append(item)
            }
        }

        return items
    }

    private func parseBulletLine(_ line: String) -> (marker: String, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Unordered bullets: -, *, +, •
        if trimmed.hasPrefix("- ") { return ("•", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("* ") { return ("•", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("+ ") { return ("•", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("• ") { return ("•", String(trimmed.dropFirst(2))) }

        // Ordered bullets: 1. 2) 3]
        if let dotIdx = trimmed.firstIndex(of: "."), dotIdx > trimmed.startIndex {
            let prefix = String(trimmed[..<dotIdx])
            if Int(prefix) != nil, trimmed[dotIdx...].hasPrefix(". ") {
                return (prefix + ".", String(trimmed[trimmed.index(dotIdx, offsetBy: 2)...]))
            }
        }
        if let parenIdx = trimmed.firstIndex(of: ")"), parenIdx > trimmed.startIndex {
            let prefix = String(trimmed[..<parenIdx])
            if Int(prefix) != nil, trimmed[parenIdx...].hasPrefix(") ") {
                return (prefix + ")", String(trimmed[trimmed.index(parenIdx, offsetBy: 2)...]))
            }
        }
        if let bracketIdx = trimmed.firstIndex(of: "]"), bracketIdx > trimmed.startIndex {
            let prefix = String(trimmed[..<bracketIdx])
            if Int(prefix) != nil, trimmed[bracketIdx...].hasPrefix("] ") {
                return (prefix + "]", String(trimmed[trimmed.index(bracketIdx, offsetBy: 2)...]))
            }
        }

        return nil
    }

    private func extractRemainingText(from text: String, afterListItems items: [(String, String)]) -> String {
        var remaining = ""
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            if parseBulletLine(line) == nil {
                remaining += (remaining.isEmpty ? "" : "\n") + line
            }
        }

        return remaining
    }

    @AppStorage("isAdvancedMode") private var isAdvancedMode = false
    @AppStorage("showGenerationDiagnostics") private var showGenerationDiagnostics = true
    @AppStorage("showRawAssistantOutput") private var showRawAssistantOutput = false

    private var isAssistantMessage: Bool {
        msg.role == "🤖" || msg.role.lowercased() == "assistant"
    }

    /// When "Show Raw Output" is on, an assistant bubble renders the model's
    /// complete raw transcript — literal markdown, `<think>` reasoning, code
    /// fences, AND every tool call (arguments + result/error) serialized in
    /// place — instead of the parsed/formatted pieces. Shown whenever there is
    /// any text or any tool call; user bubbles are unaffected.
    private var shouldRenderRawOutput: Bool {
        guard showRawAssistantOutput, isAssistantMessage else { return false }
        let hasText = !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || (msg.toolCalls?.isEmpty == false)
    }

    @ViewBuilder
    private func rawOutputView(pieces: [ChatVM.Piece]) -> some View {
        Text(rawTranscript(from: pieces))
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Full raw transcript for an assistant message: literal text / reasoning /
    /// code in order, with each tool call serialized where it occurred. Tool
    /// calls that carried no inline marker in the text are appended so a
    /// round-trip is never silently dropped.
    private func rawTranscript(from pieces: [ChatVM.Piece]) -> String {
        var blocks: [String] = []
        var renderedToolIDs = Set<UUID>()
        let toolCalls = msg.toolCalls ?? []

        for piece in pieces {
            switch piece {
            case .text(let t):
                let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { blocks.append(s) }
            case .think(let t, _):
                let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { blocks.append("<think>\n\(s)\n</think>") }
            case .code(let code, let language):
                blocks.append("```\(language ?? "")\n\(code)\n```")
            case .tool(let index):
                guard toolCalls.indices.contains(index) else { continue }
                let call = displayedToolCall(toolCalls[index])
                guard renderedToolIDs.insert(call.id).inserted else { continue }
                blocks.append(rawToolCallText(call))
            case .outputContinuation:
                continue
            }
        }

        // Out-of-band tool calls (no inline marker in the text) — append so the
        // raw view shows every round-trip, matching piecesView's fallback.
        for original in toolCalls {
            let call = displayedToolCall(original)
            guard renderedToolIDs.insert(call.id).inserted else { continue }
            blocks.append(rawToolCallText(call))
        }

        return blocks.joined(separator: "\n\n")
    }

    /// Serializes one tool call as a raw, protocol-style block: the request as
    /// `<tool_call>{name, arguments}</tool_call>`, then its raw result / error.
    private func rawToolCallText(_ call: ChatVM.Msg.ToolCall) -> String {
        let rawArgs = call.requestParams.mapValues { $0.value }
        let argsJSON: String
        if !rawArgs.isEmpty,
           JSONSerialization.isValidJSONObject(rawArgs),
           let data = try? JSONSerialization.data(withJSONObject: rawArgs, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            argsJSON = json
        } else {
            argsJSON = "{}"
        }

        var out = "<tool_call>\n{\"name\": \"\(call.toolName)\", \"arguments\": \(argsJSON)}\n</tool_call>"
        if let result = call.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "\n<tool_result>\n\(result)\n</tool_result>"
        }
        if let error = call.error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "\n<tool_error>\n\(error)\n</tool_error>"
        }
        return out
    }

    // MARK: - Code block rendering
    private struct CodeBlockView: View {
        let code: String
        let language: String?
        @State private var copied = false

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if let lang = language, !lang.isEmpty {
                        Text(lang)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
#if os(iOS)
                        UIPasteboard.general.string = code
#elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
#endif
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                            Text(copied ? "Copied!" : "Copy")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
#if os(macOS)
                        .textSelection(.enabled)
#endif
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(.systemGray6))
                .adaptiveCornerRadius(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .background(Color(.systemGray5))
            .adaptiveCornerRadius(.medium)
            .overlay(
                RoundedRectangle(cornerRadius: UIConstants.cornerRadius)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
            )
        }
    }

    // Helper to find matching closing brace for a JSON object, honoring strings and escapes
    private func findMatchingBrace(in text: Substring, startingFrom startIndex: Substring.Index) -> Substring.Index? {
        guard text[startIndex] == "{" else { return nil }
        var braceCount = 0
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
                if char == "{" { braceCount += 1 }
                else if char == "}" {
                    braceCount -= 1
                    if braceCount == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    // Helper to find matching closing bracket for a JSON array, honoring strings and escapes
    private func findMatchingBracket(in text: Substring, startingFrom startIndex: Substring.Index) -> Substring.Index? {
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
                if char == "[" { depth += 1 }
                else if char == "]" {
                    depth -= 1
                    if depth == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private var chatBodyFont: Font {
#if os(macOS)
        return .system(size: 16, weight: .regular)
#else
        return .body
#endif
    }

    /// Point size matching `chatBodyFont`, plumbed to the macOS AppKit renderer.
    private var chatBodyPointSize: CGFloat {
#if os(macOS)
        return 16
#else
        return preferredFontSize(.body)
#endif
    }

    private var tableHeaderFont: Font {
#if os(macOS)
        return .system(size: 15, weight: .semibold)
#else
        return .system(size: 15, weight: .semibold)
#endif
    }

    private var tableBackgroundColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.06)
        }
        return Color.primary.opacity(0.05)
    }

    private var tableBorderColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.2 : 0.08)
    }

    private var isUserMessage: Bool {
        msg.role == "🧑‍💻"
    }

    private var messageHorizontalPadding: CGFloat {
        isUserMessage ? 12 : 0
    }

    private var messageVerticalPadding: CGFloat {
        isUserMessage ? 12 : 6
    }

    var bubbleColor: Color {
        if isUserMessage {
            return ChatTheme.userBubble(colorScheme)
        }
        return .clear
    }

    @ViewBuilder
    private func imagesView(paths: [String]) -> some View {
        let thumbSize = CGSize(width: 96, height: 96)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(paths.prefix(5).enumerated()), id: \.offset) { _, p in
                    let img = ImageThumbnailCache.shared.thumbnail(for: p, pointSize: thumbSize)
                    ZStack {
                        if let ui = img {
                            Image(platformImage: ui)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.15))
                                .overlay(ProgressView().scaleEffect(0.6))
                        }
                    }
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .clipped()
                    .cornerRadius(12)
                    .drawingGroup(opaque: false)
                    .contentShape(Rectangle())
                    .onTapGesture { expandedImagePath = p }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func mediaAttachmentsView(_ attachments: [ChatMediaAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                mediaAttachmentCard(attachment)
            }
        }
        .padding(.horizontal, 12)
    }

    private func mediaAttachmentCard(_ attachment: ChatMediaAttachment) -> some View {
        let saveFeedback = transcriptSaveFeedback[attachment.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: attachment.kind.iconName)
                    .foregroundStyle(Color.accentColor)
                Text(attachment.transcript?.displaySourceName ?? attachment.originalFilename)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if attachment.hasCompletedTranscript {
                    Button {
                        transcriptReviewAttachment = attachment
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help(Text("Review Transcript"))

                    Menu {
                        Button {
                            saveTranscriptAttachment(attachment)
                        } label: {
                            Label(LocalizedStringKey("Save to Stored"), systemImage: "tray.and.arrow.down")
                        }
                        Button {
                            existingDatasetSaveAttachment = attachment
                        } label: {
                            Label(LocalizedStringKey("Save to existing dataset"), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        if saveFeedback?.isSaving == true {
                            ProgressView()
                                .scaleEffect(0.72)
                        } else {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .disabled(saveFeedback?.isSaving == true || saveFeedback?.isSaved == true)
                    .help(Text("Save transcript to Stored"))
                }
            }

            if let mediaDetailLabel = attachment.mediaDetailLabel {
                Text(mediaDetailLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let transcript = attachment.transcript {
                Text(transcript.provenanceSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                Text(transcript.exportText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            } else if let error = attachment.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }

            if let saveFeedback, let message = saveFeedback.message {
                Text(message)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(saveFeedback.isSaved ? Color.green : (saveFeedback.isSaving ? Color.secondary : Color.red))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func saveTranscriptAttachment(_ attachment: ChatMediaAttachment) {
        guard transcriptSaveFeedback[attachment.id]?.isSaving != true else { return }
        transcriptSaveFeedback[attachment.id] = .saving
        Task {
            let result = await vm.saveTranscriptAttachmentAsDataset(attachment)
            await MainActor.run {
                switch result {
                case .success(let dataset):
                    transcriptSaveFeedback[attachment.id] = .saved(dataset.name)
                case .failure(let error):
                    transcriptSaveFeedback[attachment.id] = .failed(
                        String.localizedStringWithFormat(
                            String(localized: "Transcript save failed: %@"),
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private func saveTranscriptAttachment(_ attachment: ChatMediaAttachment, toExistingDataset dataset: LocalDataset) {
        guard transcriptSaveFeedback[attachment.id]?.isSaving != true else { return }
        transcriptSaveFeedback[attachment.id] = .saving
        Task {
            let result = await vm.saveTranscriptAttachment(attachment, toExistingDataset: dataset)
            await MainActor.run {
                switch result {
                case .success(let dataset):
                    transcriptSaveFeedback[attachment.id] = .saved(dataset.name)
                case .failure(let error):
                    transcriptSaveFeedback[attachment.id] = .failed(
                        String.localizedStringWithFormat(
                            String(localized: "Transcript save failed: %@"),
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private struct AttachmentPreview: View {
        let path: String
        let onClose: () -> Void
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.95).ignoresSafeArea()
#if canImport(UIKit)
                if let ui = UIImage(contentsOfFile: path) {
                    Image(platformImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                        .background(Color.black.opacity(0.001).ignoresSafeArea())
                } else {
                    Text("Unable to load image").foregroundColor(.white)
                }
#else
                if let ns = NSImage(contentsOfFile: path) {
                    Image(nsImage: ns)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                        .background(Color.black.opacity(0.001).ignoresSafeArea())
                } else {
                    Text("Unable to load image").foregroundColor(.white)
                }
#endif
                HStack {
                    Spacer()
                    Button(action: { onClose(); dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onClose(); dismiss() }
        }
    }

    private func displayedToolCall(_ call: ChatVM.Msg.ToolCall) -> ChatVM.Msg.ToolCall {
        guard call.toolName == "noema.web.retrieve" else { return call }

        if let err = msg.webError {
            return ChatVM.Msg.ToolCall(
                id: call.id,
                toolName: call.toolName,
                displayName: call.displayName,
                iconName: call.iconName,
                requestParams: call.requestParams,
                phase: .failed,
                externalToolCallID: call.externalToolCallID,
                result: call.result,
                error: err,
                timestamp: call.timestamp,
                completedAt: call.completedAt
            )
        }

        // Preserve the executor's original result. Rich web retrieval returns a
        // versioned envelope containing signed references, fetch status, and
        // evidence passages; rebuilding it from `webHits` below would silently
        // downgrade the tool detail sheet to the old five-field snippet array.
        if let result = call.result,
           !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return call
        }

        // Compatibility for old persisted calls that have message-level hits but
        // no recorded tool result at all.
        guard let hits = msg.webHits, !hits.isEmpty else { return call }

        let hitsArray: [[String: Any]] = hits.map { hit in
            [
                "title": hit.title,
                "url": hit.url,
                "snippet": hit.snippet,
                "engine": hit.engine,
                "score": hit.score
            ]
        }

        if let data = try? JSONSerialization.data(withJSONObject: hitsArray, options: .prettyPrinted),
           let jsonString = String(data: data, encoding: .utf8) {
            return ChatVM.Msg.ToolCall(
                id: call.id,
                toolName: call.toolName,
                displayName: call.displayName,
                iconName: call.iconName,
                requestParams: call.requestParams,
                phase: .completed,
                externalToolCallID: call.externalToolCallID,
                result: jsonString,
                error: nil,
                timestamp: call.timestamp,
                completedAt: call.completedAt
            )
        }

        return call
    }

    enum MissingToolFallbackKind: Equatable {
        case text
        case code
        case think
        case tool
        case outputContinuation
        case promptProcessing
        case genericLoading
        case postToolWait
        case routing
    }

    static func insertIndexForMissingToolEntries(in kinds: [MissingToolFallbackKind]) -> Int {
        let thinkIndices = kinds.enumerated().compactMap { index, kind -> Int? in
            kind == .think ? index : nil
        }
        if thinkIndices.count >= 2 {
            return thinkIndices[1]
        }
        if let firstThinkIndex = thinkIndices.first {
            return firstThinkIndex + 1
        }
        if let narrativeIndex = kinds.firstIndex(where: { $0 == .text || $0 == .code }) {
            return narrativeIndex
        }
        return kinds.endIndex
    }

    static func insertIndexForPromptProcessingEntry(in kinds: [MissingToolFallbackKind]) -> Int {
        if let lastToolIndex = kinds.lastIndex(of: .tool) {
            return lastToolIndex + 1
        }
        if let lastThinkIndex = kinds.lastIndex(of: .think) {
            return lastThinkIndex + 1
        }
        if let narrativeIndex = kinds.firstIndex(where: { $0 == .text || $0 == .code }) {
            return narrativeIndex
        }
        if let genericLoadingIndex = kinds.lastIndex(of: .genericLoading) {
            return genericLoadingIndex + 1
        }
        return kinds.endIndex
    }

    private struct RenderEntry: Identifiable {
        enum Kind {
            case text(String)
            case code(code: String, language: String?)
            case thinkExisting(key: String)
            case thinkNew(text: String, done: Bool, key: String)
            case tool(ChatVM.Msg.ToolCall)
            case outputContinuation(ChatVM.Msg.OutputContinuationEvent)
            case promptProcessing(progress: Double)
            case genericLoading
            case postToolWait
            case routing
        }

        let id: String
        let kind: Kind
        let topPadding: CGFloat
        let bottomPadding: CGFloat

        init(id: String, kind: Kind, topPadding: CGFloat, bottomPadding: CGFloat = 0) {
            self.id = id
            self.kind = kind
            self.topPadding = topPadding
            self.bottomPadding = bottomPadding
        }
    }

    private var shouldShowRoutingEntry: Bool {
        guard msg.role == "🤖" || msg.role.lowercased() == "assistant" else { return false }
        if msg.route != nil { return true }
        return msg.streaming && vm.autoRoutingStage == .deciding && vm.isAutoRoutingActive
    }

    private var routerRowPhase: RouterRowPhase {
        msg.route == nil ? .deciding : .resolved
    }

    private var canRerouteMessage: Bool {
        msg.route != nil && canRegenerateMessage
    }

    private func rerouteMessage() {
        guard let route = msg.route, canRerouteMessage else { return }
        let target: AutoRouteTarget = route.answerTarget == .cloud ? .local : .cloud
        Task { await vm.reroute(messageID: msg.id, target: target) }
    }

    /// Messages whose routing row already resolved with a VoiceOver announcement;
    /// keeps re-renders (and revisits of the same chat) from repeating it.
    @MainActor private static var announcedRouteMessageIDs: Set<UUID> = []

    private func announceRouteResolutionIfNeeded() {
        guard let record = msg.route else { return }
        guard Self.announcedRouteMessageIDs.insert(msg.id).inserted else { return }
#if os(macOS)
        // The announcer's AppKit branch posts unconditionally; only speak when
        // VoiceOver is actually running (the UIKit branch already guards).
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
#endif
        if record.fellBackToLocal {
            let reason = record.reasonKey.map(AutopilotReasonKey.localized) ?? record.reason
            AccessibilityAnnouncer.announce(
                String(localized: "Autopilot") + ": " + reason
            )
            return
        }
        switch record.answerTarget {
        case .local:
            AccessibilityAnnouncer.announce(String(localized: "Autopilot: answering on-device."))
        case .cloud:
            let model = record.escalationModelName ?? String(localized: "cloud")
            AccessibilityAnnouncer.announce(String(localized: "Autopilot: escalated to \(model)."))
        }
    }

    @ViewBuilder
    private func piecesView(_ pieces: [ChatVM.Piece]) -> some View {
        let thinkOrdinals: [Int?] = {
            var ordinals = Array(repeating: Int?.none, count: pieces.count)
            var counter = 0
            for idx in pieces.indices {
                if pieces[idx].isThink {
                    ordinals[idx] = counter
                    counter += 1
                }
            }
            return ordinals
        }()

        let renderEntries: [RenderEntry] = {
            var results: [RenderEntry] = []
            var renderedToolCallIDs = Set<UUID>()

            for idx in pieces.indices {
                let piece = pieces[idx]
                let prevIsThink = idx > 0 ? pieces[idx - 1].isThink : false
                let prevIsTool = idx > 0 ? pieces[idx - 1].isTool : false

                switch piece {
                case .text(let t):
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let topPadding: CGFloat = (prevIsThink || prevIsTool) ? 10 : 4
                    results.append(
                        RenderEntry(
                            id: "text-\(msg.id.uuidString)-\(idx)",
                            kind: .text(t),
                            topPadding: topPadding
                        )
                    )
                case .code(let code, let language):
                    results.append(
                        RenderEntry(
                            id: "code-\(msg.id.uuidString)-\(idx)",
                            kind: .code(code: code, language: language),
                            topPadding: 4
                        )
                    )
                case .think(let t, let done):
                    guard let thinkOrdinalIndex = thinkOrdinals[idx] else { continue }
                    // Never render an empty reasoning block — even when a rolling-thought
                    // view model happens to exist at this ordinal. A stale/mismatched view
                    // model would otherwise surface another block's text here as a duplicate
                    // REASONING row. (parse() no longer emits empty think pieces, so this is
                    // belt-and-suspenders against any residual/whitespace-only block.)
                    guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let thinkKey = "message-\(msg.id.uuidString)-think-\(thinkOrdinalIndex)"

                    if vm.rollingThoughtViewModels[thinkKey] != nil {
                        results.append(
                            RenderEntry(
                                id: "think-existing-\(thinkKey)",
                                kind: .thinkExisting(key: thinkKey),
                                topPadding: 4
                            )
                        )
                    } else {
                        results.append(
                            RenderEntry(
                                id: "think-new-\(thinkKey)",
                                kind: .thinkNew(text: t, done: done, key: thinkKey),
                                topPadding: 4
                            )
                        )
                    }
                case .tool(let toolIndex):
                    guard let toolCalls = msg.toolCalls,
                          toolCalls.indices.contains(toolIndex) else { continue }

                    let originalCall = toolCalls[toolIndex]
                    let call = displayedToolCall(originalCall)
                    guard renderedToolCallIDs.insert(call.id).inserted else { continue }

                    results.append(
                        RenderEntry(
                            id: "tool-\(call.id.uuidString)",
                            kind: .tool(call),
                            topPadding: 4,
                            bottomPadding: 2
                        )
                    )
                case .outputContinuation(let event):
                    results.append(
                        RenderEntry(
                            id: "output-continuation-\(event.id.uuidString)-\(event.phase.rawValue)",
                            kind: .outputContinuation(event),
                            topPadding: 8,
                            bottomPadding: 4
                        )
                    )
                }
            }
            // Ensure pending/completed tool calls render even when the model stream
            // did not emit inline TOOL_CALL/TOOL_RESULT markers in message text.
            if let toolCalls = msg.toolCalls {
                let hasParsedToolEntries = results.contains { entry in
                    if case .tool = entry.kind { return true }
                    return false
                }
                var missingToolEntries: [RenderEntry] = []
                for originalCall in toolCalls {
                    let call = displayedToolCall(originalCall)
                    guard renderedToolCallIDs.insert(call.id).inserted else { continue }
                    missingToolEntries.append(
                        RenderEntry(
                            id: "tool-\(call.id.uuidString)",
                            kind: .tool(call),
                            topPadding: 4,
                            bottomPadding: 2
                        )
                    )
                }
                if !missingToolEntries.isEmpty {
                    let insertIndex: Int
                    if !hasParsedToolEntries {
                        let kinds = results.map { entry -> MissingToolFallbackKind in
                            switch entry.kind {
                            case .text:
                                return .text
                            case .code:
                                return .code
                            case .thinkExisting, .thinkNew:
                                return .think
                            case .tool:
                                return .tool
                            case .outputContinuation:
                                return .outputContinuation
                            case .promptProcessing:
                                return .promptProcessing
                            case .genericLoading:
                                return .genericLoading
                            case .postToolWait:
                                return .postToolWait
                            case .routing:
                                return .routing
                            }
                        }
                        insertIndex = Self.insertIndexForMissingToolEntries(in: kinds)
                    } else {
                        // Out-of-band tool calls (no inline marker in text) slot in
                        // after the reasoning that *requested* them but before the
                        // reasoning/narrative that *reacted* to their result.
                        func isThinkEntry(_ kind: RenderEntry.Kind) -> Bool {
                            switch kind {
                            case .thinkExisting, .thinkNew:
                                return true
                            default:
                                return false
                            }
                        }
                        let lastParsedToolIndex = results.lastIndex { entry in
                            if case .tool = entry.kind { return true }
                            return false
                        }
                        let searchStart = lastParsedToolIndex.map { $0 + 1 } ?? results.startIndex
                        let thinkIndicesAfterTools = results.indices.filter {
                            $0 >= searchStart && isThinkEntry(results[$0].kind)
                        }
                        let trailingThinkIsStreaming: Bool = {
                            if case .think(_, let done)? = pieces.last, !done { return true }
                            return false
                        }()
                        let allMissingCallsResolved = missingToolEntries.allSatisfy { entry in
                            if case .tool(let call) = entry.kind {
                                return call.phase == .completed || call.phase == .failed
                            }
                            return true
                        }
                        if let lastThinkIndex = thinkIndicesAfterTools.last,
                           thinkIndicesAfterTools.count >= 2
                            || (trailingThinkIsStreaming && allMissingCallsResolved) {
                            // The final reasoning segment is the model reacting to
                            // the tool result — the call itself happened before it.
                            insertIndex = lastThinkIndex
                        } else {
                            insertIndex = results.firstIndex { entry in
                                switch entry.kind {
                                case .text, .code:
                                    return true
                                case .thinkExisting, .thinkNew, .tool, .outputContinuation, .promptProcessing, .genericLoading, .postToolWait, .routing:
                                    return false
                                }
                            } ?? results.endIndex
                        }
                    }
                    results.insert(contentsOf: missingToolEntries, at: insertIndex)
                }
            }
            if msg.shouldShowGenericLoadingIndicator {
                results.append(
                    RenderEntry(
                        id: "generic-loading-\(msg.id.uuidString)",
                        kind: .genericLoading,
                        // Clear the preceding tool card's drop shadow (radius 8,
                        // y 4) so the spinner doesn't sit half-buried under it.
                        topPadding: 12,
                        bottomPadding: 2
                    )
                )
            }
            if msg.shouldShowPromptProcessingCard, let promptProcessing = msg.promptProcessing {
                let kinds = results.map { entry -> MissingToolFallbackKind in
                    switch entry.kind {
                    case .text:
                        return .text
                    case .code:
                        return .code
                    case .thinkExisting, .thinkNew:
                        return .think
                    case .tool:
                        return .tool
                    case .outputContinuation:
                        return .outputContinuation
                    case .promptProcessing:
                        return .promptProcessing
                    case .genericLoading:
                        return .genericLoading
                    case .postToolWait:
                        return .postToolWait
                    case .routing:
                        return .routing
                    }
                }
                let insertIndex = Self.insertIndexForPromptProcessingEntry(in: kinds)
                results.insert(
                    RenderEntry(
                        id: "prompt-processing-\(msg.id.uuidString)",
                        kind: .promptProcessing(progress: promptProcessing.progress),
                        topPadding: 8,
                        bottomPadding: 2
                    ),
                    at: insertIndex
                )
            }
            // Append a small spinner after the last tool call while waiting
            // for the post-tool continuation to start streaming tokens.
            if msg.postToolWaiting, (!renderedToolCallIDs.isEmpty || (msg.toolCalls?.isEmpty == false)) {
                results.append(
                    RenderEntry(
                        id: "post-tool-wait-\(msg.id.uuidString)",
                        kind: .postToolWait,
                        topPadding: 6,
                        bottomPadding: 2
                    )
                )
            }
            // Autopilot verdict row. Prepended last — after every positional
            // insertion above — so it always sits above the entire reply.
            if shouldShowRoutingEntry {
                results.insert(
                    RenderEntry(
                        id: "routing-\(msg.id.uuidString)",
                        kind: .routing,
                        topPadding: 4,
                        bottomPadding: 2
                    ),
                    at: results.startIndex
                )
            }
            return results
        }()

        VStack(alignment: .leading, spacing: 0) {
            ForEach(renderEntries) { entry in
                switch entry.kind {
                case .text(let text):
                    renderTextOrList(text)
                        .padding(.top, entry.topPadding)
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                        .padding(.top, entry.topPadding)
                case .thinkExisting(let key):
                    if let viewModel = vm.rollingThoughtViewModels[key] {
                        RollingThoughtBox(viewModel: viewModel)
                            .padding(.top, entry.topPadding)
                    }
                case .thinkNew(let text, let done, let key):
                    let tempVM = RollingThoughtViewModel()
                    RollingThoughtBox(viewModel: tempVM)
                        .padding(.top, entry.topPadding)
                        .onAppear {
                            DispatchQueue.main.async {
                                tempVM.fullText = text
                                tempVM.updateRollingLines()
                                tempVM.phase = done ? .complete : .streaming
                                if vm.rollingThoughtViewModels[key] == nil {
                                    vm.rollingThoughtViewModels[key] = tempVM
                                }
                            }
                        }
                case .tool(let call):
                    VStack(alignment: .leading, spacing: 6) {
                        ToolCallView(toolCall: call).equatable()
                        // Show a rendered chart inline in the bubble (not just in the
                        // tool-call detail). No-op until the result carries an image.
                        if ToolCallViewSupport.toolKind(for: call.toolName) == .chart,
                           let result = call.result {
                            InlineToolChartView(result: result)
                                .padding(.leading, 14)
                        }
                    }
                    .padding(.top, entry.topPadding)
                    .padding(.bottom, entry.bottomPadding)
                case .outputContinuation(let event):
                    OutputContinuationReceiptView(event: event)
                        .padding(.top, entry.topPadding)
                        .padding(.bottom, entry.bottomPadding)
                case .promptProcessing(let progress):
                    ProcessingPromptCardView(progress: progress)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, entry.topPadding)
                        .padding(.bottom, entry.bottomPadding)
                case .genericLoading:
                    HStack {
                        ProgressView()
                            .scaleEffect(0.85)
                            .tint(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, entry.topPadding)
                    .padding(.bottom, entry.bottomPadding)
                case .postToolWait:
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.top, entry.topPadding)
                        .padding(.bottom, entry.bottomPadding)
                case .routing:
                    RouterDecisionRow(
                        phase: routerRowPhase,
                        record: msg.route,
                        localModelName: msg.localModelName,
                        onReroute: canRerouteMessage ? { rerouteMessage() } : nil
                    )
                    .equatable()
                    .onChangeCompat(of: routerRowPhase) { oldPhase, newPhase in
                        guard oldPhase == .deciding, newPhase == .resolved else { return }
                        announceRouteResolutionIfNeeded()
                    }
                    .padding(.top, entry.topPadding)
                    .padding(.bottom, entry.bottomPadding)
                }
            }
        }
    }

    private func copyMessageToPasteboard() {
        let copyPayload = copyableMessageText()
#if os(iOS) || os(visionOS)
        UIPasteboard.general.string = copyPayload
#if os(iOS)
        Haptics.impact(.light)
#endif
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyPayload, forType: .string)
#endif
        copiedMessage = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedMessage = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if copiedMessage {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showCopyPopup = false
                }
            }
        }
    }

    private func toggleMessageBookmark() {
        vm.toggleBookmark(messageID: msg.id)
#if os(iOS)
        Haptics.impact(.light)
#endif
    }

    private func pinMessageToScratchpad() {
        let text = copyableMessageText()
        vm.pinMessageTextToActiveScratchpad(text, role: msg.role, timestamp: msg.timestamp)
#if os(iOS)
        Haptics.impact(.light)
#endif
        pinnedToScratchpad = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            pinnedToScratchpad = false
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
    }

    private func branchFromMessage() {
        _ = vm.branchSession(fromMessageID: msg.id)
#if os(iOS)
        Haptics.impact(.light)
#endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
    }

    private var canRegenerateMessage: Bool {
        (msg.role == "🤖" || msg.role.lowercased() == "assistant")
            && !msg.streaming
            && vm.canAcceptChatInput
            && !vm.isStreamingInAnotherSession
    }

    private var canAskWithAnotherModel: Bool {
        (msg.role == "🤖" || msg.role.lowercased() == "assistant")
            && !msg.streaming
            && !vm.isStreamingInAnotherSession
    }

    private var canAuditMessage: Bool {
        (msg.role == "🤖" || msg.role.lowercased() == "assistant")
            && !msg.streaming
            && vm.canAcceptChatInput
            && !vm.isStreamingInAnotherSession
    }

    private func regenerateMessage() {
        guard canRegenerateMessage else { return }
#if os(iOS)
        Haptics.impact(.light)
#endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
        Task { await vm.regenerateAssistantResponse(messageID: msg.id) }
    }

    private func askWithAnotherModel() {
        guard canAskWithAnotherModel else { return }
        guard vm.prepareAskSamePromptWithAnotherModel(messageID: msg.id) else { return }
#if os(iOS)
        Haptics.impact(.light)
#endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
        UserDefaults.standard.set(ExploreSection.models.rawValue, forKey: "exploreSection")
        tabRouter.selection = .explore
    }

    private func auditMessage() {
        guard canAuditMessage else { return }
#if os(iOS)
        Haptics.impact(.light)
#endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
        let prompt = String(localized: "Audit the previous answer for unsupported claims, missing caveats, possible errors, and places where the evidence is weak.")
        Task { await vm.sendMessage(prompt) }
    }

    private func copyableMessageText() -> String {
        let pieces = parse(msg.text, toolCalls: msg.toolCalls)
        var sections: [String] = []
        sections.reserveCapacity(pieces.count)

        var textAccumulator = ""

        func flushTextAccumulator() {
            let trimmed = textAccumulator.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let sanitized = textAccumulator.trimmingCharacters(in: .newlines)
                sections.append(sanitized)
            }
            textAccumulator.removeAll(keepingCapacity: true)
        }

        for piece in pieces {
            switch piece {
            case .text(let text):
                textAccumulator.append(text)
            case .code(let code, let language):
                flushTextAccumulator()
                let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedCode.isEmpty else { continue }
                let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let header = lang.isEmpty ? "```" : "```\(lang)"
                var block = header + "\n" + code
                if !code.hasSuffix("\n") {
                    block.append("\n")
                }
                block.append("```")
                sections.append(block)
            case .think, .tool, .outputContinuation:
                continue
            }
        }
        flushTextAccumulator()

        let combined = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !combined.isEmpty {
            return combined
        }

        return msg.text
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func datasetBadge(_ name: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dataset")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var privacyGuaranteeBadge: some View {
        if let descriptor = privacyBadgeDescriptor {
            HStack(spacing: 5) {
                Image(systemName: descriptor.iconName)
                    .font(.system(size: 10, weight: .semibold))
                Text(descriptor.title)
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(descriptor.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(descriptor.tint.opacity(colorScheme == .dark ? 0.14 : 0.10))
            )
            .accessibilityLabel(Text(descriptor.accessibilityLabel))
        }
    }

    @ViewBuilder
    private var evidenceReceiptButton: some View {
        if hasEvidenceReceipt {
            Button {
                showEvidenceSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Evidence")
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Text(verbatim: "\(evidenceItemCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.10))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String.localizedStringWithFormat(NSLocalizedString("%d evidence items", comment: "Accessibility label for evidence receipt count"), evidenceItemCount)))
        } else if isAdvancedMode, shouldNudgeForMissingEvidence {
            Button(action: auditMessage) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 10, weight: .semibold))
                    Text("No Evidence")
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Audit Evidence"))
        } else if isAdvancedMode, shouldShowModelOnlyUncertainty {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text("Model Only")
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.14 : 0.10))
            )
            .accessibilityLabel(Text("Model-only answer. No sources were attached."))
        }
    }

    /// Generation-speed details shown only in Advanced mode: token count,
    /// throughput and time-to-first-token, presented inline with the timestamp
    /// as one quiet metadata line.
    private var perfParts: [String] {
        guard isAdvancedMode, showGenerationDiagnostics, msg.role != "🧑‍💻", !msg.streaming, let perf = msg.perf else { return [] }
        var out: [String] = []
        if perf.tokenCount > 0 {
            out.append(String.localizedStringWithFormat(String(localized: "%lld tokens"), Int64(perf.tokenCount)))
        }
        if perf.avgTokPerSec > 0 {
            out.append(String.localizedStringWithFormat(String(localized: "%.1f tok/s"), perf.avgTokPerSec))
        }
        if perf.timeToFirst > 0 {
            out.append(String.localizedStringWithFormat(String(localized: "%.2fs TFT"), perf.timeToFirst))
        }
        if perf.totalDuration > 0 {
            out.append(String.localizedStringWithFormat(String(localized: "%.2fs total"), perf.totalDuration))
        }
        if let rate = perf.draftAcceptanceRate {
            let key = perf.speculativeType == "draft-mtp"
                ? String(localized: "MTP %lld%% accepted")
                : String(localized: "Speculative %lld%% accepted")
            out.append(String.localizedStringWithFormat(key, Int64((rate * 100).rounded())))
        }
        return out
    }

    /// Single low-contrast footer line: timestamp, plus generation stats when
    /// diagnostics are enabled.
    private var messageMetadataRow: some View {
        HStack(spacing: 6) {
            Text(msg.timestamp, style: .time)
            ForEach(perfParts, id: \.self) { part in
                Text(verbatim: "·")
                Text(part)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .padding(msg.role == "🧑‍💻" ? .trailing : .leading, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var messageReceiptBadges: some View {
        if hasReceiptBadges {
            HStack(spacing: 6) {
                privacyGuaranteeBadge
                evidenceReceiptButton
            }
            .padding(msg.role == "🧑‍💻" ? .trailing : .leading, 12)
            .frame(maxWidth: .infinity, alignment: msg.role == "🧑‍💻" ? .trailing : .leading)
        }
    }

#if os(visionOS)
    private func pinMessage() {
        guard let sessionID = vm.activeSessionID else { return }
        let note = pinnedStore.pin(message: msg, in: sessionID)
        openWindow(id: VisionSceneID.pinnedCardWindow, value: note.id)
    }
#endif

    @ViewBuilder
    private func bubbleView(
        _ pieces: [ChatVM.Piece],
        hasWebRetrieveCall: Bool,
        isSpotlighted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if msg.role == "🧑‍💻", let datasetName = datasetDisplayName {
                datasetBadge(datasetName)
            }

            if msg.role != "🧑‍💻",
               let transition = ChatVM.documentContextTransitionReceipt(for: msg, in: vm.msgs) {
                DocumentContextTransitionReceiptView(receipt: transition)
                    .padding(.bottom, 4)
            }

            if msg.role != "🧑‍💻",
               ChatVM.shouldShowDocumentAccessReceipt(for: msg, in: vm.msgs) {
                DocumentAccessDecisionBox(
                    decision: msg.documentAccessDecision,
                    info: msg.ragInjectionInfo
                )
                    .padding(.bottom, 4)
            }

            if shouldRenderRawOutput {
                rawOutputView(pieces: pieces)
            } else if !pieces.isEmpty
                || (msg.toolCalls?.isEmpty == false)
                || msg.shouldShowPromptProcessingCard
                || msg.shouldShowGenericLoadingIndicator
                || msg.postToolWaiting
                || shouldShowRoutingEntry {
                Group {
                    if bubbleShouldCombineForAccessibility {
                        // Finished plain-text bubble: expose as ONE VoiceOver
                        // element so a multi-paragraph reply is a single swipe
                        // stop and list re-layout can't bounce the cursor to a
                        // neighboring message. Tool/code/reasoning/streaming
                        // bubbles stay granular and individually focusable.
                        piecesView(pieces)
                            .accessibilityElement(children: .combine)
                    } else {
                        piecesView(pieces)
                    }
                }
            }
        }
        .padding(.horizontal, messageHorizontalPadding)
        .padding(.vertical, messageVerticalPadding)
        .frame(
            // Cap the user bubble so it reads as a chat bubble, not a banner.
            maxWidth: isUserMessage
                ? min(currentDeviceWidth() * 0.85, ChatTheme.userBubbleMaxWidth)
                : .infinity,
            alignment: isUserMessage ? .trailing : .leading
        )
        .background {
            if isUserMessage {
                RoundedRectangle(cornerRadius: ChatTheme.bubbleRadius, style: .continuous)
                    .fill(bubbleColor)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isUserMessage ? ChatTheme.bubbleRadius : 0,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIConstants.cornerRadius)
                .stroke(Color.accentColor.opacity(isSpotlighted ? 0.9 : 0), lineWidth: isSpotlighted ? 3 : 0)
        )
#if os(macOS)
        .textSelection(.enabled)
#endif
        .animation(.easeInOut(duration: 0.2), value: isSpotlighted)
    }

    @ViewBuilder
    private func messageContainer(
        pieces: [ChatVM.Piece],
        hasWebRetrieveCall: Bool,
        isSpotlighted: Bool
    ) -> some View {
        messageContainerBody(
            pieces: pieces,
            hasWebRetrieveCall: hasWebRetrieveCall,
            isSpotlighted: isSpotlighted
        )
#if os(macOS)
        .textSelection(.enabled)
#endif
    }

    private func messageContainerBody(
        pieces: [ChatVM.Piece],
        hasWebRetrieveCall: Bool,
        isSpotlighted: Bool
    ) -> some View {
        VStack(alignment: msg.role == "🧑‍💻" ? .trailing : .leading, spacing: 2) {
            if let paths = msg.imagePaths, !paths.isEmpty {
                imagesView(paths: paths)
            }
            if let mediaAttachments = msg.mediaAttachments, !mediaAttachments.isEmpty {
                mediaAttachmentsView(mediaAttachments)
            }

            HStack {
                if msg.role == "🧑‍💻" { Spacer() }

                bubbleView(pieces, hasWebRetrieveCall: hasWebRetrieveCall, isSpotlighted: isSpotlighted)

                if msg.role != "🧑‍💻" { Spacer() }
            }


            messageMetadataRow

            if msg.isBookmarked {
                HStack(spacing: 4) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                    Text(LocalizedStringKey("Bookmarked"))
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(msg.role == "🧑‍💻" ? .trailing : .leading, 12)
                .accessibilityElement(children: .combine)
            }

            messageReceiptBadges
        }
        .macWindowDragDisabled()
#if os(macOS)
        .environment(\.messageHoverCopySuppression, $suppressHoverCopy)
#endif
    }

    @ViewBuilder
    private func popupContainer(
        pieces: [ChatVM.Piece],
        hasWebRetrieveCall: Bool,
        isSpotlighted: Bool
    ) -> some View {
        HStack {
            if msg.role == "🧑‍💻" { Spacer() }

            VStack(alignment: .leading, spacing: 12) {
                messageContainer(
                    pieces: pieces,
                    hasWebRetrieveCall: hasWebRetrieveCall,
                    isSpotlighted: isSpotlighted
                )
                .allowsHitTesting(false)
                .scaleEffect(1.02)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: { copyMessageToPasteboard() }) {
                            Label(copiedMessage ? "Copied!" : "Copy", systemImage: copiedMessage ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: toggleMessageBookmark) {
                            Label(
                                msg.isBookmarked ? LocalizedStringKey("Remove Bookmark") : LocalizedStringKey("Bookmark Message"),
                                systemImage: msg.isBookmarked ? "bookmark.slash" : "bookmark"
                            )
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: pinMessageToScratchpad) {
                            Label(
                                pinnedToScratchpad ? LocalizedStringKey("Pinned to Scratchpad") : LocalizedStringKey("Pin to Scratchpad"),
                                systemImage: pinnedToScratchpad ? "checkmark" : "note.text.badge.plus"
                            )
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: branchFromMessage) {
                            Label("Branch", systemImage: "arrow.triangle.branch")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.12))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        if canRegenerateMessage {
                            Button(action: regenerateMessage) {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.12))
                                    .foregroundColor(.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        if canAuditMessage {
                            Button(action: auditMessage) {
                                Label("Audit", systemImage: "checkmark.shield")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.12))
                                    .foregroundColor(.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        if canAskWithAnotherModel {
                            Button(action: askWithAnotherModel) {
                                Label("Try Model", systemImage: "rectangle.2.swap")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.12))
                                    .foregroundColor(.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 12)
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showCopyPopup = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: currentDeviceWidth() * 0.9)

            if msg.role != "🧑‍💻" { Spacer() }
        }
        .padding(.horizontal, 12)
        .transition(.scale.combined(with: .opacity))
    }

    var body: some View {
        // Finished messages saved by older versions may still contain a textual
        // end-of-turn marker. Keep it available to Raw Model Output, but never
        // feed protocol control text into the normal formatted renderer.
        let sourceText = shouldRenderRawOutput
            ? msg.text
            : AssistantOutputSanitizer.strippingTrailingControlMarkers(from: msg.text)
        let markedSourceText = shouldRenderRawOutput
            ? sourceText
            : insertingOutputContinuationMarkers(
                into: sourceText,
                events: msg.outputContinuationEvents ?? []
            )
        let displayText = WebCitationLinkifier.linkify(markedSourceText, hits: msg.webHits)
        let pieces = parse(
            displayText,
            toolCalls: msg.toolCalls,
            outputContinuationEvents: shouldRenderRawOutput ? nil : msg.outputContinuationEvents
        )
        let hasWebRetrieveCall = msg.toolCalls?.contains { $0.toolName == "noema.web.retrieve" } ?? false

        let isSpotlighted = vm.spotlightMessageID == msg.id

        ZStack(alignment: .center) {
            messageContainer(
                pieces: pieces,
                hasWebRetrieveCall: hasWebRetrieveCall,
                isSpotlighted: isSpotlighted
            )
            .opacity(showCopyPopup ? 0.25 : 1)
            .allowsHitTesting(!showCopyPopup)

            if showCopyPopup {
                ZStack {
                    Color.black.opacity(0.001)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showCopyPopup = false
                            }
                        }

                    popupContainer(
                        pieces: pieces,
                        hasWebRetrieveCall: hasWebRetrieveCall,
                        isSpotlighted: isSpotlighted
                    )
                }
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == "🧑‍💻" ? .trailing : .leading)
#if os(iOS)
        .onLongPressGesture(minimumDuration: 0.45) {
            copiedMessage = false
            performMediumImpact()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                showCopyPopup = true
            }
        }
#endif
#if os(macOS)
        .overlay(alignment: .bottomTrailing) {
            if hoverCopyVisible && !showCopyPopup && !suppressHoverCopy {
                HStack(spacing: 0) {
                    // Copy — shows label for feedback clarity
                    Button(action: copyMessageToPasteboard) {
                        HStack(spacing: 5) {
                            Image(systemName: copiedMessage ? "checkmark" : "doc.on.doc")
                            Text(copiedMessage ? "Copied" : "Copy")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(copiedMessage ? Color.green : Color.primary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy message")

                    Color.primary.opacity(0.1).frame(width: 1, height: 16)

                    Button(action: toggleMessageBookmark) {
                        Image(systemName: msg.isBookmarked ? "bookmark.fill" : "bookmark")
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundStyle(msg.isBookmarked ? Color.primary.opacity(0.85) : Color.primary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(msg.isBookmarked ? "Remove Bookmark" : "Bookmark")
                    .accessibilityLabel(msg.isBookmarked ? "Remove Bookmark" : "Bookmark Message")

                    Button(action: pinMessageToScratchpad) {
                        Image(systemName: pinnedToScratchpad ? "checkmark" : "note.text.badge.plus")
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundStyle(pinnedToScratchpad ? Color.primary.opacity(0.85) : Color.primary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(pinnedToScratchpad ? "Pinned to Scratchpad" : "Pin to Scratchpad")
                    .accessibilityLabel(pinnedToScratchpad ? "Pinned to Scratchpad" : "Pin to Scratchpad")

                    Button(action: branchFromMessage) {
                        Image(systemName: "arrow.triangle.branch")
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundStyle(Color.primary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Branch Conversation")
                    .accessibilityLabel("Branch Conversation")

                    if canRegenerateMessage {
                        Color.primary.opacity(0.1).frame(width: 1, height: 16)
                        Button(action: regenerateMessage) {
                            Image(systemName: "arrow.clockwise")
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Regenerate Response")
                        .accessibilityLabel("Regenerate Response")
                    }

                    if canAuditMessage {
                        Button(action: auditMessage) {
                            Image(systemName: "checkmark.shield")
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Audit Answer")
                        .accessibilityLabel("Audit Answer")
                    }

                    if canAskWithAnotherModel {
                        Button(action: askWithAnotherModel) {
                            Image(systemName: "rectangle.2.swap")
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Ask with Another Model")
                        .accessibilityLabel("Ask with Another Model")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                hoverCopyVisible = hovering
            }
            if !hovering {
                suppressHoverCopy = false
            }
        }
#endif
#if os(visionOS)
        .overlay(alignment: msg.role == "🧑‍💻" ? .bottomTrailing : .bottomLeading) {
            if showInteractionOptions && !showCopyPopup {
                HStack(spacing: 10) {
                    Button(action: copyMessageToPasteboard) {
                        Image(systemName: copiedMessage ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy message")

                    Button(action: pinMessage) {
                        Image(systemName: "pin")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pin message")

                    Button(action: pinMessageToScratchpad) {
                        Image(systemName: pinnedToScratchpad ? "checkmark" : "note.text.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pinnedToScratchpad ? "Pinned to Scratchpad" : "Pin to Scratchpad")

                    Button(action: branchFromMessage) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Branch Conversation")

                    if canRegenerateMessage {
                        Button(action: regenerateMessage) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Regenerate Response")
                    }

                    if canAuditMessage {
                        Button(action: auditMessage) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Audit Answer")
                    }

                    if canAskWithAnotherModel {
                        Button(action: askWithAnotherModel) {
                            Image(systemName: "rectangle.2.swap")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ask with Another Model")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .offset(y: 26)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                hoverActive = hovering
                if hovering {
                    showInteractionOptions = true
                } else if !isPressingMessage {
                    showInteractionOptions = false
                }
            }
        }
        .onChangeCompat(of: isPressingMessage) { _, pressing in
            withAnimation(.easeInOut(duration: 0.18)) {
                if pressing {
                    showInteractionOptions = true
                } else if !hoverActive {
                    showInteractionOptions = false
                }
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .updating($isPressingMessage) { current, state, _ in
                    state = current
                }
        )
#endif
        .onChangeCompat(of: showCopyPopup) { _, newValue in
            if !newValue {
                copiedMessage = false
            }
#if os(visionOS)
            if newValue {
                showInteractionOptions = false
            }
#endif
        }
        .onChangeCompat(of: msg.text) { _, _ in
            if showCopyPopup {
                copiedMessage = false
            }
        }
        .onChangeCompat(of: vm.msgs) { _, _ in
            if showCopyPopup {
                showCopyPopup = false
            }
        }
#if os(iOS) || os(visionOS)
        .fullScreenCover(isPresented: Binding(get: { expandedImagePath != nil }, set: { if !$0 { expandedImagePath = nil } })) {
            if let p = expandedImagePath {
                AttachmentPreview(path: p) { expandedImagePath = nil }
            }
        }
#else
        .sheet(isPresented: Binding(get: { expandedImagePath != nil }, set: { if !$0 { expandedImagePath = nil } })) {
            if let p = expandedImagePath {
                AttachmentPreview(path: p) { expandedImagePath = nil }
                    .frame(minWidth: 560, minHeight: 420)
            }
        }
#endif
        .sheet(item: $transcriptReviewAttachment) { attachment in
            TranscriptReviewSheet(
                attachment: attachment,
                allowsEditing: true,
                onSaveEdits: { title, transcriptText in
                    vm.updateMessageMediaTranscript(
                        messageID: msg.id,
                        attachmentID: attachment.id,
                        title: title,
                        transcriptText: transcriptText
                    )
                },
                onQuickAction: { action in
                    copyTranscriptToPasteboard(action.prompt(for: attachment.transcript?.displaySourceName ?? attachment.originalFilename))
                },
                onSaveNewDataset: {
                    saveTranscriptAttachment(attachment)
                },
                onSaveExistingDataset: {
                    existingDatasetSaveAttachment = attachment
                }
            )
        }
        .sheet(item: $existingDatasetSaveAttachment) { attachment in
            TranscriptDatasetPickerSheet(datasets: vm.datasetManager?.datasets ?? []) { dataset in
                saveTranscriptAttachment(attachment, toExistingDataset: dataset)
            }
        }
        .sheet(isPresented: $showEvidenceSheet) {
            MessageEvidenceSheet(message: msg)
        }
#if os(visionOS) || os(macOS)
        .contextMenu {
            Button {
                copyMessageToPasteboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                toggleMessageBookmark()
            } label: {
                Label(msg.isBookmarked ? "Remove Bookmark" : "Bookmark Message", systemImage: msg.isBookmarked ? "bookmark.slash" : "bookmark")
            }
            if canRerouteMessage, let route = msg.route {
                Button {
                    rerouteMessage()
                } label: {
                    Label(route.fellBackToLocal
                          ? ((route.escalationIsLocal == true || route.escalationUsesPrivateCloudCompute == true)
                                ? "Retry with Stronger Model"
                                : "Retry Cloud")
                          : (route.answerTarget == .cloud
                                ? "Redo On-Device"
                                : (AutopilotConfigStore.load().escalationTarget == .remote
                                    ? "Redo on Cloud"
                                    : "Redo with Stronger Model")),
                          systemImage: "arrow.triangle.branch")
                }
            }
#if os(visionOS)
            // Pinned-card windows are a visionOS-only surface.
            Button {
                pinMessage()
            } label: {
                Label("Pin", systemImage: "pin")
            }
#endif
            Button {
                pinMessageToScratchpad()
            } label: {
                Label("Pin to Scratchpad", systemImage: "note.text.badge.plus")
            }
            Button {
                branchFromMessage()
            } label: {
                Label("Branch", systemImage: "arrow.triangle.branch")
            }
            if canRegenerateMessage {
                Button {
                    regenerateMessage()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
            }
            if canAuditMessage {
                Button {
                    auditMessage()
                } label: {
                    Label("Audit", systemImage: "checkmark.shield")
                }
            }
            if canAskWithAnotherModel {
                Button {
                    askWithAnotherModel()
                } label: {
                    Label("Try Model", systemImage: "rectangle.2.swap")
                }
            }
        }
#endif
    }

    private struct MessageEvidenceSheet: View {
        let message: ChatVM.Msg
        @Environment(\.dismiss) private var dismiss

        private var retrievedChunks: [String] {
            (message.retrievedContext ?? "")
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        // On-demand dataset-search (`noema.rag.search`) returns retrieved chunks; each chunk is
        // a citation, so it joins the citation tally rather than counting as one tool call.
        private var datasetToolChunkCount: Int {
            (message.toolCalls ?? []).reduce(0) { total, call in
                guard call.toolName == "noema.rag.search", let result = call.result,
                      let payload = ToolCallViewSupport.parseDatasetSearchResult(from: result) else { return total }
                return total + payload.citations.count
            }
        }

        private var citationCount: Int { (message.citations?.count ?? 0) + datasetToolChunkCount }
        // Exclude web and dataset search from the tool-call tally; they're represented by their
        // results (`webCount` / `datasetToolChunkCount`) so the calls aren't double-counted.
        private var toolCount: Int {
            message.toolCalls?.filter { $0.toolName != "noema.web.retrieve" && $0.toolName != "noema.rag.search" }.count ?? 0
        }
        private var webCount: Int { message.webHits?.count ?? 0 }
        private var imageCount: Int { message.imagePaths?.count ?? 0 }
        private var mediaCount: Int { message.mediaAttachments?.count ?? 0 }

        // RAG surfaces the same chunks as citations, the joined retrievedContext,
        // and the ragInjectionInfo summary. Count them once (as the chunk count)
        // so the total matches the number of retrieved chunks.
        private var ragChunkCount: Int { message.citations?.count ?? retrievedChunks.count }

        private var evidenceItemCount: Int {
            ragChunkCount + datasetToolChunkCount + toolCount + webCount + imageCount + mediaCount
        }

        var body: some View {
#if os(macOS)
            // macOS sheets collapse a NavigationStack+List to near-zero height;
            // use an explicit header + sized list instead.
            VStack(spacing: 0) {
                HStack {
                    Text("Evidence")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider().opacity(0.5)
                List {
                    summarySection
                    retrievalSection
                    citationsSection
                    retrievedContextSection
                    toolCallsSection
                    webResultsSection
                    attachmentsSection
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 520, idealWidth: 600, maxWidth: 680, minHeight: 440, idealHeight: 560, maxHeight: 680)
#else
            NavigationStack {
                List {
                    summarySection
                    retrievalSection
                    citationsSection
                    retrievedContextSection
                    toolCallsSection
                    webResultsSection
                    attachmentsSection
                }
                .navigationTitle(Text("Evidence"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
#endif
        }

        @ViewBuilder
        private var summarySection: some View {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    summaryChip(title: "Evidence", value: String(evidenceItemCount), icon: "list.bullet.rectangle")
                    summaryChip(title: "Citations", value: String(citationCount), icon: "quote.bubble")
                    summaryChip(title: "Tool Calls", value: String(toolCount), icon: "wrench.and.screwdriver")
                    summaryChip(title: "Web Sources", value: String(webCount), icon: "globe")
                    summaryChip(title: "Attachments", value: String(imageCount + mediaCount), icon: "paperclip")
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("Evidence Summary")
            }
        }

        @ViewBuilder
        private var retrievalSection: some View {
            if message.documentAccessDecision != nil || message.ragInjectionInfo != nil {
                Section {
                    if let decision = message.documentAccessDecision {
                        detailRow("Dataset", value: decision.datasetName)
                        detailRow("Planner", value: documentPlannerText(decision.decidedBy))
                        detailRow("Requested Plan", value: documentAccessStrategyText(decision.requestedStrategy))
                        if decision.wasCapabilityAdjusted {
                            detailRow("Effective Plan", value: documentAccessStrategyText(decision.effectiveStrategy))
                        }
                    }
                    if let info = message.ragInjectionInfo {
                        if message.documentAccessDecision == nil {
                            detailRow("Dataset", value: info.datasetName)
                        }
                        detailRow("Method", value: retrievalMethodText(info.method))
                        detailRow("Stage", value: retrievalStageText(info.stage))
                        detailRow("Chunks", value: "\(info.injectedChunkCount) / \(info.retrievedChunkCount)")
                        detailRow("Injected Tokens", value: "\(info.injectedContextTokens)")
                        detailRow("Prompt Budget", value: "\(info.contextBudgetTokens)")
                        detailRow("Reserved Response", value: "\(info.reservedResponseTokens)")
                        if !info.decisionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            previewBlock(title: "Decision", text: info.decisionReason)
                        }
                    }
                } header: {
                    Text("Document Access")
                }
            }
        }

        private func documentPlannerText(_ decidedBy: DocumentAccessDecisionRecord.DecidedBy) -> String {
            switch decidedBy {
            case .appleFoundationModel:
                return String(localized: "Apple Foundation Models") + " · " + String(localized: "on-device")
            case .rulesFallback:
                return String(localized: "Rules Fallback")
            }
        }

        private func documentAccessStrategyText(_ strategy: DocumentAccessStrategy) -> String {
            switch strategy {
            case .none:
                return String(localized: "Document Not Used")
            case .context:
                return String(localized: "Automatic Context")
            case .navigate:
                return String(localized: "PDF Navigation")
            case .contextThenNavigate:
                return String(localized: "Context + PDF Navigation")
            }
        }

        @ViewBuilder
        private var citationsSection: some View {
            if let citations = message.citations, !citations.isEmpty {
                Section {
                    ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
                        CitationRow(index: index + 1, citation: citation)
                    }
                } header: {
                    Text("Citations")
                }
            }
        }

        @ViewBuilder
        private var retrievedContextSection: some View {
            // RAG surfaces the same chunks as citations, so only show the raw
            // retrieved context when there are no citations — otherwise it just
            // duplicates the Citations section above.
            if (message.citations?.isEmpty ?? true), !retrievedChunks.isEmpty {
                Section {
                    ForEach(Array(retrievedChunks.enumerated()), id: \.offset) { index, chunk in
                        previewBlock(title: "#\(index + 1)", text: chunk)
                    }
                } header: {
                    Text("Retrieved Context")
                }
            }
        }

        @ViewBuilder
        private var toolCallsSection: some View {
            // Web searches are surfaced in their own Web Results section, so drop
            // the `noema.web.retrieve` call here to match the Tool Calls tally.
            let toolCalls = (message.toolCalls ?? []).filter { $0.toolName != "noema.web.retrieve" }
            if !toolCalls.isEmpty {
                Section {
                    ForEach(toolCalls) { tool in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Image(systemName: tool.iconName)
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text(verbatim: tool.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(verbatim: tool.phase.rawValue.capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(tool.phase == .failed ? .orange : .secondary)
                            }
                            let entries = ToolCallViewSupport.parameterSummaryEntries(
                                from: tool.requestParams,
                                maxEntries: 3,
                                maxValueLength: 80
                            )
                            if !entries.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Parameters")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(entries) { entry in
                                        detailRow(Text(verbatim: entry.key), value: entry.value)
                                    }
                                }
                            }
                            if let error = tool.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                                previewBlock(title: "Error", text: error, tint: .orange)
                            } else if let result = tool.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                                previewBlock(title: "Result", text: ToolCallViewSupport.formatRawResult(result))
                            } else {
                                detailRow("Result", value: String(localized: "No result"))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Tool Calls")
                }
            }
        }

        @ViewBuilder
        private var webResultsSection: some View {
            if let webHits = message.webHits, !webHits.isEmpty {
                Section {
                    ForEach(webHits, id: \.id) { hit in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "[\(hit.id)]")
                                    .font(.caption.monospacedDigit().weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                Text(verbatim: hit.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                            }
                            HStack(spacing: 10) {
                                detailPill(title: "Status", value: webStatusLabel(hit.fetchStatus))
                                detailPill(title: "Engine", value: hit.engine)
                                if hit.score > 0 {
                                    detailPill(title: "Score", value: String(format: "%.2f", hit.score))
                                }
                            }
                            if let author = hit.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                                detailRow("Author", value: author)
                            }
                            if let published = hit.publishedAt?.trimmingCharacters(in: .whitespacesAndNewlines), !published.isEmpty {
                                detailRow("Published", value: published)
                            }
                            if !hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(verbatim: compactPreview(hit.snippet))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                            if let passages = hit.passages, !passages.isEmpty {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(passages) { passage in
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 6) {
                                                    if let heading = passage.heading, !heading.isEmpty {
                                                        Text(verbatim: heading)
                                                            .font(.caption.weight(.semibold))
                                                            .lineLimit(1)
                                                    }
                                                    Spacer(minLength: 0)
                                                    Text(verbatim: webPassageLocation(passage))
                                                        .font(.caption2.monospacedDigit())
                                                        .foregroundStyle(.secondary)
                                                }
                                                Text(verbatim: passage.text)
                                                    .font(.footnote)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }
                                    .padding(.top, 6)
                                } label: {
                                    Text("Evidence passages")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            if let url = URL(string: hit.url) {
                                Link(destination: url) {
                                    Label("URL", systemImage: "link")
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            } else {
                                detailRow("URL", value: hit.url)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Web Sources")
                }
            }
        }

        private func webStatusLabel(_ rawValue: String?) -> String {
            switch rawValue {
            case WebFetchStatus.read.rawValue: return String(localized: "Read")
            case WebFetchStatus.blocked.rawValue: return String(localized: "Blocked")
            case WebFetchStatus.unsupported.rawValue: return String(localized: "Unsupported")
            case WebFetchStatus.tooLarge.rawValue: return String(localized: "Too large")
            case WebFetchStatus.timeout.rawValue: return String(localized: "Timed out")
            case WebFetchStatus.noText.rawValue: return String(localized: "No readable text")
            default: return String(localized: "Snippet only")
            }
        }

        private func webPassageLocation(_ passage: ChatVM.Msg.WebPassage) -> String {
            if let page = passage.page {
                return String(format: String(localized: "Page %d"), page)
            }
            if let start = passage.lineStart, let end = passage.lineEnd {
                return String(format: String(localized: "Lines %d–%d"), start, end)
            }
            return String(localized: "Evidence")
        }

        @ViewBuilder
        private var attachmentsSection: some View {
            if imageCount > 0 || mediaCount > 0 {
                Section {
                    if let imagePaths = message.imagePaths, !imagePaths.isEmpty {
                        ForEach(Array(imagePaths.enumerated()), id: \.offset) { index, path in
                            HStack(spacing: 10) {
                                Image(systemName: "photo")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Images")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(verbatim: URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "#\(index + 1)" : URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.footnote)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    if let mediaAttachments = message.mediaAttachments, !mediaAttachments.isEmpty {
                        ForEach(mediaAttachments) { attachment in
                            HStack(spacing: 10) {
                                Image(systemName: attachment.kind.iconName)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: attachment.transcript?.displaySourceName ?? attachment.originalFilename)
                                        .font(.footnote.weight(.semibold))
                                        .lineLimit(1)
                                    Text(verbatim: [attachment.kind.title, attachment.mediaDetailLabel].compactMap(\.self).joined(separator: " / "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Attachments")
                }
            }
        }

        private func summaryChip(title: LocalizedStringKey, value: String, icon: String) -> some View {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value)
                        .font(.caption.monospacedDigit().weight(.bold))
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }

        private func detailRow(_ label: LocalizedStringKey, value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verbatim: value)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }

        private func detailRow(_ label: Text, value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verbatim: value)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }

        private func detailPill(title: LocalizedStringKey, value: String) -> some View {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
        }

        private func previewBlock(title: LocalizedStringKey, text: String, tint: Color = .secondary) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(verbatim: compactPreview(text))
                    .font(.footnote)
                    .foregroundStyle(tint)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func retrievalMethodText(_ method: ChatVM.Msg.RAGInjectionInfo.Method?) -> String {
            switch method {
            case .fullContent:
                return String(localized: "Full Content")
            case .rag:
                return String(localized: "RAG")
            case .none:
                return String(localized: "Unknown")
            }
        }

        private func retrievalStageText(_ stage: ChatVM.Msg.RAGInjectionInfo.Stage) -> String {
            switch stage {
            case .deciding:
                return String(localized: "Deciding")
            case .chosen:
                return String(localized: "Chosen")
            case .injected:
                return String(localized: "Injected")
            }
        }

        private func compactPreview(_ text: String, limit: Int = 420) -> String {
            let cleaned = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard cleaned.count > limit else { return cleaned }
            return String(cleaned.prefix(limit)) + "..."
        }

        /// A single citation in the evidence sheet. Tapping the row toggles
        /// between a compact preview and the full chunk text.
        private struct CitationRow: View {
            let index: Int
            let citation: ChatVM.Msg.Citation
            @State private var expanded = false

            var body: some View {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(verbatim: "#\(index)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Text(verbatim: sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let score = citation.score {
                            Text(String(format: "%.2f", score))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: expanded ? citation.text : preview)
                        .font(.footnote)
                        .lineLimit(expanded ? nil : 4)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                }
            }

            private var sourceLabel: String {
                if let source = citation.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
                    return source
                }
                return String(localized: "No source")
            }

            private var preview: String {
                let cleaned = citation.text
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                guard cleaned.count > 420 else { return cleaned }
                return String(cleaned.prefix(420)) + "..."
            }
        }
    }


    // MARK: - Citation UI

    private struct DocumentAccessDecisionBox: View {
        let decision: DocumentAccessDecisionRecord?
        let info: ChatVM.Msg.RAGInjectionInfo?
        @Environment(\.colorScheme) private var colorScheme
        @State private var isExpanded = false

        private var surfaceColor: Color {
#if os(macOS)
            Color.primary.opacity(0.035)
#else
            Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04)
#endif
        }

        private var borderColor: Color {
#if os(macOS)
            Color.primary.opacity(0.08)
#else
            Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09)
#endif
        }

#if os(macOS)
        private static let containerRadius: CGFloat = 10
        private static let borderWidth: CGFloat = 1
#else
        private static let containerRadius: CGFloat = 16
        private static let borderWidth: CGFloat = 0.9
#endif

        private var accentColor: Color {
            if let info {
                switch info.stage {
                case .deciding:
                    return .orange
                case .chosen, .injected:
                    switch info.method {
                    case .fullContent:
                        return .green
                    case .rag:
                        return .blue
                    case .none:
                        return .orange
                    }
                }
            }
            switch decision?.effectiveStrategy {
            case .some(.navigate), .some(.contextThenNavigate):
                return .purple
            case .some(.context):
                return .blue
            case .some(.none), nil:
                return .gray
            }
        }

        private var retrievalStatusText: String? {
            guard let info else { return nil }
            switch info.stage {
            case .deciding:
                return "Choosing context strategy"
            case .chosen, .injected:
                switch info.method {
                case .fullContent:
                    return "Using full document"
                case .rag:
                    // Only assert "nothing found" once retrieval has SETTLED
                    // (.injected). During .chosen the count is still 0 and would
                    // momentarily read as a false abstain while the search runs.
                    if info.stage == .injected && info.retrievedChunkCount == 0 {
                        return "No relevant passages found"
                    }
                    if info.injectedChunkCount < info.retrievedChunkCount {
                        return "Using smart retrieval • \(info.injectedChunkCount) of \(info.retrievedChunkCount) chunks fit"
                    }
                    return "Using smart retrieval"
                case .none:
                    return "Choosing context strategy"
                }
            }
        }

        private var headerKey: LocalizedStringKey {
            decision == nil ? "RETRIEVAL" : "Document Access"
        }

        private var decisionSourceText: String {
            switch decision?.decidedBy {
            case .appleFoundationModel:
                return "AFM"
            case .rulesFallback:
                return String(localized: "Rules Fallback")
            case .none:
                return ""
            }
        }

        private var requestedPlanKey: LocalizedStringKey {
            accessPlanKey(decision?.requestedStrategy)
        }

        private var effectivePlanKey: LocalizedStringKey {
            accessPlanKey(decision?.effectiveStrategy)
        }

        private func accessPlanKey(_ strategy: DocumentAccessStrategy?) -> LocalizedStringKey {
            switch strategy {
            case .some(.none):
                return "Document Not Used"
            case .some(.context):
                return "Automatic Context"
            case .some(.navigate):
                return "PDF Navigation"
            case .some(.contextThenNavigate):
                return "Context + PDF Navigation"
            case nil:
                return "RETRIEVAL"
            }
        }

        private var plannerDetailText: String? {
            switch decision?.decidedBy {
            case .appleFoundationModel:
                return String(localized: "Apple Foundation Models") + " · " + String(localized: "on-device")
            case .rulesFallback:
                return String(localized: "Rules Fallback")
            case .none:
                return nil
            }
        }

        private var modeText: String {
            guard let info else { return "Pending" }
            switch info.method {
            case .fullContent:
                return "Full Document"
            case .rag:
                return "Smart Retrieval"
            case .none:
                return "Pending"
            }
        }

        private var stageText: String {
            guard let info else { return "Deciding" }
            switch info.stage {
            case .deciding:
                return "Deciding"
            case .chosen:
                return "Chosen"
            case .injected:
                return "Injected"
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
#if os(macOS)
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
#else
                    Image(systemName: info?.stage == .deciding ? "hourglass" : "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentColor)
#endif

                    VStack(alignment: .leading, spacing: 4) {
                        Text(headerKey)
                            .textCase(.uppercase)
#if os(macOS)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(Color.primary.opacity(0.6))
#else
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
#endif
                        if decision != nil {
                            HStack(spacing: 4) {
                                Text(verbatim: decisionSourceText)
                                Text(verbatim: "·")
                                Text(requestedPlanKey)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(decision?.decidedBy == .appleFoundationModel ? Color.cyan : .primary)
                            .textCase(.uppercase)
                            .multilineTextAlignment(.leading)
                        } else if let retrievalStatusText {
                            Text(LocalizedStringKey(retrievalStatusText))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }

                        if decision?.wasCapabilityAdjusted == true {
                            HStack(spacing: 4) {
                                Text("Capability Adjusted")
                                Text(verbatim: "·")
                                Text(effectivePlanKey)
                            }
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textCase(.uppercase)
                        }

                        if decision != nil, let retrievalStatusText {
                            Text(LocalizedStringKey(retrievalStatusText))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if let decision {
                            detailRow(String(localized: "Dataset"), decision.datasetName)
                            if let plannerDetailText {
                                detailRow(String(localized: "Planner"), plannerDetailText)
                            }
                            detailRow(
                                String(localized: "Requested Plan"),
                                localizedAccessPlan(decision.requestedStrategy)
                            )
                            if decision.wasCapabilityAdjusted {
                                detailRow(
                                    String(localized: "Effective Plan"),
                                    localizedAccessPlan(decision.effectiveStrategy)
                                )
                            }
                        }
                        if let info {
                            if decision == nil {
                                detailRow(String(localized: "Dataset"), info.datasetName)
                            }
                            detailRow(String(localized: "Mode"), modeText)
                            detailRow(String(localized: "Stage"), stageText)
                            detailRow(String(localized: "Requested chunks"), "\(info.requestedMaxChunks)")
                            detailRow(String(localized: "Retrieved chunks"), "\(info.retrievedChunkCount)")
                            detailRow(String(localized: "Injected chunks"), "\(info.injectedChunkCount)")
                            detailRow(String(localized: "Trimmed chunks"), "\(info.trimmedChunkCount)")
                            detailRow(String(localized: "Configured context"), "\(info.configuredContextTokens) tok")
                            detailRow(String(localized: "Reserved for response"), "\(info.reservedResponseTokens) tok")
                            detailRow(String(localized: "Usable prompt budget"), "\(info.contextBudgetTokens) tok")
                            detailRow(String(localized: "Injected context"), "\(info.injectedContextTokens) tok")
                            if let fullEstimate = info.fullContentEstimateTokens {
                                detailRow(String(localized: "Full document estimate"), "\(fullEstimate) tok")
                            }
                            if info.partialChunkInjected {
                                Text("Only a partial excerpt of the top chunk fit in the prompt budget.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Text(info.decisionReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Self.containerRadius, style: .continuous)
                    .fill(surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.containerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: Self.borderWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: Self.containerRadius, style: .continuous))
            .onTapGesture {
                isExpanded.toggle()
            }
            .accessibilityAddTraits(.isButton)
        }

        @ViewBuilder
        private func detailRow(_ label: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
            }
        }

        private func localizedAccessPlan(_ strategy: DocumentAccessStrategy) -> String {
            switch strategy {
            case .none:
                return String(localized: "Document Not Used")
            case .context:
                return String(localized: "Automatic Context")
            case .navigate:
                return String(localized: "PDF Navigation")
            case .contextThenNavigate:
                return String(localized: "Context + PDF Navigation")
            }
        }
    }

    // Helper functions for global indexing overlay
    private func globalStageColor(_ stage: DatasetProcessingStage, current: DatasetProcessingStage) -> Color {
        switch (stage, current) {
        case (.extracting, .extracting), (.compressing, .compressing), (.embedding, .embedding):
            return .blue
        case (.extracting, .compressing), (.extracting, .embedding), (.compressing, .embedding):
            return .green
        default:
            return .gray.opacity(0.3)
        }
    }

    private func globalStageLabel(_ stage: DatasetProcessingStage) -> String {
        switch stage {
        case .extracting: return "Extracting"
        case .compressing: return "Compressing"
        case .embedding: return "Embedding"
        case .completed: return "Ready"
        case .failed: return "Failed"
        }
    }

}
#endif
