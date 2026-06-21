import CoreGraphics
import CoreText
import Foundation

enum ChatExportPackBuilder {
    enum ExportKind: String, CaseIterable, Hashable {
        case markdown
        case pdf
        case docx
        case citationsJSON
        case promptReceipt
        case generationReplayJSON

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .pdf: return "pdf"
            case .docx: return "docx"
            case .citationsJSON: return "json"
            case .promptReceipt: return "txt"
            case .generationReplayJSON: return "json"
            }
        }

        var filenameSuffix: String {
            switch self {
            case .markdown: return "note"
            case .pdf: return "note"
            case .docx: return "note"
            case .citationsJSON: return "citations"
            case .promptReceipt: return "prompt-receipt"
            case .generationReplayJSON: return "generation-replay"
            }
        }
    }

    enum ExportError: LocalizedError {
        case pdfContextUnavailable

        var errorDescription: String? {
            switch self {
            case .pdfContextUnavailable:
                return String(localized: "Export file unavailable")
            }
        }
    }

    static func writeExportPack(
        title: String,
        markdownNote: String,
        citationsJSON: String,
        promptReceipt: String,
        generationReplayJSON: String,
        exportedAt: Date = Date(),
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> [ExportKind: URL] {
        let packageDirectory = directory
            .appendingPathComponent("noema-export-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)

        let stem = "\(sanitizedFileStem(title))-\(fileTimestamp(exportedAt))"
        let payloads: [(ExportKind, Data)] = [
            (.markdown, Data(markdownNote.utf8)),
            (.pdf, try makePDFData(title: title, markdownNote: markdownNote)),
            (.docx, makeDOCXData(title: title, markdownNote: markdownNote)),
            (.citationsJSON, Data(citationsJSON.utf8)),
            (.promptReceipt, Data(promptReceipt.utf8)),
            (.generationReplayJSON, Data(generationReplayJSON.utf8))
        ]

        var urls: [ExportKind: URL] = [:]
        for (kind, data) in payloads {
            let filename = "\(stem)-\(kind.filenameSuffix).\(kind.fileExtension)"
            let url = packageDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: [.atomic])
            urls[kind] = url
        }
        return urls
    }

    static func makePDFData(title: String, markdownNote: String) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ExportError.pdfContextUnavailable
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.pdfContextUnavailable
        }

        let body = "# \(title)\n\n\(markdownNote)"
        let font = CTFontCreateWithName("Menlo" as CFString, 10, nil)
        var lineSpacing: CGFloat = 2
        let paragraph = withUnsafePointer(to: &lineSpacing) { pointer in
            CTParagraphStyleCreate(
                [CTParagraphStyleSetting(
                    spec: .lineSpacingAdjustment,
                    valueSize: MemoryLayout<CGFloat>.size,
                    value: pointer
                )],
                1
            )
        }
        let attributed = NSAttributedString(
            string: body,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1),
                .paragraphStyle: paragraph
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = mediaBox.insetBy(dx: 48, dy: 54)
        let path = CGMutablePath()
        path.addRect(CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: textRect.height))

        var range = CFRange(location: 0, length: 0)
        while range.location < attributed.length {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity

            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.restoreGState()
            context.endPDFPage()

            guard visible.length > 0 else { break }
            range.location += visible.length
        }

        context.closePDF()
        return data as Data
    }

    static func makeDOCXData(title: String, markdownNote: String) -> Data {
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
        \(docxParagraphs(for: "# \(title)\n\n\(markdownNote)"))
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/></w:sectPr>
          </w:body>
        </w:document>
        """
        let files = [
            ZipEntry(
                path: "[Content_Types].xml",
                data: Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
                  <Default Extension="xml" ContentType="application/xml"/>
                  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
                </Types>
                """.utf8)
            ),
            ZipEntry(
                path: "_rels/.rels",
                data: Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
                </Relationships>
                """.utf8)
            ),
            ZipEntry(path: "word/document.xml", data: Data(documentXML.utf8))
        ]
        return makeStoredZip(entries: files)
    }

    static func sanitizedFileStem(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(localized: "Noema Chat")
        let source = trimmed.isEmpty ? fallback : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stem = String(collapsed.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return stem.isEmpty ? "noema-chat" : stem
    }

    static func fileTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func docxParagraphs(for text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let escaped = xmlEscaped(trimmed.isEmpty ? " " : trimmed)
                return """
                    <w:p><w:r><w:t xml:space="preserve">\(escaped)</w:t></w:r></w:p>
                """
            }
            .joined(separator: "\n")
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private struct ZipEntry {
        let path: String
        let data: Data
    }

    private struct CentralDirectoryEntry {
        let pathData: Data
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private static func makeStoredZip(entries: [ZipEntry]) -> Data {
        var output = Data()
        var centralDirectory: [CentralDirectoryEntry] = []
        let (dosTime, dosDate) = dosTimestamp(Date())

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(output.count)

            output.appendUInt32LE(0x04034b50)
            output.appendUInt16LE(20)
            output.appendUInt16LE(0)
            output.appendUInt16LE(0)
            output.appendUInt16LE(dosTime)
            output.appendUInt16LE(dosDate)
            output.appendUInt32LE(crc)
            output.appendUInt32LE(UInt32(entry.data.count))
            output.appendUInt32LE(UInt32(entry.data.count))
            output.appendUInt16LE(UInt16(pathData.count))
            output.appendUInt16LE(0)
            output.append(pathData)
            output.append(entry.data)

            centralDirectory.append(CentralDirectoryEntry(pathData: pathData, data: entry.data, crc: crc, offset: offset))
        }

        let centralStart = UInt32(output.count)
        for entry in centralDirectory {
            output.appendUInt32LE(0x02014b50)
            output.appendUInt16LE(20)
            output.appendUInt16LE(20)
            output.appendUInt16LE(0)
            output.appendUInt16LE(0)
            output.appendUInt16LE(dosTime)
            output.appendUInt16LE(dosDate)
            output.appendUInt32LE(entry.crc)
            output.appendUInt32LE(UInt32(entry.data.count))
            output.appendUInt32LE(UInt32(entry.data.count))
            output.appendUInt16LE(UInt16(entry.pathData.count))
            output.appendUInt16LE(0)
            output.appendUInt16LE(0)
            output.appendUInt16LE(0)
            output.appendUInt16LE(0)
            output.appendUInt32LE(0)
            output.appendUInt32LE(entry.offset)
            output.append(entry.pathData)
        }

        let centralSize = UInt32(output.count) - centralStart
        output.appendUInt32LE(0x06054b50)
        output.appendUInt16LE(0)
        output.appendUInt16LE(0)
        output.appendUInt16LE(UInt16(centralDirectory.count))
        output.appendUInt16LE(UInt16(centralDirectory.count))
        output.appendUInt32LE(centralSize)
        output.appendUInt32LE(centralStart)
        output.appendUInt16LE(0)
        return output
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = max((components.year ?? 1980) - 1980, 0)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crcTable[index]
        }
        return crc ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >>= 1
            }
        }
        return crc
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
