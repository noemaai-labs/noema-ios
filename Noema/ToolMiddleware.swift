// ToolMiddleware.swift
#if os(iOS) || os(visionOS) || os(macOS)
import Foundation

// MARK: - Scan/Dispatch Guards (per-message)
// Use an actor to synchronize access to per-message scan/dispatch state.
actor ToolScanRegistry {
    static let shared = ToolScanRegistry()
    private var openTagLoggedForMessage: Set<Int> = []
    private var dispatchedSignaturesByMessage: [Int: Set<String>] = [:]
    private var placeholderSignaturesByMessage: [Int: Set<String>] = [:]

    func shouldLogOpenTagOnce(messageIndex: Int?) -> Bool {
        guard let idx = messageIndex else { return false }
        if openTagLoggedForMessage.contains(idx) { return false }
        openTagLoggedForMessage.insert(idx)
        return true
    }

    func hasDispatched(_ signature: String, for messageIndex: Int?) -> Bool {
        guard let idx = messageIndex else { return false }
        return dispatchedSignaturesByMessage[idx]?.contains(signature) ?? false
    }

    func markDispatched(_ signature: String, for messageIndex: Int?) {
        guard let idx = messageIndex else { return }
        var set = dispatchedSignaturesByMessage[idx] ?? []
        set.insert(signature)
        dispatchedSignaturesByMessage[idx] = set
    }

    func shouldInsertPlaceholder(_ signature: String, for messageIndex: Int?) -> Bool {
        guard let idx = messageIndex else { return false }
        var set = placeholderSignaturesByMessage[idx] ?? []
        if set.contains(signature) { return false }
        set.insert(signature)
        placeholderSignaturesByMessage[idx] = set
        return true
    }

    func clearPlaceholder(_ signature: String, for messageIndex: Int?) {
        guard let idx = messageIndex else { return }
        var set = placeholderSignaturesByMessage[idx] ?? []
        set.remove(signature)
        placeholderSignaturesByMessage[idx] = set
    }

    func clearPlaceholderSignatures(withPrefix prefix: String, for messageIndex: Int?) {
        guard let idx = messageIndex else { return }
        var set = placeholderSignaturesByMessage[idx] ?? []
        set = set.filter { !$0.hasPrefix(prefix) }
        placeholderSignaturesByMessage[idx] = set
    }
}

private let toolPrefix = "TOOL_CALL:"

// Returns true if the given index lies within an open <think>…</think> block in textBuffer
private func isIndexInsideOpenThink(_ textBuffer: String, at index: String.Index) -> Bool {
    // Consider only the prefix up to the index
    let prefix = textBuffer[..<index]
    let lastOpen = prefix.range(of: "<think>", options: .backwards)
    let lastClose = prefix.range(of: "</think>", options: .backwards)
    if let o = lastOpen {
        if let c = lastClose { return o.lowerBound > c.lowerBound }
        return true
    }
    return false
}

// Tool metadata for UI display
struct ToolMetadata {
    let displayName: String
    let iconName: String
}

private let toolMetadataMap: [String: ToolMetadata] = [
    "noema.web.retrieve": ToolMetadata(displayName: "Web Search", iconName: "globe"),
    "noema.python.execute": ToolMetadata(displayName: "Python", iconName: "chevron.left.forwardslash.chevron.right"),
    "noema.memory": ToolMetadata(displayName: "Memory", iconName: "bookmark"),
    "noema.dataset.search": ToolMetadata(displayName: "Dataset Search", iconName: "doc.text.magnifyingglass"),
    "noema.code.analyze": ToolMetadata(displayName: "Code Analysis", iconName: "curlybraces"),
    "noema.math.calculate": ToolMetadata(displayName: "Calculator", iconName: "function"),
    "noema.units.convert": ToolMetadata(displayName: "Unit Converter", iconName: "arrow.left.arrow.right"),
    "noema.image.analyze": ToolMetadata(displayName: "Image Analysis", iconName: "photo"),
    "noema.file.read": ToolMetadata(displayName: "File Reader", iconName: "doc"),
    "noema.system.info": ToolMetadata(displayName: "System Info", iconName: "info.circle"),
]

// Normalize various aliases emitted by different models to our canonical names
private func normalizeToolName(_ raw: String) -> String {
    // Web search aliases
    if raw == "noema.web.retrieve" { return "noema.web.retrieve" }
    if raw == "noema_web_retrieve" { return "noema.web.retrieve" }
    if raw == "Web_Search" || raw == "WEB_SEARCH" { return "noema.web.retrieve" }
    // Python aliases
    if raw == "noema.python.execute" { return "noema.python.execute" }
    if raw == "noema_python_execute" { return "noema.python.execute" }
    if raw == "noema.memory" { return "noema.memory" }
    if raw == "noema_memory" { return "noema.memory" }
    if raw == "noema.math.calculate" { return "noema.math.calculate" }
    if raw == "noema_math_calculate" { return "noema.math.calculate" }
    if raw == "noema.units.convert" { return "noema.units.convert" }
    if raw == "noema_units_convert" { return "noema.units.convert" }
    let lower = raw.lowercased()
    if lower == "web_search" || lower == "web.search" || lower == "websearch" || lower == "web-search" {
        return "noema.web.retrieve"
    }
    if lower == "python" || lower == "python_execute" || lower == "code_execute"
        || lower == "run_python" || lower == "execute_python" || lower == "python.execute"
        || lower == "code_interpreter" || lower == "code-interpreter" {
        return "noema.python.execute"
    }
    if lower == "memory" || lower == "memory_tool" || lower == "memorytool"
        || lower == "persistent_memory" || lower == "persistent-memory" {
        return "noema.memory"
    }
    if lower == "calculator" || lower == "calculate" || lower == "math"
        || lower == "math_calculate" || lower == "math.calculate" || lower == "math-calculate" {
        return "noema.math.calculate"
    }
    if lower == "unit_converter" || lower == "unit-converter" || lower == "unitconverter"
        || lower == "units_convert" || lower == "units.convert" || lower == "convert_units" {
        return "noema.units.convert"
    }
    return raw
}

private func getToolMetadata(_ toolName: String) -> ToolMetadata {
    let canonical = normalizeToolName(toolName)
    return toolMetadataMap[canonical] ?? ToolMetadata(
        displayName: canonical.components(separatedBy: ".").last?.capitalized ?? "Tool",
        iconName: "wrench.and.screwdriver"
    )
}

private enum ToolRequestStatus {
    case requesting
    case ready
    case failed
}

private func normalizedRequestStatus(from raw: String?) -> ToolRequestStatus? {
    guard let raw else { return nil }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "requesting":
        return .requesting
    case "ready", "executing", "complete", "completed", "success", "succeeded":
        return .ready
    case "failed", "failure", "error":
        return .failed
    default:
        return nil
    }
}

enum EmbeddedToolHandlingMode: Equatable {
    case dispatchIfAllowed
    case scrubOnly
}

struct EmbeddedToolInterceptResult {
    let token: String?
    // When `token` is non-nil, `cleanedText` preserves the tool position by
    // inserting `noemaToolAnchorToken` at the removal site. Scrub-only results
    // never inject a new anchor.
    let cleanedText: String
}

func isDanglingPlaceholderToolCall(_ call: ChatVM.Msg.ToolCall) -> Bool {
    call.phase == .requesting &&
    call.externalToolCallID == nil &&
    call.requestParams.isEmpty &&
    call.result == nil &&
    call.error == nil
}

private func removingLastToolAnchors(from text: String, count: Int) -> String {
    guard count > 0 else { return text }
    var output = text
    var remaining = count
    while remaining > 0,
          let range = output.range(of: noemaToolAnchorToken, options: .backwards) {
        output.removeSubrange(range)
        remaining -= 1
    }
    return output
}

