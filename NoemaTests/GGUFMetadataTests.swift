import XCTest
import NoemaPackages
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

    func testPositiveNextNMetadataWithoutTensorsRequiresSidecar() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("qwen-mtp.gguf")
        try writeGGUF(
            to: url,
            metadata: [
                .string("general.architecture", "qwen35"),
                .uint32("qwen35.nextn_predict_layers", 1)
            ],
            tensors: []
        )

        XCTAssertEqual(GGUFMetadata.mtpCapability(at: url), .sidecarRequired)
        XCTAssertFalse(GGUFMetadata.hasMTP(at: url))
    }

    func testHasMTPMatchesNextNTensorNames() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("qwen-mtp-tensor.gguf")
        try writeGGUF(
            to: url,
            metadata: [
                .string("general.architecture", "qwen35"),
                .uint32("qwen35.nextn_predict_layers", 1)
            ],
            tensors: [
                "blk.35.nextn.eh_proj.weight",
                "blk.35.nextn.enorm.weight",
                "blk.35.nextn.hnorm.weight"
            ]
        )

        XCTAssertTrue(GGUFMetadata.hasMTP(at: url))
    }

    func testUnsupportedArchitectureIsNotAutoEnabled() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("unsupported-nextn.gguf")
        try writeGGUF(
            to: url,
            metadata: [
                .string("general.architecture", "deepseek32"),
                .uint32("deepseek32.nextn_predict_layers", 1)
            ],
            tensors: [
                "blk.35.nextn.eh_proj.weight",
                "blk.35.nextn.enorm.weight",
                "blk.35.nextn.hnorm.weight"
            ]
        )

        XCTAssertEqual(GGUFMetadata.mtpCapability(at: url), .declaredButUnsupported)
        XCTAssertFalse(GGUFMetadata.hasMTP(at: url))
    }

    func testSidecarValidationRequiresMatchingTokenizerAndDimensions() throws {
        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("qwen-target.gguf")
        let sidecar = root.appendingPathComponent("qwen-mtp.gguf")
        let incompatible = root.appendingPathComponent("qwen-mtp-other-vocab.gguf")
        let commonMetadata: [GGUFValue] = [
            .string("general.architecture", "qwen35"),
            .uint32("qwen35.nextn_predict_layers", 1),
            .uint32("qwen35.embedding_length", 2_048),
            .uint32("qwen35.vocab_size", 3),
            .stringArray("tokenizer.ggml.tokens", ["a", "b", "c"])
        ]
        let tensors = [
            "blk.35.nextn.eh_proj.weight",
            "blk.35.nextn.enorm.weight",
            "blk.35.nextn.hnorm.weight"
        ]
        try writeGGUF(to: target, metadata: commonMetadata, tensors: [])
        try writeGGUF(to: sidecar, metadata: commonMetadata, tensors: tensors)
        try writeGGUF(
            to: incompatible,
            metadata: commonMetadata.dropLast().map { $0 } + [
                .stringArray("tokenizer.ggml.tokens", ["a", "x", "c"])
            ],
            tensors: tensors
        )

        XCTAssertEqual(
            GGUFMetadata.mtpCapability(targetURL: target, sidecarURL: sidecar),
            .sidecarValidated(sidecar)
        )
        XCTAssertEqual(
            GGUFMetadata.mtpCapability(targetURL: target, sidecarURL: incompatible),
            .unavailable
        )
    }

    func testMetadataParsersSkipStringArraysWithoutLosingLaterValues() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("metadata-after-token-array.gguf")
        let template = "{% for message in messages %}{{ message.content }}{% endfor %}"
        try writeGGUF(
            to: url,
            metadata: [
                .stringArray("tokenizer.ggml.tokens", ["one", "two", "three"]),
                .string("general.architecture", "llama"),
                .uint32("llama.block_count", 48),
                .uint32("llama.context_length", 32_768),
                .string("tokenizer.chat_template", template),
                .string("llava.projector_type", "mlp")
            ],
            tensors: []
        )

        XCTAssertEqual(GGUFMetadata.architectureInfo(at: url)?.architecture, "llama")
        XCTAssertEqual(GGUFMetadata.layerCount(at: url), 48)
        XCTAssertEqual(GGUFMetadata.contextLength(at: url), 32_768)
        XCTAssertEqual(GGUFMetadata.chatTemplate(at: url), template)
        XCTAssertTrue(GGUFMetadata.hasMultimodalProjector(at: url))

        let materializedURL = try XCTUnwrap(
            TemplateDrivenModelSupport.resolveChatTemplateFile(modelURL: url).map(URL.init(fileURLWithPath:))
        )
        XCTAssertEqual(try String(contentsOf: materializedURL, encoding: .utf8), template)
    }

    func testMetadataParsersRejectOverflowingLengthsWithoutCrashing() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("overflowing-length.gguf")
        var data = Data("GGUF".utf8)
        appendUInt32(3, to: &data)
        appendUInt64(0, to: &data)
        appendUInt64(1, to: &data)
        appendUInt64(.max, to: &data)
        try data.write(to: url)

        XCTAssertNil(GGUFMetadata.architectureInfo(at: url))
        XCTAssertNil(GGUFMetadata.layerCount(at: url))
        XCTAssertNil(GGUFMetadata.contextLength(at: url))
        XCTAssertNil(GGUFMetadata.chatTemplate(at: url))
        XCTAssertFalse(GGUFMetadata.hasMultimodalProjector(at: url))
        XCTAssertFalse(GGUFMetadata.hasMTP(at: url))
        XCTAssertNil(TemplateDrivenModelSupport.resolveChatTemplateFile(modelURL: url))
    }

    func testMemoryMetadataRecognizesHybridAttentionAndRecurrentState() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("qwen35-hybrid.gguf")
        try writeGGUF(
            to: url,
            metadata: [
                .string("general.architecture", "qwen35"),
                .uint32("qwen35.block_count", 64),
                .uint32("qwen35.embedding_length", 5_120),
                .uint32("qwen35.feed_forward_length", 17_408),
                .uint32("qwen35.vocab_size", 248_320),
                .uint32("qwen35.attention.head_count", 40),
                .uint32("qwen35.attention.head_count_kv", 8),
                .uint32("qwen35.attention.key_length", 128),
                .uint32("qwen35.attention.value_length", 128),
                .uint32("qwen35.full_attention_interval", 4),
                .uint32("qwen35.ssm.conv_kernel", 4),
                .uint32("qwen35.ssm.inner_size", 8_192),
                .uint32("qwen35.ssm.state_size", 128),
                .uint32("qwen35.ssm.group_count", 8)
            ],
            tensors: []
        )

        let info = try XCTUnwrap(GGUFMetadata.moeInfo(at: url))
        XCTAssertEqual(info.architecture, "qwen35")
        XCTAssertEqual(info.totalLayerCount, 64)
        XCTAssertEqual(info.attentionLayerCount, 16)
        XCTAssertEqual(info.recurrentLayerCount, 48)
        XCTAssertEqual(info.hiddenSize, 5_120)
        XCTAssertEqual(info.feedForwardSize, 17_408)
        XCTAssertEqual(info.vocabSize, 248_320)
        XCTAssertEqual(info.ssmInnerSize, 8_192)
        XCTAssertEqual(info.ssmStateSize, 128)
    }

    func testHybridAttentionKeepsAppendedNextNLayerDense() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("qwen35-nextn.gguf")
        try writeGGUF(
            to: url,
            metadata: [
                .string("general.architecture", "qwen35"),
                .uint32("qwen35.block_count", 65),
                .uint32("qwen35.full_attention_interval", 4),
                .uint32("qwen35.nextn_predict_layers", 1)
            ],
            tensors: []
        )

        let info = try XCTUnwrap(GGUFMetadata.moeInfo(at: url))
        XCTAssertEqual(info.totalLayerCount, 65)
        XCTAssertEqual(info.recurrentLayerCount, 48)
        XCTAssertEqual(info.attentionLayerCount, 17)
    }

    private enum GGUFValue {
        case string(String, String)
        case stringArray(String, [String])
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
            case .stringArray(let key, let strings):
                appendString(key, to: &data)
                appendUInt32(9, to: &data)
                appendUInt32(8, to: &data)
                appendUInt64(UInt64(strings.count), to: &data)
                for string in strings {
                    appendStringPayload(string, to: &data)
                }
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
