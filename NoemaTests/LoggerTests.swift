import Foundation
import XCTest
@testable import Noema

private final class LockedLogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let snapshot = messages
        lock.unlock()
        return snapshot
    }
}

final class LoggerTests: XCTestCase {
    func testDiagnosticLogRedactorRemovesPromptsAndPrivateSourceSnippets() {
        let prompt = "Summarize Project Acorn for ada@example.com and include 415-555-0100."
        let sourceSnippet = "Private source snippet: revenue miss, employee medical leave, board-only appendix."
        let lines = [
            "[ChatVM][SendAttempt] \(prompt)",
            "[ChatVM] USER ▶︎ \(prompt)",
            "[Llama][Prompt] <s>[INST] \(sourceSnippet) [/INST]",
            "[Tool] TOOL_CALL detected: {\"name\":\"noema.web.retrieve\",\"arguments\":{\"query\":\"\(prompt)\",\"source\":\"\(sourceSnippet)\"}}",
            "[RAG] retrieve.done picked=2 totalTokens=124 chars=340"
        ]

        let redacted = lines.map(DiagnosticLogRedactor.redactLine(_:))
        let joined = redacted.joined(separator: "\n")

        XCTAssertFalse(joined.contains(prompt))
        XCTAssertFalse(joined.contains(sourceSnippet))
        XCTAssertFalse(joined.contains("ada@example.com"))
        XCTAssertFalse(joined.contains("415-555-0100"))
        XCTAssertTrue(joined.contains("[ChatVM][SendAttempt] <redacted"))
        XCTAssertTrue(joined.contains("[Tool] TOOL_CALL detected: <redacted"))
        XCTAssertTrue(joined.contains("hash="))
        XCTAssertTrue(joined.contains("[RAG] retrieve.done picked=2 totalTokens=124 chars=340"))
    }

    func testDiagnosticRecentLogPayloadIsBoundedAndRedacted() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-redaction-test-\(UUID().uuidString).log")
        let prompt = "Find mentions of private merger Falcon in my imported board notes."
        let contents = [
            "[Runtime] ready",
            "[ChatVM][SendAttempt] \(prompt)",
            "[Tool] Result from noema.web.retrieve: confidential result body"
        ].joined(separator: "\n")
        try contents.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let payload = DiagnosticLogRedactor.recentLogPayload(from: tempURL, maxLines: 2)
        let lines = try XCTUnwrap(payload["lines"] as? [String])

        XCTAssertEqual(payload["sourceFile"] as? String, tempURL.lastPathComponent)
        XCTAssertEqual(payload["maxLines"] as? Int, 2)
        XCTAssertEqual(payload["omittedLineCount"] as? Int, 1)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.joined(separator: "\n").contains(prompt))
        XCTAssertFalse(lines.joined(separator: "\n").contains("confidential result body"))
        XCTAssertTrue(lines.allSatisfy { $0.contains("<redacted") })
    }

    @MainActor
    func testSendMessageLogsAttemptBeforeLoadingBlock() async {
        let vm = ChatVM()
        vm.loading = true

        let logs = await captureLogs {
            await vm.sendMessage("hello")
        }

        assertLogOrder(
            logs,
            first: "[ChatVM][SendAttempt] hello",
            second: "[ChatVM] Blocking send: model still loading"
        )
    }

    @MainActor
    func testSendMessageLogsAttemptBeforeCrossSessionBlock() async {
        let vm = ChatVM()
        let activeSession = vm.sessions[0]
        let streamingSession = ChatVM.Session(
            title: "Other",
            messages: [.init(role: "🤖", text: "", timestamp: Date(), streaming: true)],
            date: Date(),
            datasetID: ""
        )
        vm.sessions = [activeSession, streamingSession]
        vm.activeSessionID = activeSession.id
        vm.setStreamSessionIndexForTesting(1)

        let logs = await captureLogs {
            await vm.sendMessage("hello")
        }

        assertLogOrder(
            logs,
            first: "[ChatVM][SendAttempt] hello",
            second: "[ChatVM] Blocking send: another chat is still generating"
        )
    }

    @MainActor
    func testSuccessfulSendPathLogsAttemptBeforeUserLine() async {
        let vm = ChatVM()
        vm.activeSessionID = nil

        let logs = await captureLogs {
            await vm.sendMessage("hello")
        }

        assertLogOrder(
            logs,
            first: "[ChatVM][SendAttempt] hello",
            second: "[ChatVM] USER ▶︎ hello"
        )
    }

    private func captureLogs(_ body: () async -> Void) async -> [String] {
        let store = LockedLogStore()
        let token = await logger.addObserver { message in
            store.append(message)
        }

        await body()

        await logger.removeObserver(token)
        return store.snapshot()
    }

    private func assertLogOrder(
        _ logs: [String],
        first: String,
        second: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let firstIndex = logs.firstIndex(of: first) else {
            XCTFail("Missing log: \(first)\nCaptured logs: \(logs)", file: file, line: line)
            return
        }
        guard let secondIndex = logs.firstIndex(of: second) else {
            XCTFail("Missing log: \(second)\nCaptured logs: \(logs)", file: file, line: line)
            return
        }
        XCTAssertLessThan(firstIndex, secondIndex, "Expected '\(first)' before '\(second)'. Logs: \(logs)", file: file, line: line)
    }
}