@MainActor
@discardableResult
func pruneDanglingPlaceholderToolCalls(
    messageIndex: Int?,
    chatVM: ChatVM?,
    preferredText: String? = nil
) async -> String? {
    guard let messageIndex,
          let chatVM,
          chatVM.streamMsgs.indices.contains(messageIndex) else {
        return preferredText
    }

    let originalToolCalls = chatVM.streamMsgs[messageIndex].toolCalls ?? []
    let danglingPlaceholders = originalToolCalls.filter(isDanglingPlaceholderToolCall)
    let baseText = preferredText ?? chatVM.streamMsgs[messageIndex].text

    guard !danglingPlaceholders.isEmpty else {
        if let preferredText {
            chatVM.streamMsgs[messageIndex].text = preferredText
            return preferredText
        }
        return baseText
    }

    for call in danglingPlaceholders {
        await ToolScanRegistry.shared.clearPlaceholderSignatures(
            withPrefix: normalizeToolName(call.toolName),
            for: messageIndex
        )
    }

    let filteredToolCalls = originalToolCalls.filter { !isDanglingPlaceholderToolCall($0) }
    let cleanedText = removingLastToolAnchors(from: baseText, count: danglingPlaceholders.count)

    chatVM.streamMsgs[messageIndex].toolCalls = filteredToolCalls.isEmpty ? nil : filteredToolCalls
    chatVM.streamMsgs[messageIndex].text = cleanedText
    return cleanedText
}

private let placeholderMetadataKeys: Set<String> = [
    "tool", "tool_name", "name",
    "arguments", "args",
    "id", "tool_call_id", "toolCallID",
    "request_status", "requestStatus", "phase",
    "error"
]

private func placeholderSignature(
    for canonicalTool: String,
    externalToolCallID: String? = nil,
    arguments: [String: Any] = [:]
) -> String {
    if let externalToolCallID,
       !externalToolCallID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "\(canonicalTool)#id=\(externalToolCallID)"
    }
    let keys = arguments.keys.sorted()
    if keys.isEmpty { return canonicalTool }
    return "\(canonicalTool)#keys=\(keys.joined(separator: ","))"
}

private func extractPlaceholderArgumentKeys(from rawFragment: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #""([^"]+)"\s*:"#) else { return [] }
    let nsRange = NSRange(rawFragment.startIndex..., in: rawFragment)
    let keys = regex.matches(in: rawFragment, range: nsRange).compactMap { match -> String? in
        guard match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: rawFragment) else { return nil }
        let key = String(rawFragment[range])
        return placeholderMetadataKeys.contains(key) ? nil : key
    }
    return Array(Set(keys)).sorted()
}

private func placeholderSignature(
    for canonicalTool: String,
    rawFragment: String
) -> String {
    let keys = extractPlaceholderArgumentKeys(from: rawFragment)
    if keys.isEmpty { return canonicalTool }
    return "\(canonicalTool)#keys=\(keys.joined(separator: ","))"
}

@MainActor
private func insertToolPlaceholderIfNeeded(
    messageIndex: Int?,
    chatVM: ChatVM?,
    toolName: String,
    rawFragment: String,
    externalToolCallID: String? = nil
) async {
    let signature: String
    if let externalToolCallID,
       !externalToolCallID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        signature = placeholderSignature(for: toolName, externalToolCallID: externalToolCallID)
    } else {
        signature = placeholderSignature(for: toolName, rawFragment: rawFragment)
    }
    guard await ToolScanRegistry.shared.shouldInsertPlaceholder(signature, for: messageIndex) else { return }
    _ = upsertToolCall(
        messageIndex: messageIndex,
        chatVM: chatVM,
        toolName: toolName,
        requestParams: [:],
        phase: .requesting
    )
    await logger.log("[Tool] Placeholder tool box inserted for \(toolName)")
}

@MainActor
@discardableResult
private func upsertToolCall(
    messageIndex: Int?,
    chatVM: ChatVM?,
    toolName: String,
    requestParams: [String: AnyCodable],
    phase: ChatVM.Msg.ToolCallPhase,
    externalToolCallID: String? = nil,
    result: String? = nil,
    error: String? = nil
) -> ChatVM.Msg.ToolCall? {
    guard let messageIndex,
          let chatVM,
          chatVM.streamMsgs.indices.contains(messageIndex) else {
        return nil
    }

    if chatVM.streamMsgs[messageIndex].toolCalls == nil {
        chatVM.streamMsgs[messageIndex].toolCalls = []
    }

    let metadata = getToolMetadata(toolName)
    var toolCalls = chatVM.streamMsgs[messageIndex].toolCalls ?? []
    let existingIndex: Int? = {
        if let externalToolCallID, !externalToolCallID.isEmpty,
           let matched = toolCalls.lastIndex(where: { $0.externalToolCallID == externalToolCallID }) {
            return matched
        }
        return toolCalls.lastIndex(where: {
            ($0.toolName == toolName || $0.toolName == "tool.call") &&
            $0.phase.isInFlight
        })
    }()

    let existing = existingIndex.flatMap { toolCalls[$0] }
    if let existing,
       (existing.phase == .completed || existing.phase == .failed),
       phase.isInFlight {
        return existing
    }

    if existingIndex == nil,
       phase.isInFlight,
       let terminalMatchIndex = toolCalls.lastIndex(where: {
           $0.toolName == toolName &&
           $0.requestParams == requestParams &&
           ($0.phase == .completed || $0.phase == .failed)
       }) {
        return toolCalls[terminalMatchIndex]
    }

    var mergedParams = existing?.requestParams ?? [:]
    for (key, value) in requestParams {
        mergedParams[key] = value
    }

    let updated = ChatVM.Msg.ToolCall(
        id: existing?.id ?? UUID(),
        toolName: toolName,
        displayName: metadata.displayName,
        iconName: metadata.iconName,
        requestParams: mergedParams,
        phase: phase,
        externalToolCallID: externalToolCallID ?? existing?.externalToolCallID,
        result: result,
        error: error,
        timestamp: existing?.timestamp ?? Date()
    )

    if let existingIndex {
        toolCalls[existingIndex] = updated
    } else {
        toolCalls.append(updated)
        chatVM.streamMsgs[messageIndex].text.append(noemaToolAnchorToken)
    }
    chatVM.streamMsgs[messageIndex].toolCalls = toolCalls
    return updated
}

private func displayParams(from arguments: [String: Any]) -> [String: AnyCodable] {
    arguments.reduce(into: [:]) { acc, pair in
        acc[pair.key] = AnyCodable(pair.value)
    }
}

private func normalizedDisplayArguments(_ arguments: [String: Any]) -> [String: Any] {
    var normalizedArgs = arguments
    if let topk = normalizedArgs.removeValue(forKey: "top_k") { normalizedArgs["count"] = topk }
    if let safeSearch = normalizedArgs.removeValue(forKey: "safe_search") { normalizedArgs["safesearch"] = safeSearch }
    return normalizedArgs
}

@MainActor
private func finalizedExecutionArguments(
    for canonicalTool: String,
    from displayArguments: [String: Any],
    messageIndex: Int?,
    chatVM: ChatVM?
) -> [String: Any]? {
    var normalizedArgs = displayArguments

    if canonicalTool == "noema.web.retrieve" {
        if normalizedArgs["count"] == nil { normalizedArgs["count"] = 3 }
        if normalizedArgs["safesearch"] == nil { normalizedArgs["safesearch"] = "moderate" }
        if let s = normalizedArgs["safesearch"] as? String {
            let allowed = ["off", "moderate", "strict"]
            if !allowed.contains(s.lowercased()) { normalizedArgs["safesearch"] = "moderate" }
        }
        if normalizedArgs["query"] == nil || (normalizedArgs["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            if let chatVM, let idx = messageIndex {
                var i = idx
                var priorUser = ""
                while i >= 0 {
                    if chatVM.streamMsgs.indices.contains(i) {
                        let role = chatVM.streamMsgs[i].role.lowercased()
                        if role == "user" || role == "🧑‍💻" {
                            priorUser = chatVM.streamMsgs[i].text
                            break
                        }
                    }
                    i -= 1
                }
                if !priorUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    normalizedArgs["query"] = priorUser
                }
            }
        }
        if let q = normalizedArgs["query"] as? String {
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "..." { return nil }
        }
    }

    if canonicalTool == "noema.python.execute" {
        guard let code = normalizedArgs["code"] as? String,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
    }

    return normalizedArgs
}

