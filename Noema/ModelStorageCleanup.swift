import Foundation

enum ModelStorageCleanup {
    struct Result: Equatable {
        var removedFiles = 0
        var removedDirectories = 0
        var removedDownloadArtifacts = 0

        var didRemoveAnything: Bool {
            removedFiles > 0 || removedDirectories > 0 || removedDownloadArtifacts > 0
        }
    }

    static func installRoot(for model: LocalModel) -> URL {
        InstalledModelsStore.baseDir(for: model.format, modelID: model.modelID)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static func installRoot(for installed: InstalledModel) -> URL {
        InstalledModelsStore.baseDir(for: installed.format, modelID: installed.modelID)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    @discardableResult
    static func deleteModelFiles(for model: LocalModel,
                                 installedModels: [InstalledModel],
                                 fileManager fm: FileManager = .default) -> Result {
        guard model.format != .afm else { return Result() }

        let root = installRoot(for: model)
        let canonicalURL = InstalledModelsStore.canonicalURL(for: model.url, format: model.format)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let remainingInstalled = installedModels.filter {
            !($0.modelID == model.modelID && $0.quantLabel == model.quant)
        }
        let rootIsShared = remainingInstalled.contains {
            installRoot(for: $0).path == root.path && fm.fileExists(atPath: $0.url.path)
        }

        var result = Result()
        if !rootIsShared {
            removeDirectoryIfPresent(root, result: &result, fileManager: fm)
            pruneEmptyAncestors(from: root.deletingLastPathComponent(), stoppingAt: localModelsRoot(), result: &result, fileManager: fm)
            return result
        }

        removeTargetArtifacts(for: model, canonicalURL: canonicalURL, root: root, result: &result, fileManager: fm)
        pruneArtifactsJSON(in: root, removing: canonicalURL, result: &result, fileManager: fm)
        pruneEmptyAncestors(from: canonicalURL.deletingLastPathComponent(), stoppingAt: root, result: &result, fileManager: fm)
        return result
    }

    @discardableResult
    static func deleteURLs(_ urls: [URL], fileManager fm: FileManager = .default) -> Result {
        var result = Result()
        for url in urls {
            let isStagingURL = url.pathExtension.lowercased() == "download"
            removeItemIfPresent(url, result: &result, fileManager: fm, isDownloadArtifact: isStagingURL)
            removeItemIfPresent(url.appendingPathExtension("download"), result: &result, fileManager: fm, isDownloadArtifact: true)
            if isStagingURL {
                continue
            }
            let downloadSibling = URL(fileURLWithPath: url.path + ".download")
            removeItemIfPresent(downloadSibling, result: &result, fileManager: fm, isDownloadArtifact: true)
        }
        return result
    }

    @discardableResult
    static func pruneOrphanedModelDirectories(installedModels: [InstalledModel],
                                              activeDownloadURLs: Set<String>,
                                              fileManager fm: FileManager = .default) -> Result {
        let root = localModelsRoot()
        guard fm.fileExists(atPath: root.path) else { return Result() }

        var protectedRoots = Set(installedModels.map { installRoot(for: $0).path })
        protectedRoots.insert(EmbeddingModelCatalog.baseDirectory.standardizedFileURL.path)
        protectedRoots.insert(WhisperModelCatalog.baseDirectory.standardizedFileURL.path)

        var result = Result()
        pruneDownloadFiles(under: root, activeDownloadURLs: activeDownloadURLs, result: &result, fileManager: fm)
        removeUnreferencedLeafDirectories(under: root, protectedRoots: protectedRoots, activeDownloadURLs: activeDownloadURLs, result: &result, fileManager: fm)
        return result
    }

    @discardableResult
    static func removeAllSupportModelStorage(fileManager fm: FileManager = .default) -> Result {
        var result = Result()
        removeDirectoryIfPresent(EmbeddingModelCatalog.baseDirectory, result: &result, fileManager: fm)
        removeDirectoryIfPresent(WhisperModelCatalog.baseDirectory, result: &result, fileManager: fm)
        UserDefaults.standard.removeObject(forKey: EmbeddingModelCatalog.activeModelIDKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.whisperKitActiveModelKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.whisperCppActiveModelKey)
        return result
    }

    static func clearPassExtractionSelectionIfNeeded(deletedModel: LocalModel, defaults: UserDefaults = .standard) {
        let storedPath = defaults.string(forKey: PassExtractionModelCatalog.activeModelPathKey) ?? ""
        let storedID = defaults.string(forKey: PassExtractionModelCatalog.activeModelIDKey) ?? ""
        let storedQuant = defaults.string(forKey: PassExtractionModelCatalog.activeModelQuantKey) ?? ""
        let storedFormat = defaults.string(forKey: PassExtractionModelCatalog.activeModelFormatKey) ?? ""
        let pathMatches = !storedPath.isEmpty && storedPath == deletedModel.url.path
        let identityMatches = storedID == deletedModel.modelID
            && (storedQuant.isEmpty || storedQuant == deletedModel.quant)
            && (storedFormat.isEmpty || storedFormat == deletedModel.format.rawValue)
        guard pathMatches || identityMatches else { return }
        defaults.removeObject(forKey: PassExtractionModelCatalog.activeModelPathKey)
        defaults.removeObject(forKey: PassExtractionModelCatalog.activeModelIDKey)
        defaults.removeObject(forKey: PassExtractionModelCatalog.activeModelQuantKey)
        defaults.removeObject(forKey: PassExtractionModelCatalog.activeModelFormatKey)
        defaults.removeObject(forKey: PassExtractionModelCatalog.activeModelNameKey)
    }

    private static func removeTargetArtifacts(for model: LocalModel,
                                              canonicalURL: URL,
                                              root: URL,
                                              result: inout Result,
                                              fileManager fm: FileManager) {
        var targets: Set<URL> = [canonicalURL]
        targets.insert(URL(fileURLWithPath: canonicalURL.path + ".download"))

        if model.format == .gguf {
            if let split = GGUFShardNaming.parseSplitFilename(canonicalURL.lastPathComponent),
               let files = try? fm.contentsOfDirectory(at: canonicalURL.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "gguf" || file.pathExtension.lowercased() == "download" {
                    let name = file.pathExtension.lowercased() == "download"
                        ? file.deletingPathExtension().lastPathComponent
                        : file.lastPathComponent
                    guard let candidate = GGUFShardNaming.parseSplitFilename(name),
                          candidate.baseStem.caseInsensitiveCompare(split.baseStem) == .orderedSame,
                          candidate.partCount == split.partCount else { continue }
                    targets.insert(file)
                }
            }
            if let artifactTargets = artifactTargetsFromJSON(in: root, canonicalURL: canonicalURL) {
                targets.formUnion(artifactTargets)
            }
            targets.insert(canonicalURL.deletingLastPathComponent().appendingPathComponent("ds_markers.cache.json"))
        }

        for target in targets {
            removeItemIfPresent(target, result: &result, fileManager: fm, isDownloadArtifact: target.pathExtension.lowercased() == "download")
        }
    }

    private static func artifactTargetsFromJSON(in root: URL, canonicalURL: URL) -> Set<URL>? {
        let artifactsURL = root.appendingPathComponent("artifacts.json")
        guard let data = try? Data(contentsOf: artifactsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var targets: Set<URL> = []
        func appendRelative(_ value: Any?) {
            guard let relative = value as? String, !relative.isEmpty else { return }
            let url = root.appendingPathComponent(relative)
            if url.lastPathComponent == canonicalURL.lastPathComponent || relative == canonicalURL.lastPathComponent {
                targets.insert(url)
                targets.insert(URL(fileURLWithPath: url.path + ".download"))
            }
        }
        appendRelative(obj["weights"])
        appendRelative(obj["mmproj"])
        appendRelative(obj["imatrix"])
        appendRelative(obj["mtp"])
        if let shards = obj["weightShards"] as? [String] {
            for shard in shards {
                let url = root.appendingPathComponent(shard)
                if shard == canonicalURL.lastPathComponent || GGUFShardNaming.sameSplitFamily(shard, canonicalURL.lastPathComponent) {
                    targets.insert(url)
                    targets.insert(URL(fileURLWithPath: url.path + ".download"))
                }
            }
        }
        return targets
    }

    private static func pruneArtifactsJSON(in root: URL,
                                           removing canonicalURL: URL,
                                           result: inout Result,
                                           fileManager fm: FileManager) {
        let artifactsURL = root.appendingPathComponent("artifacts.json")
        guard let data = try? Data(contentsOf: artifactsURL),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let removedName = canonicalURL.lastPathComponent
        var didChange = false

        for key in ["weights", "mmproj", "imatrix", "mtp"] {
            if let value = obj[key] as? String,
               value == removedName || root.appendingPathComponent(value).path == canonicalURL.path {
                obj.removeValue(forKey: key)
                didChange = true
            }
        }

        if let shards = obj["weightShards"] as? [String] {
            let filtered = shards.filter { shard in
                shard != removedName && !GGUFShardNaming.sameSplitFamily(shard, removedName)
            }
            if filtered.count != shards.count {
                if filtered.isEmpty {
                    obj.removeValue(forKey: "weightShards")
                } else {
                    obj["weightShards"] = filtered
                }
                didChange = true
            }
        }

        guard didChange else { return }
        if obj.isEmpty {
            removeItemIfPresent(artifactsURL, result: &result, fileManager: fm)
        } else if let output = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? output.write(to: artifactsURL, options: [.atomic])
        }
    }

    private static func pruneDownloadFiles(under root: URL,
                                           activeDownloadURLs: Set<String>,
                                           result: inout Result,
                                           fileManager fm: FileManager) {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "download" {
            let path = url.standardizedFileURL.path
            guard !activeDownloadURLs.contains(path) else { continue }
            removeItemIfPresent(url, result: &result, fileManager: fm, isDownloadArtifact: true)
        }
    }

    private static func removeUnreferencedLeafDirectories(under root: URL,
                                                          protectedRoots: Set<String>,
                                                          activeDownloadURLs: Set<String>,
                                                          result: inout Result,
                                                          fileManager fm: FileManager) {
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for owner in children {
            guard isDirectory(owner, fileManager: fm) else { continue }
            if protectedRoots.contains(owner.standardizedFileURL.path) { continue }
            if owner.lastPathComponent == "Embeddings" || owner.lastPathComponent == "Whisper" { continue }

            let repoChildren = (try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            if repoChildren.isEmpty {
                removeDirectoryIfPresent(owner, result: &result, fileManager: fm)
                continue
            }
            for repo in repoChildren where isDirectory(repo, fileManager: fm) {
                let path = repo.standardizedFileURL.path
                guard !protectedRoots.contains(path) else { continue }
                guard !activeDownloadURLs.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else { continue }
                guard directoryContainsModelPayload(repo, fileManager: fm) else { continue }
                removeDirectoryIfPresent(repo, result: &result, fileManager: fm)
            }
            pruneEmptyAncestors(from: owner, stoppingAt: root, result: &result, fileManager: fm)
        }
    }

    private static func directoryContainsModelPayload(_ url: URL, fileManager fm: FileManager) -> Bool {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
        let payloadExtensions: Set<String> = ["gguf", "safetensors", "pte", "bundle", "mlmodelc", "mlpackage", "mlmodel", "download"]
        for case let item as URL in enumerator {
            if payloadExtensions.contains(item.pathExtension.lowercased()) { return true }
        }
        return false
    }

    private static func localModelsRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLMModels", isDirectory: true)
            .standardizedFileURL
    }

    private static func removeDirectoryIfPresent(_ url: URL, result: inout Result, fileManager fm: FileManager) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        if (try? fm.removeItem(at: url)) != nil {
            result.removedDirectories += 1
        }
    }

    private static func removeItemIfPresent(_ url: URL,
                                            result: inout Result,
                                            fileManager fm: FileManager,
                                            isDownloadArtifact: Bool = false) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if (try? fm.removeItem(at: url)) != nil {
            if isDir.boolValue {
                result.removedDirectories += 1
            } else if isDownloadArtifact {
                result.removedDownloadArtifacts += 1
            } else {
                result.removedFiles += 1
            }
        }
    }

    private static func pruneEmptyAncestors(from start: URL,
                                            stoppingAt stop: URL,
                                            result: inout Result,
                                            fileManager fm: FileManager) {
        var current = start.standardizedFileURL
        let stopPath = stop.standardizedFileURL.path
        while current.path.hasPrefix(stopPath), current.path != stopPath {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path), contents.isEmpty else { break }
            removeDirectoryIfPresent(current, result: &result, fileManager: fm)
            current.deleteLastPathComponent()
        }
    }

    private static func isDirectory(_ url: URL, fileManager fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

private extension GGUFShardNaming {
    static func sameSplitFamily(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = parseSplitFilename(lhs), let right = parseSplitFilename(rhs) else { return false }
        return left.baseStem.caseInsensitiveCompare(right.baseStem) == .orderedSame
            && left.partCount == right.partCount
    }
}
