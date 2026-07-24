import Foundation

enum WebRetrieveOperation: String, Codable {
    case research
    case open
    case find
}

struct WebRetrieveArguments: Codable, Equatable {
    var operation: WebRetrieveOperation?
    var query: String?
    var count: Int?
    var safesearch: String?
    var timeRange: String?
    var sourceRef: String?
    var cursor: String?
    var pattern: String?

    private enum CodingKeys: String, CodingKey {
        case operation, query, count, safesearch, cursor, pattern
        case timeRange = "time_range"
        case sourceRef = "source_ref"
    }

    var resolvedOperation: WebRetrieveOperation { operation ?? .research }
}

enum WebFetchStatus: String, Codable, CaseIterable {
    case read
    case snippetOnly = "snippet_only"
    case blocked
    case unsupported
    case tooLarge = "too_large"
    case timeout
    case noText = "no_text"
}

enum WebContentType: String, Codable {
    case html
    case text
    case pdf
    case unknown
}

struct WebEvidencePassage: Codable, Equatable, Identifiable {
    let id: String
    let text: String
    let heading: String?
    let lineStart: Int?
    let lineEnd: Int?
    let page: Int?
    let relevance: Double?

    private enum CodingKeys: String, CodingKey {
        case id, text, heading, page, relevance
        case lineStart = "line_start"
        case lineEnd = "line_end"
    }
}

struct WebEvidenceSource: Codable, Equatable, Identifiable {
    var citationIndex: Int
    let sourceRef: String?
    let title: String
    let url: String
    let canonicalURL: String
    let domain: String
    let snippet: String
    let engine: String
    let engines: [String]
    let author: String?
    let publishedAt: String?
    let fetchedAt: String?
    let contentType: WebContentType
    let fetchStatus: WebFetchStatus
    let contentHash: String?
    let passages: [WebEvidencePassage]
    let nextCursor: String?

    var id: String { sourceRef ?? canonicalURL }

    private enum CodingKeys: String, CodingKey {
        case title, url, domain, snippet, engine, engines, author, passages
        case citationIndex = "citation_index"
        case sourceRef = "source_ref"
        case canonicalURL = "canonical_url"
        case publishedAt = "published_at"
        case fetchedAt = "fetched_at"
        case contentType = "content_type"
        case fetchStatus = "fetch_status"
        case contentHash = "content_hash"
        case nextCursor = "next_cursor"
    }
}

struct WebRetrieveCapabilities: Codable, Equatable {
    let richRetrieval: Bool
    let html: Bool
    let textPDF: Bool
    let javascript: Bool
    let ocr: Bool

    private enum CodingKeys: String, CodingKey {
        case html, javascript, ocr
        case richRetrieval = "rich_retrieval"
        case textPDF = "text_pdf"
    }

    static let rich = WebRetrieveCapabilities(
        richRetrieval: true,
        html: true,
        textPDF: true,
        javascript: false,
        ocr: false
    )

    static let snippets = WebRetrieveCapabilities(
        richRetrieval: false,
        html: false,
        textPDF: false,
        javascript: false,
        ocr: false
    )
}

struct WebRetrieveEnvelope: Codable, Equatable {
    let version: Int
    let operation: WebRetrieveOperation
    var sources: [WebEvidenceSource]
    var warnings: [String]
    let capabilities: WebRetrieveCapabilities

    static func snippetFallback(
        hits: [WebHit],
        warning: String? = nil,
        richCapability: Bool = false
    ) -> WebRetrieveEnvelope {
        let sources = hits.enumerated().compactMap { index, hit -> WebEvidenceSource? in
            guard let normalized = WebURLNormalizer.canonicalURLString(hit.url),
                  let url = URL(string: normalized) else { return nil }
            return WebEvidenceSource(
                citationIndex: index + 1,
                sourceRef: nil,
                title: hit.title,
                url: hit.url,
                canonicalURL: normalized,
                domain: url.host ?? "",
                snippet: hit.snippet,
                engine: hit.engine,
                engines: hit.engines ?? [],
                author: nil,
                publishedAt: hit.publishedAt,
                fetchedAt: nil,
                contentType: .unknown,
                fetchStatus: .snippetOnly,
                contentHash: nil,
                passages: [],
                nextCursor: nil
            )
        }
        return WebRetrieveEnvelope(
            version: 2,
            operation: .research,
            sources: sources,
            warnings: warning.map { [$0] } ?? [],
            capabilities: richCapability ? .rich : .snippets
        )
    }
}

struct WebRetrieveErrorPayload: Codable, Equatable {
    let error: String
    let code: String?
}

enum WebToolResultDecoder {
    static func envelope(from data: Data) -> WebRetrieveEnvelope? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(WebRetrieveEnvelope.self, from: data) {
            return envelope
        }
        if let legacy = try? decoder.decode([WebHit].self, from: data) {
            return .snippetFallback(hits: legacy)
        }
        return nil
    }

    static func error(from data: Data) -> WebRetrieveErrorPayload? {
        try? JSONDecoder().decode(WebRetrieveErrorPayload.self, from: data)
    }
}

