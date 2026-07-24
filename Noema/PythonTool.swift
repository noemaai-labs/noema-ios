import Foundation

public struct PythonTool: Tool {
    public let name = "noema.python.execute"
    public let description = "Execute Python code and return stdout/stderr output. Use for calculations, data processing, text manipulation, or any task that benefits from code execution. The code runs in a sandboxed environment with a 30-second timeout."
    public let schema = #"""
    { "type":"object", "properties":{
        "code":{"type":"string","description":"Python 3 code to execute. Use print() to produce output."}
    }, "required":["code"] }
    """#

    public func call(args: Data) async throws -> Data {
        struct PythonArgs: Decodable {
            let code: String
        }

        let input = try JSONDecoder().decode(PythonArgs.self, from: args)

        let maxCodeLength = 100_000
        guard input.code.count <= maxCodeLength else {
            let errorPayload = ["error": "The code is too long (max \(maxCodeLength) characters). Send a shorter script."]
            return try JSONSerialization.data(withJSONObject: errorPayload)
        }

        #if DEBUG
        await logger.log(
            """
            [PythonTool] \u{21E2} request
              code length: \(input.code.count) chars
              first 200 chars: \(String(input.code.prefix(200)))
            """
        )
        #endif

        let runtimeStatus = PythonRuntime.status()

        guard PythonToolGate.isAvailable() else {
            if runtimeStatus.isAvailable == false, let reason = runtimeStatus.reason, !reason.isEmpty {
                let errorPayload = ["error": reason]
                return try JSONSerialization.data(withJSONObject: errorPayload)
            }
            let errorPayload = ["error": "Python execution is disabled."]
            return try JSONSerialization.data(withJSONObject: errorPayload)
        }

        guard let executor = PythonRuntime.makeExecutor() else {
            let errorPayload = ["error": runtimeStatus.reason ?? "Python is not available on this platform."]
            return try JSONSerialization.data(withJSONObject: errorPayload)
        }

        do {
            let result = try await executor.execute(code: input.code, timeout: 30.0)

            #if DEBUG
            await logger.log(
                """
                [PythonTool] \u{21E0} response
                  exitCode: \(result.exitCode)
                  timedOut: \(result.timedOut)
                  stdout: \(result.stdout.prefix(200))
                  stderr: \(result.stderr.prefix(200))
                  time: \(result.executionTimeMs)ms
                """
            )
            #endif

            // Cap stdout/stderr before the result enters the transcript and the model
            // context — a single print('x' * 10**7) would otherwise persist megabytes
            // into the session and blow the prompt budget on the continuation turn.
            let maxStdout = 20_000
            let maxStderr = 8_000
            let bounded = PythonExecutionResult(
                stdout: Self.truncated(result.stdout, limit: maxStdout),
                stderr: Self.truncated(result.stderr, limit: maxStderr),
                exitCode: result.exitCode,
                executionTimeMs: result.executionTimeMs,
                error: result.error,
                timedOut: result.timedOut,
                artifacts: result.artifacts
            )
            return try JSONEncoder().encode(bounded)

        } catch {
            #if DEBUG
            await logger.log(
                """
                [PythonTool] \u{274C} error
                  message: \(error.localizedDescription)
                """
            )
            #endif

            let message: String
            if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
                message = localized
            } else {
                let desc = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                message = desc.isEmpty ? "Python execution failed." : desc
            }

            let errorPayload = ["error": message]
            return try JSONSerialization.data(withJSONObject: errorPayload)
        }
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… [output truncated: \(text.count - limit) more characters]"
    }
}
