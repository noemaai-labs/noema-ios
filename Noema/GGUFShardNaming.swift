import Foundation

enum GGUFShardNaming {
    struct SplitInfo: Hashable, Sendable {
        let baseStem: String
        let partIndex: Int
        let partCount: Int
        let indexDigits: Int
        let countDigits: Int
    }

    /// Parses split GGUF filenames like `Model-Q4_K_M-00001-of-00004.gguf`.
    static func parseSplitFilename(_ filename: String) -> SplitInfo? {
        let name = (filename as NSString).lastPathComponent
        let pattern = #"(?i)^(.*)-(\d+)-of-(\d+)\.gguf$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, options: [], range: nsRange),
              match.numberOfRanges == 4,
              let stemRange = Range(match.range(at: 1), in: name),
              let idxRange = Range(match.range(at: 2), in: name),
              let cntRange = Range(match.range(at: 3), in: name) else {
            return nil
        }

        let baseStem = String(name[stemRange])
        let idxText = String(name[idxRange])
        let cntText = String(name[cntRange])
        guard let partIndex = Int(idxText),
              let partCount = Int(cntText),
              partIndex > 0,
              partCount > 1 else {
            return nil
        }

        return SplitInfo(
            baseStem: baseStem,
            partIndex: partIndex,
            partCount: partCount,
            indexDigits: idxText.count,
            countDigits: cntText.count
        )
    }

    static func parseSplitPath(_ path: String) -> SplitInfo? {
        parseSplitFilename((path as NSString).lastPathComponent)
    }

    static func strippedShardPath(_ path: String) -> String {
        let ns = path as NSString
        let filename = ns.lastPathComponent
        guard let split = parseSplitFilename(filename) else { return path }
        let replacement = split.baseStem + ".gguf"
        let dir = ns.deletingLastPathComponent
        if dir.isEmpty || dir == "." {
            return replacement
        }
        return (dir as NSString).appendingPathComponent(replacement)
    }

    /// Stable grouping key for split GGUF files; includes directory path to avoid cross-folder collisions.
    static func splitGroupKey(forPath path: String) -> String? {
        guard let split = parseSplitPath(path) else { return nil }
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent.lowercased()
        return "\(dir)|\(split.baseStem.lowercased())"
    }

    static func isShardFilename(_ filename: String) -> Bool {
        parseSplitFilename(filename) != nil
    }

    static func isShardPath(_ path: String) -> Bool {
        parseSplitPath(path) != nil
    }

    static func isShardPartOne(_ url: URL) -> Bool {
        guard let split = parseSplitFilename(url.lastPathComponent) else { return false }
        return split.partIndex == 1
    }

    static func normalizedQuantLabel(for path: String, repoID: String?) -> String {
        // Normalize split filenames before extraction so shard suffixes never leak into labels.
        var base = strippedShardPath(path)
        if let repoID,
           let repoName = repoID.split(separator: "/").last.map(String.init),
           base.lowercased().hasPrefix(repoName.lowercased()) {
            base = String(base.dropFirst(repoName.count))
        }

        if base.lowercased().hasSuffix(".gguf") {
            base = String(base.dropLast(".gguf".count))
        }

        var working = base.replacingOccurrences(of: "[\\-\\./]", with: "_", options: .regularExpression)
        working = working.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))

        // Prefer explicit / richer quant tokens first.
        let patterns = [
            #"(?i)(?:^|_)(ud_(?:iq\d+|q\d+|tq\d+)(?:_(?:k|m|s|l|xl|xs|xxs|nl|[01]))*)(?:_|$)"#,
            #"(?i)(?:^|_)(mxfp\d+(?:_moe)?)(?:_|$)"#,
            #"(?i)(?:^|_)(pq\d+(?:_[a-z0-9]+)*)(?:_|$)"#,
            #"(?i)(?:^|_)(tq\d+(?:_[01])?)(?:_|$)"#,
            #"(?i)(?:^|_)(iq\d+(?:_(?:k|m|s|l|xl|xs|xxs|nl|[01]))*)(?:_|$)"#,
            #"(?i)(?:^|_)(q\d+(?:_(?:k|m|s|l|xl|xs|xxs|nl|[01]))*)(?:_|$)"#,
            #"(?i)(?:^|_)(bf16|f16|f32)(?:_|$)"#
        ]

        for pattern in patterns {
            if let token = lastRegexMatch(in: working, pattern: pattern) {
                return token.uppercased()
            }
        }

        // Final fallback: cleaned file path (still stable across split shards due to strippedShardPath).
        return working.uppercased()
    }

    private static func lastRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: full)
        guard let m = matches.last else { return nil }
        let rangeIndex = m.numberOfRanges > 1 ? 1 : 0
        guard let r = Range(m.range(at: rangeIndex), in: text) else { return nil }
        return String(text[r])
    }
}
