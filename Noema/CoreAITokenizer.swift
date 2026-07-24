import Foundation

/// Minimal byte-level BPE tokenizer that reads a Hugging Face `tokenizer.json`.
///
/// Covers the byte-level BPE models in the `apple/coreai-models` catalog
/// (Qwen, Gemma, Mistral, GPT-OSS). It is intentionally dependency-free so it
/// compiles and unit-tests on the current toolchain even though the Core AI
/// runtime that consumes it requires iOS 27 / Xcode 27.
///
/// This is the "initial version" sampler companion described in the plan;
/// full parity with Apple's `LanguageModels` runtime is a follow-up.
final class CoreAITokenizer: @unchecked Sendable {
    struct SpecialToken {
        let content: String
        let id: Int
    }

    private let vocab: [String: Int]
    private let idToToken: [Int: String]
    private let mergeRanks: [String: Int]
    private let specialTokens: [SpecialToken]
    private let byteEncoder: [UInt8: Character]
    private let byteDecoder: [Character: UInt8]

    /// Common end-of-turn / end-of-text ids discovered from special tokens.
    let eosTokenIDs: Set<Int>

    /// Whether the vocabulary defines `token`. Used to pick a chat template
    /// (e.g. ChatML's `<|im_start|>`) that the model can actually tokenize.
    func hasToken(_ token: String) -> Bool { vocab[token] != nil }

    /// Total vocabulary size (BPE vocab + added tokens). Used when synthesizing
    /// LanguageBundle metadata for bundles that ship without one.
    var vocabularySize: Int { vocab.count }

