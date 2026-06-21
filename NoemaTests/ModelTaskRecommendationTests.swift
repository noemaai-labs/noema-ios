import XCTest
@testable import Noema

final class ModelTaskRecommendationTests: XCTestCase {
    func testCodingReasoningModelGetsTaskRecommendations() {
        let details = makeDetails(
            id: "deepseek-ai/DeepSeek-Coder-R1-GGUF",
            summary: "Reasoning code assistant with structured JSON outputs.",
            quants: [makeQuant(label: "Q4_K_M", format: .gguf, sizeBytes: 4_000_000_000)]
        )

        let recommendations = ModelTaskRecommendationClassifier.recommendations(for: details)

        XCTAssertTrue(recommendations.contains(.generalChat))
        XCTAssertTrue(recommendations.contains(.coding))
        XCTAssertTrue(recommendations.contains(.reasoning))
        XCTAssertTrue(recommendations.contains(.toolUse))
    }

    func testVisionModelGetsVisionRecommendation() {
        let details = makeDetails(
            id: "owner/llava-vlm-gguf",
            summary: "Multimodal image-text model.",
            quants: [makeQuant(label: "Q4_K_M", format: .gguf, sizeBytes: 3_500_000_000)]
        )

        let recommendations = ModelTaskRecommendationClassifier.recommendations(for: details)

        XCTAssertTrue(recommendations.contains(.vision))
    }

    func testSmallETModelGetsQuickLocalRecommendation() {
        let details = makeDetails(
            id: "owner/tiny-et",
            summary: "Small on-device assistant.",
            quants: [makeQuant(label: "ExecuTorch", format: .et, sizeBytes: 900_000_000)]
        )

        let recommendations = ModelTaskRecommendationClassifier.recommendations(for: details)

        XCTAssertTrue(recommendations.contains(.quickLocal))
    }

    func testGenericModelStillGetsGeneralChat() {
        let details = makeDetails(
            id: "owner/basic-chat",
            summary: nil,
            quants: [makeQuant(label: "Q6_K", format: .gguf, sizeBytes: 5_000_000_000)]
        )

        XCTAssertEqual(ModelTaskRecommendationClassifier.recommendations(for: details), [.generalChat])
    }

    private func makeDetails(id: String, summary: String?, quants: [QuantInfo]) -> ModelDetails {
        ModelDetails(
            id: id,
            summary: summary,
            quants: quants,
            promptTemplate: nil
        )
    }

    private func makeQuant(label: String, format: ModelFormat, sizeBytes: Int64) -> QuantInfo {
        QuantInfo(
            label: label,
            format: format,
            sizeBytes: sizeBytes,
            downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/model.bin")!,
            sha256: nil,
            configURL: nil
        )
    }
}
