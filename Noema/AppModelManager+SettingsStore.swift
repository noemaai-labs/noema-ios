import Foundation

struct DecodedModelSettingsMap {
    let map: [String: ModelSettings]
    let droppedInvalidEntries: Bool
}

struct DecodedLocalModelSettingsPayload {
    let entries: [ModelSettingsStore.Entry]
    /// Raw JSON objects that no schema this build knows could decode (typically
    /// written by a newer app version). They are preserved verbatim across saves
    /// instead of being dropped, so running an older build can't destroy them.
    let unrecognizedRawEntries: [[String: Any]]

    var droppedInvalidEntries: Bool { !unrecognizedRawEntries.isEmpty }
}

enum ModelSettingsPersistenceDecoder {
    private struct RemoteEntry: Decodable {
        let settings: ModelSettings
    }

    static func decodeLocalPayload(from data: Data) -> DecodedLocalModelSettingsPayload? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEntries = root["entries"] as? [Any] else {
            return nil
        }

        let decoder = JSONDecoder()
        var entries: [ModelSettingsStore.Entry] = []
        var unrecognized: [[String: Any]] = []

        for rawEntry in rawEntries {
            guard let entryObject = rawEntry as? [String: Any] else { continue }
            if JSONSerialization.isValidJSONObject(entryObject),
               let entryData = try? JSONSerialization.data(withJSONObject: entryObject),
               let entry = try? decoder.decode(ModelSettingsStore.Entry.self, from: entryData) {
                entries.append(entry)
            } else {
                unrecognized.append(entryObject)
            }
        }

        return DecodedLocalModelSettingsPayload(entries: entries, unrecognizedRawEntries: unrecognized)
    }

    static func decodeRemoteSettingsMap(from data: Data) -> DecodedModelSettingsMap? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let decoder = JSONDecoder()
        var map: [String: ModelSettings] = [:]
        var droppedInvalidEntries = false

        for (key, rawSettings) in root {
            guard let settingsObject = rawSettings as? [String: Any] else {
                droppedInvalidEntries = true
                continue
            }

            let wrappedObject: [String: Any] = ["settings": settingsObject]
            guard JSONSerialization.isValidJSONObject(wrappedObject),
                  let entryData = try? JSONSerialization.data(withJSONObject: wrappedObject),
                  let entry = try? decoder.decode(RemoteEntry.self, from: entryData) else {
                droppedInvalidEntries = true
                continue
            }

            map[key] = entry.settings
        }

        return DecodedModelSettingsMap(map: map, droppedInvalidEntries: droppedInvalidEntries)
    }
}

/// Durable per-model settings persistence in Application Support.
/// Model settings are not secrets, so keeping them out of Keychain avoids macOS
/// authorization prompts when the app's development signature changes.
enum ModelSettingsStore {
    nonisolated(unsafe) static var directoryOverrideForTesting: URL?

    struct Entry: Codable, Equatable {
        let modelID: String
        let quantLabel: String
        let canonicalPath: String?
        let settings: ModelSettings
    }

    /// Result of reading the durable payload. `storeReadable` is false when a payload
    /// exists but could not be read. Writers must not rebuild the payload from an
    /// unreadable result: doing so would wipe every entry that is still on disk.
    struct DurableLoadResult {
        let entries: [Entry]
        let storeReadable: Bool
    }

    /// Passthrough pen for raw entries the current build can't decode (see
    /// `DecodedLocalModelSettingsPayload.unrecognizedRawEntries`). Refilled on every
    /// load, re-emitted on every save.
    private final class UnrecognizedEntryPen: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [[String: Any]] = []

        func set(_ raw: [[String: Any]]) {
            lock.lock()
            defer { lock.unlock() }
            entries = raw
        }

        func current() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private static let unrecognizedPen = UnrecognizedEntryPen()

    private static func setUnrecognizedRawEntries(_ raw: [[String: Any]]) {
        unrecognizedPen.set(raw)
    }

    private static func currentUnrecognizedRawEntries() -> [[String: Any]] {
        unrecognizedPen.current()
    }

    static var unrecognizedRawEntryCountForTesting: Int {
        currentUnrecognizedRawEntries().count
    }

    /// Overwrites the raw payload directly, bypassing entry encoding — lets tests
    /// simulate a payload written by a different (e.g. newer) app version.
    static func replacePayloadForTesting(_ data: Data) {
        try? writePayload(data)
    }

