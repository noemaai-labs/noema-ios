import Foundation

enum VisionModelDetector {
    static func isVisionModel(repoId: String, token: String?) async -> Bool {
        if let cached = cachedMeta(repoId: repoId) {
            if cached.isVision { return true }
        }
        let resolvedToken = normalizedToken(token)
        guard let meta = await HuggingFaceMetadataCache.fetchAndCache(repoId: repoId, token: resolvedToken) else {
            return false
        }
        return meta.isVision
    }

    static func isVisionModelCachedOrHeuristic(repoId: String) -> Bool {
        guard let cached = cachedMeta(repoId: repoId) else { return false }
        return cached.isVision
    }

    static func projectorMetadata(repoId: String, token: String?) async -> ModelHubMeta.ProjectorFile? {
        (await projectorFiles(repoId: repoId, token: token)).first
    }

    static func projectorFiles(repoId: String, token: String?) async -> [ModelHubMeta.ProjectorFile] {
        if let cached = cachedMeta(repoId: repoId),
           let files = cached.projectorFiles {
            return files
        }
        let resolvedToken = normalizedToken(token)
        let meta = await HuggingFaceMetadataCache.fetchAndCache(repoId: repoId, token: resolvedToken)
        return meta?.projectorFiles ?? []
    }

    static func projectorDownloadPlan(
        repoIDs: [String],
        token: String?,
        preference: VisionProjectorDownloadPreference
    ) async -> VisionProjectorDownloadPlan {
        var artifacts: [VisionProjectorArtifact] = []
        var seen: Set<String> = []
        for (priority, repoID) in repoIDs.enumerated() {
            let files = await projectorFiles(repoId: repoID, token: token)
            for file in files {
                let identity = "\(repoID)/\(file.filename)"
                guard seen.insert(identity).inserted else { continue }
                artifacts.append(VisionProjectorArtifact(
                    repositoryID: repoID,
                    filename: file.filename,
                    size: file.size,
                    repositoryPriority: priority
                ))
            }
        }
        return .resolve(artifacts: artifacts, preference: preference)
    }

    static func repositoryCandidates(modelID: String, downloadURL: URL) -> [String] {
        var candidates: [String] = []
        if let repositoryID = huggingFaceRepositoryID(from: downloadURL) {
            candidates.append(repositoryID)
        }
        if !candidates.contains(modelID) {
            candidates.append(modelID)
        }
        return candidates
    }

    private static func cachedMeta(repoId: String) -> ModelHubMeta? {
        HuggingFaceMetadataCache.cached(repoId: repoId)
    }

    private static func normalizedToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func huggingFaceRepositoryID(from url: URL) -> String? {
        guard let host = url.host,
              host.contains("huggingface.co") || host.contains("hf-mirror.com") else { return nil }
        var parts = url.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        let prefixes: Set<String> = ["repos", "api", "models"]
        while parts.count > 2, let first = parts.first, prefixes.contains(first) {
            parts.removeFirst()
        }
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
