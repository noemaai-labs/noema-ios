import XCTest
@testable import Noema

final class VisionProjectorDownloadPreferenceTests: XCTestCase {
    private let artifacts = [
        VisionProjectorArtifact(repositoryID: "owner/model", filename: "mmproj-F32.gguf", size: 1_000, repositoryPriority: 0),
        VisionProjectorArtifact(repositoryID: "owner/model", filename: "mmproj-BF16.gguf", size: 800, repositoryPriority: 0),
        VisionProjectorArtifact(repositoryID: "owner/model", filename: "mmproj-F16.gguf", size: 750, repositoryPriority: 0),
        VisionProjectorArtifact(repositoryID: "owner/model", filename: "mmproj-Q8_0.gguf", size: 500, repositoryPriority: 0),
        VisionProjectorArtifact(repositoryID: "owner/model", filename: "mmproj-Q4_K_M.gguf", size: 300, repositoryPriority: 0)
    ]

    func testDefaultPreferenceIsF16() {
        XCTAssertEqual(VisionProjectorDownloadPreference.defaultPreference, .f16)
    }

    func testHighestAndLowestQualityResolveOppositeEnds() {
        let highest = VisionProjectorDownloadPlan.resolve(
            artifacts: artifacts,
            preference: .highestQuality
        )
        let lowest = VisionProjectorDownloadPlan.resolve(
            artifacts: artifacts,
            preference: .lowestQuality
        )

        XCTAssertEqual(highest.selected?.qualityLabel, "F32")
        XCTAssertEqual(lowest.selected?.qualityLabel, "Q4")
        XCTAssertFalse(highest.requiresUserChoice)
        XCTAssertFalse(lowest.requiresUserChoice)
    }

    func testF16DoesNotSilentlyTreatBF16AsExactMatch() {
        let plan = VisionProjectorDownloadPlan.resolve(
            artifacts: artifacts,
            preference: .f16
        )

        XCTAssertEqual(plan.selected?.filename, "mmproj-F16.gguf")
        XCTAssertFalse(plan.requiresUserChoice)
    }

    func testMissingExactPrecisionRequiresFallbackChoice() {
        let withoutQ8 = artifacts.filter { !$0.filename.contains("Q8_0") }
        let plan = VisionProjectorDownloadPlan.resolve(
            artifacts: withoutQ8,
            preference: .q8_0
        )

        XCTAssertNil(plan.selected)
        XCTAssertTrue(plan.requiresUserChoice)
        XCTAssertEqual(plan.alternatives.first?.qualityLabel, "F32")
    }

    func testLegacyModelSettingsEnableProjectorByDefault() throws {
        let decoded = try JSONDecoder().decode(
            ModelSettings.self,
            from: Data(#"{"contextLength":4096}"#.utf8)
        )
        XCTAssertTrue(decoded.loadVisionProjector)

        var disabled = ModelSettings()
        disabled.loadVisionProjector = false
        let roundTrip = try JSONDecoder().decode(
            ModelSettings.self,
            from: JSONEncoder().encode(disabled)
        )
        XCTAssertFalse(roundTrip.loadVisionProjector)
    }
}
