import Foundation

struct AFMToolCallSummary: Sendable {
    let toolName: String
    let requestParams: [String: AnyCodable]
    let result: String?
    let error: String?
    let timestamp: Date
}

struct AFMToolExecutionSummary: Sendable {
    let calls: [AFMToolCallSummary]

    var isEmpty: Bool { calls.isEmpty }
}

struct AFMResolvedToolCall: Sendable {
    let toolName: String
    let displayName: String
    let iconName: String
    let requestParams: [String: AnyCodable]
    let result: String?
    let error: String?
    let timestamp: Date
}

struct AFMResolvedToolExecution: Sendable {
    let calls: [AFMResolvedToolCall]
    let usedWebSearch: Bool
    let webHits: [WebHit]?
    let webError: String?
}

actor AFMToolRecorder {
    private var calls: [AFMToolCallSummary] = []

    func reset() {
        calls.removeAll()
    }

    func record(_ summary: AFMToolCallSummary) {
        calls.append(summary)
    }

    func drain() -> AFMToolExecutionSummary? {
        guard !calls.isEmpty else { return nil }
        let summary = AFMToolExecutionSummary(calls: calls)
        calls.removeAll()
        return summary
    }
}

enum AFMWebSearchExecution {
    typealias SearchHandler = @Sendable (_ query: String, _ count: Int, _ safesearch: String) async throws -> [WebHit]

    static func perform(
        query: String,
        count: Int,
        safesearch: String,
        isAvailable: Bool = WebToolGate.isAvailable(currentFormat: .afm),
        searchHandler: SearchHandler? = nil
    ) async -> String {
        guard isAvailable else {
            return errorPayload("Web search is disabled or offline-only.")
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return errorPayload("Search query cannot be empty.")
        }

        let clampedCount = max(1, min(count, 5))
        let normalizedSafeSearch = normalizedSafeSearch(safesearch)
        let search = searchHandler ?? { query, count, safesearch in
            try await SearXNGSearchClient().search(query, count: count, safesearch: safesearch)
        }

        do {
            let hits = try await search(
                trimmedQuery,
                clampedCount,
                normalizedSafeSearch
            )
            return hitsPayload(hits)
        } catch {
            return errorPayload(userFacingMessage(for: error))
        }
    }

    static func errorMessage(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    static func hits(from payload: String) -> [WebHit]? {
        guard let data = payload.data(using: .utf8),
              let hits = try? JSONDecoder().decode([WebHit].self, from: data),
              !hits.isEmpty else {
            return nil
        }
        return hits
    }

    static func modelReadableOutput(from payload: String, query: String) -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let hits = hits(from: payload), !hits.isEmpty {
            var lines = ["Web search results for \"\(trimmedQuery)\":"]
            for (index, hit) in hits.enumerated() {
                lines.append("\(index + 1). \(hit.title)")
                lines.append("URL: \(hit.url)")
                let snippet = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                if !snippet.isEmpty {
                    lines.append("Snippet: \(snippet)")
                }
            }
            return lines.joined(separator: "\n")
        }

        if let error = errorMessage(from: payload) {
            return "Web search error: \(error)"
        }

        return "Web search error: Web search failed. Please try again."
    }

    private static func hitsPayload(_ hits: [WebHit]) -> String {
        guard let data = try? JSONEncoder().encode(hits),
              let string = String(data: data, encoding: .utf8) else {
            return errorPayload("Web search failed. Please try again.")
        }
        return string
    }

    private static func errorPayload(_ message: String) -> String {
        let payload = ["error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Web search failed. Please try again.\"}"
        }
        return string
    }

    private static func normalizedSafeSearch(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "strict":
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        default:
            return "moderate"
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        let ns = error as NSError
        let code = (error as? URLError)?.code ?? URLError.Code(rawValue: ns.code)
        switch code {
        case .timedOut:
            return "Web search timed out. Please try again."
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
            return "Web search is unavailable right now. Check your internet connection and try again."
        case .cancelled:
            return "Web search was cancelled."
        default:
            if let localized = (error as? LocalizedError)?.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !localized.isEmpty {
                return localized
            }
            let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return localized.isEmpty ? "Web search failed. Please try again." : localized
        }
    }
}

