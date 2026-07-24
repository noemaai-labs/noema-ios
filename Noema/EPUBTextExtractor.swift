import Foundation
import Compression

/// Minimal EPUB (.epub) text extractor used for RAG.
///
/// - Does not aim to be a full EPUB renderer.
/// - Reads the ZIP central directory, extracts XHTML/HTML files and strips tags.
/// - Supports stored (0) and deflate (8) compression methods.
/// - Best-effort; silently skips malformed entries.
struct EPUBTextExtractor {
    private struct CentralEntry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Extracts plain text from an EPUB, invoking `onUnit` for each content file processed.
    /// - Parameters:
    ///   - url: Path to the `.epub` file.
    ///   - onUnit: Called with (processed, total) counts for progress reporting.
    /// - Returns: A single string containing all textual content joined by blank lines.
    static func extractText(from url: URL, onUnit: ((Int, Int) -> Void)? = nil) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        guard let entries = parseCentralDirectory(data) else { return "" }
        let content = entries.filter { n in
            let lower = n.name.lowercased()
            return lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm")
        }
        guard !content.isEmpty else { return "" }
        var texts: [String] = []
        let total = content.count
        var processed = 0
        for e in content {
            if let bytes = extractFileData(from: data, entry: e), !bytes.isEmpty {
                if let s = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) {
                    let t = stripHTML(s)
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { texts.append(t) }
                }
            }
            processed += 1
            onUnit?(processed, total)
        }
        return texts.joined(separator: "\n\n")
    }

    /// Counts how many XHTML/HTML files are present in the EPUB for progress budgeting.
    static func countHTMLUnits(in url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        guard let entries = parseCentralDirectory(data) else { return 0 }
        return entries.filter { e in
            let lower = e.name.lowercased()
            return lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm")
        }.count
    }

    // MARK: - ZIP parsing

    private static func parseCentralDirectory(_ data: Data) -> [CentralEntry]? {
        // EOCD signature 0x06054b50
        let eocdSig: UInt32 = 0x06054b50
        let maxSearch = min(65_535 + 22, data.count)
        var eocdOffset: Int? = nil
        if maxSearch <= 0 { return nil }
        let start = data.count - maxSearch
        var i = data.count - 22
        while i >= start {
            if readU32(data, i) == eocdSig { eocdOffset = i; break }
            i -= 1
        }
        guard let eocd = eocdOffset else { return nil }
        // EOCD layout:
        // offset+8: number of entries on this disk (2)
        // offset+10: total number of entries (2)
        // offset+12: central directory size (4)
        // offset+16: central directory offset (4)
        let totalEntries = Int(readU16(data, eocd + 10))
        let cdOffset = Int(readU32(data, eocd + 16))
        let cdSig: UInt32 = 0x02014b50
        var entries: [CentralEntry] = []
        var off = cdOffset
        for _ in 0..<totalEntries {
            if off + 46 > data.count { break }
            if readU32(data, off) != cdSig { break }
            let method = readU16(data, off + 10)
            let compSize = Int(readU32(data, off + 20))
            let uncomp = Int(readU32(data, off + 24))
            let nameLen = Int(readU16(data, off + 28))
            let extraLen = Int(readU16(data, off + 30))
            let commentLen = Int(readU16(data, off + 32))
            let localHeaderRel = Int(readU32(data, off + 42))
            let nameStart = off + 46
            if nameStart + nameLen > data.count { break }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            entries.append(CentralEntry(name: name, method: method, compressedSize: compSize, uncompressedSize: uncomp, localHeaderOffset: localHeaderRel))
            off = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func extractFileData(from data: Data, entry: CentralEntry) -> Data? {
        // Local header signature 0x04034b50
        let localSig: UInt32 = 0x04034b50
        var lh = entry.localHeaderOffset
        if lh + 30 > data.count { return nil }
        if readU32(data, lh) != localSig { return nil }
        let nameLen = Int(readU16(data, lh + 26))
        let extraLen = Int(readU16(data, lh + 28))
        let dataStart = lh + 30 + nameLen + extraLen
        let compEnd = dataStart + entry.compressedSize
        if dataStart > data.count || compEnd > data.count { return nil }
        let comp = data.subdata(in: dataStart..<compEnd)
        switch entry.method {
        case 0: // stored
            return comp
        case 8: // deflate
            return inflate(data: comp, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    private static func inflate(data: Data, expectedSize: Int) -> Data? {
        if expectedSize > 0 {
            var out = Data(count: expectedSize)
            let resultSize = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!,
                        expectedSize,
                        src.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if resultSize > 0 { out.count = resultSize; return out }
        }
        // Fallback streaming when expected size is unknown
        let dstChunk = 64 * 1024
        var stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        var s = stream.pointee
        var status = compression_stream_init(&s, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(&s) }
        let srcBuffer = data
        let srcCount = srcBuffer.count
        if srcCount == 0 { return nil }
        var outData = Data()
        outData.reserveCapacity(max(expectedSize, 128 * 1024))
        srcBuffer.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) in
            s.src_ptr = srcPtr.bindMemory(to: UInt8.self).baseAddress!
            s.src_size = srcCount
            var dst = [UInt8](repeating: 0, count: dstChunk)
            while status == COMPRESSION_STATUS_OK {
                dst.withUnsafeMutableBytes { dstPtr in
                    s.dst_ptr = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                    s.dst_size = dstChunk
                    status = compression_stream_process(&s, 0)
                    let produced = dstChunk - s.dst_size
                    if produced > 0 {
                        let ptr = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                        outData.append(ptr, count: produced)
                    }
                }
            }
            // Drain remaining output
            while status == COMPRESSION_STATUS_END && s.dst_size == 0 {
                var dst = [UInt8](repeating: 0, count: dstChunk)
                dst.withUnsafeMutableBytes { dstPtr in
                    s.dst_ptr = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                    s.dst_size = dstChunk
                    status = compression_stream_process(&s, 0)
                    let produced = dstChunk - s.dst_size
                    if produced > 0 {
                        let ptr = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                        outData.append(ptr, count: produced)
                    }
                }
            }
        }
        return outData.isEmpty ? nil : outData
    }

    // MARK: - Utilities
    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        if offset + 2 > data.count { return 0 }
        return data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { ptr in
            UInt16(littleEndian: ptr.load(as: UInt16.self))
        }
    }
    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        if offset + 4 > data.count { return 0 }
        return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { ptr in
            UInt32(littleEndian: ptr.load(as: UInt32.self))
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        // Remove scripts/styles
        let patterns = ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>"]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            }
        }
        // Replace <br> and block tags with newlines for readability
        let blockTags = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>", "</li>", "</tr>", "</section>", "</article>"]
        for tag in blockTags { text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive) }
        text = text.replacingOccurrences(of: "<br ?/?>", with: "\n", options: .regularExpression)
        // Strip remaining tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        }
        // Collapse whitespace
        text = text.replacingOccurrences(of: "\r", with: "")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


