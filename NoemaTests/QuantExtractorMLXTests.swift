import XCTest
@testable import Noema

final class QuantExtractorMLXTests: XCTestCase {
    func testMLXShardedRepoEnumeratesEverySafetensorsShard() throws {
        // Mirrors lmstudio-community/Qwen3.6-27B-MLX-5bit: four safetensors shards
        // whose sizes only sum correctly when all are treated as one quant.
        let files = [
            RepoFile(path: "model-00001-of-00004.safetensors", size: 5_340_000_000, sha256: "sha1"),
            RepoFile(path: "model-00002-of-00004.safetensors", size: 5_360_000_000, sha256: "sha2"),
            RepoFile(path: "model-00003-of-00004.safetensors", size: 5_370_000_000, sha256: "sha3"),
            RepoFile(path: "model-00004-of-00004.safetensors", size: 3_350_000_000, sha256: "sha4"),
            RepoFile(path: "model.safetensors.index.json", size: 42_000, sha256: nil),
            RepoFile(path: "config.json", size: 1_234, sha256: nil),
            RepoFile(path: "tokenizer.json", size: 5_000_000, sha256: nil)
        ]

        let quant = try XCTUnwrap(
            QuantExtractor.extract(from: files, repoID: "lmstudio-community/Qwen3.6-27B-MLX-5bit")
                .first(where: { $0.format == .mlx })
        )

        XCTAssertEqual(quant.label, "INT5")
        XCTAssertTrue(quant.isMultipart)
        // Every shard is present, in order, and nothing but the safetensors are treated as weights.
        XCTAssertEqual(
            quant.allRelativeDownloadPaths,
            [
                "model-00001-of-00004.safetensors",
                "model-00002-of-00004.safetensors",
                "model-00003-of-00004.safetensors",
                "model-00004-of-00004.safetensors"
            ]
        )
        // Size is the whole model, not just the first shard.
        XCTAssertEqual(quant.sizeBytes, 19_420_000_000)
        XCTAssertEqual(quant.primaryDownloadRelativePath, "model-00001-of-00004.safetensors")
        XCTAssertEqual(
            quant.allDownloadParts.map(\.downloadURL.absoluteString),
            quant.allRelativeDownloadPaths.map {
                "https://huggingface.co/lmstudio-community/Qwen3.6-27B-MLX-5bit/resolve/main/\($0)?download=1"
            }
        )
    }

    func testMLXSingleSafetensorsStaysSingleFile() throws {
        let files = [
            RepoFile(path: "model.safetensors", size: 2_000_000_000, sha256: "sha"),
            RepoFile(path: "config.json", size: 900, sha256: nil)
        ]

        let quant = try XCTUnwrap(
            QuantExtractor.extract(from: files, repoID: "mlx-community/tiny-4bit")
                .first(where: { $0.format == .mlx })
        )

        XCTAssertFalse(quant.isMultipart)
        XCTAssertNil(quant.downloadParts)
        XCTAssertEqual(quant.sizeBytes, 2_000_000_000)
        XCTAssertEqual(quant.allRelativeDownloadPaths, ["model.safetensors"])
    }

    func testMLXNPZFallbackWhenNoSafetensors() throws {
        let files = [
            RepoFile(path: "weights.npz", size: 1_500_000_000, sha256: nil),
            RepoFile(path: "config.json", size: 700, sha256: nil)
        ]

        let quant = try XCTUnwrap(
            QuantExtractor.extract(from: files, repoID: "mlx-community/npz-model")
                .first(where: { $0.format == .mlx })
        )

        XCTAssertFalse(quant.isMultipart)
        XCTAssertEqual(quant.sizeBytes, 1_500_000_000)
        XCTAssertEqual(quant.allRelativeDownloadPaths, ["weights.npz"])
    }
}
