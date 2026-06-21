import XCTest
@testable import Noema

final class QuantComparisonProfileTests: XCTestCase {
    func testHigherBitQuantHasBetterQualityAndLowerSpeedThanSmallerQuant() {
        let q2 = makeQuant(label: "Q2_K", sizeBytes: 1_200_000_000)
        let q4 = makeQuant(label: "Q4_K_M", sizeBytes: 2_800_000_000)
        let q8 = makeQuant(label: "Q8_0", sizeBytes: 5_600_000_000)

        let profiles = QuantComparisonProfile.make(for: [q2, q4, q8])
        let q2Profile = try! XCTUnwrap(profiles.first { $0.label == "Q2_K" })
        let q4Profile = try! XCTUnwrap(profiles.first { $0.label == "Q4_K_M" })
        let q8Profile = try! XCTUnwrap(profiles.first { $0.label == "Q8_0" })

        XCTAssertEqual(q8Profile.quality, .high)
        XCTAssertGreaterThan(q4Profile.quality, q2Profile.quality)
        XCTAssertGreaterThan(q2Profile.speed, q8Profile.speed)
        XCTAssertTrue(q2Profile.isSmallest)
        XCTAssertTrue(q8Profile.isBestQuality)
    }

    func testRuntimeFormatsPreferFastSpeedTier() {
        let et = makeQuant(label: "ExecuTorch", format: .et, sizeBytes: 1_800_000_000)
        let ane = makeQuant(label: "CML", format: .ane, sizeBytes: 2_200_000_000)

        let profiles = QuantComparisonProfile.make(for: [et, ane])

        XCTAssertEqual(profiles.first { $0.format == .et }?.speed, .high)
        XCTAssertEqual(profiles.first { $0.format == .ane }?.speed, .high)
    }

    private func makeQuant(label: String, format: ModelFormat = .gguf, sizeBytes: Int64) -> QuantInfo {
        QuantInfo(
            label: label,
            format: format,
            sizeBytes: sizeBytes,
            downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/\(label).bin")!,
            sha256: nil,
            configURL: nil
        )
    }
}
