import Foundation

enum DiagnosticLogRedactor {
    private static let maxLineCharacters = 700

    private static let sensitiveMarkers = [
        "[ChatVM][SendAttempt] ",
        "[ChatVM] USER ▶︎ ",
        "[ChatVM] Tool-enabled message request: ",
        "[Llama][Prompt] ",
        "[Llama][Result] ",
        "[Tool] TOOL_CALL detected: ",
        "[Tool] Invoking ",
        "[Tool] Dry-run recorded ",
        "[Tool] Result from ",
        "[Remote][Tool]",
        "Body: "
    ]

    static func recentLogPayload(from url: URL, maxLines: Int = 120) -> [String: Any] {
        let lines = readLines(from: url)
        let boundedMax = max(1, maxLines)
        let omittedLineCount = max(0, lines.count - boundedMax)
        let recentLines = Array(lines.suffix(boundedMax))
        return [
            "sourceFile": url.lastPathComponent,
            "maxLines": boundedMax,
            "omittedLineCount": omittedLineCount,
            "lines": recentLines.map(redactLine(_:))
        ]
    }

    static func redactLine(_ line: String) -> String {
        var sanitized = line
        for marker in sensitiveMarkers {
            if let range = sanitized.range(of: marker) {
                let prefix = sanitized[..<range.upperBound]
                let sensitive = sanitized[range.upperBound...]
                sanitized = "\(prefix)\(redactedSummary(for: String(sensitive)))"
                break
            }
        }
        sanitized = redactCommonSecrets(in: sanitized)
        if sanitized.count > maxLineCharacters {
            let prefix = sanitized.prefix(maxLineCharacters)
            return "\(prefix)... <truncated len=\(sanitized.count)>"
        }
        return sanitized
    }

    private static func readLines(from url: URL) -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private static func redactedSummary(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<redacted chars=\(trimmed.count) hash=\(privacyHash(trimmed))>"
    }

    private static func redactCommonSecrets(in line: String) -> String {
        var sanitized = line
        sanitized = replaceMatches(
            in: sanitized,
            pattern: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            replacement: "<redacted-email>"
        )
        sanitized = replaceMatches(
            in: sanitized,
            pattern: #"\b(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b"#,
            replacement: "<redacted-phone>"
        )
        sanitized = replaceMatches(
            in: sanitized,
            pattern: #"(?i)(authorization|api[-_ ]?key|token|password|secret)(["']?\s*[:=]\s*["']?)[^"',\s}]+"#,
            replacement: "$1$2<redacted-secret>"
        )
        return sanitized
    }

    private static func replaceMatches(in value: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }

    private static func privacyHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
