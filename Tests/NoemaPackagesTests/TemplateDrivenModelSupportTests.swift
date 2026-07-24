import Foundation
import XCTest
@testable import NoemaPackages

final class TemplateDrivenModelSupportTests: XCTestCase {
    func testEmbeddedTemplateParsingSkipsStringArrays() throws {
        let directory = try makeTemporaryDirectory()
        let modelURL = directory.appendingPathComponent("model.gguf")
        let template = "{% for message in messages %}{{ message.content }}{% endfor %}"
        var data = ggufHeader(metadataCount: 2)
        appendStringArray(key: "tokenizer.ggml.tokens", values: ["one", "two"], to: &data)
        appendString(key: "tokenizer.chat_template", value: template, to: &data)
        try data.write(to: modelURL)

        let materializedPath = try XCTUnwrap(
            TemplateDrivenModelSupport.resolveChatTemplateFile(modelURL: modelURL)
        )
        defer { try? FileManager.default.removeItem(atPath: materializedPath) }
        XCTAssertEqual(try String(contentsOfFile: materializedPath, encoding: .utf8), template)
    }

    func testEmbeddedTemplateParsingRejectsOverflowingLength() throws {
        let directory = try makeTemporaryDirectory()
        let modelURL = directory.appendingPathComponent("malformed.gguf")
        var data = ggufHeader(metadataCount: 1)
        appendUInt64(.max, to: &data)
        try data.write(to: modelURL)

        XCTAssertNil(TemplateDrivenModelSupport.resolveChatTemplateFile(modelURL: modelURL))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func ggufHeader(metadataCount: UInt64) -> Data {
        var data = Data("GGUF".utf8)
        appendUInt32(3, to: &data)
        appendUInt64(0, to: &data)
        appendUInt64(metadataCount, to: &data)
        return data
    }

    private func appendString(key: String, value: String, to data: inout Data) {
        appendStringPayload(key, to: &data)
        appendUInt32(8, to: &data)
        appendStringPayload(value, to: &data)
    }

    private func appendStringArray(key: String, values: [String], to data: inout Data) {
        appendStringPayload(key, to: &data)
        appendUInt32(9, to: &data)
        appendUInt32(8, to: &data)
        appendUInt64(UInt64(values.count), to: &data)
        values.forEach { appendStringPayload($0, to: &data) }
    }

    private func appendStringPayload(_ string: String, to data: inout Data) {
        let bytes = Data(string.utf8)
        appendUInt64(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
