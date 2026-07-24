import XCTest
@testable import Noema

final class ModelSettingsSectionSnapshotTests: XCTestCase {
    func testCompactIPhoneSectionsByFormat() {
        XCTAssertEqual(
            sectionIDs(for: .gguf, isAdvancedMode: false, platform: .iOSForm),
            ["essentials", "performance", "behavior", "details"]
        )
        XCTAssertEqual(
            sectionIDs(for: .mlx, isAdvancedMode: false, platform: .iOSForm),
            ["essentials", "performance", "behavior", "details"]
        )
        XCTAssertEqual(
            sectionIDs(for: .et, isAdvancedMode: false, platform: .iOSForm),
            ["essentials", "performance", "behavior", "details"]
        )
        XCTAssertEqual(
            sectionIDs(for: .ane, isAdvancedMode: false, platform: .iOSForm),
            ["essentials", "performance", "behavior", "details"]
        )
        XCTAssertEqual(
            sectionIDs(for: .afm, isAdvancedMode: false, platform: .iOSForm),
            ["essentials", "performance", "behavior", "details"]
        )
    }

    func testAdvancedIPhoneSectionsByFormat() {
        XCTAssertEqual(
            sectionIDs(for: .gguf, isAdvancedMode: true, platform: .iOSForm),
            ["essentials", "performance", "behavior", "advanced", "details"]
        )
        XCTAssertEqual(
            sectionIDs(for: .mlx, isAdvancedMode: true, platform: .iOSForm),
            ["essentials", "performance", "behavior", "advanced", "details"]
        )
        XCTAssertEqual(
            sectionIDs(for: .et, isAdvancedMode: true, platform: .iOSForm),
            ["essentials", "performance", "behavior", "advanced", "details"]
        )
        XCTAssertEqual(
            sectionIDs(for: .ane, isAdvancedMode: true, platform: .iOSForm),
            ["essentials", "performance", "behavior", "advanced", "details"]
        )
        XCTAssertEqual(
            sectionIDs(for: .afm, isAdvancedMode: true, platform: .iOSForm),
            ["essentials", "performance", "behavior", "advanced", "details"]
        )
    }

    func testMacUsesTheSameHierarchyAsOtherDevices() {
        XCTAssertEqual(
            sectionIDs(for: .gguf, isAdvancedMode: true, platform: .macOS),
            ["essentials", "performance", "behavior", "advanced", "details"]
        )
        XCTAssertEqual(
            sectionIDs(for: .afm, isAdvancedMode: true, platform: .macOS),
            ["essentials", "performance", "behavior", "advanced", "details"]
        )
    }

    func testSectionTitlesDescribeTheSharedInformationArchitecture() {
        let ane = ModelSettingsSectionSnapshot.sections(for: .ane, isAdvancedMode: false, platform: .iOSForm)
        XCTAssertEqual(ane.first?.title, "Essentials")
        XCTAssertEqual(ane.last?.title, "Model Details")

        let gguf = ModelSettingsSectionSnapshot.sections(for: .gguf, isAdvancedMode: false, platform: .iOSForm)
        XCTAssertEqual(gguf.map(\.title), ["Essentials", "Performance", "Behavior", "Model Details"])
    }

    private func sectionIDs(
        for format: ModelFormat,
        isAdvancedMode: Bool,
        platform: ModelSettingsSectionSnapshot.Platform
    ) -> [String] {
        ModelSettingsSectionSnapshot
            .sections(for: format, isAdvancedMode: isAdvancedMode, platform: platform)
            .map { $0.id.rawValue }
    }
}
