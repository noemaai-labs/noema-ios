#if os(macOS)
import CryptoKit
import Foundation
import Security

enum MCPConfigurationError: LocalizedError, Equatable {
    case invalidJSON(String)
    case missingServersObject
    case invalidServer(String, String)
    case unsupportedInput
    case missingSecret(String)
    case keychain(OSStatus)
    case externalConflict

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message): String(localized: "Invalid JSON: \(message)")
        case .missingServersObject: String(localized: "The configuration needs a top-level mcpServers object.")
        case .invalidServer(let id, let message): "\(id): \(message)"
        case .unsupportedInput: String(localized: "Paste an MCP URL, command, or JSON configuration.")
        case .missingSecret(let name): String(localized: "A required secret is missing: \(name)")
        case .keychain(let status): String(localized: "Keychain error (\(status)).")
        case .externalConflict: String(localized: "mcp.json changed outside Noema while you were editing.")
        }
    }
}

struct MCPImportPreview: Equatable, Sendable {
    struct Secret: Equatable, Sendable {
        var serverID: String
        var container: String
        var key: String
        var value: String
        var keychainName: String
    }
    var added: [String]
    var replaced: [String]
    var unchanged: [String]
    var secrets: [Secret]
    var resultingDocument: JSONValue
}

enum MCPCommandTokenizer {
    static func tokenize(_ source: String) throws -> [String] {
        enum Quote { case single, double }
        var quote: Quote?
        var escaping = false
        var token = ""
        var tokens: [String] = []

        func finish() {
            if !token.isEmpty { tokens.append(token); token = "" }
        }

        for character in source {
            if escaping { token.append(character); escaping = false; continue }
            switch (quote, character) {
            case (.single, "'"): quote = nil
            case (.double, "\""): quote = nil
            case (.double, "\\"): escaping = true
            case (nil, "'"): quote = .single
            case (nil, "\""): quote = .double
            case (nil, "\\"): escaping = true
            case (nil, let value) where value.isWhitespace: finish()
            default: token.append(character)
            }
        }
        guard quote == nil, !escaping else {
            throw MCPConfigurationError.invalidJSON(String(localized: "The command has an unfinished quote or escape."))
        }
        finish()
        guard !tokens.isEmpty else { throw MCPConfigurationError.unsupportedInput }

        // The tokenizer never invokes a shell. Reject syntax that is almost certainly
        // an attempt to build a shell pipeline so intent cannot change silently.
        let shellOperators: Set<String> = ["|", "||", "&&", ";", ">", ">>", "<", "&"]
        guard tokens.allSatisfy({ !shellOperators.contains($0) }) else {
            throw MCPConfigurationError.invalidServer("command", String(localized: "Shell operators are not supported. Add the executable and each argument directly."))
        }
        return tokens
    }
}

enum MCPAlias {
    static func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func make(serverID: String, toolName: String, existing: Set<String> = []) -> String {
        func safe(_ value: String) -> String {
            let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            let pieces = folded.split { !$0.isASCII || !($0.isLetter || $0.isNumber) }
            return pieces.joined(separator: "_")
        }
        let base = "mcp_\(safe(serverID))_\(safe(toolName))".prefix(48)
        let suffix = String(stableHash("\(serverID)\u{0}\(toolName)").prefix(8))
        var alias = "\(base)_\(suffix)"
        var counter = 2
        while existing.contains(alias) { alias = "\(base)_\(suffix)_\(counter)"; counter += 1 }
        return alias
    }
}

enum MCPKeychain {
    private static let service = "ai.noema.mcp"

    static func value(named name: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MCPConfigurationError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, named name: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status: OSStatus
        if SecItemCopyMatching(identity as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MCPConfigurationError.keychain(status) }
    }

    static func remove(named name: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ] as CFDictionary)
    }
}

