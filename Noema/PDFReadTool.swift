import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

public struct PDFReadTool: Tool {
    public let name = "noema.pdf.read"
    public let description = "Read and search a PDF in the active chat dataset. Use \"info\" for a PDF's page count + table of contents, \"grep\" to find one literal word/number/name/contiguous phrase (or an intentional regex; returns line numbers + pages + context), \"lines\" to extract an exact line range, and \"read\" for whole pages. A plain multi-word grep query is one exact phrase, not a keyword list. Pair grep→lines the way you'd grep a codebase then read the matching lines."
    public let schema = #"""
    { "type":"object", "properties":{
        "action":{"type":"string","enum":["info","grep","lines","read"],"description":"\"info\": list PDFs with page count + table of contents. \"grep\": search for one literal word or contiguous phrase, or an intentional regex; returns matching line numbers, pages, and surrounding context. \"lines\": extract an exact range of lines (use the line numbers grep returned). \"read\": return the text of whole pages."},
        "document":{"type":"string","description":"Optional PDF name (or part of it) to target when more than one PDF is available."},
        "query":{"type":"string","description":"For action \"grep\": one literal word, number, name, or contiguous phrase. Spaces are part of the exact phrase; they do not separate independent keywords. Do not combine unrelated terms in one plain query. Search one distinctive term or short phrase per call, or set \"regex\":true for intentional alternatives such as revenue|sales."},
        "regex":{"type":"boolean","default":false,"description":"For action \"grep\": treat \"query\" as a regular expression instead of plain text."},
        "ignore_case":{"type":"boolean","default":true,"description":"For action \"grep\": case-insensitive match (default true)."},
        "context":{"type":"integer","default":2,"description":"For action \"grep\": lines of context to include before and after each match (0-10)."},
        "max_matches":{"type":"integer","default":20,"description":"For action \"grep\": cap on matches returned (1-50)."},
        "start":{"type":"integer","description":"For action \"lines\": first line number to extract (1-based, from grep output)."},
        "end":{"type":"integer","description":"For action \"lines\": last line number to extract (inclusive)."},
        "pages":{"type":"string","description":"For action \"read\": which pages to read, e.g. \"3\", \"3-7\", or \"3,5,9\". Up to 20 pages per call."},
        "ocr":{"type":"boolean","default":false,"description":"For action \"read\": run on-device OCR on requested pages that have no text layer (scanned images). Slower; use it only on the pages you need."}
    }, "required":["action"] }
    """#

    public init() {}

    // MARK: - Sendable output models

    struct OutlineEntry: Codable, Sendable { let title: String; let page: Int?; let depth: Int }
    struct PDFInfo: Codable, Sendable { let name: String; let pageCount: Int; let lineCount: Int; let title: String?; let outline: [OutlineEntry] }
    struct InfoResult: Codable, Sendable { let documents: [PDFInfo] }
    struct PageText: Codable, Sendable { let page: Int; let text: String }
    struct ReadResult: Codable, Sendable { let document: String; let pageCount: Int; let pages: [PageText] }
    struct GrepMatch: Codable, Sendable { let line: Int; let page: Int; let text: String; let before: [String]; let after: [String] }
    struct GrepResult: Codable, Sendable { let document: String; let pageCount: Int; let lineCount: Int; let totalMatches: Int; let truncated: Bool; let matches: [GrepMatch]; let hint: String? }
    struct LineText: Codable, Sendable { let line: Int; let page: Int; let text: String }
    struct LinesResult: Codable, Sendable { let document: String; let pageCount: Int; let lineCount: Int; let start: Int; let end: Int; let truncated: Bool; let lines: [LineText] }
    struct PDFRef: Sendable { let name: String; let url: URL }
    enum ReadOutcome: Sendable { case ok(ReadResult); case error(String) }
    enum GrepOutcome: Sendable { case ok(GrepResult); case error(String) }
    enum LinesOutcome: Sendable { case ok(LinesResult); case error(String) }

    // A line in the flattened, page-tracked line index. `grep` and `lines` build the
    // SAME index so the line numbers grep returns are valid inputs to lines.
    struct LineRef: Sendable { let line: Int; let page: Int; let text: String }

    private struct LineIndexCacheKey: Hashable {
        let path: String
        let fileSize: Int
        let modifiedAt: TimeInterval
    }

    private final class LineIndexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LineIndexCacheKey: [LineRef]] = [:]
        private var insertionOrder: [LineIndexCacheKey] = []
        private let limit = 8

        func value(for key: LineIndexCacheKey) -> [LineRef]? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func insert(_ value: [LineRef], for key: LineIndexCacheKey) {
            lock.lock()
            defer { lock.unlock() }
            if values[key] == nil { insertionOrder.append(key) }
            values[key] = value
            while insertionOrder.count > limit {
                values.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
    }

    private static let maxPagesPerCall = 20
    private static let maxCharsPerPage = 4000
    private static let maxDocuments = 50
    private static let maxIndexLines = 50_000
    private static let maxLinesPerExtract = 300
    private static let maxCharsPerLine = 2000
    private static let lineIndexCache = LineIndexCache()

    public func call(args: Data) async throws -> Data {
        struct Args: Decodable {
            let action: String
            let document: String?
            let query: String?
            let regex: Bool?
            let ignore_case: Bool?
            let context: Int?
            let max_matches: Int?
            let start: Int?
            let end: Int?
            let pages: String?
            let ocr: Bool?
        }
        let input = try JSONDecoder().decode(Args.self, from: args)

        #if canImport(PDFKit)
        let pdfs = await Task.detached(priority: .userInitiated) { Self.discoverPDFs() }.value
        guard !pdfs.isEmpty else {
            return try err("No PDF is available in this chat's active dataset.")
        }

        let wanted = input.document?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The PDFs in this chat's active dataset (set by ChatVM, newline-joined).
        // When there is exactly one, "read the PDF" can omit the filename.
        let preferredNames = (UserDefaults.standard.string(forKey: "pdfToolPreferredDocuments") ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let matchPDF: (String) -> PDFRef? = { query in
            // Match the on-disk filename ("doc.pdf"), then the name WITHOUT its extension
            // (dataset display names may be stored extension-stripped), then a loose
            // substring as a last resort for partial names the model might pass.
            pdfs.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
                ?? pdfs.first { ($0.name as NSString).deletingPathExtension.caseInsensitiveCompare(query) == .orderedSame }
                ?? pdfs.first { $0.name.localizedCaseInsensitiveContains(query) }
        }
        var seenPreferred = Set<String>()
        let preferredRefs = preferredNames.compactMap(matchPDF).filter { seenPreferred.insert($0.name).inserted }
        let target: PDFRef? = {
            if let wanted, !wanted.isEmpty { return matchPDF(wanted) }
            if pdfs.count == 1 { return pdfs.first }
            if preferredRefs.count == 1 { return preferredRefs.first }
            return nil
        }()
        // No target: if the model named a doc, say it wasn't found; else ask it to choose —
        // listing the active dataset's PDFs when there are several.
        func targetMissingError() -> String {
            if let wanted, !wanted.isEmpty {
                return "No PDF matching \"\(wanted)\". Available: \(pdfs.map(\.name).joined(separator: ", "))."
            }
            let choices = preferredRefs.count > 1 ? preferredRefs : pdfs
            return "Multiple PDFs available — set \"document\" to one of: \(choices.map(\.name).joined(separator: ", "))."
        }

        switch input.action.lowercased() {
        case "info":
            let refs = target.map { [$0] } ?? pdfs
            let infos = await Task.detached(priority: .userInitiated) { refs.compactMap { Self.info(for: $0) } }.value
            return try JSONEncoder().encode(InfoResult(documents: infos))

        case "grep":
            guard let query = input.query, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return try err("Provide a \"query\" to grep for, e.g. \"revenue\" or a regex with \"regex\":true.")
            }
            guard let ref = target else {
                return try err(targetMissingError())
            }
            let regex = input.regex ?? false
            let ignoreCase = input.ignore_case ?? true
            let context = min(max(input.context ?? 2, 0), 10)
            let maxMatches = min(max(input.max_matches ?? 20, 1), 50)
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.grep(ref: ref, query: query, regex: regex, ignoreCase: ignoreCase, context: context, maxMatches: maxMatches)
            }.value
            switch outcome {
            case .ok(let result): return try JSONEncoder().encode(result)
            case .error(let message): return try err(message)
            }

        case "lines":
            guard let start = input.start, let end = input.end else {
                return try err("Provide \"start\" and \"end\" line numbers for action \"lines\" (use the line numbers from grep).")
            }
            guard let ref = target else {
                return try err(targetMissingError())
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.extractLines(ref: ref, start: start, end: end)
            }.value
            switch outcome {
            case .ok(let result): return try JSONEncoder().encode(result)
            case .error(let message): return try err(message)
            }

        case "read":
            guard let pages = input.pages, !pages.trimmingCharacters(in: .whitespaces).isEmpty else {
                return try err("Provide pages to read for action \"read\", e.g. \"3-7\".")
            }
            guard let ref = target else {
                return try err(targetMissingError())
            }
            let enableOCR = input.ocr ?? false
            let outcome = await Task.detached(priority: .userInitiated) { Self.readPages(ref: ref, spec: pages, enableOCR: enableOCR) }.value
            switch outcome {
            case .ok(let result): return try JSONEncoder().encode(result)
            case .error(let message): return try err(message)
            }

        default:
            return try err("Unknown action \"\(input.action)\". Use \"info\", \"grep\", \"lines\", or \"read\".")
        }
        #else
        return try err("PDF reading isn't available on this platform.")
        #endif
    }

    private func err(_ message: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["error": message])
    }

    #if canImport(PDFKit)
    // MARK: - PDFKit helpers (run off the main actor)

    private static func discoverPDFs() -> [PDFRef] {
        // The active dataset root is set whenever the user selects a dataset for
        // this chat. Never fall back to the entire library: that would let a model
        // cross the chat's explicit document boundary by guessing another filename.
        guard let rootPath = UserDefaults.standard.string(forKey: "pdfToolActiveDatasetRoot"),
              !rootPath.isEmpty else { return [] }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        return PDFDatasetAccess.pdfURLs(in: root, limit: maxDocuments).map {
            PDFRef(name: $0.lastPathComponent, url: $0)
        }
    }

    private static func info(for ref: PDFRef) -> PDFInfo? {
        guard let doc = PDFDocument(url: ref.url) else { return nil }
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PDFInfo(
            name: ref.name,
            pageCount: doc.pageCount,
            // Whitespace repair never changes native line boundaries. Count
            // native lines here so a metadata-only call does not OCR every page.
            lineCount: nativeLineCount(doc),
            title: (title?.isEmpty == false) ? title : nil,
            outline: outlineEntries(doc)
        )
    }

    private static func nativeLineCount(_ doc: PDFDocument) -> Int {
        var count = 0
        for pageIndex in 0..<doc.pageCount {
            guard let pageText = doc.page(at: pageIndex)?.string else { continue }
            count += pageText.split(separator: "\n", omittingEmptySubsequences: false).count
            if count >= maxIndexLines { return maxIndexLines }
        }
        return count
    }

    private static func outlineEntries(_ doc: PDFDocument) -> [OutlineEntry] {
        guard let root = doc.outlineRoot else { return [] }
        var entries: [OutlineEntry] = []
        func walk(_ node: PDFOutline, depth: Int) {
            guard entries.count < 500 else { return }
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    var pageNumber: Int?
                    if let page = child.destination?.page {
                        pageNumber = doc.index(for: page) + 1
                    }
                    entries.append(OutlineEntry(title: label, page: pageNumber, depth: depth))
                }
                walk(child, depth: depth + 1)
                if entries.count >= 500 { return }
            }
        }
        walk(root, depth: 0)
        return entries
    }

    // Flatten the PDF's text layer into a page-tracked, globally line-numbered index.
    // grep and lines share this so the numbers grep reports are valid lines inputs.
    private static func buildLineIndex(_ doc: PDFDocument, url: URL) -> [LineRef] {
        let cacheKey = makeLineIndexCacheKey(url: url)
        if let cacheKey, let cached = lineIndexCache.value(for: cacheKey) {
            return cached
        }
        var refs: [LineRef] = []
        var lineNo = 1
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let pageText = PDFTextExtractor.text(
                from: page,
                documentURL: url,
                pageNumber: p + 1,
                ocrEmptyPage: false
            )
            for raw in pageText.split(separator: "\n", omittingEmptySubsequences: false) {
                refs.append(LineRef(line: lineNo, page: p + 1, text: String(raw)))
                lineNo += 1
                if refs.count >= maxIndexLines {
                    if let cacheKey { lineIndexCache.insert(refs, for: cacheKey) }
                    return refs
                }
            }
        }
        if let cacheKey { lineIndexCache.insert(refs, for: cacheKey) }
        return refs
    }

    private static func makeLineIndexCacheKey(url: URL) -> LineIndexCacheKey? {
        let standardized = url.standardizedFileURL
        guard let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return LineIndexCacheKey(
            path: standardized.path,
            fileSize: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        )
    }

    private static func grep(ref: PDFRef, query: String, regex: Bool, ignoreCase: Bool, context: Int, maxMatches: Int) -> GrepOutcome {
        guard let doc = PDFDocument(url: ref.url) else { return .error("Couldn't open \"\(ref.name)\".") }
        let index = buildLineIndex(doc, url: ref.url)
        guard !index.isEmpty else {
            return .error("\"\(ref.name)\" has no extractable text layer to search — it may be a scanned image. Try noema.rag.search (it used OCR at index time), or action \"read\" with ocr:true.")
        }

        // Build the matcher once.
        let matcher: (String) -> Bool
        if regex {
            var options: NSRegularExpression.Options = []
            if ignoreCase { options.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: query, options: options) else {
                return .error("Invalid regular expression: \"\(query)\".")
            }
            matcher = { line in
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                return re.firstMatch(in: line, options: [], range: range) != nil
            }
        } else {
            matcher = { line in
                PDFTextExtractor.containsPlainText(query, in: line, ignoreCase: ignoreCase)
            }
        }

        var matches: [GrepMatch] = []
        var total = 0
        for (i, entry) in index.enumerated() {
            guard matcher(entry.text) else { continue }
            total += 1
            if matches.count < maxMatches {
                let before = (max(0, i - context)..<i).map { clip(index[$0].text) }
                let after = ((i + 1)..<min(index.count, i + 1 + context)).map { clip(index[$0].text) }
                matches.append(GrepMatch(line: entry.line, page: entry.page, text: clip(entry.text), before: before, after: after))
            }
        }
        return .ok(GrepResult(
            document: ref.name,
            pageCount: doc.pageCount,
            lineCount: index.count,
            totalMatches: total,
            truncated: total > matches.count,
            matches: matches,
            hint: total == 0 ? PDFGrepQuerySemantics.zeroMatchHint(query: query, regex: regex) : nil
        ))
    }

    private static func extractLines(ref: PDFRef, start: Int, end: Int) -> LinesOutcome {
        guard let doc = PDFDocument(url: ref.url) else { return .error("Couldn't open \"\(ref.name)\".") }
        let index = buildLineIndex(doc, url: ref.url)
        guard !index.isEmpty else {
            return .error("\"\(ref.name)\" has no extractable text layer. Use action \"read\" with ocr:true, or noema.rag.search.")
        }
        let lineCount = index.count
        let lo = max(1, min(start, end))
        let hiRequested = min(lineCount, max(start, end))
        guard lo <= lineCount else {
            return .error("Line \(lo) is past the end — \"\(ref.name)\" has \(lineCount) lines.")
        }
        let hi = min(hiRequested, lo + maxLinesPerExtract - 1)
        let slice = index.filter { $0.line >= lo && $0.line <= hi }
        let out = slice.map { LineText(line: $0.line, page: $0.page, text: clip($0.text)) }
        return .ok(LinesResult(
            document: ref.name,
            pageCount: doc.pageCount,
            lineCount: lineCount,
            start: lo,
            end: hi,
            truncated: hi < hiRequested,
            lines: out
        ))
    }

    private static func clip(_ text: String) -> String {
        text.count > maxCharsPerLine ? String(text.prefix(maxCharsPerLine)) + "…" : text
    }

    private static func readPages(ref: PDFRef, spec: String, enableOCR: Bool) -> ReadOutcome {
        guard let doc = PDFDocument(url: ref.url) else { return .error("Couldn't open \"\(ref.name)\".") }
        let pageCount = doc.pageCount
        let nums = parsePages(spec, pageCount: pageCount)
        guard !nums.isEmpty else {
            return .error("No valid pages in \"\(spec)\". The document has \(pageCount) page\(pageCount == 1 ? "" : "s").")
        }
        var out: [PageText] = []
        for n in nums {
            guard let page = doc.page(at: n - 1) else { continue }
            var text = PDFTextExtractor.text(
                from: page,
                documentURL: ref.url,
                pageNumber: n,
                ocrEmptyPage: enableOCR
            )
            // No text layer → optionally OCR the page (on-device Vision), else hint.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if text.isEmpty {
                    text = enableOCR
                        ? "(no text found, even with OCR — the page may be blank or non-text)"
                        : "(no extractable text on this page — it may be a scanned image; call read again with ocr:true to OCR it)"
                }
            }
            if text.count > maxCharsPerPage { text = String(text.prefix(maxCharsPerPage)) + "…" }
            out.append(PageText(page: n, text: text))
        }
        return .ok(ReadResult(document: ref.name, pageCount: pageCount, pages: out))
    }

    private static func parsePages(_ spec: String, pageCount: Int) -> [Int] {
        var pages = Set<Int>()
        for part in spec.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.contains("-") {
                let bounds = token.split(separator: "-", maxSplits: 1).map {
                    Int($0.trimmingCharacters(in: .whitespaces))
                }
                if bounds.count == 2, let lo = bounds[0], let hi = bounds[1] {
                    for n in min(lo, hi)...max(lo, hi) { pages.insert(n) }
                }
            } else if let n = Int(token) {
                pages.insert(n)
            }
        }
        return Array(pages.filter { $0 >= 1 && $0 <= pageCount }.sorted().prefix(maxPagesPerCall))
    }
    #endif
}
