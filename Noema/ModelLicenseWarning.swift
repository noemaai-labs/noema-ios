import Foundation

enum ModelLicenseWarningLevel: String, Codable, Equatable, Sendable {
    case permissive
    case review
    case restricted
    case unknown

    var requiresDownloadConfirmation: Bool {
        switch self {
        case .restricted, .unknown:
            return true
        case .permissive, .review:
            return false
        }
    }
}

enum ModelLicenseWarningPolicy {
    static func level(for rawLicenseLabel: String?) -> ModelLicenseWarningLevel {
        let normalized = normalize(rawLicenseLabel)
        guard !normalized.isEmpty else { return .unknown }

        if containsAny(normalized, ["unknown", "unspecified", "no license", "proprietary"]) {
            return .unknown
        }
        if containsAny(normalized, ["non commercial", "noncommercial", "nc", "research only", "cc by nc", "cc-by-nc"]) {
            return .restricted
        }
        if containsAny(normalized, ["llama", "gemma", "openrail", "rail", "custom", "community"]) {
            return .review
        }
        if containsAny(normalized, ["apache", "mit", "bsd", "isc", "cc by", "cc-by", "public domain", "unlicense"]) {
            return .permissive
        }
        return .review
    }

    private static func normalize(_ label: String?) -> String {
        (label ?? "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func containsAny(_ normalized: String, _ needles: [String]) -> Bool {
        needles.contains { normalized.contains($0) }
    }
}

extension EmbeddingModelRecord {
    var licenseWarningLevel: ModelLicenseWarningLevel {
        ModelLicenseWarningPolicy.level(for: licenseLabel)
    }
}
