import XCTest
@testable import Noema

final class ModelCollectionClassifierTests: XCTestCase {
    func testClassifiesCommonCollectionSignals() {
        XCTAssertTrue(collections(for: "Qwen/Qwen3-Coder-4B-Instruct", tags: ["function-calling"]).contains(.coding))
        XCTAssertTrue(collections(for: "Qwen/Qwen3-Coder-4B-Instruct", tags: ["function-calling"]).contains(.toolCapable))
        XCTAssertTrue(collections(for: "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B").contains(.reasoning))
        XCTAssertTrue(collections(for: "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B").contains(.tinyFast))
        XCTAssertTrue(collections(for: "google/gemma-3-4b-it", summary: "Multilingual compact assistant").contains(.multilingual))
        XCTAssertTrue(collections(for: "math-ai/NuminaMath-7B", summary: "AIME and olympiad math model").contains(.math))
    }

    func testVisionUsesPipelineAndSupportSignals() {
        let pipelineRecord = makeRecord(
            id: "llava/vision-model",
            pipelineTag: "image-text-to-text",
            supportsVision: false
        )
        let supportRecord = makeRecord(
            id: "example/plain-name",
            pipelineTag: nil,
            supportsVision: true
        )

        XCTAssertTrue(ModelCollectionClassifier.collections(for: pipelineRecord).contains(.vision))
        XCTAssertTrue(ModelCollectionClassifier.collections(for: supportRecord).contains(.vision))
    }

    func testOptionalFilterKeepsAllWhenNoCollectionSelected() {
        let record = makeRecord(id: "example/Plain-7B")

        XCTAssertTrue(ModelCollectionClassifier.record(record, matches: nil))
        XCTAssertFalse(ModelCollectionClassifier.record(record, matches: .coding))
    }

    private func collections(
        for id: String,
        summary: String? = nil,
        tags: [String]? = nil
    ) -> Set<ModelCollection> {
        ModelCollectionClassifier.collections(for: makeRecord(id: id, summary: summary, tags: tags))
    }

    private func makeRecord(
        id: String,
        summary: String? = nil,
        tags: [String]? = nil,
        pipelineTag: String? = nil,
        supportsVision: Bool = false
    ) -> ModelRecord {
        ModelRecord(
            id: id,
            displayName: id.split(separator: "/").last.map(String.init) ?? id,
            publisher: id.split(separator: "/").first.map(String.init) ?? "",
            summary: summary,
            hasInstallableQuant: true,
            formats: [.gguf],
            installed: false,
            tags: tags,
            pipeline_tag: pipelineTag,
            supportsVision: supportsVision
        )
    }
}
