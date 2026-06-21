import Foundation

private struct MemoryToolArguments: Decodable {
    let operation: String
    let entryID: String?
    let title: String?
    let content: String?
    let oldString: String?
    let newString: String?
    let insertAt: Int?
    let scope: String?
    let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case operation
        case entryID = "entry_id"
        case title
        case content
        case oldString = "old_string"
        case newString = "new_string"
        case insertAt = "insert_at"
        case scope
        case expiresAt = "expires_at"
    }
}

struct MemoryToolResponse: Codable, Sendable {
    struct EntryPayload: Codable, Sendable {
        let id: String
        let title: String
        let content: String
        let scope: String
        let expiresAt: Date?
        let createdAt: Date
        let updatedAt: Date

        init(_ entry: MemoryEntry) {
            self.id = entry.id.uuidString
            self.title = entry.title
            self.content = entry.content
            self.scope = entry.effectiveScope.rawValue
            self.expiresAt = entry.expiresAt
            self.createdAt = entry.createdAt
            self.updatedAt = entry.updatedAt
        }
    }

    struct ConflictPayload: Codable, Sendable {
        let entryID: String
        let title: String
        let reason: String

        init(_ conflict: MemoryConflict) {
            self.entryID = conflict.entryID.uuidString
            self.title = conflict.title
            self.reason = conflict.kind.localizedSummary
        }
    }

    let ok: Bool
    let operation: String
    let entry: EntryPayload?
    let entries: [EntryPayload]?
    let conflicts: [ConflictPayload]?
    let message: String?
    let error: String?

    init(
        ok: Bool,
        operation: String,
        entry: EntryPayload?,
        entries: [EntryPayload]?,
        conflicts: [ConflictPayload]? = nil,
        message: String?,
        error: String?
    ) {
        self.ok = ok
        self.operation = operation
        self.entry = entry
        self.entries = entries
        self.conflicts = conflicts
        self.message = message
        self.error = error
    }
}

