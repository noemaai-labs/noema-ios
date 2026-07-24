import Foundation

public struct RepoFile { let path: String; let size: Int64; let sha256: String? }

public enum QuantExtractor {
    static func extract(from files: [RepoFile], repoID: String) -> [QuantInfo] {
        var quants: [QuantInfo] = []
        var seenLabels: Set<String> = []
        // `.noema-paged` packages (manifest.json + resident.gguf + expert banks)
        // install as one unit; member files must not surface as standalone
        // quants below — a resident.gguf without its expert banks is unusable.
        let pagedQuants = pagedPackageQuants(from: files, repoID: repoID)
        let files = files.filter { pagedPackageRoot(from: $0.path) == nil }
        struct GGUFGroup {
            let key: String
            var files: [RepoFile] = []
        }

        var groupsByKey: [String: GGUFGroup] = [:]
        var groupOrder: [String] = []

        for file in files {
            let lower = file.path.lowercased()
            // Skip companion artifacts (.mmproj/projector, MTP, and DSpark draft heads).
            if lower.contains("mmproj")
                || lower.contains("projector")
                || lower.contains("image_proj")
                || lower.contains("mtp-")
                || lower.contains("-mtp")
                || lower.contains("nextn")
                || lower.contains("dspark") {
                continue
            }
            guard lower.hasSuffix(".gguf") else { continue }

            let key = GGUFShardNaming.splitGroupKey(forPath: file.path) ?? "single:\(file.path)"
            if groupsByKey[key] == nil {
                groupsByKey[key] = GGUFGroup(key: key, files: [])
                groupOrder.append(key)
            }
            var existing = groupsByKey[key] ?? GGUFGroup(key: key, files: [])
            existing.files.append(file)
            groupsByKey[key] = existing
        }

        let cfg = URL(string: "https://huggingface.co/\(repoID)/raw/main/config.json")

        for key in groupOrder {
            guard let group = groupsByKey[key], !group.files.isEmpty else { continue }

            let splitInfos: [(file: RepoFile, info: GGUFShardNaming.SplitInfo)] = group.files.compactMap { file in
                guard let info = GGUFShardNaming.parseSplitPath(file.path) else { return nil }
                return (file, info)
            }

            let isSplitGroup = !splitInfos.isEmpty
            if isSplitGroup && splitInfos.count != group.files.count {
                print("[QuantExtractor] Skipping mixed GGUF split/non-split group: \(group.key)")
                continue
            }

            if isSplitGroup {
                let expectedCounts = Set(splitInfos.map { $0.info.partCount })
                guard expectedCounts.count == 1, let expected = expectedCounts.first else {
                    print("[QuantExtractor] Skipping GGUF split group with inconsistent part counts: \(group.key)")
                    continue
                }

                var uniqueByPart: [Int: (file: RepoFile, info: GGUFShardNaming.SplitInfo)] = [:]
                for entry in splitInfos where uniqueByPart[entry.info.partIndex] == nil {
                    uniqueByPart[entry.info.partIndex] = entry
                }
                guard uniqueByPart.count == expected else {
                    print("[QuantExtractor] Skipping incomplete GGUF split group (\(uniqueByPart.count)/\(expected)): \(group.key)")
                    continue
                }

                let ordered = uniqueByPart.values.sorted { a, b in
                    if a.info.partIndex != b.info.partIndex { return a.info.partIndex < b.info.partIndex }
                    return a.file.path < b.file.path
                }
                guard let primary = ordered.first(where: { $0.info.partIndex == 1 }) ?? ordered.first else { continue }

                let label = Self.label(for: primary.file.path, repoID: repoID, ext: ".gguf")
                guard seenLabels.insert(label).inserted else { continue }

                let parts: [QuantInfo.DownloadPart] = ordered.map { entry in
                    QuantInfo.DownloadPart(
                        path: entry.file.path,
                        sizeBytes: entry.file.size,
                        sha256: entry.file.sha256,
                        downloadURL: URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(entry.file.path)?download=1")!
                    )
                }
                let totalBytes = parts.reduce(into: Int64(0)) { $0 += max($1.sizeBytes, 0) }

                quants.append(QuantInfo(
                    label: label,
                    format: .gguf,
                    sizeBytes: totalBytes,
                    downloadURL: parts.first(where: { GGUFShardNaming.parseSplitPath($0.path)?.partIndex == 1 })?.downloadURL ?? parts[0].downloadURL,
                    sha256: nil,
                    configURL: cfg,
                    downloadParts: parts
                ))
                continue
            }

            guard let file = group.files.first else { continue }
            let label = Self.label(for: file.path, repoID: repoID, ext: ".gguf")
            // Skip duplicate labels within the same repo (common with mirrored filenames)
            guard seenLabels.insert(label).inserted else { continue }
            let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(file.path)?download=1")!
            quants.append(QuantInfo(label: label,
                                   format: .gguf,
                                   sizeBytes: file.size,
                                   downloadURL: url,
                                   sha256: file.sha256,
                                   configURL: cfg))
        }

        for quant in pagedQuants where seenLabels.insert(quant.label).inserted {
            quants.append(quant)
        }
        // MLX detection (prefer safetensors shards, then NPZ, then weights.json).
        // MLX repos are single-quant, so every `.safetensors` file is a shard of
        // that one quant — enumerate them all into `downloadParts` (the total size
        // and the fit/plan/progress accounting all derive from this). Picking only
        // the first shard here made a 19GB model report as its 5GB first shard.
        let safetensorShards = files
            .filter { $0.path.lowercased().hasSuffix(".safetensors") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if !safetensorShards.isEmpty {
            let parts: [QuantInfo.DownloadPart] = safetensorShards.compactMap { file in
                guard let url = resolveDownloadURL(repoID: repoID, path: file.path) else { return nil }
                return QuantInfo.DownloadPart(
                    path: file.path,
                    sizeBytes: file.size,
                    sha256: file.sha256,
                    downloadURL: url
                )
            }
            if let primary = parts.first {
                let totalBytes = parts.reduce(into: Int64(0)) { $0 += max($1.sizeBytes, 0) }
                let label = Self.mlxLabel(for: primary.path, repoID: repoID)
                quants.append(QuantInfo(label: label,
                                       format: .mlx,
                                       sizeBytes: totalBytes,
                                       downloadURL: primary.downloadURL,
                                       sha256: primary.sha256,
                                       configURL: cfg,
                                       downloadParts: parts.count > 1 ? parts : nil))
            }
        } else {
            let npz = files.first(where: { $0.path.lowercased().hasSuffix(".npz") })
            let weightsJson = files.first(where: { $0.path.lowercased().hasSuffix("weights.json") })
            if let picked = npz ?? weightsJson {
                let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(picked.path)")!
                let label = Self.mlxLabel(for: picked.path, repoID: repoID)
                quants.append(QuantInfo(label: label,
                                       format: .mlx,
                                       sizeBytes: picked.size,
                                       downloadURL: url,
                                       sha256: picked.sha256,
                                       configURL: cfg))
            }
        }

        // ExecuTorch detection (.pte program files plus required tokenizer sidecars)
        let pteFiles = files.filter { $0.path.lowercased().hasSuffix(".pte") }
        if !pteFiles.isEmpty {
            let orderedPTE = pteFiles.sorted { lhs, rhs in
                let l = lhs.path.lowercased()
                let r = rhs.path.lowercased()
                let lPrimary = l.hasSuffix("/model.pte") || l == "model.pte"
                let rPrimary = r.hasSuffix("/model.pte") || r == "model.pte"
                if lPrimary != rPrimary { return lPrimary && !rPrimary }
                let lXNNPACK = l.contains("xnnpack")
                let rXNNPACK = r.contains("xnnpack")
                if lXNNPACK != rXNNPACK { return lXNNPACK && !rXNNPACK }
                let lQuantized = l.contains("quantized") || l.contains("8da4w") || l.contains("int4")
                let rQuantized = r.contains("quantized") || r.contains("8da4w") || r.contains("int4")
                if lQuantized != rQuantized { return lQuantized && !rQuantized }
                return l < r
            }
            for file in orderedPTE {
                let label = Self.etLabel(for: file.path, repoID: repoID)
                guard seenLabels.insert(label).inserted else { continue }
                let parts = Self.etDownloadParts(primaryPTE: file, files: files, repoID: repoID)
                let totalBytes = parts.reduce(into: Int64(0)) { sum, part in
                    sum += max(part.sizeBytes, 0)
                }
                let url = parts.first?.downloadURL
                    ?? URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(file.path)?download=1")!
                let cfg = URL(string: "https://huggingface.co/\(repoID)/raw/main/tokenizer_config.json")
                quants.append(
                    QuantInfo(
                        label: label,
                        format: .et,
                        sizeBytes: max(file.size, totalBytes),
                        downloadURL: url,
                        sha256: file.sha256,
                        configURL: cfg,
                        downloadParts: parts.count > 1 ? parts : nil
                    )
                )
            }
        }

        // CoreML / ANE detection (single install artifact, no quant tiers)
        if let aneQuant = aneQuant(from: files, repoID: repoID) {
            if seenLabels.insert(aneQuant.label).inserted {
                quants.append(aneQuant)
            }
        }

        // Core AI detection (.aimodel / .aimodelc bundles, one quant per variant)
        for quant in coreAIQuants(from: files, repoID: repoID) where seenLabels.insert(quant.label).inserted {
            quants.append(quant)
        }
        return quants
    }

    private static func label(for path: String, repoID: String, ext: String) -> String {
        _ = ext // kept to preserve the existing signature and call sites
        return GGUFShardNaming.normalizedQuantLabel(for: path, repoID: repoID)
    }

    /// Directory-component prefix (`<stem>.noema-paged`) enclosing `path`, or
    /// nil when the file is not a paged-package member. Listings only carry
    /// files, so any path with a `.noema-paged` directory component is inside
    /// a package.
    private static func pagedPackageRoot(from path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return nil }
        for idx in components.indices.dropLast() where components[idx].lowercased().hasSuffix(".noema-paged") {
            return components[components.startIndex...idx].map(String.init).joined(separator: "/")
        }
        return nil
    }

