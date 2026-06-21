import Foundation

struct DatasetIndexMetadata: Codable, Equatable, Sendable {
    enum SourceLabelMode: String, Codable, Equatable, Sendable {
        case relativePath
    }

    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let sourceLabelMode: SourceLabelMode
    let chunkCount: Int
    let embeddingFingerprint: EmbeddingIndexFingerprint?
    let createdAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sourceLabelMode: SourceLabelMode = .relativePath,
        chunkCount: Int,
        embeddingFingerprint: EmbeddingIndexFingerprint? = EmbeddingModelCatalog.currentIndexFingerprint(),
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.sourceLabelMode = sourceLabelMode
        self.chunkCount = chunkCount
        self.embeddingFingerprint = embeddingFingerprint
        self.createdAt = createdAt
    }

    var isValidReadyIndex: Bool {
        isValidReadyIndex(expectedFingerprint: EmbeddingModelCatalog.currentIndexFingerprint())
    }

    func isValidReadyIndex(expectedFingerprint: EmbeddingIndexFingerprint) -> Bool {
        schemaVersion == Self.currentSchemaVersion &&
        sourceLabelMode == .relativePath &&
        chunkCount > 0 &&
        embeddingFingerprint == expectedFingerprint
    }
}

struct DatasetIndexReport: Codable, Equatable, Sendable {
    var processedFiles: [String]
    var skippedFiles: [String]
    var emptyFiles: [String]
    var failureReason: String?

    static var empty: DatasetIndexReport {
        DatasetIndexReport(
            processedFiles: [],
            skippedFiles: [],
            emptyFiles: [],
            failureReason: nil
        )
    }
}

enum DatasetStorage {
    static let vectorsFilename = "vectors.json"
    static let metadataFilename = "index_metadata.json"
    static let reportFilename = "index_report.json"
    static let extractedFilename = "extracted.txt"
    static let compactFilename = "extracted.compact.txt"
    static let titleFilename = "title.txt"
    /// Legacy artifact from the removed source-reliability feature. No longer
    /// written; kept in `internalFilenames` so pre-existing files stay hidden.
    static let sourceReliabilityFilename = "source_reliability.json"
    /// Noema Teams dataset manifest. Governance metadata only — must never be
    /// indexed, retrieved, or surfaced as dataset content to the model.
    static let enterpriseManifestFilename = ".enterprise-manifest.json"
    static let transcriptMetadataDirectoryName = "Transcript Metadata"

    static let internalFilenames: Set<String> = [
        vectorsFilename,
        metadataFilename,
        reportFilename,
        extractedFilename,
        compactFilename,
        titleFilename,
        sourceReliabilityFilename,
        enterpriseManifestFilename,
    ]

    static func isInternalRelativePath(_ relativePath: String) -> Bool {
        let normalized = DatasetPathing.normalizeRelativePath(relativePath)
        return internalFilenames.contains(normalized)
            || normalized.hasPrefix(transcriptMetadataDirectoryName + "/")
    }
}

/// Shared `<<<FILE: path>>>` source-marker format used by the extracted/compact
/// dataset text artifacts to attribute content to its originating file.
enum DatasetSourceMarkers {
    static let prefix = "<<<FILE: "
    static let suffix = ">>>"

    static func marker(forRelativePath relativePath: String) -> String {
        prefix + relativePath + suffix
    }

