// HFEndpoint.swift
// Routes Hugging Face traffic through a user-selected mirror (e.g. hf-mirror.com)
// or a custom endpoint so model downloads work in regions where huggingface.co
// is blocked. URLs are rewritten at the network boundary; catalog data and
// repo-ID parsing keep canonical huggingface.co URLs.
import Foundation

enum HFEndpoint {
    enum Mode: String {
        case official
        case mirror
        case custom
    }

    static let modeKey = "hfEndpointMode"
    static let customURLKey = "hfCustomEndpointURL"

    static let officialBaseString = "https://huggingface.co"
    static let mirrorBaseString = "https://hf-mirror.com"

    static var mode: Mode {
        guard let raw = UserDefaults.standard.string(forKey: modeKey),
              let mode = Mode(rawValue: raw) else { return .official }
        return mode
    }

    /// The active non-official base URL, or nil when the official endpoint is in
    /// use (or the custom URL is invalid, which silently falls back to official).
    static var baseURL: URL? {
        switch mode {
        case .official:
            return nil
        case .mirror:
            return URL(string: mirrorBaseString)
        case .custom:
            return validatedCustomBase(UserDefaults.standard.string(forKey: customURLKey) ?? "")
        }
    }

    /// Base string for building user-fetched web resources (e.g. README images).
    /// No trailing slash.
    static var webBaseString: String {
        baseURL?.absoluteString ?? officialBaseString
    }

    /// Custom endpoints must be https origins (scheme + host + optional port, no
    /// path); anything else is rejected so request paths join predictably.
    static func validatedCustomBase(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var comps = URLComponents(string: trimmed),
              comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty,
              comps.path.isEmpty || comps.path == "/",
              comps.query == nil, comps.fragment == nil,
              comps.user == nil, comps.password == nil
        else { return nil }
        comps.path = ""
        return comps.url
    }

    static func isOfficialHFHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "huggingface.co" || host == "www.huggingface.co" || host == "hf.co"
    }

    /// Swaps scheme/host/port onto the active endpoint, keeping path, query and
    /// fragment intact. Non-HF URLs (and everything when official) pass through.
    static func rewrite(_ url: URL) -> URL {
        guard let base = baseURL, isOfficialHFHost(url.host) else { return url }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.scheme = base.scheme
        comps.host = base.host
        comps.port = base.port
        return comps.url ?? url
    }

    /// Rewrites the request URL and drops the Authorization header when the
    /// token must not be sent to a non-official host.
    static func rewrite(_ request: URLRequest) -> URLRequest {
        var req = request
        if let url = req.url {
            let rewritten = rewrite(url)
            req.url = rewritten
            if req.value(forHTTPHeaderField: "Authorization") != nil,
               !shouldSendAuthorization(to: rewritten) {
                req.setValue(nil, forHTTPHeaderField: "Authorization")
            }
        }
        return req
    }

    /// The HF token belongs to huggingface.co; never ship it to a mirror or
    /// custom endpoint. Hosts unrelated to the endpoint keep their headers.
    static func shouldSendAuthorization(to url: URL) -> Bool {
        if isOfficialHFHost(url.host) { return true }
        if let baseHost = baseURL?.host?.lowercased(),
           url.host?.lowercased() == baseHost {
            return false
        }
        return true
    }

    /// Exports HF_ENDPOINT for dependencies that read it (e.g. WhisperKit's
    /// vendored HubApi). Call at startup and whenever the setting changes.
    static func applyEnvironment() {
        if let base = baseURL {
            setenv("HF_ENDPOINT", base.absoluteString, 1)
        } else {
            unsetenv("HF_ENDPOINT")
        }
    }
}