enum MCPReferenceResolver {
    static func resolve(_ source: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let expression = try NSRegularExpression(pattern: #"\$\{(env|keychain):([A-Za-z_][A-Za-z0-9_.-]*)\}"#)
        var result = source
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed()
        for match in matches {
            guard let full = Range(match.range(at: 0), in: source),
                  let kindRange = Range(match.range(at: 1), in: source),
                  let nameRange = Range(match.range(at: 2), in: source) else { continue }
            let kind = String(source[kindRange]); let name = String(source[nameRange])
            let replacement: String?
            if kind == "env" { replacement = environment[name] }
            else { replacement = try MCPKeychain.value(named: name) }
            guard let replacement else { throw MCPConfigurationError.missingSecret(name) }
            result.replaceSubrange(full, with: replacement)
        }
        return result
    }

    static func resolve(_ values: [String: String]) throws -> [String: String] {
        try values.mapValues { try resolve($0) }
    }
}

@MainActor
final class MCPConfigurationStore: ObservableObject {
    static let shared = MCPConfigurationStore()

    static let emptyConfigurationText = "{\n  \"mcpServers\": {}\n}"
    private static let emptyDocument = JSONValue.object(["mcpServers": .object([:])])

    @Published private(set) var document: JSONValue = emptyDocument
    @Published private(set) var servers: [MCPServerConfiguration] = []
    @Published private(set) var rawText = emptyConfigurationText
    @Published private(set) var diagnostic: MCPConfigurationError?
    @Published private(set) var externalConflict = false

    nonisolated(unsafe) static var directoryOverrideForTesting: URL?
    private var lastKnownModification: Date?
    private var editorDirty = false
    private var watcher: Timer?

    nonisolated static var directory: URL {
        if let override = directoryOverrideForTesting { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noema", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("mcp.json") }
    static var lastKnownGoodURL: URL { directory.appendingPathComponent("mcp.last-known-good.json") }

    private init() {
        load()
        watcher = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkForExternalChange() }
        }
    }

