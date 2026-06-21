#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Tokenizers

// MARK: - Continuation Encoding

/// Encodes context and continuation for evaluation
/// Uses divergence-point detection to handle tokenization boundary issues
///
/// Key insight: `encode("hello") + encode(" world")` ≠ `encode("hello world")`
/// The continuation may merge with the end of context (e.g., " " + "B" → " B").
/// We find where tokens diverge and consider all tokens from that point as part
/// of the continuation for evaluation purposes.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct ContinuationEncoding: Sendable {
    /// Tokens for the context part (tokens that are identical in both encodings)
    public let contextTokens: [Int32]
    /// Tokens for the continuation part (targets for evaluation)
    /// This includes any merged boundary token
    public let continuationTokens: [Int32]
    /// The whole encoding (context + continuation)
    public let tokens: [Int32]
    /// Index where continuation starts in wholeTokens
    public let continuationStartIndex: Int

    /// Initialize continuation encoding
    /// - Parameters:
    ///   - context: The context string (e.g., question + "Answer: ")
    ///   - continuation: The continuation string (e.g., "A")
    ///   - tokenizer: Tokenizer to use for encoding
    public init(context: String, continuation: String, tokenizer: any Tokenizer) {
        // Encode context alone
        let encodedContext = tokenizer.encode(text: context).map { Int32($0) }

        // Encode whole string (context + continuation)
        let encodedTokens = tokenizer.encode(text: context + continuation).map { Int32($0) }

        // Find divergence point - where context-only and whole encoding differ
        // This handles BPE merging at boundaries (e.g., " " + "B" → " B")
        let divergenceIndex =
            (0..<encodedContext.count).first { i in
                encodedTokens[i] != encodedContext[i]
            } ?? encodedContext.count

        // Context tokens are only those that are identical in both encodings
        self.contextTokens = Array(encodedTokens.prefix(divergenceIndex))
        self.continuationTokens = Array(encodedTokens.dropFirst(divergenceIndex))
        self.tokens = encodedTokens
        self.continuationStartIndex = divergenceIndex
    }
}

// MARK: - Continuation Evaluation Result

/// Result of continuation evaluation containing logits for each continuation position
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct ContinuationEvaluationResult: Sendable {
    /// Tokens for the context part
    public let contextTokens: [Int32]
    /// Tokens for the continuation part (targets)
    public let continuationTokens: [Int32]

    /// Logits for each continuation position [num_continuation_tokens, vocab_size]
    public let logits: [[LogitsScalarType]]

    /// Calculate log probability of the continuation
    /// Sum of log probabilities for each target token
    public func logProbability() -> Double {
        var totalLogProb: Double = 0.0
        for (logitsVec, targetToken) in zip(logits, continuationTokens) {
            let tokenIndex = Int(targetToken)
            // Validate token index is within vocabulary bounds
            guard tokenIndex >= 0 && tokenIndex < logitsVec.count else {
                continue
            }
            let logProbs = logSoftmax(logitsVec)
            totalLogProb += Double(logProbs[tokenIndex])
        }
        return totalLogProb
    }

    /// Calculate average log probability per token
    public func averageLogProbability() -> Double {
        guard !continuationTokens.isEmpty else { return 0.0 }
        return logProbability() / Double(continuationTokens.count)
    }

    /// Calculate perplexity of the continuation
    public func perplexity() -> Double {
        let avgLogProb = averageLogProbability()
        return exp(-avgLogProb)
    }

    /// Get probability of the target token at each position
    public func targetProbabilities() -> [Double] {
        var probs: [Double] = []
        for (logitsVec, targetToken) in zip(logits, continuationTokens) {
            let tokenIndex = Int(targetToken)
            // Validate token index is within vocabulary bounds
            guard tokenIndex >= 0 && tokenIndex < logitsVec.count else {
                probs.append(0.0)
                continue
            }
            let logProbs = logSoftmax(logitsVec)
            probs.append(exp(Double(logProbs[tokenIndex])))
        }
        return probs
    }

    /// Compute log-softmax over logits for better numerical stability than softmax + log
    ///
    /// **Why log-softmax is more stable:**
    /// With softmax + log, small probabilities underflow:
    ///   - logits = [100, 0, 0] → softmax ≈ [1.0, 3.7e-44, 3.7e-44]
    ///   - In Float16, 3.7e-44 underflows to 0 → log(0) = -inf
    ///
    /// With log-softmax, we compute directly:
    ///   - shifted = [100-100, 0-100, 0-100] = [0, -100, -100]
    ///   - logSumExp ≈ log(1 + 2e-44) ≈ 0
    ///   - log-softmax ≈ [0, -100, -100] (finite values, not -inf)
    ///
    /// Formula: log(softmax(x)[i]) = x[i] - max(x) - log(sum(exp(x - max(x))))
    private func logSoftmax<T: BinaryFloatingPoint>(_ logits: [T]) -> [T] {
        let maxLogit = logits.max() ?? 0
        let shifted = logits.map { Float($0) - Float(maxLogit) }
        let sumExp = shifted.map { exp($0) }.reduce(0, +)
        // Guard against log(0) with epsilon 1e-10; bounds log at ~-23 nats
        let logSumExp = log(max(sumExp, 1e-10))
        return shifted.map { T($0 - logSumExp) }
    }
}

// MARK: - Errors

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public enum ContinuationEvaluationError: Error, LocalizedError {
    case requiresDisabledChatTemplate
    case requiresLogitsOutput
    case engineDoesNotSupportLogits
    case emptyContinuation
    case rawTokensNotSupported

    public var errorDescription: String? {
        switch self {
        case .requiresDisabledChatTemplate:
            return "--continuation requires --apply-chat-template=false"
        case .requiresLogitsOutput:
            return "--continuation requires --print-logits or --save-logits"
        case .engineDoesNotSupportLogits:
            return "The current inference engine does not support returning logits"
        case .emptyContinuation:
            return "Continuation string cannot be empty"
        case .rawTokensNotSupported:
            return "--continuation requires text prompt (--prompt or --prompt-file), not --raw-tokens"
        }
    }
}

#endif  // canImport(CoreAI)