    enum TokenizerError: LocalizedError {
        case unreadable(URL)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url):
                return "Couldn't read tokenizer at \(url.lastPathComponent)."
            case .unsupported(let detail):
                return "Unsupported tokenizer: \(detail)."
            }
        }
    }

    // MARK: - Loading

    init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TokenizerError.unreadable(url)
        }
        guard let model = root["model"] as? [String: Any] else {
            throw TokenizerError.unsupported("missing model section")
        }

        // Vocab
        var vocab: [String: Int] = [:]
        if let raw = model["vocab"] as? [String: Int] {
            vocab = raw
        } else if let raw = model["vocab"] as? [String: NSNumber] {
            for (k, v) in raw { vocab[k] = v.intValue }
        }
        guard !vocab.isEmpty else { throw TokenizerError.unsupported("empty vocab") }

        // Merges: either ["a b", ...] or [["a","b"], ...]
        var ranks: [String: Int] = [:]
        if let merges = model["merges"] as? [String] {
            for (rank, merge) in merges.enumerated() {
                ranks[merge] = rank
            }
        } else if let merges = model["merges"] as? [[String]] {
            for (rank, pair) in merges.enumerated() where pair.count == 2 {
                ranks["\(pair[0]) \(pair[1])"] = rank
            }
        }

        // Special / added tokens
        var specials: [SpecialToken] = []
        if let added = root["added_tokens"] as? [[String: Any]] {
            for entry in added {
                if let content = entry["content"] as? String,
                   let id = (entry["id"] as? NSNumber)?.intValue ?? (entry["id"] as? Int) {
                    specials.append(SpecialToken(content: content, id: id))
                    vocab[content] = id
                }
            }
        }
        // Longest-first so multi-char specials match before substrings.
        specials.sort { $0.content.count > $1.content.count }

        self.vocab = vocab
        self.mergeRanks = ranks
        self.specialTokens = specials
        var idToToken: [Int: String] = [:]
        idToToken.reserveCapacity(vocab.count)
        for (token, id) in vocab { idToToken[id] = token }
        self.idToToken = idToToken

        let (encoder, decoder) = Self.byteLevelMaps()
        self.byteEncoder = encoder
        self.byteDecoder = decoder

        // Heuristic EOS detection from common end markers.
        var eos = Set<Int>()
        for marker in ["<|im_end|>", "<|endoftext|>", "<|eot_id|>", "</s>", "<end_of_turn>", "<eos>"] {
            if let id = vocab[marker] { eos.insert(id) }
        }
        self.eosTokenIDs = eos
    }

    // MARK: - Encoding

    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var ids: [Int] = []
        for segment in splitOnSpecials(text) {
            switch segment {
            case .special(let id):
                ids.append(id)
            case .text(let chunk):
                for piece in preTokenize(chunk) {
                    ids.append(contentsOf: bpe(piece))
                }
            }
        }
        return ids
    }

    func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids {
            guard let token = idToToken[id] else { continue }
            if specialTokens.contains(where: { $0.id == id }) {
                // Flush accumulated bytes, then append the special literally.
                if let s = String(bytes: bytes, encoding: .utf8) { /* keep order */ _ = s }
                bytes.append(contentsOf: Array(token.utf8))
                continue
            }
            for ch in token {
                if let byte = byteDecoder[ch] {
                    bytes.append(byte)
                } else {
                    bytes.append(contentsOf: Array(String(ch).utf8))
                }
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    // MARK: - Internals

    private enum Segment {
        case text(String)
        case special(Int)
    }

    private func splitOnSpecials(_ text: String) -> [Segment] {
        guard !specialTokens.isEmpty else { return [.text(text)] }
        var segments: [Segment] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            var matched = false
            // Find the earliest special-token occurrence.
            var bestRange: Range<Substring.Index>?
            var bestID = 0
            for special in specialTokens {
                if let range = remaining.range(of: special.content) {
                    if bestRange.map({ range.lowerBound < $0.lowerBound }) ?? true {
                        bestRange = range
                        bestID = special.id
                    }
                }
            }
            if let range = bestRange {
                if range.lowerBound > remaining.startIndex {
                    segments.append(.text(String(remaining[remaining.startIndex..<range.lowerBound])))
                }
                segments.append(.special(bestID))
                remaining = remaining[range.upperBound...]
                matched = true
            }
            if !matched {
                segments.append(.text(String(remaining)))
                break
            }
        }
        return segments
    }

    /// GPT-2 / Qwen-style pretokenizer split, then byte-level encode each piece.
    private func preTokenize(_ text: String) -> [String] {
        let pattern = "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [byteEncode(text)]
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var pieces: [String] = []
        for match in matches {
            let piece = ns.substring(with: match.range)
            if !piece.isEmpty {
                pieces.append(byteEncode(piece))
            }
        }
        return pieces.isEmpty ? [byteEncode(text)] : pieces
    }

    private func byteEncode(_ piece: String) -> String {
        var out = ""
        for byte in piece.utf8 {
            if let ch = byteEncoder[byte] { out.append(ch) }
        }
        return out
    }

    /// Greedy rank-based BPE merge over a byte-encoded piece.
    private func bpe(_ piece: String) -> [Int] {
        var symbols = piece.map { String($0) }
        guard symbols.count > 1 else {
            return tokenIDs(for: symbols)
        }
        while true {
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(symbols.count - 1) {
                let pair = symbols[i] + " " + symbols[i + 1]
                if let rank = mergeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            if bestIndex < 0 { break }
            symbols[bestIndex] = symbols[bestIndex] + symbols[bestIndex + 1]
            symbols.remove(at: bestIndex + 1)
            if symbols.count == 1 { break }
        }
        return tokenIDs(for: symbols)
    }

    private func tokenIDs(for symbols: [String]) -> [Int] {
        var ids: [Int] = []
        for symbol in symbols {
            if let id = vocab[symbol] {
                ids.append(id)
            } else {
                // Fall back to single-character ids for unknown merges.
                for ch in symbol {
                    if let id = vocab[String(ch)] { ids.append(id) }
                }
            }
        }
        return ids
    }

    /// GPT-2 byte<->unicode reversible mapping.
    private static func byteLevelMaps() -> ([UInt8: Character], [Character: UInt8]) {
        var bs: [Int] = []
        bs.append(contentsOf: 33...126)
        bs.append(contentsOf: Int(0xA1)...Int(0xAC))
        bs.append(contentsOf: Int(0xAE)...Int(0xFF))
        var cs = bs
        var n = 0
        for b in 0...255 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var encoder: [UInt8: Character] = [:]
        var decoder: [Character: UInt8] = [:]
        for (b, c) in zip(bs, cs) {
            if let scalar = Unicode.Scalar(c) {
                let ch = Character(scalar)
                encoder[UInt8(b)] = ch
                decoder[ch] = UInt8(b)
            }
        }
        return (encoder, decoder)
    }
}
