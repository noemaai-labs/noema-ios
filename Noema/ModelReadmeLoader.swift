// ModelReadmeLoader.swift
import Foundation
import SwiftUI

/// Lazily loads and caches raw README files for Hugging Face models.
@MainActor
final class ModelReadmeLoader: ObservableObject {
    @Published private(set) var markdown: String?
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published private(set) var fallbackSummary: String?

    private let repo: String
    private let branch: String
    private let token: String?
    private var task: Task<Void, Never>?
    // Static coordination to avoid duplicate network fetches for the same repo across multiple loader instances
    private static var fetchingRepos: Set<String> = []
    private static let fetchQueue = DispatchQueue(label: "ModelReadmeLoader.fetchQueue")

    init(repo: String, branch: String = "main", token: String? = nil) {
        self.repo = repo
        self.branch = branch
        self.token = token
    }

    func load(force: Bool = false) {
        // If this repo is provided manually in the app (curated), prefer the handwritten summary
        if let manual = ManualModelRegistry.defaultEntries.first(where: { $0.record.id == repo || $0.details.id == repo }) {
            // `summary` is optional on ModelDetails; prefer it, fall back to record.summary, then empty string
            let sourceSummary = manual.details.summary ?? manual.record.summary ?? ""
            let formatted = ReadmeMobileFormatter.transform(sourceSummary)
            let cleaned = Self.preprocess(formatted, repo: repo)
            markdown = cleaned
            if fallbackSummary == nil { fallbackSummary = Self.firstSentence(from: cleaned) }
            return
        }
        // If a load is already in progress and we're not forcing, do nothing to avoid duplicate fetches
        if !force, task != nil {
            return
        }
        task?.cancel()
        isLoading = true  // Set loading state immediately
        task = Task { [weak self] in
            await self?.fetch(force: force)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Clears the currently loaded markdown. Call on the main actor.
    func clearMarkdown() {
        markdown = nil
    }

    private func cacheDir() -> URL {
        var url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url.appendPathComponent("ModelCards", isDirectory: true)
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
            let originalContent = String(decoding: data, as: UTF8.self)
            let formattedContent = ReadmeMobileFormatter.transform(originalContent)
            let cleaned = Self.preprocess(formattedContent, repo: repo)
            #if DEBUG
            print("[README] Cached content - Formatted length: \(formattedContent.count)")
            print("[README] Cached content - Final length: \(cleaned.count)")
            #endif
            markdown = cleaned
            if fallbackSummary == nil {
                fallbackSummary = Self.firstSentence(from: cleaned)
            }
            // Avoid triggering a concurrent network fetch if another loader for the same repo is active
            var shouldFetch = false
            ModelReadmeLoader.fetchQueue.sync {
                if !ModelReadmeLoader.fetchingRepos.contains(repo) {
                    ModelReadmeLoader.fetchingRepos.insert(repo)
                    shouldFetch = true
                }
            }
            if shouldFetch {
                defer {
                    ModelReadmeLoader.fetchQueue.sync {
                        ModelReadmeLoader.fetchingRepos.remove(repo)
                    }
                }
                await networkFetch(cacheURL: cacheURL, etagURL: etagURL, etag: cachedEtag)
            } else {
                #if DEBUG
                print("[README] Skipping duplicate networkFetch for \(repo)")
                #endif
            }
            return
        }

        // Ensure only one active network fetch per repo across loader instances
        var shouldFetch = false
        ModelReadmeLoader.fetchQueue.sync {
            if !ModelReadmeLoader.fetchingRepos.contains(repo) {
                ModelReadmeLoader.fetchingRepos.insert(repo)
                shouldFetch = true
            }
        }
        if shouldFetch {
            defer {
                ModelReadmeLoader.fetchQueue.sync {
                    ModelReadmeLoader.fetchingRepos.remove(repo)
                }
            }
            await networkFetch(cacheURL: cacheURL, etagURL: etagURL, etag: cachedEtag, force: force)
        } else {
            #if DEBUG
            print("[README] Skipping duplicate networkFetch for \(repo)")
            #endif
        }
    }

    private func networkFetch(cacheURL: URL, etagURL: URL, etag: String?, force: Bool = false) async {
        if NetworkKillSwitch.isEnabled { return }
        // Try common README filenames and endpoints
        let names = ["README.md", "Readme.md", "readme.md", "README.MD", "README.txt", "readme.txt"]
        let endpoints: [(String) -> String] = [
            { "https://huggingface.co/\(self.repo)/resolve/\(self.branch)/\($0)" },
            { "https://huggingface.co/\(self.repo)/raw/\(self.branch)/\($0)" }
        ]
        
        for name in names {
            for makeURLString in endpoints {
                let urlString = makeURLString(name)
                guard let url = URL(string: urlString) else { continue }
                
                var req = URLRequest(url: url)
                req.timeoutInterval = 10.0
                if let etag, !force { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                // Do not send Authorization for public repos to avoid 401s
                
                do {
                    let (data, resp) = try await HFHubRequestManager.shared.data(for: url,
                                                                                 accept: nil,
                                                                                 timeout: 10)
                    if let http = resp as? HTTPURLResponse {
                        print("[README] Tried \(urlString) -> \(http.statusCode)")
                        if http.statusCode == 304 { return }
                        guard (200..<300).contains(http.statusCode) else { continue }
                        if let newTag = http.value(forHTTPHeaderField: "Etag") {
                            try? newTag.write(to: etagURL, atomically: true, encoding: .utf8)
                        }
                    }
                    var md = String(decoding: data, as: UTF8.self)
                    if data.count > 800_000 { md = String(md.prefix(600_000)) + "\n\n*(truncated)*" }
                    try? md.data(using: .utf8)?.write(to: cacheURL)
                    
                    // Apply mobile formatting first, then preprocessing
                    let formattedContent = ReadmeMobileFormatter.transform(md)
                    let cleaned = Self.preprocess(formattedContent, repo: repo)
                    #if DEBUG
                    print("[README] Preprocessed content length: \(cleaned.count)")
                    print("[README] Contains tables: \(cleaned.contains("|"))")
                    print("[README] Contains flex divs: \(cleaned.contains("display: flex"))")
                    print("[README] Contains frontmatter: \(cleaned.hasPrefix("---"))")
                    #endif
                    markdown = cleaned
                    #if DEBUG
                    print("[README] Final formatted content length: \(markdown?.count ?? 0)")
                    #endif
                    if fallbackSummary == nil { fallbackSummary = Self.firstSentence(from: cleaned) }
                    print("[README] Success loading from \(urlString)")
                    return
                } catch {
                    print("[README] Error fetching \(urlString): \(error)")
                    continue
                }
            }
        }
        
        // Final fallback: list files via API and try any README-like file found
        print("[README] Trying API discovery fallback for \(repo)")
        if let alt = await discoverReadmeCandidate(), let data = await fetchURL(alt) {
            var md = String(decoding: data, as: UTF8.self)
            if data.count > 800_000 { md = String(md.prefix(600_000)) + "\n\n*(truncated)*" }
            try? md.data(using: .utf8)?.write(to: cacheURL)
            
            // Apply mobile formatting first, then preprocessing
            let formattedContent = ReadmeMobileFormatter.transform(md)
            let cleaned = Self.preprocess(formattedContent, repo: repo)
            #if DEBUG
            print("[README] API discovery - Formatted length: \(formattedContent.count)")
            print("[README] API discovery - Final length: \(cleaned.count)")
            #endif
            markdown = cleaned
            if fallbackSummary == nil { fallbackSummary = Self.firstSentence(from: cleaned) }
            print("[README] Success from API discovery: \(alt)")
            return
        }
        
        print("[README] All methods failed for \(repo)")
        self.error = URLError(.fileDoesNotExist)
    }

    private func discoverReadmeCandidate() async -> URL? {
        var comps = URLComponents(string: "https://huggingface.co/api/models/\(repo)")!
        comps.queryItems = [URLQueryItem(name: "full", value: "1")]
        let req = URLRequest(url: comps.url!)
        // Don't send Authorization for public model API query in README discovery
        do {
            let (data, _) = try await HFHubRequestManager.shared.data(for: req.url!,
                                                                      accept: "application/json",
                                                                      timeout: 10)
            struct Meta: Decodable { let siblings: [Sibling]?; struct Sibling: Decodable { let rfilename: String } }
            let meta = try JSONDecoder().decode(Meta.self, from: data)
            let candidates = (meta.siblings ?? []).map { $0.rfilename }
                .sorted { $0.count < $1.count }
                .filter { $0.lowercased().contains("readme") && $0.lowercased().hasSuffix(".md") }
            if let first = candidates.first {
                return URL(string: "https://huggingface.co/\(repo)/resolve/\(branch)/\(first)")
            }
        } catch { }
        return nil
    }

    private func fetchURL(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        // Don't send Authorization for README file fetch
        do {
            let (data, resp) = try await HFHubRequestManager.shared.data(for: req.url!,
                                                                         accept: nil,
                                                                         timeout: 10)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return data }
        } catch { }
        return nil
    }

    // MARK: - Preprocessing and Rendering
    private static func preprocess(_ text: String, repo: String) -> String {
        var result = text
        
        // Preserve YAML frontmatter (don't remove it anymore)
        // The ReadmeMobileFormatter will handle frontmatter preservation
        
        // Remove key:value metadata block (only if it's not YAML frontmatter)
        if let firstBlank = result.range(of: "\\n\\s*\\n") {
            let lines = result[result.startIndex..<firstBlank.lowerBound].split(separator: "\n")
            // Only remove if it's not YAML frontmatter (doesn't start with ---)
            if lines.allSatisfy({ $0.contains(":") && !$0.contains("[") }) && 
               !result.hasPrefix("---") {
                result.removeSubrange(result.startIndex..<firstBlank.upperBound)
            }
        }
        
        // rewrite relative urls (via the configured HF endpoint so images load behind mirrors)
        let base = "\(HFEndpoint.webBaseString)/\(repo)/resolve/main/"
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

    private static func firstSentence(from markdown: String) -> String? {
        let plain = markdown.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[#*`_]", with: "", options: .regularExpression)
        for sentence in plain.components(separatedBy: CharacterSet(charactersIn: ".!?")) {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func preferredSummary(cardData: String?, readme: String?) -> String? {
        if let sum = cardData, !sum.isEmpty { return String(sum.prefix(140)) }
        if let read = readme, !read.isEmpty { return String(read.prefix(140)) }
        return nil
    }

    static func fetchSummary(repo: String, token: String?) async -> String? {
        var comps = URLComponents(string: "https://huggingface.co/api/models/\(repo)")!
        comps.queryItems = [URLQueryItem(name: "cardData", value: "true")]
        let req = URLRequest(url: comps.url!)
        do {
            let (data, _) = try await HFHubRequestManager.shared.data(for: req.url!,
                                                                      token: token,
                                                                      accept: "application/json",
                                                                      timeout: 10)
            struct Meta: Decodable { let cardData: Card?; struct Card: Decodable { let summary: String? } }
            let meta = try JSONDecoder().decode(Meta.self, from: data)
            return meta.cardData?.summary
        } catch {
            return nil
        }
    }
}