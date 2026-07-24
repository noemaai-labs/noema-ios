import Foundation
import XCTest
@testable import Noema

final class WebResearchTests: XCTestCase {
    func testToolSchemaExposesResearchOpenAndFind() {
        let schema = WebRetrieveTool().schema
        XCTAssertTrue(schema.contains(#""operation""#))
        XCTAssertTrue(schema.contains(#""research""#))
        XCTAssertTrue(schema.contains(#""open""#))
        XCTAssertTrue(schema.contains(#""find""#))
        XCTAssertTrue(schema.contains(#""source_ref""#))
        XCTAssertTrue(schema.contains(#""time_range""#))
    }

    func testLegacySearchArrayDecodesAsSnippetEnvelope() throws {
        let data = Data(#"[{"title":"Result","url":"https://example.com/story?utm_source=x","snippet":"Snippet","engine":"searxng","score":0.5}]"#.utf8)
        let envelope = try XCTUnwrap(WebToolResultDecoder.envelope(from: data))
        XCTAssertEqual(envelope.version, 2)
        XCTAssertEqual(envelope.operation, .research)
        XCTAssertFalse(envelope.capabilities.richRetrieval)
        XCTAssertEqual(envelope.sources.first?.fetchStatus, .snippetOnly)
        XCTAssertEqual(envelope.sources.first?.canonicalURL, "https://example.com/story")
    }

    func testVersionedEvidenceEnvelopeDecodesLocations() throws {
        let data = Data(#"{"version":2,"operation":"research","sources":[{"citation_index":2,"source_ref":"signed","title":"Report","url":"https://example.com/report.pdf","canonical_url":"https://example.com/report.pdf","domain":"example.com","snippet":"","engine":"bing","engines":["bing"],"content_type":"pdf","fetch_status":"read","passages":[{"id":"p2","text":"Evidence","page":7,"relevance":0.9}]}],"warnings":[],"capabilities":{"rich_retrieval":true,"html":true,"text_pdf":true,"javascript":false,"ocr":false}}"#.utf8)
        let envelope = try XCTUnwrap(WebToolResultDecoder.envelope(from: data))
        XCTAssertEqual(envelope.sources.first?.citationIndex, 2)
        XCTAssertEqual(envelope.sources.first?.contentType, .pdf)
        XCTAssertEqual(envelope.sources.first?.passages.first?.page, 7)
    }

    func testVersionedEvidenceEnvelopeFormatsAsWebResults() {
        let result = #"{"version":2,"operation":"research","sources":[{"citation_index":1,"source_ref":"signed","title":"Evidence source","url":"https://example.com/story","canonical_url":"https://example.com/story","domain":"example.com","snippet":"Supporting text","engine":"direct","engines":["direct"],"content_type":"html","fetch_status":"read","passages":[]}],"warnings":[],"capabilities":{"rich_retrieval":true,"html":true,"text_pdf":true,"javascript":false,"ocr":false}}"#
        let items = ToolCallViewSupport.parseWebResults(from: result)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Evidence source")
        XCTAssertEqual(items.first?.url, "https://example.com/story")
    }

    func testDirectURLRecognitionDoesNotMistakeSignedReferencesForDomains() {
        XCTAssertEqual(WebURLNormalizer.directURLString("noemaai.com"), "https://noemaai.com")
        XCTAssertEqual(WebURLNormalizer.directURLString("https://noemaai.com/about#team"), "https://noemaai.com/about")
        XCTAssertNil(WebURLNormalizer.directURLString("eyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tIn0.abcdefghijklmnopqrstuvwxyzABCDEFGHI"))
        XCTAssertNil(WebURLNormalizer.directURLString("https://user:password@example.com"))
        XCTAssertNil(WebURLNormalizer.directURLString("https://example.com:8443"))
    }

    func testEvidenceMergePreservesCitationAndUpgradesPassages() {
        let existing = ChatVM.Msg.WebHit(
            id: "2",
            title: "Result",
            snippet: "Snippet",
            url: "https://example.com/story",
            engine: "bing",
            score: 0.4,
            sourceRef: "signed",
            canonicalURL: "https://example.com/story",
            fetchStatus: WebFetchStatus.snippetOnly.rawValue
        )
        let passage = WebEvidencePassage(
            id: "evidence",
            text: "Located evidence",
            heading: "Results",
            lineStart: 10,
            lineEnd: 12,
            page: nil,
            relevance: 1
        )
        let source = WebEvidenceSource(
            citationIndex: 1,
            sourceRef: "signed",
            title: "Result",
            url: "https://example.com/story",
            canonicalURL: "https://example.com/story",
            domain: "example.com",
            snippet: "Snippet",
            engine: "bing",
            engines: ["bing"],
            author: nil,
            publishedAt: nil,
            fetchedAt: nil,
            contentType: .html,
            fetchStatus: .read,
            contentHash: "hash",
            passages: [passage],
            nextCursor: nil
        )
        let envelope = WebRetrieveEnvelope(
            version: 2,
            operation: .open,
            sources: [source],
            warnings: [],
            capabilities: .rich
        )
        let merged = WebEvidenceMessageMapper.merging(existing: [existing], envelope: envelope)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "2")
        XCTAssertEqual(merged[0].fetchStatus, WebFetchStatus.read.rawValue)
        XCTAssertEqual(merged[0].passages?.first?.id, "evidence")
    }

    func testCitationLinkifierUsesKnownSourceURLOnly() {
        let hit = ChatVM.Msg.WebHit(
            id: "1",
            title: "Result",
            snippet: "",
            url: "https://example.com/story",
            engine: "bing",
            score: 1
        )
        let linked = WebCitationLinkifier.linkify("Supported claim [1], unknown [2].", hits: [hit])
        XCTAssertEqual(linked, "Supported claim [1](https://example.com/story), unknown [2].")
    }

    func testCitationLinkifierLinksEveryAdjacentKnownSource() {
        let hits = (1...3).map { index in
            ChatVM.Msg.WebHit(
                id: String(index),
                title: "Result \(index)",
                snippet: "",
                url: "https://example.com/source-\(index)",
                engine: "bing",
                score: 1
            )
        }

        let linked = WebCitationLinkifier.linkify("Supported by [1][2][3].", hits: hits)

        XCTAssertEqual(
            linked,
            "Supported by [1](https://example.com/source-1)[2](https://example.com/source-2)[3](https://example.com/source-3)."
        )
    }

    func testOldPersistedWebHitStillDecodes() throws {
        let data = Data(#"{"id":"1","title":"Old","snippet":"Legacy","url":"https://example.com","engine":"searxng","score":0.2}"#.utf8)
        let hit = try JSONDecoder().decode(ChatVM.Msg.WebHit.self, from: data)
        XCTAssertNil(hit.sourceRef)
        XCTAssertNil(hit.passages)
    }

    func testCustomInstanceHasNoReaderEndpoint() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "customSearXNGURL")
        defer {
            if let previous { defaults.set(previous, forKey: "customSearXNGURL") }
            else { defaults.removeObject(forKey: "customSearXNGURL") }
        }
        defaults.set("https://search.example.com/search", forKey: "customSearXNGURL")
        XCTAssertFalse(SearXNGSearchConfig.isDefaultInstance)
        XCTAssertNil(SearXNGSearchConfig.readerEndpointURL())
    }

    func testOnDeviceAFMRemainsIneligibleForWebRetrieval() {
        XCTAssertFalse(WebToolGate.isAvailable(currentFormat: .afm, afmKind: .onDevice))
    }
}
