import XCTest
@testable import Noema

final class ModelProvenanceSnapshotTests: XCTestCase {
    func testSnapshotPrefersInstalledModelMetadata() {
        let installed = InstalledModel(
            modelID: "example/FastTutor-7B",
            quantLabel: "Q4_K_M",
            parameterCountLabel: "7B",
            url: FileManager.default.temporaryDirectory.appendingPathComponent("FastTutor.gguf"),
            format: .gguf,
            sizeBytes: 4_200,
            lastUsed: Date(timeIntervalSince1970: 1_700_000_500),
            installDate: Date(timeIntervalSince1970: 1_700_000_000),
            checksum: "sha256:test",
            isFavourite: true,
            totalLayers: 32,
            isMultimodal: true,
            isToolCapable: true,
            moeInfo: MoEInfo(
                isMoE: true,
                expertCount: 8,
                defaultUsed: 2,
                moeLayerCount: 16,
                totalLayerCount: 32,
                hiddenSize: nil,
                feedForwardSize: nil,
                vocabSize: nil
            ),
            alias: "Tutor"
        )

        let snapshot = ModelProvenanceSnapshot(installed: installed)

        XCTAssertEqual(snapshot.modelID, "example/FastTutor-7B")
        XCTAssertEqual(snapshot.displayName, "Tutor")
        XCTAssertEqual(snapshot.alias, "Tutor")
        XCTAssertEqual(snapshot.formatRawValue, "GGUF")
        XCTAssertEqual(snapshot.quantLabel, "Q4_K_M")
        XCTAssertEqual(snapshot.parameterCountLabel, "7B")
        XCTAssertEqual(snapshot.sizeBytes, 4_200)
        XCTAssertEqual(snapshot.checksum, "sha256:test")
        XCTAssertTrue(snapshot.isFavourite)
        XCTAssertTrue(snapshot.isMultimodal)
        XCTAssertTrue(snapshot.isToolCapable)
        XCTAssertEqual(snapshot.totalLayers, 32)
        XCTAssertEqual(snapshot.isMoE, true)
        XCTAssertEqual(snapshot.expertCount, 8)
        XCTAssertEqual(snapshot.defaultExperts, 2)
        XCTAssertEqual(snapshot.moeLayerCount, 16)
        XCTAssertTrue(snapshot.localPath.hasSuffix("FastTutor.gguf"))
        XCTAssertTrue(snapshot.installRootPath.contains("FastTutor-7B"))
    }

    func testSnapshotFallsBackToLocalModelWhenStoreRecordIsMissing() {
        let local = LocalModel(
            modelID: "example/Fallback-3B",
            name: "Fallback-3B",
            url: FileManager.default.temporaryDirectory.appendingPathComponent("Fallback.gguf"),
            quant: "Q5_K_M",
            parameterCountLabel: "3B",
            architecture: "llama",
            architectureFamily: "llama",
            format: .gguf,
            sizeGB: 2.5,
            isMultimodal: false,
            isToolCapable: true,
            isDownloaded: true,
            downloadDate: Date(timeIntervalSince1970: 1_700_010_000),
            lastUsedDate: nil,
            isFavourite: false,
            totalLayers: 24,
            alias: nil
        )

        let snapshot = ModelProvenanceSnapshot(model: local, installed: nil)

        XCTAssertEqual(snapshot.modelID, "example/Fallback-3B")
        XCTAssertEqual(snapshot.displayName, "Fallback-3B")
        XCTAssertNil(snapshot.alias)
        XCTAssertEqual(snapshot.formatRawValue, "GGUF")
        XCTAssertEqual(snapshot.quantLabel, "Q5_K_M")
        XCTAssertEqual(snapshot.parameterCountLabel, "3B")
        XCTAssertEqual(snapshot.sizeBytes, 2_684_354_560)
        XCTAssertNil(snapshot.checksum)
        XCTAssertNil(snapshot.lastUsedDate)
        XCTAssertFalse(snapshot.isMultimodal)
        XCTAssertTrue(snapshot.isToolCapable)
        XCTAssertEqual(snapshot.totalLayers, 24)
    }
}
