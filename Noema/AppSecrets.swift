import Foundation

/// Centralizes access to secrets that are supplied via `Secrets.plist`
/// (kept locally and ignored by git) or environment variables when running
/// from the command line.
enum AppSecrets {
    enum SecretError: LocalizedError {
        case missing(Key)
        case invalidURL(Key)

        var errorDescription: String? {
            switch self {
            case .missing(let key):
                return "Missing secret for key \(key.rawValue)."
            case .invalidURL(let key):
                return "Missing or invalid URL for key \(key.rawValue)."
            }
        }
    }

    enum Key: String {
        case searxngURL = "SearXNGURL"
        case searxngAPIKey = "SearXNGAPIKey"
        case teamsAPIURL = "TeamsAPIURL"
    }

    private static let secrets: [String: String]? = {
        guard let url = locateSecretsFile(),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: PropertyListSerialization.ReadOptions(), format: nil) as? [String: String] else {
            return nil
        }
        return plist
    }()

    private static func locateSecretsFile() -> URL? {
        let candidateBundles: [Bundle] = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in candidateBundles {
            if let url = bundle.url(forResource: "Secrets", withExtension: "plist") {
                return url
            }
        }
        return nil
    }

    private static func environmentOverride(for key: Key) -> String? {
        let env = ProcessInfo.processInfo.environment
        switch key {
        case .searxngURL:
            return env["SEARXNG_URL"]
        case .searxngAPIKey:
            return env["NOEMA_SEARCH_KEY"]
        case .teamsAPIURL:
            return env["NOEMA_TEAMS_URL"]
        }
    }

    private static func trimmedValue(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func string(for key: Key) -> String? {
        if let override = environmentOverride(for: key), let trimmed = trimmedValue(override) {
            return trimmed
        }
        guard let stored = secrets?[key.rawValue] else {
            return nil
        }
        return trimmedValue(stored)
    }

    static func requireString(for key: Key) throws -> String {
        guard let value = string(for: key) else {
            throw SecretError.missing(key)
        }
        return value
    }

    static func url(for key: Key) -> URL? {
        guard let urlString = string(for: key) else { return nil }
        return URL(string: urlString)
    }

    static func requireURL(for key: Key) throws -> URL {
        guard let url = url(for: key) else {
            throw SecretError.invalidURL(key)
        }
        return url
    }

    private static var defaultSearXNGURL: URL {
        URL(string: "https://search.noemaai.com/v1/search")!
    }

    static var searxngSearchURL: URL {
        url(for: .searxngURL) ?? defaultSearXNGURL
    }

    static var optionalSearXNGURL: URL? {
        url(for: .searxngURL)
    }

    /// API key for the keyed `/v1/search` tier. Set via Secrets.plist key
    /// `SearXNGAPIKey` or env var `NOEMA_SEARCH_KEY`.
    static var searxngAPIKey: String? {
        string(for: .searxngAPIKey)
    }

    /// Root of the Noema Teams workspace API (paths live under /v1/teams).
    /// Override via Secrets.plist `TeamsAPIURL`, env `NOEMA_TEAMS_URL`, or the
    /// `enterpriseAPIBaseURL` UserDefaults key for local development.
    /// search.noemaai.com/v1/teams serves the same API as a fallback.
    static var teamsAPIBaseURL: URL {
        url(for: .teamsAPIURL) ?? URL(string: "https://api.noemaai.com")!
    }
}
