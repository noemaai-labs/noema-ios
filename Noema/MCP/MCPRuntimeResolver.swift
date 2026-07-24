#if os(macOS)
import Foundation

struct MCPResolvedRuntime: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: URL?
    var summary: String
    var packageSpecification: String?
}

enum MCPRuntimeResolutionError: LocalizedError, Equatable {
    case directEditionRequired
    case executableNotFound(String, [String])
    case invalidWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .directEditionRequired:
            String(localized: "App Store apps cannot launch arbitrary local MCP server commands. Remote MCP servers over HTTPS are supported.")
        case .executableNotFound(let name, let hints):
            String(localized: "Could not find \(name). Checked: \(hints.joined(separator: ", ")).")
        case .invalidWorkingDirectory(let value):
            String(localized: "The working directory does not exist: \(value)")
        }
    }
}

enum MCPDirectEdition {
    static var isAvailable: Bool {
        if Bundle.main.bundleIdentifier?.hasSuffix(".direct") == true { return true }
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugIns.appendingPathComponent("NoemaMCPHost.xpc").path)
    }
}

enum MCPRuntimeResolver {
    static func resolve(configuration: MCPTransportConfiguration) throws -> MCPResolvedRuntime {
        guard case .stdio(let command, let arguments, let workingDirectory, let configuredEnvironment) = configuration else {
            throw MCPRuntimeResolutionError.executableNotFound("stdio", [])
        }
        guard MCPDirectEdition.isAvailable else { throw MCPRuntimeResolutionError.directEditionRequired }

        var environment = ProcessInfo.processInfo.environment
        let support = MCPConfigurationStore.directory
        environment["npm_config_cache"] = support.appendingPathComponent("MCP/npm-cache", isDirectory: true).path
        environment["npm_config_update_notifier"] = "false"
        environment["NO_UPDATE_NOTIFIER"] = "1"
        for (key, value) in try MCPReferenceResolver.resolve(configuredEnvironment) { environment[key] = value }

        let workingURL: URL?
        if let workingDirectory {
            let resolved = try MCPReferenceResolver.resolve(workingDirectory)
            let url = URL(fileURLWithPath: NSString(string: resolved).expandingTildeInPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw MCPRuntimeResolutionError.invalidWorkingDirectory(resolved)
            }
            workingURL = url
        } else { workingURL = nil }

        let resolvedCommand = try MCPReferenceResolver.resolve(command)
        let resolvedArguments = try arguments.map { try MCPReferenceResolver.resolve($0) }
        let executable = try locate(resolvedCommand, environment: environment)
        let logicalName = URL(fileURLWithPath: resolvedCommand).lastPathComponent.lowercased()
        let package = logicalName == "npx" ? npxPackageSpecification(resolvedArguments) : nil
        let source = executable.path.contains("/Contents/Resources/MCPRuntime/") ? String(localized: "Built-in Node runtime") : executable.deletingLastPathComponent().path
        return .init(
            executableURL: executable, arguments: resolvedArguments, environment: environment,
            workingDirectory: workingURL, summary: "\(executable.lastPathComponent) · \(source)", packageSpecification: package
        )
    }

    private static func locate(_ command: String, environment: [String: String]) throws -> URL {
        let fm = FileManager.default
        let expanded = NSString(string: command).expandingTildeInPath
        if expanded.contains("/") {
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            if fm.isExecutableFile(atPath: url.path) { return url }
            throw MCPRuntimeResolutionError.executableNotFound(command, [url.path])
        }

        let logical = command.lowercased()
        var directories: [String] = []
        if ["node", "npm", "npx"].contains(logical),
           let embedded = Bundle.main.resourceURL?.appendingPathComponent("MCPRuntime/bin", isDirectory: true).path {
            directories.append(embedded)
        }
        directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            NSString(string: "~/.volta/bin").expandingTildeInPath,
            NSString(string: "~/.local/bin").expandingTildeInPath,
            NSString(string: "~/.bun/bin").expandingTildeInPath,
            NSString(string: "~/.deno/bin").expandingTildeInPath,
            NSString(string: "~/.asdf/shims").expandingTildeInPath,
            NSString(string: "~/.local/share/mise/shims").expandingTildeInPath
        ]
        var checked: [String] = []
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(command)
            checked.append(candidate.path)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate.resolvingSymlinksInPath() }
        }
        throw MCPRuntimeResolutionError.executableNotFound(command, checked)
    }

    static func npxPackageSpecification(_ arguments: [String]) -> String? {
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if ["--package", "-p", "--cache", "--userconfig", "--call", "-c"].contains(argument) { skipNext = true; continue }
            if argument.hasPrefix("--package=") { return String(argument.dropFirst("--package=".count)) }
            if argument.hasPrefix("-") { continue }
            return argument
        }
        return nil
    }
}

@objc private protocol MCPProcessHostXPCProtocol {
    func launch(
        executable: String, arguments: [String], environment: [String: String], workingDirectory: String?,
        withReply reply: @escaping (NSNumber?, FileHandle?, FileHandle?, FileHandle?, String?) -> Void
    )
    func terminate(processID: NSNumber, withReply reply: @escaping () -> Void)
    func terminateAll(withReply reply: @escaping () -> Void)
}

final class MCPHostedProcess: @unchecked Sendable {
    let processID: Int32
    let standardOutput: FileHandle
    let standardInput: FileHandle
    let standardError: FileHandle
    private let connection: NSXPCConnection

    init(processID: Int32, standardOutput: FileHandle, standardInput: FileHandle, standardError: FileHandle, connection: NSXPCConnection) {
        self.processID = processID; self.standardOutput = standardOutput; self.standardInput = standardInput
        self.standardError = standardError; self.connection = connection
    }

    func terminate() async {
        guard let proxy = connection.remoteObjectProxy as? MCPProcessHostXPCProtocol else { connection.invalidate(); return }
        await withCheckedContinuation { continuation in
            proxy.terminate(processID: NSNumber(value: processID)) { self.connection.invalidate(); continuation.resume() }
        }
    }
}

enum MCPDirectProcessLauncher {
    static func launch(_ runtime: MCPResolvedRuntime) async throws -> MCPHostedProcess {
        let connection = NSXPCConnection(serviceName: "ai.noema.NoemaMCPHost")
        let interface = NSXPCInterface(with: MCPProcessHostXPCProtocol.self)
        connection.remoteObjectInterface = interface; connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in connection.invalidate() }) as? MCPProcessHostXPCProtocol else {
            connection.invalidate(); throw ToolError.executionFailed(String(localized: "The MCP process host is unavailable."))
        }
        return try await withCheckedThrowingContinuation { continuation in
            proxy.launch(
                executable: runtime.executableURL.path, arguments: runtime.arguments,
                environment: runtime.environment, workingDirectory: runtime.workingDirectory?.path
            ) { processID, stdout, stdin, stderr, error in
                guard let processID, let stdout, let stdin, let stderr else {
                    connection.invalidate(); continuation.resume(throwing: ToolError.executionFailed(error ?? String(localized: "The MCP server could not be started."))); return
                }
                continuation.resume(returning: MCPHostedProcess(
                    processID: processID.int32Value, standardOutput: stdout, standardInput: stdin, standardError: stderr, connection: connection
                ))
            }
        }
    }
}
#endif