    /// Detects `.noema-paged` package directories (manifest.json alongside a
    /// resident GGUF and expert banks) and produces one installable quant per
    /// package covering every member file.
    private static func pagedPackageQuants(from files: [RepoFile], repoID: String) -> [QuantInfo] {
        let roots = Set(files.compactMap { pagedPackageRoot(from: $0.path) })
        guard !roots.isEmpty else { return [] }

        var filesByPath: [String: RepoFile] = [:]
        for file in files where filesByPath[file.path] == nil {
            filesByPath[file.path] = file
        }
        let cfg = URL(string: "https://huggingface.co/\(repoID)/raw/main/config.json")

        var quants: [QuantInfo] = []
        for root in roots.sorted() {
            let manifestPath = root + "/manifest.json"
            guard filesByPath[manifestPath] != nil else { continue }

            // manifest.json leads so the download router recognizes a paged
            // install from the primary part path; relative paths keep the
            // package directory component so the multipart writer recreates
            // the layout on disk.
            func rank(_ path: String) -> Int {
                if path == manifestPath { return 0 }
                let name = String(path.dropFirst(root.count + 1)).lowercased()
                if name.hasSuffix(".gguf") { return 1 }
                if name.hasPrefix("experts-") && name.hasSuffix(".bin") { return 2 }
                return 3
            }
            let orderedPaths = files
                .filter { $0.path.hasPrefix(root + "/") }
                .map(\.path)
                .sorted { lhs, rhs in
                    let lr = rank(lhs)
                    let rr = rank(rhs)
                    if lr != rr { return lr < rr }
                    return lhs.localizedStandardCompare(rhs) == .orderedAscending
                }

            let parts: [QuantInfo.DownloadPart] = orderedPaths.compactMap { path in
                guard let file = filesByPath[path],
                      let url = resolveDownloadURL(repoID: repoID, path: path) else { return nil }
                return QuantInfo.DownloadPart(
                    path: path,
                    sizeBytes: file.size,
                    sha256: file.sha256,
                    downloadURL: url
                )
            }
            guard parts.count >= 2, parts.first?.path == manifestPath else { continue }
            let totalBytes = parts.reduce(into: Int64(0)) { $0 += max($1.sizeBytes, 0) }

            let dirName = root.split(separator: "/").last.map(String.init) ?? root
            let stem = String(dirName.dropLast(".noema-paged".count))
            let quantLabel = GGUFShardNaming.normalizedQuantLabel(for: stem + ".gguf", repoID: repoID)
            // Unlike a conventional GGUF repo, each `.noema-paged` directory
            // is a complete model package. Keep the package stem in the
            // identity so two different models using the same quant remain
            // distinct throughout downloads and the installed-model store.
            let label = "\(quantLabel) · \(stem) · Paged"

            quants.append(QuantInfo(
                label: label,
                format: .gguf,
                sizeBytes: totalBytes,
                downloadURL: parts[0].downloadURL,
                sha256: nil,
                configURL: cfg,
                downloadParts: parts
            ))
        }
        return quants
    }