enum AFMToolExecutionMapper {
    static func resolve(_ summary: AFMToolExecutionSummary) -> AFMResolvedToolExecution {
        var resolvedCalls: [AFMResolvedToolCall] = []
        var resolvedHits: [WebHit]?
        var resolvedError: String?
        var usedWebSearch = false

        for call in summary.calls {
            let isWebSearch = call.toolName == "noema.web.retrieve"
            let isPython = call.toolName == "noema.python.execute"
            let isMemory = call.toolName == "noema.memory"
            // Legacy only: the escalation tool was removed in favor of the
            // Dynamic Profile baton-pass (AFMDynamicProfileRouting.swift),
            // which is never recorded. This mapping keeps any old recorded
            // summaries rendering correctly.
            let isPCC = call.toolName == "noema.afm.escalateToPrivateCloudCompute"
            let displayName: String = {
                if isWebSearch { return "Web Search" }
                if isPython { return "Python" }
                if isMemory { return "Memory" }
                if isPCC { return "Private Cloud Compute" }
                return "Tool"
            }()
            let iconName: String = {
                if isWebSearch { return "globe" }
                if isPython { return "chevron.left.forwardslash.chevron.right" }
                if isMemory { return "bookmark" }
                if isPCC { return "cloud" }
                return "wrench.and.screwdriver"
            }()

            resolvedCalls.append(
                AFMResolvedToolCall(
                    toolName: call.toolName,
                    displayName: displayName,
                    iconName: iconName,
                    requestParams: call.requestParams,
                    result: call.result,
                    error: call.error,
                    timestamp: call.timestamp
                )
            )

            guard isWebSearch else { continue }
            usedWebSearch = true
            if let result = call.result, let hits = AFMWebSearchExecution.hits(from: result) {
                resolvedHits = hits
                resolvedError = nil
            } else if let error = call.error ?? call.result.flatMap(AFMWebSearchExecution.errorMessage(from:)) {
                resolvedHits = nil
                resolvedError = error
            }
        }

        return AFMResolvedToolExecution(
            calls: resolvedCalls,
            usedWebSearch: usedWebSearch,
            webHits: resolvedHits,
            webError: resolvedError
        )
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
final class AFMWebSearchTool: FoundationModels.Tool {
    let name = "noema.web.retrieve"
    let description = "Search the web for fresh information and return results with title, url, and snippet."

    private let recorder: AFMToolRecorder?

    init(recorder: AFMToolRecorder? = nil) {
        self.recorder = recorder
    }

    @Generable
    struct Arguments {
        @Guide(description: "Search query to look up on the web")
        var query: String

        @Guide(description: "Number of results to return", .range(1...5))
        var count: Int

        @Guide(description: "Content filtering level: off, moderate, or strict")
        var safesearch: String
    }

    func call(arguments: Arguments) async throws -> String {
        let normalizedQuery = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedCount = max(1, min(arguments.count, 5))
        let normalizedSafeSearch = {
            switch arguments.safesearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "off", "strict":
                return arguments.safesearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            default:
                return "moderate"
            }
        }()
        let payload = await AFMWebSearchExecution.perform(
            query: normalizedQuery,
            count: clampedCount,
            safesearch: normalizedSafeSearch
        )
        await recorder?.record(
            AFMToolCallSummary(
                toolName: name,
                requestParams: [
                    "query": AnyCodable(normalizedQuery),
                    "count": AnyCodable(clampedCount),
                    "safesearch": AnyCodable(normalizedSafeSearch)
                ],
                result: payload,
                error: AFMWebSearchExecution.errorMessage(from: payload),
                timestamp: Date()
            )
        )
        return AFMWebSearchExecution.modelReadableOutput(from: payload, query: normalizedQuery)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
final class AFMPythonTool: FoundationModels.Tool {
    let name = "noema.python.execute"
    let description = "Execute sandboxed Python 3 code for calculations, parsing, data processing, and other computational work."

    private let recorder: AFMToolRecorder?

    init(recorder: AFMToolRecorder? = nil) {
        self.recorder = recorder
    }

    @Generable
    struct Arguments {
        @Guide(description: "Runnable Python 3 code. Use print() to produce output.")
        var code: String
    }

    func call(arguments: Arguments) async throws -> String {
        struct PythonArgumentsPayload: Encodable {
            let code: String
        }

        let payloadData = try await PythonTool().call(
            args: JSONEncoder().encode(PythonArgumentsPayload(code: arguments.code))
        )
        let payload = String(data: payloadData, encoding: .utf8) ?? "{\"error\":\"Python execution failed.\"}"
        await recorder?.record(
            AFMToolCallSummary(
                toolName: name,
                requestParams: ["code": AnyCodable(arguments.code)],
                result: payload,
                error: AFMWebSearchExecution.errorMessage(from: payload),
                timestamp: Date()
            )
        )
        if let result = try? JSONDecoder().decode(PythonExecutionResult.self, from: payloadData) {
            var lines = ["Python execution results:"]
            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("stdout:\n\(result.stdout)")
            }
            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("stderr:\n\(result.stderr)")
            }
            if let error = result.error, !error.isEmpty {
                lines.append("error: \(error)")
            }
            lines.append("exit_code: \(result.exitCode)")
            return lines.joined(separator: "\n")
        }
        return payload
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
final class AFMMemoryTool: FoundationModels.Tool {
    let name = "noema.memory"
    let description = "Read and update persistent on-device memory entries that remain available across conversations."

    private let recorder: AFMToolRecorder?

    init(recorder: AFMToolRecorder? = nil) {
        self.recorder = recorder
    }

    @Generable
    struct Arguments {
        @Guide(description: "Memory operation: list, view, create, replace, insert, str_replace, delete, or rename.")
        var operation: String

        @Guide(description: "Stable memory entry id for targeting an existing memory.")
        var entry_id: String?

        @Guide(description: "Entry title. Required for create and may be used to look up an existing memory if entry_id is omitted.")
        var title: String?

        @Guide(description: "Entry content. Required for create, replace, and insert.")
        var content: String?

        @Guide(description: "Existing text to replace for str_replace.")
        var old_string: String?

        @Guide(description: "Replacement text for str_replace, or the new title for rename.")
        var new_string: String?

        @Guide(description: "Character offset for insert. Omit to append at the end.")
        var insert_at: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        struct Payload: Encodable {
            let operation: String
            let entry_id: String?
            let title: String?
            let content: String?
            let old_string: String?
            let new_string: String?
            let insert_at: Int?
        }

        let payload = Payload(
            operation: arguments.operation,
            entry_id: arguments.entry_id,
            title: arguments.title,
            content: arguments.content,
            old_string: arguments.old_string,
            new_string: arguments.new_string,
            insert_at: arguments.insert_at
        )

        let payloadData = try await MemoryTool().call(args: JSONEncoder().encode(payload))
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{\"error\":\"Memory tool failed.\"}"
        var requestParams: [String: AnyCodable] = [
            "operation": AnyCodable(arguments.operation)
        ]
        if let entryID = arguments.entry_id {
            requestParams["entry_id"] = AnyCodable(entryID)
        }
        if let title = arguments.title {
            requestParams["title"] = AnyCodable(title)
        }
        if let content = arguments.content {
            requestParams["content"] = AnyCodable(content)
        }
        if let oldString = arguments.old_string {
            requestParams["old_string"] = AnyCodable(oldString)
        }
        if let newString = arguments.new_string {
            requestParams["new_string"] = AnyCodable(newString)
        }
        if let insertAt = arguments.insert_at {
            requestParams["insert_at"] = AnyCodable(insertAt)
        }
        await recorder?.record(
            AFMToolCallSummary(
                toolName: name,
                requestParams: requestParams,
                result: payloadString,
                error: nil,
                timestamp: Date()
            )
        )

        if let response = ToolCallViewSupport.parseMemoryResult(from: payloadString) {
            var lines = ["Memory tool result:"]
            lines.append("operation: \(response.operation)")
            if let message = response.message, !message.isEmpty {
                lines.append("message: \(message)")
            }
            if let entry = response.entry {
                lines.append("title: \(entry.title)")
                lines.append("content: \(entry.content)")
                lines.append("entry_id: \(entry.id)")
            } else if let entries = response.entries {
                lines.append("entries: \(entries.count)")
                for entry in entries {
                    lines.append("- \(entry.title): \(entry.content)")
                }
            }
            if let error = response.error, !error.isEmpty {
                lines.append("error: \(error)")
            }
            return lines.joined(separator: "\n")
        }

        return payloadString
    }
}

#endif
