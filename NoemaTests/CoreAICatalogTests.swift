import Foundation
import XCTest
@testable import Noema

final class CoreAICatalogTests: XCTestCase {

    // MARK: - Format mapping

    func testDetectCoreAIExtensions() {
        XCTAssertEqual(ModelFormat.detect(from: URL(fileURLWithPath: "/tmp/Model.aimodel")), .coreai)
        XCTAssertEqual(ModelFormat.detect(from: URL(fileURLWithPath: "/tmp/Model.aimodelc")), .coreai)
        XCTAssertEqual(ModelFormat.detect(from: URL(string: "coreai://catalog/qwen3-0.6b")!), .coreai)
        XCTAssertEqual(ModelFormat.coreai.displayName, "Core AI")
    }

    // MARK: - Catalog entry helpers

    func testCatalogEntryDerivedFields() {
        let entry = CoreAICatalogEntry(
            shortName: "qwen3-0.6b",
            hfId: "Qwen/Qwen3-0.6B",
            family: "qwen3",
            type: "llm",
            task: "text-generation",
            platforms: ["macOS", "iOS"],
            variants: [
                .init(platform: "macOS", compression: "4bit", computePrecision: "float16", maxContextLength: 8192),
                .init(platform: "iOS", compression: "mixed_4bit_8bit", computePrecision: "float16", maxContextLength: 4096)
            ],
            notes: nil
        )
        XCTAssertEqual(entry.modelID, "coreai/qwen3-0.6b")
        XCTAssertTrue(entry.isChatModel)
        XCTAssertEqual(entry.publisher, "Qwen")
        XCTAssertEqual(entry.parameterCountLabel, "0.6B")
        // iOS variant context is preferred for the on-device target.
        XCTAssertEqual(entry.maxContextLength, 4096)
    }

    // MARK: - Registry behavior (injected catalog, no bundle dependency)

    private func makeRegistry() -> CoreAIModelRegistry {
        let catalog = CoreAIModelCatalog(
            version: 1,
            source: "test",
            note: nil,
            models: [
                CoreAICatalogEntry(
                    shortName: "qwen3-0.6b",
                    hfId: "Qwen/Qwen3-0.6B",
                    family: "qwen3",
                    type: "llm",
                    task: "text-generation",
                    platforms: ["iOS"],
                    variants: [.init(platform: "iOS", compression: "mixed_4bit_8bit", computePrecision: "float16", maxContextLength: 4096)],
                    notes: nil
                ),
                CoreAICatalogEntry(
                    shortName: "whisper-large-v3",
                    hfId: "openai/whisper-large-v3",
                    family: "whisper",
                    type: "utility",
                    task: "asr",
                    platforms: ["iOS", "macOS"],
                    variants: [],
                    notes: "Export: models/whisper/export.py"
                )
            ]
        )
        return CoreAIModelRegistry(catalog: catalog)
    }

    func testRegistryCuratedMapsToCoreAIRecords() async throws {
        let records = try await makeRegistry().curated()
        XCTAssertEqual(records.count, 2)
        for record in records {
            XCTAssertEqual(record.formats, [.coreai])
            XCTAssertTrue(record.id.hasPrefix("coreai/"))
        }
        XCTAssertEqual(records.first?.parameterCountLabel, "0.6B")
    }

    func testRegistryDetailsCarrySideLoadNotice() async throws {
        let details = try await makeRegistry().details(for: "coreai/qwen3-0.6b")
        XCTAssertFalse(details.quants.isEmpty)
        XCTAssertTrue(details.quants.allSatisfy { $0.format == .coreai })
        let summary = details.summary ?? ""
        XCTAssertTrue(summary.contains("side-load") || summary.contains("Side-load") || summary.contains("downloadable"))
    }

