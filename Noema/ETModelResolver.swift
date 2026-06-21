import Foundation

enum ETModelResolver {
    static let sourceRepoFilename = "source_repo.txt"
    static let legacyRepoFilename = "repo.txt"
    static let tokenizerFileNames = [
        "tokenizer.json",
        "tokenizer.model",
        "spiece.model",
        "sentencepiece.bpe.model"
    ]
    static let sidecarFileNames = [
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "vocab.json",
        "vocab.txt",
        "merges.txt",
        "config.json",
        "generation_config.json",
        "chat_template.json",
        "chat_template.jinja",
        "tokenizer.model",
        "spiece.model",
        "sentencepiece.bpe.model"
    ]

    struct LoadArtifacts {
        let pteURL: URL
        let tokenizerURL: URL
        let modelDirectory: URL
    }

    struct ArtifactDiagnostic: Error, LocalizedError {
        enum Reason: Equatable {
            case missingPTE
            case invalidPTE(String)
            case missingTokenizer
            case invalidTokenizer(String)
        }

        let reason: Reason
        let modelDirectory: URL
        let searchedPaths: [String]
        let sourceRepoID: String?

        var isRepairable: Bool {
            switch reason {
            case .missingTokenizer, .invalidTokenizer:
                return true
            case .missingPTE, .invalidPTE:
                return false
            }
        }

        var errorDescription: String? {
            switch reason {
            case .missingPTE:
                return String(localized: "No .pte program found for ET model.")
            case .invalidPTE(let detail):
                return String(
                    format: String(localized: "The ET model program is not usable: %@"),
                    detail
                )
            case .missingTokenizer:
                return String(localized: "Tokenizer file not found for ET model.")
            case .invalidTokenizer(let detail):
                return String(
                    format: String(localized: "The ET tokenizer is not usable: %@"),
                    detail
                )
            }
        }

        var recoverySuggestion: String? {
            guard isRepairable else { return nil }
            if let sourceRepoID, !sourceRepoID.isEmpty {
                return String(
                    format: String(localized: "Tap Repair to download the missing ET tokenizer files from %@."),
                    sourceRepoID
                )
            }
            return String(localized: "Tap Repair to download the missing ET tokenizer files, or reinstall the model if repair is unavailable.")
        }

        var userFacingMessage: String {
            let base = errorDescription ?? String(localized: "ET model files are incomplete.")
            guard let recoverySuggestion else { return base }
            return "\(base) \(recoverySuggestion)"
        }
    }

    static func pteURL(for url: URL) -> URL? {
        let fixed = url.resolvingSymlinksInPath().standardizedFileURL
        if fixed.pathExtension.lowercased() == "pte" {
            return fixed
        }
        return firstMatchingFile(in: fixed, extensions: ["pte"])
    }

    static func tokenizerURL(for url: URL) -> URL? {
        let fixed = url.resolvingSymlinksInPath().standardizedFileURL
        if fixed.lastPathComponent.lowercased() == "tokenizer.json" {
            return fixed
        }
        return firstMatchingFile(
            in: fixed,
            names: tokenizerFileNames
        )
    }

    static func tokenizerConfigURL(for url: URL) -> URL? {
        let fixed = url.resolvingSymlinksInPath().standardizedFileURL
        if fixed.lastPathComponent.lowercased() == "tokenizer_config.json" {
            return fixed
        }
        return firstMatchingFile(in: fixed, names: ["tokenizer_config.json"])
    }

    static func hasPTEArtifact(at url: URL) -> Bool {
        pteURL(for: url) != nil
    }

