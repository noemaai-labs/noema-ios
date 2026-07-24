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
                case .et:
                    let target = extra.label.lowercased()
                    picked = candidates.first(where: { $0.label.lowercased() == target })
                        ?? candidates.first(where: { $0.label.localizedCaseInsensitiveContains("xnnpack") })
                        ?? candidates.first
                case .ane, .afm:
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
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "download" }) {
            items.append(URLQueryItem(name: "download", value: "1"))
        }
        comps.queryItems = items

        guard let requestURL = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: requestURL)
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

        if details.id.caseInsensitiveCompare("prism-ml/Ternary-Bonsai-27B-gguf") == .orderedSame,
           let q2 = details.quants.first(where: {
               $0.format == .gguf &&
               QuantExtractor.shortLabel(from: $0.label, format: $0.format).caseInsensitiveCompare("Q2_0") == .orderedSame
           }) {
            return q2
        }

        if details.id.caseInsensitiveCompare("prism-ml/Bonsai-27B-gguf") == .orderedSame,
           let q1 = details.quants.first(where: {
               $0.format == .gguf &&
               QuantExtractor.shortLabel(from: $0.label, format: $0.format).caseInsensitiveCompare("Q1_0") == .orderedSame
           }) {
            return q1
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

    private struct CuratedSource {
        let format: ModelFormat
        let label: String
        let repoID: String
        let starterSizeBytes: Int64?
    }

    private static func curatedSource(
        _ format: ModelFormat,
        _ repoID: String,
        label: String,
        starterSizeBytes: Int64? = nil
    ) -> CuratedSource {
        CuratedSource(
            format: format,
            label: label,
            repoID: repoID,
            starterSizeBytes: starterSizeBytes
        )
    }

    private static func curatedEntry(
        id: String,
        displayName: String,
        publisher: String,
        parameterCountLabel: String,
        starterSizeBytes: Int64,
        supportsVision: Bool = false,
        tags: [String] = [],
        sources: [CuratedSource]
    ) -> Entry {
        let minimumRAM = requiredRAMBytes(from: starterSizeBytes)
        let formats = Set(sources.map(\.format))
        var minimumRAMByFormat: [ModelFormat: Int64] = [:]
        for source in sources {
            let sourceSize = source.starterSizeBytes ?? starterSizeBytes
            let sourceMinimumRAM = requiredRAMBytes(from: sourceSize)
            minimumRAMByFormat[source.format] = min(
                minimumRAMByFormat[source.format] ?? Int64.max,
                sourceMinimumRAM
            )
        }

        let formatTags = formats.map { format -> String in
            switch format {
            case .ane: return "cml"
            case .coreai: return "coreai"
            default: return format.rawValue.lowercased()
            }
        }
        let allTags = Array(Set(tags + formatTags)).sorted()
        let pipelineTag = supportsVision ? "image-text-to-text" : "text-generation"
        let quants = sources.map { source in
            QuantInfo(
                label: source.label,
                format: source.format,
                sizeBytes: source.starterSizeBytes ?? 0,
                downloadURL: URL(string: "https://huggingface.co/\(source.repoID)")!,
                sha256: nil,
                configURL: nil
            )
        }

        return Entry(
            record: ModelRecord(
                id: id,
                displayName: displayName,
                publisher: publisher,
                summary: nil,
                parameterCountLabel: parameterCountLabel,
                hasInstallableQuant: true,
                formats: formats,
                installed: false,
                tags: allTags,
                pipeline_tag: pipelineTag,
                minRAMBytes: minimumRAM,
                minRAMBytesByFormat: minimumRAMByFormat,
                recommendedETBackend: formats.contains(.et) ? .xnnpack : nil,
                supportsVision: supportsVision
            ),
            details: ModelDetails(
                id: id,
                summary: nil,
                parameterCountLabel: parameterCountLabel,
                quants: quants,
                promptTemplate: nil,
                minRAMBytes: minimumRAM
            )
        )
    }

    /// Verified against the Hugging Face Hub on 2026-07-14. Keep this list in
    /// ascending device tier so phones, iPads, and increasingly large-memory Macs
    /// all receive useful options when the fit-first shelf is applied.
    private static var additionalCuratedEntries: [Entry] {
        [
            curatedEntry(
                id: "LiquidAI/LFM2.5-230M-GGUF",
                displayName: "LFM 2.5 230M",
                publisher: "Liquid AI",
                parameterCountLabel: "230M",
                starterSizeBytes: 149_080_928,
                tags: ["lfm2.5", "on-device", "small"],
                sources: [
                    curatedSource(.gguf, "LiquidAI/LFM2.5-230M-GGUF", label: "GGUF", starterSizeBytes: 149_080_928),
                    curatedSource(.mlx, "LiquidAI/LFM2.5-230M-MLX-4bit", label: "INT4", starterSizeBytes: 180_000_000),
                    curatedSource(.ane, "code-and-canvas/lfm2.5-230m-coreML-fp16", label: "CML", starterSizeBytes: 602_577_778)
                ]
            ),
            curatedEntry(
                id: "unsloth/Qwen3.5-0.8B-GGUF",
                displayName: "Qwen 3.5 0.8B",
                publisher: "Qwen",
                parameterCountLabel: "0.8B",
                starterSizeBytes: 507_154_688,
                supportsVision: true,
                tags: ["qwen3.5", "reasoning", "tool-use", "vision"],
                sources: [
                    curatedSource(.gguf, "unsloth/Qwen3.5-0.8B-GGUF", label: "GGUF", starterSizeBytes: 507_154_688),
                    curatedSource(.mlx, "mlx-community/Qwen3.5-0.8B-MLX-4bit", label: "INT4", starterSizeBytes: 650_000_000),
                    curatedSource(.et, "prismindanalytics/Qwen3.5-0.8B-ExecuTorch", label: "ET", starterSizeBytes: 1_448_222_848),
                    curatedSource(.ane, "mlboydaisuke/qwen3.5-0.8B-CoreML", label: "CML", starterSizeBytes: 8_048_235_426),
                    curatedSource(.coreai, "mlboydaisuke/qwen3.5-0.8B-CoreAI", label: "gpu-pipelined/decode_int8", starterSizeBytes: 1_200_000_000)
                ]
            ),
            curatedEntry(
                id: "ibm-granite/granite-4.0-1b-GGUF",
                displayName: "Granite 4.0 1B",
                publisher: "IBM",
                parameterCountLabel: "1B",
                starterSizeBytes: 974_984_960,
                tags: ["granite4", "enterprise", "tool-use"],
                sources: [
                    curatedSource(.gguf, "ibm-granite/granite-4.0-1b-GGUF", label: "GGUF", starterSizeBytes: 974_984_960),
                    curatedSource(.mlx, "mlx-community/granite-4.0-1b-4bit", label: "INT4", starterSizeBytes: 760_000_000)
                ]
            ),
            curatedEntry(
                id: "LiquidAI/LFM2.5-1.2B-Instruct-GGUF",
                displayName: "LFM 2.5 1.2B Instruct",
                publisher: "Liquid AI",
                parameterCountLabel: "1.2B",
                starterSizeBytes: 695_751_488,
                tags: ["lfm2.5", "instruct", "on-device"],
                sources: [
                    curatedSource(.gguf, "LiquidAI/LFM2.5-1.2B-Instruct-GGUF", label: "GGUF", starterSizeBytes: 695_751_488),
                    curatedSource(.mlx, "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit", label: "INT4", starterSizeBytes: 750_000_000),
                    curatedSource(.et, "software-mansion/react-native-executorch-lfm2.5-1.2B-instruct", label: "ET", starterSizeBytes: 1_030_000_000),
                    curatedSource(.ane, "alan13367/LFM2.5-1.2B-Instruct-CoreML", label: "CML", starterSizeBytes: 580_371_709)
                ]
            ),
            curatedEntry(
                id: "LiquidAI/LFM2.5-VL-1.6B-GGUF",
                displayName: "LFM 2.5 VL 1.6B",
                publisher: "Liquid AI",
                parameterCountLabel: "1.6B",
                starterSizeBytes: 1_000_000_000,
                supportsVision: true,
                tags: ["lfm2.5", "multimodal", "vision"],
                sources: [
                    curatedSource(.gguf, "LiquidAI/LFM2.5-VL-1.6B-GGUF", label: "GGUF", starterSizeBytes: 1_000_000_000),
                    curatedSource(.mlx, "mlx-community/LFM2.5-VL-1.6B-4bit", label: "INT4", starterSizeBytes: 1_100_000_000),
                    curatedSource(.et, "software-mansion/react-native-executorch-lfm2.5-VL-1.6B", label: "ET-XNNPACK", starterSizeBytes: 2_080_000_000),
                    curatedSource(.ane, "mweinbach/LFM2.5-VL-1.6B-CoreML", label: "CML", starterSizeBytes: 5_534_674_947)
                ]
            ),
            curatedEntry(
                id: "ggml-org/SmolLM3-3B-GGUF",
                displayName: "SmolLM3 3B",
                publisher: "Hugging Face",
                parameterCountLabel: "3B",
                starterSizeBytes: 1_915_305_312,
                tags: ["smollm3", "reasoning", "long-context"],
                sources: [
                    curatedSource(.gguf, "ggml-org/SmolLM3-3B-GGUF", label: "GGUF", starterSizeBytes: 1_915_305_312),
                    curatedSource(.mlx, "mlx-community/SmolLM3-3B-4bit", label: "INT4", starterSizeBytes: 1_850_000_000)
                ]
            ),
            curatedEntry(
                id: "ibm-granite/granite-4.0-h-micro-GGUF",
                displayName: "Granite 4.0 H Micro",
                publisher: "IBM",
                parameterCountLabel: "3B",
                starterSizeBytes: 1_855_516_320,
                tags: ["granite4", "hybrid", "enterprise", "tool-use"],
                sources: [
                    curatedSource(.gguf, "ibm-granite/granite-4.0-h-micro-GGUF", label: "GGUF", starterSizeBytes: 1_855_516_320),
                    curatedSource(.mlx, "mlx-community/granite-4.0-h-micro-4bit", label: "INT4", starterSizeBytes: 1_900_000_000)
                ]
            ),
            curatedEntry(
                id: "lmstudio-community/Phi-4-mini-instruct-GGUF",
                displayName: "Phi-4 Mini Instruct",
                publisher: "Microsoft",
                parameterCountLabel: "3.8B",
                starterSizeBytes: 2_491_874_400,
                tags: ["phi4", "instruct", "tool-use"],
                sources: [
                    curatedSource(.gguf, "lmstudio-community/Phi-4-mini-instruct-GGUF", label: "GGUF", starterSizeBytes: 2_491_874_400),
                    curatedSource(.mlx, "mlx-community/Phi-4-mini-instruct-4bit", label: "INT4", starterSizeBytes: 2_100_000_000),
                    curatedSource(.et, "pytorch/Phi-4-mini-instruct-INT8-INT4", label: "ET", starterSizeBytes: 2_776_887_680)
                ]
            ),
            curatedEntry(
                id: "lmstudio-community/Phi-4-mini-reasoning-GGUF",
                displayName: "Phi-4 Mini Reasoning",
                publisher: "Microsoft",
                parameterCountLabel: "3.8B",
                starterSizeBytes: 2_491_874_560,
                tags: ["phi4", "reasoning", "math"],
                sources: [
                    curatedSource(.gguf, "lmstudio-community/Phi-4-mini-reasoning-GGUF", label: "GGUF", starterSizeBytes: 2_491_874_560),
                    curatedSource(.mlx, "lmstudio-community/Phi-4-mini-reasoning-MLX-4bit", label: "INT4", starterSizeBytes: 2_100_000_000)
                ]
            ),
            curatedEntry(
                id: "unsloth/Qwen3.5-4B-GGUF",
                displayName: "Qwen 3.5 4B",
                publisher: "Qwen",
                parameterCountLabel: "4B",
                starterSizeBytes: 2_583_221_408,
                supportsVision: true,
                tags: ["qwen3.5", "reasoning", "tool-use", "vision"],
                sources: [
                    curatedSource(.gguf, "unsloth/Qwen3.5-4B-GGUF", label: "GGUF", starterSizeBytes: 2_583_221_408),
                    curatedSource(.mlx, "mlx-community/Qwen3.5-4B-MLX-4bit", label: "INT4", starterSizeBytes: 2_650_000_000)
                ]
            ),
            curatedEntry(
                id: "mistralai/Ministral-3-3B-Instruct-2512-GGUF",
                displayName: "Ministral 3 3B Instruct",
                publisher: "Mistral AI",
                parameterCountLabel: "3B",
                starterSizeBytes: 2_147_023_008,
                supportsVision: true,
                tags: ["ministral3", "instruct", "multimodal", "vision"],
                sources: [
                    curatedSource(.gguf, "mistralai/Ministral-3-3B-Instruct-2512-GGUF", label: "GGUF", starterSizeBytes: 2_147_023_008),
                    curatedSource(.mlx, "mlx-community/Ministral-3-3B-Instruct-2512-4bit", label: "INT4", starterSizeBytes: 2_200_000_000)
                ]
            ),
            curatedEntry(
                id: "prism-ml/Bonsai-27B-gguf",
                displayName: "Bonsai 27B (1-bit)",
                publisher: "Prism ML",
                parameterCountLabel: "27B",
                starterSizeBytes: 3_803_452_480,
                supportsVision: true,
                tags: ["bonsai", "qwen3.6", "1-bit", "reasoning", "tool-use", "vision"],
                sources: [
                    curatedSource(.gguf, "prism-ml/Bonsai-27B-gguf", label: "Q1_0", starterSizeBytes: 3_803_452_480),
                    curatedSource(.mlx, "prism-ml/Bonsai-27B-mlx-1bit", label: "1-bit", starterSizeBytes: 5_129_115_752)
                ]
            ),
            curatedEntry(
                id: "lmstudio-community/gemma-4-E4B-it-GGUF",
                displayName: "Gemma 4 E4B Instruct",
                publisher: "Google",
                parameterCountLabel: "E4B",
                starterSizeBytes: 5_335_289_664,
                supportsVision: true,
                tags: ["gemma4", "multimodal", "vision", "audio"],
                sources: [
                    curatedSource(.gguf, "lmstudio-community/gemma-4-E4B-it-GGUF", label: "GGUF", starterSizeBytes: 5_335_289_664),
                    curatedSource(.mlx, "lmstudio-community/gemma-4-E4B-it-MLX-4bit", label: "INT4", starterSizeBytes: 6_861_470_124),
                    curatedSource(.ane, "mlboydaisuke/gemma-4-E4B-coreml", label: "CML", starterSizeBytes: 2_328_482_563),
                    curatedSource(.coreai, "mlboydaisuke/gemma-4-E4B-CoreAI", label: "gpu-pipelined/decode_int4", starterSizeBytes: 6_000_000_000)
                ]
            ),
            curatedEntry(
                id: "LiquidAI/LFM2.5-8B-A1B-GGUF",
                displayName: "LFM 2.5 8B A1B",
                publisher: "Liquid AI",
                parameterCountLabel: "8B-A1B",
                starterSizeBytes: 4_844_678_368,
                tags: ["lfm2.5", "moe", "reasoning", "tool-use"],
                sources: [
                    curatedSource(.gguf, "LiquidAI/LFM2.5-8B-A1B-GGUF", label: "GGUF", starterSizeBytes: 4_844_678_368),
                    curatedSource(.mlx, "LiquidAI/LFM2.5-8B-A1B-MLX-4bit", label: "INT4", starterSizeBytes: 4_900_000_000)
                ]
            ),
            curatedEntry(
                id: "mistralai/Ministral-3-8B-Instruct-2512-GGUF",
                displayName: "Ministral 3 8B Instruct",
                publisher: "Mistral AI",
                parameterCountLabel: "8B",
                starterSizeBytes: 5_198_911_904,
                supportsVision: true,
                tags: ["ministral3", "instruct", "multimodal", "vision"],
                sources: [
                    curatedSource(.gguf, "mistralai/Ministral-3-8B-Instruct-2512-GGUF", label: "GGUF", starterSizeBytes: 5_198_911_904),
                    curatedSource(.mlx, "mlx-community/Ministral-3-8B-Instruct-2512-4bit", label: "INT4", starterSizeBytes: 5_200_000_000)
                ]
            ),
            curatedEntry(
                id: "unsloth/Qwen3.5-9B-GGUF",
                displayName: "Qwen 3.5 9B",
                publisher: "Qwen",
                parameterCountLabel: "9B",
                starterSizeBytes: 5_379_417_312,
                supportsVision: true,
                tags: ["qwen3.5", "reasoning", "tool-use", "vision"],
                sources: [
                    curatedSource(.gguf, "unsloth/Qwen3.5-9B-GGUF", label: "GGUF", starterSizeBytes: 5_379_417_312),
                    curatedSource(.mlx, "lmstudio-community/Qwen3.5-9B-MLX-4bit", label: "INT4", starterSizeBytes: 5_500_000_000)
                ]
            ),
            curatedEntry(
                id: "unsloth/gemma-4-12b-it-GGUF",
                displayName: "Gemma 4 12B Instruct",
                publisher: "Google",
                parameterCountLabel: "12B",
                starterSizeBytes: 6_738_474_400,
                supportsVision: true,
                tags: ["gemma4", "multimodal", "vision"],
                sources: [
                    curatedSource(.gguf, "unsloth/gemma-4-12b-it-GGUF", label: "GGUF", starterSizeBytes: 6_738_474_400),
                    curatedSource(.mlx, "mlx-community/gemma-4-12B-it-4bit", label: "INT4", starterSizeBytes: 6_900_000_000),
                    curatedSource(.ane, "lube8163/gemma-4-12b-coreml-iphone-practical-chat", label: "CML", starterSizeBytes: 12_589_632_369),
                    curatedSource(.coreai, "mlboydaisuke/Gemma-4-12B-CoreAI", label: "gpu-pipelined/decode_int4", starterSizeBytes: 11_700_000_000)
                ]
            ),
            curatedEntry(
                id: "prism-ml/Ternary-Bonsai-27B-gguf",
                displayName: "Ternary Bonsai 27B",
                publisher: "Prism ML",
                parameterCountLabel: "27B",
                starterSizeBytes: 7_165_121_600,
                supportsVision: true,
                tags: ["bonsai", "qwen3.6", "ternary", "2-bit", "reasoning", "tool-use", "vision"],
                sources: [
                    curatedSource(.gguf, "prism-ml/Ternary-Bonsai-27B-gguf", label: "Q2_0", starterSizeBytes: 7_165_121_600),
                    curatedSource(.mlx, "prism-ml/Ternary-Bonsai-27B-mlx-2bit", label: "2-bit", starterSizeBytes: 8_490_785_104)
                ]
            ),
            curatedEntry(
                id: "mistralai/Ministral-3-14B-Instruct-2512-GGUF",
                displayName: "Ministral 3 14B Instruct",
                publisher: "Mistral AI",
                parameterCountLabel: "14B",
                starterSizeBytes: 8_239_593_024,
                supportsVision: true,
                tags: ["ministral3", "instruct", "multimodal", "vision"],
                sources: [
                    curatedSource(.gguf, "mistralai/Ministral-3-14B-Instruct-2512-GGUF", label: "GGUF", starterSizeBytes: 8_239_593_024),
                    curatedSource(.mlx, "mlx-community/Ministral-3-14B-Instruct-2512-4bit", label: "INT4", starterSizeBytes: 8_300_000_000)
                ]
            ),
            curatedEntry(
                id: "unsloth/gpt-oss-20b-GGUF",
                displayName: "GPT-OSS 20B",
                publisher: "OpenAI",
                parameterCountLabel: "20B",
                starterSizeBytes: 11_501_495_488,
                tags: ["gpt-oss", "moe", "reasoning", "tool-use"],
                sources: [
                    curatedSource(.gguf, "unsloth/gpt-oss-20b-GGUF", label: "GGUF", starterSizeBytes: 11_501_495_488),
                    curatedSource(.mlx, "mlx-community/gpt-oss-20b-MXFP4-Q4", label: "INT4", starterSizeBytes: 11_206_437_333)
                ]
            ),
            curatedEntry(
                id: "unsloth/gemma-4-26B-A4B-it-GGUF",
                displayName: "Gemma 4 26B A4B Instruct",
                publisher: "Google",
                parameterCountLabel: "26B-A4B",
                starterSizeBytes: 16_551_046_944,
                supportsVision: true,
                tags: ["gemma4", "moe", "multimodal", "vision"],
                sources: [
                    curatedSource(.gguf, "unsloth/gemma-4-26B-A4B-it-GGUF", label: "GGUF", starterSizeBytes: 16_551_046_944),
                    curatedSource(.mlx, "lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit", label: "INT4", starterSizeBytes: 16_700_000_000)
                ]
            ),
            curatedEntry(
                id: "unsloth/Qwen3.5-27B-GGUF",
                displayName: "Qwen 3.5 27B",
                publisher: "Qwen",
                parameterCountLabel: "27B",
                starterSizeBytes: 15_721_973_664,
                supportsVision: true,
                tags: ["qwen3.5", "reasoning", "tool-use", "vision"],
                sources: [
                    curatedSource(.gguf, "unsloth/Qwen3.5-27B-GGUF", label: "GGUF", starterSizeBytes: 15_721_973_664),
                    curatedSource(.mlx, "mlx-community/Qwen3.5-27B-4bit", label: "INT4", starterSizeBytes: 15_900_000_000)
                ]
            ),
            curatedEntry(
                id: "unsloth/Qwen3.6-27B-GGUF",
                displayName: "Qwen 3.6 27B",
                publisher: "Qwen",
                parameterCountLabel: "27B",
                starterSizeBytes: 15_791_278_304,
                tags: ["qwen3.6", "reasoning", "tool-use", "mtp"],
                sources: [
                    curatedSource(.gguf, "unsloth/Qwen3.6-27B-GGUF", label: "GGUF", starterSizeBytes: 15_791_278_304),
                    curatedSource(.mlx, "lmstudio-community/Qwen3.6-27B-MLX-4bit", label: "INT4", starterSizeBytes: 16_000_000_000),
                    curatedSource(.coreai, "mlboydaisuke/Qwen3.6-27B-CoreAI", label: "gpu-pipelined/decode_int8", starterSizeBytes: 29_774_040_341)
                ]
            ),
            curatedEntry(
                id: "unsloth/Qwen3.5-35B-A3B-GGUF",
                displayName: "Qwen 3.5 35B A3B",
                publisher: "Qwen",
                parameterCountLabel: "35B-A3B",
                starterSizeBytes: 21_587_638_912,
                supportsVision: true,
                tags: ["qwen3.5", "moe", "reasoning", "tool-use", "vision"],
                sources: [
                    curatedSource(.gguf, "unsloth/Qwen3.5-35B-A3B-GGUF", label: "GGUF", starterSizeBytes: 21_587_638_912),
                    curatedSource(.mlx, "mlx-community/Qwen3.5-35B-A3B-4bit", label: "INT4", starterSizeBytes: 21_800_000_000)
                ]
            ),
            curatedEntry(
                id: "unsloth/gpt-oss-120b-GGUF",
                displayName: "GPT-OSS 120B",
                publisher: "OpenAI",
                parameterCountLabel: "120B",
                starterSizeBytes: 62_620_023_392,
                tags: ["gpt-oss", "moe", "reasoning", "tool-use"],
                sources: [
                    curatedSource(.gguf, "unsloth/gpt-oss-120b-GGUF", label: "GGUF", starterSizeBytes: 62_620_023_392),
                    curatedSource(.mlx, "mlx-community/gpt-oss-120b-MXFP4-Q4", label: "INT4", starterSizeBytes: 62_357_925_763)
                ]
            ),
            curatedEntry(
                id: "unsloth/Qwen3.5-122B-A10B-GGUF",
                displayName: "Qwen 3.5 122B A10B",
                publisher: "Qwen",
                parameterCountLabel: "122B-A10B",
                starterSizeBytes: 74_664_408_608,
                supportsVision: true,
                tags: ["qwen3.5", "moe", "reasoning", "tool-use", "vision"],
                sources: [
                    curatedSource(.gguf, "unsloth/Qwen3.5-122B-A10B-GGUF", label: "GGUF", starterSizeBytes: 74_664_408_608),
                    curatedSource(.mlx, "mlx-community/Qwen3.5-122B-A10B-4bit", label: "INT4", starterSizeBytes: 75_000_000_000)
                ]
            ),
            curatedEntry(
                id: "unsloth/Qwen3.5-397B-A17B-GGUF",
                displayName: "Qwen 3.5 397B A17B",
                publisher: "Qwen",
                parameterCountLabel: "397B-A17B",
                starterSizeBytes: 237_352_358_496,
                supportsVision: true,
                tags: ["qwen3.5", "moe", "reasoning", "tool-use", "vision"],
                sources: [
                    curatedSource(.gguf, "unsloth/Qwen3.5-397B-A17B-GGUF", label: "GGUF", starterSizeBytes: 237_352_358_496),
                    curatedSource(.mlx, "mlx-community/Qwen3.5-397B-A17B-4bit", label: "INT4", starterSizeBytes: 238_000_000_000)
                ]
            )
        ]
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
        let noemaSummary = String(localized: "Noema-2B is a compact reasoning model from Noema, derived from Qwen 3.5-2B and built on a hybrid Gated-DeltaNet architecture with roughly 2 billion parameters. It is tuned and evaluated in non-thinking mode for fast, direct answers, with particular strength in reasoning and math, and ships as GGUF quantizations for efficient on-device inference with llama.cpp. Despite its small size it keeps a very large native context window, making it a strong lightweight default for local chat, prototyping, and everyday tasks.", locale: locale)
        let noemaMinimumRAM = requiredRAMBytes(from: 1_274_396_096)
        let qwen35MinimumRAM = requiredRAMBytes(from: 1_107_149_056)
        let bonsaiMinimumRAM = requiredRAMBytes(from: 1_158_654_496)
        let gemma3MinimumRAM = requiredRAMBytes(from: 2_370_065_536)
        let lfmThinkingMinimumRAM = requiredRAMBytes(from: 695_751_680)
        let graniteTinyMinimumRAM = requiredRAMBytes(from: 3_962_938_208)
        let gemma4E2MinimumRAM = requiredRAMBytes(from: 3_041_376_384)
        let qwen3MinimumRAM = requiredRAMBytes(from: 1_834_426_016)
        var entries = [
            Entry(
                record: ModelRecord(
                    id: "NoemaAI-labs/Noema-2B-GGUF",
                    displayName: "Noema 2B",
                    publisher: "Noema",
                    summary: noemaSummary,
                    parameterCountLabel: "2B",
                    hasInstallableQuant: true,
                    formats: [.gguf],
                    installed: false,
                    tags: ["gguf", "noema", "qwen3.5", "gated-deltanet", "reasoning", "math", "llama.cpp"],
                    pipeline_tag: nil,
                    minRAMBytes: noemaMinimumRAM,
                    recommendedETBackend: nil,
                    supportsVision: false
                ),
                details: ModelDetails(
                    id: "NoemaAI-labs/Noema-2B-GGUF",
                    summary: noemaSummary,
                    parameterCountLabel: "2B",
                    quants: [
                        QuantInfo(
                            label: "GGUF",
                            format: .gguf,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/NoemaAI-labs/Noema-2B-GGUF")!,
                            sha256: nil,
                            configURL: nil
                        )
                    ],
                    promptTemplate: nil,
                    minRAMBytes: noemaMinimumRAM
                )
            ),

            Entry(
                record: ModelRecord(
                    id: "unsloth/Qwen3.5-2B-GGUF",
                    displayName: "Qwen 3.5 2B",
                    publisher: "Qwen",
                    summary: qwenSummary,
                    hasInstallableQuant: true,
                    formats: [.gguf, .mlx, .ane, .coreai],
                    installed: false,
                    tags: ["gguf", "mlx", "cml", "coreai", "qwen3.5", "multimodal", "vision", "reasoning", "tool-use"],
                    pipeline_tag: "image-text-to-text",
                    minRAMBytes: qwen35MinimumRAM,
                    minRAMBytesByFormat: [
                        .gguf: qwen35MinimumRAM,
                        .mlx: requiredRAMBytes(from: 1_350_000_000),
                        .ane: requiredRAMBytes(from: 3_766_256_156),
                        .coreai: requiredRAMBytes(from: 2_500_000_000)
                    ],
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
                            label: "CML",
                            format: .ane,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlboydaisuke/qwen3.5-2B-CoreML")!,
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
                    minRAMBytes: qwen35MinimumRAM
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
                    minRAMBytes: bonsaiMinimumRAM,
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
                    minRAMBytes: bonsaiMinimumRAM
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
                    minRAMBytes: gemma3MinimumRAM,
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
                    minRAMBytes: gemma3MinimumRAM
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
                    minRAMBytes: lfmThinkingMinimumRAM,
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
                    minRAMBytes: lfmThinkingMinimumRAM
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
                    minRAMBytes: graniteTinyMinimumRAM,
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
                    minRAMBytes: graniteTinyMinimumRAM
                )
            ),

            Entry(
                record: ModelRecord(
                    id: "unsloth/gemma-4-E2B-it-GGUF",
                    displayName: "Gemma 4 E2B it",
                    publisher: "Google",
                    summary: gemma4Summary,
                    hasInstallableQuant: true,
                    formats: [.gguf, .mlx, .et, .ane, .coreai],
                    installed: false,
                    tags: ["gguf", "mlx", "et", "cml", "coreai", "gemma", "gemma4", "multimodal", "vision", "audio"],
                    pipeline_tag: "image-text-to-text",
                    minRAMBytes: gemma4E2MinimumRAM,
                    minRAMBytesByFormat: [
                        .gguf: gemma4E2MinimumRAM,
                        .mlx: requiredRAMBytes(from: 3_300_000_000),
                        .et: requiredRAMBytes(from: 3_000_000_000),
                        .ane: requiredRAMBytes(from: 25_199_186_701),
                        .coreai: requiredRAMBytes(from: 4_000_000_000)
                    ],
                    recommendedETBackend: .xnnpack,
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
                        ),
                        QuantInfo(
                            label: "ET-XNNPACK",
                            format: .et,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/software-mansion/react-native-executorch-gemma-4")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "CML",
                            format: .ane,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlboydaisuke/gemma-4-E2B-coreml")!,
                            sha256: nil,
                            configURL: nil
                        ),
                        QuantInfo(
                            label: "gpu-pipelined/decode_int4",
                            format: .coreai,
                            sizeBytes: 0,
                            downloadURL: URL(string: "https://huggingface.co/mlboydaisuke/gemma-4-E2B-CoreAI")!,
                            sha256: nil,
                            configURL: nil
                        )
                    ],
                    promptTemplate: nil,
                    minRAMBytes: gemma4E2MinimumRAM
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
                    minRAMBytes: qwen3MinimumRAM,
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
                    minRAMBytes: qwen3MinimumRAM
                )
            )
        ]
        entries.append(contentsOf: additionalCuratedEntries)
        return entries
    }
}