    func testRegistrySearchHonorsFormatFilter() async throws {
        let registry = makeRegistry()

        // A non-CoreAI format filter yields nothing.
        var ggufHits: [ModelRecord] = []
        for try await rec in registry.searchStream(query: "qwen", page: 0, format: .gguf, includeVisionModels: true, visionOnly: false) {
            ggufHits.append(rec)
        }
        XCTAssertTrue(ggufHits.isEmpty)

        // CoreAI filter + query matches by short name / family.
        var hits: [ModelRecord] = []
        for try await rec in registry.searchStream(query: "qwen", page: 0, format: .coreai, includeVisionModels: false, visionOnly: false) {
            hits.append(rec)
        }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, "coreai/qwen3-0.6b")
    }

    // MARK: - Hugging Face Core AI repos (.aimodel quants)

    func testInferFormatsDetectsCoreAITags() {
        let formats = HuggingFaceRegistry.inferFormats(
            tags: ["coreai", "aimodel", "apple-silicon", "ane", "on-device"],
            id: "mlboydaisuke/qwen3.5-0.8B-CoreAI"
        )
        XCTAssertTrue(formats.contains(.coreai))

        let unrelated = HuggingFaceRegistry.inferFormats(tags: ["gguf"], id: "unsloth/Qwen3-GGUF")
        XCTAssertFalse(unrelated.contains(.coreai))
    }

    func testQuantExtractorBuildsCoreAIQuantsFromAimodelBundles() {
        let files: [RepoFile] = [
            RepoFile(path: "README.md", size: 10, sha256: nil),
            RepoFile(path: "gpu-pipelined/qwen3_5_0_8b_decode_int8lin/metadata.json", size: 578, sha256: nil),
            RepoFile(path: "gpu-pipelined/qwen3_5_0_8b_decode_int8lin/qwen3_5_0_8b_decode_int8lin.aimodel/main.mlirb", size: 1_038_846_584, sha256: "abc"),
            RepoFile(path: "gpu-pipelined/qwen3_5_0_8b_decode_int8lin/qwen3_5_0_8b_decode_int8lin.aimodel/main.hash", size: 32, sha256: nil),
            RepoFile(path: "gpu-pipelined/qwen3_5_0_8b_decode_int8lin/qwen3_5_0_8b_decode_int8lin.aimodel/metadata.json", size: 28, sha256: nil),
            RepoFile(path: "gpu-pipelined/qwen3_5_0_8b_decode_int8lin/tokenizer/tokenizer.json", size: 19_989_343, sha256: nil),
            RepoFile(path: "gpu-pipelined/qwen3_5_0_8b_decode_int8lin/tokenizer/merges.txt", size: 3_353_273, sha256: nil),
            RepoFile(path: "ios-ane/qwen3_5_0_8b_decode_int8.aimodel/main.mlirb", size: 1_016_041_748, sha256: nil),
            RepoFile(path: "ios-ane/qwen3_5_0_8b_decode_int8.aimodel/main.hash", size: 32, sha256: nil),
            RepoFile(path: "ios-ane/qwen3_5_0_8b_decode_int8.aimodel/metadata.json", size: 28, sha256: nil),
            RepoFile(path: "ios-gpu/qwen3_5_0_8b_ios_hc0_int8v3.aimodel/main.mlirb", size: 1_344_212_992, sha256: nil),
            RepoFile(path: "ios-gpu/qwen3_5_0_8b_ios_hc0_int8v3.aimodel/main.hash", size: 32, sha256: nil),
            RepoFile(path: "ios-gpu/qwen3_5_0_8b_ios_hc_prefill_q16_b2048_int8.aimodel/main.mlirb", size: 1_016_608_450, sha256: nil),
            RepoFile(path: "ios-gpu/qwen3_5_0_8b_ios_hc_prefill_q16_b2048_int8.aimodel/main.hash", size: 32, sha256: nil)
        ]

        let quants = QuantExtractor.extract(from: files, repoID: "mlboydaisuke/qwen3.5-0.8B-CoreAI")
        let coreai = quants.filter { $0.format == .coreai }

        // One quant per .aimodel bundle; the chunked-prefill companion is not a
        // standalone quant — it rides along with the decode bundles that share
        // its directory.
        XCTAssertEqual(coreai.count, 3)
        let labels = Set(coreai.map(\.label))
        XCTAssertEqual(labels, ["gpu-pipelined/decode_int8lin", "ios-ane/decode_int8", "ios-gpu/ios_hc0_int8v3"])

        let hostCache = coreai.first { $0.label == "ios-gpu/ios_hc0_int8v3" }
        let hcParts = hostCache?.downloadParts ?? []
        // Decode bundle (2 files, largest first) + the prefill companion (2 files).
        XCTAssertEqual(hcParts.count, 4)
        XCTAssertEqual(hcParts.first?.path, "ios-gpu/qwen3_5_0_8b_ios_hc0_int8v3.aimodel/main.mlirb")
        XCTAssertTrue(hcParts.contains { $0.path == "ios-gpu/qwen3_5_0_8b_ios_hc_prefill_q16_b2048_int8.aimodel/main.mlirb" })

        let pipelined = coreai.first { $0.label == "gpu-pipelined/decode_int8lin" }
        let parts = pipelined?.downloadParts ?? []
        // Bundle contents plus the variant-level metadata + tokenizer companions.
        XCTAssertEqual(parts.count, 6)
        XCTAssertEqual(parts.first?.path, "gpu-pipelined/qwen3_5_0_8b_decode_int8lin/qwen3_5_0_8b_decode_int8lin.aimodel/main.mlirb")
        XCTAssertTrue(parts.contains { $0.path == "gpu-pipelined/qwen3_5_0_8b_decode_int8lin/tokenizer/tokenizer.json" })
        XCTAssertTrue(parts.contains { $0.path == "gpu-pipelined/qwen3_5_0_8b_decode_int8lin/metadata.json" })

        let ane = coreai.first { $0.label == "ios-ane/decode_int8" }
        // No companions next to this bundle; the tokenizer is backfilled at install time.
        XCTAssertEqual(ane?.downloadParts?.count, 3)
        XCTAssertEqual(ane?.downloadParts?.first?.path, "ios-ane/qwen3_5_0_8b_decode_int8.aimodel/main.mlirb")
    }

    func testResolverPrefersDeviceFitCoreAIDecodeBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreai-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let hostCacheDecode = root
            .appendingPathComponent("ios-gpu", isDirectory: true)
            .appendingPathComponent("qwen_ios_hc0_int8v3.aimodel", isDirectory: true)
        let gpuPrefill = root
            .appendingPathComponent("ios-gpu", isDirectory: true)
            .appendingPathComponent("qwen_hc_prefill_q16_b2048_int8.aimodel", isDirectory: true)
        let gpuDecode = root
            .appendingPathComponent("gpu-pipelined", isDirectory: true)
            .appendingPathComponent("qwen_decode_int8lin.aimodel", isDirectory: true)
        let aneDecode = root
            .appendingPathComponent("ios-ane", isDirectory: true)
            .appendingPathComponent("qwen_decode_int8.aimodel", isDirectory: true)
        for url in [hostCacheDecode, gpuPrefill, gpuDecode, aneDecode] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let resolved = try CoreAIModelResolver.resolve(modelURL: root)
        #if os(macOS)
        // Mac: pipelined decode speed dominates; the companion sits in another
        // directory, so no prefill handoff.
        XCTAssertTrue(resolved.modelURL.path.contains("gpu-pipelined"))
        XCTAssertNil(resolved.prefillModelURL)
        #else
        // iPhone: host-cache bundle wins for chat (chunked prefill + cross-turn
        // cache) and brings its same-directory companion.
        XCTAssertTrue(resolved.modelURL.path.contains("ios-gpu"))
        XCTAssertEqual(resolved.prefillModelURL?.lastPathComponent, gpuPrefill.lastPathComponent)
        #endif
        XCTAssertFalse(resolved.modelURL.lastPathComponent.lowercased().contains("prefill"))
    }

    func testResolverAvoidsPrefillCompanionWithinSameFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreai-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let variant = root.appendingPathComponent("ios-ane", isDirectory: true)
        let prefill = variant.appendingPathComponent("qwen_prefill_q16_b2048_int8.aimodel", isDirectory: true)
        let decode = variant.appendingPathComponent("qwen_decode_int8.aimodel", isDirectory: true)
        for url in [prefill, decode] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let resolved = try CoreAIModelResolver.resolve(modelURL: variant)
        XCTAssertEqual(resolved.modelURL.lastPathComponent, decode.lastPathComponent)
        // The same-directory companion is surfaced as the fast prefill path.
        XCTAssertEqual(resolved.prefillModelURL?.lastPathComponent, prefill.lastPathComponent)
    }

    // MARK: - Tokenizer round-trip

    func testByteLevelBPERoundTrip() throws {
        let json = """
        {
          "model": {
            "type": "BPE",
            "vocab": { "h": 0, "i": 1, "hi": 2, "!": 3 },
            "merges": ["h i"]
          },
          "added_tokens": []
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreai-tok-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tokenizer = try CoreAITokenizer(contentsOf: url)
        let ids = tokenizer.encode("hi")
        XCTAssertEqual(ids, [2])                 // "h"+"i" merge to "hi"
        XCTAssertEqual(tokenizer.decode([2]), "hi")
        XCTAssertEqual(tokenizer.decode([0, 1]), "hi")
    }

    func testTokenizerDetectsEOS() throws {
        let json = """
        {
          "model": { "type": "BPE", "vocab": { "a": 0 }, "merges": [] },
          "added_tokens": [ { "id": 100, "content": "<|im_end|>" } ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreai-tok-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tokenizer = try CoreAITokenizer(contentsOf: url)
        XCTAssertTrue(tokenizer.eosTokenIDs.contains(100))
    }

    // MARK: - PCC settings persistence

    func testPrivateCloudReasoningLevelPersistsThroughCodable() throws {
        var settings = ModelSettings.default(for: .afm)
        settings.pccReasoningLevel = .deep

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ModelSettings.self, from: data)
        XCTAssertEqual(decoded.pccReasoningLevel, .deep)
    }

    func testLegacyHiddenPCCSettingsAreIgnored() throws {
        let legacyJSON = """
        {"afmUsePrivateCloudCompute":true,"afmPrivateCloudComputeMode":"always"}
        """
        let decoded = try JSONDecoder().decode(ModelSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.pccReasoningLevel, .moderate)
    }
}