@MainActor
func interceptToolCallIfPresent(_ line: String, messageIndex: Int? = nil, chatVM: ChatVM? = nil) async -> (String, String?)? {
    guard line.hasPrefix(toolPrefix) else { return nil }

    // Extract JSON block and preserve any trailing text after the closing brace
    let afterPrefix = String(line.dropFirst(toolPrefix.count))
    guard let open = afterPrefix.firstIndex(of: "{"),
          let close = findMatchingBrace(in: afterPrefix, startingFrom: open) else {
        // Incomplete JSON – wait for more tokens
        return nil
    }
    let jsonPart = String(afterPrefix[open...close])
    let trailingStart = afterPrefix.index(after: close)
    let trailingRaw = afterPrefix[trailingStart...]
    let trailing = String(trailingRaw).trimmingCharacters(in: .whitespacesAndNewlines)

    await logger.log("[Tool] TOOL_CALL detected: \(jsonPart)")

    struct Call: Decodable {
        let tool: String
        let args: [String: AnyCodable]
        let externalToolCallID: String?
        let requestStatus: ToolRequestStatus?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case tool
            case toolName
            case name
            case args
            case arguments
            case id
            case toolCallID
            case requestStatus
            case phase
            case error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let tool = try container.decodeIfPresent(String.self, forKey: .tool) {
                self.tool = tool
            } else if let toolName = try container.decodeIfPresent(String.self, forKey: .toolName) {
                self.tool = toolName
            } else {
                self.tool = try container.decode(String.self, forKey: .name)
            }

            let externalToolCallID =
                try container.decodeIfPresent(String.self, forKey: .toolCallID)
                ?? container.decodeIfPresent(String.self, forKey: .id)
            self.externalToolCallID = externalToolCallID

            let statusRaw =
                try container.decodeIfPresent(String.self, forKey: .requestStatus)
                ?? container.decodeIfPresent(String.self, forKey: .phase)
            requestStatus = normalizedRequestStatus(from: statusRaw)
            error = try container.decodeIfPresent(String.self, forKey: .error)

            if let args = try? container.decode([String: AnyCodable].self, forKey: .args) {
                self.args = args
            } else if let args = try? container.decode([String: AnyCodable].self, forKey: .arguments) {
                self.args = args
            } else if let argsString = try container.decodeIfPresent(String.self, forKey: .args)
                        ?? container.decodeIfPresent(String.self, forKey: .arguments),
                      let data = argsString.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.args = obj.mapValues(AnyCodable.init)
            } else {
                self.args = [:]
            }
        }
    }
    guard let data = jsonPart.data(using: .utf8) else {
        return ("TOOL_RESULT: {\"code\":\"PARSE\",\"message\":\"Invalid encoding\"}", trailing.isEmpty ? nil : trailing)
    }
    
    do {
        let call = try JSONDecoder().decode(Call.self, from: data)
        let canonicalTool = normalizeToolName(call.tool)
        let requestStatus = call.requestStatus
        let displayArguments = normalizedDisplayArguments(call.args.mapValues { $0.value })
        let placeholderSig = placeholderSignature(
            for: canonicalTool,
            externalToolCallID: call.externalToolCallID,
            arguments: displayArguments
        )
        let initialDisplayParams = displayParams(from: displayArguments)

        let initialPhase: ChatVM.Msg.ToolCallPhase = {
            switch requestStatus {
            case .requesting:
                return .requesting
            case .failed:
                return .failed
            case .ready, .none:
                return .executing
            }
        }()

        let toolCall = upsertToolCall(
            messageIndex: messageIndex,
            chatVM: chatVM,
            toolName: canonicalTool,
            requestParams: initialDisplayParams,
            phase: initialPhase,
            externalToolCallID: call.externalToolCallID,
            result: nil,
            error: requestStatus == .failed ? (call.error ?? "Tool request failed") : nil
        )

        if requestStatus != .requesting {
            await ToolScanRegistry.shared.clearPlaceholder(placeholderSig, for: messageIndex)
        }

        if requestStatus == .requesting {
            return nil
        }

        if requestStatus == .failed {
            await ToolScanRegistry.shared.clearPlaceholder(placeholderSig, for: messageIndex)
            return nil
        }

        guard let normalizedArgs = finalizedExecutionArguments(
            for: canonicalTool,
            from: displayArguments,
            messageIndex: messageIndex,
            chatVM: chatVM
        ) else {
            return nil
        }

        let displayParamsForExecution = displayParams(from: normalizedArgs)
        _ = upsertToolCall(
            messageIndex: messageIndex,
            chatVM: chatVM,
            toolName: canonicalTool,
            requestParams: displayParamsForExecution,
            phase: .executing,
            externalToolCallID: call.externalToolCallID,
            result: nil,
            error: nil
        ) ?? toolCall

        guard let tool = ToolRegistry.shared.tool(named: canonicalTool) else {
            await logger.log("[Tool] Unknown tool: \(canonicalTool)")
            _ = upsertToolCall(
                messageIndex: messageIndex,
                chatVM: chatVM,
                toolName: canonicalTool,
                requestParams: displayParamsForExecution,
                phase: .failed,
                externalToolCallID: call.externalToolCallID,
                result: nil,
                error: "Tool not registered"
            )
            await ToolScanRegistry.shared.clearPlaceholder(placeholderSig, for: messageIndex)
            return ("TOOL_RESULT: {\"code\":\"UNKNOWN_TOOL\",\"message\":\"Tool not registered\"}", trailing.isEmpty ? nil : trailing)
        }
        
        // Use normalized args for execution; clamp web search count to a hard maximum of 5 regardless of input
        var clampedArgs = normalizedArgs
        if canonicalTool == "noema.web.retrieve" {
            if let rawCount = clampedArgs["count"] as? Int {
                clampedArgs["count"] = max(1, min(rawCount, 5))
            } else if let rawCountString = clampedArgs["count"] as? String, let parsed = Int(rawCountString) {
                clampedArgs["count"] = max(1, min(parsed, 5))
            }
        }
        // De-dupe execution using a stable signature per message
        if let sigData = try? JSONSerialization.data(withJSONObject: ["tool": canonicalTool, "args": clampedArgs], options: [.sortedKeys]),
           let signature = String(data: sigData, encoding: .utf8) {
            if await ToolScanRegistry.shared.hasDispatched(signature, for: messageIndex) {
                return nil
            }
        }

        if ToolDryRunSupport.isEnabled {
            let outString = ToolDryRunSupport.resultString(toolName: canonicalTool, arguments: clampedArgs)
            await logger.log("[Tool] Dry-run recorded \(canonicalTool) with args: \(clampedArgs)")
            if let sigData = try? JSONSerialization.data(withJSONObject: ["tool": canonicalTool, "args": clampedArgs], options: [.sortedKeys]),
               let signature = String(data: sigData, encoding: .utf8) {
                await ToolScanRegistry.shared.markDispatched(signature, for: messageIndex)
            }
            _ = upsertToolCall(
                messageIndex: messageIndex,
                chatVM: chatVM,
                toolName: canonicalTool,
                requestParams: displayParamsForExecution,
                phase: .completed,
                externalToolCallID: call.externalToolCallID,
                result: outString,
                error: nil
            )
            await ToolScanRegistry.shared.clearPlaceholder(placeholderSig, for: messageIndex)
            return ("TOOL_RESULT: \(outString)", trailing.isEmpty ? nil : trailing)
        }

        await logger.log("[Tool] Invoking \(canonicalTool) with args: \(clampedArgs)")
        let argsData = try JSONSerialization.data(withJSONObject: clampedArgs)

        // Respect cancellation before starting any tool work
        if Task.isCancelled { return nil }
        await Task.yield()

        // Check for direct handler for faster execution
        let outData: Data
        if canonicalTool == "noema.web.retrieve" {
            let contextLimit = chatVM?.contextLimit ?? 4096
            outData = await handle_noema_web_retrieve(argsData, contextLimit: contextLimit)
        } else if canonicalTool == "noema.python.execute" {
            outData = try await tool.call(args: argsData)
        } else {
            outData = try await tool.call(args: argsData)
        }
        let outString = String(data: outData, encoding: .utf8) ?? "{\"code\":\"ENCODE\",\"message\":\"Failed to encode\"}"
        let preview = outString.count > 400 ? String(outString.prefix(400)) + "…" : outString
        await logger.log("[Tool] Result from \(canonicalTool): \(preview)")
        // Mark this tool+args as dispatched for this message to avoid re-execution on future scans
        if let sigData = try? JSONSerialization.data(withJSONObject: ["tool": canonicalTool, "args": clampedArgs], options: [.sortedKeys]),
           let signature = String(data: sigData, encoding: .utf8) {
            await ToolScanRegistry.shared.markDispatched(signature, for: messageIndex)
        }
        
        // Update tool call with result
        _ = upsertToolCall(
            messageIndex: messageIndex,
            chatVM: chatVM,
            toolName: canonicalTool,
            requestParams: displayParamsForExecution,
            phase: .completed,
            externalToolCallID: call.externalToolCallID,
            result: outString,
            error: nil
        )
        await ToolScanRegistry.shared.clearPlaceholder(placeholderSig, for: messageIndex)

        // If this is the web search tool, optionally update the message's
        // webHits/webError so the UI transitions from "Searching the web…".
        if Task.isCancelled { return nil }
        if canonicalTool == "noema.web.retrieve",
           let messageIndex = messageIndex,
           let chatVM = chatVM,
           chatVM.streamMsgs.indices.contains(messageIndex) {
            await logger.log("[Tool][UI] Applying web search result to message state")
            chatVM.streamMsgs[messageIndex].usedWebSearch = true
            // Milestone: record web search usage for in‑app review gating
            ReviewPrompter.shared.noteWebSearchUsed()
            if let data = outString.data(using: .utf8) {
                struct SimpleWebHit: Decodable {
                    let title: String
                    let url: String
                    let snippet: String
                    let engine: String?
                    let score: Double?
                }
                if let hits = try? JSONDecoder().decode([SimpleWebHit].self, from: data) {
                    if hits.isEmpty {
                        chatVM.streamMsgs[messageIndex].webError = "No results found"
                        chatVM.streamMsgs[messageIndex].webHits = nil
                    } else {
                        chatVM.streamMsgs[messageIndex].webError = nil
                        chatVM.streamMsgs[messageIndex].webHits = hits.enumerated().map { (i, h) in
                            let engine = h.engine?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let resolvedEngine = engine?.isEmpty == false ? engine! : "searxng"
                            return .init(
                                id: String(i+1),
                                title: h.title,
                                snippet: h.snippet,
                                url: h.url,
                                engine: resolvedEngine,
                                score: h.score ?? 0
                            )
                        }
                    }
                } else if let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let err: String? = {
                        if let e = any["error"] as? String { return e }
                        if let msg = any["message"] as? String { return msg }
                        if let code = any["code"] { return "Error: \(code)" }
                        return nil
                    }()
                    if let err = err, !err.isEmpty {
                        chatVM.streamMsgs[messageIndex].webError = err
                        chatVM.streamMsgs[messageIndex].webHits = nil
                    }
                }
            }
            // Try prompting after success moments (guarded: never during active streaming)
            ReviewPrompter.shared.safeMaybePromptIfEligible(chatVM: chatVM)
        }
        
        if Task.isCancelled { return nil }
        return ("TOOL_RESULT: \(outString)", trailing.isEmpty ? nil : trailing)
    } catch {
        if (error as? CancellationError) != nil { return nil }
        await logger.log("[Tool] Parse/dispatch error: \(error.localizedDescription)")
        if let toolName = extractToolName(from: jsonPart).map(normalizeToolName) {
            _ = upsertToolCall(
                messageIndex: messageIndex,
                chatVM: chatVM,
                toolName: toolName,
                requestParams: [:],
                phase: .failed,
                result: nil,
                error: error.localizedDescription
            )
            await ToolScanRegistry.shared.clearPlaceholder(
                placeholderSignature(for: toolName, rawFragment: jsonPart),
                for: messageIndex
            )
        }
        
        if Task.isCancelled { return nil }
        return ("TOOL_RESULT: {\"code\":\"PARSE\",\"message\":\"\(error)\"}", trailing.isEmpty ? nil : trailing)
    }
}

