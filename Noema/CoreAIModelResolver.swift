import Foundation
#if canImport(CoreAI)
import CoreAI
#endif

/// Locates the runnable artifacts inside a side-loaded Core AI model folder.
///
/// Core AI language models are exported (via Apple's `apple/coreai-models` tooling
/// on macOS / Xcode 27) as a resource folder containing one or more `.aimodel`
/// (or pre-compiled `.aimodelc`) bundles plus a tokenizer. This resolver finds
/// those pieces given any URL pointing at the folder or a nested file.
struct CoreAIResolvedModel: Sendable {
    /// The `.aimodel` / `.aimodelc` bundle to load with `AIModel(contentsOf:)`.
    let modelURL: URL
    /// The directory that holds the model bundle and its companions.
    let resourceRoot: URL
    /// Tokenizer file (`tokenizer.json`) if present alongside the model.
    let tokenizerURL: URL?
    /// Chunked-prefill companion bundle (`*_prefill_q16_*` etc.) sitting next to
    /// the decode bundle. Same state contract as the decode graph; consumes the
    /// prompt in fixed-size token blocks, then hands the states to the decode
    /// graph — the fast prefill path for static q=1 exports.
    let prefillModelURL: URL?
}

enum CoreAIModelResolverError: LocalizedError {
    case modelNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let url):
            return String(
                localized: "No .aimodel was found in \(url.lastPathComponent). Export and side-load a Core AI model folder."
            )
        }
    }
}

enum CoreAIModelResolver {
    private static let modelExtensions: Set<String> = ["aimodel", "aimodelc"]

    /// Resolves the model bundle + tokenizer from `modelURL`, which may be the
    /// `.aimodel` bundle itself, the enclosing resource folder, or a nested file.
    static func resolve(modelURL: URL) throws -> CoreAIResolvedModel {
        let fixed = modelURL.resolvingSymlinksInPath().standardizedFileURL

        // 1) The URL already points at (or inside) an `.aimodel` bundle.
        if let artifact = InstalledModelsStore.enclosingCoreAIArtifact(for: fixed) {
            let root = artifact.deletingLastPathComponent()
            return CoreAIResolvedModel(
                modelURL: artifact,
                resourceRoot: root,
                tokenizerURL: tokenizer(in: root),
                prefillModelURL: prefillCompanion(near: artifact)
            )
        }

        // 2) The URL is a folder: search it recursively. Install layouts mirror
        //    the repo paths, so bundles can sit several levels down — e.g.
        //    `gpu-pipelined/<variant>/<bundle>.aimodel/` is two levels deep.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fixed.path, isDirectory: &isDir), isDir.boolValue {
            if let artifact = preferredArtifact(under: fixed) {
                let root = artifact.deletingLastPathComponent()
                return CoreAIResolvedModel(
                    modelURL: artifact,
                    resourceRoot: root,
                    // Backfilled tokenizers may sit at the install root rather
                    // than next to a nested bundle — walk up to the search root.
                    tokenizerURL: tokenizer(in: root) ?? tokenizerInAncestors(of: root, upTo: fixed),
                    prefillModelURL: prefillCompanion(near: artifact)
                )
            }
        }

