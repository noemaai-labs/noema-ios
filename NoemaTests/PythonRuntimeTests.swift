import Foundation
import XCTest
@testable import Noema

final class PythonRuntimeTests: XCTestCase {
    func testEmbeddedExecutorReportsUnavailableWhenPathsAreMissing() {
        let executor = EmbeddedPythonExecutor(
            runtimeRootURL: URL(fileURLWithPath: "/tmp/noema-missing-python"),
            stdlibURL: URL(fileURLWithPath: "/tmp/noema-missing-python/lib/python3.14"),
            tempRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("noema-python-tests", isDirectory: true),
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            timeoutClock: Date.init
        )

        XCTAssertFalse(executor.isAvailable)
        XCTAssertNotNil(executor.unavailableReason)
    }

    func testEmbeddedExecutorSmokeTest() async throws {
        let executor = try makeRuntimeExecutor()

        let result = try await executor.execute(code: "print(2 + 2)", timeout: 5)

        XCTAssertEqual(result.stdout, "4\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.error)
    }

    func testEmbeddedExecutorBlocksNetworkImportsAndExternalReads() async throws {
        let executor = try makeRuntimeExecutor()
        let outsidePath = "/etc/hosts"
        let code = """
        try:
            import socket
        except Exception as exc:
            print(type(exc).__name__)
        try:
            with open("\(outsidePath)", "r", encoding="utf-8") as handle:
                print(handle.read())
        except Exception as exc:
            print(type(exc).__name__)
        """

        let result = try await executor.execute(code: code, timeout: 5)

        XCTAssertTrue(result.stdout.contains("ImportError"))
        XCTAssertTrue(result.stdout.contains("PermissionError"))
    }

    func testEmbeddedExecutorAllowsTempDirectoryFileAccess() async throws {
        let executor = try makeRuntimeExecutor()
        let code = """
        from pathlib import Path
        path = Path("sample.txt")
        path.write_text("ok", encoding="utf-8")
        print(path.read_text(encoding="utf-8"))
        """

        let result = try await executor.execute(code: code, timeout: 5)

        XCTAssertEqual(result.stdout, "ok\n")
        XCTAssertNil(result.error)
    }

    func testExecutorCapturesNotebookArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-python-artifact-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "name,value\nalpha,1\nbeta,2\n".write(
            to: root.appendingPathComponent("table.csv"),
            atomically: true,
            encoding: .utf8
        )
        try "artifact notes".write(
            to: root.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data([
            137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
            0, 0, 0, 1, 0, 0, 0, 1, 8, 4, 0, 0, 0, 181, 28, 12, 2,
            0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 252, 255, 31,
            0, 3, 3, 2, 0, 239, 191, 167, 219, 0, 0, 0, 0, 73, 69,
            78, 68, 174, 66, 96, 130
        ]).write(to: root.appendingPathComponent("plot.png"))

        let artifacts = PythonExecutionArtifactCollector.collect(from: root)

        let table = try XCTUnwrap(artifacts.first { $0.relativePath == "table.csv" })
        XCTAssertEqual(table.kind, "table")
        XCTAssertEqual(table.mimeType, "text/csv")
        XCTAssertTrue(table.preview?.contains("alpha,1") ?? false)
        XCTAssertEqual(
            Array(ToolCallViewSupport.tablePreviewRows(for: table).prefix(2)),
            [["name", "value"], ["alpha", "1"]]
        )

        let image = try XCTUnwrap(artifacts.first { $0.relativePath == "plot.png" })
        XCTAssertEqual(image.kind, "image")
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertNotNil(image.base64Data)

        let notes = try XCTUnwrap(artifacts.first { $0.relativePath == "notes.txt" })
        XCTAssertEqual(notes.kind, "text")
        XCTAssertEqual(notes.preview, "artifact notes")
    }

    func testEmbeddedExecutorTimesOutBusyLoop() async throws {
        let executor = try makeRuntimeExecutor()
        let result = try await executor.execute(code: "while True:\n    pass", timeout: 1)

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertNotNil(result.error)
    }

    func testEmbeddedExecutorRecoversAfterFailure() async throws {
        let executor = try makeRuntimeExecutor()
        _ = try await executor.execute(code: "raise ValueError('boom')", timeout: 5)

        let result = try await executor.execute(code: "print('still works')", timeout: 5)

        XCTAssertEqual(result.stdout, "still works\n")
        XCTAssertNil(result.error)
    }

    private func makeRuntimeExecutor(file: StaticString = #filePath) throws -> any PythonExecutor {
#if os(macOS)
        let testsURL = URL(fileURLWithPath: "\(file)")
        let projectRoot = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let frameworkRoot = projectRoot
            .appendingPathComponent("Frameworks/Python-macOS.xcframework/macos-arm64_x86_64/Python.framework/Versions/3.14", isDirectory: true)
        let stdlibRoot = frameworkRoot.appendingPathComponent("lib/python3.14", isDirectory: true)

        return EmbeddedPythonExecutor(
            runtimeRootURL: frameworkRoot,
            stdlibURL: stdlibRoot,
            tempRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("noema-python-tests", isDirectory: true),
            executableURL: Bundle.main.executableURL,
            timeoutClock: Date.init
        )
#else
        guard let executor = PythonRuntime.makeExecutor() else {
            throw XCTSkip("Embedded Python runtime is not available in the current test host.")
        }
        return executor
#endif
    }
}
