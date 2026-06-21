import XCTest
@testable import Noema

final class ModelSettingsSectionSnapshotTests: XCTestCase {
    func testCompactIPhoneSectionsByFormat() {
        XCTAssertEqual(
            sectionIDs(for: .gguf, isAdvancedMode: false, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "benchmark", "maintenance", "files", "provenance"]
        )
        XCTAssertEqual(
            sectionIDs(for: .mlx, isAdvancedMode: false, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "benchmark", "maintenance", "provenance"]
        )
        XCTAssertEqual(
            sectionIDs(for: .et, isAdvancedMode: false, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "benchmark", "maintenance", "provenance"]
        )
        XCTAssertEqual(
            sectionIDs(for: .ane, isAdvancedMode: false, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "benchmark", "maintenance", "provenance"]
        )
        XCTAssertEqual(
            sectionIDs(for: .afm, isAdvancedMode: false, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "benchmark", "maintenance", "provenance"]
        )
    }

    func testAdvancedIPhoneSectionsByFormat() {
        XCTAssertEqual(
            sectionIDs(for: .gguf, isAdvancedMode: true, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "sampling", "speculativeDecoding", "benchmark", "maintenance", "files", "provenance"]
        )
        XCTAssertEqual(
            sectionIDs(for: .mlx, isAdvancedMode: true, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "sampling", "benchmark", "maintenance", "provenance"]
        )
        XCTAssertEqual(
            sectionIDs(for: .et, isAdvancedMode: true, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "sampling", "benchmark", "maintenance", "provenance"]
        )
        XCTAssertEqual(
            sectionIDs(for: .ane, isAdvancedMode: true, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "sampling", "benchmark", "maintenance", "provenance"]
        )
        XCTAssertEqual(
            sectionIDs(for: .afm, isAdvancedMode: true, platform: .iOSForm),
            ["overview", "chatTemplatePreview", "formatSpecific", "sampling", "benchmark", "maintenance", "provenance"]
        )
    }

    func testMacSectionsOmitTemplatePreviewAndKeepFormatSpecificPolicy() {
        XCTAssertEqual(
            sectionIDs(for: .gguf, isAdvancedMode: true, platform: .macOS),
            ["overview", "formatSpecific", "sampling", "speculativeDecoding", "benchmark", "maintenance", "files", "provenance"]
        )
        XCTAssertEqual(
            sectionIDs(for: .afm, isAdvancedMode: true, platform: .macOS),
            ["overview", "formatSpecific", "sampling", "benchmark", "maintenance", "provenance"]
        )
    }

    func testSectionTitlesUseFormatDisplayNames() {
        let ane = ModelSettingsSectionSnapshot.sections(for: .ane, isAdvancedMode: false, platform: .iOSForm)
        XCTAssertEqual(ane.first?.title, "CML")
        XCTAssertEqual(ane.first(where: { $0.id == .formatSpecific })?.title, "CML")

        let gguf = ModelSettingsSectionSnapshot.sections(for: .gguf, isAdvancedMode: false, platform: .iOSForm)
        XCTAssertEqual(gguf.first?.title, "GGUF")
        XCTAssertEqual(gguf.first(where: { $0.id == .provenance })?.title, "Provenance")
        XCTAssertEqual(gguf.first(where: { $0.id == .files })?.title, "Files")
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