    static func modelDirectory(for url: URL) -> URL {
        let fixed = url.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fixed.path, isDirectory: &isDir), isDir.boolValue {
            return fixed
        }
        if fixed.pathExtension.lowercased() == "pte" {
            return fixed.deletingLastPathComponent()
        }
        return fixed.deletingLastPathComponent()
    }

    static func sourceRepoID(in directory: URL) -> String? {
        for filename in [sourceRepoFilename, legacyRepoFilename] {
            let file = directory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: file),
                  let value = String(data: data, encoding: .utf8) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func writeSourceRepoID(_ repoID: String, into directory: URL) {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(trimmed.utf8).write(to: directory.appendingPathComponent(sourceRepoFilename), options: .atomic)
    }

    static func resolveLoadArtifacts(for url: URL, settings: ModelSettings? = nil) throws -> LoadArtifacts {
        let input = url.resolvingSymlinksInPath().standardizedFileURL
        let searchRoot = modelDirectory(for: input)
        let sourceRepo = sourceRepoID(in: searchRoot)
        let searched = searchedArtifactPaths(in: input, includeTokenizer: true)

        guard let pte = pteURL(for: input) ?? pteURL(for: searchRoot) else {
            throw ArtifactDiagnostic(
                reason: .missingPTE,
                modelDirectory: searchRoot,
                searchedPaths: searched,
                sourceRepoID: sourceRepo
            )
        }

        if let invalid = invalidPTEReason(at: pte) {
            throw ArtifactDiagnostic(
                reason: .invalidPTE(invalid),
                modelDirectory: pte.deletingLastPathComponent(),
                searchedPaths: searched,
                sourceRepoID: sourceRepoID(in: pte.deletingLastPathComponent()) ?? sourceRepo
            )
        }

        let tokenizerCandidates = tokenizerCandidates(for: input, pteURL: pte, settings: settings)
        var invalidReasons: [String] = []
        for candidate in tokenizerCandidates {
            if let reason = invalidTokenizerReason(at: candidate) {
                invalidReasons.append("\(candidate.lastPathComponent): \(reason)")
                continue
            }
            return LoadArtifacts(
                pteURL: pte,
                tokenizerURL: candidate,
                modelDirectory: pte.deletingLastPathComponent()
            )
        }

        let effectiveRepo = sourceRepoID(in: pte.deletingLastPathComponent()) ?? sourceRepo
        if !invalidReasons.isEmpty {
            throw ArtifactDiagnostic(
                reason: .invalidTokenizer(invalidReasons.joined(separator: "; ")),
                modelDirectory: pte.deletingLastPathComponent(),
                searchedPaths: searched,
                sourceRepoID: effectiveRepo
            )
        }

        throw ArtifactDiagnostic(
            reason: .missingTokenizer,
            modelDirectory: pte.deletingLastPathComponent(),
            searchedPaths: searched,
            sourceRepoID: effectiveRepo
        )
    }

    private static func firstMatchingFile(in root: URL, names: [String] = [], extensions: [String] = []) -> URL? {
        let fm = FileManager.default
        let nameSet = Set(names.map { $0.lowercased() })
        let extSet = Set(extensions.map { $0.lowercased() })

        func matches(_ file: URL) -> Bool {
            let fileName = file.lastPathComponent.lowercased()
            if !nameSet.isEmpty, nameSet.contains(fileName) { return true }
            if !extSet.isEmpty, extSet.contains(file.pathExtension.lowercased()) { return true }
            return false
        }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDir), !isDir.boolValue {
            return matches(root) ? root : nil
        }

        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: preferredFileOrder) else {
            return nil
        }

        if let direct = files.first(where: { matches($0) }) {
            return direct
        }

        for entry in files {
            var subIsDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &subIsDir), subIsDir.boolValue else { continue }
            guard let subFiles = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil).sorted(by: preferredFileOrder) else { continue }
            if let subMatch = subFiles.first(where: { matches($0) }) {
                return subMatch
            }
        }

        return nil
    }

    private static func tokenizerCandidates(for input: URL, pteURL: URL, settings: ModelSettings?) -> [URL] {
        var candidates: [URL] = []
        func append(_ url: URL?) {
            guard let url else { return }
            let fixed = url.resolvingSymlinksInPath().standardizedFileURL
            if !candidates.contains(fixed) {
                candidates.append(fixed)
            }
        }

        if let explicit = settings?.tokenizerPath?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            append(URL(fileURLWithPath: explicit))
        }
        append(tokenizerURL(for: input))
        append(tokenizerURL(for: pteURL.deletingLastPathComponent()))
        append(tokenizerURL(for: pteURL))
        return candidates
    }

    private static func searchedArtifactPaths(in input: URL, includeTokenizer: Bool) -> [String] {
        let roots = [input, modelDirectory(for: input)]
        var values: [String] = []
        for root in roots {
            if !values.contains(root.path) { values.append(root.path) }
            guard includeTokenizer else { continue }
            for name in tokenizerFileNames {
                let path = root.appendingPathComponent(name).path
                if !values.contains(path) { values.append(path) }
            }
        }
        return values
    }

    private static func invalidPTEReason(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return String(localized: "file is missing")
        }
        guard fileSize(at: url) > 0 else {
            return String(localized: "file is empty")
        }
        if isGitLFSPointer(at: url) {
            return String(localized: "file is a Git LFS pointer, not the ExecuTorch program content")
        }
        return nil
    }

    static func invalidTokenizerReason(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return String(localized: "file is missing")
        }
        guard fileSize(at: url) > 0 else {
            return String(localized: "file is empty")
        }
        if isGitLFSPointer(at: url) {
            return String(localized: "file is a Git LFS pointer, not the tokenizer content")
        }
        if url.lastPathComponent.lowercased() == "tokenizer.json" {
            guard let data = try? Data(contentsOf: url),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return String(localized: "tokenizer.json is not valid JSON")
            }
        }
        return nil
    }

    private static func isGitLFSPointer(at url: URL) -> Bool {
        guard fileSize(at: url) <= 4096,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        let lower = text.lowercased()
        return lower.contains("git-lfs") || lower.contains("oid sha256:")
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    private static func preferredFileOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        func rank(_ url: URL) -> (Int, String) {
            let name = url.lastPathComponent.lowercased()
            if let index = tokenizerFileNames.firstIndex(of: name) {
                return (index, name)
            }
            if name == "model.pte" { return (-1, name) }
            return (Int.max, name)
        }
        let l = rank(lhs)
        let r = rank(rhs)
        if l.0 != r.0 { return l.0 < r.0 }
        return l.1 < r.1
    }
}