// Detect and handle XML-style or bare-JSON tool calls that appear inside an accumulated buffer.
// This supports responses like:
// <tool_call>{"tool_name":"noema.web.retrieve","arguments":{"query":"...","count":3,"safesearch":"moderate"}}</tool_call>
// as well as a bare JSON object with the same shape (often emitted inside a "Thought." block).
// MLX models may emit a simplified structure {"tool":"...","args":{...}}, which is also handled here.
@MainActor
func interceptEmbeddedToolCallIfPresent(
    in textBuffer: String,
    messageIndex: Int? = nil,
    chatVM: ChatVM? = nil,
    handlingMode: EmbeddedToolHandlingMode = .dispatchIfAllowed
) async -> EmbeddedToolInterceptResult? {
    // Guard: Do NOT process tool calls if we're inside an unclosed <think> block.
    // The model should only call tools OUTSIDE of thinking.
    let lastThinkOpen = textBuffer.range(of: "<think>", options: .backwards)
    let lastThinkClose = textBuffer.range(of: "</think>", options: .backwards)
    let insideThink: Bool = {
        if let open = lastThinkOpen {
            if let close = lastThinkClose {
                // Inside think if the last <think> comes AFTER the last </think>
                return open.lowerBound > close.lowerBound
            }
            // Have <think> but no </think> means we're inside
            return true
        }
        return false
    }()
    if insideThink {
        await logger.log("[Tool][Scan] Skipping tool scan - inside unclosed <think> block")
        return nil
    }

    var didLogScrub = false
    func scrubResult(cleanedText: String) async -> EmbeddedToolInterceptResult {
        if !didLogScrub {
            await logger.log("[Tool][Scan] Tool artifact scrubbed without dispatch")
            didLogScrub = true
        }
        return EmbeddedToolInterceptResult(token: nil, cleanedText: cleanedText)
    }

    func combinedCleanedText(
        before: String,
        after: String,
        preserveToolPosition: Bool
    ) -> String {
        if preserveToolPosition {
            return before + noemaToolAnchorToken + after
        }
        return before + after
    }

    func finalizeCandidate(
        jsonString: String,
        before: String,
        after: String,
        logPrefix: String? = nil
    ) async -> EmbeddedToolInterceptResult? {
        switch handlingMode {
        case .dispatchIfAllowed:
            if let logPrefix {
                await logger.log(logPrefix)
            }
            if let token = await dispatchParsedToolCallJSON(
                jsonString: jsonString,
                messageIndex: messageIndex,
                chatVM: chatVM
            ) {
                return EmbeddedToolInterceptResult(
                    token: token,
                    cleanedText: combinedCleanedText(
                        before: before,
                        after: after,
                        preserveToolPosition: true
                    )
                )
            }
            return nil
        case .scrubOnly:
            return await scrubResult(
                cleanedText: combinedCleanedText(
                    before: before,
                    after: after,
                    preserveToolPosition: false
                )
            )
        }
    }

    if let toolCallRange = textBuffer.range(of: "TOOL_CALL:") {
        let afterPrefix = String(textBuffer[toolCallRange.upperBound...])
        if let open = afterPrefix.firstIndex(of: "{"),
           let close = findMatchingBrace(in: afterPrefix, startingFrom: open) {
            let candidate = String(afterPrefix[open...close])
            let before = String(textBuffer[..<toolCallRange.lowerBound])
            let after = String(afterPrefix[afterPrefix.index(after: close)...])
            if let result = await finalizeCandidate(
                jsonString: candidate,
                before: before,
                after: after,
                logPrefix: "[Tool] Attempting to parse TOOL_CALL payload: \(candidate.prefix(200))…"
            ) {
                return result
            }
        } else if handlingMode == .scrubOnly {
            return await scrubResult(cleanedText: String(textBuffer[..<toolCallRange.lowerBound]))
        }
    }

    // 1) Try bare JSON around specific web tool name (or aliases) to quickly dispatch
    let webAliases = [
        "noema.web.retrieve",
        "noema_web_retrieve",
        "Web_Search", "WEB_SEARCH",
        "web_search", "web.search", "websearch", "web-search"
    ]
    if let webRange = webAliases.compactMap({ textBuffer.range(of: $0) }).sorted(by: { $0.lowerBound < $1.lowerBound }).first,
       let open = textBuffer[..<webRange.lowerBound].lastIndex(of: "{"),
       let close = findMatchingBrace(in: textBuffer, startingFrom: open) {
        let candidate = String(textBuffer[open...close])
        if (candidate.contains("\"arguments\"") || candidate.contains("\"args\"")) {
            let before = String(textBuffer[..<open])
            var afterStart = textBuffer.index(after: close)
            while afterStart < textBuffer.endIndex && textBuffer[afterStart].isWhitespace {
                afterStart = textBuffer.index(after: afterStart)
            }
            if afterStart < textBuffer.endIndex && textBuffer[afterStart] == "}" {
                afterStart = textBuffer.index(after: afterStart)
            }
            let after = String(textBuffer[afterStart...])
            if let result = await finalizeCandidate(
                jsonString: candidate,
                before: before,
                after: after,
                logPrefix: "[Tool] Attempting to parse JSON around web tool: \(candidate.prefix(200))…"
            ) {
                return result
            }
        }
    }

    // 2) Generic scan for JSON objects anywhere in the buffer
    var searchIndex = textBuffer.startIndex
    while searchIndex < textBuffer.endIndex {
        guard let startIndex = textBuffer[searchIndex...].firstIndex(of: "{") else { break }
        if let endIndex = findMatchingBrace(in: textBuffer, startingFrom: startIndex) {
            let candidate = String(textBuffer[startIndex...endIndex])
            if (candidate.contains("\"tool_name\"") || candidate.contains("\"name\"") || candidate.contains("\"tool\"")) &&
               (candidate.contains("\"arguments\"") || candidate.contains("\"args\"")) {
                var removalStart = startIndex
                var removalEnd = endIndex
                if let fenceStart = textBuffer[..<startIndex].range(of: "```json", options: .backwards)?.lowerBound {
                    removalStart = fenceStart
                } else if let fenceStart = textBuffer[..<startIndex].range(of: "```", options: .backwards)?.lowerBound {
                    removalStart = fenceStart
                }
                let afterEnd = textBuffer.index(after: endIndex)
                if let fenceEnd = textBuffer[afterEnd...].range(of: "```")?.upperBound {
                    removalEnd = fenceEnd
                }

                if let tagOpen = textBuffer[..<removalStart].range(of: "<tool_call>", options: .backwards) {
                    removalStart = tagOpen.lowerBound
                    if let tagClose = textBuffer[removalEnd...].range(of: "</tool_call>") {
                        removalEnd = tagClose.upperBound
                    }
                }

                let before = String(textBuffer[..<removalStart])
                var afterStart: String.Index
                if removalEnd == endIndex {
                    afterStart = textBuffer.index(after: removalEnd)
                } else {
                    afterStart = removalEnd
                }
                while afterStart < textBuffer.endIndex && textBuffer[afterStart].isWhitespace {
                    afterStart = textBuffer.index(after: afterStart)
                }
                if afterStart < textBuffer.endIndex && textBuffer[afterStart] == "}" {
                    afterStart = textBuffer.index(after: afterStart)
                }
                let after = String(textBuffer[afterStart...])
                if let result = await finalizeCandidate(
                    jsonString: candidate,
                    before: before,
                    after: after,
                    logPrefix: "[Tool] Attempting to parse JSON: \(candidate.prefix(200))…"
                ) {
                    return result
                }
            }
            searchIndex = textBuffer.index(after: endIndex)
        } else {
            let remainder = String(textBuffer[startIndex...])
            if (remainder.contains("\"tool_name\"") || remainder.contains("\"name\"") || remainder.contains("\"tool\"")) &&
               (remainder.contains("\"arguments\"") || remainder.contains("\"args\"")) {
                if let extractedToolName = extractToolName(from: remainder) {
                    let toolName = normalizeToolName(extractedToolName)
                    await insertToolPlaceholderIfNeeded(
                        messageIndex: messageIndex,
                        chatVM: chatVM,
                        toolName: toolName,
                        rawFragment: remainder
                    )
                }
                if handlingMode == .scrubOnly {
                    return await scrubResult(cleanedText: String(textBuffer[..<startIndex]))
                }
            }
            break
        }
    }

    // 3) Fallback: XML-style <tool_call>…</tool_call>
    if let start = textBuffer.range(of: "<tool_call>") {
        if await ToolScanRegistry.shared.shouldLogOpenTagOnce(messageIndex: messageIndex) {
            await logger.log("[Tool][Scan] Found <tool_call> marker in buffer (len=\(textBuffer.count))")
        }
        if let end = textBuffer.range(of: "</tool_call>") {
            let rawInside = String(textBuffer[start.upperBound..<end.lowerBound])
            // Some models wrap JSON in code fences inside the tool_call tag; strip fences
            let jsonString: String = {
                var s = rawInside.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.hasPrefix("```") {
                    // Drop opening ```[lang]? line
                    if let fenceEnd = s.firstIndex(of: "\n") { s = String(s[s.index(after: fenceEnd)...]) } else { s = s.replacingOccurrences(of: "```", with: "") }
                }
                if s.hasSuffix("```") { s.removeLast(3) }
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }()
            // Some models incorrectly place a tool RESULT inside <tool_call>. If we detect
            // a result-only object, skip logging/dispatch here and let generic detection
            // find the actual tool CALL JSON elsewhere in the buffer.
            let lower = jsonString.lowercased()
            let looksLikeResultOnly = lower.contains("\"result\"") && !(lower.contains("\"tool_name\"") || lower.contains("\"name\"") || lower.contains("\"tool\""))
            if !looksLikeResultOnly {
                // Qwen/Hermes models emit `<function=…><parameter=…>` inside <tool_call>
                // instead of JSON. Convert it so it dispatches like any other call.
                let candidateJSON = jsonString.contains("<function=")
                    ? (xmlFunctionCallToJSON(jsonString) ?? jsonString)
                    : jsonString
                let before = String(textBuffer[..<start.lowerBound])
                var after = String(textBuffer[end.upperBound...])
                while after.first?.isWhitespace == true { after.removeFirst() }
                if let result = await finalizeCandidate(
                    jsonString: candidateJSON,
                    before: before,
                    after: after,
                    logPrefix: "[Tool][Scan] Extracted candidate inside <tool_call>: \(candidateJSON.prefix(220))…"
                ) {
                    return result
                } else {
                    let trimmed = candidateJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                    let hasBraces = trimmed.contains("{") && trimmed.contains("}")
                    if hasBraces {
                        await logger.log("[Tool][Scan] JSON inside <tool_call> could not be parsed; leaving for fallback scan")
                        if let extractedToolName = extractToolName(from: trimmed) {
                            let toolName = normalizeToolName(extractedToolName)
                            await insertToolPlaceholderIfNeeded(
                                messageIndex: messageIndex,
                                chatVM: chatVM,
                                toolName: toolName,
                                rawFragment: trimmed
                            )
                        }
                    } else {
                        await logger.log("[Tool][Scan] Incomplete JSON inside <tool_call>; continuing to scan for bare JSON")
                    }
                }
            }
        } else {
            // No closing tag yet. Be tolerant: attempt to extract the first complete JSON
            // object after <tool_call> and dispatch immediately. This covers cases where
            // stop tokens cut the stream before </tool_call> is emitted.
            let tail = String(textBuffer[start.upperBound...])
            // Qwen/Hermes XML form may also be cut before </tool_call>; convert and
            // dispatch as soon as the function block itself is complete (</function>).
            if tail.contains("<function="), tail.contains("</function>"),
               let candidateJSON = xmlFunctionCallToJSON(tail) {
                let before = String(textBuffer[..<start.lowerBound])
                let after = tail.range(of: "</function>").map { String(tail[$0.upperBound...]) } ?? ""
                if let result = await finalizeCandidate(
                    jsonString: candidateJSON,
                    before: before,
                    after: after,
                    logPrefix: "[Tool][Scan] Converted XML function call after open <tool_call>: \(candidateJSON.prefix(220))…"
                ) {
                    return result
                }
            }
            if let firstBrace = tail.firstIndex(of: "{"),
               let lastBrace = findMatchingBrace(in: tail, startingFrom: firstBrace) {
                let candidate = String(tail[firstBrace...lastBrace])
                let before = String(textBuffer[..<start.lowerBound])
                var afterStart = tail.index(after: lastBrace)
                while afterStart < tail.endIndex && tail[afterStart].isWhitespace { afterStart = tail.index(after: afterStart) }
                let after = String(tail[afterStart...])
                if let result = await finalizeCandidate(
                    jsonString: candidate,
                    before: before,
                    after: after,
                    logPrefix: "[Tool][Scan] Found JSON after open <tool_call> (no close yet): \(candidate.prefix(220))…"
                ) {
                    return result
                } else {
                    await logger.log("[Tool][Scan] dispatchParsedToolCallJSON returned nil for JSON after open tag")
                }
            } else {
                // Provide a placeholder tool box so the UI reflects the pending call even if
                // the JSON body is still streaming from a slower backend.
                let snippet = String(tail.prefix(160))
                if let extractedToolName = extractToolName(from: snippet) {
                    let toolName = normalizeToolName(extractedToolName)
                    await insertToolPlaceholderIfNeeded(
                        messageIndex: messageIndex,
                        chatVM: chatVM,
                        toolName: toolName,
                        rawFragment: snippet
                    )
                }
                if handlingMode == .scrubOnly {
                    return await scrubResult(cleanedText: String(textBuffer[..<start.lowerBound]))
                }
            }
            // If we can't find a complete object yet, keep scanning for a bare JSON
            // object elsewhere in the buffer.
        }
    }

    return nil
}


