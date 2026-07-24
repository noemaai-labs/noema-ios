import Foundation

enum VisionProjectorDownloadPreference: String, CaseIterable, Identifiable, Sendable {
    static let defaultsKey = "defaultVisionProjectorDownloadPreference"
    static let defaultPreference: Self = .f16

    case highestQuality
    case f32
    case f16
    case q8_0
    case lowestQuality

    var id: String { rawValue }

    static var current: Self {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let preference = Self(rawValue: raw) else {
            return defaultPreference
        }
        return preference
    }

    var titleKey: String {
        switch self {
        case .highestQuality: return "Highest Quality"
        case .f32: return "F32"
        case .f16: return "F16"
        case .q8_0: return "Q8_0"
        case .lowestQuality: return "Lowest Quality"
        }
    }

    /// Explicit labels for the download setting, where a generic quality label could
    /// be mistaken for the quality or quantization of the language-model weights.
    var mmprojTitleKey: String {
        switch self {
        case .highestQuality: return "Highest quality mmproj"
        case .f32: return "F32 mmproj"
        case .f16: return "F16 mmproj"
        case .q8_0: return "Q8_0 mmproj"
        case .lowestQuality: return "Lowest quality mmproj"
        }
    }

    var requiresExactMatch: Bool {
        switch self {
        case .f32, .f16, .q8_0: return true
        case .highestQuality, .lowestQuality: return false
        }
    }
}

struct VisionProjectorArtifact: Identifiable, Hashable, Sendable {
    let repositoryID: String
    let filename: String
    let size: Int64
    let repositoryPriority: Int

    var id: String { "\(repositoryID)/\(filename)" }

    var qualityLabel: String {
        VisionProjectorQuality.qualityLabel(for: filename)
    }
}

struct VisionProjectorDownloadPlan: Sendable {
    let preference: VisionProjectorDownloadPreference
    let selected: VisionProjectorArtifact?
    let alternatives: [VisionProjectorArtifact]

    var requiresUserChoice: Bool {
        preference.requiresExactMatch && selected == nil && !alternatives.isEmpty
    }
}

