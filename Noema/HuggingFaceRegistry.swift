// HuggingFaceRegistry.swift
import Foundation

public final class HuggingFaceRegistry: ModelRegistry, @unchecked Sendable {
    static let aneAuthor = "anemll"

    private let session: URLSession
    private let token: String?

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        if let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            self.token = t
        } else {
            self.token = nil
        }
    }

    enum RegistryError: LocalizedError {
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                return "Server error (HTTP \(code))"
            }
        }
    }

    // MARK: - ModelRegistry
    public func curated() async throws -> [ModelRecord] { [] }

    public func searchStream(query: String, page: Int, format: ModelFormat? = nil, includeVisionModels: Bool = true, visionOnly: Bool = false) -> AsyncThrowingStream<ModelRecord, Error> {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .init { $0.finish() } }
        let offset = page * 50
        
        // Make search more flexible by removing spaces for model names like "gemma 3 4b"
        // This helps match models named "gemma-3-4b" or "gemma3-4b"
        let searchQuery = trimmed
        
        let requiredAuthor = Self.requiredAuthor(for: format)

        func makeURL(filters: [String], author: String? = nil) -> URL {
            var c = URLComponents(string: "https://huggingface.co/api/models")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "search", value: searchQuery),
                URLQueryItem(name: "sort", value: "downloads"),
                URLQueryItem(name: "direction", value: "-1"),
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "cardData", value: "true")
            ]
            if let author, !author.isEmpty {
                queryItems.append(URLQueryItem(name: "author", value: author))
            }
            for filter in filters where !filter.isEmpty {
                queryItems.append(URLQueryItem(name: "filter", value: filter))
            }
            c.queryItems = queryItems
            return c.url!
        }

        let pipelineFilter: String? = {
            if visionOnly { return "image-text-to-text" }
            if includeVisionModels { return nil }
            return "text-generation"
        }()
        
        // Determine which URLs to fetch based on parameters
        let urlsToFetch: [URL]
        if format == .et {
            var filters = ["executorch"]
            if let pipelineFilter { filters.append(pipelineFilter) }
            urlsToFetch = [makeURL(filters: filters)]
        } else if format == .ane {
            var filters = ["coreml"]
            if let pipelineFilter { filters.append(pipelineFilter) }
            urlsToFetch = [makeURL(filters: filters, author: requiredAuthor)]
        } else if format == .coreai {
            // Core AI repos are tagged "coreai" and/or "aimodel". The HF API ANDs
            // multiple filters, so fetch both tags separately and dedupe by id.
            urlsToFetch = ["coreai", "aimodel"].map { tag in
                var filters = [tag]
                if let pipelineFilter { filters.append(pipelineFilter) }
                return makeURL(filters: filters)
            }
        } else {
            var filters: [String] = []
            if let pipelineFilter { filters.append(pipelineFilter) }
            urlsToFetch = [makeURL(filters: filters)]
        }
        
        return .init { continuation in
            let task = Task {
                do {
                    struct Entry: Decodable {
                        let modelId: String
                        let author: String?
                        let tags: [String]?
                        let pipeline_tag: String?
                        let cardData: Card?
                        struct Card: Decodable { let summary: String?; let pipeline_tag: String? }

                        enum CodingKeys: String, CodingKey { case modelId, id, author, tags, pipeline_tag, cardData }

                        init(from decoder: Decoder) throws {
                            let container = try decoder.container(keyedBy: CodingKeys.self)
                            if let mid = try container.decodeIfPresent(String.self, forKey: .modelId) {
                                self.modelId = mid
                            } else {
                                self.modelId = try container.decode(String.self, forKey: .id)
                            }
                            self.author = try container.decodeIfPresent(String.self, forKey: .author)
                            self.tags = try container.decodeIfPresent([String].self, forKey: .tags)
                            let topPipeline = try container.decodeIfPresent(String.self, forKey: .pipeline_tag)
                            self.cardData = try container.decodeIfPresent(Card.self, forKey: .cardData)
                            self.pipeline_tag = topPipeline ?? self.cardData?.pipeline_tag
                        }
                    }
                    
                    var combinedData: [Data] = []
                    
                    // Fetch from all specified URLs
                    for url in urlsToFetch {
                        let data = try await self.data(from: url)
                        combinedData.append(data.0)
                    }
                    
                    // Process both result sets
                    var seen = Set<String>()
                    for rawData in combinedData {
                        guard let pageResults = try? JSONDecoder().decode([Entry].self, from: rawData) else {
                            continue
                        }
                        print("[registry] search \(trimmed) page \(page) → \(pageResults.count)")
                        for entry in pageResults {
                            if !seen.insert(entry.modelId).inserted { continue }
                            guard Self.matchesAuthorConstraint(
                                format: format,
                                modelID: entry.modelId,
                                author: entry.author
                            ) else { continue }
                            let tags = entry.tags ?? []
                            let forcedFormat: ModelFormat? = {
                                switch format {
                                case .ane: return .ane
                                case .coreai: return .coreai
                                default: return nil
                                }
                            }()
                            let formats = Self.inferFormats(
                                tags: tags,
                                id: entry.modelId,
                                pipelineTag: entry.pipeline_tag,
                                forcedFormat: forcedFormat
                            )
                            let effectiveFormats = formats
                            let owner = entry.modelId.split(separator: "/").first.map(String.init) ?? (entry.author ?? "")
                            let recommendedETBackend = formats.contains(.et)
                                ? ETBackendDetector.detect(tags: tags, modelName: entry.modelId)
                                : nil
                            let supportsVision = Self.inferSupportsVision(tags: tags, pipelineTag: entry.pipeline_tag)
                            let record = ModelRecord(
                                id: entry.modelId,
                                displayName: Self.prettyName(from: entry.modelId),
                                publisher: owner,
                                summary: entry.cardData?.summary,
                                hasInstallableQuant: true,
                                formats: effectiveFormats,
                                installed: false,
                                tags: tags,
                                pipeline_tag: entry.pipeline_tag,
                                recommendedETBackend: recommendedETBackend,
                                supportsVision: supportsVision
                            )
                            continuation.yield(record)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func details(for id: String) async throws -> ModelDetails {
        var comps = URLComponents(string: "https://huggingface.co/api/models/\(id)")!
        comps.queryItems = [URLQueryItem(name: "full", value: "1"), URLQueryItem(name: "cardData", value: "true")]
        let (data, _) = try await data(from: comps.url!)
        struct Meta: Decodable {
            let modelId: String
            let author: String?
            let tags: [String]?
            let cardData: Card?
            let siblings: [Sibling]?
            let gguf: GGUF?

            struct Card: Decodable {
                let summary: String?
            }

            struct GGUF: Decodable {
                let quantize_imatrix_file: String?
            }

            struct Sibling: Decodable {
                let rfilename: String
                let size: Int?
                let lfs: LFS?

                struct LFS: Decodable {
                    let sha256: String?
                    let size: Int?
                }
            }
        }
        let meta = try JSONDecoder().decode(Meta.self, from: data)
        let siblings = meta.siblings ?? []
        let needsTreeSizeFallback = siblings.contains {
            Int64($0.lfs?.size ?? $0.size ?? 0) <= 0
        }
        let treeMetadata = needsTreeSizeFallback ? (try? await fetchTreeMetadata(for: id)) : nil
        let files = siblings.map { sibling in
            let declaredSize = Int64(sibling.lfs?.size ?? sibling.size ?? 0)
            let fallback = treeMetadata?[sibling.rfilename]
            let effectiveSize = declaredSize > 0 ? declaredSize : max(fallback?.size ?? 0, 0)
            let effectiveSHA = sibling.lfs?.sha256 ?? fallback?.sha256
            return RepoFile(path: sibling.rfilename, size: effectiveSize, sha256: effectiveSHA)
        }
        var quants = QuantExtractor.extract(from: files, repoID: id)

        let importanceMatrix: QuantInfo.AuxiliaryFile? = {
            func normalizedImatrixFileName(_ raw: String) -> String {
                raw.lowercased().replacingOccurrences(of: "_file", with: "")
            }

            func likelyImatrixPathFromSiblings() -> String? {
                let lowerTags = (meta.tags ?? []).map { $0.lowercased() }
                guard lowerTags.contains(where: { $0.contains("imatrix") }) else { return nil }

                let candidates = files
                    .map(\.path)
                    .filter { path in
                        let lower = path.lowercased()
                        return lower.contains("imatrix")
                            && (lower.hasSuffix(".gguf") || lower.hasSuffix(".gguf_file"))
                    }
                guard !candidates.isEmpty else { return nil }

                return candidates.sorted { lhs, rhs in
                    let l = lhs.lowercased()
                    let r = rhs.lowercased()
                    let lExact = l.hasSuffix(".gguf")
                    let rExact = r.hasSuffix(".gguf")
                    if lExact != rExact { return lExact && !rExact }
                    return lhs.count < rhs.count
                }.first
            }

            let rawPath = meta.gguf?.quantize_imatrix_file?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = (rawPath?.isEmpty == false ? rawPath : nil) ?? likelyImatrixPathFromSiblings()
            guard let path else { return nil }

            let pathLower = path.lowercased()
            let pathName = URL(fileURLWithPath: path).lastPathComponent
            let match = files.first { file in
                let lower = file.path.lowercased()
                if lower == pathLower || lower == pathLower + "_file" { return true }
                let siblingName = URL(fileURLWithPath: file.path).lastPathComponent
                return normalizedImatrixFileName(siblingName) == normalizedImatrixFileName(pathName)
            }

            let escapedRepo = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            let encodedPath = path
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { comp in
                    String(comp).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(comp)
                }
                .joined(separator: "/")
            guard let url = URL(string: "https://huggingface.co/\(escapedRepo)/resolve/main/\(encodedPath)?download=1") else {
                return nil
            }

            return QuantInfo.AuxiliaryFile(
                path: path,
                sizeBytes: match?.size ?? 0,
                sha256: match?.sha256,
                downloadURL: url
            )
        }()

        let mtpFile: QuantInfo.AuxiliaryFile? = {
            let candidates = files.filter { file in
                let lower = file.path.lowercased()
                guard lower.hasSuffix(".gguf") || lower.hasSuffix(".gguf_file") else { return false }
                guard !lower.contains("mmproj"), !lower.contains("projector"), !lower.contains("image_proj") else {
                    return false
                }
                return lower.contains("mtp-") || lower.contains("-mtp") || lower.contains("nextn")
            }
            guard let match = candidates.sorted(by: { lhs, rhs in
                let l = lhs.path.lowercased()
                let r = rhs.path.lowercased()
                let lScore = (l.contains("mtp-") || l.contains("-mtp") ? 2 : 0) + (l.contains("nextn") ? 1 : 0)
                let rScore = (r.contains("mtp-") || r.contains("-mtp") ? 2 : 0) + (r.contains("nextn") ? 1 : 0)
                if lScore != rScore { return lScore > rScore }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }).first else {
                return nil
            }

            let escapedRepo = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            let encodedPath = match.path
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { comp in
                    String(comp).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(comp)
                }
                .joined(separator: "/")
            guard let url = URL(string: "https://huggingface.co/\(escapedRepo)/resolve/main/\(encodedPath)?download=1") else {
                return nil
            }

            return QuantInfo.AuxiliaryFile(
                path: match.path,
                sizeBytes: match.size,
                sha256: match.sha256,
                downloadURL: url
            )
        }()

        if let importanceMatrix {
            for i in quants.indices where quants[i].format == .gguf && quants[i].isIQQuant {
                quants[i] = quants[i].copying(importanceMatrix: .some(importanceMatrix))
            }
        }
        if let mtpFile {
            for i in quants.indices where quants[i].format == .gguf {
                quants[i] = quants[i].copying(mtp: .some(mtpFile))
            }
        }

        let cfgURL = URL(string: "https://huggingface.co/\(id)/raw/main/config.json")
        for i in quants.indices {
            if quants[i].sizeBytes == 0 {
                if let size = try? await resolveSize(for: quants[i]), size > 0 {
                    quants[i] = quants[i].copying(sizeBytes: size, configURL: cfgURL)
                }
            } else if quants[i].configURL == nil {
                quants[i] = quants[i].copying(configURL: cfgURL)
            }
        }
        let prompt: String? = nil
        return ModelDetails(id: meta.modelId,
                            summary: meta.cardData?.summary,
                            quants: quants,
                            promptTemplate: prompt)
    }

    // MARK: - helpers
    private struct TreeFileMetadata: Sendable {
        let size: Int64
        let sha256: String?
    }

    private struct TreeEntry: Decodable {
        let path: String
        let type: String?
        let size: Int?
        let lfs: LFS?

        struct LFS: Decodable {
            let size: Int?
            let sha256: String?
            let oid: String?
        }
    }

    private func fetchTreeMetadata(for repoID: String) async throws -> [String: TreeFileMetadata] {
        var comps = URLComponents(string: "https://huggingface.co/api/models/\(repoID)/tree/main")!
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        let (data, _) = try await data(from: comps.url!)
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)

        var metadataByPath: [String: TreeFileMetadata] = [:]
        metadataByPath.reserveCapacity(entries.count)

        for entry in entries {
            if entry.type == "directory" { continue }
            let size = Int64(entry.lfs?.size ?? entry.size ?? 0)
            let sha256 = entry.lfs?.sha256 ?? entry.lfs?.oid
            metadataByPath[entry.path] = TreeFileMetadata(size: size, sha256: sha256)
        }

        return metadataByPath
    }

    private func resolveSize(for quant: QuantInfo) async throws -> Int64 {
        if quant.isMultipart {
            var total: Int64 = 0
            var hasAnyPartSize = false

            for part in quant.allDownloadParts {
                let knownSize = max(part.sizeBytes, 0)
                if knownSize > 0 {
                    total += knownSize
                    hasAnyPartSize = true
                    continue
                }

                let fetched = try await fetchSize(part.downloadURL)
                if fetched > 0 {
                    total += fetched
                    hasAnyPartSize = true
                }
            }

            if hasAnyPartSize {
                return total
            }
        }

        return try await fetchSize(quant.downloadURL)
    }

    private func fetchRecord(id: String) async throws -> ModelRecord? {
        do {
            let details = try await details(for: id)
            let fmts = Set(details.quants.map { $0.format })
            return ModelRecord(id: id,
                              displayName: Self.prettyName(from: id),
                              publisher: "",
                              summary: details.summary,
                              hasInstallableQuant: !details.quants.isEmpty,
                              formats: fmts,
                              installed: false,
                              tags: nil,
                              pipeline_tag: nil)
        } catch { return nil }
    }

    private func data(from url: URL) async throws -> (Data, URLResponse) {
        print("[registry] GET \(url.absoluteString)")
        let (data, resp) = try await HFHubRequestManager.shared.data(for: url,
                                                                     token: token,
                                                                     accept: "application/json")
        if let http = resp as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            // Surface HTTP status code for easier debugging.
            print("[registry] HTTP \(http.statusCode) for \(url.path)")
            throw RegistryError.badStatus(http.statusCode)
        }
        return (data, resp)
    }


    private func fetchSize(_ url: URL) async throws -> Int64 {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "download" }) {
            items.append(URLQueryItem(name: "download", value: "1"))
        }
        comps.queryItems = items

        let (_, resp) = try await HFHubRequestManager.shared.data(for: comps.url!,
                                                                  token: token,
                                                                  method: "HEAD")
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

    static func requiredAuthor(for format: ModelFormat?) -> String? {
        guard format == .ane else { return nil }
        return aneAuthor
    }

    static func matchesAuthorConstraint(format: ModelFormat?, modelID: String, author: String?) -> Bool {
        guard let requiredAuthor = requiredAuthor(for: format) else { return true }
        let owner = modelID.split(separator: "/").first.map(String.init)
        if owner?.caseInsensitiveCompare(requiredAuthor) == .orderedSame {
            return true
        }
        return author?.caseInsensitiveCompare(requiredAuthor) == .orderedSame
    }

    private static func prettyName(from id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        var cleaned = base.replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)gguf", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)ggml", with: "", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }

    static func inferFormats(
        tags: [String],
        id: String,
        pipelineTag: String? = nil,
        forcedFormat: ModelFormat? = nil
    ) -> Set<ModelFormat> {
        var result: Set<ModelFormat> = []
        let lowerTags = tags.map { $0.lowercased() }
        let lowerID = id.lowercased()
        if lowerTags.contains(where: { $0.contains("gguf") || $0.contains("ggml") }) {
            result.insert(.gguf)
        }
        // Treat MLX explicitly tagged repositories as MLX, and also include
        // the canonical MLX conversion namespace. Do not infer MLX from
        // GGUF-heavy publisher namespaces alone.
        if lowerTags.contains(where: { $0.contains("mlx") })
            || lowerID.hasPrefix("mlx-community/") {
            result.insert(.mlx)
        }
        if lowerTags.contains(where: { $0.contains("executorch") || $0.contains("pte") }) {
            result.insert(.et)
        }
        if lowerTags.contains(where: {
            $0.contains("coreml")
                || $0.contains("core-ml")
                || $0.contains("mlmodel")
                || $0.contains("ane")
        }) || lowerID.contains("coreml") {
            result.insert(.ane)
        }
        if lowerTags.contains(where: { $0 == "coreai" || $0 == "aimodel" })
            || lowerID.contains("coreai") {
            result.insert(.coreai)
        }
        if let forcedFormat {
            result.insert(forcedFormat)
        }
        return result
    }

    private static func inferSupportsVision(tags: [String], pipelineTag: String?) -> Bool {
        let lowerTags = tags.map { $0.lowercased() }
        if pipelineTag?.lowercased() == "image-text-to-text" { return true }
        return lowerTags.contains(where: { tag in
            tag.contains("vision")
                || tag.contains("vlm")
                || tag.contains("multimodal")
                || tag.contains("image-text-to-text")
        })
    }

}
