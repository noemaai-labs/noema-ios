import Foundation

/// Registry for searching the Open Textbook Library catalog.
public final class OpenTextbookLibraryDatasetRegistry: DatasetRegistry, @unchecked Sendable {
    private let session: URLSession
    // Cache of aggregated, relevance-sorted records per (query|perPage)
    private var cache: [String: [DatasetRecord]] = [:]
    // Tracks which remote pages have been fetched for a (query|perPage)
    private var fetchedPages: [String: Set<Int>] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func curated() async throws -> [DatasetRecord] { [] }

    public func searchStream(query: String, perPage: Int = 100, maxPages: Int = 10) -> AsyncThrowingStream<DatasetRecord, Error> {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .init { $0.finish() } }
        let session = self
        return .init { continuation in
            let task = Task {
                var seen = Set<Int>()
                for page in 1...maxPages {
                    if Task.isCancelled { break }
                    do {
                        let records = try await session.fetchPage(query: trimmed, page: page, perPage: perPage)
                        for r in records {
                            if let idInt = Int(r.id.split(separator: "/").last ?? ""), seen.insert(idInt).inserted {
                                continuation.yield(r)
                            }
                        }
                        if records.count < perPage { break }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func fetchPage(query: String, page: Int, perPage: Int) async throws -> [DatasetRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        // Key cache by query and requested perPage so we can track remote pages consistently
        let key = "\(trimmed)|\(perPage)"
        var aggregated = cache[key] ?? []
        var pages = fetchedPages[key] ?? []

        // Ensure we have fetched remote pages up to the requested page
        // and merged them into a single, relevance-sorted array.
        if !pages.contains(page) {
            // Fetch any missing pages up to 'page'
            let qLower = trimmed.lowercased()
            for p in 1...page where !pages.contains(p) {
                var comps = URLComponents(string: "https://open.umn.edu/opentextbooks/textbooks.json")!
                comps.queryItems = [
                    URLQueryItem(name: "q", value: trimmed),
                    URLQueryItem(name: "per_page", value: String(perPage)),
                    URLQueryItem(name: "page", value: String(p)),
                    URLQueryItem(name: "format", value: "json")
                ]
                let url = comps.url!
                print("[OTL] GET \(url.absoluteString)")
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, _) = try await session.data(for: request)
                struct Response: Decodable { let data: [Entry] }
                struct Entry: Decodable {
                    let id: Int
                    let title: String
                    let description: String?
                    let publishers: [Publisher]?
                    let url: String
                    let formats: [Format]?
                    struct Publisher: Decodable { let name: String? }
                    struct Format: Decodable { let type: String? }
                }
                let res = try JSONDecoder().decode(Response.self, from: data)
                var newRecords: [DatasetRecord] = []
                for entry in res.data {
                    let idStr = "OTL/\(entry.id)"
                    // Ensure the entry advertises a usable PDF or EPUB format
                    let hasUsable = entry.formats?.contains { f in
                        let kind = f.type?.lowercased() ?? ""
                        return kind.contains("pdf") || kind.contains("epub")
                    } ?? false
                    if hasUsable {
                        newRecords.append(
                            DatasetRecord(
                                id: idStr,
                                displayName: entry.title,
                                publisher: entry.publishers?.first?.name ?? "",
                                summary: entry.description,
                                installed: false
                            )
                        )
                    }
                }
                // Merge unique by id then re-sort by relevance score
                if !newRecords.isEmpty {
                    let existingIds = Set(aggregated.map { $0.id })
                    newRecords.removeAll { existingIds.contains($0.id) }
                    aggregated.append(contentsOf: newRecords)
                    aggregated.sort { a, b in Self.score(a, qLower) > Self.score(b, qLower) }
                }
                pages.insert(p)
            }
            cache[key] = aggregated
            fetchedPages[key] = pages
        }

        let start = (page - 1) * perPage
        guard start < aggregated.count else { return [] }
        let end = min(start + perPage, aggregated.count)
        let slice = Array(aggregated[start..<end])
        let ids = slice.prefix(3).compactMap { Int($0.id.split(separator: "/").last ?? "") }
        print("[OTL] page \(page) ids: \(ids)")
        return slice

    }

    private static func score(_ r: DatasetRecord, _ q: String) -> Int {
        let title = r.displayName.lowercased()
        let desc = (r.summary ?? "").lowercased()
        if title == q { return 1_000_000 }
        let qTokens = Set(q.split { !$0.isLetter && !$0.isNumber })
        let titleTokens = Set(title.split { !$0.isLetter && !$0.isNumber })
        let descTokens = Set(desc.split { !$0.isLetter && !$0.isNumber })
        let titleHit = qTokens.intersection(titleTokens).count
        let descHit = qTokens.intersection(descTokens).count
        let exactBoost = title.contains(q) ? 10_000 : 0
        return exactBoost + titleHit * 100 + descHit
    }

    public func details(for id: String) async throws -> DatasetDetails {
        guard let slug = id.split(separator: "/").dropFirst().first else {
            throw URLError(.badURL)
        }
        let url = URL(string: "https://open.umn.edu/opentextbooks/textbooks/\(slug).json")!
        let (data, _) = try await session.data(from: url)
        struct Response: Decodable { let data: Entry }
        struct Entry: Decodable {
            let id: Int
            let title: String
            let description: String?
            let formats: [Format]
            struct Format: Decodable { let type: String; let url: String? }
        }
        let res = try JSONDecoder().decode(Response.self, from: data).data
        var files: [DatasetFile] = []
        for f in res.formats {
            guard let urlStr = f.url, let url = URL(string: urlStr) else { continue }
            let kind = f.type.lowercased()

            if kind.contains("pdf") || url.pathExtension.lowercased() == "pdf" {
                if let (finalURL, length) = try? await resolvedPDFURL(from: url) {
                    var name = finalURL.lastPathComponent
                    if name.isEmpty || !name.contains(".") { name = (name.isEmpty ? "file" : name) + ".pdf" }
                    files.append(DatasetFile(id: name, name: name, sizeBytes: length, downloadURL: finalURL))
                } else {
                    // Fall back to original landing page as HTML with unknown size
                    var name = url.lastPathComponent
                    if name.isEmpty || !name.contains(".") { name = (name.isEmpty ? "page" : name) + ".html" }
                    files.append(DatasetFile(id: name, name: name, sizeBytes: 0, downloadURL: url))
                }
                continue
            }

            if kind.contains("epub") || url.pathExtension.lowercased() == "epub" {
                if let (finalURL, length) = try? await resolvedEPUBURL(from: url) {
                    var name = finalURL.lastPathComponent
                    if name.isEmpty || !name.contains(".") { name = (name.isEmpty ? "file" : name) + ".epub" }
                    files.append(DatasetFile(id: name, name: name, sizeBytes: length, downloadURL: finalURL))
                } else {
                    // Fall back to original landing page as HTML with unknown size
                    var name = url.lastPathComponent
                    if name.isEmpty || !name.contains(".") { name = (name.isEmpty ? "page" : name) + ".html" }
                    files.append(DatasetFile(id: name, name: name, sizeBytes: 0, downloadURL: url))
                }
            }
        }
        return DatasetDetails(id: id, summary: res.description, files: files, displayName: res.title)
    }

    private func resolvedPDFURL(from original: URL) async throws -> (URL, Int64)? {
        // 1) Try HEAD/Range on the original URL
        if let head = try? await headInfo(original) {
            if let accepted = await validatePDFCandidate(head: head, referer: nil) {
                return accepted
            }
        }

        // 2) Fetch a small chunk of HTML and try to find a real PDF link
        if let html = try? await fetchHTMLPreview(from: original, maxBytes: 200_000) {
            // Prefer clear .pdf links
            let candidates = extractCandidateLinks(fromHTML: html, base: original)
            for url in candidates {
                if let head = try? await headInfo(url, referer: original),
                   let accepted = await validatePDFCandidate(head: head, referer: original) {
                    return accepted
                }
            }

            // Obvious tweaks based on observed markup
            if html.lowercased().contains("format=pdf"),
               var comps = URLComponents(url: original, resolvingAgainstBaseURL: false) {
                var items = comps.queryItems ?? []
                items.append(URLQueryItem(name: "format", value: "pdf"))
                comps.queryItems = items
                if let test = comps.url, let head = try? await headInfo(test, referer: original),
                   let accepted = await validatePDFCandidate(head: head, referer: original) {
                    return accepted
                }
            }
            if html.lowercased().contains("download"),
               var comps = URLComponents(url: original, resolvingAgainstBaseURL: false) {
                var items = comps.queryItems ?? []
                items.append(URLQueryItem(name: "download", value: "1"))
                comps.queryItems = items
                if let test = comps.url, let head = try? await headInfo(test, referer: original),
                   let accepted = await validatePDFCandidate(head: head, referer: original) {
                    return accepted
                }
            }
        }

        // 3) Give up
        return nil
    }

    private func resolvedEPUBURL(from original: URL) async throws -> (URL, Int64)? {
        // 1) Try HEAD/Range on the original URL
        if let head = try? await headInfo(original) {
            let ct = head.contentType?.lowercased() ?? ""
            let isEPUB = ct.contains("application/epub+zip") || head.finalURL.pathExtension.lowercased() == "epub"
            if isEPUB || (!ct.contains("text/html") && original.pathExtension.lowercased() == "epub") {
                return (head.finalURL, head.length)
            }
        }
        // 2) Fetch partial HTML and look for .epub links
        if let html = try? await fetchHTMLPreview(from: original, maxBytes: 200_000) {
            let candidates = extractCandidateLinks(fromHTML: html, base: original)
            for url in candidates {
                if url.pathExtension.lowercased() != "epub" && !url.absoluteString.lowercased().contains("epub") {
                    continue
                }
                if let head = try? await headInfo(url, referer: original) {
                    let ct = head.contentType?.lowercased() ?? ""
                    if ct.contains("application/epub+zip") || head.finalURL.pathExtension.lowercased() == "epub" {
                        return (head.finalURL, head.length)
                    }
                }
            }
            // Try toggling obvious query params
            if html.lowercased().contains("format=epub"),
               var comps = URLComponents(url: original, resolvingAgainstBaseURL: false) {
                var items = comps.queryItems ?? []
                items.append(URLQueryItem(name: "format", value: "epub"))
                comps.queryItems = items
                if let test = comps.url, let head = try? await headInfo(test, referer: original) {
                    let ct = head.contentType?.lowercased() ?? ""
                    if ct.contains("application/epub+zip") || head.finalURL.pathExtension.lowercased() == "epub" {
                        return (head.finalURL, head.length)
                    }
                }
            }
            if html.lowercased().contains("download"),
               var comps = URLComponents(url: original, resolvingAgainstBaseURL: false) {
                var items = comps.queryItems ?? []
                items.append(URLQueryItem(name: "download", value: "1"))
                comps.queryItems = items
                if let test = comps.url, let head = try? await headInfo(test, referer: original) {
                    let ct = head.contentType?.lowercased() ?? ""
                    if ct.contains("application/epub+zip") || head.finalURL.pathExtension.lowercased() == "epub" {
                        return (head.finalURL, head.length)
                    }
                }
            }
        }
        // 3) Give up
        return nil
    }

    private func headInfo(_ url: URL, referer: URL? = nil) async throws -> (contentType: String?, length: Int64, finalURL: URL) {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue("application/pdf, application/epub+zip;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let referer {
            req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return (nil, 0, url) }
            let ct = http.value(forHTTPHeaderField: "Content-Type")
            var size: Int64 = 0
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let totalStr = range.split(separator: "/").last,
               let total = Int64(totalStr) {
                size = total
            } else if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
                      let len = Int64(lenStr) {
                size = len
            } else if http.expectedContentLength > 0 {
                size = http.expectedContentLength
            }
            return (ct, size, http.url ?? url)
        } catch {
            var get = URLRequest(url: url)
            get.httpMethod = "GET"
            get.setValue("bytes=0-7", forHTTPHeaderField: "Range")
            get.setValue("application/pdf, application/epub+zip;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
            get.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            if let referer {
                get.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }
            let (_, resp) = try await session.data(for: get)
            guard let http = resp as? HTTPURLResponse else { return (nil, 0, url) }
            let ct = http.value(forHTTPHeaderField: "Content-Type")
            var size: Int64 = 0
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let totalStr = range.split(separator: "/").last,
               let total = Int64(totalStr) {
                size = total
            } else if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
                      let len = Int64(lenStr) {
                size = len
            } else if http.expectedContentLength > 0 {
                size = http.expectedContentLength
            }
            return (ct, size, http.url ?? url)
        }
    }

    private func fetchHTMLPreview(from url: URL, maxBytes: Int) async throws -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("bytes=0-\(maxBytes)", forHTTPHeaderField: "Range")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return String(data: data, encoding: .utf8)
    }

    private enum FileValidationError: Error {
        case invalidSignature
    }

    private func validatePDFDataPrefix(_ data: Data) throws {
        // A PDF file starts with "%PDF-"
        guard let signature = String(data: data.prefix(5), encoding: .ascii), signature == "%PDF-" else {
            throw FileValidationError.invalidSignature
        }
    }

    private func fetchPrefix(_ url: URL, bytes: Int = 8, referer: URL? = nil) async throws -> (Data, String?, Int64, URL) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=0-\(max(bytes - 1, 0))", forHTTPHeaderField: "Range")
        req.setValue("application/pdf, */*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let referer { req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return (data, nil, 0, url) }
        let ct = http.value(forHTTPHeaderField: "Content-Type")
        var size: Int64 = 0
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let totalStr = range.split(separator: "/").last,
           let total = Int64(totalStr) {
            size = total
        } else if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
                  let len = Int64(lenStr) {
            size = len
        } else if http.expectedContentLength > 0 {
            size = http.expectedContentLength
        }
        return (data, ct, size, http.url ?? url)
    }

    private func validatePDFCandidate(head: (contentType: String?, length: Int64, finalURL: URL), referer: URL?) async -> (URL, Int64)? {
        let ctLower = head.contentType?.lowercased() ?? ""
        let isPDF = ctLower.contains("application/pdf") || head.finalURL.pathExtension.lowercased() == "pdf"
        let notHTMLWithPdfExt = !ctLower.contains("text/html") && head.finalURL.pathExtension.lowercased() == "pdf"
        if !(isPDF || notHTMLWithPdfExt) { return nil }
        if head.length >= 1_024 { return (head.finalURL, head.length) }
        if let (prefix, _, inferredLength, finalURL) = try? await fetchPrefix(head.finalURL, bytes: 8, referer: referer),
           (try? validatePDFDataPrefix(prefix)) != nil {
            let length = inferredLength > 0 ? inferredLength : head.length
            return (finalURL, length)
        }
        return nil
    }

    private func extractCandidateLinks(fromHTML html: String, base: URL) -> [URL] {
        var results: [URL] = []
        // A more advanced regex that can also capture the link's text
        let pattern = #"<a\s+(?:[^>]*?\s+)?href\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)<\/a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)

        var urlsAndTexts: [(url: URL, text: String)] = []
        regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let match = match, match.numberOfRanges == 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { return }

            let href = String(html[hrefRange])
            if href.hasPrefix("#") || href.lowercased().hasPrefix("mailto:") || href.lowercased().hasPrefix("javascript:") { return }

            if let url = URL(string: href, relativeTo: base) {
                let linkText = String(html[textRange]).lowercased()
                urlsAndTexts.append((url, linkText))
            }
        }

        // Prioritization logic
        let endsWithPDF = urlsAndTexts.filter { $0.url.path.lowercased().hasSuffix(".pdf") }
        let textIndicatesPDF = urlsAndTexts.filter { $0.text.contains("pdf") || $0.text.contains("full text") || $0.text.contains("view pdf") || $0.text.contains("download") }
        let containsDownloadOrKeywords = urlsAndTexts.filter {
            let s = $0.url.absoluteString.lowercased()
            return s.contains("download") || s.contains("fulltext") || s.contains("content") || s.contains("asset")
        }

        // Combine and also look for data-* attributes and embedded JSON URLs that look like downloads
        var combined = (endsWithPDF + textIndicatesPDF + containsDownloadOrKeywords).map { $0.url }
        combined.append(contentsOf: extractLinksFromDataAttributes(in: html, base: base))
        combined.append(contentsOf: extractURLsFromEmbeddedJSON(in: html, base: base))

        // De-duplicate while preserving order
        var seen: Set<String> = []
        results = combined.filter { seen.insert($0.absoluteString).inserted }

        return results
    }

    private func extractLinksFromDataAttributes(in html: String, base: URL) -> [URL] {
        let pattern = #"(?:data-(?:href|url|download|file|pdf))\s*=\s*[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [URL] = []
        regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: html) else { return }
            let raw = String(html[r])
            if let u = URL(string: raw, relativeTo: base) { results.append(u) }
        }
        return results
    }

    private func extractURLsFromEmbeddedJSON(in html: String, base: URL) -> [URL] {
        let scriptPattern = #"<script[^>]*type\s*=\s*[\"']application/json[\"'][^>]*>(.*?)<\/script>"#
        guard let regex = try? NSRegularExpression(pattern: scriptPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var urls: [URL] = []
        regex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 2, let bodyRange = Range(match.range(at: 1), in: html) else { return }
            let jsonString = String(html[bodyRange])
            guard let data = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return }
            var strings: [String] = []
            func collect(_ value: Any) {
                if let dict = value as? [String: Any] {
                    for (_, v) in dict { collect(v) }
                } else if let arr = value as? [Any] {
                    for v in arr { collect(v) }
                } else if let s = value as? String {
                    strings.append(s)
                }
            }
            collect(obj)
            for s in strings {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let lower = trimmed.lowercased()
                let isLikelyURL = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//") || lower.hasPrefix("/")
                if !isLikelyURL { continue }
                if lower.contains(".pdf") || lower.contains("download") || lower.contains("fulltext") {
                    if let u = URL(string: trimmed, relativeTo: base) { urls.append(u) }
                }
            }
        }
        // De-duplicate and lightly prioritize .pdf endings
        var seen = Set<String>()
        let sorted = urls.sorted { a, b in
            let aPDF = a.path.lowercased().hasSuffix(".pdf")
            let bPDF = b.path.lowercased().hasSuffix(".pdf")
            return (aPDF ? 0 : 1) < (bPDF ? 0 : 1)
        }
        return sorted.filter { seen.insert($0.absoluteString).inserted }
    }
}
