import XCTest
@testable import Noema

final class ModelUpdateCheckerTests: XCTestCase {
    func testReportsCurrentWhenChecksumSizeAndFileMatch() {
        let installed = makeSnapshot(
            quantLabel: "Q4_K_M",
            filename: "model-q4_k_m.gguf",
            sizeBytes: 1_024,
            checksum: "sha256:abc123"
        )
        let details = makeDetails(
            quant: makeQuant(
                label: "Q4_K_M",
                filename: "model-q4_k_m.gguf",
                sizeBytes: 1_024,
                sha256: "abc123"
            )
        )

        let result = ModelUpdateChecker.compare(installed: installed, against: details)

        XCTAssertEqual(result.state, .current)
        XCTAssertEqual(result.differences, [])
    }

    func testReportsChangedChecksumAndSize() {
        let installed = makeSnapshot(
            quantLabel: "Q4_K_M",
            filename: "model-q4_k_m.gguf",
            sizeBytes: 1_024,
            checksum: "sha256:old"
        )
        let details = makeDetails(
            quant: makeQuant(
                label: "Q4_K_M",
                filename: "model-q4_k_m.gguf",
                sizeBytes: 2_048,
                sha256: "new"
            )
        )

        let result = ModelUpdateChecker.compare(installed: installed, against: details)

        XCTAssertEqual(result.state, .updateAvailable)
        XCTAssertEqual(Set(result.differences), [.checksum, .size])
    }

    func testFallsBackToFilenameWhenQuantLabelChanges() {
        let installed = makeSnapshot(
            quantLabel: "Old Label",
            filename: "model-q5_k_m.gguf",
            sizeBytes: 1_024,
            checksum: nil
        )
        let details = makeDetails(
            quant: makeQuant(
                label: "Q5_K_M",
                filename: "model-q5_k_m.gguf",
                sizeBytes: 1_024,
                sha256: nil
            )
        )

        let result = ModelUpdateChecker.compare(installed: installed, against: details)

        XCTAssertEqual(result.state, .current)
        XCTAssertEqual(result.remoteQuant?.label, "Q5_K_M")
    }

    func testReportsMissingWhenInstalledQuantIsNoLongerListed() {
        let installed = makeSnapshot(
            quantLabel: "Q2_K",
            filename: "model-q2_k.gguf",
            sizeBytes: 512,
            checksum: nil
        )
        let details = makeDetails(
            quant: makeQuant(
                label: "Q4_K_M",
                filename: "model-q4_k_m.gguf",
                sizeBytes: 1_024,
                sha256: nil
            )
        )

        let result = ModelUpdateChecker.compare(installed: installed, against: details)

        XCTAssertEqual(result.state, .missingRemoteQuant)
    }

    private func makeSnapshot(
        quantLabel: String,
        filename: String,
        sizeBytes: Int64,
        checksum: String?
    ) -> ModelProvenanceSnapshot {
        let installed = InstalledModel(
            modelID: "owner/model",
            quantLabel: quantLabel,
            url: URL(fileURLWithPath: "/tmp/\(filename)"),
            format: .gguf,
            sizeBytes: sizeBytes,
            lastUsed: nil,
            installDate: Date(timeIntervalSince1970: 1_700_000_000),
            checksum: checksum,
            isFavourite: false,
            totalLayers: 0
        )
        return ModelProvenanceSnapshot(installed: installed)
    }

    private func makeDetails(quant: QuantInfo) -> ModelDetails {
        ModelDetails(
            id: "owner/model",
            summary: nil,
            quants: [quant],
            promptTemplate: nil
        )
    }

    private func makeQuant(label: String, filename: String, sizeBytes: Int64, sha256: String?) -> QuantInfo {
        QuantInfo(
            label: label,
            format: .gguf,
            sizeBytes: sizeBytes,
            downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/\(filename)")!,
            sha256: sha256,
            configURL: nil
        )
    }
}
