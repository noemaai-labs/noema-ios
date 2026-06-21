import XCTest
@testable import Noema

final class ModelDownloadManagerTests: XCTestCase {
    func testCanonicalProgressSnapshotUsesActualTransferBytes() {
        let snapshot = ModelDownloadManager.canonicalProgressSnapshot(
            written: 4_096,
            reportedExpected: 10_000,
            fallbackExpected: 80_000
        )

        XCTAssertEqual(snapshot.downloadedBytes, 4_096)
        XCTAssertEqual(snapshot.expectedBytes, 80_000)
        XCTAssertEqual(snapshot.progress, 0.0512, accuracy: 0.0001)
    }

    func testCanonicalProgressSnapshotUsesReportedExpectedWhenItIsBestTotal() {
        let snapshot = ModelDownloadManager.canonicalProgressSnapshot(
            written: 4_096,
            reportedExpected: 10_000,
            fallbackExpected: 0
        )

        XCTAssertEqual(snapshot.downloadedBytes, 4_096)
        XCTAssertEqual(snapshot.expectedBytes, 10_000)
        XCTAssertEqual(snapshot.progress, 0.4096, accuracy: 0.0001)
    }

    func testModelSidecarArtifactIDIsStable() {
        XCTAssertEqual(
            ModelDownloadManager.modelSidecarArtifactID(relativePath: "tokenizer.json"),
            "sidecar:tokenizer.json"
        )
    }

    private actor RequestRecorder {
        private var urls: [String] = []

        func append(_ url: URL) {
            urls.append(url.absoluteString)
        }

        func all() -> [String] {
            urls
        }
    }

    actor Counter {
        private var active = 0
        private var maxObserved = 0

        func begin() {
            active += 1
            maxObserved = max(maxObserved, active)
        }

        func end() {
            active -= 1
        }

        func maximum() -> Int {
            maxObserved
        }
    }

    func testBoundedConcurrencyCapsParallelMultipartWorkAtFour() async throws {
        let counter = Counter()

        let results = try await ModelDownloadManager.runBoundedConcurrency(
            limit: ModelDownloadManager.multipartDownloadConcurrencyLimit,
            count: 8
        ) { index in
            await counter.begin()
            do {
                try await Task.sleep(for: .milliseconds(40))
                await counter.end()
                return index
            } catch {
                await counter.end()
                throw error
            }
        }

        XCTAssertEqual(results, Array(0..<8))
        let maximum = await counter.maximum()
        XCTAssertEqual(maximum, ModelDownloadManager.multipartDownloadConcurrencyLimit)
    }

    func testRequiredETTokenizerArtifactsThrowWhenTokenizerCannotBeFetched() async throws {
        let dir = try makeTemporaryDirectory()
        try Data("pte".utf8).write(to: dir.appendingPathComponent("model.pte"))

        let previousFetcher = ModelDownloadManager.repositoryFileFetcherOverride
        ModelDownloadManager.repositoryFileFetcherOverride = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(), response)
        }
        defer {
            ModelDownloadManager.repositoryFileFetcherOverride = previousFetcher
        }

        do {
            _ = try await ModelDownloadManager().fetchETTokenizerArtifactsForTesting(
                repoID: "larryliu0820/Qwen3-1.7B-INT8-INT4-ExecuTorch-XNNPACK",
                into: dir,
                required: true
            )
            XCTFail("Expected required ET tokenizer fetch to fail before install finalization")
        } catch let diagnostic as ETModelResolver.ArtifactDiagnostic {
            XCTAssertEqual(diagnostic.reason, .missingTokenizer)
            XCTAssertEqual(diagnostic.sourceRepoID, "larryliu0820/Qwen3-1.7B-INT8-INT4-ExecuTorch-XNNPACK")
        }
    }

    func testRepairETArtifactsUsesPersistedSourceRepoBeforeDisplayModelID() async throws {
        let dir = try makeTemporaryDirectory()
        try Data("pte".utf8).write(to: dir.appendingPathComponent("model.pte"))
        ETModelResolver.writeSourceRepoID(
            "larryliu0820/Qwen3-1.7B-INT8-INT4-ExecuTorch-XNNPACK",
            into: dir
        )

        let recorder = RequestRecorder()
        let previousFetcher = ModelDownloadManager.repositoryFileFetcherOverride
        ModelDownloadManager.repositoryFileFetcherOverride = { request in
            let url = try XCTUnwrap(request.url)
            await recorder.append(url)
            let data: Data
            switch url.lastPathComponent {
            case "tokenizer.json":
                data = Data(#"{"model":"mock"}"#.utf8)
            case "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json":
                data = Data("{}".utf8)
            case "vocab.json":
                data = Data(#"{"hello":0}"#.utf8)
            case "vocab.txt":
                data = Data("hello\n".utf8)
            case "merges.txt":
                data = Data("#version: 0.2\n".utf8)
            default:
                data = Data()
            }
            let statusCode = data.isEmpty ? 404 : 200
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ))
            return (data, response)
        }
        defer {
            ModelDownloadManager.repositoryFileFetcherOverride = previousFetcher
        }

        try await ModelDownloadManager().repairETArtifacts(
            modelID: "unsloth/Qwen3-1.7B-GGUF",
            modelURL: dir
        )

        let artifacts = try ETModelResolver.resolveLoadArtifacts(for: dir)
        XCTAssertEqual(artifacts.tokenizerURL.lastPathComponent, "tokenizer.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("vocab.json").path))

        let urls = await recorder.all()
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy { $0.contains("larryliu0820/Qwen3-1.7B-INT8-INT4-ExecuTorch-XNNPACK") })
        XCTAssertFalse(urls.contains { $0.contains("unsloth/Qwen3-1.7B-GGUF") })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
