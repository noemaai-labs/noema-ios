import Foundation

// MARK: - Live composer state

/// Transient UI state for the document currently attached to the composer. Mirrors
/// how `pendingMediaAttachments` represents an in-flight media attachment.
/// One file within a composer attachment. A single attach can carry several documents,
/// all embedded into one dataset (so RAG covers them together) but shown + targetable
/// individually.
struct AttachedFile: Equatable, Sendable {
    let name: String   // display name (no extension), matches the on-disk file's stem
    let isPDF: Bool
}

struct AttachedDocumentState: Identifiable, Equatable, Sendable {
    enum Mode: String, Sendable {
        /// Small enough to inject whole into the next prompt's context.
        case injected
        /// Embedded on the spot; retrieved per-turn via auto-RAG.
        case embedding
    }

    enum Phase: Equatable, Sendable {
        case preparing            // copying / extracting / compacting / embedding
        case ready                // injected text staged, or embedded + armed
        case failed(String)
    }

    let id: String
    var name: String
    /// True when ANY attached file is a PDF — drives the PDF tool's presence.
    var isPDF: Bool
    /// Every file in this attachment. Count > 1 ⇒ a multi-document attach.
    var files: [AttachedFile]
    var mode: Mode
    var phase: Phase
    /// Set once the document has been imported as a dataset (embedding path only).
    var datasetID: String?
    /// When the embedded vectors will be auto-deleted (embedding path only).
    var expiresAt: Date?

    var isPreparing: Bool { if case .preparing = phase { return true } else { return false } }
    var isReady: Bool { phase == .ready }
}

// MARK: - Persisted registry of expiring embedded documents

/// One on-the-spot embedded document whose vectors are deleted once `expiresAt` passes.
struct EphemeralAttachedDocument: Codable, Identifiable, Equatable, Sendable {
    let datasetID: String
    let name: String
    let createdAt: Date
    var expiresAt: Date
    var id: String { datasetID }
}

/// Background-safe registry + janitor for embedded composer documents. Persisted so
/// cleanup survives app restarts. All file deletion is plain disk I/O so it can run
/// off the main actor.
enum EphemeralAttachedDocumentStore {
    private static let registryKey = "ephemeralAttachedDocuments.v1"
    static let expiryHoursKey = "attachedDocExpiryHours"
    private static let lock = NSLock()

    /// Allowed expiry windows offered in Settings, in hours.
    static let expiryOptionsHours: [Int] = [2, 6, 12, 24, 72, 168]
    static let defaultExpiryHours = 24

    static var expiryHours: Int {
        let v = UserDefaults.standard.integer(forKey: expiryHoursKey)
        return expiryOptionsHours.contains(v) ? v : defaultExpiryHours
    }

    static var expiryInterval: TimeInterval { TimeInterval(expiryHours) * 3600 }

    // MARK: Registry

    static func all() -> [EphemeralAttachedDocument] {
        lock.lock(); defer { lock.unlock() }
        return decodeLocked()
    }

    @discardableResult
    static func register(datasetID: String, name: String, ttl: TimeInterval? = nil) -> EphemeralAttachedDocument {
        let now = Date()
        let doc = EphemeralAttachedDocument(
            datasetID: datasetID,
            name: name,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl ?? expiryInterval)
        )
        lock.lock()
        var list = decodeLocked()
        list.removeAll { $0.datasetID == datasetID }
        list.append(doc)
        encodeLocked(list)
        lock.unlock()
        return doc
    }

    /// Remove a document from tracking and delete its files immediately.
    static func removeNow(datasetID: String) {
        lock.lock()
        var list = decodeLocked()
        list.removeAll { $0.datasetID == datasetID }
        encodeLocked(list)
        lock.unlock()
        deleteDatasetFiles(datasetID: datasetID)
    }

    /// Delete every document whose expiry has passed. Returns the deleted dataset ids
    /// so callers can unbind any session still pointing at one.
    @discardableResult
    static func purgeExpired(now: Date = Date()) -> [String] {
        lock.lock()
        var list = decodeLocked()
        let expired = list.filter { $0.expiresAt <= now }
        list.removeAll { $0.expiresAt <= now }
        encodeLocked(list)
        lock.unlock()
        for doc in expired { deleteDatasetFiles(datasetID: doc.datasetID) }
        return expired.map(\.datasetID)
    }

    static func isTracked(datasetID: String) -> Bool {
        all().contains { $0.datasetID == datasetID }
    }

    // MARK: File deletion

    private static func deleteDatasetFiles(datasetID: String) {
        var url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url.appendPathComponent("LocalLLMDatasets", isDirectory: true)
        for component in datasetID.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: true)
        }
        try? FileManager.default.removeItem(at: url)

        // Keep the embedded-dataset bookkeeping (DatasetManager) in sync.
        let key = "embeddedDatasetIDs"
        var set = Set((UserDefaults.standard.string(forKey: key) ?? "")
            .split(separator: ",").map(String.init))
        if set.remove(datasetID) != nil {
            UserDefaults.standard.set(set.joined(separator: ","), forKey: key)
        }
    }

    // MARK: Codable helpers (call inside `lock`)

    private static func decodeLocked() -> [EphemeralAttachedDocument] {
        guard let data = UserDefaults.standard.data(forKey: registryKey),
              let list = try? JSONDecoder().decode([EphemeralAttachedDocument].self, from: data) else { return [] }
        return list
    }

    private static func encodeLocked(_ list: [EphemeralAttachedDocument]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: registryKey)
        }
    }
}
