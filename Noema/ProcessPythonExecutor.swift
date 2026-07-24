#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation

/// macOS Python executor using Foundation.Process to spawn system Python 3.
struct ProcessPythonExecutor: PythonExecutor, Sendable {

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: pythonPath)
    }

    func execute(code: String, timeout: TimeInterval) async throws -> PythonExecutionResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-python-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("script.py")
        let sandboxedCode = pythonSandboxPreamble + code
        try sandboxedCode.write(to: scriptURL, atomically: true, encoding: .utf8)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-u", scriptURL.path] // -u for unbuffered output
        process.currentDirectoryURL = tempDir
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = [
            "PATH": "/usr/bin:/usr/local/bin",
            "HOME": tempDir.path,
            "TMPDIR": tempDir.path,
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONIOENCODING": "utf-8",
            pythonSandboxAllowedRootEnvVar: tempDir.path,
        ]

        // Run process with timeout
        let result: PythonExecutionResult = try await withThrowingTaskGroup(of: PythonExecutionResult.self) { group in
            // Task 1: Run the process
            group.addTask {
                try process.run()
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                let artifacts = PythonExecutionArtifactCollector.collect(from: tempDir)

                return PythonExecutionResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus,
                    executionTimeMs: elapsed,
                    error: process.terminationStatus != 0 ? "Process exited with code \(process.terminationStatus)" : nil,
                    timedOut: false,
                    artifacts: artifacts
                )
            }

            // Task 2: Timeout watchdog
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // If we get here, timeout expired
                process.terminate()
                // Give it a moment to clean up, then force kill
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning {
                    process.interrupt()
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                let artifacts = PythonExecutionArtifactCollector.collect(from: tempDir)

                return PythonExecutionResult(
                    stdout: stdout,
                    stderr: stderr + "\n[Execution timed out after \(Int(timeout))s]",
                    exitCode: -1,
                    executionTimeMs: elapsed,
                    error: "Execution timed out after \(Int(timeout)) seconds",
                    timedOut: true,
                    artifacts: artifacts
                )
            }

            // Return whichever finishes first
            let firstResult = try await group.next()!
            group.cancelAll()
            return firstResult
        }

        return result
    }

    // MARK: - Private

    private var pythonPath: String {
        // Prefer /usr/bin/python3, fall back to common Homebrew locations
        for path in ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/bin/python3"
    }
}
#endif