        throw CoreAIModelResolverError.modelNotFound(fixed)
    }

    private static func tokenizerInAncestors(of dir: URL, upTo limit: URL) -> URL? {
        let limitPath = limit.standardizedFileURL.path
        var current = dir.standardizedFileURL
        while current.path != limitPath, current.path.hasPrefix(limitPath) {
            current = current.deletingLastPathComponent()
            if let found = tokenizer(in: current) { return found }
        }
        return nil
    }

    /// Recursively collects every `.aimodel` / `.aimodelc` under `dir` (without
    /// descending into the bundles themselves), then prefers the bundle family
    /// that fits this device, avoids prefill-only companion graphs, and prefers
    /// a pre-compiled `.aimodelc` matching the current device architecture.
    private static func preferredArtifact(under dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var artifacts: [URL] = []
        for case let url as URL in enumerator {
            if modelExtensions.contains(url.pathExtension.lowercased()) {
                artifacts.append(url)
                enumerator.skipDescendants()
            }
        }
        return artifacts.sorted(by: artifactPrecedes).first
    }

    private static func artifactPrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        let l = artifactSortKey(lhs)
        let r = artifactSortKey(rhs)
        if l.prefillPenalty != r.prefillPenalty { return l.prefillPenalty < r.prefillPenalty }
        if l.familyRank != r.familyRank { return l.familyRank < r.familyRank }
        if l.compilationRank != r.compilationRank { return l.compilationRank < r.compilationRank }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private static func artifactSortKey(_ artifact: URL) -> (prefillPenalty: Int, familyRank: Int, compilationRank: Int) {
        let stem = artifact.deletingPathExtension().lastPathComponent.lowercased()
        return (
            prefillPenalty: stem.contains("prefill") ? 1 : 0,
            familyRank: bundleFamilyRank(for: artifact),
            compilationRank: compilationRank(for: artifact)
        )
    }

    private static func bundleFamilyRank(for artifact: URL) -> Int {
        // Mirrors CoreAIBundleFamily.sortRank: on iPhone the host-cache
        // ios-gpu bundles win for chat (chunked-prefill companion + cross-turn
        // state cache keep TTFT flat); on a Mac the pipelined engine's decode
        // speed dominates.
        let components = Set(artifact.pathComponents.map { $0.lowercased() })
        #if os(macOS)
        if components.contains("gpu-pipelined") { return 0 }
        if components.contains("macos") { return 1 }
        if components.contains("ios-ane") { return 2 }
        if components.contains("ios-gpu") { return 3 }
        #else
        if components.contains("ios-gpu") { return 0 }
        if components.contains("gpu-pipelined") { return 1 }
        if components.contains("ios-ane") { return 2 }
        if components.contains("macos") { return 3 }
        #endif
        return 9
    }

    private static func compilationRank(for artifact: URL) -> Int {
        guard artifact.pathExtension.lowercased() == "aimodelc" else { return 2 }
        let arch = CoreAIDeviceArchitecture.current
        if !arch.isEmpty,
           artifact.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(arch) {
            return 0
        }
        return 1
    }

    /// Chunked-prefill companion bundle in the same directory as the decode
    /// bundle (stem contains "prefill"). When both int8 and fp16 companions
    /// exist the int8 one wins: the fp16 prefill graph plus the decode monolith
    /// exceed the app memory budget on device.
    private static func prefillCompanion(near artifact: URL) -> URL? {
        let fm = FileManager.default
        let dir = artifact.deletingLastPathComponent()
        let artifactPath = artifact.standardizedFileURL.path
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let candidates = entries.filter { url in
            modelExtensions.contains(url.pathExtension.lowercased())
                && url.deletingPathExtension().lastPathComponent.lowercased().contains("prefill")
                && url.standardizedFileURL.path != artifactPath
        }
        return candidates.sorted { lhs, rhs in
            let l = lhs.lastPathComponent.lowercased().contains("int8") ? 0 : 1
            let r = rhs.lastPathComponent.lowercased().contains("int8") ? 0 : 1
            if l != r { return l < r }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }.first
    }

    private static func tokenizer(in dir: URL) -> URL? {
        let fm = FileManager.default
        // Exports may keep the tokenizer next to the bundle or in a `tokenizer/`
        // subfolder (the layout used by Hugging Face Core AI repos).
        for parent in [dir, dir.appendingPathComponent("tokenizer", isDirectory: true)] {
            for name in ["tokenizer.json", "tokenizer.model"] {
                let candidate = parent.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

/// Thin indirection so non-iOS-27 builds still compile.
enum CoreAIDeviceArchitecture {
    static var current: String {
        #if canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return AIModel.deviceArchitectureName
        }
        #endif
        return ""
    }
}
