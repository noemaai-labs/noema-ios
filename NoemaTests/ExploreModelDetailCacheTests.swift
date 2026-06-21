import Foundation
import XCTest
@testable import Noema

final class ExploreModelDetailCacheTests: XCTestCase {
    func testSavesAndLoadsModelDetailsSnapshot() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let details = makeDetails(id: "owner/Test-Model", label: "Q4_K_M")
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        ExploreModelDetailCache.save(details, root: root, date: date)

        let snapshot = try XCTUnwrap(ExploreModelDetailCache.snapshot(repoID: details.id, root: root))
        XCTAssertEqual(snapshot.details, details)
        XCTAssertEqual(snapshot.cachedAt, date)
        XCTAssertEqual(ExploreModelDetailCache.cachedAt(repoID: details.id, root: root), date)
    }

    func testRecordsAreReturnedNewestFirst() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        ExploreModelDetailCache.save(
            makeDetails(id: "owner/Older-Model", label: "Q4_K_M"),
            root: root,
            date: Date(timeIntervalSince1970: 100)
        )
        ExploreModelDetailCache.save(
            makeDetails(id: "owner/Newer-Model", label: "Q5_K_M"),
            root: root,
            date: Date(timeIntervalSince1970: 200)
        )

        let records = ExploreModelDetailCache.records(root: root)

        XCTAssertEqual(records.map(\.id), ["owner/Newer-Model", "owner/Older-Model"])
        XCTAssertEqual(records.first?.formats, [.gguf])
        XCTAssertEqual(records.first?.publisher, "owner")
        XCTAssertEqual(records.first?.hasInstallableQuant, true)
    }

    func testRepoIDPathComponentsIgnoreTraversalSegments() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = ExploreModelDetailCache.directory(for: "../owner/../Model", root: root, create: false)

        XCTAssertTrue(url.path.hasPrefix(root.appendingPathComponent("ModelCards").path))
        XCTAssertFalse(url.path.contains("/../"))
    }

    private func makeDetails(id: String, label: String) -> ModelDetails {
        ModelDetails(
            id: id,
            summary: "Cached model",
            quants: [
                QuantInfo(
                    label: label,
                    format: .gguf,
                    sizeBytes: 123_456,
                    downloadURL: URL(string: "https://huggingface.co/\(id)/resolve/main/model.gguf?download=1")!,
                    sha256: "abc",
                    configURL: URL(string: "https://huggingface.co/\(id)/raw/main/config.json")
                )
            ],
            promptTemplate: nil
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-explore-cache-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
