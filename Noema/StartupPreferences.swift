import Foundation

struct StartupPreferences: Codable, Equatable, Sendable {
    enum Priority: String, Codable, CaseIterable, Identifiable, Sendable {
        case remoteFirst
        case localFirst

        var id: String { rawValue }

        var title: String {
            switch self {
            case .remoteFirst:
                return "Remote first"
            case .localFirst:
                return "Local first"
            }
        }
    }

    struct RemoteSelection: Identifiable, Codable, Equatable, Sendable {
        var id: UUID
        var backendID: RemoteBackend.ID
        var backendName: String
        var modelID: String
        var modelName: String
        var relayRecordName: String?

        init(id: UUID = UUID(),
             backendID: RemoteBackend.ID,
             backendName: String,
             modelID: String,
             modelName: String,
             relayRecordName: String? = nil) {
            self.id = id
            self.backendID = backendID
            self.backendName = backendName
            self.modelID = modelID
            self.modelName = modelName
            self.relayRecordName = relayRecordName
        }
    }

    enum Attempt: Equatable, Sendable {
        case local(path: String)
        case remote(RemoteSelection)
    }

    static let storageKey = "startupPreferences"
    static let legacyKey = "defaultModelPath"
    static let minTimeout: Double = 2
    static let maxTimeout: Double = 60
    static let defaultTimeout: Double = 8

    var localModelPath: String?
    var remoteSelections: [RemoteSelection]
    var priority: Priority
    var remoteTimeout: Double

    init(localModelPath: String? = nil,
         remoteSelections: [RemoteSelection] = [],
         priority: Priority = .remoteFirst,
         remoteTimeout: Double = StartupPreferences.defaultTimeout) {
        self.localModelPath = localModelPath
        self.remoteSelections = remoteSelections
        self.priority = priority
        self.remoteTimeout = remoteTimeout
        normalize()
    }

    var hasLocalSelection: Bool { localModelPath?.isEmpty == false }
    var hasRemoteSelection: Bool { remoteSelections.contains { !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    func orderedAttempts(offGrid: Bool) -> [Attempt] {
        let trimmedLocal = localModelPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let localAttempt: Attempt? = (trimmedLocal?.isEmpty == false) ? .local(path: trimmedLocal!) : nil
        let remoteAttempts: [Attempt]
        if offGrid {
            remoteAttempts = []
        } else {
            remoteAttempts = remoteSelections
                .filter { !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { .remote($0) }
        }
        switch (localAttempt, remoteAttempts.isEmpty) {
        case (nil, true):
            return []
        case (let local?, true):
            return [local]
        case (nil, false):
            return remoteAttempts
        case (let local?, false):
            switch priority {
            case .remoteFirst:
                return remoteAttempts + [local]
            case .localFirst:
                return [local] + remoteAttempts
            }
        }
    }

    mutating func normalize() {
        if let trimmed = localModelPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            localModelPath = trimmed
        } else {
            localModelPath = nil
        }

        var seen: Set<RemoteBackend.ID> = []
        remoteSelections = remoteSelections.reduce(into: []) { partialResult, selection in
            if seen.insert(selection.backendID).inserted {
                var updated = selection
                updated.modelID = updated.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.modelName = updated.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.backendName = updated.backendName.trimmingCharacters(in: .whitespacesAndNewlines)
                partialResult.append(updated)
            }
        }

        remoteTimeout = max(Self.minTimeout, min(Self.maxTimeout, remoteTimeout))
    }
}

enum StartupPreferencesStore {
    static func load(defaults: UserDefaults = .standard) -> StartupPreferences {
        if let data = defaults.data(forKey: StartupPreferences.storageKey),
           let decoded = try? JSONDecoder().decode(StartupPreferences.self, from: data) {
            return decoded
        }
        if let legacy = defaults.string(forKey: StartupPreferences.legacyKey), !legacy.isEmpty {
            var migrated = StartupPreferences(localModelPath: legacy, priority: .localFirst)
            save(migrated, defaults: defaults)
            defaults.removeObject(forKey: StartupPreferences.legacyKey)
            return migrated
        }
        return StartupPreferences()
    }

    static func save(_ preferences: StartupPreferences, defaults: UserDefaults = .standard) {
        var normalized = preferences
        normalized.normalize()
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: StartupPreferences.storageKey)
        }
    }

