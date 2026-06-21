import XCTest
@testable import Noema

final class CuratedModelNotesTests: XCTestCase {
    func testDetectsCommonModelFamiliesFromRepositoryID() {
        XCTAssertEqual(CuratedModelNotes.note(for: "Qwen/Qwen3-4B-Instruct-GGUF")?.id, "qwen")
        XCTAssertEqual(CuratedModelNotes.note(for: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF")?.id, "llama")
        XCTAssertEqual(CuratedModelNotes.note(for: "google/gemma-3-4b-it-qat-q4_0-gguf")?.id, "gemma")
        XCTAssertEqual(CuratedModelNotes.note(for: "mistralai/Mixtral-8x7B-Instruct-v0.1")?.id, "mistral")
        XCTAssertEqual(CuratedModelNotes.note(for: "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B")?.id, "deepseek")
        XCTAssertEqual(CuratedModelNotes.note(for: "microsoft/phi-4-mini-instruct")?.id, "phi")
    }

    func testAppleFoundationModelNoteUsesSystemRuntimeContext() {
        let note = CuratedModelNotes.note(for: "apple/system-foundation-model")

        XCTAssertEqual(note?.id, "apple-foundation")
        XCTAssertEqual(note?.systemImage, "apple.intelligence")
    }

    func testUnknownFamiliesDoNotShowCuratedNotes() {
        XCTAssertNil(CuratedModelNotes.note(for: "example/unknown-research-model"))
    }
}
