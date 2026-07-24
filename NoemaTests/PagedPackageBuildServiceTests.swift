#if os(macOS)

import Foundation
import XCTest
@testable import Noema

final class PagedPackageBuildServiceTests: XCTestCase {
    func testGemma4UsesLiveArchitectureWhenPersistedMoEArchitectureIsMissing() {
        let model = makeModel(
            architectureFamily: "gemma4",
            persistedMoEArchitecture: nil
        )

        XCTAssertTrue(PagedPackageBuildService.canCreatePackage(for: model))
    }

    func testUnknownLiveArchitectureDoesNotBypassWhitelist() {
        let model = makeModel(
            architectureFamily: "unsupported-moe",
            persistedMoEArchitecture: nil
        )

        XCTAssertFalse(PagedPackageBuildService.canCreatePackage(for: model))
    }

    private func makeModel(
        architectureFamily: String,
        persistedMoEArchitecture: String?
    ) -> LocalModel {
        LocalModel(
            modelID: "unsloth/gemma-4-26B-A4B-it-qat-GGUF",
            name: "gemma-4-26B-A4B-it-qat-GGUF",
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("gguf"),
            quant: "UD_Q4_K_XL",
            architecture: architectureFamily,
            architectureFamily: architectureFamily,
            format: .gguf,
            sizeGB: 0,
            isMultimodal: false,
            isToolCapable: false,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 1,
            moeInfo: MoEInfo(
                isMoE: true,
                expertCount: 8,
                defaultUsed: 2,
                moeLayerCount: 1,
                totalLayerCount: 1,
                hiddenSize: 32,
                feedForwardSize: 64,
                vocabSize: 256,
                architecture: persistedMoEArchitecture
            )
        )
    }
}

#endif
