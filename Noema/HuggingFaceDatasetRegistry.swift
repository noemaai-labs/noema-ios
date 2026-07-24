import Foundation

/// Registry for searching datasets on Hugging Face Hub.
public final class HuggingFaceDatasetRegistry: DatasetRegistry, @unchecked Sendable {
    private let session: URLSession
    private let token: String?

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        if let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            self.token = t
        } else {
            self.token = nil
        }
    }

    enum RegistryError: LocalizedError {
        case badStatus(Int)
        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                return "Server error (HTTP \(code))"
            }
        }
    }

    public func curated() async throws -> [DatasetRecord] { [] }

    public func searchStream(query: String, perPage: Int, maxPages: Int) -> AsyncThrowingStream<DatasetRecord, Error> {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .init { $0.finish() } }
        return .init { continuation in
            let task = Task {
                var seen = Set<String>()
                for page in 0..<maxPages {
                    if Task.isCancelled { break }
                    var comps = URLComponents(string: "https://huggingface.co/api/datasets")!
                    comps.queryItems = [
                        URLQueryItem(name: "search", value: trimmed),
                        URLQueryItem(name: "sort", value: "downloads"),
                        URLQueryItem(name: "limit", value: String(perPage)),
                        URLQueryItem(name: "offset", value: String(page * perPage)),
                        URLQueryItem(name: "cardData", value: "true")
                    ]
                    let url = comps.url!
                    var data: Data
                    do {
                        (data, _) = try await self.data(from: url)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    struct Entry: Decodable {
                        let id: String
                        let author: String?
                        let cardData: Card?
                        struct Card: Decodable { let description: String? }
                    }
                    guard let pageResults = try? JSONDecoder().decode([Entry].self, from: data) else { break }
                    if pageResults.isEmpty { break }
                    for entry in pageResults {
                        if seen.insert(entry.id).inserted {
                            let record = DatasetRecord(id: entry.id,
                                                      displayName: Self.prettyName(from: entry.id),
                                                      publisher: entry.author ?? "",
                                                      summary: entry.cardData?.description,
                                                      installed: false)
                            continuation.yield(record)
                        }
                    }
                    if pageResults.count < perPage { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func details(for id: String) async throws -> DatasetDetails {
        var comps = URLComponents(string: "https://huggingface.co/api/datasets/\(id)")!
        comps.queryItems = [URLQueryItem(name: "full", value: "1"), URLQueryItem(name: "cardData", value: "true")]
        let (data, _) = try await self.data(from: comps.url!)
        struct Meta: Decodable {
            let id: String
            let cardData: Card?
            let siblings: [Sibling]?
            struct Card: Decodable { let description: String? }
            struct Sibling: Decodable {
                let rfilename: String
                let size: Int?
                let lfs: LFS?
                struct LFS: Decodable { let size: Int? }
            }
        }
        let meta = try JSONDecoder().decode(Meta.self, from: data)
        var files = (meta.siblings ?? []).map { sib in
            DatasetFile(id: sib.rfilename,
                        name: sib.rfilename,
                        sizeBytes: Int64(sib.lfs?.size ?? sib.size ?? 0),
                        downloadURL: URL(string: "https://huggingface.co/datasets/\(id)/resolve/main/\(sib.rfilename)?download=1")!)
        }
        for i in files.indices {
            if files[i].sizeBytes == 0 {
                if let size = try? await fetchSize(files[i].downloadURL) {
                    files[i] = DatasetFile(id: files[i].id,
                                           name: files[i].name,
                                           sizeBytes: size,
                                           downloadURL: files[i].downloadURL)
                }
            }
        }
        // For HF, prefer a pretty name derived from id; cardData title is not guaranteed
        let pretty = Self.prettyName(from: meta.id)
        return DatasetDetails(id: meta.id, summary: meta.cardData?.description, files: files, displayName: pretty)
    }

    private func data(from url: URL) async throws -> (Data, URLResponse) {
        print("[dataset registry] GET \(url.absoluteString)")
        let (data, resp) = try await HFHubRequestManager.shared.data(for: url,
                                                                     token: token,
                                                                     accept: "application/json")
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RegistryError.badStatus(http.statusCode)
        }
        return (data, resp)
    }

    private func fetchSize(_ url: URL) async throws -> Int64 {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "download" }) {
            items.append(URLQueryItem(name: "download", value: "1"))
        }
        comps.queryItems = items

        let (_, resp) = try await HFHubRequestManager.shared.data(for: comps.url!,
                                                                  token: token,
                                                                  method: "HEAD")
        guard let http = resp as? HTTPURLResponse else { return 0 }

        if let linked = http.value(forHTTPHeaderField: "X-Linked-Size"),
           let len = Int64(linked) { return len }
        if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
           let len = Int64(lenStr), len > 0 { return len }
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last,
           let len = Int64(total) { return len }
        return http.expectedContentLength > 0 ? http.expectedContentLength : 0
    }

    private static func prettyName(from id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        var cleaned = base.replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }
}