    /// Parses a (whitespace-trimmed) line and returns the relative path when it
    /// is a source marker.
    static func sourcePath(fromLine line: String) -> String? {
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        let end = line.index(line.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        let raw = String(line[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Drops sections attributed to internal artifacts (index files, the Noema
    /// Teams governance manifest, …) from extracted/compact dataset text.
    /// Artifacts written before a filename became internal can still carry such
    /// sections, so prepared text must pass through here before reaching the model.
    static func strippingInternalSections(from text: String) -> String {
        guard text.contains(prefix) else { return text }
        var kept: [Substring] = []
        var skipping = false
        var dropped = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let source = sourcePath(fromLine: line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                skipping = DatasetStorage.isInternalRelativePath(source)
                if skipping {
                    dropped = true
                    continue
                }
            } else if skipping {
                continue
            }
            kept.append(line)
        }
        return dropped ? kept.joined(separator: "\n") : text
    }
}

enum DatasetIndexIO {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private struct StoredVectorProbe: Decodable {
        let vector: [Float]
    }

    static func vectorsURL(for datasetURL: URL) -> URL {
        datasetURL.appendingPathComponent(DatasetStorage.vectorsFilename)
    }

    static func metadataURL(for datasetURL: URL) -> URL {
        datasetURL.appendingPathComponent(DatasetStorage.metadataFilename)
    }

    static func reportURL(for datasetURL: URL) -> URL {
        datasetURL.appendingPathComponent(DatasetStorage.reportFilename)
    }

    static func extractedURL(for datasetURL: URL) -> URL {
        datasetURL.appendingPathComponent(DatasetStorage.extractedFilename)
    }

    static func compactURL(for datasetURL: URL) -> URL {
        datasetURL.appendingPathComponent(DatasetStorage.compactFilename)
    }

    static func titleURL(for datasetURL: URL) -> URL {
        datasetURL.appendingPathComponent(DatasetStorage.titleFilename)
    }

    static func transcriptMetadataDirectoryURL(for datasetURL: URL) -> URL {
        datasetURL.appendingPathComponent(DatasetStorage.transcriptMetadataDirectoryName, isDirectory: true)
    }

    static func loadMetadata(from datasetURL: URL) -> DatasetIndexMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: datasetURL)) else { return nil }
        return try? decoder.decode(DatasetIndexMetadata.self, from: data)
    }

    static func loadReport(from datasetURL: URL) -> DatasetIndexReport? {
        guard let data = try? Data(contentsOf: reportURL(for: datasetURL)) else { return nil }
        return try? decoder.decode(DatasetIndexReport.self, from: data)
    }

    static func hasValidIndex(at datasetURL: URL) -> Bool {
        hasValidIndex(at: datasetURL, expectedFingerprint: EmbeddingModelCatalog.currentIndexFingerprint())
    }

    static func hasValidIndex(
        at datasetURL: URL,
        expectedFingerprint: EmbeddingIndexFingerprint
    ) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vectorsURL(for: datasetURL).path),
              let metadata = loadMetadata(from: datasetURL) else {
            return false
        }
        guard metadata.isValidReadyIndex(expectedFingerprint: expectedFingerprint) else {
            return false
        }
        if let dimension = firstVectorDimension(at: datasetURL) {
            return dimension == expectedFingerprint.dimension
        }
        return false
    }

    static func hasIndexArtifacts(at datasetURL: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: vectorsURL(for: datasetURL).path) ||
            fm.fileExists(atPath: metadataURL(for: datasetURL).path)
    }

    static func writeMetadata(_ metadata: DatasetIndexMetadata, to datasetURL: URL) {
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: metadataURL(for: datasetURL), options: .atomic)
    }

    static func firstVectorDimension(at datasetURL: URL) -> Int? {
        guard let data = try? Data(contentsOf: vectorsURL(for: datasetURL)),
              let decoded = try? decoder.decode([StoredVectorProbe].self, from: data),
              let first = decoded.first else {
            return nil
        }
        return first.vector.count
    }

    static func writeReport(_ report: DatasetIndexReport, to datasetURL: URL) {
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: reportURL(for: datasetURL), options: .atomic)
    }

    static func clearReadyIndex(at datasetURL: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: vectorsURL(for: datasetURL))
        try? fm.removeItem(at: metadataURL(for: datasetURL))
    }
}

enum DatasetPathing {
    static func normalizeRelativePath(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { component in
                component != "." && component != ".."
            }
            .map(String.init)
            .joined(separator: "/")
    }

    static func relativePath(for fileURL: URL, under rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            let normalized = normalizeRelativePath(relative)
            if !normalized.isEmpty {
                return normalized
            }
        }

