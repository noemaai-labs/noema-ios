#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAIShared

/// `language` block of `metadata.json` schema 0.2 — LLM-specific config.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct LanguageConfig: Codable, Sendable, Equatable {
    public let tokenizer: String
    public let vocabSize: Int
    public let maxContextLength: Int

    /// `true` if the bundle ships its own tokenizer directory; `false` to
    /// load via HuggingFace at runtime. Defaults to `true` when omitted.
    public let embeddedTokenizer: Bool

    /// Optional override for graph-function role → physical names. When
    /// absent, the runtime probes via `AIModelAsset.summary()` and applies
    /// known role conventions (`main`, `extend_<N>`, `load_embeddings`, ...).
    public let functionMap: FunctionMap?

    public init(
        tokenizer: String,
        vocabSize: Int,
        maxContextLength: Int,
        embeddedTokenizer: Bool = true,
        functionMap: FunctionMap? = nil
    ) {
        self.tokenizer = tokenizer
        self.vocabSize = vocabSize
        self.maxContextLength = maxContextLength
        self.embeddedTokenizer = embeddedTokenizer
        self.functionMap = functionMap
    }

    enum CodingKeys: String, CodingKey {
        case tokenizer
        case vocabSize = "vocab_size"
        case maxContextLength = "max_context_length"
        case embeddedTokenizer = "embedded_tokenizer"
        case functionMap = "function_map"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tokenizer = try c.decode(String.self, forKey: .tokenizer)
        self.vocabSize = try c.decode(Int.self, forKey: .vocabSize)
        self.maxContextLength = try c.decode(Int.self, forKey: .maxContextLength)
        self.embeddedTokenizer = try c.decodeIfPresent(Bool.self, forKey: .embeddedTokenizer) ?? true
        self.functionMap = try c.decodeIfPresent(FunctionMap.self, forKey: .functionMap)
    }
}

#endif  // canImport(CoreAI)
