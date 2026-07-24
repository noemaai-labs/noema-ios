import SwiftUI

// MARK: - Markdown block model

enum ReadmeMarkdown {
    struct Block: Identifiable, Sendable {
        let id: Int
        let kind: Kind
    }

    enum Kind: Sendable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case code(language: String?, text: String)
        case listItem(indent: Int, marker: String, text: AttributedString)
        case quote(AttributedString)
        case table(headers: [AttributedString], rows: [[AttributedString]])
        case image(url: URL, alt: String, maxWidth: CGFloat?)
        case divider
    }

    nonisolated static func parse(_ markdown: String) -> [Block] {
        var text = stripFrontmatter(markdown)
        text = normalizeHTML(text)
        text = isolateStandaloneImages(text)

        var blocks: [Kind] = []
        var paragraphBuffer: [String] = []
        var quoteBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
            paragraphBuffer = []
            let trimmed = joined.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            blocks.append(.paragraph(inline(trimmed)))
        }

        func flushQuote() {
            guard !quoteBuffer.isEmpty else { return }
            let joined = quoteBuffer.joined(separator: " ")
            quoteBuffer = []
            let trimmed = joined.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            blocks.append(.quote(inline(trimmed)))
        }

        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                i += 1
                continue
            }

            if let fence = fenceInfo(trimmed) {
                flushParagraph()
                flushQuote()
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(String(repeating: fence.char, count: fence.length)) { break }
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1
                let code = codeLines.joined(separator: "\n")
                if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.code(language: fence.language, text: code))
                }
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var content = trimmed
                while content.hasPrefix(">") {
                    content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                quoteBuffer.append(content)
                i += 1
                continue
            }
            flushQuote()

            if let heading = headingInfo(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: inline(heading.text)))
                i += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                i += 1
                continue
            }

            if let image = standaloneImage(trimmed) {
                flushParagraph()
                if !isBadgeURL(image.url) {
                    blocks.append(.image(url: image.url, alt: image.alt, maxWidth: image.maxWidth))
                }
                i += 1
                continue
            }

            if let cells = tableCells(trimmed), i + 1 < lines.count,
               isTableDivider(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let headers = cells.map { inline($0) }
                var rows: [[AttributedString]] = []
                i += 2
                while i < lines.count,
                      let rowCells = tableCells(lines[i].trimmingCharacters(in: .whitespaces)) {
                    var padded = rowCells.map { inline($0) }
                    while padded.count < headers.count { padded.append(AttributedString()) }
                    rows.append(Array(padded.prefix(headers.count)))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if let item = listItemInfo(line) {
                flushParagraph()
                blocks.append(.listItem(indent: item.indent, marker: item.marker, text: inline(item.text)))
                i += 1
                continue
            }

            paragraphBuffer.append(trimmed)
            i += 1
        }
        flushParagraph()
        flushQuote()

        return blocks.enumerated().map { Block(id: $0.offset, kind: $0.element) }
    }

    // MARK: Inline

    private nonisolated static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        styleInlineCode(&attributed)
        return attributed
    }

    /// Render Markdown code spans (`` `x` ``, plus HTML `<code>`/`<kbd>`/`<samp>`
    /// converted upstream in `normalizeHTML`) as a monospaced chip in the app's
    /// monochrome design language, rather than the plain body run
    /// `AttributedString` produces by default.
    private nonisolated static func styleInlineCode(_ attributed: inout AttributedString) {
        // Snapshot the code-span ranges before mutating: writing attributes back
        // into `attributed` invalidates a live `runs` iteration.
        var ranges: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                ranges.append(run.range)
            }
        }
        for range in ranges {
            attributed[range].font = .system(size: 13.5, weight: .regular, design: .monospaced)
            attributed[range].backgroundColor = Color.primary.opacity(0.06)
        }
    }

    // MARK: Line classification

    private nonisolated static func fenceInfo(_ line: String) -> (char: Character, length: Int, language: String?)? {
        guard line.hasPrefix("```") || line.hasPrefix("~~~") else { return nil }
        let char = line.first!
        let length = line.prefix(while: { $0 == char }).count
        let language = line.drop(while: { $0 == char }).trimmingCharacters(in: .whitespaces)
        return (char, length, language.isEmpty ? nil : language)
    }

    private nonisolated static func headingInfo(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " || rest.isEmpty else { return nil }
        let text = rest.trimmingCharacters(in: CharacterSet(charactersIn: " #"))
        guard !text.isEmpty else { return nil }
        return (hashes.count, text)
    }

    private nonisolated static func isHorizontalRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    private nonisolated static func standaloneImage(_ line: String) -> (url: URL, alt: String, maxWidth: CGFloat?)? {
        let pattern = #"^!\[([^\]]*)\]\(([^)\s]+)[^)]*\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let urlRange = Range(match.range(at: 2), in: line) else { return nil }
        // The width hint from an <img width>/max-width style rides along as a
        // "#noema-w=N" marker appended by convertImgTags; peel it back off.
        var urlString = String(line[urlRange])
        var maxWidth: CGFloat?
        if let marker = urlString.range(of: "#noema-w=") {
            let digits = urlString[marker.upperBound...].prefix(while: \.isNumber)
            if let n = Int(digits), n > 0 { maxWidth = CGFloat(n) }
            urlString = String(urlString[..<marker.lowerBound])
        }
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
        let alt = Range(match.range(at: 1), in: line).map { String(line[$0]) } ?? ""
        return (url, alt, maxWidth)
    }

    private nonisolated static func isBadgeURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if host.contains("shields.io") || host.contains("badge") { return true }
        return url.path.lowercased().contains("badge")
    }

    private nonisolated static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|"), line != "|" else { return nil }
        var content = line
        if content.hasPrefix("|") { content = String(content.dropFirst()) }
        if content.hasSuffix("|") { content = String(content.dropLast()) }
        let cells = splitTableRow(content)
        guard cells.count >= 2 else { return nil }
        return cells
    }

    /// Split a table row on cell-separating `|`, treating pipes inside an inline
    /// code span (`` `…|…` ``) as literal. Without this, a restored HTML
    /// `<code>` chip containing a pipe would shred the row into extra cells and
    /// drop content. Rows without backticks split exactly as before.
    private nonisolated static func splitTableRow(_ content: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        for ch in content {
            if ch == "`" {
                inCode.toggle()
                current.append(ch)
            } else if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private nonisolated static func isTableDivider(_ line: String) -> Bool {
        guard let cells = tableCells(line) else { return false }
        // GitHub accepts single-dash dividers (|-|-|, |:-:|); requiring three
        // dashes made those tables fall through and render as plain text.
        return cells.allSatisfy { cell in
            cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil
        }
    }

    private nonisolated static func listItemInfo(_ line: String) -> (indent: Int, marker: String, text: String)? {
        let leading = line.prefix(while: { $0 == " " }).count
        let content = line.trimmingCharacters(in: .whitespaces)
        let indent = min(leading / 2, 3)

        for prefix in ["- [ ] ", "* [ ] "] where content.hasPrefix(prefix) {
            return (indent, "☐", String(content.dropFirst(prefix.count)))
        }
        for prefix in ["- [x] ", "- [X] ", "* [x] ", "* [X] "] where content.hasPrefix(prefix) {
            return (indent, "☑", String(content.dropFirst(prefix.count)))
        }
        for prefix in ["- ", "* ", "+ "] where content.hasPrefix(prefix) {
            return (indent, "•", String(content.dropFirst(prefix.count)))
        }
        if let match = content.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            let marker = content[match].trimmingCharacters(in: .whitespaces)
            return (indent, marker, String(content[match.upperBound...]))
        }
        return nil
    }

    // MARK: Preprocessing

    private nonisolated static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        for idx in 1..<lines.count where lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(idx + 1)...].joined(separator: "\n")
        }
        return text
    }

    /// READMEs on the Hub are full of presentational HTML (centered divs, badge
    /// rows, <br> layout). Convert the meaningful parts to markdown and drop the
    /// rest so the native renderer gets clean input.
    private nonisolated static func normalizeHTML(_ text: String) -> String {
        var result = text
        func replace(_ pattern: String, with template: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            result = regex.stringByReplacingMatches(in: result,
                                                    range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: template)
        }

        replace(#"<!--.*?-->"#, with: "")

        // Pull <pre>/<code>/<kbd>/<samp> out before any other tag handling. Their
        // inner text is frequently literal markup (e.g. an inline chip reading
        // "<think>" or "temperature=0.6") that the generic tag strip below would
        // otherwise mangle or drop. Restored as markdown code once the rest of
        // the document is normalized.
        var inlineCode: [String] = []
        var blockCode: [String] = []
        result = protectCodeHTML(result, inline: &inlineCode, block: &blockCode)

        // Hub model cards (e.g. Qwen benchmark tables) publish tables as raw HTML.
        // Convert them to markdown pipes BEFORE the generic tag strip below, which
        // would otherwise flatten them to one cell per line.
        result = htmlTablesToMarkdown(result)
        replace(#"<br\s*/?>"#, with: "\n")
        replace(#"<hr\s*/?>"#, with: "\n---\n")
        // Convert <img> to markdown, preserving any width hint so badge/button
        // images (e.g. the Unsloth logo/Discord/Docs header) render at their
        // intended small size instead of being upscaled to full width. Runs
        // before the <a> conversion so a wrapping link still forms a linked
        // image that isolateStandaloneImages can unwrap.
        result = convertImgTags(result)
        replace(#"<h[1-6][^>]*>(.*?)</h[1-6]>"#, with: "\n# $1\n")
        replace(#"<a[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, with: "[$2]($1)")
        replace(#"</?(b|strong)>"#, with: "**")
        replace(#"</?(i|em)>"#, with: "*")
        replace(#"</(td|th)>"#, with: " ")
        replace(#"</tr>"#, with: "\n")
        replace(#"<li[^>]*>"#, with: "\n- ")
        replace(#"<(p|div|details|summary|center|table|thead|tbody|tr|td|th|span|sub|sup|ul|ol|blockquote|video|source|figure|figcaption|font|picture)[^>]*>"#, with: "\n")
        replace(#"</(p|div|details|summary|center|table|thead|tbody|span|sub|sup|ul|ol|li|blockquote|video|figure|figcaption|font|picture)>"#, with: "\n")
        // Any code-ish tags still here are unbalanced (well-formed pairs were
        // pulled out by protectCodeHTML); drop the stray opener/closer so a
        // malformed `<code>` doesn't leak into rendered text.
        replace(#"</?(?:code|pre|kbd|samp|tt)[^>]*>"#, with: "")

        result = decodeEntities(result)

        result = restoreCodeHTML(result, inline: inlineCode, block: blockCode)
        return result
    }

    private nonisolated static func decodeEntities(_ text: String) -> String {
        // `&amp;` must be resolved last so it can't re-form another entity.
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let inlineCodeToken = "\u{FFFC}NOEMAINLINECODE"
    private static let blockCodeToken = "\u{FFFC}NOEMABLOCKCODE"

    /// Swap `<pre>`/`<code>`/`<kbd>`/`<samp>` regions for opaque placeholder
    /// tokens (no angle brackets, so later passes leave them alone). The captured
    /// text is entity-decoded and stashed for `restoreCodeHTML` to re-emit as
    /// Markdown code — fenced blocks for `<pre>`, backtick spans for the rest.
    private nonisolated static func protectCodeHTML(_ text: String,
                                                    inline: inout [String],
                                                    block: inout [String]) -> String {
        var result = text

        // Block code first so a <pre><code> pair collapses into one fenced block
        // rather than a fenced block wrapping a stray inline span.
        if let preRegex = try? NSRegularExpression(pattern: #"<pre[^>]*>(.*?)</pre>"#,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            var blocks = block
            while let match = preRegex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
                  let whole = Range(match.range, in: result),
                  let inner = Range(match.range(at: 1), in: result) {
                var body = String(result[inner])
                body = body.replacingOccurrences(of: #"^\s*<code[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
                body = body.replacingOccurrences(of: #"</code>\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                body = decodeEntities(body).trimmingCharacters(in: .newlines)
                let token = "\(blockCodeToken)\(blocks.count)\u{FFFC}"
                blocks.append(body)
                result.replaceSubrange(whole, with: "\n\n\(token)\n\n")
            }
            block = blocks
        }

        // Inline code / keyboard / sample spans.
        if let codeRegex = try? NSRegularExpression(pattern: #"<(?:code|kbd|samp|tt)[^>]*>(.*?)</(?:code|kbd|samp|tt)>"#,
                                                    options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            var spans = inline
            while let match = codeRegex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
                  let whole = Range(match.range, in: result),
                  let inner = Range(match.range(at: 1), in: result) {
                var body = String(result[inner])
                // Drop any residual markup and flatten to a single line.
                body = body.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                body = decodeEntities(body)
                body = body.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let token = "\(inlineCodeToken)\(spans.count)\u{FFFC}"
                spans.append(body)
                result.replaceSubrange(whole, with: token)
            }
            inline = spans
        }

        return result
    }

    private nonisolated static func restoreCodeHTML(_ text: String,
                                                    inline: [String],
                                                    block: [String]) -> String {
        var result = text
        for (idx, body) in block.enumerated() {
            let token = "\(blockCodeToken)\(idx)\u{FFFC}"
            result = result.replacingOccurrences(of: token, with: "\n\n```\n\(body)\n```\n\n")
        }
        for (idx, body) in inline.enumerated() {
            let token = "\(inlineCodeToken)\(idx)\u{FFFC}"
            // An empty <code></code> has nothing to render; dropping it avoids
            // leaving a bare "``" that shows as literal backticks.
            let replacement = body.isEmpty ? "" : backtickSpan(body)
            result = result.replacingOccurrences(of: token, with: replacement)
        }
        return result
    }

    /// Wrap `body` in the shortest backtick run that doesn't collide with its
    /// contents (CommonMark inline-code fencing).
    private nonisolated static func backtickSpan(_ body: String) -> String {
        guard body.contains("`") else { return "`\(body)`" }
        var longest = 0
        var current = 0
        for ch in body {
            if ch == "`" { current += 1; longest = max(longest, current) } else { current = 0 }
        }
        let fence = String(repeating: "`", count: longest + 1)
        return "\(fence) \(body) \(fence)"
    }

    private nonisolated static func htmlTablesToMarkdown(_ text: String) -> String {
        guard text.range(of: "<table", options: .caseInsensitive) != nil,
              let tableRegex = try? NSRegularExpression(
                  pattern: #"<table[^>]*>.*?</table>"#,
                  options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let rowRegex = try? NSRegularExpression(
                  pattern: #"<tr[^>]*>(.*?)</tr>"#,
                  options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let cellRegex = try? NSRegularExpression(
                  pattern: #"<t([hd])([^>]*)>(.*?)</t[hd]\s*>"#,
                  options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return text }

        var result = text
        let matches = tableRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let tableRange = Range(match.range, in: result) else { continue }
            let tableHTML = String(result[tableRange])

            var rows: [[String]] = []
            for rowMatch in rowRegex.matches(in: tableHTML, range: NSRange(tableHTML.startIndex..., in: tableHTML)) {
                guard let rowRange = Range(rowMatch.range(at: 1), in: tableHTML) else { continue }
                let rowHTML = String(tableHTML[rowRange])
                var cells: [String] = []
                for cellMatch in cellRegex.matches(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML)) {
                    let attrs = Range(cellMatch.range(at: 2), in: rowHTML).map { String(rowHTML[$0]) } ?? ""
                    let content = Range(cellMatch.range(at: 3), in: rowHTML).map { String(rowHTML[$0]) } ?? ""
                    cells.append(inlineTextFromCellHTML(content))
                    // colspan cells (e.g. section-header rows in benchmark tables)
                    // pad with empties so columns stay aligned.
                    if let spanRange = attrs.range(of: #"colspan\s*=\s*["']?(\d+)"#, options: [.regularExpression, .caseInsensitive]),
                       let span = Int(attrs[spanRange].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()),
                       span > 1 {
                        cells.append(contentsOf: Array(repeating: "", count: span - 1))
                    }
                }
                if !cells.isEmpty { rows.append(cells) }
            }

            let columnCount = rows.map(\.count).max() ?? 0
            guard rows.count >= 2, columnCount >= 2 else { continue }

            let padded = rows.map { row in
                row + Array(repeating: "", count: columnCount - row.count)
            }
            var lines: [String] = []
            lines.append("| " + padded[0].joined(separator: " | ") + " |")
            lines.append("| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |")
            for row in padded.dropFirst() {
                lines.append("| " + row.joined(separator: " | ") + " |")
            }
            result.replaceSubrange(tableRange, with: "\n\n" + lines.joined(separator: "\n") + "\n\n")
        }
        return result
    }

    /// Reduce a table cell's inner HTML to single-line markdown text safe for a
    /// pipe table: keep bold/italic/links, drop other tags, escape pipes.
    private nonisolated static func inlineTextFromCellHTML(_ html: String) -> String {
        var cell = html
        func replace(_ pattern: String, with template: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return }
            cell = regex.stringByReplacingMatches(in: cell,
                                                  range: NSRange(cell.startIndex..., in: cell),
                                                  withTemplate: template)
        }
        replace(#"<br\s*/?>"#, with: " ")
        replace(#"</?(b|strong)>"#, with: "**")
        replace(#"</?(i|em)>"#, with: "*")
        replace(#"<a[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, with: "[$2]($1)")
        replace(#"<[^>]+>"#, with: "")
        return cell
            // The pipe-table splitter is naive (no \| escaping), so substitute a
            // lookalike that can't be mistaken for a column separator.
            .replacingOccurrences(of: "|", with: "¦")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Convert every `<img>` to a markdown image, carrying a width hint through
    /// as a `#noema-w=N` URL marker when the tag (or a `max-width`/`width` style,
    /// which ReadmeMobileFormatter leaves behind) specifies one.
    private nonisolated static func convertImgTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let tag = String(result[range])
            guard let src = tagAttribute("src", in: tag) else {
                result.replaceSubrange(range, with: "")
                continue
            }
            let replacement: String
            if let width = imgWidthHint(tag) {
                replacement = "![](\(src)#noema-w=\(width))"
            } else {
                replacement = "![](\(src))"
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private nonisolated static func tagAttribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
    }

    private nonisolated static func imgWidthHint(_ tag: String) -> Int? {
        // Prefer a CSS width from the style attribute (ReadmeMobileFormatter
        // rewrites `<img width=N>` inside flex rows to `max-width: Npx`).
        if let style = tagAttribute("style", in: tag) {
            for key in ["max-width", "width"] {
                if let r = style.range(of: "\(key)\\s*:\\s*(\\d+)\\s*px", options: [.regularExpression, .caseInsensitive]) {
                    if let n = Int(style[r].filter(\.isNumber)), n > 0 { return n }
                }
            }
        }
        // Otherwise the raw HTML width attribute (avoid matching "max-width").
        if let r = tag.range(of: #"(?<![-\w])width\s*=\s*["']?(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            if let n = Int(tag[r].filter(\.isNumber)), n > 0 { return n }
        }
        return nil
    }

    private nonisolated static func isolateStandaloneImages(_ text: String) -> String {
        var result = text
        // Unwrap linked images (badge/link pattern, possibly spread over
        // several lines) down to the bare image.
        if let regex = try? NSRegularExpression(pattern: #"\[\s*(!\[[^\]]*\]\([^)]+\))\s*\]\([^)]+\)"#) {
            result = regex.stringByReplacingMatches(in: result,
                                                    range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: "$1")
        }
        if let regex = try? NSRegularExpression(pattern: #"(!\[[^\]]*\]\([^)]+\))"#) {
            result = regex.stringByReplacingMatches(in: result,
                                                    range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: "\n$1\n")
        }
        return result
    }
}

// MARK: - Block renderer

struct ReadmeMarkdownView: View {
    let blocks: [ReadmeMarkdown.Block]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                blockView(block.kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ kind: ReadmeMarkdown.Kind) -> some View {
        switch kind {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .foregroundStyle(AppTheme.text)
                .padding(.top, level <= 2 ? 8 : 4)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(text)
                .font(FontTheme.body)
                .foregroundStyle(AppTheme.text)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let language, let code):
            codeBlock(language: language, code: code)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(FontTheme.body)
                    .foregroundStyle(AppTheme.secondaryText)
                Text(text)
                    .font(FontTheme.body)
                    .foregroundStyle(AppTheme.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppTheme.secondaryText.opacity(0.35))
                    .frame(width: 3)
                Text(text)
                    .font(FontTheme.body.italic())
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let headers, let rows):
            tableBlock(headers: headers, rows: rows)
        case .image(let url, let alt, let maxWidth):
            readmeImage(url: url, alt: alt, maxWidth: maxWidth)
        case .divider:
            Rectangle()
                .fill(AppTheme.cardStroke)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return FontTheme.heading(size: 22)
        case 2: return FontTheme.heading(size: 19)
        case 3: return FontTheme.heading(size: 17)
        default: return FontTheme.heading(size: 15)
        }
    }

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .medium))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(AppTheme.text)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.cardStroke, lineWidth: 1)
        )
    }

    private func tableBlock(headers: [AttributedString], rows: [[AttributedString]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        tableCell(header, isHeader: true)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    Rectangle()
                        .fill(AppTheme.cardStroke.opacity(rowIndex == 0 ? 1 : 0.6))
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            tableCell(cell, isHeader: false)
                        }
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.cardStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func tableCell(_ text: AttributedString, isHeader: Bool) -> some View {
        Text(text)
            .font(isHeader ? FontTheme.caption.weight(.semibold) : .system(size: 13))
            .foregroundStyle(isHeader ? AppTheme.secondaryText : AppTheme.text)
            .lineLimit(6)
            .frame(minWidth: 44, maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func readmeImage(url: URL, alt: String, maxWidth: CGFloat?) -> some View {
        // A width hint caps the image so small badges/buttons/logos keep their
        // intended size (never upscaled past the hint); the surrounding card
        // still scales it down if the hint is wider than the column. Hint-less
        // images (screenshots, benchmark charts) keep the full-width fit.
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: 280, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            case .failure:
                EmptyView()
            default:
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.04))
                    .frame(maxWidth: maxWidth, minHeight: 44, maxHeight: 120, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(alt.isEmpty ? String(localized: "Model card image") : alt)
    }
}

// MARK: - Collapsible section

struct ModelCardSection: View {
    let repoID: String

    @StateObject private var loader: ModelReadmeLoader
    @State private var blocks: [ReadmeMarkdown.Block] = []
    @State private var hasParsed = false
    @State private var expanded = false

    private let collapsedHeight: CGFloat = 200
    private let collapsedBlockLimit = 12

    init(repoID: String, token: String?) {
        self.repoID = repoID
        _loader = StateObject(wrappedValue: ModelReadmeLoader(repo: repoID,
                                                              token: token,
                                                              preserveTables: true,
                                                              preferManualSummary: false))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Rectangle()
                .fill(AppTheme.cardStroke)
                .frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loader.load() }
        .onDisappear { loader.cancel() }
        .task(id: loader.markdown) {
            guard let markdown = loader.markdown else { return }
            let parsed = await Task.detached(priority: .userInitiated) {
                ReadmeMarkdown.parse(markdown)
            }.value
            blocks = parsed
            hasParsed = true
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey("Model Card"))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .tracking(0.3)
                .foregroundStyle(AppTheme.secondaryText)
            Spacer(minLength: 16)
            if collapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? LocalizedStringKey("Show less") : LocalizedStringKey("Show more"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard collapsible else { return }
            withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !blocks.isEmpty {
            if expanded || !collapsible {
                ReadmeMarkdownView(blocks: blocks)
                expandedFooter
            } else {
                collapsedPreview
            }
        } else if loader.isLoading || (loader.markdown != nil && !hasParsed) {
            loadingPlaceholder
        } else {
            unavailableRow
        }
    }

    private var collapsible: Bool {
        blocks.count > 3 || (loader.markdown?.count ?? 0) > 800
    }

    private var collapsedPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReadmeMarkdownView(blocks: Array(blocks.prefix(collapsedBlockLimit)))
                .frame(maxHeight: collapsedHeight, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [Color.detailSheetBackground.opacity(0), Color.detailSheetBackground],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 72)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) { expanded = true }
                }
                .accessibilityHidden(true)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) { expanded = true }
            } label: {
                HStack(spacing: 5) {
                    Text(LocalizedStringKey("Show more"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(FontTheme.caption.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private var expandedFooter: some View {
        HStack {
            if collapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { expanded = false }
                } label: {
                    HStack(spacing: 5) {
                        Text(LocalizedStringKey("Show less"))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(FontTheme.caption.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if let url = hubURL {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text(LocalizedStringKey("View on Hugging Face"))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(FontTheme.caption.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
        .padding(.top, 4)
    }

    private var hubURL: URL? {
        URL(string: "\(HFEndpoint.webBaseString)/\(repoID)")
    }

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([1.0, 0.85, 0.6], id: \.self) { fraction in
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: proxy.size.width * fraction)
                }
                .frame(height: 12)
            }
        }
        .accessibilityHidden(true)
    }

    private var unavailableRow: some View {
        HStack {
            Text(LocalizedStringKey("Model card unavailable"))
                .font(FontTheme.caption)
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
            Button(LocalizedStringKey("Retry")) {
                loader.load(force: true)
            }
            .font(FontTheme.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }
}
