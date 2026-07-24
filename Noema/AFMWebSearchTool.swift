import Foundation

enum AFMToolCallPhase: Equatable, Sendable {
    case executing
    case completed
    case failed

    var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

struct AFMToolCallSummary: Sendable {
    let id: String
    let toolName: String
    let requestParams: [String: AnyCodable]
    let phase: AFMToolCallPhase
    let result: String?
    let error: String?
    let timestamp: Date
    let completedAt: Date?

    init(
        id: String = UUID().uuidString,
        toolName: String,
        requestParams: [String: AnyCodable],
        phase: AFMToolCallPhase = .completed,
        result: String?,
        error: String?,
        timestamp: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.requestParams = requestParams
        self.phase = phase
        self.result = result
        self.error = error
        self.timestamp = timestamp
        self.completedAt = completedAt ?? (phase.isTerminal ? timestamp : nil)
    }
}

struct AFMToolExecutionSummary: Sendable {
    let calls: [AFMToolCallSummary]

    var isEmpty: Bool { calls.isEmpty }
}

struct AFMResolvedToolCall: Sendable {
    let id: String
    let toolName: String
    let displayName: String
    let iconName: String
    let requestParams: [String: AnyCodable]
    let phase: AFMToolCallPhase
    let result: String?
    let error: String?
    let timestamp: Date
    let completedAt: Date?
}

struct AFMResolvedToolExecution: Sendable {
    let calls: [AFMResolvedToolCall]
    let usedWebSearch: Bool
    let webHits: [WebHit]?
    let webError: String?
}

actor AFMToolRecorder {
    private var calls: [AFMToolCallSummary] = []
    private let onRecord: (@Sendable (AFMToolCallSummary) async -> Void)?

    init(onRecord: (@Sendable (AFMToolCallSummary) async -> Void)? = nil) {
        self.onRecord = onRecord
    }

    func reset() {
        calls.removeAll()
    }

    func record(_ summary: AFMToolCallSummary) async {
        if summary.phase.isTerminal {
            if let index = calls.firstIndex(where: { $0.id == summary.id }) {
                calls[index] = summary
            } else {
                calls.append(summary)
            }
        }
        // Native FoundationModels tools execute inside the response stream.
        // Publish both the executing event and its terminal update. The tool
        // awaits this callback before doing/returning work, so the chat can show
        // the card while execution is actually in progress.
        await onRecord?(summary)
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
            let (displayName, iconName): (String, String) = {
                switch call.toolName {
                case "noema.web.retrieve": return ("Web Search", "globe")
                case "noema.python.execute": return ("Python", "chevron.left.forwardslash.chevron.right")
                case "noema.memory": return ("Memory", "bookmark")
                case "noema.rag.search": return ("Dataset Search", "doc.text.magnifyingglass")
                case "noema.pdf.read": return ("PDF Reader", "doc.richtext")
                case "noema.chart.render": return ("Chart", "chart.bar")
                case "noema.calendar.events": return ("Calendar", "calendar")
                case "noema.calendar.addEvent": return ("Add Event", "calendar.badge.plus")
                case "noema.math.calculate": return ("Calculator", "function")
                case "noema.units.convert": return ("Unit Converter", "arrow.left.arrow.right")
                // Legacy only: the hidden AFM escalation tool has been removed.
                // Keep old recorded summaries rendering correctly.
                case "noema.afm.escalateToPrivateCloudCompute": return ("Private Cloud Compute", "cloud")
                default: return ("Tool", "wrench.and.screwdriver")
                }
            }()

            resolvedCalls.append(
                AFMResolvedToolCall(
                    id: call.id,
                    toolName: call.toolName,
                    displayName: displayName,
                    iconName: iconName,
                    requestParams: call.requestParams,
                    phase: call.phase,
                    result: call.result,
                    error: call.error,
                    timestamp: call.timestamp,
                    completedAt: call.completedAt
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

// The AFM web tool is now `AFMLoopbackToolAdapter(wrapping: WebRetrieveTool())`
// so PCC runs the same research/open/find pipeline as the loopback models.
// `AFMWebSearchExecution` above remains: its payload parsing serves the mapper
// and the legacy-result fallback.

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

        let callID = UUID().uuidString
        let startedAt = Date()
        let requestParams = ["code": AnyCodable(arguments.code)]
        await recorder?.record(
            AFMToolCallSummary(
                id: callID,
                toolName: name,
                requestParams: requestParams,
                phase: .executing,
                result: nil,
                error: nil,
                timestamp: startedAt
            )
        )
        let payloadData: Data
        do {
            payloadData = try await PythonTool().call(
                args: JSONEncoder().encode(PythonArgumentsPayload(code: arguments.code))
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder?.record(
                AFMToolCallSummary(
                    id: callID,
                    toolName: name,
                    requestParams: requestParams,
                    phase: .failed,
                    result: nil,
                    error: message,
                    timestamp: startedAt,
                    completedAt: Date()
                )
            )
            throw error
        }
        let payload = String(data: payloadData, encoding: .utf8) ?? "{\"error\":\"Python execution failed.\"}"
        let error = AFMWebSearchExecution.errorMessage(from: payload)
        await recorder?.record(
            AFMToolCallSummary(
                id: callID,
                toolName: name,
                requestParams: requestParams,
                phase: error == nil ? .completed : .failed,
                result: payload,
                error: error,
                timestamp: startedAt,
                completedAt: Date()
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
        let callID = UUID().uuidString
        let startedAt = Date()
        await recorder?.record(
            AFMToolCallSummary(
                id: callID,
                toolName: name,
                requestParams: requestParams,
                phase: .executing,
                result: nil,
                error: nil,
                timestamp: startedAt
            )
        )

        let payloadData: Data
        do {
            payloadData = try await MemoryTool().call(args: JSONEncoder().encode(payload))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder?.record(
                AFMToolCallSummary(
                    id: callID,
                    toolName: name,
                    requestParams: requestParams,
                    phase: .failed,
                    result: nil,
                    error: message,
                    timestamp: startedAt,
                    completedAt: Date()
                )
            )
            throw error
        }
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{\"error\":\"Memory tool failed.\"}"
        let error = AFMWebSearchExecution.errorMessage(from: payloadString)
        await recorder?.record(
            AFMToolCallSummary(
                id: callID,
                toolName: name,
                requestParams: requestParams,
                phase: error == nil ? .completed : .failed,
                result: payloadString,
                error: error,
                timestamp: startedAt,
                completedAt: Date()
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