    private static func lastRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: full)
        guard let m = matches.last, let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    private static func mlxLabel(for path: String, repoID: String) -> String {
        let combined = (repoID + " " + path).lowercased()
        if let r = combined.range(of: #"(?:q|int|fp)[ _-]?(\d{1,2})|(\d{1,2})[ _-]?bit"#, options: .regularExpression) {
            let match = String(combined[r])
            let digits = match.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let bits = Int(digits) {
                if bits == 16 { return "F16" }
                return "INT\(bits)"
            }
        }
        return "MLX"
    }

    private static func etLabel(for path: String, repoID: String) -> String {
        let combined = (repoID + " " + path).lowercased()
        if combined.contains("xnnpack") { return "ET-XNNPACK" }
        if combined.contains("coreml") || combined.contains("core-ml") { return "ET-CoreML" }
        if combined.contains("mps") || combined.contains("metal") { return "ET-MPS" }
        return "ET"
    }

    private static func etDownloadParts(primaryPTE: RepoFile, files: [RepoFile], repoID: String) -> [QuantInfo.DownloadPart] {
        var orderedPaths: [String] = [primaryPTE.path]
        var seen = Set(orderedPaths)

        let primaryDirectory = URL(fileURLWithPath: primaryPTE.path).deletingLastPathComponent().path
        let normalizedPrimaryDirectory = primaryDirectory == "." ? "" : primaryDirectory
        let sidecarNames = Set(ETModelResolver.sidecarFileNames.map { $0.lowercased() })

        let sidecars = files
            .map(\.path)
            .filter { path in
                guard path != primaryPTE.path else { return false }
                let url = URL(fileURLWithPath: path)
                let name = url.lastPathComponent.lowercased()
                guard sidecarNames.contains(name) else { return false }
                let dir = url.deletingLastPathComponent().path
                let normalizedDir = dir == "." ? "" : dir
                return normalizedDir.isEmpty
                    || normalizedDir == normalizedPrimaryDirectory
                    || normalizedDir.lowercased().contains("tokenizer")
            }
            .sorted { lhs, rhs in
                let lName = URL(fileURLWithPath: lhs).lastPathComponent.lowercased()
                let rName = URL(fileURLWithPath: rhs).lastPathComponent.lowercased()
                let lRank = ETModelResolver.sidecarFileNames.firstIndex(of: lName) ?? Int.max
                let rRank = ETModelResolver.sidecarFileNames.firstIndex(of: rName) ?? Int.max
                if lRank != rRank { return lRank < rRank }
                return lhs < rhs
            }

        for path in sidecars where seen.insert(path).inserted {
            orderedPaths.append(path)
        }

        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return orderedPaths.compactMap { path in
            guard let file = byPath[path],
                  let url = resolveDownloadURL(repoID: repoID, path: path) else { return nil }
            return QuantInfo.DownloadPart(
                path: path,
                sizeBytes: file.size,
                sha256: file.sha256,
                downloadURL: url
            )
        }
    }

    private static let aneSidecarNames: [String] = [
        "meta.yaml",
        "meta.yml",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "tokenizer.model",
        "spiece.model",
        "sentencepiece.bpe.model",
        "vocab.json",
        "vocab.txt",
        "merges.txt",
        "config.json",
        "generation_config.json",
        "chat_template.json",
        "chat_template.jinja"
    ]

    private static func aneQuant(from files: [RepoFile], repoID: String) -> QuantInfo? {
        guard !files.isEmpty else { return nil }

        let roots = Set(files.compactMap { coreMLRootPath(from: $0.path) })
        guard !roots.isEmpty else { return nil }

        let prioritizedRoots = roots.sorted { lhs, rhs in
            let lp = coreMLPriority(for: lhs)
            let rp = coreMLPriority(for: rhs)
            if lp != rp { return lp < rp }
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs < rhs
        }

        var orderedPaths: [String] = []
        var seen = Set<String>()

        for root in prioritizedRoots {
            let rootLower = root.lowercased()
            let isContainer = rootLower.hasSuffix(".mlmodelc") || rootLower.hasSuffix(".mlpackage")
            let matches = files
                .map(\.path)
                .filter { path in
                    if isContainer {
                        return path == root || path.hasPrefix(root + "/")
                    }
                    return path == root
                }
                .sorted()
            for match in matches where seen.insert(match).inserted {
                orderedPaths.append(match)
            }
        }

        if !orderedPaths.isEmpty {
            let sidecars = files
                .map(\.path)
                .filter { path in
                    let lower = path.lowercased()
                    let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
                    return aneSidecarNames.contains(name)
                        || lower.hasSuffix("/tokenizer.json")
                        || lower.hasSuffix("/tokenizer_config.json")
                        || lower.hasSuffix("/config.json")
                }
                .sorted()
            for sidecar in sidecars where seen.insert(sidecar).inserted {
                orderedPaths.append(sidecar)
            }
        }

        guard !orderedPaths.isEmpty else { return nil }

        var filesByPath: [String: RepoFile] = [:]
        for file in files where filesByPath[file.path] == nil {
            filesByPath[file.path] = file
        }
        let parts: [QuantInfo.DownloadPart] = orderedPaths.compactMap { path in
            guard let file = filesByPath[path] else { return nil }
            guard let downloadURL = resolveDownloadURL(repoID: repoID, path: path) else { return nil }
            return QuantInfo.DownloadPart(
                path: path,
                sizeBytes: file.size,
                sha256: file.sha256,
                downloadURL: downloadURL
            )
        }
        guard !parts.isEmpty else { return nil }

        let totalBytes = parts.reduce(into: Int64(0)) { sum, part in
            sum += max(part.sizeBytes, 0)
        }

        let primaryPath = prioritizedRoots.first.flatMap { root in
            parts.first(where: { part in
                part.path == root || part.path.hasPrefix(root + "/")
            })?.path
        }
        let primaryPart = parts.first(where: { $0.path == primaryPath }) ?? parts[0]
        let cfg = URL(string: "https://huggingface.co/\(repoID)/raw/main/config.json")

        return QuantInfo(
            label: "CML",
            format: .ane,
            sizeBytes: totalBytes,
            downloadURL: primaryPart.downloadURL,
            sha256: nil,
            configURL: cfg,
            downloadParts: parts
        )
    }

    /// Detects Core AI `.aimodel` / `.aimodelc` bundles published on Hugging Face
    /// (repos tagged "coreai"/"aimodel"). Each bundle becomes one installable quant;
    /// download parts cover the bundle contents plus any variant-level companions
    /// (metadata.json, tokenizer files) sitting next to the bundle.
    private static func coreAIQuants(from files: [RepoFile], repoID: String) -> [QuantInfo] {
        let roots = Set(files.compactMap { coreAIBundleRoot(from: $0.path) })
        guard !roots.isEmpty else { return [] }

        var filesByPath: [String: RepoFile] = [:]
        for file in files where filesByPath[file.path] == nil {
            filesByPath[file.path] = file
        }
        let sidecarNames = Set((aneSidecarNames + ["metadata.json"]).map { $0.lowercased() })
        let cfg = URL(string: "https://huggingface.co/\(repoID)/raw/main/config.json")

        func isPrefillRoot(_ root: String) -> Bool {
            URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
                .lowercased().contains("prefill")
        }
        func parentDir(of root: String) -> String {
            root.contains("/") ? String(root[..<root.lastIndex(of: "/")!]) : ""
        }

        var quants: [QuantInfo] = []
        for root in roots.sorted() {
            // Chunked-prefill companion graphs aren't standalone chat models —
            // they ride along with the decode bundles in their directory instead
            // (see below).
            if isPrefillRoot(root) { continue }

            // Largest file first (main.mlirb) so the primary part lives inside the
            // bundle — canonical install URLs resolve from it.
            let bundleFiles = files
                .filter { $0.path == root || $0.path.hasPrefix(root + "/") }
                .sorted { lhs, rhs in
                    if lhs.size != rhs.size { return lhs.size > rhs.size }
                    return lhs.path < rhs.path
                }
            guard !bundleFiles.isEmpty else { continue }

            let variantDir = root.contains("/") ? String(root[..<root.lastIndex(of: "/")!]) : ""
            let prefix = variantDir.isEmpty ? "" : variantDir + "/"
            let sidecars = files
                .map(\.path)
                .filter { path in
                    guard path.hasPrefix(prefix), coreAIBundleRoot(from: path) == nil else { return false }
                    let rel = String(path.dropFirst(prefix.count)).lowercased()
                    if sidecarNames.contains(rel) { return true }
                    if rel.hasPrefix("tokenizer/"), !rel.dropFirst("tokenizer/".count).contains("/") { return true }
                    return false
                }
                .sorted()

            // The chunked-prefill companion (e.g. `*_prefill_q16_*.aimodel`) is
            // the fast prefill path for the q=1 decode graphs in its directory:
            // it consumes the prompt in fixed-size token blocks with the same
            // state contract, then hands the states to the decode graph. Install
            // it alongside every decode bundle that shares its directory.
            let companionPaths = roots
                .filter { $0 != root && isPrefillRoot($0) && parentDir(of: $0) == variantDir }
                .sorted()
                .flatMap { companionRoot in
                    files
                        .filter { $0.path == companionRoot || $0.path.hasPrefix(companionRoot + "/") }
                        .map(\.path)
                        .sorted()
                }

            var orderedPaths = bundleFiles.map(\.path)
            var seen = Set(orderedPaths)
            for companion in companionPaths where seen.insert(companion).inserted {
                orderedPaths.append(companion)
            }
            for sidecar in sidecars where seen.insert(sidecar).inserted {
                orderedPaths.append(sidecar)
            }

            let parts: [QuantInfo.DownloadPart] = orderedPaths.compactMap { path in
                guard let file = filesByPath[path],
                      let url = resolveDownloadURL(repoID: repoID, path: path) else { return nil }
                return QuantInfo.DownloadPart(
                    path: path,
                    sizeBytes: file.size,
                    sha256: file.sha256,
                    downloadURL: url
                )
            }
            guard let primary = parts.first else { continue }
            let totalBytes = parts.reduce(into: Int64(0)) { $0 += max($1.sizeBytes, 0) }

            quants.append(QuantInfo(
                label: coreAILabel(for: root, repoID: repoID),
                format: .coreai,
                sizeBytes: totalBytes,
                downloadURL: primary.downloadURL,
                sha256: nil,
                configURL: cfg,
                downloadParts: parts
            ))
        }
        return quants
    }

    private static func coreAIBundleRoot(from path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        for idx in components.indices {
            let component = components[idx].lowercased()
            if component.hasSuffix(".aimodel") || component.hasSuffix(".aimodelc") {
                return components[components.startIndex...idx].map(String.init).joined(separator: "/")
            }
        }
        return nil
    }

    /// Builds a compact quant label from a bundle path, e.g.
    /// `ios-ane/qwen3_5_0_8b_decode_int8.aimodel` → "ios-ane/decode_int8":
    /// leading stem tokens already present in the repo name are dropped, and the
    /// top-level folder (platform / compute-unit grouping) is kept as a prefix.
    private static func coreAILabel(for root: String, repoID: String) -> String {
        let stem = URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent
        let repoName = (repoID.split(separator: "/").last.map(String.init) ?? repoID)
        let normalizedRepo = repoName.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)

        var kept: [Substring] = []
        var dropping = true
        for token in stem.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." }) {
            if dropping {
                let normalized = token.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
                if !normalized.isEmpty, normalizedRepo.contains(normalized) { continue }
                dropping = false
            }
            kept.append(token)
        }
        let cleanedStem = kept.isEmpty ? stem : kept.joined(separator: "_")

        let components = root.split(separator: "/")
        if components.count > 1 {
            return "\(components[0])/\(cleanedStem)"
        }
        return cleanedStem
    }

    private static func coreMLPriority(for path: String) -> Int {
        let lower = path.lowercased()
        if lower.hasSuffix(".mlmodelc") { return 0 }
        if lower.hasSuffix(".mlpackage") { return 1 }
        if lower.hasSuffix(".mlmodel") { return 2 }
        return 9
    }

    private static func coreMLRootPath(from path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }

        for idx in components.indices {
            let component = components[idx].lowercased()
            if component.hasSuffix(".mlmodelc") || component.hasSuffix(".mlpackage") {
                return components[components.startIndex...idx].map(String.init).joined(separator: "/")
            }
        }

        if normalized.lowercased().hasSuffix(".mlmodel") {
            return components.map(String.init).joined(separator: "/")
        }
        return nil
    }

    private static func resolveDownloadURL(repoID: String, path: String) -> URL? {
        let escapedRepo = repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoID
        let encodedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
            }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(escapedRepo)/resolve/main/\(encodedPath)?download=1")
    }

    static func shortLabel(from label: String, format: ModelFormat) -> String {
        switch format {
        case .gguf:
            // Prefer full informative token over just Q-number
            let normalized = label.replacingOccurrences(of: "-", with: "_")
            let pat = #"(?i)(ud_(?:iq\d+[a-z0-9_]*|pq\d+[a-z0-9_]*|q\d+[a-z0-9_]*|tq\d+[a-z0-9_]*|mxfp\d+(?:_moe)?)|iq\d+[a-z0-9_]*|pq\d+[a-z0-9_]*|q\d+[a-z0-9_]*|tq\d+[a-z0-9_]*|mxfp\d+(?:_moe)?)"#
            if let regex = try? NSRegularExpression(pattern: pat),
               let r = regex.matches(in: normalized, options: [], range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)).last,
               let rr = Range(r.range, in: normalized) {
                return String(normalized[rr]).uppercased()
            }
            return normalized.uppercased()
        case .mlx:
            if let r = label.range(of: #"(\d{1,2})"#, options: .regularExpression) {
                let digits = label[r]
                return "\(digits)bit"
            }
            return label
        case .et:
            return label
        case .ane:
            return label
        case .afm:
            return label
        case .coreai:
            return label
        }
    }
}
