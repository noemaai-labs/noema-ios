#if ((os(iOS) && !targetEnvironment(macCatalyst)) || os(visionOS) || (os(macOS) && !targetEnvironment(macCatalyst)))
import Foundation

struct EmbeddedPythonExecutor: PythonExecutor, Sendable {
    let runtimeRootURL: URL?
    let stdlibURL: URL?
    let tempRootURL: URL
    let executableURL: URL?
    let timeoutClock: @Sendable () -> Date

    init(
        runtimeRootURL: URL?,
        stdlibURL: URL?,
        tempRootURL: URL,
        executableURL: URL?,
        timeoutClock: @escaping @Sendable () -> Date
    ) {
        self.runtimeRootURL = runtimeRootURL
        self.stdlibURL = stdlibURL
        self.tempRootURL = tempRootURL
        self.executableURL = executableURL
        self.timeoutClock = timeoutClock
    }

    var isAvailable: Bool {
        unavailableReason == nil
    }

    var unavailableReason: String? {
        guard let runtimeRootURL else {
            return "Embedded Python runtime is missing from the app bundle."
        }
        guard FileManager.default.fileExists(atPath: runtimeRootURL.path) else {
            return "Embedded Python runtime is missing from the app bundle."
        }
        guard let stdlibURL else {
            return "Embedded Python standard library is missing from the app bundle."
        }
        guard FileManager.default.fileExists(atPath: stdlibURL.path) else {
            return "Embedded Python standard library is missing from the app bundle."
        }
        return nil
    }

    func execute(code: String, timeout: TimeInterval) async throws -> PythonExecutionResult {
        guard let runtimeRootURL, let stdlibURL else {
            throw EmbeddedPythonExecutorError.runtimeUnavailable(unavailableReason ?? "Embedded Python runtime unavailable.")
        }
        guard isAvailable else {
            throw EmbeddedPythonExecutorError.runtimeUnavailable(unavailableReason ?? "Embedded Python runtime unavailable.")
        }

        try FileManager.default.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
        let executionDirectory = tempRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: executionDirectory) }

        #if DEBUG
        await logger.log("[EmbeddedPythonExecutor] execute start root=\(runtimeRootURL.path) stdlib=\(stdlibURL.path)")
        #endif

        let initResult = noema_embedded_python_initialize(
            runtimeRootURL.path,
            stdlibURL.path,
            executableURL?.path,
            false
        )

        defer {
            noema_embedded_python_free_string(initResult.error_message)
        }

        guard initResult.success else {
            let message = initResult.error_message.map { String(cString: $0) } ?? "Embedded Python initialization failed."
            #if DEBUG
            await logger.log("[EmbeddedPythonExecutor] init failed: \(message)")
            #endif
            throw EmbeddedPythonExecutorError.initializationFailed(message)
        }

        let executionResult = noema_embedded_python_execute(
            code,
            pythonSandboxPreamble,
            executionDirectory.path,
            timeout
        )

        defer {
            noema_embedded_python_free_string(executionResult.json)
            noema_embedded_python_free_string(executionResult.error_message)
        }

        guard executionResult.success else {
            let message = executionResult.error_message.map { String(cString: $0) } ?? "Embedded Python execution failed."
            #if DEBUG
            await logger.log("[EmbeddedPythonExecutor] execution failed: \(message)")
            #endif
            throw EmbeddedPythonExecutorError.executionFailed(message)
        }

        guard let jsonPointer = executionResult.json else {
            throw EmbeddedPythonExecutorError.executionFailed("Embedded Python returned an empty payload.")
        }

        let payload = String(cString: jsonPointer)
        guard let data = payload.data(using: .utf8) else {
            throw EmbeddedPythonExecutorError.executionFailed("Embedded Python returned invalid UTF-8.")
        }

        do {
            let decoded = try JSONDecoder().decode(PythonExecutionResult.self, from: data)
            #if DEBUG
            await logger.log("[EmbeddedPythonExecutor] execute complete exitCode=\(decoded.exitCode) timedOut=\(decoded.timedOut)")
            #endif
            return decoded
        } catch {
            throw EmbeddedPythonExecutorError.executionFailed("Embedded Python returned malformed JSON: \(payload)")
        }
    }
}

enum EmbeddedPythonExecutorError: LocalizedError {
    case runtimeUnavailable(String)
    case initializationFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let message),
             .initializationFailed(let message),
             .executionFailed(let message):
            return message
        }
    }
}
#endif