private enum VisionProjectorQuality {
    static func normalizedName(_ filename: String) -> String {
        filename.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    static func matches(_ artifact: VisionProjectorArtifact, preference: VisionProjectorDownloadPreference) -> Bool {
        let name = normalizedName(artifact.filename)
        switch preference {
        case .f32:
            return name.contains("F32") || name.contains("FP32")
        case .f16:
            return (name.contains("F16") || name.contains("FP16")) && !name.contains("BF16")
        case .q8_0:
            return name.contains("Q8_0")
        case .highestQuality, .lowestQuality:
            return true
        }
    }

    static func qualityScore(for filename: String) -> Int {
        let name = normalizedName(filename)
        if name.contains("F32") || name.contains("FP32") { return 320 }
        if name.contains("BF16") { return 161 }
        if name.contains("F16") || name.contains("FP16") { return 160 }
        for bits in stride(from: 8, through: 1, by: -1) where name.contains("Q\(bits)") {
            return bits * 10
        }
        if name.contains("TQ1") { return 9 }
        // Unknown projector encodings sort between Q8 and F16 instead of being
        // mistaken for either the best or the lowest-quality choice.
        return 100
    }

    static func qualityLabel(for filename: String) -> String {
        let name = normalizedName(filename)
        if name.contains("F32") || name.contains("FP32") { return "F32" }
        if name.contains("BF16") { return "BF16" }
        if name.contains("F16") || name.contains("FP16") { return "F16" }
        for bits in stride(from: 8, through: 1, by: -1) {
            if name.contains("Q\(bits)_0") { return "Q\(bits)_0" }
            if name.contains("Q\(bits)") { return "Q\(bits)" }
        }
        if name.contains("TQ1") { return "TQ1" }
        return String(localized: "Other")
    }

    static func ordered(
        _ artifacts: [VisionProjectorArtifact],
        for preference: VisionProjectorDownloadPreference
    ) -> [VisionProjectorArtifact] {
        artifacts.sorted { lhs, rhs in
            let lhsScore = qualityScore(for: lhs.filename)
            let rhsScore = qualityScore(for: rhs.filename)
            if lhsScore != rhsScore {
                return preference == .lowestQuality ? lhsScore < rhsScore : lhsScore > rhsScore
            }
            if lhs.repositoryPriority != rhs.repositoryPriority {
                return lhs.repositoryPriority < rhs.repositoryPriority
            }
            if lhs.size != rhs.size, lhs.size > 0, rhs.size > 0 {
                return preference == .lowestQuality ? lhs.size < rhs.size : lhs.size > rhs.size
            }
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
    }

    static func plan(
        artifacts: [VisionProjectorArtifact],
        preference: VisionProjectorDownloadPreference
    ) -> VisionProjectorDownloadPlan {
        let ordered = ordered(artifacts, for: preference)
        let selected: VisionProjectorArtifact?
        if preference.requiresExactMatch {
            selected = ordered.first(where: { matches($0, preference: preference) })
        } else {
            selected = ordered.first
        }
        let alternatives = ordered.filter { $0.id != selected?.id }
        return VisionProjectorDownloadPlan(
            preference: preference,
            selected: selected,
            alternatives: selected == nil ? ordered : alternatives
        )
    }
}

extension VisionProjectorDownloadPlan {
    static func resolve(
        artifacts: [VisionProjectorArtifact],
        preference: VisionProjectorDownloadPreference
    ) -> Self {
        VisionProjectorQuality.plan(artifacts: artifacts, preference: preference)
    }
}

extension String {
    /// Detects if a model name indicates it's a reasoning model
    var isReasoningModel: Bool {
        let lowercased = self.lowercased()
        let reasoningPatterns = [
            "o1-", "o1_",
            "deepseek-r1", "deepseek_r1",
            "qwq", "qwen-qwq", "qwen_qwq",
            "reasoning", "reasoner",
            "step-by-step", "stepbystep",
            "chain-of-thought", "chainofthought", "cot"
        ]
        
        return reasoningPatterns.contains { pattern in
            lowercased.contains(pattern)
        }
    }
}

extension LocalModel {
    /// Indicates if this is a reasoning model based on its name or ID
    var isReasoningModel: Bool {
        return name.isReasoningModel || modelID.isReasoningModel
    }
}

extension ModelRecord {
    /// Indicates if this is a reasoning model based on its name or ID
    var isReasoningModel: Bool {
        return displayName.isReasoningModel || id.isReasoningModel
    }
}

enum ModelVisionDetector {
    static func guessLlamaVisionModel(from url: URL) -> Bool {
        ProjectorLocator.hasProjectorFile(alongside: url)
    }
}

enum ProjectorLocator {
    private static let projectorKeywords = ["mmproj", "projector", "image_proj"]
    private static let projectorExtensions: Set<String> = ["gguf", "mmproj"]

    static func hasProjectorFile(alongside modelURL: URL) -> Bool {
        let directory = modelURL.deletingLastPathComponent()
        return hasProjectorFile(in: directory)
    }

    static func hasProjectorForModelID(_ modelID: String) -> Bool {
        let baseDir = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
        return hasProjectorFile(in: baseDir)
    }

    static func hasProjectorFile(in directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        if contents.contains(where: isProjectorFile(_:)) {
            return true
        }
        for entry in contents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let subcontents = try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil),
                   subcontents.contains(where: isProjectorFile(_:)) {
                    return true
                }
            }
        }
        return false
    }

    private static func isProjectorFile(_ url: URL) -> Bool {
        guard projectorExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let lowercased = url.lastPathComponent.lowercased()
        return projectorKeywords.contains { lowercased.contains($0) }
    }

    private static func projectorCandidates(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        var candidates = contents.filter { isProjectorFile($0) }

        // Also scan one level deep (some model repos nest projectors under a subfolder).
        for entry in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            if let subcontents = try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                candidates.append(contentsOf: subcontents.filter { isProjectorFile($0) })
            }
        }

        return candidates
    }

    /// Returns the absolute path to a projector `.gguf` if we can resolve one next to the model.
    /// Resolution order:
    /// 1) `artifacts.json` key "mmproj" (sibling file)
    /// 2) First `.gguf` file in the same directory matching common projector keywords,
    ///    preferring F16/F32 variants when multiple are present.
    static func projectorPath(alongside modelURL: URL) -> String? {
        let dir: URL = {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDir), isDir.boolValue {
                return modelURL
            }
            return modelURL.deletingLastPathComponent()
        }()

        // Try artifacts.json hint first
        let artifactsURL = dir.appendingPathComponent("artifacts.json")
        if let data = try? Data(contentsOf: artifactsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rel = obj["mmproj"] as? String {
            let abs = dir.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: abs.path) { return abs.path }
        }

        // Fallback: scan directory for projector-like gguf files
        let candidates = projectorCandidates(in: dir)
        if candidates.isEmpty { return nil }
        // Prefer F16/F32 names if available
        if let hi = candidates.first(where: { name in
            let s = name.lastPathComponent.uppercased()
            return s.contains("F16") || s.contains("F32")
        }) {
            return hi.path
        }
        return candidates.first?.path
    }
}

enum MtpLocator {
    private static let mtpKeywords = ["mtp", "nextn"]

    private struct CacheEntry {
        let directoryModificationTime: TimeInterval
        let result: Bool
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var hasMtpCache: [String: CacheEntry] = [:]