enum WebURLNormalizer {
    private static let trackingNames = Set(["fbclid", "gclid", "mc_cid", "mc_eid"])

    static func canonicalURLString(_ rawValue: String) -> String? {
        guard var components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        components.scheme = scheme
        components.fragment = nil
        components.queryItems = components.queryItems?.filter { item in
            let lowered = item.name.lowercased()
            return !lowered.hasPrefix("utm_") && !trackingNames.contains(lowered)
        }
        return components.url?.absoluteString
    }

    static func diverseCandidates(from hits: [WebHit], limit: Int = 8) -> [WebHit] {
        var seenURLs = Set<String>()
        var domainCounts: [String: Int] = [:]
        var output: [WebHit] = []
        for hit in hits {
            guard let canonical = canonicalURLString(hit.url),
                  let host = URL(string: canonical)?.host?.lowercased(),
                  !seenURLs.contains(canonical),
                  domainCounts[host, default: 0] < 2 else { continue }
            seenURLs.insert(canonical)
            domainCounts[host, default: 0] += 1
            output.append(hit)
            if output.count == limit { break }
        }
        return output
    }

    /// Recognizes a user/model-supplied HTTP(S) URL or ordinary DNS name without
    /// confusing the reader's long `payload.signature` source references for a
    /// hostname. The reader remains responsible for DNS pinning and SSRF checks.
    static func directURLString(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \Character.isWhitespace) else { return nil }

        let referenceSegments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let base64URLCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if referenceSegments.count == 2,
           referenceSegments.allSatisfy({ $0.count >= 32 }),
           referenceSegments.allSatisfy({ segment in
               segment.unicodeScalars.allSatisfy(base64URLCharacters.contains)
           }) {
            return nil
        }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            guard trimmed.count <= 2_048 else { return nil }
            let authority = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let host = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2,
                  host.count <= 253,
                  labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return nil }
            candidate = "https://" + trimmed
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              host.contains("."),
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 80 || components.port == 443 else {
            return nil
        }
        return canonicalURLString(candidate)
    }
}

private struct WebReaderCandidate: Encodable {
    let title: String
    let url: String
    let snippet: String
    let engine: String
    let engines: [String]
    let score: Double?
    let publishedAt: String?

    private enum CodingKeys: String, CodingKey {
        case title, url, snippet, engine, engines, score
        case publishedAt = "published_at"
    }
}

private struct WebReaderRequest: Encodable {
    let operation: WebRetrieveOperation
    let query: String?
    let candidates: [WebReaderCandidate]?
    let desiredSources: Int?
    let maxEvidenceChars: Int
    let sourceRef: String?
    let cursor: String?
    let pattern: String?

    private enum CodingKeys: String, CodingKey {
        case operation, query, candidates, cursor, pattern
        case desiredSources = "desired_sources"
        case maxEvidenceChars = "max_evidence_chars"
        case sourceRef = "source_ref"
    }
}

enum WebResearchError: LocalizedError {
    case invalidArguments(String)
    case richRetrievalUnavailable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return message
        case .richRetrievalUnavailable:
            return String(localized: "Opening and finding within sources requires Noema’s web search service.")
        case .server(let message): return message
        }
    }
}

