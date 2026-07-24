import Foundation
import SwiftUI

/// Lazily loads and caches raw README files for Hugging Face datasets.
@MainActor
final class DatasetReadmeLoader: ObservableObject {
    @Published private(set) var markdown: String?
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    private let repo: String
    private let branch: String
    private let token: String?
    private var task: Task<Void, Never>?

    init(repo: String, branch: String = "main", token: String? = nil) {
        self.repo = repo
        self.branch = branch
        self.token = token
    }

    func load(force: Bool = false) {
        task?.cancel()
        isLoading = true
        task = Task { [weak self] in
            await self?.fetch(force: force)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func clearMarkdown() { markdown = nil }

    private func cacheDir() -> URL {
        var url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url.appendPathComponent("DatasetCards", isDirectory: true)
        url.appendPathComponent(repo, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fetch(force: Bool) async {
        error = nil
        defer { isLoading = false; task = nil }

        let dir = cacheDir()
        let cacheURL = dir.appendingPathComponent("README.md")
        let etagURL = dir.appendingPathComponent("etag")
        var cachedEtag: String? = try? String(contentsOf: etagURL)
        if !force,
           let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let mod = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) < 86_400,
           let data = try? Data(contentsOf: cacheURL) {
            let cleaned = Self.preprocess(String(decoding: data, as: UTF8.self), repo: repo)
            // ReadmeCollapseView renders through ReadmeMarkdownView, which draws
            // tables natively — keep them instead of the list rewrite.
            markdown = ReadmeMobileFormatter.transform(cleaned, keepTables: true)
            await networkFetch(cacheURL: cacheURL, etagURL: etagURL, etag: cachedEtag)
            return
        }

        await networkFetch(cacheURL: cacheURL, etagURL: etagURL, etag: cachedEtag, force: force)
    }

    private func networkFetch(cacheURL: URL, etagURL: URL, etag: String?, force: Bool = false) async {
        var comps = URLComponents(string: "https://huggingface.co/datasets/\(repo)/raw/\(branch)/README.md")!
        comps.queryItems = [URLQueryItem(name: "download", value: "1")]
        var request = URLRequest(url: comps.url!)
        if let etag, !force { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await HFHubRequestManager.shared.data(for: request.url!,
                                                                         token: token,
                                                                         accept: "text/plain",
                                                                         timeout: 10)
            if let http = resp as? HTTPURLResponse {
                if http.statusCode == 304 { return }
                guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                if let newTag = http.value(forHTTPHeaderField: "Etag") {
                    try? newTag.write(to: etagURL, atomically: true, encoding: .utf8)
                }
            }
            var md = String(decoding: data, as: UTF8.self)
            if data.count > 800_000 { md = String(md.prefix(600_000)) + "\n\n*(truncated)*" }
            try? md.data(using: .utf8)?.write(to: cacheURL)
            let cleaned = Self.preprocess(md, repo: repo)
            markdown = ReadmeMobileFormatter.transform(cleaned, keepTables: true)
        } catch { self.error = error }
    }

    // MARK: - Preprocessing
    private static func preprocess(_ text: String, repo: String) -> String {
        var result = text
        if let r = result.range(of: "^---\\n[\\s\\S]*?\\n---\\n", options: .regularExpression) {
            result.removeSubrange(r)
        }
        if let firstBlank = result.range(of: "\\n\\s*\\n") {
            let lines = result[result.startIndex..<firstBlank.lowerBound].split(separator: "\n")
            if lines.allSatisfy({ $0.contains(":") && !$0.contains("[") }) {
                result.removeSubrange(result.startIndex..<firstBlank.upperBound)
            }
        }
        let base = "\(HFEndpoint.webBaseString)/datasets/\(repo)/resolve/main/"
        let linkRegex = try? NSRegularExpression(pattern: #"(?<=\]\()(?!(https?|data):|#)([^)]+)"#)
        let imgRegex = try? NSRegularExpression(pattern: #"(?<=!\[.*\]\()(?!(https?|data):)([^)]+)"#)
        let rootRegex = try? NSRegularExpression(pattern: #"(?<=\]|!\[.*\]\()/(?!/)([^)]+)"#)
        for regexOptional in [linkRegex, imgRegex] {
            guard let regex = regexOptional else { continue }
            var ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: result) {
                    let replacement = base + result[r]
                    ns = ns.replacingCharacters(in: m.range(at: 1), with: replacement) as NSString
                }
            }
            result = ns as String
        }
        if let regex = rootRegex {
            var ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: result) {
                    let replacement = "\(HFEndpoint.webBaseString)/" + result[r]
                    ns = ns.replacingCharacters(in: m.range(at: 1), with: replacement) as NSString
                }
            }
            result = ns as String
        }
        return result
    }
}