    static func hasMtpFile(alongside modelURL: URL) -> Bool {
        mtpPath(alongside: modelURL) != nil
    }

    /// Directory-scan-free while the containing directory is unchanged. A
    /// sidecar added or replaced during the session invalidates the cached miss.
    static func hasMtpFileCached(alongside modelURL: URL) -> Bool {
        let key = modelURL.path
        let stamp = directoryModificationTime(for: modelURL)
        cacheLock.lock()
        if let cached = hasMtpCache[key], cached.directoryModificationTime == stamp {
            cacheLock.unlock()
            return cached.result
        }
        cacheLock.unlock()
        let result = hasMtpFile(alongside: modelURL)
        cacheLock.lock()
        hasMtpCache[key] = CacheEntry(directoryModificationTime: stamp, result: result)
        cacheLock.unlock()
        return result
    }

    static func invalidateCache(alongside modelURL: URL? = nil) {
        cacheLock.lock()
        if let modelURL {
            hasMtpCache.removeValue(forKey: modelURL.path)
        } else {
            hasMtpCache.removeAll()
        }
        cacheLock.unlock()
    }

    static func mtpPath(alongside modelURL: URL) -> String? {
        let dir: URL = {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDir), isDir.boolValue {
                return modelURL
            }
            return modelURL.deletingLastPathComponent()
        }()

        let artifactsURL = dir.appendingPathComponent("artifacts.json")
        if let data = try? Data(contentsOf: artifactsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rel = obj["mtp"] as? String {
            let abs = dir.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
            let resolvedDirectory = dir.standardizedFileURL.resolvingSymlinksInPath()
            let directoryPath = resolvedDirectory.path.hasSuffix("/")
                ? resolvedDirectory.path
                : resolvedDirectory.path + "/"
            if !rel.hasPrefix("/"),
               abs.path.hasPrefix(directoryPath),
               abs.pathExtension.lowercased() == "gguf",
               abs != modelURL.standardizedFileURL.resolvingSymlinksInPath(),
               FileManager.default.fileExists(atPath: abs.path),
               case .sidecarValidated = GGUFMetadata.mtpCapability(targetURL: modelURL, sidecarURL: abs) {
                return abs.path
            }
        }

        let candidates = mtpCandidates(in: dir, excluding: modelURL)
        guard candidates.count > 1 else { return candidates.first?.path }

        let scored = candidates.map { ($0, associationScore($0, target: modelURL)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0,
              scored.filter({ $0.1 == best.1 }).count == 1 else {
            return nil
        }
        return best.0.path
    }

    private static func mtpCandidates(in directory: URL, excluding modelURL: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        var candidates = contents.filter { isMtpFile($0, for: modelURL) }
        for entry in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            if let subcontents = try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                candidates.append(contentsOf: subcontents.filter { isMtpFile($0, for: modelURL) })
            }
        }
        return candidates.sorted { lhs, rhs in
            mtpScore(lhs) == mtpScore(rhs)
                ? lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
                : mtpScore(lhs) > mtpScore(rhs)
        }
    }

    private static func isMtpFile(_ url: URL, for modelURL: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gguf" else { return false }
        guard url.standardizedFileURL.path != modelURL.standardizedFileURL.path else { return false }
        let lower = url.lastPathComponent.lowercased()
        guard !lower.contains("mmproj"), !lower.contains("projector"), !lower.contains("image_proj") else {
            return false
        }
        guard mtpKeywords.contains(where: { lower.contains($0) }) else { return false }
        if case .sidecarValidated = GGUFMetadata.mtpCapability(targetURL: modelURL, sidecarURL: url) {
            return true
        }
        return false
    }

    private static func mtpScore(_ url: URL) -> Int {
        let lower = url.lastPathComponent.lowercased()
        var score = 0
        if lower.contains("mtp-") || lower.contains("-mtp") { score += 30 }
        if lower.contains("nextn") { score += 20 }
        if lower.contains("f16") || lower.contains("f32") { score += 5 }
        return score
    }

    private static func associationScore(_ sidecar: URL, target: URL) -> Int {
        let ignored = Set([
            "gguf", "model", "weights", "mtp", "nextn", "f16", "f32",
            "q2", "q3", "q4", "q5", "q6", "q8", "k", "m", "s", "l", "iq"
        ])
        func tokens(_ url: URL) -> Set<String> {
            Set(url.deletingPathExtension().lastPathComponent.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init))
                .subtracting(ignored)
        }
        return tokens(sidecar).intersection(tokens(target)).count * 100 + mtpScore(sidecar)
    }

    private static func directoryModificationTime(for modelURL: URL) -> TimeInterval {
        var isDirectory: ObjCBool = false
        let directory = FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? modelURL
            : modelURL.deletingLastPathComponent()
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
    }
}
