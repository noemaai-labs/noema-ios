import Foundation

struct InstalledModel: Identifiable, Codable, Sendable {
    let id: UUID
    let modelID: String
    let quantLabel: String
    let parameterCountLabel: String?
    let url: URL
    let format: ModelFormat
    let sizeBytes: Int64
    var lastUsed: Date?
    var installDate: Date
    let checksum: String?
    var isFavourite: Bool = false
    var totalLayers: Int = 0
    var isMultimodal: Bool = false
    var isToolCapable: Bool = false
    var moeInfo: MoEInfo? = nil
    var etBackend: ETBackend? = nil
    var alias: String? = nil
    var pagedPackageFingerprint: String? = nil
    var pagedPackageBytes: Int64? = nil

    init(id: UUID = UUID(), modelID: String, quantLabel: String, parameterCountLabel: String? = nil, url: URL, format: ModelFormat, sizeBytes: Int64, lastUsed: Date?, installDate: Date, checksum: String?, isFavourite: Bool, totalLayers: Int, isMultimodal: Bool = false, isToolCapable: Bool = false, moeInfo: MoEInfo? = nil, etBackend: ETBackend? = nil, alias: String? = nil, pagedPackageFingerprint: String? = nil, pagedPackageBytes: Int64? = nil) {
        self.id = id
        self.modelID = modelID
        self.quantLabel = quantLabel
        self.parameterCountLabel = parameterCountLabel
        self.url = url
        self.format = format
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.installDate = installDate
        self.checksum = checksum
        self.isFavourite = isFavourite
        self.totalLayers = totalLayers
        self.isMultimodal = isMultimodal
        self.isToolCapable = isToolCapable
        self.moeInfo = moeInfo
        self.etBackend = etBackend
        self.alias = alias
        self.pagedPackageFingerprint = pagedPackageFingerprint
        self.pagedPackageBytes = pagedPackageBytes
    }
}

