#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation

// MARK: - Errors

/// Errors specific to KV cache operations.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
enum KVCacheError: Error, LocalizedError {
    case allocationFailed(Int)
    case unsupportedStrategy(String)
    case layoutCreationFailed
    case capacityExceeded(needed: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .allocationFailed(let bytes):
            return "Failed to allocate KV cache buffer of \(bytes) bytes"
        case .unsupportedStrategy(let strategy):
            return "Unsupported KV cache strategy: \(strategy)"
        case .layoutCreationFailed:
            return "Failed to create tensor layout from requirements"
        case .capacityExceeded(let needed, let available):
            return "KV cache capacity exceeded: need \(needed) tokens but only \(available) available. "
                + "Use --kv-cache-strategy growing for automatic expansion."
        }
    }
}

// MARK: - Logits Utilities

/// Extracts the logits for the **last token** from a flat Float16 logit buffer.
///
/// After batched inference the model returns logits for all `tokenCount` tokens in one
/// contiguous `[tokenCount × vocabSize]` array. When the caller only needs the final
/// token's distribution (the typical generate-next-token case) this helper slices the
/// correct sub-range without an extra allocation.
///
/// - Parameters:
///   - logitBuffer: Flat array of shape `[tokenCount × vocabSize]`.
///   - vocabSize: Number of vocabulary entries per token.
/// - Returns: A slice (as a new `Array`) of length `vocabSize` for the last token.
///   Returns the full buffer unchanged when it already has exactly `vocabSize` elements
///   (i.e. a single-token batch – avoids a redundant copy).
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
func lastTokenLogits(from logitBuffer: [LogitsScalarType], vocabSize: Int) -> [LogitsScalarType] {
    guard logitBuffer.count > vocabSize else { return logitBuffer }
    let tokensInBuffer = logitBuffer.count / vocabSize
    let lastTokenOffset = (tokensInBuffer - 1) * vocabSize
    return Array(logitBuffer[lastTokenOffset..<(lastTokenOffset + vocabSize)])
}

#endif  // canImport(CoreAI)
