import Foundation

enum StreamChunkMergeMode: Equatable {
    case unknown
    case delta
    case cumulative
}

struct StreamChunkMerger {
    private(set) var mode: StreamChunkMergeMode

    init(mode: StreamChunkMergeMode = .unknown) {
        self.mode = mode
    }

    @discardableResult
    mutating func append(_ newChunk: String, to existing: inout String) -> String {
        let delta = deltaToAppend(for: newChunk, existing: existing)
        existing += delta
        return delta
    }

    mutating func deltaToAppend(for newChunk: String, existing: String) -> String {
        guard !newChunk.isEmpty else { return "" }
        guard !existing.isEmpty else { return newChunk }

        switch mode {
        case .delta:
            return newChunk
        case .cumulative:
            return cumulativeDelta(newChunk: newChunk, existing: existing)
        case .unknown:
            if newChunk.count > existing.count, newChunk.hasPrefix(existing) {
                mode = .cumulative
                return String(newChunk.dropFirst(existing.count))
            }

            let overlap = suffixPrefixOverlapLength(existing: existing, incoming: newChunk)
            if overlap > 0, overlap < newChunk.count {
                return String(newChunk.dropFirst(overlap))
            }

            return newChunk
        }
    }

    private func cumulativeDelta(newChunk: String, existing: String) -> String {
        if newChunk == existing { return "" }
        if newChunk.count > existing.count, newChunk.hasPrefix(existing) {
            return String(newChunk.dropFirst(existing.count))
        }

        let overlap = suffixPrefixOverlapLength(existing: existing, incoming: newChunk)
        if overlap > 0 {
            return String(newChunk.dropFirst(overlap))
        }

        return newChunk
    }

    private func suffixPrefixOverlapLength(existing: String, incoming: String) -> Int {
        let maxOverlap = min(existing.count, incoming.count)
        guard maxOverlap > 0 else { return 0 }

        var overlap = maxOverlap
        while overlap > 0 {
            if existing.suffix(overlap) == incoming.prefix(overlap) {
                return overlap
            }
            overlap -= 1
        }

        return 0
    }
}
