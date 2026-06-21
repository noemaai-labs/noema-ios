import XCTest
@testable import Noema

final class GGUFMetadataTests: XCTestCase {
    func testHasMTPDoesNotMatchDraftTextWithoutNextNLayers() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("base-qwen.gguf")
        try writeGGUF(
            to: url,
            metadata: [
                .string("general.name", "Qwen draft model with mtp text in metadata"),
                .uint32("qwen35.nextn_predict_layers", 0)
            ],
            tensors: []
        )

        XCTAssertFalse(GGUFMetadata.hasMTP(at: url))
    }

    func testHasMTPMatchesPositiveNextNPredictLayerMetadata() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("qwen-mtp.gguf")
        try writeGGUF(
            to: url,
            metadata: [
                .uint32("qwen35.nextn_predict_layers", 1)
            ],
            tensors: []
        )

        XCTAssertTrue(GGUFMetadata.hasMTP(at: url))
    }

    func testHasMTPMatchesNextNTensorNames() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("qwen-mtp-tensor.gguf")
        try writeGGUF(
            to: url,
            metadata: [],
            tensors: ["blk.35.nextn.eh_proj.weight"]
        )

        XCTAssertTrue(GGUFMetadata.hasMTP(at: url))
    }

    private enum GGUFValue {
        case string(String, String)
        case uint32(String, UInt32)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func writeGGUF(to url: URL, metadata: [GGUFValue], tensors: [String]) throws {
        var data = Data()
        data.append(Data("GGUF".utf8))
        appendUInt32(3, to: &data)
        appendUInt64(UInt64(tensors.count), to: &data)
        appendUInt64(UInt64(metadata.count), to: &data)

        for value in metadata {
            switch value {
            case .string(let key, let string):
                appendString(key, to: &data)
                appendUInt32(8, to: &data)
                appendStringPayload(string, to: &data)
            case .uint32(let key, let integer):
                appendString(key, to: &data)
                appendUInt32(4, to: &data)
                appendUInt32(integer, to: &data)
            }
        }

        for tensor in tensors {
            appendString(tensor, to: &data)
            appendUInt32(1, to: &data)
            appendUInt64(1, to: &data)
            appendUInt32(0, to: &data)
            appendUInt64(0, to: &data)
        }

        try data.write(to: url)
    }

    private func appendString(_ string: String, to data: inout Data) {
        appendStringPayload(string, to: &data)
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
