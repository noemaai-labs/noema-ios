import Foundation

#if canImport(UIKit) || os(macOS)
/// Keeps automatic context-window continuation seams readable. The checkpoint
/// removes only a short, unfinished prose fragment; the boundary filter then
/// suppresses exact text the fresh model request repeats from that checkpoint.
enum OutputContinuationTextCoordinator {
    private static let maximumRollbackCharacters = 320
    private static let terminalCharacters = CharacterSet(charactersIn: ".!?…:;)]}\"'`")

    /// Rolls back a short unfinished final sentence while preserving reasoning
    /// markup, complete paragraphs, Markdown headings, and fenced code.
    nonisolated static func checkpoint(from rawText: String) -> String {
        guard !rawText.isEmpty else { return rawText }

        let answerStart: String.Index = {
            guard let close = rawText.range(
                of: "</think>",
                options: [.backwards, .caseInsensitive]
            ) else {
                return rawText.startIndex
            }
            return close.upperBound
        }()
        let answer = rawText[answerStart...]
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty,
              let lastScalar = trimmedAnswer.unicodeScalars.last,
              !terminalCharacters.contains(lastScalar) else {
            return rawText
        }

        // Never rewrite a continuation boundary inside an open fenced block.
        // MessageView can still place the receipt there correctly, but removing
        // source characters could change the code itself.
        let fenceCount = String(answer).components(separatedBy: "```").count - 1
        guard fenceCount.isMultiple(of: 2) else { return rawText }

        let trimmedEnd = answer.lastIndex(where: { !$0.isWhitespace })
            .map { answer.index(after: $0) } ?? answer.endIndex
        let content = answer[..<trimmedEnd]

        var candidates: [String.Index] = []
        if let paragraphBreak = content.range(of: "\n\n", options: .backwards) {
            candidates.append(paragraphBreak.upperBound)
        }

        var index = content.startIndex
        while index < content.endIndex {
            let character = content[index]
            if character == "." || character == "!" || character == "?" || character == "…" {
                let after = content.index(after: index)
                if after == content.endIndex || content[after].isWhitespace {
                    candidates.append(after)
                }
            }
            index = content.index(after: index)
        }

        guard let boundary = candidates.max(by: {
            content.distance(from: content.startIndex, to: $0)
                < content.distance(from: content.startIndex, to: $1)
        }) else {
            return rawText
        }

        let removed = content[boundary...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !removed.isEmpty,
              removed.count <= maximumRollbackCharacters,
              removed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return rawText
        }

        let retainedAnswer = answer[..<boundary]
        return String(rawText[..<answerStart]) + retainedAnswer
    }
}

/// Buffers only the opening of a fresh continuation pass. This lets us compare
/// a complete enough prefix against the visible checkpoint and remove an exact
/// repeated suffix without confusing legitimate repeated one-token deltas.
struct OutputContinuationBoundaryFilter {
    private let checkpoint: String
    private var pending = ""
    private var resolved = false

    private static let minimumOverlap = 12
    private static let ordinaryDecisionLength = 32
    private static let maximumDecisionLength = 320

    init(checkpoint: String) {
        self.checkpoint = checkpoint
    }

    mutating func append(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        guard !resolved else { return delta }

        pending += delta
        let overlap = Self.longestOverlap(checkpoint: checkpoint, incoming: pending)
        let fullyMatchesCheckpointTail = overlap == pending.count
            && overlap >= Self.minimumOverlap
        let couldStillBeReplayingCheckpoint = pending.count >= Self.minimumOverlap
            && checkpoint.suffix(Self.maximumDecisionLength).contains(pending)

        if (fullyMatchesCheckpointTail || couldStillBeReplayingCheckpoint)
            && pending.count < Self.maximumDecisionLength {
            return ""
        }

        let hasEnoughEvidence = pending.count >= Self.ordinaryDecisionLength
            || pending.contains("\n")
            || pending.count >= Self.maximumDecisionLength
        guard hasEnoughEvidence else { return "" }

        return resolve(overlap: overlap)
    }

    mutating func finish() -> String {
        guard !resolved else { return "" }
        let overlap = Self.longestOverlap(checkpoint: checkpoint, incoming: pending)
        return resolve(overlap: overlap)
    }

    private mutating func resolve(overlap: Int) -> String {
        resolved = true
        defer { pending.removeAll(keepingCapacity: false) }
        guard overlap >= Self.minimumOverlap else { return pending }
        return String(pending.dropFirst(overlap))
    }

    private nonisolated static func longestOverlap(
        checkpoint: String,
        incoming: String
    ) -> Int {
        var overlap = min(checkpoint.count, incoming.count)
        while overlap >= minimumOverlap {
            if checkpoint.suffix(overlap) == incoming.prefix(overlap) {
                return overlap
            }
            overlap -= 1
        }
        return 0
    }
}
#endif
