import Foundation

struct ModelHubMeta: Codable {
    let id: String
    let author: String?
    let pipelineTag: String?
    let tags: [String]?
    let gguf: GGUFMeta?
    let projectorFiles: [ProjectorFile]?
    // When available, indicates vision capability inferred from Hub JSON (non‑GGUF paths, e.g. MLX)
    // This is computed by scanning pipeline_tag, config archetypes/model_type,
    // presence of processor/preprocessor artifacts in siblings, and chat template tokens.
    let mlxVisionCapable: Bool?

    struct GGUFMeta: Codable {
        let architecture: String?
        let context_length: Int?
        let chat_template: String?
        let quantize_imatrix_file: String?
    }

    struct ProjectorFile: Codable {
        let filename: String
        let size: Int64
    }
    
    var hasProjectorFile: Bool {
        guard let projectorFiles else { return false }
        return !projectorFiles.isEmpty
    }

    var isVision: Bool {
        // Consider either GGUF projector files or MLX/VLM hub signals
        hasProjectorFile || (mlxVisionCapable ?? false)
    }
}

private actor HFMetadataSingleFlight {
    static let shared = HFMetadataSingleFlight()
    private var inflight: [String: Task<ModelHubMeta?, Never>] = [:]
    
    func run(key: String, operation: @escaping @Sendable () async -> ModelHubMeta?) async -> ModelHubMeta? {
        if let existing = inflight[key] { return await existing.value }
        let task = Task { await operation() }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }
}

