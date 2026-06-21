import Foundation
import XCTest
@testable import Noema

final class ChatExportPackBuilderTests: XCTestCase {
    func testExportPackWritesAllRequestedArtifacts() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-export-pack-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let urls = try ChatExportPackBuilder.writeExportPack(
            title: "Research Chat",
            markdownNote: "# Research Chat\n\nAssistant answer with [1].",
            citationsJSON: #"{"messages":[{"citations":[{"source":"paper.pdf","text":"quoted"}]}]}"#,
            promptReceipt: "Settings Summary: balanced",
            generationReplayJSON: #"{"schema":"noema.generation_replay"}"#,
            exportedAt: Date(timeIntervalSince1970: 0),
            directory: tempDirectory
        )

        XCTAssertEqual(Set(urls.keys), Set(ChatExportPackBuilder.ExportKind.allCases))
        XCTAssertEqual(urls[.markdown]?.pathExtension, "md")
        XCTAssertEqual(urls[.pdf]?.pathExtension, "pdf")
        XCTAssertEqual(urls[.docx]?.pathExtension, "docx")
        XCTAssertEqual(urls[.citationsJSON]?.pathExtension, "json")
        XCTAssertEqual(urls[.promptReceipt]?.pathExtension, "txt")
        XCTAssertEqual(urls[.generationReplayJSON]?.pathExtension, "json")

        for url in urls.values {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing export file \(url.path)")
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            XCTAssertGreaterThan(size?.intValue ?? 0, 0)
        }
    }

    func testPDFAndDOCXPayloadsAreRecognizableDocuments() throws {
        let markdown = "# Title\n\nA&B <private> citation."
        let pdfData = try ChatExportPackBuilder.makePDFData(title: "Title", markdownNote: markdown)
        let docxData = ChatExportPackBuilder.makeDOCXData(title: "Title", markdownNote: markdown)

        XCTAssertTrue(pdfData.starts(with: Data("%PDF".utf8)))
        XCTAssertTrue(docxData.starts(with: Data([0x50, 0x4b, 0x03, 0x04])))
        XCTAssertNotNil(docxData.range(of: Data("word/document.xml".utf8)))
        XCTAssertNotNil(docxData.range(of: Data("A&amp;B &lt;private&gt; citation.".utf8)))
    }

    func testFileStemSanitizesChatTitles() {
        XCTAssertEqual(
            ChatExportPackBuilder.sanitizedFileStem("  Project / Legal: Notes?  "),
            "Project---Legal--Notes"
        )
        XCTAssertEqual(ChatExportPackBuilder.sanitizedFileStem(""), "Noema-Chat")
    }
}
