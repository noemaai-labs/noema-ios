import XCTest
@testable import Noema

final class QuantExtractorETTests: XCTestCase {
    func testETQuantIncludesTokenizerSidecarsInDownloadParts() throws {
        let files = [
            RepoFile(path: "model.pte", size: 1_280_617_088, sha256: "pte-sha"),
            RepoFile(path: "tokenizer.json", size: 11_422_654, sha256: "tokenizer-sha"),
            RepoFile(path: "tokenizer_config.json", size: 9_732, sha256: nil),
            RepoFile(path: "vocab.json", size: 2_776_833, sha256: nil),
            RepoFile(path: "merges.txt", size: 1_671_853, sha256: nil),
            RepoFile(path: "generation_config.json", size: 239, sha256: nil),
            RepoFile(path: "README.md", size: 100, sha256: nil)
        ]

        let quant = try XCTUnwrap(
            QuantExtractor.extract(
                from: files,
                repoID: "larryliu0820/Qwen3-1.7B-INT8-INT4-ExecuTorch-XNNPACK"
            ).first(where: { $0.format == .et })
        )

        XCTAssertEqual(quant.label, "ET-XNNPACK")
        XCTAssertEqual(quant.downloadURL.absoluteString, "https://huggingface.co/larryliu0820/Qwen3-1.7B-INT8-INT4-ExecuTorch-XNNPACK/resolve/main/model.pte?download=1")
        XCTAssertEqual(
            quant.allRelativeDownloadPaths,
            [
                "model.pte",
                "tokenizer.json",
                "tokenizer_config.json",
                "vocab.json",
                "merges.txt",
                "generation_config.json"
            ]
        )
        XCTAssertEqual(
            quant.allDownloadParts.map(\.downloadURL.absoluteString),
            quant.allRelativeDownloadPaths.map {
                "https://huggingface.co/larryliu0820/Qwen3-1.7B-INT8-INT4-ExecuTorch-XNNPACK/resolve/main/\($0)?download=1"
            }
        )
    }

    func testETQuantKeepsBarePTEWhenNoSidecarsAdvertised() throws {
        let files = [
            RepoFile(path: "model.pte", size: 1024, sha256: nil)
        ]

        let quant = try XCTUnwrap(
            QuantExtractor.extract(from: files, repoID: "owner/repo").first(where: { $0.format == .et })
        )

        XCTAssertFalse(quant.isMultipart)
        XCTAssertEqual(quant.allRelativeDownloadPaths, ["model.pte"])
    }
}
