import XCTest
@testable import Noema

final class ETModelResolverTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETModelResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)?.write(to: url)
    }

    func testResolvesRootPTEAndTokenizerJSON() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("pte", to: root.appendingPathComponent("model.pte"))
        try write("{}", to: root.appendingPathComponent("tokenizer.json"))

        let artifacts = try ETModelResolver.resolveLoadArtifacts(for: root)

        XCTAssertEqual(artifacts.pteURL.lastPathComponent, "model.pte")
        XCTAssertEqual(artifacts.tokenizerURL.lastPathComponent, "tokenizer.json")
    }

    func testResolvesOneLevelNestedTokenizerDeterministically() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("pte", to: root.appendingPathComponent("model.pte"))
        try write("sentencepiece", to: root.appendingPathComponent("tokenizer.model"))
        let nestedTokenizer = root
            .appendingPathComponent("tokenizer", isDirectory: true)
            .appendingPathComponent("tokenizer.json")
        try write("{}", to: nestedTokenizer)

        let artifacts = try ETModelResolver.resolveLoadArtifacts(for: root)

        XCTAssertEqual(artifacts.tokenizerURL.lastPathComponent, "tokenizer.model")
    }

    func testMissingTokenizerProducesRepairableDiagnostic() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("pte", to: root.appendingPathComponent("model.pte"))
        ETModelResolver.writeSourceRepoID("owner/repo-et", into: root)

        XCTAssertThrowsError(try ETModelResolver.resolveLoadArtifacts(for: root)) { error in
            let diagnostic = error as? ETModelResolver.ArtifactDiagnostic
            XCTAssertEqual(diagnostic?.reason, .missingTokenizer)
            XCTAssertEqual(diagnostic?.sourceRepoID, "owner/repo-et")
            XCTAssertEqual(diagnostic?.isRepairable, true)
        }
    }

    func testMissingPTEProducesNonRepairableDiagnostic() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("{}", to: root.appendingPathComponent("tokenizer.json"))
        ETModelResolver.writeSourceRepoID("owner/repo-et", into: root)

        XCTAssertThrowsError(try ETModelResolver.resolveLoadArtifacts(for: root)) { error in
            let diagnostic = error as? ETModelResolver.ArtifactDiagnostic
            XCTAssertEqual(diagnostic?.reason, .missingPTE)
            XCTAssertEqual(diagnostic?.sourceRepoID, "owner/repo-et")
            XCTAssertEqual(diagnostic?.isRepairable, false)
            XCTAssertNil(diagnostic?.recoverySuggestion)
        }
    }

    func testRejectsEmptyPTEProgramAsNonRepairable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(atPath: root.appendingPathComponent("model.pte").path, contents: Data())
        try write("{}", to: root.appendingPathComponent("tokenizer.json"))

        XCTAssertThrowsError(try ETModelResolver.resolveLoadArtifacts(for: root)) { error in
            guard let diagnostic = error as? ETModelResolver.ArtifactDiagnostic else {
                XCTFail("Expected ET artifact diagnostic")
                return
            }
            if case .invalidPTE(let detail) = diagnostic.reason {
                XCTAssertTrue(detail.contains("empty"))
            } else {
                XCTFail("Expected invalid PTE diagnostic")
            }
            XCTAssertFalse(diagnostic.isRepairable)
        }
    }

    func testRejectsGitLFSPointerPTEProgramAsUnsupportedArtifact() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(
            """
            version https://git-lfs.github.com/spec/v1
            oid sha256:abc123
            size 1024
            """,
            to: root.appendingPathComponent("model.pte")
        )
        try write("{}", to: root.appendingPathComponent("tokenizer.json"))

        XCTAssertThrowsError(try ETModelResolver.resolveLoadArtifacts(for: root)) { error in
            guard let diagnostic = error as? ETModelResolver.ArtifactDiagnostic else {
                XCTFail("Expected ET artifact diagnostic")
                return
            }
            if case .invalidPTE(let detail) = diagnostic.reason {
                XCTAssertTrue(detail.contains("Git LFS"))
                XCTAssertTrue(detail.contains("ExecuTorch program"))
            } else {
                XCTFail("Expected invalid PTE diagnostic")
            }
            XCTAssertFalse(diagnostic.isRepairable)
        }
    }

    func testRejectsEmptyTokenizer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("pte", to: root.appendingPathComponent("model.pte"))
        FileManager.default.createFile(atPath: root.appendingPathComponent("tokenizer.json").path, contents: Data())

        XCTAssertThrowsError(try ETModelResolver.resolveLoadArtifacts(for: root)) { error in
            guard let diagnostic = error as? ETModelResolver.ArtifactDiagnostic else {
                XCTFail("Expected ET artifact diagnostic")
                return
            }
            if case .invalidTokenizer(let detail) = diagnostic.reason {
                XCTAssertTrue(detail.contains("empty"))
            } else {
                XCTFail("Expected invalid tokenizer diagnostic")
            }
        }
    }

    func testRejectsInvalidTokenizerJSON() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("pte", to: root.appendingPathComponent("model.pte"))
        try write("not-json", to: root.appendingPathComponent("tokenizer.json"))

        XCTAssertThrowsError(try ETModelResolver.resolveLoadArtifacts(for: root)) { error in
            guard let diagnostic = error as? ETModelResolver.ArtifactDiagnostic else {
                XCTFail("Expected ET artifact diagnostic")
                return
            }
            if case .invalidTokenizer(let detail) = diagnostic.reason {
                XCTAssertTrue(detail.contains("valid JSON"))
            } else {
                XCTFail("Expected invalid tokenizer diagnostic")
            }
        }
    }

    func testRejectsGitLFSPointerTokenizer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("pte", to: root.appendingPathComponent("model.pte"))
        try write(
            """
            version https://git-lfs.github.com/spec/v1
            oid sha256:abc123
            size 123
            """,
            to: root.appendingPathComponent("tokenizer.json")
        )

        XCTAssertThrowsError(try ETModelResolver.resolveLoadArtifacts(for: root)) { error in
            guard let diagnostic = error as? ETModelResolver.ArtifactDiagnostic else {
                XCTFail("Expected ET artifact diagnostic")
                return
            }
            if case .invalidTokenizer(let detail) = diagnostic.reason {
                XCTAssertTrue(detail.contains("Git LFS"))
            } else {
                XCTFail("Expected invalid tokenizer diagnostic")
            }
        }
    }
}
