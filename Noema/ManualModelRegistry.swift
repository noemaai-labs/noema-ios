// ManualModelRegistry.swift
import Foundation

// Concurrency-safe cache for MLX repo details
private actor MlxRepoDetailsCache {
    private var cache: [String: ModelDetails] = [:]

    func get(_ key: String) -> ModelDetails? {
        return cache[key]
    }

    func set(_ key: String, _ value: ModelDetails) {
        cache[key] = value
    }
}

/// Registry providing manually curated model information from various sources.
public final class ManualModelRegistry: ModelRegistry, @unchecked Sendable {
    public struct Entry: Sendable {
        let record: ModelRecord
        let details: ModelDetails
    }

    private let entries: [Entry]

    public init(entries: [Entry] = ManualModelRegistry.defaultEntries) {
        self.entries = entries
    }

    public func curated() async throws -> [ModelRecord] {
        return entries.map { $0.record }
    }


    public func searchStream(query: String, page: Int, format: ModelFormat?, includeVisionModels: Bool, visionOnly: Bool) -> AsyncThrowingStream<ModelRecord, Error> {
        // Manual registry doesn't need vision models parameter, but we need to match the protocol
        return .init { continuation in
            continuation.finish()
        }
    }

    public func details(for id: String) async throws -> ModelDetails {
        guard let entry = entries.first(where: { $0.record.id == id }) else {
            throw URLError(.badURL)
        }

        var base = entry.details

        // Prefer pulling quants dynamically like Explore does, then merge curated extras
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")
        let hf = HuggingFaceRegistry(token: token)

        var quants: [QuantInfo]
        if let det = try? await hf.details(for: base.id) {
            quants = det.quants.filter { !shouldExcludeDynamicQuant($0, baseID: base.id) }
        } else {
            quants = base.quants
        }

        // Merge curated extras that point to other Hugging Face repos (e.g., MLX or GGUF mirrors)
        for extra in base.quants {
            guard let repo = huggingFaceRepoID(from: extra.downloadURL) else { continue }
            // Skip if already the same repo; dynamic quants above already covered it
            if repo == base.id { continue }

            if let det = try? await hf.details(for: repo) {
                let candidates = det.quants.filter { $0.format == extra.format }
                var picked: QuantInfo?
                switch extra.format {
                case .mlx:
                    if let bits = extractBitness(from: extra.label) {
                        picked = candidates.first(where: { QuantExtractor.shortLabel(from: $0.label, format: .mlx).lowercased() == "\(bits)bit" }) ?? candidates.first
                    } else {
                        picked = candidates.first
                    }
                case .gguf:
                    let target = QuantExtractor.shortLabel(from: extra.label, format: .gguf).lowercased()
                    picked = candidates.first(where: { QuantExtractor.shortLabel(from: $0.label, format: .gguf).lowercased() == target }) ?? candidates.first
                case .et, .ane, .afm:
                    picked = candidates.first
                case .coreai:
                    // Core AI repos publish one bundle per variant; the curated label
                    // names the intended one (e.g. "ios-gpu/ios_hc0_int8v3").
                    picked = candidates.first(where: { $0.label.caseInsensitiveCompare(extra.label) == .orderedSame }) ?? candidates.first
                }
                if let q = picked {
                    if !quants.contains(where: { $0.downloadURL == q.downloadURL }) {
                        quants.append(q)
                    }
                }
            } else {
                // Fallback: ensure ?download=1 and set config to the repo
                var comps = URLComponents(url: extra.downloadURL, resolvingAgainstBaseURL: false)!
                var q = comps.queryItems ?? []
                if !q.contains(where: { $0.name == "download" }) { q.append(URLQueryItem(name: "download", value: "1")) }
                comps.queryItems = q
                if let newURL = comps.url {
                    let cfg = URL(string: "https://huggingface.co/\(repo)/raw/main/config.json")
                    let candidate = QuantInfo(label: extra.label,
                                              format: extra.format,
                                              sizeBytes: extra.sizeBytes,
                                              downloadURL: newURL,
                                              sha256: extra.sha256,
                                              configURL: extra.configURL ?? cfg,
                                              downloadParts: extra.downloadParts)
                    if !quants.contains(where: { $0.downloadURL == candidate.downloadURL }) {
                        quants.append(candidate)
                    }
                }
            }
        }

        // De-duplicate by URL and short label per format to avoid duplicates from merges
        do {
            var unique: [QuantInfo] = []
            var seenURLs: Set<String> = []
            var seenKeys: Set<String> = []
            for q in quants {
                let urlKey = q.downloadURL.absoluteString
                let labelKey = QuantExtractor.shortLabel(from: q.label, format: q.format).lowercased()
                let key = "\(q.format.rawValue):\(labelKey)"
                if seenURLs.contains(urlKey) || seenKeys.contains(key) { continue }
                seenURLs.insert(urlKey)
                seenKeys.insert(key)
                unique.append(q)
            }
            quants = unique
        }

        for i in quants.indices {
            // Resolve MLX curated links only once per repo and only when opening the curated model
            if quants[i].format == .mlx, let host = quants[i].downloadURL.host, host.contains("huggingface.co"), let repo = huggingFaceRepoID(from: quants[i].downloadURL) {
                if let cached = await ManualModelRegistry.mlxRepoDetailsCache.get(repo) {
                    // Prefer MLX quant matching curated label bitness if possible
                    let mlxQuants = cached.quants.filter { $0.format == .mlx }
                    let picked: QuantInfo?
                    if let bits = extractBitness(from: quants[i].label) {
                        picked = mlxQuants.first(where: { QuantExtractor.shortLabel(from: $0.label, format: .mlx).lowercased() == "\(bits)bit" }) ?? mlxQuants.first
                    } else {
                        picked = mlxQuants.first
                    }
                    if let mlxQuant = picked {
                        quants[i] = quants[i].copying(
                            format: .mlx,
                            sizeBytes: mlxQuant.sizeBytes,
                            downloadURL: mlxQuant.downloadURL,
                            sha256: mlxQuant.sha256,
                            configURL: mlxQuant.configURL ?? URL(string: "https://huggingface.co/\(repo)/raw/main/config.json"),
                            downloadParts: mlxQuant.downloadParts
                        )
                    }
                } else {
                    // First time for this curated MLX repo: fetch details and cache
                    let token = UserDefaults.standard.string(forKey: "huggingFaceToken")
                    let hf = HuggingFaceRegistry(token: token)
                    if let det = try? await hf.details(for: repo) {
                        await ManualModelRegistry.mlxRepoDetailsCache.set(repo, det)
                        let mlxQuants = det.quants.filter { $0.format == .mlx }
                        let picked: QuantInfo?
                        if let bits = extractBitness(from: quants[i].label) {
                            picked = mlxQuants.first(where: { QuantExtractor.shortLabel(from: $0.label, format: .mlx).lowercased() == "\(bits)bit" }) ?? mlxQuants.first
                        } else {
                            picked = mlxQuants.first
                        }
                        if let mlxQuant = picked {
                            quants[i] = quants[i].copying(
                                format: .mlx,
                                sizeBytes: mlxQuant.sizeBytes,
                                downloadURL: mlxQuant.downloadURL,
                                sha256: mlxQuant.sha256,
                                configURL: mlxQuant.configURL ?? URL(string: "https://huggingface.co/\(repo)/raw/main/config.json"),
                                downloadParts: mlxQuant.downloadParts
                            )
                        }
                    } else {
                        // Fallback: add ?download=1 for size probing and set config to the repo
                        var comps = URLComponents(url: quants[i].downloadURL, resolvingAgainstBaseURL: false)!
                        var q = comps.queryItems ?? []
                        if !q.contains(where: { $0.name == "download" }) { q.append(URLQueryItem(name: "download", value: "1")) }
                        comps.queryItems = q
                        if let newURL = comps.url {
                            quants[i] = quants[i].copying(
                                downloadURL: newURL,
                                configURL: quants[i].configURL ?? URL(string: "https://huggingface.co/\(repo)/raw/main/config.json")
                            )
                        }
                    }
                }
            }

            if quants[i].sizeBytes == 0 {
                if let size = try? await fetchSize(quants[i].downloadURL) {
                    quants[i] = quants[i].copying(sizeBytes: size)
                }
            }
        }
        return ModelDetails(id: base.id,
                            summary: base.summary,
                            quants: quants,
                            promptTemplate: base.promptTemplate)

    }