actor WebResearchClient {
    func retrieve(_ arguments: WebRetrieveArguments, contextLimit: Double = 4_096) async throws -> WebRetrieveEnvelope {
        switch arguments.resolvedOperation {
        case .research:
            return try await research(arguments, contextLimit: contextLimit)
        case .open, .find:
            guard SearXNGSearchConfig.isDefaultInstance,
                  SearXNGSearchConfig.readerEndpointURL() != nil else {
                throw WebResearchError.richRetrievalUnavailable
            }
            if let suppliedReference = arguments.sourceRef,
               let directURL = WebURLNormalizer.directURLString(suppliedReference) {
                return try await retrieveDirectURL(
                    directURL,
                    requestedArguments: arguments,
                    contextLimit: contextLimit
                )
            }
            return try await callReader(arguments, candidates: nil, contextLimit: contextLimit)
        }
    }

    /// Small local models sometimes place a URL in `source_ref` when the user says
    /// "open example.com". Bootstrap that URL through research so the server, not
    /// the model, creates the signed reference, then perform the requested operation.
    private func retrieveDirectURL(
        _ urlString: String,
        requestedArguments: WebRetrieveArguments,
        contextLimit: Double
    ) async throws -> WebRetrieveEnvelope {
        guard let url = URL(string: urlString), let host = url.host else {
            throw WebResearchError.invalidArguments(String(localized: "Web source response was invalid."))
        }
        let candidate = WebReaderCandidate(
            title: host,
            url: urlString,
            snippet: "",
            engine: "direct",
            engines: ["direct"],
            score: 1,
            publishedAt: nil
        )
        let bootstrapArguments = WebRetrieveArguments(
            operation: .research,
            query: urlString,
            count: 1,
            safesearch: requestedArguments.safesearch ?? "moderate",
            timeRange: nil,
            sourceRef: nil,
            cursor: nil,
            pattern: nil
        )
        let bootstrap = try await callReader(
            bootstrapArguments,
            candidates: [candidate],
            contextLimit: contextLimit
        )
        guard let readableSource = bootstrap.sources.first(where: {
            $0.fetchStatus == .read && $0.sourceRef?.isEmpty == false
        }), let signedReference = readableSource.sourceRef else {
            return bootstrap
        }

        var signedArguments = requestedArguments
        signedArguments.sourceRef = signedReference
        return try await callReader(signedArguments, candidates: nil, contextLimit: contextLimit)
    }

    private func research(_ arguments: WebRetrieveArguments, contextLimit: Double) async throws -> WebRetrieveEnvelope {
        let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            throw WebResearchError.invalidArguments(String(localized: "Search query cannot be empty."))
        }
        let count = max(1, min(arguments.count ?? 3, 5))
        let safesearch = arguments.safesearch ?? "moderate"
        let client = SearXNGSearchClient()
        let hits = try await client.searchCandidates(
            query,
            limit: SearXNGSearchConfig.isDefaultInstance ? 20 : count,
            safesearch: safesearch,
            timeRange: arguments.timeRange
        )

        guard SearXNGSearchConfig.isDefaultInstance,
              SearXNGSearchConfig.readerEndpointURL() != nil else {
            return .snippetFallback(
                hits: Array(hits.prefix(count)),
                warning: String(localized: "This custom SearXNG instance provides search snippets but not Noema source reading.")
            )
        }

        let candidates = WebURLNormalizer.diverseCandidates(from: hits).map { hit in
            WebReaderCandidate(
                title: hit.title,
                url: hit.url,
                snippet: hit.snippet,
                engine: hit.engine,
                engines: hit.engines ?? [],
                score: hit.score,
                publishedAt: hit.publishedAt
            )
        }
        guard !candidates.isEmpty else { return .snippetFallback(hits: Array(hits.prefix(count))) }
        do {
            var requestArguments = arguments
            requestArguments.count = count
            return try await callReader(requestArguments, candidates: candidates, contextLimit: contextLimit)
        } catch {
            return .snippetFallback(
                hits: Array(hits.prefix(count)),
                warning: String(localized: "Source reading was unavailable, so these results contain search snippets only.")
            )
        }
    }

    private func callReader(
        _ arguments: WebRetrieveArguments,
        candidates: [WebReaderCandidate]?,
        contextLimit: Double
    ) async throws -> WebRetrieveEnvelope {
        guard let endpoint = SearXNGSearchConfig.readerEndpointURL() else {
            throw WebResearchError.richRetrievalUnavailable
        }
        let evidenceBudget = min(20_000, max(2_000, Int(contextLimit * 1.5)))
        let payload = WebReaderRequest(
            operation: arguments.resolvedOperation,
            query: arguments.query,
            candidates: candidates,
            desiredSources: arguments.resolvedOperation == .research ? max(1, min(arguments.count ?? 3, 5)) : nil,
            maxEvidenceChars: evidenceBudget,
            sourceRef: arguments.sourceRef,
            cursor: arguments.cursor,
            pattern: arguments.pattern
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = AppSecrets.searxngAPIKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-Noema-Search-Key")
        }
        request.timeoutInterval = 30

        if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 35
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        NetworkKillSwitch.track(session: session)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = object["error"] as? String { throw WebResearchError.server(error) }
                if let detail = object["detail"] as? [String: Any], let error = detail["error"] as? String {
                    throw WebResearchError.server(error)
                }
            }
            throw WebResearchError.server(
                String(format: String(localized: "Web source reading failed (HTTP %d)."), response.statusCode)
            )
        }
        guard let envelope = WebToolResultDecoder.envelope(from: data) else {
            throw WebResearchError.server(String(localized: "Web source response was invalid."))
        }
        return envelope
    }
}

enum WebRetrieveExecutor {
    static func run(args: Data, contextLimit: Double = 4_096) async -> Data {
        guard WebToolGate.isAvailable() else {
            return errorData("Web search is disabled or offline-only.", code: "web_disabled")
        }
        do {
            let input = try JSONDecoder().decode(WebRetrieveArguments.self, from: args)
            let envelope = try await WebResearchClient().retrieve(input, contextLimit: contextLimit)
            return try JSONEncoder().encode(envelope)
        } catch {
            let message: String
            switch (error as? URLError)?.code {
            case .timedOut?:
                message = "Web search timed out. Please try again."
            case .notConnectedToInternet?, .networkConnectionLost?, .cannotConnectToHost?, .cannotFindHost?:
                message = "Web search is unavailable right now. Check your internet connection and try again."
            case .cancelled?:
                message = "Web search was cancelled."
            default:
                let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                message = localized.isEmpty ? "Web search failed. Please try again." : localized
            }
            return errorData(message, code: "web_retrieve_failed")
        }
    }

    private static func errorData(_ message: String, code: String) -> Data {
        (try? JSONEncoder().encode(WebRetrieveErrorPayload(error: message, code: code)))
            ?? Data("{\"error\":\"Web search failed.\"}".utf8)
    }
}
