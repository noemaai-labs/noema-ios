import Foundation

public struct DatasetSearchTool: Tool {
    public let name = "noema.rag.search"

    /// Computed so the model is told *which* datasets actually exist on this device.
    /// It lists only indexed (embedded) datasets by title, so the model can decide from
    /// the titles alone whether searching is worthwhile, and explains exactly what it
    /// gets back (scored citations to quote).
    public var description: String {
        let titles = DatasetManager.indexedDatasetsForTooling()
            .map(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let availability: String
        if titles.isEmpty {
            availability = "There are no indexed datasets on this device right now, so this tool currently has nothing to search."
        } else {
            let list = titles.map { "\"\($0)\"" }.joined(separator: ", ")
            availability = "Indexed datasets you can search (by title): \(list)."
        }
        return """
        Search the user's own indexed documents and knowledge packs and ground your answer in them. \(availability) \
        Call this tool when one of those dataset titles looks relevant to the user's question: it runs semantic \
        retrieval and returns up to 8 ranked citations — each an exact excerpt with its source title and a 0–1 \
        relevance score — which you should quote and cite in your reply. If none of the titles look relevant to \
        the question, do not call it; just answer normally.
        """
    }
    public let schema = #"""
    { "type":"object", "properties":{
        "query":{"type":"string","description":"What to look for, as search keywords or a short topic phrase (the words you'd expect in the source text), e.g. \"eigenvalues\" or \"eigenvalue decomposition\" — NOT a full question."},
        "dataset":{"type":"string","description":"Optional dataset name or id to restrict the search to. Omit to search every indexed dataset."},
        "max_chunks":{"type":"integer","maximum":8,"minimum":1,"default":5,"description":"Maximum number of passages to return (1-8)."},
        "min_score":{"type":"number","minimum":0,"maximum":1,"default":0,"description":"Minimum relevance score to include (0-1). Higher is stricter."}
    }, "required":["query"] }
    """#

    public init() {}

    public func call(args: Data) async throws -> Data {
        struct SearchArgs: Decodable {
            // Optional so a missing `query` yields a corrective, model-readable
            // error instead of a DecodingError ("The data couldn't be read…")
            // the model can't act on. ChatVM's dispatch layer already backfills
            // an empty query from the user's message; this is the last resort.
            let query: String?
            let dataset: String?
            let max_chunks: Int?
            let min_score: Double?
        }
        let input = try JSONDecoder().decode(SearchArgs.self, from: args)
        let query = (input.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try encodeError(
                "Missing required `query` argument. Call noema.rag.search again with {\"query\": \"<search keywords>\"} — use the words you expect in the source text. Do not invent citations without search results."
            )
        }

        let maxChunks = max(1, min(input.max_chunks ?? 5, 8))
        let minScore = Float(max(0.0, min(input.min_score ?? 0.0, 1.0)))

        // Enumerate indexed, policy-allowed datasets off the main actor.
        let datasets = await Task.detached(priority: .userInitiated) {
            DatasetManager.indexedDatasetsForTooling()
        }.value

        guard !datasets.isEmpty else {
            return try encode(Output(results: [], datasets_searched: [],
                                     message: "No indexed datasets are available on this device. Ask the user to add a document or knowledge pack first."))
        }

        // Resolve which datasets to search.
        let targets: [LocalDataset]
        if let wanted = input.dataset?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty {
            guard let match = datasets.first(where: {
                $0.datasetID.caseInsensitiveCompare(wanted) == .orderedSame
                    || $0.name.caseInsensitiveCompare(wanted) == .orderedSame
            }) else {
                let names = datasets.map(\.name).joined(separator: ", ")
                return try encode(Output(results: [], datasets_searched: [],
                                         message: "No indexed dataset matches \"\(wanted)\". Available: \(names)."))
            }
            targets = [match]
        } else {
            targets = datasets
        }

        // Retrieval needs the embedding model warmed up.
        if !(await EmbeddingModel.shared.isReady()) {
            await EmbeddingModel.shared.ensureModel()
            await EmbeddingModel.shared.warmUp()
        }

        // Retrieve from each target and merge by score (cosine scores from the same
        // embedding model are directly comparable across datasets).
        var collected: [ResultItem] = []
        for ds in targets {
            if Task.isCancelled { break }
            let hits = await DatasetRetriever.shared.fetchContextDetailed(
                for: query,
                dataset: ds,
                maxChunks: maxChunks,
                minScore: minScore,
                mode: .balanced
            )
            for hit in hits {
                collected.append(ResultItem(text: hit.text, source: hit.source, score: hit.score, dataset: ds.name))
            }
        }
        collected.sort { ($0.score ?? 0) > ($1.score ?? 0) }
        let top = Array(collected.prefix(maxChunks))

        let message = top.isEmpty
            ? "No relevant passages found in \(targets.count) dataset\(targets.count == 1 ? "" : "s")."
            : nil
        return try encode(Output(results: top, datasets_searched: targets.map(\.name), message: message))
    }

    // MARK: - Output shapes

    private struct ResultItem: Encodable {
        let text: String
        let source: String?
        let score: Float?
        let dataset: String
    }

    private struct Output: Encodable {
        let results: [ResultItem]
        let datasets_searched: [String]
        let message: String?
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func encodeError(_ message: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["error": message])
    }
}