enum HuggingFaceMetadataCache {
    static func cacheDir(repoId: String) -> URL {
        var base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        base.appendPathComponent("ModelCards", isDirectory: true)
        for comp in repoId.split(separator: "/") {
            base.appendPathComponent(String(comp), isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private final class MemCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: (meta: ModelHubMeta?, mtime: TimeInterval)] = [:]
        func get(_ k: String, mtime: TimeInterval) -> ModelHubMeta?? {
            lock.lock(); defer { lock.unlock() }
            if let e = map[k], e.mtime == mtime { return .some(e.meta) }
            return nil
        }
        func set(_ k: String, _ v: ModelHubMeta?, mtime: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            map[k] = (v, mtime)
        }
    }
    private static let mem = MemCache()

    /// Read-only path to the cached hub.json — does NOT create the directory (unlike cacheDir).
    private static func hubJSONURL(repoId: String) -> URL {
        var base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        base.appendPathComponent("ModelCards", isDirectory: true)
        for comp in repoId.split(separator: "/") { base.appendPathComponent(String(comp), isDirectory: true) }
        return base.appendingPathComponent("hub.json")
    }

    static func cached(repoId: String) -> ModelHubMeta? {
        // In-memory cache keyed by repoId + file mtime. The Explore Text/Vision filter calls this
        // per record inside the view body; without this it did a createDirectory + Data(contentsOf:)
        // + JSONDecode on the main thread for every record on every render. Also caches the "no
        // hub.json" (nil) result so models without a card don't re-hit the disk each pass.
        let url = hubJSONURL(repoId: repoId)
        let mtime = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)?.timeIntervalSince1970 ?? -1
        if let hit = mem.get(repoId, mtime: mtime) { return hit }
        let result: ModelHubMeta? = {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ModelHubMeta.self, from: data)
        }()
        mem.set(repoId, result, mtime: mtime)
        return result
    }

    static func fetch(repoId: String, token: String?) async -> ModelHubMeta? {
        let escaped = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        guard let url = URL(string: "https://huggingface.co/api/models/\(escaped)?full=1") else { return nil }
        do {
            let (data, resp) = try await HFHubRequestManager.shared.data(for: url,
                                                                         token: token,
                                                                         accept: "application/json",
                                                                         timeout: 10)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let id = (raw?["id"] as? String) ?? repoId
            let author = raw?["author"] as? String
            let pipeline = (raw?["pipeline_tag"] as? String) ?? (raw?["cardData"] as? [String: Any])?["pipeline_tag"] as? String
            let tags = raw?["tags"] as? [String]
            var gguf: ModelHubMeta.GGUFMeta? = nil
            if let g = raw?["gguf"] as? [String: Any] {
                let arch = g["architecture"] as? String
                let ctx = g["context_length"] as? Int
                let tmpl = g["chat_template"] as? String
                let imatrix = g["quantize_imatrix_file"] as? String
                gguf = .init(architecture: arch, context_length: ctx, chat_template: tmpl, quantize_imatrix_file: imatrix)
            }
            // Parse siblings for both GGUF projector files and MLX processors
            var projectorFiles: [ModelHubMeta.ProjectorFile] = []
            var hasProcessor = false
            var hasVideoPreprocessor = false
            if let siblings = raw?["siblings"] as? [[String: Any]] {
                let projectorKeywords = ["mmproj", "projector", "image_proj"]
                for entry in siblings {
                    guard let rfilename = entry["rfilename"] as? String else { continue }
                    let lower = rfilename.lowercased()
                    // GGUF projector detection
                    if lower.hasSuffix(".gguf"), projectorKeywords.contains(where: { lower.contains($0) }) {
                        var size: Int64 = 0
                        if let lfs = entry["lfs"] as? [String: Any], let s = lfs["size"] as? Int {
                            size = Int64(s)
                        }
                        if size == 0, let s = entry["size"] as? Int { size = Int64(s) }
                        projectorFiles.append(.init(filename: rfilename, size: size))
                    }
                    // MLX/VLM processor artefacts
                    if lower == "preprocessor_config.json" || lower == "processor_config.json" { hasProcessor = true }
                    if lower == "video_preprocessor_config.json" { hasVideoPreprocessor = true }
                }
            }

            // Extract optional config for architectures/model_type and chat templates
            var configArchitectures: [String] = []
            var configModelType: String = ""
            var chatTemplates: [String] = []
            if let cfg = raw?["config"] as? [String: Any] {
                if let archs = cfg["architectures"] as? [String] { configArchitectures = archs }
                if let mt = cfg["model_type"] as? String { configModelType = mt }
                if let ct = cfg["chat_template"] as? String { chatTemplates.append(ct) }
                if let ctj = cfg["chat_template_jinja"] as? String { chatTemplates.append(ctj) }
            }
            if let card = raw?["cardData"] as? [String: Any] {
                if let ct = card["chat_template"] as? String { chatTemplates.append(ct) }
                if let ctj = card["chat_template_jinja"] as? String { chatTemplates.append(ctj) }
            }

            // Compute MLX/VLM vision capability from converging hub signals
            let pipelineLower = (pipeline ?? "").lowercased()
            let pipelineLooksVision = pipelineLower.contains("image-text-to-text") || pipelineLower.contains("image-to-text") || pipelineLower.contains("image") || pipelineLower.contains("video")
            let archLower = Set(configArchitectures.map { $0.lowercased() })
            let mtypeLower = configModelType.lowercased()
            let archLooksVLM = archLower.contains(where: { $0.contains("vl") || $0.contains("vision") || $0.contains("gemma3") || $0.contains("gemma3n") || $0.contains("qwen3") })
                || mtypeLower.contains("vl") || mtypeLower.contains("vision") || mtypeLower.contains("qwen3_vl") || mtypeLower.contains("gemma3")
            let templatesJoined = chatTemplates.joined(separator: "\n").lowercased()
            let templateHasVisionTokens = templatesJoined.contains("<|vision_start|>") || templatesJoined.contains("<image_soft_token>") || templatesJoined.contains("<image_pad>") || templatesJoined.contains("<video_pad>")
            // Tags as corroboration
            let lowerTags = Set((tags ?? []).map { $0.lowercased() })
            let tagHints = ["qwen3_vl", "image-text-to-text", "video-text-to-text", "vision-language", "vlm"]
            let tagsSuggestVision = lowerTags.contains(where: { tagHints.contains($0) })

            var mlxVisionCapable: Bool = false
            if pipelineLooksVision && (archLooksVLM || hasProcessor || templateHasVisionTokens) {
                mlxVisionCapable = true
            } else if hasProcessor || templateHasVisionTokens || hasVideoPreprocessor {
                mlxVisionCapable = true
            } else if pipelineLooksVision && tagsSuggestVision {
                // Supportive fallback when pipelines + tags strongly suggest vision
                mlxVisionCapable = true
            }

            return ModelHubMeta(id: id,
                                author: author,
                                pipelineTag: pipeline,
                                tags: tags,
                                gguf: gguf,
                                projectorFiles: projectorFiles,
                                mlxVisionCapable: mlxVisionCapable)
        } catch {
            return nil
        }
    }

    static func fetchAndCache(repoId: String, token: String?) async -> ModelHubMeta? {
        let key = repoId + "|" + (token ?? "")
        return await HFMetadataSingleFlight.shared.run(key: key) {
            guard let meta = await fetch(repoId: repoId, token: token) else { return nil }
            let dir = cacheDir(repoId: repoId)
            let jsonURL = dir.appendingPathComponent("hub.json")
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: jsonURL)
            }
            if let chat = meta.gguf?.chat_template, !chat.isEmpty {
                let tmplURL = dir.appendingPathComponent("chat_template.txt")
                try? chat.data(using: .utf8)?.write(to: tmplURL)
            }
            return meta
        }
    }

    static func saveToModelDir(meta: ModelHubMeta, modelID: String, format: ModelFormat) {
        let dir = InstalledModelsStore.baseDir(for: format, modelID: modelID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonURL = dir.appendingPathComponent("hub.json")
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: jsonURL)
        }
        if let chat = meta.gguf?.chat_template, !chat.isEmpty {
            let tmplURL = dir.appendingPathComponent("chat_template.txt")
            try? chat.data(using: .utf8)?.write(to: tmplURL)
        }
    }
}
