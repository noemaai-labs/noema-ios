import Foundation
import XCTest
@testable import Noema

final class RemoteVisionToolsTests: XCTestCase {

    private func model(name: String = "Test Model",
                       id: String = "test/model",
                       supportedParameters: [String]? = nil,
                       inputModalities: [String]? = nil) -> RemoteModel {
        RemoteModel(id: id, name: name, author: "test",
                    supportedParameters: supportedParameters,
                    inputModalities: inputModalities)
    }

    // MARK: - Vision capability resolution

    func testStructuredModalitiesAreAuthoritative() {
        XCTAssertTrue(model(inputModalities: ["text", "image"]).isVisionModel)
        // "vision" in the name must not override an explicit text-only catalog.
        XCTAssertFalse(model(name: "SuperVision Pro", inputModalities: ["text"]).isVisionModel)
    }

    func testHeuristicFallbackWithoutStructuredModalities() {
        XCTAssertTrue(model(name: "PixWorld Vision 8B").isVisionModel)
        XCTAssertFalse(model(name: "TextOnly 7B").isVisionModel)
    }

    func testRemoteModelDecodesWithoutInputModalities() throws {
        // Persisted cachedModels from installs that predate the field.
        let legacy = #"{"id":"m","name":"M","author":"a","isCustom":false}"#
        let decoded = try JSONDecoder().decode(RemoteModel.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.inputModalities)
        XCTAssertFalse(decoded.isVisionModel)
    }

    // MARK: - Tool capability gate

    @MainActor
    func testRemoteModelSupportsToolsGate() {
        // No catalog metadata (LM Studio/Ollama/custom) stays permissive.
        XCTAssertTrue(ChatVM.remoteModelSupportsTools(model(supportedParameters: nil)))
        XCTAssertTrue(ChatVM.remoteModelSupportsTools(model(supportedParameters: ["tools", "temperature"])))
        XCTAssertFalse(ChatVM.remoteModelSupportsTools(model(supportedParameters: ["temperature"])))
    }

    // MARK: - Image encoding

    private func writeTempFile(_ data: Data, ext: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-vision-test-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testImageContentObjectShapeWithRawFallback() throws {
        // Bytes that aren't a decodable image exercise the raw fallback: the
        // payload ships as-is with a mime from the extension.
        let path = try writeTempFile(Data([0x00, 0x01, 0x02, 0x03]), ext: "png")
        let object = try XCTUnwrap(RemoteImageEncoding.imageContentObject(forPath: path))
        XCTAssertEqual(object["type"] as? String, "image_url")
        let urlDict = try XCTUnwrap(object["image_url"] as? [String: Any])
        let url = try XCTUnwrap(urlDict["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
    }

    func testImageContentObjectNilForUnreadablePath() {
        XCTAssertNil(RemoteImageEncoding.imageContentObject(forPath: "/nonexistent/nope.jpg"))
    }

    // MARK: - User content assembly

    func testUserContentValuePlainWithoutImages() {
        XCTAssertEqual(RemoteChatService.userContentValue(prompt: "hello", imagePaths: []) as? String, "hello")
    }

    func testUserContentValueFallsBackToTextWhenNoImageEncodes() {
        let value = RemoteChatService.userContentValue(prompt: "hello", imagePaths: ["/nonexistent/nope.jpg"])
        XCTAssertEqual(value as? String, "hello")
    }

    func testUserContentValueBuildsPartsArray() throws {
        let path = try writeTempFile(Data([0xFF, 0xD8, 0xFF, 0xE0]), ext: "jpg")
        let value = RemoteChatService.userContentValue(prompt: "what is this?", imagePaths: [path])
        let parts = try XCTUnwrap(value as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "what is this?")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
    }
}
