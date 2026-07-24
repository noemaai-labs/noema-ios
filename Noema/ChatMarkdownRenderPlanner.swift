import Foundation

enum ChatMarkdownPlannerEntry: Equatable {
    case blank
    case thematicBreak
    case heading(level: Int, content: String)
    case bullet(marker: String, content: String)
    case mathBlock(String)
    case table
    case text(String)
}

enum ChatMarkdownRenderUnit: Equatable {
    case bulletBlock(String)
    case textMathBlock(String)
    case entryIndex(Int)
}

enum ChatMarkdownRenderPlanner {
    static func renderUnits(for entries: [ChatMarkdownPlannerEntry], isMacOS: Bool) -> [ChatMarkdownRenderUnit] {
        var units: [ChatMarkdownRenderUnit] = []
        var index = 0

        while index < entries.count {
            if isMacOS {
                switch entries[index] {
                case .table, .thematicBreak:
                    units.append(.entryIndex(index))
                    index += 1
                case .blank, .bullet, .mathBlock, .text, .heading:
                    // Headings fold into the same selectable block as the
                    // surrounding prose (rendered as "#"-prefixed paragraphs by
                    // MacSelectableMathText) so a drag-selection can sweep across
                    // them. Only tables and rules stay as standalone units.
                    var lines: [String] = []

                    macOSBlock: while index < entries.count {
                        switch entries[index] {
                        case .blank:
                            // Never start a block with a blank line and collapse
                            // runs of blanks: a leading blank would put only a
                            // single "\n" before the first paragraph, and the
                            // renderer folds single newlines into spaces —
                            // turning "\n### Heading" into " ### Heading",
                            // which defeats heading/bullet detection.
                            if let last = lines.last, !last.isEmpty {
                                lines.append("")
                            }
                        case .bullet(let marker, let content):
                            lines.append("\(marker) \(content)")
                        case .mathBlock(let source):
                            lines.append(source)
                        case .text(let line):
                            lines.append(line)
                        case .heading(let level, let content):
                            // Surround with blank lines so the heading becomes
                            // its own paragraph (single newlines collapse to
                            // spaces in the renderer).
                            if !lines.isEmpty, lines.last != "" { lines.append("") }
                            lines.append(String(repeating: "#", count: level) + " " + content)
                            lines.append("")
                        case .table, .thematicBreak:
                            break macOSBlock
                        }
                        index += 1
                    }

                    units.append(.textMathBlock(lines.joined(separator: "\n")))
                }
            } else {
                switch entries[index] {
                case .text, .mathBlock, .blank:
                    var lines: [String] = []

                    textBlock: while index < entries.count {
                        switch entries[index] {
                        case .text(let line):
                            lines.append(line)
                        case .mathBlock(let source):
                            lines.append(source)
                        case .blank:
                            // Same rule as the macOS branch: no leading blanks,
                            // no blank runs (a lone "\n" collapses to a space in
                            // the renderer and pollutes the first paragraph).
                            if let last = lines.last, !last.isEmpty {
                                lines.append("")
                            }
                        case .heading, .table, .bullet, .thematicBreak:
                            break textBlock
                        }
                        index += 1
                    }

                    units.append(.textMathBlock(lines.joined(separator: "\n")))
                case .heading, .table, .thematicBreak:
                    units.append(.entryIndex(index))
                    index += 1
                case .bullet:
                    var lines: [String] = []

                    bulletBlock: while index < entries.count {
                        guard case .bullet(let marker, let content) = entries[index] else {
                            break bulletBlock
                        }
                        lines.append("\(marker) \(content)")
                        index += 1
                    }

                    units.append(.bulletBlock(lines.joined(separator: "\n\n")))
                }
            }
        }

        return units
    }
}
