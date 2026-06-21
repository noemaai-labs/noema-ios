import XCTest
@testable import Noema

final class TokenLatencySparklineTests: XCTestCase {
    func testSparklineReturnsEmptyForNoSamples() {
        XCTAssertEqual(TokenLatencySparkline.sparkline(for: []), "")
    }

    func testSparklineKeepsOneGlyphPerSample() {
        let sparkline = TokenLatencySparkline.sparkline(for: [10, 20, 40, 80])

        XCTAssertEqual(sparkline.count, 4)
        XCTAssertNotEqual(sparkline.first, sparkline.last)
    }

    func testMaxLatencyIgnoresInvalidSamples() {
        XCTAssertEqual(
            TokenLatencySparkline.maxLatencyMilliseconds([12, .infinity, -4, 33]),
            33
        )
    }

    func testLegacyPerfDecodingDefaultsLatencySamples() throws {
        let json = """
        {
          "tokenCount": 12,
          "avgTokPerSec": 8.5,
          "timeToFirst": 0.42
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ChatVM.Msg.Perf.self, from: json)

        XCTAssertEqual(decoded.tokenCount, 12)
        XCTAssertEqual(decoded.avgTokPerSec, 8.5)
        XCTAssertEqual(decoded.timeToFirst, 0.42)
        XCTAssertEqual(decoded.latencySamplesMs, [])
    }
}