    private static func storageURL() -> URL? {
        if let directoryOverrideForTesting {
            return directoryOverrideForTesting.appendingPathComponent("model_settings.json")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Noema", isDirectory: true)
            .appendingPathComponent("ModelSettings", isDirectory: true)
            .appendingPathComponent("model_settings.json")
    }

    /// Previous builds already maintained this JSON mirror alongside Keychain.
    /// Read it once when the Application Support file does not exist, then migrate
    /// its exact payload without ever touching the legacy Keychain item.
    private static func legacyMirrorURL() -> URL? {
        guard directoryOverrideForTesting == nil else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ModelSettings", isDirectory: true)
            .appendingPathComponent("model_settings.json")
    }

    /// Loads durable entries, preserving canonical paths when present.
    static func loadEntries() -> [Entry] {
        loadEntriesDetailed().entries
    }

    static func loadEntriesDetailed() -> DurableLoadResult {
        if let url = storageURL(), FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let decoded = ModelSettingsPersistenceDecoder.decodeLocalPayload(from: data) else {
                setUnrecognizedRawEntries([])
                return DurableLoadResult(entries: [], storeReadable: false)
            }
            return adopt(decoded)
        }

        if let legacyURL = legacyMirrorURL(), FileManager.default.fileExists(atPath: legacyURL.path) {
            guard let data = try? Data(contentsOf: legacyURL),
                  let decoded = ModelSettingsPersistenceDecoder.decodeLocalPayload(from: data) else {
                setUnrecognizedRawEntries([])
                return DurableLoadResult(entries: [], storeReadable: false)
            }
            try? writePayload(data)
            return adopt(decoded)
        }

        setUnrecognizedRawEntries([])
        return DurableLoadResult(entries: [], storeReadable: true)
    }

    private static func adopt(_ decoded: DecodedLocalModelSettingsPayload) -> DurableLoadResult {
        setUnrecognizedRawEntries(decoded.unrecognizedRawEntries)
        let normalized = normalizedEntries(decoded.entries)
        // Persist dedup cleanups, but never as a way of committing entry drops:
        // undecodable entries ride along via the passthrough pen instead.
        if normalized != decoded.entries {
            save(entries: normalized)
        }
        return DurableLoadResult(entries: normalized, storeReadable: true)
    }

    static func save(entries: [Entry]) {
        let normalized = normalizedEntries(entries)
        let encoder = JSONEncoder()
        var encodedEntries: [Any] = []
        var claimedModelKeys: Set<String> = []
        var claimedPaths: Set<String> = []

        for entry in normalized {
            guard let data = try? encoder.encode(entry),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            encodedEntries.append(object)
            claimedModelKeys.insert(entryKey(modelID: entry.modelID, quantLabel: entry.quantLabel))
            if let path = entry.canonicalPath {
                claimedPaths.insert(path)
            }
        }

        for raw in currentUnrecognizedRawEntries() {
            if let modelID = raw["modelID"] as? String,
               let quantLabel = raw["quantLabel"] as? String,
               claimedModelKeys.contains(entryKey(modelID: modelID, quantLabel: quantLabel)) {
                continue
            }
            if let path = raw["canonicalPath"] as? String, claimedPaths.contains(path) {
                continue
            }
            encodedEntries.append(raw)
        }

        let root: [String: Any] = ["entries": encodedEntries]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? writePayload(data)
    }