@MainActor
/// Converts a Qwen/Hermes-style XML function call into the canonical JSON shape
/// `{"name": <fn>, "arguments": { ... }}` so it can flow through the normal JSON
/// dispatch path. Returns nil if no `<function=...>` block is present.
///
/// The Qwen3.5 chat template emits tool calls as:
///   <tool_call>
///   <function=noema.web.retrieve>
///   <parameter=count>
///   3
///   </parameter>
///   <parameter=query>
///   latest news
///   </parameter>
///   </function>
///   </tool_call>
/// which the JSON-oriented scanner otherwise scrubs without ever dispatching.
private func xmlFunctionCallToJSON(_ body: String) -> String? {
    // Coerce a raw `<parameter>` value into a JSON-friendly scalar so numeric/boolean
    // arguments (e.g. `count`) survive as numbers instead of strings.
    func coerceValue(_ s: String) -> Any {
        if s == "true" { return true }
        if s == "false" { return false }
        if let i = Int(s) { return i }
        if s.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let d = Double(s) { return d }
        return s
    }

    guard let fnRange = body.range(of: "<function=") else { return nil }
    let afterFn = body[fnRange.upperBound...]
    guard let nameEnd = afterFn.firstIndex(of: ">") else { return nil }
    let name = String(afterFn[..<nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }

    var arguments: [String: Any] = [:]
    var cursor = afterFn[afterFn.index(after: nameEnd)...]
    while let paramOpen = cursor.range(of: "<parameter=") {
        let afterParam = cursor[paramOpen.upperBound...]
        guard let keyEnd = afterParam.firstIndex(of: ">") else { break }
        let key = String(afterParam[..<keyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let afterKey = afterParam[afterParam.index(after: keyEnd)...]
        // The value runs until the closing </parameter>. If it's missing the stream
        // was cut mid-parameter, so stop and use whatever complete params we have.
        guard let close = afterKey.range(of: "</parameter>") else { break }
        let valueString = String(afterKey[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            arguments[key] = coerceValue(valueString)
        }
        cursor = afterKey[close.upperBound...]
    }

    // Require either at least one parsed parameter or a fully-closed function block,
    // so we don't dispatch on a half-streamed call.
    guard !arguments.isEmpty || body.contains("</function>") else { return nil }

    let payload: [String: Any] = ["name": name, "arguments": arguments]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
          let json = String(data: data, encoding: .utf8) else {
        return nil
    }
    return json
}

private func dispatchParsedToolCallJSON(jsonString: String, messageIndex: Int? = nil, chatVM: ChatVM? = nil) async -> String? {
    // Clean wrappers and code fences, then extract the first complete JSON object
    func stripFencesAndTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<tool_call>", with: "").replacingOccurrences(of: "</tool_call>", with: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) } else { t = t.replacingOccurrences(of: "```", with: "") }
        }
        if t.hasSuffix("```") { t.removeLast(3) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func extractFirstJSONObject(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "{") else { return nil }
        guard let close = findMatchingBrace(in: s, startingFrom: open) else { return nil }
        return String(s[open...close])
    }
    func removeTrailingCommas(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inString = false
        var escape = false
        var i = s.startIndex
        // Lookahead for commas before } or ]
        while i < s.endIndex {
            let c = s[i]
            if escape { out.append(c); escape = false; i = s.index(after: i); continue }
            if c == "\\" && inString { out.append(c); escape = true; i = s.index(after: i); continue }
            if c == "\"" { inString.toggle(); out.append(c); i = s.index(after: i); continue }
            if !inString && c == "," {
                // Peek ahead skipping whitespace
                var j = s.index(after: i)
                while j < s.endIndex, s[j].isWhitespace { j = s.index(after: j) }
                if j < s.endIndex, s[j] == "}" || s[j] == "]" {
                    // Skip trailing comma
                    i = j; continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
    func extractArgumentsObjectJSON(_ s: String) -> String? {
        for key in ["\"arguments\"", "\"args\"", "arguments", "args", "'arguments'", "'args'"] {
            guard let keyRange = s.range(of: key),
                  let colon = s.range(of: ":", range: keyRange.upperBound..<s.endIndex)?.lowerBound else {
                continue
            }

            var valueStart = s.index(after: colon)
            while valueStart < s.endIndex, s[valueStart].isWhitespace {
                valueStart = s.index(after: valueStart)
            }
            guard valueStart < s.endIndex else { continue }

            if s[valueStart] == "{" {
                let tail = String(s[valueStart...])
                if let close = findMatchingBrace(in: tail, startingFrom: tail.startIndex) {
                    return String(tail[tail.startIndex...close])
                }
            } else if s[valueStart] == "\"" {
                var literal = "\""
                var index = s.index(after: valueStart)
                var escape = false
                while index < s.endIndex {
                    let char = s[index]
                    literal.append(char)
                    if escape {
                        escape = false
                    } else if char == "\\" {
                        escape = true
                    } else if char == "\"" {
                        if let data = literal.data(using: .utf8),
                           let decoded = try? JSONSerialization.jsonObject(with: data) as? String {
                            return decoded
                        }
                        break
                    }
                    index = s.index(after: index)
                }
            }
        }
        return nil
    }

    let cleaned = stripFencesAndTags(jsonString)

    func balancedJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var index = start
        var lastIndex = start
        while index < text.endIndex {
            let char = text[index]
            if escape {
                escape = false
            } else if char == "\\" && inString {
                escape = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        lastIndex = index
                        break
                    }
                }
            }
            lastIndex = index
            index = text.index(after: index)
        }

        var result = String(text[start...lastIndex])
        if depth > 0 {
            result.append(String(repeating: "}", count: depth))
        }
        return result
    }

    var candidate = extractFirstJSONObject(cleaned)
    if candidate == nil {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            candidate = trimmed
        } else if trimmed.contains("\"tool_name\"") || trimmed.contains("\"tool\"") || trimmed.contains("\"name\"") {
            await logger.log("[Tool][Scan] Incomplete tool JSON awaiting more tokens: \(trimmed.prefix(160))…")
            if jsonString.lowercased().contains("</tool_call") {
                candidate = balancedJSONObject(from: trimmed)
            }
        }
    }
    
    // If we still don't have a syntactically complete object, attempt a best‑effort recovery
    // from text that mentions the tool name/arguments but isn't valid JSON (common with SLMs
    // that echo instructions like "wrapper with the tool call").
    if candidate == nil {
        // Try relaxed extraction on the cleaned string before giving up.
        // This path mirrors the last‑chance logic below but runs even when no braces were found.
        func extractBetween(_ s: String, start: String, end: String) -> String? {
            guard let r1 = s.range(of: start) else { return nil }
            guard let r2 = s.range(of: end, range: r1.upperBound..<s.endIndex) else { return nil }
            return String(s[r1.upperBound..<r2.lowerBound])
        }
        func bestEffortToolNameNoJSON(_ s: String) -> String? {
            // Prefer proper JSON key first
            if let tn = extractStringValue(forKey: "tool_name", in: s) { return tn }
            if let tn = extractStringValue(forKey: "name", in: s) { return tn }
            if let tn = extractStringValue(forKey: "tool", in: s) { return tn }
            // Tolerate curly quotes and bare identifiers
            let squashed = s
                .replacingOccurrences(of: "“", with: "\"")
                .replacingOccurrences(of: "”", with: "\"")
                .replacingOccurrences(of: "’", with: "'")
            if let rough = extractBetween(squashed, start: "tool_name", end: ",") ?? extractBetween(squashed, start: "tool:", end: ",") {
                if let q1 = rough.firstIndex(of: "\""), let q2 = rough[rough.index(after: q1)...].firstIndex(of: "\"") {
                    return String(rough[rough.index(after: q1)..<q2])
                }
            }
            // Directly search for known aliases
            let aliases = ["noema.web.retrieve","noema_web_retrieve","Web_Search","WEB_SEARCH","web_search","web.search","websearch","web-search"]
            for a in aliases { if s.contains(a) { return a } }
            return nil
        }
        func bestEffortArgsFromText(_ s: String) -> String? {
            extractArgumentsObjectJSON(s)
        }
        if let tn = bestEffortToolNameNoJSON(cleaned), let argsJSON = bestEffortArgsFromText(cleaned) {
            let canonical = normalizeToolName(tn)
            var argsObj: [String: Any] = [:]
            if let data = argsJSON.data(using: .utf8),
               let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                argsObj = any
            }
            // Reuse the canonical TOOL_CALL path to unify UI updates and execution
            let payload: [String: Any] = ["tool": canonical, "args": argsObj]
            if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
               let payloadString = String(data: payloadData, encoding: .utf8) {
                if !(await ToolScanRegistry.shared.hasDispatched(payloadString, for: messageIndex)) {
                    if let (token, _) = await interceptToolCallIfPresent("\(toolPrefix)\(payloadString)", messageIndex: messageIndex, chatVM: chatVM) {
                        await ToolScanRegistry.shared.markDispatched(payloadString, for: messageIndex)
                        return token
                    }
                }
            }
        }
        // Still nothing recoverable; wait for more tokens.
        return nil
    }

    guard let complete = candidate else {
        // Should be unreachable due to early return above
        return nil
    }

    struct XMLCall: Decodable {
        let tool_name: String
        let arguments: [String: AnyCodable]

        private enum CodingKeys: String, CodingKey { case tool_name, name, tool, arguments, args }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let tn = try container.decodeIfPresent(String.self, forKey: .tool_name) {
                self.tool_name = tn
            } else if let n = try container.decodeIfPresent(String.self, forKey: .name) {
                self.tool_name = n
            } else {
                self.tool_name = try container.decode(String.self, forKey: .tool)
            }
            if let args = try? container.decode([String: AnyCodable].self, forKey: .arguments) {
                self.arguments = args
            } else if let args = try? container.decode([String: AnyCodable].self, forKey: .args) {
                self.arguments = args
            } else if let argsString = try container.decodeIfPresent(String.self, forKey: .arguments) ?? container.decodeIfPresent(String.self, forKey: .args) {
                // Some models serialize the arguments object as a JSON string; parse it
                if let data = argsString.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.arguments = any.mapValues { AnyCodable($0) }
                } else {
                    self.arguments = [:]
                }
            } else {
                self.arguments = [:]
            }
        }
    }

    // Try strict decode first
    if let data = complete.data(using: .utf8), let call = try? JSONDecoder().decode(XMLCall.self, from: data) {
        // Skip obvious prompt-echo samples (e.g., query: "...") to avoid false tool triggers
        let canonicalName = normalizeToolName(call.tool_name)
        if canonicalName == "noema.web.retrieve" {
            if let q = call.arguments["query"]?.value as? String {
                let tq = q.trimmingCharacters(in: .whitespacesAndNewlines)
                if tq.isEmpty || tq == "..." { return nil }
            }
        }
        // Reuse the canonical TOOL_CALL path to unify UI updates and execution
        let payload: [String: Any] = [
            "tool": call.tool_name,
            "args": call.arguments.mapValues { $0.value }
        ]
        if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            // Skip duplicate dispatch of the same tool+args within the same message
            if !(await ToolScanRegistry.shared.hasDispatched(payloadString, for: messageIndex)) {
                if let (token, _) = await interceptToolCallIfPresent("\(toolPrefix)\(payloadString)", messageIndex: messageIndex, chatVM: chatVM) {
                    await ToolScanRegistry.shared.markDispatched(payloadString, for: messageIndex)
                    return token
                }
            }
        }
        return nil
    }
    // Retry after removing trailing commas which some models emit
    let relaxed = removeTrailingCommas(complete)
    if let data2 = relaxed.data(using: .utf8), let call2 = try? JSONDecoder().decode(XMLCall.self, from: data2) {
        let canonicalName2 = normalizeToolName(call2.tool_name)
        if canonicalName2 == "noema.web.retrieve" {
            if let q = call2.arguments["query"]?.value as? String {
                let tq = q.trimmingCharacters(in: .whitespacesAndNewlines)
                if tq.isEmpty || tq == "..." { return nil }
            }
        }
        let payload: [String: Any] = [
            "tool": call2.tool_name,
            "args": call2.arguments.mapValues { $0.value }
        ]
        if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            if !(await ToolScanRegistry.shared.hasDispatched(payloadString, for: messageIndex)) {
                if let (token, _) = await interceptToolCallIfPresent("\(toolPrefix)\(payloadString)", messageIndex: messageIndex, chatVM: chatVM) {
                    await ToolScanRegistry.shared.markDispatched(payloadString, for: messageIndex)
                    return token
                }
            }
        }
        return nil
    }

    // Attempt to coerce single-quoted objects (common on smaller local models)
    let singleQuoted = normalizeSingleQuotedJSON(complete)
    if singleQuoted != complete,
       let data3 = singleQuoted.data(using: .utf8),
       let call3 = try? JSONDecoder().decode(XMLCall.self, from: data3) {
        let canonicalName3 = normalizeToolName(call3.tool_name)
        if canonicalName3 == "noema.web.retrieve" {
            if let q = call3.arguments["query"]?.value as? String {
                let tq = q.trimmingCharacters(in: .whitespacesAndNewlines)
                if tq.isEmpty || tq == "..." { return nil }
            }
        }
        let payload: [String: Any] = [
            "tool": call3.tool_name,
            "args": call3.arguments.mapValues { $0.value }
        ]
        if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            if !(await ToolScanRegistry.shared.hasDispatched(payloadString, for: messageIndex)) {
                if let (token, _) = await interceptToolCallIfPresent("\(toolPrefix)\(payloadString)", messageIndex: messageIndex, chatVM: chatVM) {
                    await ToolScanRegistry.shared.markDispatched(payloadString, for: messageIndex)
                    return token
                }
            }
        }
        return nil
    }

    // Last‑chance relaxed parser for slightly malformed objects that still look like
    // { "tool_name"|"name"|"tool": "...", "arguments"|"args": { ... } } but fail strict JSON decoding.
    // This helps with tiny SLMs or GGUF models that sometimes drop quotes or sprinkle
    // dangling commas despite the instructions not to.
    func extractBetween(_ s: String, start: String, end: String) -> String? {
        guard let r1 = s.range(of: start) else { return nil }
        guard let r2 = s.range(of: end, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound])
    }
    func bestEffortToolName(_ s: String) -> String? {
        // Try proper JSON key first
        if let tn = extractStringValue(forKey: "tool_name", in: s) { return tn }
        if let tn = extractStringValue(forKey: "name", in: s) { return tn }
        if let tn = extractStringValue(forKey: "tool", in: s) { return tn }
        // Try extremely relaxed patterns: tool_name: "..." without proper quoting
        if let rough = extractBetween(s, start: "tool_name", end: ",") ?? extractBetween(s, start: "tool:", end: ",") {
            if let q1 = rough.firstIndex(of: "\""), let q2 = rough[rough.index(after: q1)...].firstIndex(of: "\"") {
                return String(rough[rough.index(after: q1)..<q2])
            }
        }
        return nil
    }
    func bestEffortArgsJSON(_ s: String) -> String? {
        extractArgumentsObjectJSON(s)
    }
    if let tn = bestEffortToolName(complete), let argsJSON = bestEffortArgsJSON(complete) {
        // Build normalized payload
        let canonical = normalizeToolName(tn)
        var argsObj: [String: Any] = [:]
        if let data = argsJSON.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            argsObj = any
        }
        let payload: [String: Any] = ["tool": canonical, "args": argsObj]
        if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            if !(await ToolScanRegistry.shared.hasDispatched(payloadString, for: messageIndex)) {
                if let (token, _) = await interceptToolCallIfPresent("\(toolPrefix)\(payloadString)", messageIndex: messageIndex, chatVM: chatVM) {
                    await ToolScanRegistry.shared.markDispatched(payloadString, for: messageIndex)
                    return token
                }
            }
        }
    }

    await logger.log("[Tool] Failed to decode tool call JSON: \(complete.prefix(200))…")
    do {
        let data = complete.data(using: .utf8) ?? Data()
        let _ = try JSONDecoder().decode(XMLCall.self, from: data)
    } catch {
        await logger.log("[Tool] JSON decode error details: \(error)")
    }
    return nil
}

