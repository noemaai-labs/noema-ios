import Foundation

enum WebEvidenceMessageMapper {
    static func hits(from envelope: WebRetrieveEnvelope) -> [ChatVM.Msg.WebHit] {
        envelope.sources.map { makeHit($0) }
    }

    static func merging(
        existing: [ChatVM.Msg.WebHit]?,
        envelope: WebRetrieveEnvelope
    ) -> [ChatVM.Msg.WebHit] {
        var output = existing ?? []
        for source in envelope.sources {
            let canonical = source.canonicalURL
            let existingIndex = output.firstIndex { hit in
                if let sourceRef = source.sourceRef, hit.sourceRef == sourceRef { return true }
                return (hit.canonicalURL ?? WebURLNormalizer.canonicalURLString(hit.url)) == canonical
            }
            if let existingIndex {
                let previous = output[existingIndex]
                output[existingIndex] = makeHit(source, id: previous.id, fallback: previous)
            } else {
                let preferred = max(1, source.citationIndex)
                let used = Set(output.compactMap { Int($0.id) })
                var assigned = preferred
                while used.contains(assigned) { assigned += 1 }
                output.append(makeHit(source, id: String(assigned)))
            }
        }
        return output.sorted { (Int($0.id) ?? .max) < (Int($1.id) ?? .max) }
    }

    private static func makeHit(
        _ source: WebEvidenceSource,
        id: String? = nil,
        fallback: ChatVM.Msg.WebHit? = nil
    ) -> ChatVM.Msg.WebHit {
        let passages = source.passages.map { passage in
            ChatVM.Msg.WebPassage(
                id: passage.id,
                text: passage.text,
                heading: passage.heading,
                lineStart: passage.lineStart,
                lineEnd: passage.lineEnd,
                page: passage.page,
                relevance: passage.relevance
            )
        }
        return ChatVM.Msg.WebHit(
            id: id ?? String(max(1, source.citationIndex)),
            title: source.title,
            snippet: source.snippet,
            url: source.url,
            engine: source.engine,
            score: fallback?.score ?? source.passages.first?.relevance ?? 0,
            sourceRef: source.sourceRef ?? fallback?.sourceRef,
            canonicalURL: source.canonicalURL,
            domain: source.domain,
            engines: source.engines,
            author: source.author ?? fallback?.author,
            publishedAt: source.publishedAt ?? fallback?.publishedAt,
            fetchedAt: source.fetchedAt ?? fallback?.fetchedAt,
            contentType: source.contentType.rawValue,
            fetchStatus: source.fetchStatus.rawValue,
            contentHash: source.contentHash ?? fallback?.contentHash,
            passages: passages.isEmpty ? fallback?.passages : passages,
            nextCursor: source.nextCursor
        )
    }
}

enum WebCitationLinkifier {
    private static let pattern = try! NSRegularExpression(pattern: #"\[([1-9][0-9]*)\](?!\()"#)

    static func linkify(_ text: String, hits: [ChatVM.Msg.WebHit]?) -> String {
        guard let hits, !hits.isEmpty else { return text }
        let links = Dictionary(hits.compactMap { hit -> (Int, String)? in
            guard let index = Int(hit.id),
                  let url = URL(string: hit.url),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (index, url.absoluteString)
        }, uniquingKeysWith: { current, _ in current })
        guard !links.isEmpty else { return text }

        let source = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let output = NSMutableString(string: text)
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                  let index = Int(source.substring(with: match.range(at: 1))),
                  let url = links[index] else { continue }
            output.replaceCharacters(in: match.range, with: "[\(index)](\(url))")
        }
        return output as String
    }
}

extension ChatVM {
    @MainActor
    func applyWebToolResult(_ data: Data, messageIndex: Int) {
        guard streamMsgs.indices.contains(messageIndex) else { return }
        streamMsgs[messageIndex].usedWebSearch = true
        if let envelope = WebToolResultDecoder.envelope(from: data) {
            if envelope.sources.isEmpty {
                streamMsgs[messageIndex].webError = "No results found"
                return
            }
            streamMsgs[messageIndex].webError = nil
            streamMsgs[messageIndex].webHits = WebEvidenceMessageMapper.merging(
                existing: streamMsgs[messageIndex].webHits,
                envelope: envelope
            )
        } else if let error = WebToolResultDecoder.error(from: data), !error.error.isEmpty {
            streamMsgs[messageIndex].webError = error.error
        }
    }
}
