import Foundation

struct SourceConflict: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case numeric
        case date
        case state
    }

    struct Evidence: Equatable, Sendable {
        let value: String
        let sourceName: String
        let excerpt: String
    }

    let kind: Kind
    let claimKey: String
    let evidence: [Evidence]

    var uniqueValues: [String] {
        Array(Set(evidence.map(\.value))).sorted()
    }

    var sourceNames: [String] {
        Array(Set(evidence.map(\.sourceName))).sorted()
    }
}

struct SourceSnippet: Equatable, Sendable {
    let id: String
    let sourceName: String
    let text: String

    init(id: String, sourceName: String?, text: String) {
        self.id = id
        self.sourceName = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? sourceName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : String(localized: "Unknown Source")
        self.text = text
    }
}

enum ConflictingSourceDetector {
    private struct Claim: Equatable {
        let kind: SourceConflict.Kind
        let key: String
        let value: String
        let unit: String?
        let sourceName: String
        let excerpt: String

        var groupKey: String {
            [kind.rawValue, key, unit ?? ""].joined(separator: "|")
        }
    }

    static func detect(in snippets: [SourceSnippet]) -> [SourceConflict] {
        let claims = snippets.flatMap(claims(in:))
        let grouped = Dictionary(grouping: claims, by: \.groupKey)
        return grouped.values.compactMap(conflict(from:)).sorted { lhs, rhs in
            if lhs.kind.rawValue == rhs.kind.rawValue {
                return lhs.claimKey < rhs.claimKey
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private static func conflict(from claims: [Claim]) -> SourceConflict? {
        let uniqueValues = Set(claims.map(\.value))
        let sourceNames = Set(claims.map(\.sourceName))
        guard uniqueValues.count > 1, sourceNames.count > 1, let first = claims.first else {
            return nil
        }
        let evidence = claims
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.sourceName < rhs.sourceName }
                return lhs.value < rhs.value
            }
            .map {
                SourceConflict.Evidence(
                    value: $0.value,
                    sourceName: $0.sourceName,
                    excerpt: $0.excerpt
                )
            }
        return SourceConflict(kind: first.kind, claimKey: first.key, evidence: evidence)
    }

    private static func claims(in snippet: SourceSnippet) -> [Claim] {
        sentenceCandidates(from: snippet.text).flatMap { sentence in
            numericClaims(in: sentence, sourceName: snippet.sourceName)
                + dateClaims(in: sentence, sourceName: snippet.sourceName)
                + stateClaims(in: sentence, sourceName: snippet.sourceName)
        }
    }

    private static func numericClaims(in sentence: String, sourceName: String) -> [Claim] {
        matches(
            pattern: #"(?i)\b(.{3,70}?)\s+(?:is|was|are|were|equals|=|:)\s*([0-9]+(?:\.[0-9]+)?)\s*([a-z%]{1,16})?\b"#,
            in: sentence
        ).compactMap { match in
            guard let rawKey = match[safe: 1],
                  let rawValue = match[safe: 2] else {
                return nil
            }
            let key = normalizedClaimKey(rawKey)
            guard key.count >= 3 else { return nil }
            let value = normalizedNumber(rawValue)
            let unit = normalizedUnit(match[safe: 3])
            return Claim(
                kind: .numeric,
                key: key,
                value: unit.map { "\(value) \($0)" } ?? value,
                unit: unit,
                sourceName: sourceName,
                excerpt: clipped(sentence)
            )
        }
    }

    private static func dateClaims(in sentence: String, sourceName: String) -> [Claim] {
        matches(
            pattern: #"(?i)\b(.{3,70}?)\s+(?:is|was|on|dated|date:)\s*((?:[0-9]{4}-[0-9]{2}-[0-9]{2})|(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s+[0-9]{1,2},\s+[0-9]{4}))\b"#,
            in: sentence
        ).compactMap { match in
            guard let rawKey = match[safe: 1],
                  let rawValue = match[safe: 2] else {
                return nil
            }
            let key = normalizedClaimKey(rawKey)
            guard key.count >= 3 else { return nil }
            return Claim(
                kind: .date,
                key: key,
                value: rawValue.lowercased(),
                unit: nil,
                sourceName: sourceName,
                excerpt: clipped(sentence)
            )
        }
    }

    private static func stateClaims(in sentence: String, sourceName: String) -> [Claim] {
        var claims: [Claim] = []
        for match in matches(pattern: #"(?i)\b(.{3,70}?)\s+does\s+not\s+support\s+(.{3,60})\b"#, in: sentence) {
            guard let subject = match[safe: 1], let object = match[safe: 2] else { continue }
            let key = "\(normalizedClaimKey(subject)) supports \(normalizedObject(object))"
            if key.count >= 8 {
                claims.append(Claim(kind: .state, key: key, value: "no", unit: nil, sourceName: sourceName, excerpt: clipped(sentence)))
            }
        }
        for match in matches(pattern: #"(?i)\b(.{3,70}?)\s+supports\s+(.{3,60})\b"#, in: sentence) {
            guard let subject = match[safe: 1], let object = match[safe: 2] else { continue }
            let key = "\(normalizedClaimKey(subject)) supports \(normalizedObject(object))"
            if key.count >= 8 {
                claims.append(Claim(kind: .state, key: key, value: "yes", unit: nil, sourceName: sourceName, excerpt: clipped(sentence)))
            }
        }
        for match in matches(pattern: #"(?i)\b(.{3,70}?)\s+is\s+(enabled|disabled|available|unavailable|supported|unsupported|required|optional)\b"#, in: sentence) {
            guard let subject = match[safe: 1], let value = match[safe: 2] else { continue }
            let key = "\(normalizedClaimKey(subject)) state"
            if key.count >= 8 {
                claims.append(Claim(kind: .state, key: key, value: value.lowercased(), unit: nil, sourceName: sourceName, excerpt: clipped(sentence)))
            }
        }
        return claims
    }

    private static func sentenceCandidates(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\n", with: ". ")
            .split(whereSeparator: { ".;!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
    }

    private static func matches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { result in
            (0..<result.numberOfRanges).map { index in
                guard let range = Range(result.range(at: index), in: text) else { return "" }
                return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private static func normalizedClaimKey(_ value: String) -> String {
        let cleaned = value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 /_-]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { !["the", "a", "an", "this", "that", "source", "document"].contains($0) }
        return cleaned.suffix(5).joined(separator: " ")
    }

    private static func normalizedObject(_ value: String) -> String {
        normalizedClaimKey(value)
    }

    private static func normalizedNumber(_ value: String) -> String {
        guard let number = Double(value) else { return value }
        if number.rounded() == number {
            return String(Int64(number))
        }
        return String(format: "%.4f", number).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    private static func normalizedUnit(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func clipped(_ value: String, limit: Int = 160) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "\(trimmed.prefix(limit))..."
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