        let normalized = normalizeRelativePath(fileURL.lastPathComponent)
        return normalized.isEmpty ? "file" : normalized
    }

    static func uniqueRelativePath(_ proposedPath: String, existing: Set<String>) -> String {
        let normalized = normalizeRelativePath(proposedPath)
        let initial = normalized.isEmpty ? "file" : normalized
        let used = Set(existing.map { $0.lowercased() })
        if !used.contains(initial.lowercased()) {
            return initial
        }

        let nsPath = initial as NSString
        let directory = nsPath.deletingLastPathComponent == "." ? "" : nsPath.deletingLastPathComponent
        let filename = nsPath.lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        var suffix = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
            let candidate = directory.isEmpty ? candidateName : directory + "/" + candidateName
            if !used.contains(candidate.lowercased()) {
                return candidate
            }
            suffix += 1
        }
    }

    static func destinationURL(for relativePath: String, in baseURL: URL) -> URL {
        let normalized = normalizeRelativePath(relativePath)
        guard !normalized.isEmpty else { return baseURL.appendingPathComponent("file") }

        var url = baseURL
        for component in normalized.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }

    static func durableArtifactID(forDatasetRelativePath relativePath: String) -> String {
        let normalized = normalizeRelativePath(relativePath)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let escaped = normalized.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? normalized.replacingOccurrences(of: "/", with: "_")
        return "dataset:\(escaped)"
    }
}

enum DatasetTextReader {
    static let encodings: [String.Encoding] = [
        .utf8,
        .isoLatin1,
        .windowsCP1252,
        .utf16,
        .utf32,
    ]

    static func readString(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return string(from: data)
    }

    static func string(from data: Data) -> String? {
        for encoding in encodings {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }
        return nil
    }
}

enum DatasetFileSupport {
    static let supportedExtensions: Set<String> = [
        "pdf",
        "epub",
        "txt",
        "md",
        "json",
        "jsonl",
        "csv",
        "tsv",
    ]

    static func fileExtension(name: String, downloadURL: URL) -> String {
        let nameExt = URL(fileURLWithPath: name).pathExtension.lowercased()
        if !nameExt.isEmpty {
            return nameExt
        }
        return downloadURL.pathExtension.lowercased()
    }

    static func isSupported(name: String, downloadURL: URL) -> Bool {
        supportedExtensions.contains(fileExtension(name: name, downloadURL: downloadURL))
    }

    static func isSupported(_ file: DatasetFile) -> Bool {
        isSupported(name: file.name, downloadURL: file.downloadURL)
    }

    static func totalSupportedSize(files: [DatasetFile]) -> Int64 {
        files.reduce(0) { partial, file in
            partial + (isSupported(file) ? max(0, file.sizeBytes) : 0)
        }
    }
}

struct DatasetRetrievalCandidate<Payload> {
    let score: Float
    let source: String?
    let payload: Payload
}

enum DatasetRetrievalRanker {
    static func select<Payload>(
        _ candidates: [DatasetRetrievalCandidate<Payload>],
        maxChunks: Int,
        minScore: Float
    ) -> [DatasetRetrievalCandidate<Payload>] {
        guard maxChunks > 0, !candidates.isEmpty else { return [] }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return (lhs.source ?? "") < (rhs.source ?? "")
            }
            return lhs.score > rhs.score
        }

        // Prefer passages at or above the similarity floor. If none clear it,
        // gracefully fall back to the best-scoring passages so a `maxChunks = N`
        // request still returns up to N chunks instead of collapsing to one.
        let aboveThreshold = sorted.filter { $0.score >= minScore }
        let pool = aboveThreshold.isEmpty ? sorted : aboveThreshold

        var selected: [DatasetRetrievalCandidate<Payload>] = []
        var usedSources = Set<String>()
        var usedIndices = Set<Int>()

        // First pass: one chunk per distinct source to maximize coverage.
        for (index, candidate) in pool.enumerated() {
            if selected.count >= maxChunks { break }
            let key = candidate.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "<unknown>"
            if usedSources.insert(key).inserted {
                selected.append(candidate)
                usedIndices.insert(index)
            }
        }

        // Second pass: backfill remaining slots (e.g. single-source datasets)
        // with the next best-scoring chunks until we reach maxChunks.
        if selected.count < maxChunks {
            for (index, candidate) in pool.enumerated() where !usedIndices.contains(index) {
                selected.append(candidate)
                if selected.count >= maxChunks { break }
            }
        }

        return selected
    }
}
