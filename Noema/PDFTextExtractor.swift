import Foundation

#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(PDFKit)
enum PDFTextExtractor {
    private struct CacheKey: Hashable {
        let path: String
        let fileSize: Int
        let modifiedAt: TimeInterval
        let pageNumber: Int
        let ocrEmptyPage: Bool
    }

    private final class PageCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CacheKey: String] = [:]
        private var insertionOrder: [CacheKey] = []
        private let limit = 256

        func value(for key: CacheKey) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func insert(_ value: String, for key: CacheKey) {
            lock.lock()
            defer { lock.unlock() }
            if values[key] == nil {
                insertionOrder.append(key)
            }
            values[key] = value
            while insertionOrder.count > limit {
                let evicted = insertionOrder.removeFirst()
                values.removeValue(forKey: evicted)
            }
        }
    }

    private struct OCRLine {
        let text: String
        let boundingBox: CGRect
    }

    private struct LineStats {
        let letterCount: Int
        let whitespaceCount: Int
        let longestLetterRun: Int

        var whitespaceToLetterRatio: Double {
            Double(whitespaceCount) / Double(max(letterCount, 1))
        }
    }

    private struct CompactText {
        let characters: [Character]
        var whitespaceBefore: [String]
        let trailingWhitespace: String

        var boundaries: Set<Int> {
            Set(whitespaceBefore.indices.filter { !whitespaceBefore[$0].isEmpty })
        }

        func rebuilt() -> String {
            var result = ""
            result.reserveCapacity(
                characters.reduce(trailingWhitespace.count) { $0 + String($1).count } +
                    whitespaceBefore.reduce(0) { $0 + $1.count }
            )
            for index in characters.indices {
                result += whitespaceBefore[index]
                result.append(characters[index])
            }
            result += trailingWhitespace
            return result
        }
    }

    private static let pageCache = PageCache()
    private static let letters = CharacterSet.letters
    private static let alphanumerics = CharacterSet.alphanumerics
    private static let whitespace = CharacterSet.whitespacesAndNewlines
    private static let closingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}%〉》」』】）］｝")
    private static let openingPunctuation = CharacterSet(charactersIn: "([{<〈《「『【（［｛")

    /// Extract one page while preserving the native text layer's characters.
    /// OCR is always allowed to repair malformed spacing. `ocrEmptyPage` controls
    /// only image-only pages, so grep does not unexpectedly OCR an entire scan.
    static func text(
        from page: PDFPage,
        documentURL: URL?,
        pageNumber: Int,
        ocrEmptyPage: Bool
    ) -> String {
        let native = page.string ?? ""
        let trimmed = native.trimmingCharacters(in: .whitespacesAndNewlines)
        // The flag changes output only for an empty native page. Non-empty pages
        // share one cache entry across info/grep/lines/read calls.
        let effectiveEmptyPageOCR = trimmed.isEmpty && ocrEmptyPage
        let cacheKey = documentURL.flatMap {
            makeCacheKey(url: $0, pageNumber: pageNumber, ocrEmptyPage: effectiveEmptyPageOCR)
        }
        if let cacheKey, let cached = pageCache.value(for: cacheKey) {
            return cached
        }

        let result: String
        if trimmed.isEmpty {
            result = ocrEmptyPage ? ocrText(from: page) : native
        } else if needsLayoutRepair(native),
                  let lines = recognizeLines(from: page, dpi: 120),
                  !lines.isEmpty {
            result = repairWhitespace(in: native, using: lines.map(\.text))
        } else {
            result = native
        }

        if let cacheKey {
            pageCache.insert(result, for: cacheKey)
        }
        return result
    }

    /// OCR-only extraction retained for scanned pages and explicit `ocr:true`
    /// reads. Text-layer pages should normally go through `text(...)` above.
    static func ocrText(from page: PDFPage) -> String {
        guard let lines = recognizeLines(from: page, dpi: 200), !lines.isEmpty else {
            return ""
        }
        return linesInReadingOrder(lines).map(\.text).joined(separator: "\n")
    }

    /// Opens and extracts a complete PDF on the calling executor. Dataset code
    /// invokes this from a detached utility task so Vision and PDF rendering do
    /// not block the retrieval actor.
    static func documentText(
        from url: URL,
        ocrEmptyPages: Bool,
        onPageProgress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(document.pageCount)
        for pageIndex in 0..<document.pageCount {
            if Task.isCancelled { throw CancellationError() }
            if let page = document.page(at: pageIndex) {
                let pageText = text(
                    from: page,
                    documentURL: url,
                    pageNumber: pageIndex + 1,
                    ocrEmptyPage: ocrEmptyPages
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !pageText.isEmpty { parts.append(pageText) }
            }
            onPageProgress(pageIndex + 1, document.pageCount)
        }
        return parts.joined(separator: "\n")
    }

    /// Conservative quality gate: normal prose has frequent whitespace. A page
    /// with several long alphabetic runs and unusually few spaces is characteristic
    /// of PDFKit treating positioned word gaps as kerning instead of word breaks.
    static func needsLayoutRepair(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var suspiciousLines = 0
        for line in lines where line.count >= 40 {
            let stats = lineStats(line)
            guard stats.letterCount >= 30 else { continue }
            if stats.longestLetterRun >= 18,
               stats.whitespaceToLetterRatio < 0.16 {
                suspiciousLines += 1
            }
            if stats.longestLetterRun >= 36,
               stats.whitespaceToLetterRatio < 0.18 {
                return true
            }
        }
        return suspiciousLines >= 2
    }

    /// Add only whitespace learned from OCR. Every non-whitespace character in
    /// the result comes from the native PDFKit string, so math, names, punctuation,
    /// and Unicode are not replaced by OCR guesses.
    static func repairWhitespace(in nativeText: String, using ocrLines: [String]) -> String {
        let nativeLines = nativeText.components(separatedBy: .newlines)
        let candidates = ocrLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nativeText }

        var usedCandidates = Set<Int>()
        var repairedLines: [String] = []
        repairedLines.reserveCapacity(nativeLines.count)

        for nativeLine in nativeLines {
            let nativeSignature = signature(nativeLine)
            guard nativeSignature.count >= 12 else {
                repairedLines.append(nativeLine)
                continue
            }

            var bestIndex: Int?
            var bestScore = 0.0
            for (index, candidate) in candidates.enumerated() where !usedCandidates.contains(index) {
                let candidateSignature = signature(candidate)
                guard candidateSignature.count >= 12 else { continue }
                let lengthRatio = Double(min(nativeSignature.count, candidateSignature.count)) /
                    Double(max(nativeSignature.count, candidateSignature.count))
                guard lengthRatio >= 0.62 else { continue }
                let score = 0.8 * ngramDice(nativeSignature, candidateSignature) + 0.2 * lengthRatio
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }

            guard bestScore >= 0.58,
                  let bestIndex,
                  let repaired = transferWhitespace(from: candidates[bestIndex], to: nativeLine),
                  whitespaceCount(in: repaired) > whitespaceCount(in: nativeLine) else {
                repairedLines.append(nativeLine)
                continue
            }
            usedCandidates.insert(bestIndex)
            repairedLines.append(repaired)
        }
        return repairedLines.joined(separator: "\n")
    }

    /// Literal grep first, then a whitespace-insensitive fallback. The fallback
    /// lets "Subset drift" find "Subsetdrift" if a third-party PDF still defeats
    /// layout repair, without changing regex semantics.
    static func containsPlainText(_ query: String, in text: String, ignoreCase: Bool) -> Bool {
        let options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
        if text.range(of: query, options: options) != nil {
            return true
        }
        guard query.unicodeScalars.contains(where: { whitespace.contains($0) }) else {
            return false
        }
        let collapsedQuery = removingWhitespace(from: query)
        guard !collapsedQuery.isEmpty else { return false }
        return removingWhitespace(from: text).range(of: collapsedQuery, options: options) != nil
    }

    private static func makeCacheKey(url: URL, pageNumber: Int, ocrEmptyPage: Bool) -> CacheKey? {
        let standardized = url.standardizedFileURL
        guard let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return CacheKey(
            path: standardized.path,
            fileSize: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0,
            pageNumber: pageNumber,
            ocrEmptyPage: ocrEmptyPage
        )
    }

    private static func lineStats(_ text: String) -> LineStats {
        var letterCount = 0
        var whitespaceCount = 0
        var currentRun = 0
        var longestRun = 0
        for scalar in text.unicodeScalars {
            if letters.contains(scalar) {
                letterCount += 1
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                if whitespace.contains(scalar) { whitespaceCount += 1 }
                currentRun = 0
            }
        }
        return LineStats(
            letterCount: letterCount,
            whitespaceCount: whitespaceCount,
            longestLetterRun: longestRun
        )
    }

    private static func whitespaceCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if whitespace.contains(scalar) { count += 1 }
        }
    }

    private static func removingWhitespace(from text: String) -> String {
        String(text.unicodeScalars.filter { !whitespace.contains($0) })
    }

    private static func signature(_ text: String) -> [Character] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded.unicodeScalars.compactMap { scalar in
            guard alphanumerics.contains(scalar) else { return nil }
            return Character(String(scalar).lowercased())
        }
    }

    private static func ngramDice(_ lhs: [Character], _ rhs: [Character]) -> Double {
        let size = min(lhs.count, rhs.count) >= 3 ? 3 : 1
        func grams(_ chars: [Character]) -> Set<String> {
            guard chars.count >= size else { return [String(chars)] }
            var result = Set<String>()
            for start in 0...(chars.count - size) {
                result.insert(String(chars[start..<(start + size)]))
            }
            return result
        }
        let left = grams(lhs)
        let right = grams(rhs)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        return 2 * Double(left.intersection(right).count) / Double(left.count + right.count)
    }

    private static func transferWhitespace(from oracle: String, to native: String) -> String? {
        var nativeParts = compactText(native)
        let oracleParts = compactText(oracle)
        let nativeChars = nativeParts.characters
        let oracleChars = oracleParts.characters
        // The alignment below is quadratic. PDF lines are normally far shorter;
        // keep a malformed text layer from allocating an unbounded matrix.
        guard !nativeChars.isEmpty, !oracleChars.isEmpty,
              nativeChars.count <= 800, oracleChars.count <= 800 else { return nil }

        let alignment = align(native: nativeChars, oracle: oracleChars)
        guard alignment.similarity >= 0.72 else { return nil }

        for oracleBoundary in oracleParts.boundaries {
            guard oracleBoundary > 0, oracleBoundary < oracleChars.count,
                  let nativeLeft = nearestMappedNativeIndex(
                    in: alignment.oracleToNative,
                    from: oracleBoundary - 1,
                    direction: -1
                  ),
                  let nativeRight = nearestMappedNativeIndex(
                    in: alignment.oracleToNative,
                    from: oracleBoundary,
                    direction: 1
                  ),
                  nativeRight > nativeLeft,
                  nativeRight - nativeLeft <= 3,
                  shouldInsertBoundary(between: nativeChars[nativeLeft], and: nativeChars[nativeRight]) else {
                continue
            }
            if nativeParts.whitespaceBefore[nativeRight].isEmpty {
                nativeParts.whitespaceBefore[nativeRight] = " "
            }
        }

        return nativeParts.rebuilt()
    }

    private static func compactText(_ text: String) -> CompactText {
        var characters: [Character] = []
        var whitespaceBefore: [String] = []
        var pendingWhitespace = ""
        for character in text {
            if character.unicodeScalars.allSatisfy({ whitespace.contains($0) }) {
                pendingWhitespace.append(character)
                continue
            }
            whitespaceBefore.append(pendingWhitespace)
            characters.append(character)
            pendingWhitespace = ""
        }
        return CompactText(
            characters: characters,
            whitespaceBefore: whitespaceBefore,
            trailingWhitespace: pendingWhitespace
        )
    }

    private static func align(
        native: [Character],
        oracle: [Character]
    ) -> (oracleToNative: [Int?], similarity: Double) {
        let n = native.count
        let m = oracle.count
        var costs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { costs[i][0] = i }
        for j in 0...m { costs[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                let substitution = costs[i - 1][j - 1] + (charactersEquivalent(native[i - 1], oracle[j - 1]) ? 0 : 1)
                costs[i][j] = min(substitution, costs[i - 1][j] + 1, costs[i][j - 1] + 1)
            }
        }

        var mapping = Array<Int?>(repeating: nil, count: m)
        var i = n
        var j = m
        var equivalentCount = 0
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let equivalent = charactersEquivalent(native[i - 1], oracle[j - 1])
                let diagonal = costs[i - 1][j - 1] + (equivalent ? 0 : 1)
                if costs[i][j] == diagonal {
                    mapping[j - 1] = i - 1
                    if equivalent { equivalentCount += 1 }
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, costs[i][j] == costs[i - 1][j] + 1 {
                i -= 1
            } else if j > 0 {
                j -= 1
            }
        }
        let similarity = Double(equivalentCount) / Double(max(n, m))
        return (mapping, similarity)
    }

    private static func charactersEquivalent(_ lhs: Character, _ rhs: Character) -> Bool {
        canonicalCharacter(lhs) == canonicalCharacter(rhs)
    }

    private static func canonicalCharacter(_ character: Character) -> String {
        let raw = String(character)
        switch raw {
        case "–", "—", "−", "‐", "‑": return "-"
        case "‘", "’", "`", "´": return "'"
        case "“", "”": return "\""
        case "∼", "≈", "〜": return "~"
        default:
            return raw.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).lowercased()
        }
    }

    private static func nearestMappedNativeIndex(
        in mapping: [Int?],
        from start: Int,
        direction: Int
    ) -> Int? {
        var index = start
        while mapping.indices.contains(index) {
            if let mapped = mapping[index] { return mapped }
            index += direction
        }
        return nil
    }

    private static func shouldInsertBoundary(between lhs: Character, and rhs: Character) -> Bool {
        if rhs.unicodeScalars.allSatisfy({ closingPunctuation.contains($0) }) { return false }
        if lhs.unicodeScalars.allSatisfy({ openingPunctuation.contains($0) }) { return false }
        return true
    }

    #if canImport(Vision) && canImport(CoreGraphics)
    private static func recognizeLines(
        from page: PDFPage,
        dpi: CGFloat
    ) -> [OCRLine]? {
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 1, pageRect.height > 1 else { return nil }
        let requestedScale = dpi / 72.0
        let maxPixels: CGFloat = 8_000_000
        let requestedPixels = pageRect.width * pageRect.height * requestedScale * requestedScale
        let scale = requestedPixels > maxPixels
            ? requestedScale * (maxPixels / requestedPixels).squareRoot()
            : requestedScale
        let width = Int((pageRect.width * scale).rounded())
        let height = Int((pageRect.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        return autoreleasepool {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -pageRect.minX, y: -pageRect.minY)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { return nil }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                return nil
            }
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return OCRLine(text: text, boundingBox: observation.boundingBox)
            }
        }
    }
    #else
    private static func recognizeLines(from page: PDFPage, dpi: CGFloat) -> [OCRLine]? {
        nil
    }
    #endif

    private static func linesInReadingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let total = max(lines.count, 1)
        let spanningCount = lines.filter { $0.boundingBox.width > 0.55 }.count
        let leftCount = lines.filter {
            $0.boundingBox.midX < 0.46 && $0.boundingBox.width < 0.55
        }.count
        let rightCount = lines.filter {
            $0.boundingBox.midX > 0.54 && $0.boundingBox.width < 0.55
        }.count
        let isTwoColumn = leftCount * 5 >= total &&
            rightCount * 5 >= total &&
            spanningCount * 8 < total

        if isTwoColumn {
            return lines.sorted { lhs, rhs in
                let lhsColumn = lhs.boundingBox.midX < 0.5 ? 0 : 1
                let rhsColumn = rhs.boundingBox.midX < 0.5 ? 0 : 1
                if lhsColumn != rhsColumn { return lhsColumn < rhsColumn }
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.005 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
        }
        return lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.005 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }
}
#endif
