import XCTest
@testable import Noema

final class ModelMoEGuidanceTests: XCTestCase {
    func testMixtralStyleIDInfersTopTwoRouting() throws {
        let detail = makeDetail(id: "mistralai/Mixtral-8x7B-Instruct-v0.1-GGUF")

        let guidance = try XCTUnwrap(ModelMoEGuidance.make(for: detail))

        XCTAssertEqual(
            guidance.metrics.first { $0.id == "routing" }?.value,
            String.localizedStringWithFormat(
                String(localized: "Active experts per token: %@ of %@"),
                "2",
                "8"
            )
        )
    }

    func testExplicitTopKRoutingIsClampedToTotalExperts() throws {
        let detail = makeDetail(id: "owner/model-moe-4x3b-top8-gguf")

        let guidance = try XCTUnwrap(ModelMoEGuidance.make(for: detail))

        XCTAssertEqual(
            guidance.metrics.first { $0.id == "routing" }?.value,
            String.localizedStringWithFormat(
                String(localized: "Active experts per token: %@ of %@"),
                "4",
                "4"
            )
        )
    }

    func testDenseModelDoesNotShowMoEGuidance() {
        let detail = makeDetail(id: "meta-llama/Llama-3.2-3B-Instruct-GGUF")

        XCTAssertNil(ModelMoEGuidance.make(for: detail))
    }

    private func makeDetail(id: String) -> ModelDetails {
        ModelDetails(
            id: id,
            summary: nil,
            quants: [],
            promptTemplate: nil
        )
    }
}