    func load() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
                try persist(document, keepBackup: false)
            }
            let data = try Data(contentsOf: Self.fileURL)
            try applyValidated(data: data)
            lastKnownModification = modificationDate()
            diagnostic = nil
        } catch let error as MCPConfigurationError { diagnostic = error }
        catch { diagnostic = .invalidJSON(error.localizedDescription) }
    }

    func beginRawEditing() { editorDirty = true; externalConflict = false }
    func cancelRawEditing() { editorDirty = false; externalConflict = false; load() }

    func validate(raw: String) -> Result<[MCPServerConfiguration], MCPConfigurationError> {
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
            return .success(try Self.decodeServers(from: value))
        } catch let error as MCPConfigurationError { return .failure(error) }
        catch { return .failure(.invalidJSON(error.localizedDescription)) }
    }

    func save(raw: String, overwriteExternalChange: Bool = false) throws {
        if externalConflict && !overwriteExternalChange { throw MCPConfigurationError.externalConflict }
        let data = Data(raw.utf8)
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw MCPConfigurationError.invalidJSON(error.localizedDescription) }
        _ = try Self.decodeServers(from: value)
        try persist(value, keepBackup: true)
        try applyValidated(data: try Data(contentsOf: Self.fileURL))
        editorDirty = false; externalConflict = false; lastKnownModification = modificationDate()
    }

    func upsert(_ configuration: MCPServerConfiguration) throws {
        guard case .object(var root) = document else { throw MCPConfigurationError.missingServersObject }
        var all = root["mcpServers"]?.objectValue ?? [:]
        all[configuration.id] = configuration.raw
        root["mcpServers"] = .object(all)
        let updated = JSONValue.object(root)
        try persist(updated, keepBackup: true)
        try applyValidated(data: try Data(contentsOf: Self.fileURL))
        lastKnownModification = modificationDate()
    }

    func remove(serverID: String) throws {
        guard case .object(var root) = document else { return }
        var all = root["mcpServers"]?.objectValue ?? [:]
        all.removeValue(forKey: serverID); root["mcpServers"] = .object(all)
        try persist(.object(root), keepBackup: true); load()
    }

    func updatePolicy(serverID: String, mutate: (inout MCPServerPolicy) -> Void) throws {
        guard var server = servers.first(where: { $0.id == serverID }), case .object(var raw) = server.raw else { return }
        mutate(&server.policy)
        let data = try JSONEncoder().encode(server.policy)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: data)
        var noema = raw["_noema"]?.objectValue ?? [:]
        for (key, value) in encoded.objectValue ?? [:] { noema[key] = value }
        raw["_noema"] = .object(noema)
        server.raw = .object(raw)
        try upsert(server)
    }

    func updateExecutable(serverID: String, path: String) throws {
        guard var server = servers.first(where: { $0.id == serverID }), case .object(var raw) = server.raw else { return }
        raw["command"] = .string(path)
        server.raw = .object(raw)
        server.transport = try Self.decodeServer(id: serverID, raw: server.raw).transport
        try upsert(server)
    }

    func markLastKnownGood() throws {
        let data = try Data(contentsOf: Self.fileURL)
        try data.write(to: Self.lastKnownGoodURL, options: .atomic)
    }

    func restoreLastKnownGood() throws {
        let data = try Data(contentsOf: Self.lastKnownGoodURL)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        _ = try Self.decodeServers(from: value)
        try persist(value, keepBackup: true); load()
    }

    func previewImport(data: Data) throws -> MCPImportPreview {
        let incoming = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let incomingServers = incoming["mcpServers"]?.objectValue else { throw MCPConfigurationError.missingServersObject }
        let current = document["mcpServers"]?.objectValue ?? [:]
        var resulting = current; var added: [String] = []; var replaced: [String] = []; var unchanged: [String] = []
        for (id, value) in incomingServers {
            if current[id] == value { unchanged.append(id) }
            else if current[id] == nil { added.append(id); resulting[id] = value }
            else { replaced.append(id); resulting[id] = value }
        }
        guard case .object(var root) = document else { throw MCPConfigurationError.missingServersObject }
        root["mcpServers"] = .object(resulting)
        let secrets = incomingServers.flatMap { id, raw in Self.secretCandidates(serverID: id, raw: raw) }
        return .init(added: added.sorted(), replaced: replaced.sorted(), unchanged: unchanged.sorted(), secrets: secrets, resultingDocument: .object(root))
    }

    func applyImport(_ preview: MCPImportPreview, migrateSecrets: Bool = false) throws {
        var resulting = preview.resultingDocument
        if migrateSecrets, case .object(var root) = resulting, var all = root["mcpServers"]?.objectValue {
            for secret in preview.secrets {
                try MCPKeychain.set(secret.value, named: secret.keychainName)
                guard case .object(var server) = all[secret.serverID] else { continue }
                var container = server[secret.container]?.objectValue ?? [:]
                container[secret.key] = .string("${keychain:\(secret.keychainName)}")
                server[secret.container] = .object(container)
                all[secret.serverID] = .object(server)
            }
            root["mcpServers"] = .object(all); resulting = .object(root)
        }
        try persist(resulting, keepBackup: true); load()
    }

    func configuration(from input: String, suggestedID: String? = nil) throws -> MCPServerConfiguration {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
            if let all = value["mcpServers"]?.objectValue, let first = all.sorted(by: { $0.key < $1.key }).first {
                return try Self.decodeServer(id: first.key, raw: first.value)
            }
            let id = Self.uniqueID(suggestedID ?? "server", existing: Set(servers.map(\.id)))
            return try Self.decodeServer(id: id, raw: value)
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            let id = Self.uniqueID(suggestedID ?? url.host ?? "server", existing: Set(servers.map(\.id)))
            return try Self.decodeServer(id: id, raw: .object(["url": .string(trimmed)]))
        }
        let tokens = try MCPCommandTokenizer.tokenize(trimmed)
        let seed = suggestedID ?? URL(fileURLWithPath: tokens[0]).lastPathComponent
        let id = Self.uniqueID(seed, existing: Set(servers.map(\.id)))
        return try Self.decodeServer(id: id, raw: .object([
            "command": .string(tokens[0]),
            "args": .array(tokens.dropFirst().map(JSONValue.string))
        ]))
    }

    private func applyValidated(data: Data) throws {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw MCPConfigurationError.invalidJSON(error.localizedDescription) }
        let decoded = try Self.decodeServers(from: value)
        document = value; servers = decoded
        rawText = Self.editorText(for: value)
    }

    private func persist(_ value: JSONValue, keepBackup: Bool) throws {
        let data: Data
        if value == Self.emptyDocument {
            data = Data(Self.emptyConfigurationText.utf8)
        } else {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(value)
        }
        _ = try JSONDecoder().decode(JSONValue.self, from: data)
        let fm = FileManager.default; try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if keepBackup, fm.fileExists(atPath: Self.fileURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? fm.copyItem(at: Self.fileURL, to: Self.directory.appendingPathComponent("mcp.backup-\(stamp).json"))
            let backups = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.lastPathComponent.hasPrefix("mcp.backup-") }.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
            for old in backups.dropFirst(5) { try? fm.removeItem(at: old) }
        }
        let temporary = Self.directory.appendingPathComponent(".mcp.\(UUID().uuidString).json")
        try data.write(to: temporary, options: [.atomic])
        if fm.fileExists(atPath: Self.fileURL.path) { _ = try fm.replaceItemAt(Self.fileURL, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: Self.fileURL) }
    }

    private static func editorText(for value: JSONValue) -> String {
        value == emptyDocument ? emptyConfigurationText : value.prettyPrinted
    }

    private func checkForExternalChange() {
        guard let date = modificationDate(), let known = lastKnownModification, date != known else { return }
        if editorDirty { externalConflict = true; return }
        load()
    }

    private func modificationDate() -> Date? {
        try? Self.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func decodeServers(from document: JSONValue) throws -> [MCPServerConfiguration] {
        guard let all = document["mcpServers"]?.objectValue else { throw MCPConfigurationError.missingServersObject }
        return try all.map { try decodeServer(id: $0.key, raw: $0.value) }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func decodeServer(id: String, raw: JSONValue) throws -> MCPServerConfiguration {
        guard let object = raw.objectValue else { throw MCPConfigurationError.invalidServer(id, String(localized: "Server settings must be a JSON object.")) }
        let noema = object["_noema"]
        let policy: MCPServerPolicy
        if let noema {
            do { policy = try JSONDecoder().decode(MCPServerPolicy.self, from: JSONEncoder().encode(noema)) }
            catch { throw MCPConfigurationError.invalidServer(id, error.localizedDescription) }
        } else { policy = MCPServerPolicy() }
        let name = object["name"]?.stringValue ?? id
        let headers = object["headers"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        let transport: MCPTransportConfiguration
        if let command = object["command"]?.stringValue {
            let args = object["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let environment = object["env"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
            transport = .stdio(command: command, arguments: args, workingDirectory: object["cwd"]?.stringValue, environment: environment)
        } else if let urlString = object["url"]?.stringValue, let url = URL(string: urlString) {
            if object["transport"]?.stringValue?.lowercased() == "sse" { transport = .legacySSE(url: url, headers: headers) }
            else { transport = .streamableHTTP(url: url, headers: headers) }
        } else { throw MCPConfigurationError.invalidServer(id, String(localized: "Add either command or url.")) }
        return .init(id: id, displayName: name, transport: transport, policy: policy, raw: raw)
    }

    private static func uniqueID(_ source: String, existing: Set<String>) -> String {
        let base = source.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let usable = base.isEmpty ? "server" : base
        if !existing.contains(usable) { return usable }
        var number = 2; while existing.contains("\(usable)-\(number)") { number += 1 }
        return "\(usable)-\(number)"
    }

    private static func secretCandidates(serverID: String, raw: JSONValue) -> [MCPImportPreview.Secret] {
        guard let server = raw.objectValue else { return [] }
        var result: [MCPImportPreview.Secret] = []
        for containerName in ["headers", "env"] {
            for (key, value) in server[containerName]?.objectValue ?? [:] {
                guard let literal = value.stringValue, !literal.hasPrefix("${"), isSensitiveName(key) else { continue }
                let safeKey = key.lowercased().replacingOccurrences(of: #"[^a-z0-9_.-]+"#, with: "-", options: .regularExpression)
                result.append(.init(
                    serverID: serverID, container: containerName, key: key, value: literal,
                    keychainName: "import.\(serverID).\(containerName).\(safeKey)"
                ))
            }
        }
        return result
    }

    private static func isSensitiveName(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return ["authorization", "token", "secret", "password", "api_key", "apikey", "access_key"].contains { normalized.contains($0) }
    }
}
#endif