public struct MemoryTool: Tool {
    public let name = "noema.memory"
    public let description = "Manage persistent cross-conversation memory entries stored on device."
    public let schema = #"""
    {
      "type":"object",
      "properties":{
        "operation":{
          "type":"string",
          "description":"Memory operation to perform.",
          "enum":["list","view","create","replace","insert","str_replace","delete","rename"]
        },
        "entry_id":{
          "type":"string",
          "description":"Stable memory entry id. Use this when available to target an existing entry."
        },
        "title":{
          "type":"string",
          "description":"Entry title. Required for create. May also identify an existing entry for other operations when entry_id is omitted."
        },
        "content":{
          "type":"string",
          "description":"Memory content. Required for create, replace, and insert."
        },
        "old_string":{
          "type":"string",
          "description":"Existing text to replace for str_replace."
        },
        "new_string":{
          "type":"string",
          "description":"Replacement text for str_replace, or the new title for rename."
        },
        "insert_at":{
          "type":"integer",
          "minimum":0,
          "description":"Character offset used by insert. Defaults to appending at the end."
        },
        "scope":{
          "type":"string",
          "enum":["allChats","currentProject","temporary"],
          "description":"Scope for create. Defaults to allChats. Use temporary for facts that should expire soon."
        },
        "expires_at":{
          "type":"string",
          "format":"date-time",
          "description":"Optional ISO-8601 expiry date for create. Temporary memories default to about 24 hours if omitted."
        }
      },
      "required":["operation"]
    }
    """#

    public func call(args: Data) async throws -> Data {
        let input = try JSONDecoder().decode(MemoryToolArguments.self, from: args)
        let operation = input.operation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        do {
            let response: MemoryToolResponse
            switch operation {
            case "list":
                let entries = await MainActor.run { MemoryStore.shared.entries.map(MemoryToolResponse.EntryPayload.init) }
                response = MemoryToolResponse(ok: true, operation: operation, entry: nil, entries: entries, message: "Listed \(entries.count) memory entries.", error: nil)
            case "view":
                let entry = try await MainActor.run { try MemoryStore.shared.entry(id: input.entryID, title: input.title) }
                response = MemoryToolResponse(ok: true, operation: operation, entry: .init(entry), entries: nil, message: "Loaded memory entry.", error: nil)
            case "create":
                let scope = Self.scope(from: input.scope) ?? .allChats
                let explicitExpiry = Self.expiryDate(from: input.expiresAt)
                let expiresAt = explicitExpiry ?? Self.defaultExpiryDate(for: scope)
                let reviewRequired = UserDefaults.standard.object(forKey: "memoryReviewRequired") as? Bool ?? true
                if reviewRequired {
                    let item = try await MainActor.run {
                        try MemoryStore.shared.proposeCreate(
                            title: input.title ?? "",
                            content: input.content ?? "",
                            scope: scope,
                            expiresAt: expiresAt
                        )
                    }
                    let conflicts = item.possibleConflicts?.map(MemoryToolResponse.ConflictPayload.init) ?? []
                    response = MemoryToolResponse(
                        ok: true,
                        operation: operation,
                        entry: nil,
                        entries: nil,
                        conflicts: conflicts.isEmpty ? nil : conflicts,
                        message: conflicts.isEmpty ? "Memory save queued for review." : "Memory save queued with possible conflicts.",
                        error: nil
                    )
                } else {
                    let entry = try await MainActor.run {
                        try MemoryStore.shared.create(
                            title: input.title ?? "",
                            content: input.content ?? "",
                            scope: scope,
                            expiresAt: expiresAt
                        )
                    }
                    response = MemoryToolResponse(ok: true, operation: operation, entry: .init(entry), entries: nil, message: "Created memory entry.", error: nil)
                }
            case "replace":
                let entry = try await MainActor.run {
                    try MemoryStore.shared.replace(id: input.entryID, title: input.title, content: input.content ?? "")
                }
                response = MemoryToolResponse(ok: true, operation: operation, entry: .init(entry), entries: nil, message: "Replaced memory entry content.", error: nil)
            case "insert":
                let entry = try await MainActor.run {
                    try MemoryStore.shared.insert(id: input.entryID, title: input.title, content: input.content ?? "", at: input.insertAt)
                }
                response = MemoryToolResponse(ok: true, operation: operation, entry: .init(entry), entries: nil, message: "Inserted into memory entry.", error: nil)
            case "str_replace":
                let entry = try await MainActor.run {
                    try MemoryStore.shared.stringReplace(
                        id: input.entryID,
                        title: input.title,
                        oldString: input.oldString ?? "",
                        newString: input.newString ?? ""
                    )
                }
                response = MemoryToolResponse(ok: true, operation: operation, entry: .init(entry), entries: nil, message: "Updated memory entry text.", error: nil)
            case "delete":
                let entry = try await MainActor.run { try MemoryStore.shared.delete(id: input.entryID, title: input.title) }
                response = MemoryToolResponse(ok: true, operation: operation, entry: .init(entry), entries: nil, message: "Deleted memory entry.", error: nil)
            case "rename":
                let entry = try await MainActor.run {
                    try MemoryStore.shared.rename(id: input.entryID, title: input.title, newTitle: input.newString ?? "")
                }
                response = MemoryToolResponse(ok: true, operation: operation, entry: .init(entry), entries: nil, message: "Renamed memory entry.", error: nil)
            default:
                response = MemoryToolResponse(ok: false, operation: operation, entry: nil, entries: nil, message: nil, error: "Unsupported memory operation.")
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(response)
        } catch {
            let response = MemoryToolResponse(
                ok: false,
                operation: operation,
                entry: nil,
                entries: nil,
                message: nil,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(response)
        }
    }

    private static func scope(from rawScope: String?) -> MemoryScope? {
        guard let rawScope else { return nil }
        return MemoryScope(rawValue: rawScope.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func expiryDate(from rawDate: String?) -> Date? {
        guard let rawDate = rawDate?.trimmingCharacters(in: .whitespacesAndNewlines), !rawDate.isEmpty else {
            return nil
        }
        if let date = ISO8601DateFormatter().date(from: rawDate) {
            return date
        }
        return nil
    }

    private static func defaultExpiryDate(for scope: MemoryScope) -> Date? {
        guard scope == .temporary else { return nil }
        return Calendar.current.date(byAdding: .day, value: 1, to: Date())
    }
}
