import Foundation

enum SensitiveDataKind: String, CaseIterable, Codable, Equatable, Sendable {
    case emailAddress
    case phoneNumber
    case socialSecurityNumber
    case creditCardNumber
    case postalAddress
    case identityNumber
    case apiKey
    case password

    var logLabel: String {
        switch self {
        case .emailAddress: return "email"
        case .phoneNumber: return "phone"
        case .socialSecurityNumber: return "ssn"
        case .creditCardNumber: return "credit_card"
        case .postalAddress: return "address"
        case .identityNumber: return "id_number"
        case .apiKey: return "api_key"
        case .password: return "password"
        }
    }
}

struct SensitiveDataFinding: Codable, Equatable, Sendable {
    let kind: SensitiveDataKind
    let count: Int
}

struct SensitiveDataScanSummary: Codable, Equatable, Sendable {
    let findings: [SensitiveDataFinding]

    var isEmpty: Bool {
        findings.isEmpty
    }

    var totalCount: Int {
        findings.reduce(0) { $0 + $1.count }
    }

    var logSummary: String {
        guard !findings.isEmpty else { return "none" }
        return findings
            .map { "\($0.kind.logLabel)=\($0.count)" }
            .joined(separator: ",")
    }
}

struct SensitiveDataRemoteRedactionResult: Equatable, Sendable {
    let text: String
    let summary: SensitiveDataScanSummary
    let redacted: Bool
}

enum SensitiveDataDetector {
    private struct Rule: Sendable {
        let kind: SensitiveDataKind
        let pattern: String
        var validator: (@Sendable (String) -> Bool)? = nil
    }

    private static let rules: [Rule] = [
        Rule(
            kind: .emailAddress,
            pattern: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#
        ),
        Rule(
            kind: .phoneNumber,
            pattern: #"\b(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b"#
        ),
        Rule(
            kind: .socialSecurityNumber,
            pattern: #"\b\d{3}-\d{2}-\d{4}\b"#
        ),
        Rule(
            kind: .creditCardNumber,
            pattern: #"\b(?:\d[ -]?){13,19}\b"#,
            validator: looksLikePaymentCard(_:)
        ),
        Rule(
            kind: .postalAddress,
            pattern: #"\b\d{1,6}\s+[A-Za-z0-9.'-]+(?:\s+[A-Za-z0-9.'-]+){0,5}\s+(?:Street|St\.?|Avenue|Ave\.?|Road|Rd\.?|Drive|Dr\.?|Lane|Ln\.?|Boulevard|Blvd\.?|Court|Ct\.?|Way|Place|Pl\.?)\b"#
        ),
        Rule(
            kind: .identityNumber,
            pattern: #"(?i)\b(?:passport|driver'?s?\s+license|id\s*(?:number|#)|employee\s*id|account\s*(?:number|#))\s*[:#=]?\s*[A-Z0-9-]{5,}\b"#
        ),
        Rule(
            kind: .apiKey,
            pattern: #"(?i)\b(?:sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9_]{20,}|api[_-]?key\s*[:=]\s*["']?[A-Za-z0-9_\-.]{16,})"#
        ),
        Rule(
            kind: .password,
            pattern: #"(?i)\b(?:password|passcode|secret)\s*[:=]\s*["']?[^\s"',}]{6,}"#
        )
    ]

    static func scan(_ text: String) -> SensitiveDataScanSummary {
        guard !text.isEmpty else {
            return SensitiveDataScanSummary(findings: [])
        }

        var counts: [SensitiveDataKind: Int] = [:]
        for rule in rules {
            let matches = matchingStrings(pattern: rule.pattern, in: text)
            let accepted = rule.validator.map { validator in
                matches.filter(validator)
            } ?? matches
            if !accepted.isEmpty {
                counts[rule.kind, default: 0] += accepted.count
            }
        }

        let findings = SensitiveDataKind.allCases.compactMap { kind -> SensitiveDataFinding? in
            guard let count = counts[kind], count > 0 else { return nil }
            return SensitiveDataFinding(kind: kind, count: count)
        }
        return SensitiveDataScanSummary(findings: findings)
    }

    static func redactedForRemotePreview(_ text: String) -> String {
        var redacted = text
        for rule in rules {
            redacted = replaceMatches(pattern: rule.pattern, in: redacted, replacement: "<\(rule.kind.logLabel)>")
        }
        return redacted
    }

    static func redactedForRemote(_ text: String, enabled: Bool) -> SensitiveDataRemoteRedactionResult {
        let summary = scan(text)
        guard enabled, !summary.isEmpty else {
            return SensitiveDataRemoteRedactionResult(text: text, summary: summary, redacted: false)
        }
        let redacted = redactedForRemotePreview(text)
        return SensitiveDataRemoteRedactionResult(text: redacted, summary: summary, redacted: redacted != text)
    }

    private static func matchingStrings(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func replaceMatches(pattern: String, in text: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private static func looksLikePaymentCard(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        var shouldDouble = false
        for digit in digits.reversed() {
            guard var number = digit.wholeNumberValue else { return false }
            if shouldDouble {
                number *= 2
                if number > 9 { number -= 9 }
            }
            sum += number
            shouldDouble.toggle()
        }
        return sum % 10 == 0
    }
}
