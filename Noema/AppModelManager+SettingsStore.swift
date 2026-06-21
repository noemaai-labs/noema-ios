// AppModelManager+SettingsStore.swift
import Foundation

struct DecodedModelSettingsMap {
    let map: [String: ModelSettings]
    let droppedInvalidEntries: Bool
}

struct DecodedLocalModelSettingsPayload {
    let entries: [ModelSettingsStore.Entry]
    let droppedInvalidEntries: Bool
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
        var droppedInvalidEntries = false

        for rawEntry in rawEntries {
            guard JSONSerialization.isValidJSONObject(rawEntry),
                  let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(ModelSettingsStore.Entry.self, from: entryData) else {
                droppedInvalidEntries = true
                continue
            }
            entries.append(entry)
        }

        return DecodedLocalModelSettingsPayload(entries: entries, droppedInvalidEntries: droppedInvalidEntries)
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

/// Durable per-model settings persistence using Keychain with a local JSON mirror.
/// This survives app reinstalls (via Keychain) and also maintains a readable file for diagnostics.
enum ModelSettingsStore {
    private static let service = "Noema.ModelSettings"
    private static let account = "perModel.v1"

    struct Entry: Codable, Equatable {
        let modelID: String
        let quantLabel: String
        let canonicalPath: String?
        let settings: ModelSettings
    }

    fileprivate struct Payload: Codable {
        var entries: [Entry]
    }

    private static func mirrorURL() -> URL? {
        // Store a human-readable mirror under Documents/ModelSettings/model_settings.json
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?
            .appendingPathComponent("ModelSettings", isDirectory: true)
            .appendingPathComponent("model_settings.json")
    }

    /// Loads durable entries, preserving canonical paths when present.
    static func loadEntries() -> [Entry] {
        // Try Keychain first
        if let data = try? KeychainStore.read(service: service, account: account) {
            if let decoded = ModelSettingsPersistenceDecoder.decodeLocalPayload(from: data) {
                let normalized = normalizedEntries(decoded.entries)
                if decoded.droppedInvalidEntries || normalized != decoded.entries {
                    save(entries: normalized)
                }
                return normalized
            }
        }
        // Fallback to mirror file
        if let url = mirrorURL(), let data = try? Data(contentsOf: url) {
            if let decoded = ModelSettingsPersistenceDecoder.decodeLocalPayload(from: data) {
                let normalized = normalizedEntries(decoded.entries)
                if decoded.droppedInvalidEntries || normalized != decoded.entries {
                    save(entries: normalized)
                }
                return normalized
            }
        }
        return []
    }

    /// Loads settings map keyed by (modelID, quantLabel).
    static func load() -> [String: ModelSettings] {
        var map: [String: ModelSettings] = [:]
        for entry in loadEntries() {
            map[entryKey(modelID: entry.modelID, quantLabel: entry.quantLabel)] = entry.settings
        }
        return map
    }

    /// Saves settings map keyed by (modelID|quantLabel) back to Keychain and the mirror file.
    static func save(_ map: [String: ModelSettings]) {
        // Convert back to payload
        let entries: [Entry] = map.compactMap { (k, v) in
            guard let sep = k.firstIndex(of: "|") else { return nil }
            let id = String(k[..<sep])
            let quant = String(k[k.index(after: sep)...])
            return Entry(modelID: id, quantLabel: quant, canonicalPath: nil, settings: v)
        }
        save(entries: entries)
    }

    static func save(entries: [Entry]) {
        let payload = Payload(entries: normalizedEntries(entries))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Write Keychain
        do { try KeychainStore.write(service: service, account: account, data: data) } catch { /* ignore */ }
        // Write mirror
        if let url = mirrorURL() {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
            } catch { /* ignore */ }
        }
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
            }
        }

        if shouldPersist {
            save(entries: entries)
        }

        return resolved
    }

    /// Updates a single model entry in persistent storage (Keychain + mirror).
    static func save(settings: ModelSettings, for model: LocalModel) {
        let canonicalPath = InstalledModelsStore.canonicalURL(for: model.url, format: model.format).path
        let newEntry = Entry(
            modelID: model.modelID,
            quantLabel: model.quant,
            canonicalPath: canonicalPath,
            settings: settings
        )
        var current = loadEntries()
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
        var entries = loadEntries()
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
        // Remove durable entries from Keychain and delete the local mirror.
        _ = try? KeychainStore.delete(service: service, account: account)
        if let url = mirrorURL() {
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