    private static func writePayload(_ data: Data) throws {
        guard let url = storageURL() else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private static func normalizedEntries(_ entries: [Entry]) -> [Entry] {
        var deduped: [Entry] = []
        var seenPaths: Set<String> = []
        var seenModelKeys: Set<String> = []

        for entry in entries.reversed() {
            let modelKey = entryKey(modelID: entry.modelID, quantLabel: entry.quantLabel)
            let canonicalPath = entry.canonicalPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let canonicalPath, !canonicalPath.isEmpty {
                guard seenPaths.insert(canonicalPath).inserted else { continue }
            }
            guard seenModelKeys.insert(modelKey).inserted else { continue }
            deduped.append(
                Entry(
                    modelID: entry.modelID,
                    quantLabel: entry.quantLabel,
                    canonicalPath: canonicalPath?.isEmpty == true ? nil : canonicalPath,
                    settings: entry.settings
                )
            )
        }

        return deduped.reversed()
    }

    static func resolveLocalSettings(
        installedModels: [InstalledModel],
        legacySettingsByPath: [String: ModelSettings]
    ) -> [String: ModelSettings] {
        var entries = loadEntries()
        var entriesByPath: [String: Int] = [:]
        var entriesByModelKey: [String: Int] = [:]
        var shouldPersist = false

        for (index, entry) in entries.enumerated() {
            if let canonicalPath = entry.canonicalPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !canonicalPath.isEmpty {
                entriesByPath[canonicalPath] = index
            }
            entriesByModelKey[entryKey(modelID: entry.modelID, quantLabel: entry.quantLabel)] = index
        }

        var resolved: [String: ModelSettings] = [:]
        for item in installedModels {
            let currentPath = item.url.path
            if let index = entriesByPath[currentPath] {
                resolved[currentPath] = entries[index].settings
                continue
            }

            let modelKey = entryKey(modelID: item.modelID, quantLabel: item.quantLabel)
            if let index = entriesByModelKey[modelKey] {
                resolved[currentPath] = entries[index].settings
                if entries[index].canonicalPath != currentPath {
                    entries[index] = Entry(
                        modelID: entries[index].modelID,
                        quantLabel: entries[index].quantLabel,
                        canonicalPath: currentPath,
                        settings: entries[index].settings
                    )
                    entriesByPath[currentPath] = index
                    shouldPersist = true
                }
                continue
            }

            if let legacy = legacySettingsByPath[currentPath] {
                resolved[currentPath] = legacy
                let entry = Entry(
                    modelID: item.modelID,
                    quantLabel: item.quantLabel,
                    canonicalPath: currentPath,
                    settings: legacy
                )
                entries.append(entry)
                entriesByPath[currentPath] = entries.count - 1
                entriesByModelKey[modelKey] = entries.count - 1
                shouldPersist = true
            }
        }

        if shouldPersist {
            save(entries: entries)
        }

        return resolved
    }

    /// Updates a single model entry in persistent storage.
    static func save(settings: ModelSettings, for model: LocalModel) {
        let canonicalPath = InstalledModelsStore.canonicalURL(for: model.url, format: model.format).path
        let newEntry = Entry(
            modelID: model.modelID,
            quantLabel: model.quant,
            canonicalPath: canonicalPath,
            settings: settings
        )
        let loaded = loadEntriesDetailed()
        guard loaded.storeReadable else {
            // Rebuilding a corrupt payload from a failed read would wipe every other
            // model's settings, so keep the in-memory/legacy copies and skip this write.
            return
        }
        var current = loaded.entries
        guard !current.contains(newEntry) else { return }
        current.removeAll {
            entryKey(modelID: $0.modelID, quantLabel: $0.quantLabel) == entryKey(modelID: model.modelID, quantLabel: model.quant)
                || $0.canonicalPath == canonicalPath
        }
        current.append(newEntry)
        save(entries: current)
    }

    static func migrateCanonicalPaths(_ migrations: [(oldPath: String, newPath: String)]) {
        guard !migrations.isEmpty else { return }
        var entries = loadEntries()
        var didChange = false

        for index in entries.indices {
            guard let canonicalPath = entries[index].canonicalPath else { continue }
            if let migration = migrations.first(where: { $0.oldPath == canonicalPath }),
               migration.newPath != canonicalPath {
                entries[index] = Entry(
                    modelID: entries[index].modelID,
                    quantLabel: entries[index].quantLabel,
                    canonicalPath: migration.newPath,
                    settings: entries[index].settings
                )
                didChange = true
            }
        }

        if didChange {
            save(entries: entries)
        }
    }

    static func remove(modelID: String, quantLabel: String, canonicalPath: String?) {
        let modelKey = entryKey(modelID: modelID, quantLabel: quantLabel)
        let loaded = loadEntriesDetailed()
        guard loaded.storeReadable else { return }
        var entries = loaded.entries
        let before = entries.count
        entries.removeAll { entry in
            entryKey(modelID: entry.modelID, quantLabel: entry.quantLabel) == modelKey
                || (canonicalPath != nil && entry.canonicalPath == canonicalPath)
        }
        guard entries.count != before else { return }
        save(entries: entries)
    }

    private static func entryKey(modelID: String, quantLabel: String) -> String {
        modelID + "|" + quantLabel
    }

    static func clear() {
        // Never query or mutate the legacy Keychain item here: even deleting that
        // item can trigger the authorization prompt this file-backed store avoids.
        setUnrecognizedRawEntries([])
        for url in [storageURL(), legacyMirrorURL()].compactMap({ $0 }) {
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
                let dir = url.deletingLastPathComponent()
                if fm.fileExists(atPath: dir.path) {
                    let remaining = try fm.contentsOfDirectory(atPath: dir.path)
                    if remaining.isEmpty {
                        try fm.removeItem(at: dir)
                    }
                }
            } catch { /* ignore */ }
        }
    }
}

enum HiddenModelsStore {
    private static let storageKey = "hiddenModels.v1"

    static func load(defaults: UserDefaults = .standard) -> Set<String> {
        let stored = defaults.array(forKey: storageKey) as? [String] ?? []
        return Set(stored)
    }

    static func save(_ hidden: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(Array(hidden).sorted(), forKey: storageKey)
    }

    static func isHidden(modelID: String, quantLabel: String, defaults: UserDefaults = .standard) -> Bool {
        load(defaults: defaults).contains(key(modelID: modelID, quantLabel: quantLabel))
    }

    static func hide(modelID: String, quantLabel: String, defaults: UserDefaults = .standard) {
        var hidden = load(defaults: defaults)
        hidden.insert(key(modelID: modelID, quantLabel: quantLabel))
        save(hidden, defaults: defaults)
    }

    static func unhide(modelID: String, quantLabel: String, defaults: UserDefaults = .standard) {
        var hidden = load(defaults: defaults)
        hidden.remove(key(modelID: modelID, quantLabel: quantLabel))
        save(hidden, defaults: defaults)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    static func key(modelID: String, quantLabel: String) -> String {
        modelID + "|" + quantLabel
    }
}