    private func fetchSize(_ url: URL) async throws -> Int64 {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "download" }) {
            items.append(URLQueryItem(name: "download", value: "1"))
        }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "HEAD"
        if let token = UserDefaults.standard.string(forKey: "huggingFaceToken"), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
        NetworkKillSwitch.track(session: URLSession.shared)
        let (_, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
        guard let http = resp as? HTTPURLResponse else { return 0 }

        if let linked = http.value(forHTTPHeaderField: "X-Linked-Size"),
           let len = Int64(linked) { return len }
        if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
           let len = Int64(lenStr), len > 0 { return len }
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last,
           let len = Int64(total) { return len }
        return http.expectedContentLength > 0 ? http.expectedContentLength : 0
    }

    private func shouldExcludeDynamicQuant(_ quant: QuantInfo, baseID: String) -> Bool {
        guard baseID == "microsoft/phi-4-mini-reasoning" else { return false }
        guard quant.format == .mlx else { return false }
        let short = QuantExtractor.shortLabel(from: quant.label, format: .mlx).lowercased()
        guard short == "mlx" else { return false }
        return huggingFaceRepoID(from: quant.downloadURL) == baseID
    }

    private func huggingFaceRepoID(from url: URL) -> String? {
        guard let host = url.host, host.contains("huggingface.co") else { return nil }
        var parts = url.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        let prefixes: Set<String> = ["repos", "api", "models"]
        while parts.count > 2, let first = parts.first, prefixes.contains(first) {
            parts.removeFirst()
        }
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1]
        guard !owner.isEmpty && !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }

    private func extractBitness(from label: String) -> Int? {
        if let r = label.range(of: #"(\d{1,2})(?:\s*bit)?"#, options: .regularExpression) {
            let digits = label[r].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            return Int(digits)
        }
        return nil
    }

    private static let mlxRepoDetailsCache = MlxRepoDetailsCache()
    
    // Rough heuristic: working set ≈ 1.5x quant file size + 512MB overhead.
    // Stored privately to gate installs on low-RAM devices without surfacing in UI.
    private static func requiredRAMBytes(from sizeBytes: Int64) -> Int64 {
        let overhead: Int64 = 512 * 1024 * 1024
        let scaled = Int64(Double(sizeBytes) * 1.5)
        return max(sizeBytes, scaled + overhead)
    }

    private static func bytesFromMB(_ mb: Double) -> Int64 {
        Int64(mb * 1_048_576.0)
    }

    private static func bytesFromGB(_ gb: Double) -> Int64 {
        Int64(gb * 1_073_741_824.0)
    }

    static func recommendedStarterQuant(in details: ModelDetails) -> QuantInfo? {
        if details.id.caseInsensitiveCompare("unsloth/Qwen3.5-2B-GGUF") == .orderedSame,
           let q3 = details.quants.first(where: {
               $0.format == .gguf &&
               QuantExtractor.shortLabel(from: $0.label, format: $0.format).caseInsensitiveCompare("Q3_K_M") == .orderedSame
           }) {
            return q3
        }

        let preferredPool = details.quants.filter { $0.format == .gguf && $0.isHighBitQuant }
        let fallbackPool = preferredPool.isEmpty ? details.quants.filter { $0.isHighBitQuant } : preferredPool
        let candidates = fallbackPool.isEmpty ? details.quants : fallbackPool
        return candidates.min { starterQuantSortKey(for: $0) < starterQuantSortKey(for: $1) }
    }

    private static func starterQuantSortKey(for quant: QuantInfo) -> (Int, Int, Int, Int64, String) {
        let formatRank = quant.format == .gguf ? 0 : 1
        let bits = quant.inferredBitWidth ?? 99
        let bitDistance = abs(bits - 4)
        let label = QuantExtractor.shortLabel(from: quant.label, format: quant.format).uppercased()
        let variantRank: Int = {
            guard quant.format == .gguf else { return 0 }
            if label.contains("_K_M") { return 0 }
            if label.contains("_K_S") { return 1 }
            if label.contains("_K_L") { return 2 }
            return 9
        }()
        let sizeRank = quant.sizeBytes > 0 ? quant.sizeBytes : Int64.max / 4
        return (formatRank, bitDistance, variantRank, sizeRank, label)
    }

    public static var defaultEntries: [Entry] {
        let locale = LocalizationManager.preferredLocale()
        let qwenSummary = String(localized: "Qwen 3.5 is a new multimodal model family from Qwen designed for text, images, video, reasoning, coding, and agent-style tool use, with support for both thinking and non-thinking modes. The 2B variant shown here is a compact version intended especially for prototyping, local use, fine-tuning, and efficient deployment, while still offering a very large native context window and strong multilingual coverage.", locale: locale)
        let bonsaiSummary = String(localized: "Bonsai-8B-GGUF is a 1-bit, GGUF-packaged 8B language model built on a Qwen3-8B dense architecture and designed for efficient local inference with llama.cpp across CUDA, Metal, CPU, and mobile environments.", locale: locale)
        let gemmaSummary = String(localized: "Gemma 3 4B is a lightweight multimodal model developed by Google that accepts both text and images as input and generates text responses. Despite its relatively small size, it supports a 128K token context window, multilingual capability across more than 140 languages, and is designed to run efficiently on local hardware such as laptops and desktops.", locale: locale)
        let lfmSummary = String(localized: "LFM2.5-1.2B-Thinking is a compact reasoning-focused language model from Liquid AI designed for efficient on-device inference, built on the LFM2 architecture with additional pre-training and reinforcement learning. The release is optimized for local runtimes, allowing the roughly 1.2-billion-parameter model to run on consumer hardware while retaining strong reasoning and conversational capabilities.", locale: locale)
        let graniteSummary = String(localized: "Granite-4.0-H-Tiny is a 7-billion-parameter long-context instruction-tuned language model developed by IBM as part of the Granite 4.0 family. It is designed for enterprise-oriented applications such as conversational assistants, retrieval-augmented generation, coding tasks, and tool-calling workflows, while supporting multilingual interaction and contexts up to 128K tokens.", locale: locale)
        let gemma4Summary = String(localized: "Gemma 4 is a family of open multimodal models from Google DeepMind designed for strong reasoning, coding, and long-context tasks, with support for text and image input across the lineup and audio on the smaller variants. It comes in several sizes and architectures, including efficient dense models and a Mixture-of-Experts option, making it suitable for everything from on-device use on laptops and phones to more demanding workstation deployments.", locale: locale)
        let qwen3Summary = String(localized: "Qwen3-1.7B is a compact language model in Alibaba's Qwen3 family, designed to balance strong reasoning, instruction following, and multilingual performance within a lightweight 1.7 billion parameter size. It supports both deliberate reasoning for harder tasks and faster general conversation, making it a versatile small model for local use, research, and everyday AI applications.", locale: locale)
        return [
            Entry(
                record: ModelRecord(
                    id: "unsloth/Qwen3.5-2B-GGUF",
                    displayName: "Qwen 3.5 2B",
                    publisher: "Qwen",
                    summary: qwenSummary,
                    hasInstallableQuant: true,
                    formats: [.gguf, .mlx, .coreai],
                    installed: false,
                    tags: ["gguf", "mlx", "coreai", "qwen3.5", "multimodal", "vision", "reasoning", "tool-use"],
                    pipeline_tag: "image-text-to-text",
                    minRAMBytes: nil,
                    recommendedETBackend: nil,
                    supportsVision: true
                ),
                details: ModelDetails(
                    id: "unsloth/Qwen3.5-2B-GGUF",
                    summary: qwenSummary,
                    quants: [
                        QuantInfo(
                            label: "Q3_K_M",
                            format: .gguf,
                            sizeBytes: 1_107_149_056,
                            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q3_K_M.gguf?download=1")!,
                            sha256: nil,
                            configURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/raw/main/config.json")
                        ),
                        QuantInfo(
                            label: "INT4",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlx-community/Qwen3.5-2B-4bit")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "INT6",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlx-community/Qwen3.5-2B-6bit")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "ios-gpu/ios_hc0_int8v3",
                            format: .coreai,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlboydaisuke/qwen3.5-2B-CoreAI")!,
                            sha256: nil,
                            configURL: nil
                        )
                    ],
                    promptTemplate: nil,
                    minRAMBytes: nil
                )
            ),

            Entry(
                record: ModelRecord(
                    id: "prism-ml/Bonsai-8B-gguf",
                    displayName: "Bonsai 8b",
                    publisher: "Prism ML",
                    summary: bonsaiSummary,
                    parameterCountLabel: "8B",
                    hasInstallableQuant: true,
                    formats: [.gguf, .mlx],
                    installed: false,
                    tags: ["gguf", "mlx", "bonsai", "qwen3", "1-bit", "llama.cpp", "cuda", "metal", "cpu", "mobile"],
                    pipeline_tag: nil,
                    minRAMBytes: nil,
                    recommendedETBackend: nil,
                    supportsVision: false
                ),
                details: ModelDetails(
                    id: "prism-ml/Bonsai-8B-gguf",
                    summary: bonsaiSummary,
                    parameterCountLabel: "8B",
                    quants: [
                        QuantInfo(
                            label: "GGUF",
                            format: .gguf,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/prism-ml/Bonsai-8B-gguf")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "1-bit",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/prism-ml/Bonsai-8B-mlx-1bit")!,
                            sha256: nil,
                            configURL: nil
                        )
                    ],
                    promptTemplate: nil,
                    minRAMBytes: nil
                )
            ),

            Entry(
                record: ModelRecord(
                    id: "unsloth/gemma-3-4b-it-GGUF",
                    displayName: "Gemma 3 4B",
                    publisher: "Google",
                    summary: gemmaSummary,
                    hasInstallableQuant: true,
                    formats: [.gguf, .mlx, .et, .ane],
                    installed: false,
                    tags: ["gguf", "mlx", "et", "cml", "gemma", "gemma3", "multimodal", "vision"],
                    pipeline_tag: "image-text-to-text",
                    minRAMBytes: nil,
                    recommendedETBackend: nil,
                    supportsVision: true
                ),
                details: ModelDetails(
                    id: "unsloth/gemma-3-4b-it-GGUF",
                    summary: gemmaSummary,
                    quants: [
                        QuantInfo(
                            label: "GGUF",
                            format: .gguf,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF")!,
                            sha256: nil,
                            configURL: URL(string: "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/raw/main/config.json")
                        ),
                        QuantInfo(
                            label: "INT4",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-3-4b-it-4bit")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "INT8",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-3-4b-it-8bit")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "CML",
                            format: .ane,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/anemll/anemll-google-gemma-3-4b-it-qat-int4-ctx4096_0.3.5")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "ET",
                            format: .et,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/pytorch/gemma-3-4b-it-HQQ-INT8-INT4")!,
                            sha256: nil,
                            configURL: nil
                        )
                    ],
                    promptTemplate: nil,
                    minRAMBytes: nil
                )
            ),

            Entry(
                record: ModelRecord(
                    id: "LiquidAI/LFM2.5-1.2B-Thinking-GGUF",
                    displayName: "LFM 2.5 1.2B Thinking",
                    publisher: "Liquid AI",
                    summary: lfmSummary,
                    hasInstallableQuant: true,
                    formats: [.gguf, .mlx],
                    installed: false,
                    tags: ["gguf", "mlx", "lfm2.5", "thinking", "reasoning", "liquid-ai"],
                    pipeline_tag: nil,
                    minRAMBytes: nil,
                    recommendedETBackend: nil,
                    supportsVision: false
                ),
                details: ModelDetails(
                    id: "LiquidAI/LFM2.5-1.2B-Thinking-GGUF",
                    summary: lfmSummary,
                    quants: [
                        QuantInfo(
                            label: "GGUF",
                            format: .gguf,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Thinking-GGUF")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "INT4",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Thinking-MLX-4bit")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "INT8",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Thinking-MLX-8bit")!,
                            sha256: nil,
                            configURL: nil
                        )
                    ],
                    promptTemplate: nil,
                    minRAMBytes: nil
                )
            ),

            Entry(
                record: ModelRecord(
                    id: "ibm-granite/granite-4.0-h-tiny-GGUF",
                    displayName: "Granite 4.0 H Tiny",
                    publisher: "IBM",
                    summary: graniteSummary,
                    hasInstallableQuant: true,
                    formats: [.gguf, .mlx],
                    installed: false,
                    tags: ["gguf", "mlx", "granite", "granite4", "enterprise", "tool-use", "coding"],
                    pipeline_tag: nil,
                    minRAMBytes: nil,
                    recommendedETBackend: nil,
                    supportsVision: false
                ),
                details: ModelDetails(
                    id: "ibm-granite/granite-4.0-h-tiny-GGUF",
                    summary: graniteSummary,
                    quants: [
                        QuantInfo(
                            label: "GGUF",
                            format: .gguf,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/ibm-granite/granite-4.0-h-tiny-GGUF")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "INT4",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlx-community/granite-4.0-h-tiny-4bit")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "INT8",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlx-community/granite-4.0-h-tiny-8bit")!,
                            sha256: nil,
                            configURL: nil
                        )
                    ],
                    promptTemplate: nil,
                    minRAMBytes: nil
                )
            ),

            Entry(
                record: ModelRecord(
                    id: "unsloth/gemma-4-E2B-it-GGUF",
                    displayName: "Gemma 4 E2B it",
                    publisher: "Google",
                    summary: gemma4Summary,
                    hasInstallableQuant: true,
                    formats: [.gguf, .mlx],
                    installed: false,
                    tags: ["gguf", "mlx", "gemma", "gemma4", "multimodal", "vision"],
                    pipeline_tag: "image-text-to-text",
                    minRAMBytes: nil,
                    recommendedETBackend: nil,
                    supportsVision: true
                ),
                details: ModelDetails(
                    id: "unsloth/gemma-4-E2B-it-GGUF",
                    summary: gemma4Summary,
                    quants: [
                        QuantInfo(
                            label: "GGUF",
                            format: .gguf,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "INT4",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-UD-MLX-4bit")!,
                            sha256: nil,
                            configURL: nil
                        )
                    ],
                    promptTemplate: nil,
                    minRAMBytes: nil
                )
            ),

            Entry(
                record: ModelRecord(
                    id: "Qwen/Qwen3-1.7B-GGUF",
                    displayName: "Qwen 3 1.7B",
                    publisher: "Qwen",
                    summary: qwen3Summary,
                    hasInstallableQuant: true,
                    formats: [.gguf, .mlx, .et, .ane],
                    installed: false,
                    tags: ["gguf", "mlx", "et", "cml", "qwen", "qwen3"],
                    pipeline_tag: nil,
                    minRAMBytes: nil,
                    recommendedETBackend: nil,
                    supportsVision: false
                ),
                details: ModelDetails(
                    id: "Qwen/Qwen3-1.7B-GGUF",
                    summary: qwen3Summary,
                    quants: [
                        QuantInfo(
                            label: "GGUF",
                            format: .gguf,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "INT4",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "INT8",
                            format: .mlx,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-1.7B-8bit")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "CML",
                            format: .ane,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/anemll/anemll-Qwen-Qwen3-1.7B-ctx2048_0.3.5")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "ET",
                            format: .et,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/larryliu0820/Qwen3-1.7B-INT8-INT4-ExecuTorch-XNNPACK")!,
                            sha256: nil,
                            configURL: nil
                        )
                    ],
                    promptTemplate: nil,
                    minRAMBytes: nil
                )
            )
        ]
    }
}
