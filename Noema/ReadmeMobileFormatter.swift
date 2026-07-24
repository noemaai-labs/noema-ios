import Foundation

final class ReadmeMobileFormatter {
    
    private static let codeBlockPlaceholder = "__CODE_BLOCK_"

    static func transform(_ content: String, keepTables: Bool = false) -> String {
        let (frontmatter, body) = splitFrontmatter(content)
        let (bodyNoCode, codeBlocks) = extractFencedCodeBlocks(body)
        let bodyWithResponsiveHTML = transformResponsiveHTML(bodyNoCode)
        let bodyWithTables = keepTables ? bodyWithResponsiveHTML : transformMarkdownTables(bodyWithResponsiveHTML)
        let transformedBody = restoreCodeBlocks(bodyWithTables, codeBlocks: codeBlocks)
        return frontmatter + transformedBody
    }
    
    // MARK: - Frontmatter Handling
    
    private static func splitFrontmatter(_ text: String) -> (String, String) {
        guard text.hasPrefix("---") else { return ("", text) }
        
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty && lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
            return ("", text)
        }
        
        for idx in 1..<lines.count {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                let frontmatter = lines[0...idx].joined(separator: "\n") + "\n"
                let rest = lines[(idx + 1)...].joined(separator: "\n")
                return (frontmatter, rest)
            }
        }
        
        return ("", text)
    }
    
    // MARK: - Code Block Handling
    
    private static func extractFencedCodeBlocks(_ text: String) -> (String, [String]) {
        var outputParts: [String] = []
        var codeBlocks: [String] = []
        
        let lines = text.components(separatedBy: .newlines)
        var inCode = false
        var fenceChar = ""
        var fenceLen = 0
        var currentBlock: [String] = []
        
        func isFence(_ line: String) -> (Bool, String, Int) {
            let pattern = #"^(\s*)(`{3,}|~{3,})(.*)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  match.numberOfRanges > 2 else {
                return (false, "", 0)
            }
            
            let fenceRange = match.range(at: 2)
            guard let range = Range(fenceRange, in: line) else { return (false, "", 0) }
            let fence = String(line[range])
            guard let first = fence.first else { return (false, "", 0) }
            return (true, String(first), fence.count)
        }
        
        for line in lines {
            if !inCode {
                let (isStart, ch, ln) = isFence(line)
                if isStart {
                    inCode = true
                    fenceChar = ch
                    fenceLen = ln
                    currentBlock = [line]
                } else {
                    outputParts.append(line)
                }
            } else {
                currentBlock.append(line)
                let pattern = #"^\s*"# + NSRegularExpression.escapedPattern(for: fenceChar) + #"{"# + String(fenceLen) + #",}\s*.*$"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    let blockText = currentBlock.joined(separator: "\n")
                    let placeholder = "\(codeBlockPlaceholder)\(codeBlocks.count)__"
                    codeBlocks.append(blockText)
                    outputParts.append(placeholder)
                    inCode = false
                    fenceChar = ""
                    fenceLen = 0
                    currentBlock = []
                }
            }
        }
        
        if !currentBlock.isEmpty {
            outputParts.append(contentsOf: currentBlock)
        }
        
        return (outputParts.joined(separator: "\n"), codeBlocks)
    }
    
    private static func restoreCodeBlocks(_ text: String, codeBlocks: [String]) -> String {
        var result = text
        for (idx, block) in codeBlocks.enumerated() {
            let placeholder = "\(codeBlockPlaceholder)\(idx)__"
            result = result.replacingOccurrences(of: placeholder, with: block)
        }
        return result
    }
    
    // MARK: - HTML Responsiveness
    
    private static func transformResponsiveHTML(_ text: String) -> String {
        var result = text
        var searchPos = 0
        
        while let divRange = result.range(of: "<div", options: [], range: result.index(result.startIndex, offsetBy: searchPos)..<result.endIndex) {
            let divStart = divRange.lowerBound
            
            // Find the end of the opening tag
            guard let tagEnd = findTagEnd(result, startIndex: divStart) else {
                searchPos = result.distance(from: result.startIndex, to: divRange.upperBound)
                continue
            }
            
            let openTag = String(result[divStart..<tagEnd])
            
            // Check for style with display:flex
            guard hasDisplayFlex(openTag) else {
                searchPos = result.distance(from: result.startIndex, to: tagEnd)
                continue
            }
            
            // Find matching closing </div>
            guard let containerEnd = findMatchingDivEnd(result, openTagStart: divStart) else {
                searchPos = result.distance(from: result.startIndex, to: tagEnd)
                continue
            }
            
            let containerHTML = String(result[divStart..<containerEnd])
            
            // Modify opening tag (add flex-wrap)
            let newOpenTag = addFlexWrapToDivOpenTag(openTag)
            
            // Process inner HTML content for <img> tags
            let innerStart = result.distance(from: divStart, to: tagEnd)
            let closingDivStart = containerHTML.lastIndex(of: "<") ?? containerHTML.endIndex
            let innerHTML = String(containerHTML[containerHTML.index(containerHTML.startIndex, offsetBy: innerStart)..<closingDivStart])
            let processedInner = processImgTags(innerHTML)
            let closingHTML = String(containerHTML[closingDivStart...])
            
            let newContainerHTML = newOpenTag + processedInner + closingHTML
            result.replaceSubrange(divStart..<containerEnd, with: newContainerHTML)
            
            searchPos = result.distance(from: result.startIndex, to: divStart) + newContainerHTML.count
        }
        
        return result
    }
    
    private static func findTagEnd(_ text: String, startIndex: String.Index) -> String.Index? {
        var inSingle = false
        var inDouble = false
        var idx = startIndex
        
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if ch == ">" && !inSingle && !inDouble {
                return text.index(after: idx)
            }
            idx = text.index(after: idx)
        }
        return nil
    }
    
    private static func findMatchingDivEnd(_ text: String, openTagStart: String.Index) -> String.Index? {
        guard let openTagEnd = findTagEnd(text, startIndex: openTagStart) else { return nil }
        
        var depth = 1
        var idx = openTagEnd
        
        while idx < text.endIndex {
            guard let nextLt = text[idx...].firstIndex(of: "<") else { return nil }
            
            // Skip comments
            if text[nextLt...].hasPrefix("<!--") {
                guard let endComment = text[nextLt...].range(of: "-->") else { return nil }
                idx = endComment.upperBound
                continue
            }
            
            if text[nextLt...].hasPrefix("<div") || text[nextLt...].hasPrefix("<DIV") {
                // Nested <div>
                guard let tagEnd = findTagEnd(text, startIndex: nextLt) else { return nil }
                depth += 1
                idx = tagEnd
                continue
            }
            
            // Closing tag
            if text[nextLt...].lowercased().hasPrefix("</div") {
                guard let tagEnd = findTagEnd(text, startIndex: nextLt) else { return nil }
                depth -= 1
                if depth == 0 {
                    return tagEnd
                }
                idx = tagEnd
                continue
            }
            
            // Other tag; skip its end
            guard let tagEnd = findTagEnd(text, startIndex: nextLt) else { return nil }
            idx = tagEnd
        }
        return nil
    }
    
    private static func hasDisplayFlex(_ openTag: String) -> Bool {
        let pattern = #"style\s*=\s*("[^"]*"|'[^']*')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: openTag, range: NSRange(openTag.startIndex..., in: openTag)) else {
            return false
        }
        
        let styleRange = match.range(at: 1)
        let styleValue = String(openTag[Range(styleRange, in: openTag)!])
        let trimmedStyle = styleValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        
        let displayFlexPattern = #"(^|;)\s*display\s*:\s*flex\s*;"#
        guard let displayRegex = try? NSRegularExpression(pattern: displayFlexPattern, options: .caseInsensitive) else {
            return false
        }
        
        return displayRegex.firstMatch(in: trimmedStyle, range: NSRange(trimmedStyle.startIndex..., in: trimmedStyle)) != nil
    }
    
    private static func addFlexWrapToDivOpenTag(_ openTag: String) -> String {
        let pattern = #"style\s*=\s*("[^"]*"|'[^']*')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: openTag, range: NSRange(openTag.startIndex..., in: openTag)) else {
            return openTag
        }
        
        let styleAttr = String(openTag[Range(match.range, in: openTag)!])
        let quoteChar = styleAttr.contains("=\"") ? "\"" : "'"
        let styleValue = styleAttr.split(separator: "=", maxSplits: 1)[1]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        
        // Check if flex-wrap is already present
        let flexWrapPattern = #"(^|;)\s*flex-wrap\s*:\s*wrap\s*(;|$)"#
        if let flexWrapRegex = try? NSRegularExpression(pattern: flexWrapPattern, options: .caseInsensitive),
           flexWrapRegex.firstMatch(in: styleValue, range: NSRange(styleValue.startIndex..., in: styleValue)) != nil {
            return openTag
        }
        
        var newStyleValue = styleValue
        if !newStyleValue.isEmpty && !newStyleValue.hasSuffix(";") {
            newStyleValue += ";"
        }
        newStyleValue += " flex-wrap: wrap;"
        
        let newStyleAttr = "style=\(quoteChar)\(newStyleValue)\(quoteChar)"
        let result = openTag.replacingOccurrences(of: styleAttr, with: newStyleAttr)
        return result
    }
    
    private static func processImgTags(_ html: String) -> String {
        var result = html
        var searchPos = 0
        
        while let imgRange = result.range(of: "<img", options: [], range: result.index(result.startIndex, offsetBy: searchPos)..<result.endIndex) {
            let imgStart = imgRange.lowerBound
            
            guard let tagEnd = findTagEnd(result, startIndex: imgStart) else {
                searchPos = result.distance(from: result.startIndex, to: imgRange.upperBound)
                continue
            }
            
            let imgTag = String(result[imgStart..<tagEnd])
            let newImgTag = processImgTag(imgTag)
            
            result.replaceSubrange(imgStart..<tagEnd, with: newImgTag)
            searchPos = result.distance(from: result.startIndex, to: imgStart) + newImgTag.count
        }
        
        return result
    }
    
    private static func processImgTag(_ imgTag: String) -> String {
        // Find width attribute
        let widthPattern = #"\swidth\s*=\s*("[^"]*"|'[^']*'|\d+)"#
        guard let widthRegex = try? NSRegularExpression(pattern: widthPattern, options: .caseInsensitive),
              let widthMatch = widthRegex.firstMatch(in: imgTag, range: NSRange(imgTag.startIndex..., in: imgTag)) else {
            return imgTag
        }
        
        let widthValueRaw = String(imgTag[Range(widthMatch.range(at: 1), in: imgTag)!])
        let widthContent = widthValueRaw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        
        guard let widthNumMatch = widthContent.range(of: #"\d+"#, options: .regularExpression),
              let widthNum = Int(String(widthContent[widthNumMatch])) else {
            // Remove width attribute without adding style
            return String(imgTag[..<Range(widthMatch.range, in: imgTag)!.lowerBound]) +
                   String(imgTag[Range(widthMatch.range, in: imgTag)!.upperBound...])
        }
        
        // Remove the width attribute entirely
        var newImgTag = String(imgTag[..<Range(widthMatch.range, in: imgTag)!.lowerBound]) +
                       String(imgTag[Range(widthMatch.range, in: imgTag)!.upperBound...])
        
        // Add or merge style attribute
        let newStylePair = "max-width: \(widthNum)px; height: auto;"
        let stylePattern = #"style\s*=\s*("[^"]*"|'[^']*')"#
        
        if let styleRegex = try? NSRegularExpression(pattern: stylePattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let styleMatch = styleRegex.firstMatch(in: newImgTag, range: NSRange(newImgTag.startIndex..., in: newImgTag)) {
            // Merge with existing style
            let whole = String(newImgTag[Range(styleMatch.range, in: newImgTag)!])
            let quoteChar = whole.contains("=\"") ? "\"" : "'"
            var styleVal = whole.split(separator: "=", maxSplits: 1)[1]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            
            // Remove existing max-width/height:auto to avoid duplication
            styleVal = styleVal.replacingOccurrences(of: #"(^|;)\s*max-width\s*:\s*[^;]*;?"#, with: "", options: .regularExpression)
            styleVal = styleVal.replacingOccurrences(of: #"(^|;)\s*height\s*:\s*auto\s*;?"#, with: "", options: .regularExpression)
            
            if !styleVal.isEmpty && !styleVal.hasSuffix(";") {
                styleVal += ";"
            }
            styleVal = " \(newStylePair) \(styleVal)"
            
            let replacement = "style=\(quoteChar)\(styleVal.trimmingCharacters(in: .whitespaces))\(quoteChar)"
            newImgTag = newImgTag.replacingOccurrences(of: whole, with: replacement)
        } else {
            // Insert before closing '>'
            if let gtIndex = newImgTag.lastIndex(of: ">") {
                newImgTag.insert(contentsOf: " style=\"\(newStylePair)\"", at: gtIndex)
            }
        }
        
        return newImgTag
    }
    
    // MARK: - Table Transformation
    
    private static func transformMarkdownTables(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var outLines: [String] = []
        var i = 0
        
        while i < lines.count {
            guard let headerCells = splitTableLine(lines[i]) else {
                outLines.append(lines[i])
                i += 1
                continue
            }
            
            // Need a divider line next
            guard i + 1 < lines.count && isDividerLine(lines[i + 1]) else {
                outLines.append(lines[i])
                i += 1
                continue
            }
            
            let headers = headerCells
            i += 2 // Skip header and divider
            
            var dataRows: [[String]] = []
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
                guard let rowCells = splitTableLine(lines[i]) else {
                    break
                }
                dataRows.append(rowCells)
                i += 1
            }
            
            // Emit transformed block
            for row in dataRows {
                guard !row.isEmpty else { continue }
                
                var heading = row[0].trimmingCharacters(in: .whitespaces)
                // Ensure bold heading (avoid double-bold if already wrapped)
                if !(heading.hasPrefix("**") && heading.hasSuffix("**")) {
                    heading = "**\(heading)**"
                }
                outLines.append(heading)
                
                for colIdx in 1..<min(row.count, headers.count) {
                    let headerName = headers[colIdx].trimmingCharacters(in: .whitespaces)
                    let cellContent = row[colIdx].trimmingCharacters(in: .whitespaces)
                    outLines.append("- **\(headerName):** \(cellContent)")
                }
                // Blank line between groups
                outLines.append("")
            }
            
            // If we stopped due to a blank line, preserve it and move past it
            if i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                outLines.append(lines[i])
                i += 1
            }
        }
        
        // Rejoin with newlines; preserve trailing newline if present in original
        let result = outLines.joined(separator: "\n")
        if text.hasSuffix("\n") && !result.hasSuffix("\n") {
            return result + "\n"
        }
        return result
    }
    
    private static func splitTableLine(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed != "|" else { return nil }
        
        var processed = trimmed
        if processed.hasPrefix("|") {
            processed = String(processed.dropFirst())
        }
        if processed.hasSuffix("|") {
            processed = String(processed.dropLast())
        }
        
        let cells = processed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 2 else { return nil }
        
        return cells
    }
    
    private static func isDividerLine(_ line: String) -> Bool {
        guard let cells = splitTableLine(line) else { return false }
        
        let pattern = #"^\s*:?-+:?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        
        for cell in cells {
            if regex.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)) == nil {
                return false
            }
        }
        return true
    }
}
