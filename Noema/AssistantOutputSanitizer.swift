import Foundation

/// Removes protocol-level end markers that some model runtimes surface as text
/// instead of consuming as end-of-generation tokens.
enum AssistantOutputSanitizer {
    /// Keep these exact and conservative: they are established model protocol
    /// markers, not a blanket rule for angle-bracketed user content.
    static let terminalControlMarkers = [
        "<|END_OF_TURN_TOKEN|>",
        "<｜end▁of▁sentence｜>",
        "<|end_of_turn|>",
        "<|end_of_text|>",
        "<|endofturn|>",
        "<|endoftext|>",
        "<|eot_id|>",
        "<|im_end|>",
        "<|role_end|>",
        "<end_of_turn>",
        "<|eot|>",
        "<|EOT|>",
        "<|end|>",
        "<eot>",
        "<eos>",
        "</s>"
    ]

    /// Adds known terminal markers for client-side stream enforcement without
    /// changing the stop list forwarded to a remote API.
    static func locallyEnforcedStopSequences(including configured: [String]) -> [String] {
        var result = configured
        for marker in terminalControlMarkers where !result.contains(marker) {
            result.append(marker)
        }
        return result
    }

    /// Removes one trailing stop sequence plus whitespace emitted after it.
    /// The caller can loop when a broken backend emits more than one marker.
    static func strippingTrailingStopSequence(
        from text: String,
        stopSequences: [String]
    ) -> (text: String, matched: String)? {
        guard let lastContentIndex = text.lastIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        let significantEnd = text.index(after: lastContentIndex)
        let significantText = text[..<significantEnd]

        var match: String?
        for candidate in stopSequences where !candidate.isEmpty {
            guard significantText.hasSuffix(candidate) else { continue }
            if candidate.count > (match?.count ?? 0) {
                match = candidate
            }
        }
        guard let match else { return nil }

        let markerStart = significantText.index(significantText.endIndex, offsetBy: -match.count)
        return (String(significantText[..<markerStart]), match)
    }

    static func strippingTrailingControlMarkers(from text: String) -> String {
        var result = text
        while let stripped = strippingTrailingStopSequence(
            from: result,
            stopSequences: terminalControlMarkers
        ) {
            result = stripped.text
        }
        return result
    }

    /// Removes hidden `<think>` regions before replaying a partial answer in a
    /// fresh continuation request. This deliberately differs from the normal
    /// transcript renderer, which keeps reasoning available to the expandable
    /// thought UI. Replaying it would ask a small-context model to reason over
    /// the same answer again and can consume every resumed window before it
    /// returns to user-visible output.
    static func strippingReasoningBlocks(from text: String) -> String {
        var remaining = text[...]

        // Some templates pre-open the reasoning block in the generation prompt,
        // so the streamed text begins with reasoning and only contains a close.
        let firstOpen = remaining.range(of: "<think>", options: .caseInsensitive)
        let firstClose = remaining.range(of: "</think>", options: .caseInsensitive)
        if let firstClose {
            let closesImplicitBlock = firstOpen.map {
                firstClose.lowerBound < $0.lowerBound
            } ?? true
            if closesImplicitBlock {
                remaining = remaining[firstClose.upperBound...]
            }
        }

        var visible = ""
        var depth = 0
        while !remaining.isEmpty {
            let open = remaining.range(of: "<think>", options: .caseInsensitive)
            let close = remaining.range(of: "</think>", options: .caseInsensitive)
            let next: (range: Range<String.Index>, isOpen: Bool)? = {
                switch (open, close) {
                case let (open?, close?):
                    return open.lowerBound < close.lowerBound ? (open, true) : (close, false)
                case let (open?, nil):
                    return (open, true)
                case let (nil, close?):
                    return (close, false)
                case (nil, nil):
                    return nil
                }
            }()

            guard let next else {
                if depth == 0 { visible += remaining }
                break
            }
            if depth == 0 {
                visible += remaining[..<next.range.lowerBound]
            }
            if next.isOpen {
                depth += 1
            } else if depth > 0 {
                depth -= 1
            }
            remaining = remaining[next.range.upperBound...]
        }
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Closes reasoning markup that was interrupted by a full context window.
    /// The next checkpoint request has reasoning disabled, so without this the
    /// resumed final answer would be appended inside the old hidden thought box.
    static func closingUnterminatedReasoningBlocks(in text: String) -> String {
        var remaining = text[...]
        var depth = 0
        while !remaining.isEmpty {
            let open = remaining.range(of: "<think>", options: .caseInsensitive)
            let close = remaining.range(of: "</think>", options: .caseInsensitive)
            let next: (range: Range<String.Index>, isOpen: Bool)? = {
                switch (open, close) {
                case let (open?, close?):
                    return open.lowerBound < close.lowerBound ? (open, true) : (close, false)
                case let (open?, nil):
                    return (open, true)
                case let (nil, close?):
                    return (close, false)
                case (nil, nil):
                    return nil
                }
            }()
            guard let next else { break }
            if next.isOpen {
                depth += 1
            } else if depth > 0 {
                depth -= 1
            }
            remaining = remaining[next.range.upperBound...]
        }
        guard depth > 0 else { return text }
        let closingTags = Array(repeating: "</think>", count: depth).joined(separator: "\n")
        return text + "\n" + closingTags + "\n\n"
    }
}