extension InstalledModel {
    /// Human-friendly name for display in logs/UI.
    var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
        if !modelID.isEmpty {
            return quantLabel.isEmpty ? modelID : "\(modelID) (\(quantLabel))"
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

final class InstalledModelsStore {
    private struct PathMigration: Sendable {
        let oldPath: String
        let newPath: String
    }

    private var items: [InstalledModel] = []
    private let url: URL
    private let queue = DispatchQueue(label: "store")

    init(filename: String = "installed.json") {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent(filename)
        reload()
    }

    func isInstalled(id: String, quantLabel: String) -> Bool {
        queue.sync {
            items.contains { $0.modelID == id && $0.quantLabel == quantLabel }
        }
    }

    func all() -> [InstalledModel] { queue.sync { items } }

    func add(_ m: InstalledModel) {
        queue.sync {
            let url = Self.canonicalURL(for: m.url, format: m.format)
            let newModel = InstalledModel(id: m.id,
                                          modelID: m.modelID,
                                          quantLabel: m.quantLabel,
                                          parameterCountLabel: m.parameterCountLabel,
                                          url: url,
                                          format: m.format,
                                          sizeBytes: m.sizeBytes,
                                          lastUsed: m.lastUsed,
                                          installDate: m.installDate,
                                          checksum: m.checksum,
                                          isFavourite: m.isFavourite,
                                          totalLayers: m.totalLayers,
                                          isMultimodal: m.isMultimodal,
                                          isToolCapable: m.isToolCapable,
                                          moeInfo: m.moeInfo,
                                          etBackend: m.etBackend,
                                          alias: m.alias,
                                          pagedPackageFingerprint: m.pagedPackageFingerprint,
                                          pagedPackageBytes: m.pagedPackageBytes)
            self.items.append(newModel)
            self.save()
        }
    }

    func upsert(_ m: InstalledModel) {
        queue.sync {
            let url = Self.canonicalURL(for: m.url, format: m.format)
            let newModel = InstalledModel(id: m.id,
                                          modelID: m.modelID,
                                          quantLabel: m.quantLabel,
                                          parameterCountLabel: m.parameterCountLabel,
                                          url: url,
                                          format: m.format,
                                          sizeBytes: m.sizeBytes,
                                          lastUsed: m.lastUsed,
                                          installDate: m.installDate,
                                          checksum: m.checksum,
                                          isFavourite: m.isFavourite,
                                          totalLayers: m.totalLayers,
                                          isMultimodal: m.isMultimodal,
                                          isToolCapable: m.isToolCapable,
                                          moeInfo: m.moeInfo,
                                          etBackend: m.etBackend,
                                          alias: m.alias,
                                          pagedPackageFingerprint: m.pagedPackageFingerprint,
                                          pagedPackageBytes: m.pagedPackageBytes)
            if let index = self.items.firstIndex(where: { $0.modelID == m.modelID && $0.quantLabel == m.quantLabel }) {
                self.items[index] = newModel
            } else {
                self.items.append(newModel)
            }
            self.save()
        }
    }

    func updateLastUsed(modelID: String, quantLabel: String, date: Date) {
        queue.sync {
            if let idx = self.items.firstIndex(where: { $0.modelID == modelID && $0.quantLabel == quantLabel }) {
                self.items[idx].lastUsed = date
                self.save()
            }
        }
    }

    func remove(modelID: String, quantLabel: String) {
        queue.sync {
            self.items.removeAll { $0.modelID == modelID && $0.quantLabel == quantLabel }
            self.save()
        }
        Task {
            await MoEDetectionStore.shared.remove(modelID: modelID, quantLabel: quantLabel)
        }
    }

    func updateFavorite(modelID: String, quantLabel: String, fav: Bool) {
        queue.sync {
            if let idx = self.items.firstIndex(where: { $0.modelID == modelID && $0.quantLabel == quantLabel }) {
                self.items[idx].isFavourite = fav
                self.save()
            }
        }
    }

    func updateLayers(modelID: String, quantLabel: String, layers: Int) {
        queue.sync {
            if let index = items.firstIndex(where: { $0.modelID == modelID && $0.quantLabel == quantLabel }) {
                items[index].totalLayers = layers
                save()
            }
        }
    }

    func updateCapabilities(modelID: String, quantLabel: String, isMultimodal: Bool, isToolCapable: Bool) {
        queue.sync {
            if let index = items.firstIndex(where: { $0.modelID == modelID && $0.quantLabel == quantLabel }) {
                items[index].isMultimodal = isMultimodal
                items[index].isToolCapable = isToolCapable
                save()
            }
        }
    }

    func updateMoEInfo(modelID: String, quantLabel: String, info: MoEInfo?) {
        queue.sync {
            if let index = items.firstIndex(where: { $0.modelID == modelID && $0.quantLabel == quantLabel }) {
                items[index].moeInfo = info
                save()
            }
        }
    }

    func updateETBackend(modelID: String, quantLabel: String, backend: ETBackend?) {
        queue.sync {
            if let index = items.firstIndex(where: { $0.modelID == modelID && $0.quantLabel == quantLabel }) {
                items[index].etBackend = backend
                save()
            }
        }
    }

    func updateAlias(modelID: String, quantLabel: String, alias: String?) {
        queue.sync {
            if let index = items.firstIndex(where: { $0.modelID == modelID && $0.quantLabel == quantLabel }) {
                let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
                items[index].alias = trimmed?.isEmpty == false ? trimmed : nil
                save()
            }
        }
    }

    func reload() {
        let reloaded = queue.sync { () -> Bool in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([InstalledModel].self, from: data) else {
                return false
            }
            items = decoded
            return true
        }
        if reloaded {
            _ = migratePaths()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    var totalSizeBytes: Int64 { queue.sync { items.reduce(0) { $0 + $1.sizeBytes } } }

    /// Migrates GGUF and MLX records to ensure URLs use the canonical shape.
    /// GGUF entries store the `.gguf` file path; MLX entries store the root
    /// directory containing model files.
    @discardableResult
    func migratePaths() -> Bool {
        var changed = false
        var pendingMigrations: [PathMigration] = []
        queue.sync {
            for idx in items.indices {
                let item = items[idx]
                let canonical = Self.canonicalURL(for: item.url, format: item.format)
                if canonical != item.url {
                    let oldURL = item.url
                    items[idx] = InstalledModel(id: item.id,
                                               modelID: item.modelID,
                                               quantLabel: item.quantLabel,
                                               parameterCountLabel: item.parameterCountLabel,
                                               url: canonical,
                                               format: item.format,
                                               sizeBytes: item.sizeBytes,
                                               lastUsed: item.lastUsed,
                                               installDate: item.installDate,
                                               checksum: item.checksum,
                                               isFavourite: item.isFavourite,
                                               totalLayers: item.totalLayers,
                                               isMultimodal: item.isMultimodal,
                                               isToolCapable: item.isToolCapable,
                                               moeInfo: item.moeInfo,
                                               etBackend: item.etBackend,
                                               alias: item.alias)
                    pendingMigrations.append(PathMigration(oldPath: oldURL.path, newPath: canonical.path))
                    changed = true
                }
            }
            if changed { save() }
        }
        Self.applyPathMigrations(pendingMigrations)
        return changed
    }

    /// Collapses legacy fragmented split-GGUF installs (one store entry per shard)
    /// into a single logical installed model entry keyed by the primary shard.
    @discardableResult
    func migrateShardedGGUFEntries() -> Bool {
        var changed = false
        queue.sync {
            struct GroupKey: Hashable {
                let modelID: String
                let directoryPath: String
                let baseStem: String
                let partCount: Int
            }
            struct GroupState {
                var indices: [Int] = []
                var modelID: String
                var directoryURL: URL
                var baseStem: String
                var partCount: Int
            }

            var groups: [GroupKey: GroupState] = [:]

            for idx in items.indices {
                let item = items[idx]
                guard item.format == .gguf else { continue }
                guard let split = GGUFShardNaming.parseSplitFilename(item.url.lastPathComponent) else { continue }
                let dir = item.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                let key = GroupKey(
                    modelID: item.modelID,
                    directoryPath: dir.path,
                    baseStem: split.baseStem.lowercased(),
                    partCount: split.partCount
                )
                var state = groups[key] ?? GroupState(indices: [], modelID: item.modelID, directoryURL: dir, baseStem: split.baseStem, partCount: split.partCount)
                state.indices.append(idx)
                groups[key] = state
            }

            guard !groups.isEmpty else { return }

            let fm = FileManager.default
            var removalIndices = Set<Int>()
            var replacements: [InstalledModel] = []

            func writeShardArtifacts(in dir: URL, primaryName: String, shardNames: [String]) {
                let artifactsURL = dir.appendingPathComponent("artifacts.json")
                var obj: [String: Any] = [:]
                if let data = try? Data(contentsOf: artifactsURL),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    obj = parsed
                }
                obj["weights"] = primaryName
                obj["weightShards"] = shardNames
                if obj["mmproj"] == nil { obj["mmproj"] = NSNull() }
                if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
                    try? out.write(to: artifactsURL)
                }
            }

            func isProjectorFile(_ url: URL) -> Bool {
                let name = url.lastPathComponent.lowercased()
                return name.contains("mmproj")
                    || name.contains("projector")
                    || name.contains("image_proj")
                    || name.contains("imatrix")
            }

            for (_, state) in groups {
                // We only collapse fragmented installs (multiple store entries for the same split group).
                guard state.indices.count > 1 else { continue }

                guard let dirContents = try? fm.contentsOfDirectory(at: state.directoryURL, includingPropertiesForKeys: nil) else { continue }

                var shardsByPart: [Int: URL] = [:]
                for file in dirContents {
                    guard file.pathExtension.lowercased() == "gguf" else { continue }
                    guard !isProjectorFile(file) else { continue }
                    guard let split = GGUFShardNaming.parseSplitFilename(file.lastPathComponent) else { continue }
                    guard split.baseStem.caseInsensitiveCompare(state.baseStem) == .orderedSame else { continue }
                    guard split.partCount == state.partCount else { continue }
                    guard Self.isValidGGUF(at: file) else { continue }
                    if shardsByPart[split.partIndex] == nil {
                        shardsByPart[split.partIndex] = file.resolvingSymlinksInPath().standardizedFileURL
                    }
                }

                guard shardsByPart.count == state.partCount else { continue }

                let orderedParts = shardsByPart.keys.sorted()
                guard let firstPartIndex = orderedParts.first,
                      let primary = shardsByPart[1] ?? shardsByPart[firstPartIndex] else { continue }

                let orderedShardURLs = orderedParts.compactMap { shardsByPart[$0] }
                let shardNames = orderedShardURLs.map { $0.lastPathComponent }
                let totalSize = orderedShardURLs.reduce(into: Int64(0)) { result, url in
                    let sz = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                    result += sz
                }

                let sourceItems = state.indices.map { items[$0] }
                let earliestInstall = sourceItems.map(\.installDate).min() ?? Date()
                let latestLastUsed = sourceItems.compactMap(\.lastUsed).max()
                let totalLayers = sourceItems.map(\.totalLayers).max() ?? 0
                let mergedMoE: MoEInfo? =
                    sourceItems.compactMap(\.moeInfo).first(where: { $0.isMoE }) ??
                    sourceItems.compactMap(\.moeInfo).first
                let quantLabel = GGUFShardNaming.normalizedQuantLabel(for: primary.lastPathComponent, repoID: state.modelID)

                writeShardArtifacts(in: state.directoryURL, primaryName: primary.lastPathComponent, shardNames: shardNames)

                let merged = InstalledModel(
                    modelID: state.modelID,
                    quantLabel: quantLabel,
                    parameterCountLabel: sourceItems.compactMap(\.parameterCountLabel).first,
                    url: Self.canonicalURL(for: primary, format: .gguf),
                    format: .gguf,
                    sizeBytes: totalSize > 0 ? totalSize : sourceItems.reduce(0) { $0 + $1.sizeBytes },
                    lastUsed: latestLastUsed,
                    installDate: earliestInstall,
                    checksum: nil,
                    isFavourite: sourceItems.contains(where: { $0.isFavourite }),
                    totalLayers: totalLayers,
                    isMultimodal: sourceItems.contains(where: { $0.isMultimodal }),
                    isToolCapable: sourceItems.contains(where: { $0.isToolCapable }),
                    moeInfo: mergedMoE,
                    etBackend: nil,
                    alias: sourceItems.compactMap(\.alias).first
                )

                removalIndices.formUnion(state.indices)
                replacements.append(merged)
            }

            guard !replacements.isEmpty else { return }

            items = items.enumerated()
                .filter { !removalIndices.contains($0.offset) }
                .map(\.element)
            items.append(contentsOf: replacements)
            save()
            changed = true
        }
        return changed
    }

    private static func splitModelID(_ modelID: String) -> (owner: String?, repo: String) {
        guard let slash = modelID.firstIndex(of: "/") else {
            return (nil, modelID)
        }
        let owner = String(modelID[..<slash])
        let repo = String(modelID[modelID.index(after: slash)...])
        return (owner.isEmpty ? nil : owner, repo)
    }

    private static func sanitizedRepoComponent(for format: ModelFormat, repo: String) -> String {
        switch format {
        case .mlx:
            let trimmed = repo.replacingOccurrences(of: #"(?i)([-_]?gguf)$"#, with: "", options: .regularExpression)
            let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            return cleaned.isEmpty ? repo : cleaned
        default:
            return repo
        }
    }

    static func normalizedRepoName(for format: ModelFormat, modelID: String) -> String {
        let (_, repo) = splitModelID(modelID)
        return sanitizedRepoComponent(for: format, repo: repo)
    }

    static func canonicalURL(for url: URL, format: ModelFormat) -> URL {
        let fixed = url.resolvingSymlinksInPath().standardizedFileURL
        switch format {
        case .gguf:
            // Paged packages canonicalize to their resident GGUF so every
            // downstream GGUF path (metadata, benchmarks, the loopback lease)
            // stays on a real .gguf file.
            if let packageDir = PagedPackageLocator.enclosingPackage(for: fixed) {
                return PagedPackageLocator.residentGGUF(inPackage: packageDir)
                    .resolvingSymlinksInPath().standardizedFileURL
            }
            if fixed.pathExtension.lowercased() == "gguf" { return fixed }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fixed.path, isDirectory: &isDir), isDir.boolValue,
               let found = firstGGUF(in: fixed) {
                return found.resolvingSymlinksInPath().standardizedFileURL
            }
            return fixed
        case .mlx:
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fixed.path, isDirectory: &isDir) {
                return (isDir.boolValue ? fixed : fixed.deletingLastPathComponent()).resolvingSymlinksInPath().standardizedFileURL
            }
            return fixed
        case .et:
            if fixed.pathExtension.lowercased() == "pte" { return fixed }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fixed.path, isDirectory: &isDir), isDir.boolValue,
               let found = firstPTE(in: fixed) {
                return found.resolvingSymlinksInPath().standardizedFileURL
            }
            return fixed
        case .ane:
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if let artifact = enclosingANEArtifact(for: fixed) {
                return artifact.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            }
            if fm.fileExists(atPath: fixed.path, isDirectory: &isDir), isDir.boolValue {
                if firstANEArtifact(in: fixed) != nil {
                    return fixed
                }
                if firstANEArtifact(in: fixed.deletingLastPathComponent()) != nil {
                    return fixed.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                }
                return fixed
            }
            let parent = fixed.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            return parent
        case .afm:
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fixed.path, isDirectory: &isDir), isDir.boolValue {
                return fixed
            }
            return fixed.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        case .coreai:
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if let artifact = enclosingCoreAIArtifact(for: fixed) {
                return artifact.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            }
            if fm.fileExists(atPath: fixed.path, isDirectory: &isDir), isDir.boolValue {
                return fixed
            }
            return fixed.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        }
    }

    /// Walks up from `url` to find an enclosing `.aimodel` / `.aimodelc` bundle.
    static func enclosingCoreAIArtifact(for url: URL) -> URL? {
        let fm = FileManager.default
        var candidate = url.resolvingSymlinksInPath().standardizedFileURL
        while true {
            let ext = candidate.pathExtension.lowercased()
            if (ext == "aimodel" || ext == "aimodelc"),
               fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            // Directory-flagged URLs never converge at "/" — deleting yields
            // "/..", then "/../.." forever. Stop on any non-shrinking step.
            if parent.path.count >= candidate.path.count {
                return nil
            }
            candidate = parent
        }
    }

    /// Finds the first `.aimodel` / `.aimodelc` bundle directly inside `dir`.
    static func firstCoreAIArtifact(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries.first { url in
            let ext = url.pathExtension.lowercased()
            return ext == "aimodel" || ext == "aimodelc"
        }
    }

    static func enclosingANEArtifact(for url: URL) -> URL? {
        let fm = FileManager.default
        var candidate = url.resolvingSymlinksInPath().standardizedFileURL

        while true {
            let ext = candidate.pathExtension.lowercased()
            if (ext == "mlmodelc" || ext == "mlpackage" || ext == "mlmodel"),
               fm.fileExists(atPath: candidate.path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            // Directory-flagged URLs never converge at "/" — deleting yields
            // "/..", then "/../.." forever. Stop on any non-shrinking step.
            if parent.path.count >= candidate.path.count {
                return nil
            }
            candidate = parent
        }
    }

    static func localModelURL(for quant: QuantInfo, modelID: String) -> URL {
        let base = baseDir(for: quant.format, modelID: modelID)
        switch quant.format {
        case .ane:
            return canonicalURL(for: base, format: .ane)
        case .afm:
            return canonicalURL(for: base, format: .afm)
        case .coreai:
            return canonicalURL(for: base, format: .coreai)
        case .gguf, .mlx, .et:
            let relativePath = quant.primaryDownloadRelativePath
            let candidate = base.appendingPathComponent(relativePath)
            return canonicalURL(for: candidate, format: quant.format)
        }
    }

    /// Base directory used for storing models of the given format and id.
    static func baseDir(for format: ModelFormat, modelID: String) -> URL {
        switch format {
        case .gguf, .mlx, .et, .ane, .afm, .coreai:
            var dir = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalLLMModels", isDirectory: true)
            let parts = splitModelID(modelID)
            if let owner = parts.owner, !owner.isEmpty {
                dir.appendPathComponent(owner, isDirectory: true)
            }
            let repoComponent = sanitizedRepoComponent(for: format, repo: parts.repo)
            dir.appendPathComponent(repoComponent, isDirectory: true)
            return dir
        }
    }

    /// Attempts to repair missing paths by recomputing them under the current sandbox.
    @discardableResult
    func rehomeIfMissing() -> Bool {
        var changed = false
        var pendingMigrations: [PathMigration] = []
        queue.sync {
            for idx in items.indices {
                let item = items[idx]
                guard !FileManager.default.fileExists(atPath: item.url.path) else { continue }
                let base = Self.baseDir(for: item.format, modelID: item.modelID)
                let repaired: URL?
                switch item.format {
                case .gguf:
                    repaired = Self.firstGGUF(in: base)
                case .mlx:
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir)
                    repaired = (exists && isDir.boolValue) ? base : nil
                case .et:
                    repaired = Self.firstPTE(in: base)
                case .ane:
                    if Self.firstANEArtifact(in: base) != nil {
                        repaired = Self.canonicalURL(for: base, format: .ane)
                    } else {
                        repaired = nil
                    }
                case .afm:
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue {
                        repaired = Self.canonicalURL(for: base, format: .afm)
                    } else {
                        repaired = nil
                    }
                case .coreai:
                    if Self.firstCoreAIArtifact(in: base) != nil || Self.enclosingCoreAIArtifact(for: base) != nil {
                        repaired = Self.canonicalURL(for: base, format: .coreai)
                    } else {
                        repaired = nil
                    }
                }
                if let newURL = repaired {
                    let oldURL = item.url
                    items[idx] = InstalledModel(id: item.id,
                                               modelID: item.modelID,
                                               quantLabel: item.quantLabel,
                                               parameterCountLabel: item.parameterCountLabel,
                                               url: newURL,
                                               format: item.format,
                                               sizeBytes: item.sizeBytes,
                                               lastUsed: item.lastUsed,
                                               installDate: item.installDate,
                                               checksum: item.checksum,
                                               isFavourite: item.isFavourite,
                                               totalLayers: item.totalLayers,
                                               isMultimodal: item.isMultimodal,
                                               isToolCapable: item.isToolCapable,
                                               moeInfo: item.moeInfo,
                                               etBackend: item.etBackend,
                                               alias: item.alias)
                    pendingMigrations.append(PathMigration(oldPath: oldURL.path, newPath: newURL.path))
                    changed = true
                }
            }
            if changed { save() }
        }
        Self.applyPathMigrations(pendingMigrations)
        return changed
    }

    private static func applyPathMigrations(_ migrations: [PathMigration]) {
        guard !migrations.isEmpty else { return }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.applyPathMigrationsOnMain(migrations)
            }
        } else {
            Task { @MainActor in
                Self.applyPathMigrationsOnMain(migrations)
            }
        }
    }

    @MainActor
    private static func applyPathMigrationsOnMain(_ migrations: [PathMigration]) {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        var modelSettings = defaults.data(forKey: "modelSettings")
            .flatMap { try? decoder.decode([String: ModelSettings].self, from: $0) } ?? [:]
        var didUpdateModelSettings = false
        var canonicalPathMigrations: [(oldPath: String, newPath: String)] = []

        for migration in migrations {
            StartupPreferencesStore.updateLocalPath(from: migration.oldPath, to: migration.newPath)
            if let settings = modelSettings.removeValue(forKey: migration.oldPath) {
                modelSettings[migration.newPath] = settings
                didUpdateModelSettings = true
            }
            canonicalPathMigrations.append((oldPath: migration.oldPath, newPath: migration.newPath))
        }

        if didUpdateModelSettings, let newData = try? JSONEncoder().encode(modelSettings) {
            defaults.set(newData, forKey: "modelSettings")
        }
        ModelSettingsStore.migrateCanonicalPaths(canonicalPathMigrations)
    }

    /// Returns true if the given URL is a readable GGUF file (magic == "GGUF").
    static func isValidGGUF(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gguf" else { return false }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let magic = try? fh.read(upToCount: 4)
        return magic == Data("GGUF".utf8)
    }

    static func firstGGUF(in dir: URL) -> URL? {
        // Collect all .gguf files in the directory and one level of subdirectories
        var candidates: [URL] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "gguf" })
            for sub in files {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue,
                   let subfiles = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
                    candidates.append(contentsOf: subfiles.filter { $0.pathExtension.lowercased() == "gguf" })
                }
            }
        }
        if candidates.isEmpty { return nil }
        // Prefer non-mmproj/projector files and validate GGUF magic; choose the largest by size
        func isMMProj(_ u: URL) -> Bool {
            let name = u.lastPathComponent.lowercased()
            return name.contains("mmproj")
                || name.contains("projector")
                || name.contains("image_proj")
                || name.contains("imatrix")
        }
        func fileSize(_ u: URL) -> Int64 {
            (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
        }
        let valid = candidates.filter { isValidGGUF(at: $0) }
        let weights = valid.filter { !isMMProj($0) }
        func rank(_ u: URL) -> Int {
            if GGUFShardNaming.isShardPartOne(u) { return 0 }
            return 1
        }
        if let best = weights.sorted(by: {
            let r0 = rank($0)
            let r1 = rank($1)
            if r0 != r1 { return r0 < r1 }
            return fileSize($0) > fileSize($1)
        }).first {
            return best
        }
        // If only mmproj files exist, do not return them as model weights.
        return nil
    }

    static func firstPTE(in dir: URL) -> URL? {
        var candidates: [URL] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "pte" })
            for sub in files {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue,
                   let subfiles = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
                    candidates.append(contentsOf: subfiles.filter { $0.pathExtension.lowercased() == "pte" })
                }
            }
        }
        if candidates.isEmpty { return nil }
        return candidates.sorted(by: { lhs, rhs in
            let l = lhs.lastPathComponent.lowercased()
            let r = rhs.lastPathComponent.lowercased()
            if l == "model.pte" { return true }
            if r == "model.pte" { return false }
            return l < r
        }).first
    }

    static func firstANEArtifact(in dir: URL) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: file.path, isDirectory: &isDir)
                guard exists else { continue }
                let ext = file.pathExtension.lowercased()
                if isDir.boolValue {
                    if ext == "mlmodelc" || ext == "mlpackage" {
                        candidates.append(file)
                    }
                } else if ext == "mlmodel" {
                    candidates.append(file)
                }
            }
        }

        if candidates.isEmpty {
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
                while let item = enumerator.nextObject() as? URL {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
                    let ext = item.pathExtension.lowercased()
                    if isDir.boolValue {
                        if ext == "mlmodelc" || ext == "mlpackage" {
                            candidates.append(item)
                        }
                    } else if ext == "mlmodel" {
                        candidates.append(item)
                    }
                }
            }
        }

        if candidates.isEmpty { return nil }
        func priority(_ url: URL) -> Int {
            switch url.pathExtension.lowercased() {
            case "mlmodelc": return 0
            case "mlpackage": return 1
            case "mlmodel": return 2
            default: return 9
            }
        }
        return candidates.sorted { lhs, rhs in
            let lp = priority(lhs)
            let rp = priority(rhs)
            if lp != rp { return lp < rp }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }.first
    }
}

// Access is serialized via an internal queue, so it's safe to treat as Sendable.
extension InstalledModelsStore: @unchecked Sendable {}
