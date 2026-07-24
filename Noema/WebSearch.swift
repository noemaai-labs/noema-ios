import Foundation

// MARK: - Web Search Result Models

struct WebHit: Codable, Equatable {
    let title: String
    let url: String
    let snippet: String
    let engine: String
    let score: Double?
    let engines: [String]?
    let publishedAt: String?

    init(
        title: String,
        url: String,
        snippet: String,
        engine: String,
        score: Double?,
        engines: [String]? = nil,
        publishedAt: String? = nil
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.engine = engine
        self.score = score
        self.engines = engines
        self.publishedAt = publishedAt
    }
}

// MARK: - SearXNG Response Models

struct SearXNGResponse: Decodable {
    let results: [SearXNGResult]
    let unresponsiveEngines: [[String]]?

    init(results: [SearXNGResult], unresponsiveEngines: [[String]]? = nil) {
        self.results = results
        self.unresponsiveEngines = unresponsiveEngines
    }

    private enum CodingKeys: String, CodingKey {
        case results
        case unresponsiveEngines = "unresponsive_engines"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([SearXNGResult].self, forKey: .results) ?? []
        let engines = try container.decodeIfPresent([[String]].self, forKey: .unresponsiveEngines)
        self.init(results: decoded, unresponsiveEngines: engines)
    }
}

struct SearXNGResult: Decodable {
    let title: String?
    let url: String?
    let content: String?
    let snippet: String?
    let engine: String?
    let engines: [String]?
    let score: Double?
    let publishedDate: String?

    private enum CodingKeys: String, CodingKey {
        case title, url, content, snippet, engine, engines, score, publishedDate
    }
}

// MARK: - SearXNG Configuration

enum SearXNGSearchConfig {
    /// Returns `true` when the request targets the default Noema instance
    /// (or no custom URL is set), so the API key header should be attached.
    static var isDefaultInstance: Bool {
        let custom = UserDefaults.standard.string(forKey: "customSearXNGURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty
    }

    static func endpointURL() -> URL {
        // Check for user-configured custom SearXNG URL (read from UserDefaults
        // directly to avoid @MainActor isolation since callers may be off-main).
        let custom = UserDefaults.standard.string(forKey: "customSearXNGURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: URL
        if !custom.isEmpty,
           let customURL = URL(string: custom),
           customURL.scheme != nil, customURL.host != nil {
            base = customURL
            // Custom instances use /search by default
            if base.path.isEmpty || base.path == "/" {
                return base.appendingPathComponent("search")
            }
            return base
        } else {
            // Default instance already points to /v1/search
            return AppSecrets.searxngSearchURL
        }
    }

    static func readerEndpointURL() -> URL? {
        guard isDefaultInstance else { return nil }
        let searchURL = AppSecrets.searxngSearchURL
        guard var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil else { return nil }
        components.path = "/v1/web/retrieve"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

// MARK: - SearXNG Search Client

actor SearXNGSearchClient {
    func search(
        _ query: String,
        count: Int = 3,
        safesearch: String = "off",
        timeRange: String? = nil
    ) async throws -> [WebHit] {
        try await performSearch(
            query,
            resultLimit: max(1, min(count, 5)),
            safesearch: safesearch,
            timeRange: timeRange
        )
    }

    func searchCandidates(
        _ query: String,
        limit: Int = 20,
        safesearch: String = "moderate",
        timeRange: String? = nil
    ) async throws -> [WebHit] {
        try await performSearch(
            query,
            resultLimit: max(1, min(limit, 20)),
            safesearch: safesearch,
            timeRange: timeRange
        )
    }

    private func performSearch(
        _ query: String,
        resultLimit: Int,
        safesearch: String,
        timeRange: String?
    ) async throws -> [WebHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Search query cannot be empty"])
        }

        let endpoint = SearXNGSearchConfig.endpointURL()
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "q", value: trimmedQuery),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "categories", value: "web")
        ]

        let locale = Locale.current
        let languageTag: String? = {
            if #available(iOS 16.0, macOS 13.0, *) {
                if let languageCode = locale.language.languageCode?.identifier {
                    if let regionCode = locale.region?.identifier {
                        return "\(languageCode)-\(regionCode)"
                    }
                    return languageCode
                }
            }

            if let languageCode = locale.languageCode {
                if let regionCode = locale.regionCode {
                    return "\(languageCode)-\(regionCode)"
                }
                return languageCode
            }

            let fallback = locale.identifier.replacingOccurrences(of: "_", with: "-")
            return fallback.isEmpty ? nil : fallback
        }()

        if let languageTag {
            queryItems.append(URLQueryItem(name: "language", value: languageTag))
        }

        let safesearchLevel: String = {
            switch safesearch.lowercased() {
            case "off": return "0"
            case "strict": return "2"
            default: return "1"
            }
        }()

        queryItems.append(URLQueryItem(name: "safesearch", value: safesearchLevel))
        if let timeRange,
           ["day", "week", "month", "year"].contains(timeRange.lowercased()) {
            queryItems.append(URLQueryItem(name: "time_range", value: timeRange.lowercased()))
        }

        var request: URLRequest
        if SearXNGSearchConfig.isDefaultInstance {
            request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            var bodyComponents = URLComponents()
            bodyComponents.queryItems = queryItems
            request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else {
            components?.queryItems = queryItems
            guard let url = components?.url else {
                throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Unable to construct SearXNG search URL"])
            }
            request = URLRequest(url: url)
            request.httpMethod = "GET"
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if SearXNGSearchConfig.isDefaultInstance, let apiKey = AppSecrets.searxngAPIKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-Noema-Search-Key")
        }
        request.timeoutInterval = 12

        if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        NetworkKillSwitch.track(session: session)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            let payload = try decoder.decode(SearXNGResponse.self, from: data)
            let hits = payload.results.compactMap { result -> WebHit? in
                guard let title = result.title, let url = result.url else { return nil }
                let snippet = result.snippet ?? result.content ?? ""
                let engine = result.engine ?? result.engines?.first ?? "searxng"
                return WebHit(
                    title: title,
                    url: url,
                    snippet: snippet,
                    engine: engine,
                    score: result.score,
                    engines: result.engines,
                    publishedAt: result.publishedDate
                )
            }
            if hits.isEmpty,
               let unresponsive = payload.unresponsiveEngines,
               !unresponsive.isEmpty {
                let reasons = unresponsive.map { pair in
                    pair.count >= 2 ? "\(pair[0]): \(pair[1])" : pair.joined(separator: ": ")
                }.joined(separator: ", ")
                throw URLError(.resourceUnavailable,
                    userInfo: [NSLocalizedDescriptionKey: "No results \u{2014} search engines unavailable (\(reasons))"])
            }
            return Array(hits.prefix(resultLimit))

        case 400:
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorData["error"] as? String {
                throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Invalid request: \(errorMessage)"])
            }
            throw URLError(.badURL)

        case 401, 403:
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Search API key missing or invalid"])

        case 429:
            throw URLError(.resourceUnavailable, userInfo: [NSLocalizedDescriptionKey: "SearXNG rate limit exceeded"])

        case 502, 503:
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "SearXNG service temporarily unavailable"])

        default:
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
        }
    }
}