    static func sanitize(preferences: StartupPreferences,
                         models: [LocalModel],
                         backends: [RemoteBackend],
                         defaults: UserDefaults = .standard) -> StartupPreferences {
        var sanitized = preferences
        let availableLocal = Set(models.map { $0.url.path })
        if let path = sanitized.localModelPath, !availableLocal.contains(path) {
            sanitized.localModelPath = nil
        }
        if !sanitized.remoteSelections.isEmpty {
            let backendMap = Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) })
            sanitized.remoteSelections = sanitized.remoteSelections.compactMap { selection in
                guard let backend = backendMap[selection.backendID] else { return nil }
                var updated = selection
                if updated.backendName != backend.name {
                    updated.backendName = backend.name
                }
                if let model = backend.cachedModels.first(where: { $0.id == selection.modelID }) {
                    if updated.modelName != model.name {
                        updated.modelName = model.name
                    }
                    if updated.relayRecordName != model.relayRecordName {
                        updated.relayRecordName = model.relayRecordName
                    }
                }
                return updated
            }
        }
        sanitized.normalize()
        save(sanitized, defaults: defaults)
        return sanitized
    }

    static func clearLocalPath(_ path: String, defaults: UserDefaults = .standard) {
        var preferences = load(defaults: defaults)
        if preferences.localModelPath == path {
            preferences.localModelPath = nil
            save(preferences, defaults: defaults)
        }
    }

    static func updateLocalPath(from oldPath: String, to newPath: String, defaults: UserDefaults = .standard) {
        var preferences = load(defaults: defaults)
        if preferences.localModelPath == oldPath {
            preferences.localModelPath = newPath
            save(preferences, defaults: defaults)
        }
    }

    static func removeRemoteSelections(for backendID: RemoteBackend.ID, defaults: UserDefaults = .standard) {
        var preferences = load(defaults: defaults)
        let filtered = preferences.remoteSelections.filter { $0.backendID != backendID }
        if filtered.count != preferences.remoteSelections.count {
            preferences.remoteSelections = filtered
            save(preferences, defaults: defaults)
        }
    }

    static func updateRemoteBackend(_ backend: RemoteBackend, defaults: UserDefaults = .standard) {
        var preferences = load(defaults: defaults)
        var changed = false
        for index in preferences.remoteSelections.indices {
            guard preferences.remoteSelections[index].backendID == backend.id else { continue }
            if preferences.remoteSelections[index].backendName != backend.name {
                preferences.remoteSelections[index].backendName = backend.name
                changed = true
            }
            if let model = backend.cachedModels.first(where: { $0.id == preferences.remoteSelections[index].modelID }) {
                if preferences.remoteSelections[index].modelName != model.name {
                    preferences.remoteSelections[index].modelName = model.name
                    changed = true
                }
                if preferences.remoteSelections[index].relayRecordName != model.relayRecordName {
                    preferences.remoteSelections[index].relayRecordName = model.relayRecordName
                    changed = true
                }
            }
        }
        if changed {
            save(preferences, defaults: defaults)
        }
    }
}

enum StartupLoader {
    @MainActor
    static func performStartupLoad(chatVM: ChatVM,
                                   modelManager: AppModelManager,
                                   offGrid: Bool) async {
        guard !UITestLaunchConfiguration.isFakeChatReadyEnabled else { return }
        guard !chatVM.modelLoaded, !chatVM.loading else { return }

        var preferences = StartupPreferencesStore.load()
        preferences = StartupPreferencesStore.sanitize(preferences: preferences,
                                                       models: modelManager.downloadedModels,
                                                       backends: modelManager.remoteBackends)

        if UserDefaults.standard.bool(forKey: "bypassRAMLoadPending") {
            UserDefaults.standard.set(false, forKey: "bypassRAMLoadPending")
            modelManager.refresh()
            chatVM.loadError = String(
                localized: "Previous model did not finish loading. Noema did not change its saved settings; adjust Model Settings manually before trying again.",
                locale: LocalizationManager.preferredLocale()
            )
            return
        }

        let attempts = preferences.orderedAttempts(offGrid: offGrid)
        guard !attempts.isEmpty else { return }

        modelManager.refresh()

        for attempt in attempts {
            switch attempt {
            case .remote(let selection):
                let success = await attemptRemote(selection,
                                                  chatVM: chatVM,
                                                  modelManager: modelManager,
                                                  timeout: preferences.remoteTimeout)
                if success { return }
            case .local(let path):
                let success = await attemptLocal(path: path,
                                                 chatVM: chatVM,
                                                 modelManager: modelManager)
                if success { return }
            }
        }
    }

    @MainActor
    private static func attemptLocal(path: String,
                                     chatVM: ChatVM,
                                     modelManager: AppModelManager) async -> Bool {
        guard let model = modelManager.downloadedModels.first(where: { $0.url.path == path }) else { return false }
        let settings = modelManager.settings(for: model)
        UserDefaults.standard.set(true, forKey: "bypassRAMLoadPending")
        await chatVM.unload()
        let success = await chatVM.load(url: model.url, settings: settings, format: model.format)
        if success {
            modelManager.updateSettings(settings, for: model)
            modelManager.markModelUsed(model)
        } else {
            modelManager.loadedModel = nil
        }
        UserDefaults.standard.set(false, forKey: "bypassRAMLoadPending")
        return success
    }

    @MainActor
    private static func attemptRemote(_ selection: StartupPreferences.RemoteSelection,
                                      chatVM: ChatVM,
                                      modelManager: AppModelManager,
                                      timeout: Double) async -> Bool {
        guard let backend = modelManager.remoteBackend(withID: selection.backendID) else { return false }
        let remoteModel = backend.cachedModels.first(where: { $0.id == selection.modelID })
            ?? RemoteModel(id: selection.modelID,
                           name: selection.modelName.isEmpty ? selection.modelID : selection.modelName,
                           author: selection.backendName,
                           relayRecordName: selection.relayRecordName)
        let remoteSettings = modelManager.remoteSettings(for: backend.id, model: remoteModel)

        let clampedTimeout = max(StartupPreferences.minTimeout, min(StartupPreferences.maxTimeout, timeout))
        let timeoutNanoseconds = UInt64(clampedTimeout * 1_000_000_000)

        enum RemoteOutcome { case success, failure, timeout }

        return await withTaskGroup(of: RemoteOutcome.self, returning: Bool.self) { group in
            group.addTask {
                do {
                    try await chatVM.activateRemoteSession(backend: backend, model: remoteModel, settings: remoteSettings)
                    return .success
                } catch {
                    await MainActor.run {
                        if chatVM.loadError == nil {
                            chatVM.loadError = error.localizedDescription
                        }
                    }
                    return .failure
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timeout
            }

            for await outcome in group {
                switch outcome {
                case .success:
                    group.cancelAll()
                    return true
                case .timeout:
                    group.cancelAll()
                    await MainActor.run {
                        if chatVM.loadError == nil {
                            chatVM.loadError = "Remote startup timed out after \(Int(clampedTimeout)) seconds."
                        }
                    }
                    return false
                case .failure:
                    group.cancelAll()
                    return false
                }
            }
            return false
        }
    }
}