// finalizeDispatch removed; logic inlined in decode paths above

// Helper function to find the matching closing brace for a JSON object
private func findMatchingBrace(in text: String, startingFrom startIndex: String.Index) -> String.Index? {
    guard startIndex < text.endIndex, text[startIndex] == "{" else { return nil }
    var depth = 0
    var inString = false
    var escape = false
    var i = startIndex
    while i < text.endIndex {
        let c = text[i]
        if escape { escape = false; i = text.index(after: i); continue }
        if c == "\\" && inString { escape = true; i = text.index(after: i); continue }
        if c == "\"" { inString.toggle(); i = text.index(after: i); continue }
        if !inString {
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
        }
        i = text.index(after: i)
    }
    return nil
}

// Best-effort extraction of tool name from an incomplete JSON object
private func extractToolName(from text: String) -> String? {
    // Prefer new key
    if let tn = extractStringValue(forKey: "tool_name", in: text) { return tn }
    // Fallback for legacy
    if let n = extractStringValue(forKey: "name", in: text) { return n }
    // MLX-style simplified key
    if let t = extractStringValue(forKey: "tool", in: text) { return t }
    if let tn = extractSingleQuotedValue(forKey: "tool_name", in: text) { return tn }
    if let n = extractSingleQuotedValue(forKey: "name", in: text) { return n }
    if let t = extractSingleQuotedValue(forKey: "tool", in: text) { return t }
    // Qwen/Hermes XML form: <function=noema.web.retrieve>
    if let fnRange = text.range(of: "<function="),
       let nameEnd = text[fnRange.upperBound...].firstIndex(of: ">") {
        let name = String(text[fnRange.upperBound..<nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
    }
    return nil
}

private func extractStringValue(forKey key: String, in text: String) -> String? {
    let quotedKey = "\"\(key)\""
    guard let keyRange = text.range(of: quotedKey) else { return nil }
    if let colon = text.range(of: ":", range: keyRange.upperBound..<text.endIndex)?.lowerBound,
       let firstQuote = text[ text.index(after: colon)..<text.endIndex ].firstIndex(of: "\"" ) {
        let afterFirst = text.index(after: firstQuote)
        if let secondQuote = text[ afterFirst..<text.endIndex ].firstIndex(of: "\"" ) {
            let value = String(text[afterFirst..<secondQuote])
            if !value.isEmpty { return value }
        }
    }
    return nil
}

private func extractSingleQuotedValue(forKey key: String, in text: String) -> String? {
    let pattern = "'\(key)'"
    guard let keyRange = text.range(of: pattern) else { return nil }
    if let colon = text.range(of: ":", range: keyRange.upperBound..<text.endIndex)?.lowerBound,
       let firstQuote = text[text.index(after: colon)..<text.endIndex].firstIndex(of: "'") {
        let afterFirst = text.index(after: firstQuote)
        if let secondQuote = text[afterFirst..<text.endIndex].firstIndex(of: "'") {
            let value = String(text[afterFirst..<secondQuote])
            if !value.isEmpty { return value }
        }
    }
    return nil
}

private func normalizeSingleQuotedJSON(_ s: String) -> String {
    var result = s
    // Normalize single-quoted keys to double-quoted
    if let keyRegex = try? NSRegularExpression(pattern: "'([A-Za-z0-9_]+)'\\s*:") {
        let range = NSRange(location: 0, length: (result as NSString).length)
        result = keyRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\"$1\":")
    }
    // Normalize single-quoted string values that don't contain embedded quotes
    if let valueRegex = try? NSRegularExpression(pattern: ":\\s*'([^'\\n]*)'") {
        let range = NSRange(location: 0, length: (result as NSString).length)
        result = valueRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: ": \"$1\"")
    }
    return result
}

#endif
