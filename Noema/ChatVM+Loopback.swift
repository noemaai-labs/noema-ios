import SwiftUI
import Foundation
import RelayKit
import Combine
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import NoemaPackages
#if canImport(MLX)
import MLX
#endif

#if canImport(UIKit) || os(macOS)
typealias APILoopbackToolCall = ToolCall

extension ChatVM {
    func parse(_ text: String, toolCalls: [ToolCall]? = nil) -> [Piece] {
        let codeBlocks = Self.parseCodeBlocks(text)

        // Then parse think tags within each text piece
        var finalPieces: [Piece] = []
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
                    finalPieces.append(.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                    insertedToolFromCodeBlock = true
                }
                // 2) TOOL_CALL:/TOOL_RESULT markers inside code fences
                tmp = codeSub
                while let callRange = tmp.range(of: "TOOL_CALL:") {
                    tmp = tmp[callRange.upperBound...]
                    finalPieces.append(.tool(toolCallIndex))
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
                            finalPieces.append(.tool(toolCallIndex))
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
                    finalPieces.append(.code(code, language: lang))
                }
            case .text(let t):
                // Parse think tags in text
                var rest = t[...]
                while let anchorRange = rest.range(of: noemaToolAnchorToken) {
                    if anchorRange.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<anchorRange.lowerBound])))
                    }
                    rest = rest[anchorRange.upperBound...]
                    finalPieces.append(.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                // Detect inline tool call start(s) and replace with tool box, preserving following text
                while let callTag = rest.range(of: "<tool_call>") {
                    if callTag.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<callTag.lowerBound])))
                    }
                    // Skip over the tool call JSON content
                    rest = rest[callTag.upperBound...]
                    if let end = rest.range(of: "</tool_call>") {
                        rest = rest[end.upperBound...]
                    } else {
                        rest = rest[rest.endIndex...]
                    }
                    // Use the current tool call index and increment for next one
                    finalPieces.append(.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                // Detect TOOL_CALL: inline markers repeatedly and hide JSON until the next tool response marker if present
                while let callRange = rest.range(of: "TOOL_CALL:") {
                    if callRange.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<callRange.lowerBound])))
                    }
                    var after = rest[callRange.upperBound...]
                    if let nextResp = (after.range(of: "<tool_response>") ?? after.range(of: "TOOL_RESULT:")) {
                        rest = after[nextResp.lowerBound...]
                    } else if let nl = after.firstIndex(of: "\n") {
                        rest = after[nl...]
                    } else {
                        rest = rest[rest.endIndex...]
                    }
                    // Use the current tool call index and increment for next one
                    finalPieces.append(.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                // Detect inline tool result JSON markers repeatedly and render tool box instead of raw JSON
                toolLoop: while let toolRange = rest.range(of: "<tool_response>") ?? rest.range(of: "TOOL_RESULT:") {
                    // Emit text before the tool block
                    if toolRange.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<toolRange.lowerBound])))
                    }

                    let markerSlice = rest[toolRange]
                    var remainder = rest[toolRange.upperBound...]
                    var consumedPayload = false

                    if markerSlice.hasPrefix("<tool_response>") {
                        if let end = remainder.range(of: "</tool_response>") {
                            remainder = remainder[end.upperBound...]
                            consumedPayload = true
                        }
                    } else {
                        // Skip TOOL_RESULT JSON payloads. These can be objects or arrays.
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
                                // Unknown payload: drop through to the next newline to avoid leaking JSON.
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
                    finalPieces.append(.tool(toolCallIndex))
                    rest = remainder
                    if !consumedPayload { break toolLoop }
                }
                // Implicit-open reasoning: templates that pre-open <think> in the
                // prompt (DeepSeek-R1, Qwen3 *-Thinking) stream only the reasoning body
                // plus a lone </think>. Synthesize the opening block in that case.
                if let close = rest.range(of: "</think>"),
                   rest.range(of: "<think>").map({ close.lowerBound < $0.lowerBound }) ?? true {
                    finalPieces.append(.think(String(rest[..<close.lowerBound]), done: true))
                    rest = rest[close.upperBound...]
                }
                // Parse all think blocks that remain
                while let s = rest.range(of: "<think>") {
                    if s.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<s.lowerBound])))
                    }
                    rest = rest[s.upperBound...]
                    if let e = rest.range(of: "</think>") {
                        finalPieces.append(.think(String(rest[..<e.lowerBound]), done: true))
                        rest = rest[e.upperBound...]
                    } else {
                        finalPieces.append(.think(String(rest), done: false))
                        rest = rest[rest.endIndex...]
                    }
                }
                if !rest.isEmpty { finalPieces.append(.text(String(rest))) }
            case .think:
                // This shouldn't happen from parseCodeBlocks
                break
            case .tool(_):
                // Tool blocks are handled at render time; ignore here
                break
            case .outputContinuation:
                // Runtime receipts are transcript metadata, never model input.
                break
            }
        }

        return finalPieces
    }

    // Helper to find matching closing brace for a JSON object within a substring,
    // honoring string literals and escape sequences.
    func findMatchingBrace(in text: Substring, startingFrom startIndex: Substring.Index) -> Substring.Index? {
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
            if char == "\"" {
                inString.toggle()
                idx = text.index(after: idx)
                continue
            }
            if !inString {
                if char == "{" {
                    braceCount += 1
                } else if char == "}" {
                    braceCount -= 1
                    if braceCount == 0 {
                        return idx
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    // Helper to find matching closing bracket for a JSON array, honoring strings and escapes
    func findMatchingBracket(in text: Substring, startingFrom startIndex: Substring.Index) -> Substring.Index? {
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

    // Inserts retrieval context inside the current template's user section so BOS/control tokens remain valid.
    // If the template isn't recognized, it falls back to prefixing a "Context:" block.
    nonisolated static func injectContextIntoPrompt(
        original: String,
        context: String,
        kind: ModelKind,
        templateKind: ModelKind?
    ) -> String {
        let note = """
        Use the following information to answer the question. If passages are prefixed with bracketed numbers like [1], [2], cite those numbers. Otherwise cite the source names shown in the context. In <think>...</think>, reason about how each cited passage answers the question before writing the final response.
        """
        let block = note + context + "\n\n"
        let s = original
        switch templateKind ?? kind {
        case .llama3:
            // <|start_header_id|>user<|end_header_id|> ... <|eot_id|>
            let userOpen = "<|start_header_id|>user<|end_header_id|>\n"
            let eot = "<|eot_id|>"
            // Multi-turn prompts may contain many user blocks; inject into the most recent one.
            if let openRange = s.range(of: userOpen, options: .backwards) {
                if let closeRange = s.range(of: eot, range: openRange.upperBound..<s.endIndex) {
                    var out = s
                    out.insert(contentsOf: block, at: closeRange.lowerBound)
                    return out
                }
            }
        case .gemma, .qwen, .smol, .lfm:
            // <|im_start|>user\n ... <|im_end|>
            let userOpen = "<|im_start|>user\n"
            let userClose = "<|im_end|>"
            if let openRange = s.range(of: userOpen, options: .backwards) {
                if let closeRange = s.range(of: userClose, range: openRange.upperBound..<s.endIndex) {
                    var out = s
                    out.insert(contentsOf: block, at: closeRange.lowerBound)
                    return out
                }
            }
        case .mistral:
            // [INST] ... [/INST]
            let open = "[INST]"
            let close = "[/INST]"
            if let openRange = s.range(of: open, options: .backwards) {
                if let closeRange = s.range(of: close, range: openRange.upperBound..<s.endIndex) {
                    var out = s
                    out.insert(contentsOf: "\n" + block, at: closeRange.lowerBound)
                    return out
                }
            }
        case .phi:
            // <|user|> ... <|assistant|>
            let uOpen = "<|user|>"
            let aOpen = "<|assistant|>"
            if let openRange = s.range(of: uOpen, options: .backwards) {
                if let closeRange = s.range(of: aOpen, range: openRange.upperBound..<s.endIndex) {
                    var out = s
                    out.insert(contentsOf: "\n" + block, at: closeRange.lowerBound)
                    return out
                }
            }
        default:
            break
        }
        return block + s
    }

    func injectContextIntoPrompt(original: String, context: String, kind: ModelKind) -> String {
        Self.injectContextIntoPrompt(
            original: original,
            context: context,
            kind: kind,
            templateKind: templateKind()
        )
    }

    /// Full-document RAG injection placed as a STABLE LEADING SYSTEM PREFIX.
    ///
    /// Full-context injection re-runs every turn, but the document text is identical
    /// each turn. If it sits at the tail of the newest user turn (as query-specific RAG
    /// chunks do), its token positions slide back every turn, so llama.cpp / MLX / CoreAI
    /// longest-common-prefix KV reuse diverges before it and the whole document is
    /// re-processed every turn. Prepending it to the system prompt — ahead of the
    /// per-minute date line and everything else — keeps its tokens at fixed positions,
    /// so the prompt-processing KV is computed once and reused on later turns.
    func systemPromptWithFullDocument(_ document: String, baseSystemPrompt: String? = nil) -> String {
        let trimmed = document.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseSystemPrompt ?? systemPromptText
        guard !trimmed.isEmpty else { return base }
        let note = "Reference document for this conversation. Use it to answer the user's questions, citing the source names shown where relevant:"
        let block = note + "\n\n" + trimmed
        return base.isEmpty ? block : block + "\n\n" + base
    }

    private var usesTemplateDrivenLoopbackMessages: Bool {
        guard loadedFormat == .gguf, let url = loadedURL else { return false }
        return TemplateDrivenModelSupport.usesTemplateDrivenMessages(modelURL: url)
    }

    /// Formats whose client applies the model's own chat template to structured
    /// messages, so ChatVM must send history as messages rather than a
    /// pre-templated prompt string (which would be templated a second time).
    private var usesStructuredChatMessages: Bool {
        if loadedFormat == .mlx { return true }
        // CoreAILLMClient re-templates `.plain` input as a single user turn, so a
        // pre-templated prompt string would be wrapped a second time. Sending
        // structured messages lets the client apply its template exactly once and
        // keeps tool calls + results paired in replayed history.
        if loadedFormat == .coreai { return true }
        return usesTemplateDrivenLoopbackMessages
    }

    private func injectContextIntoMessages(_ messages: [ChatMessage], context: String) -> [ChatMessage] {
        let note = """
        Use the following information to answer the question. If passages are prefixed with bracketed numbers like [1], [2], cite those numbers. Otherwise cite the source names shown in the context. In <think>...</think>, reason about how each cited passage answers the question before writing the final response.
        """
        let block = note + context
        var result = messages
        if let userIndex = result.lastIndex(where: { $0.role.lowercased() == "user" }) {
            let merged = result[userIndex].content + "\n\n" + block
            result[userIndex] = ChatMessage(
                role: result[userIndex].role,
                content: merged,
                toolCalls: result[userIndex].toolCalls,
                toolCallId: result[userIndex].toolCallId
            )
            return result
        }
        result.append(ChatMessage(role: "user", content: block))
        return result
    }

    private func normalizedLoopbackRole(_ role: String) -> String {
        let lowered = role.lowercased()
        if lowered == "🧑‍💻".lowercased() { return "user" }
        if lowered == "🤖".lowercased() { return "assistant" }
        return lowered
    }

    private func sanitizedLoopbackContent(_ text: String, role: String) -> String {
        guard role == "assistant" else { return text }
        return text.replacingOccurrences(of: noemaToolAnchorToken, with: "")
    }

    func resolvedLoopbackToolCallID(for call: Msg.ToolCall) -> String {
        if let externalToolCallID = call.externalToolCallID,
           !externalToolCallID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return externalToolCallID
        }
        return call.id.uuidString
    }

    func serializedLoopbackToolCalls(from calls: [Msg.ToolCall]?) -> [APILoopbackToolCall]? {
        guard let calls, !calls.isEmpty else { return nil }
        // These bytes land verbatim inside the rendered prompt as the
        // tool_calls[].function.arguments STRING, where the request-level
        // .sortedKeys pass cannot reach. Unsorted keys follow the per-launch
        // hash seed, which breaks slot-KV prefix reuse across relaunches.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return calls.map { call in
            let requestData = (try? encoder.encode(call.requestParams)) ?? Data("{}".utf8)
            let requestJSON = String(data: requestData, encoding: .utf8) ?? "{}"
            return APILoopbackToolCall(
                id: resolvedLoopbackToolCallID(for: call),
                name: call.toolName,
                arguments: requestJSON
            )
        }
    }

    /// Re-materializes the `tool` role messages that carry tool results so a tool
    /// call *and* its result are replayed into the model context on later turns.
    ///
    /// The saved transcript keeps tool results only inside `Msg.toolCalls[].result`
    /// (the visible assistant text is scrubbed of all tool markers by
    /// `visibleAssistantText`). Without this step, history rebuilt for a new turn
    /// would serialize the assistant's `tool_calls` (the arguments) but never emit
    /// the matching `tool` result messages, so the model would only ever see its own
    /// final answers and "forget" what the tools returned. Inserting a `tool` message
    /// per call lets the existing `pendingToolCallIDs` pairing in `loopbackChatMessages`
    /// attach the results, and also preserves the `tool_calls`⇄`tool` invariant the
    /// chat-completions format expects.
    func historyWithReconstructedToolMessages(_ history: [Msg]) -> [Msg] {
        var result: [Msg] = []
        result.reserveCapacity(history.count)

        for index in history.indices {
            let message = history[index]
            result.append(message)

            guard normalizedLoopbackRole(message.role) == "assistant",
                  let calls = message.toolCalls,
                  !calls.isEmpty else { continue }

            // In-turn continuation already appends an explicit `tool` message right
            // after the assistant; don't duplicate it. This also keeps the function
            // idempotent if applied to an already-reconstructed history.
            let nextIsToolMessage: Bool = {
                let nextIndex = index + 1
                guard history.indices.contains(nextIndex) else { return false }
                return normalizedLoopbackRole(history[nextIndex].role) == "tool"
            }()
            if nextIsToolMessage { continue }

            for call in calls {
                let payload = call.result
                    ?? call.error.map { "Error: \($0)" }
                    ?? "(no tool result was recorded)"
                result.append(Msg(role: "tool", text: payload, timestamp: call.timestamp))
            }
        }

        return result
    }

    func loopbackChatMessages(
        from history: [Msg],
        retrievedContext: String? = nil,
        fullDocumentPlacement: Bool = false,
        systemPromptOverride: String? = nil
    ) -> [ChatMessage]? {
        guard usesStructuredChatMessages else { return nil }

        let trimmedContext = retrievedContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let placeFullDocumentInSystem = fullDocumentPlacement && !trimmedContext.isEmpty
        let toolAwareHistory = historyWithReconstructedToolMessages(history)
        let sanitizedHistory = sanitizedHistoryForTemplateDrivenLoopback(toolAwareHistory)
        // Full-document context goes into the system prompt so it stays a fixed leading
        // prefix the KV cache can reuse across turns; RAG chunks stay in the user turn.
        let baseSystemPrompt = systemPromptOverride ?? systemPromptText
        let systemForRender = placeFullDocumentInSystem
            ? systemPromptWithFullDocument(trimmedContext, baseSystemPrompt: baseSystemPrompt)
            : baseSystemPrompt
        let rendered = prepareForGeneration(messages: sanitizedHistory, system: systemForRender)
        guard case .messages(let renderedMessages) = rendered else { return nil }

        let sourceMessages = sanitizedHistory.filter { normalizedLoopbackRole($0.role) != "system" }
        var sourceIndex = 0
        var pendingToolCallIDs: [String] = []
        var chatMessages: [ChatMessage] = []
        chatMessages.reserveCapacity(renderedMessages.count)

        for renderedMessage in renderedMessages {
            let renderedRole = normalizedLoopbackRole(renderedMessage.role)
            if renderedRole == "system" {
                chatMessages.append(
                    ChatMessage(
                        role: renderedMessage.role,
                        content: renderedMessage.content
                    )
                )
                continue
            }

            guard sourceIndex < sourceMessages.count else {
                chatMessages.append(
                    ChatMessage(
                        role: renderedMessage.role,
                        content: sanitizedLoopbackContent(renderedMessage.content, role: renderedRole)
                    )
                )
                continue
            }

            let sourceMessage = sourceMessages[sourceIndex]
            sourceIndex += 1
            let sourceRole = normalizedLoopbackRole(sourceMessage.role)
            if sourceRole != renderedRole {
                Task {
                    await logger.log("[Loopback] role mismatch while preserving tool metadata source=\(sourceRole) rendered=\(renderedRole)")
                }
            }

            let toolCalls = sourceRole == "assistant"
                ? serializedLoopbackToolCalls(from: sourceMessage.toolCalls)
                : nil
            if sourceRole == "assistant", let sourceToolCalls = sourceMessage.toolCalls {
                pendingToolCallIDs.append(contentsOf: sourceToolCalls.map(resolvedLoopbackToolCallID))
            }

            let toolCallId: String? = {
                guard sourceRole == "tool", !pendingToolCallIDs.isEmpty else { return nil }
                return pendingToolCallIDs.removeFirst()
            }()

            chatMessages.append(
                ChatMessage(
                    role: renderedMessage.role,
                    content: sanitizedLoopbackContent(renderedMessage.content, role: renderedRole),
                    toolCalls: toolCalls,
                    toolCallId: toolCallId
                )
            )
        }

        if !placeFullDocumentInSystem,
           let retrievedContext,
           !retrievedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatMessages = injectContextIntoMessages(chatMessages, context: retrievedContext)
        }

        return chatMessages
    }

    func sanitizedHistoryForTemplateDrivenLoopback(_ history: [Msg]) -> [Msg] {
        guard let last = history.last else { return history }

        let normalizedRole = last.role.lowercased()
        let isAssistantPlaceholder = (normalizedRole == "assistant" || normalizedRole == "🤖")
            && last.streaming
            && last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isAssistantPlaceholder else { return history }

        Task {
            await logger.log("[Loopback] stripped trailing assistant placeholder for template-driven request")
        }

        var sanitized = history
        sanitized.removeLast()
        return sanitized
    }

    /// Tool schemas to attach to the request `tools` array so the model calls tools
    /// natively via its own chat template. GGUF only (llama.cpp server Jinja reliably
    /// renders them). MLX is intentionally excluded: several mlx-swift-lm VLM processors
    /// (e.g. Qwen35) drop input.tools, so MLX uses prose tool guidance + the text parser
    /// instead. Other local formats also get nil here.
    func nativeToolSpecs() async -> [ToolSpec]? {
        guard loadedFormat == .gguf else { return nil }
        let specs = await fetchEnabledToolSpecs()
        return specs.isEmpty ? nil : specs
    }

    func structuredLoopbackInput(
        for history: [Msg],
        retrievedContext: String? = nil,
        tools: [ToolSpec]? = nil,
        fullDocumentPlacement: Bool = false,
        systemPromptOverride: String? = nil
    ) -> LLMInput? {
        guard let chatMessages = loopbackChatMessages(
            from: history,
            retrievedContext: retrievedContext,
            fullDocumentPlacement: fullDocumentPlacement,
            systemPromptOverride: systemPromptOverride
        ) else {
            return nil
        }
        return LLMInput(.messages(chatMessages), generationOptions: LLMGenerationOptions(tools: tools))
    }

    func structuredLoopbackMultimodalInput(
        for history: [Msg],
        imagePaths: [String],
        retrievedContext: String? = nil,
        tools: [ToolSpec]? = nil,
        fullDocumentPlacement: Bool = false,
        systemPromptOverride: String? = nil
    ) -> LLMInput? {
        guard let chatMessages = loopbackChatMessages(
            from: history,
            retrievedContext: retrievedContext,
            fullDocumentPlacement: fullDocumentPlacement,
            systemPromptOverride: systemPromptOverride
        ) else {
            return nil
        }
        return LLMInput.multimodal(messages: chatMessages, imagePaths: imagePaths, generationOptions: LLMGenerationOptions(tools: tools))
    }

    /// Creates a fresh, bounded request that resumes the current assistant
    /// bubble after llama.cpp reports `finish_reason: length`. This is the
    /// fallback for runtimes where native KV context shifting is unavailable.
    /// It is intentionally a lightweight answer checkpoint: native tool schemas
    /// and a new reasoning pass would consume most of a small context window and
    /// caused repeated near-empty resumes.
    func automaticOutputContinuationInput(
        history: [Msg],
        assistantMessageID: UUID,
        partialAssistantText: String,
        systemPrompt: String
    ) async -> LLMInput? {
        guard loadedFormat == .gguf,
              let plan = planAutomaticOutputContinuation(
                history: history,
                assistantMessageID: assistantMessageID,
                partialAssistantText: partialAssistantText,
                systemPrompt: systemPrompt
              ),
              !plan.requiresStop else {
            return nil
        }

        if let structured = structuredLoopbackInput(
            for: plan.history,
            tools: [],
            systemPromptOverride: systemPrompt
        ) {
            return LLMInput(
                structured.content,
                generationOptions: LLMGenerationOptions(
                    reasoningEnabled: false,
                    thinkingBudgetTokens: 0,
                    tools: []
                )
            )
        }

        let prompt = buildPrompt(
            kind: currentKind,
            history: plan.history,
            systemPromptOverride: systemPrompt
        ).0
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return LLMInput(
            .plain(prompt),
            generationOptions: LLMGenerationOptions(
                reasoningEnabled: false,
                thinkingBudgetTokens: 0,
                tools: []
            )
        )
    }

    /// Rebuilds a plain post-tool prompt without losing the turn's retrieval context.
    /// The exact system prompt captured at send time is reused so llama.cpp sees the
    /// same leading tokens before and after the tool call.
    func plainToolContinuationPrompt(
        history: [Msg],
        retrievedContext: String?,
        fullDocumentPlacement: Bool,
        systemPromptOverride: String
    ) -> String {
        let trimmedContext = retrievedContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let placeFullDocumentInSystem = fullDocumentPlacement && !trimmedContext.isEmpty
        let systemPrompt = placeFullDocumentInSystem
            ? systemPromptWithFullDocument(trimmedContext, baseSystemPrompt: systemPromptOverride)
            : systemPromptOverride
        var prompt = buildPrompt(
            kind: currentKind,
            history: history,
            systemPromptOverride: systemPrompt
        ).0
        if !placeFullDocumentInSystem, !trimmedContext.isEmpty {
            prompt = injectContextIntoPrompt(original: prompt, context: trimmedContext, kind: currentKind)
        }
        return prompt
    }

    /// Creates the hidden transcript used for the first post-tool continuation.
    /// `history` is the pre-stream snapshot, so copy the live assistant tool-call
    /// metadata into it before appending the matching tool result.
    func historyForToolContinuation(
        from history: [Msg],
        assistantIndex: Int,
        assistantText: String,
        assistantToolCalls: [Msg.ToolCall]?,
        toolResult: String,
        timestamp: Date = Date()
    ) -> [Msg] {
        var result = history
        if result.indices.contains(assistantIndex) {
            result[assistantIndex].text = assistantText
            result[assistantIndex].toolCalls = assistantToolCalls
        }
        result.append(Msg(role: "tool", text: toolResult, timestamp: timestamp))
        return result
    }
}
#endif
