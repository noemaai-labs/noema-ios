#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAIShared
import Foundation
import Tokenizers
import os.signpost

/// Standard autoregressive decoding.
///
/// Handles text decoding, stop sequence detection, and Instruments profiling.
/// Uses `InferenceEngine.generate()` for the underlying token stream.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct VanillaDecodingStrategy: DecodingStrategy {
    // MARK: - Primary API

    /// Stream decoded text with optional logits.
    ///
    /// - Parameters:
    ///   - input: Input specification (raw text, prompt, or pre-tokenized)
    ///   - tokenizer: Tokenizer for encoding/decoding
    ///   - inferenceEngine: Engine for model inference
    ///   - samplingConfiguration: Sampling parameters (temperature, topK, etc.)
    ///   - options: Inference options (maxTokens, includeLogits)
    ///   - stopSequences: Token sequences that halt generation
    /// - Returns: Stream of `GenerationResult` (text + optional logits)
    public func decode(
        from input: Input,
        tokenizer: any Tokenizer,
        inferenceEngine: any InferenceEngine,
        samplingConfiguration: SamplingConfiguration,
        options: InferenceOptions,
        stopSequences: StopSequences
    ) -> AsyncThrowingStream<GenerationResult, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await runGeneration(
                        input: input,
                        tokenizer: tokenizer,
                        inferenceEngine: inferenceEngine,
                        samplingConfiguration: samplingConfiguration,
                        options: options,
                        stopSequences: stopSequences,
                        with: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Unified Generation Loop

    private func runGeneration(
        input: Input,
        tokenizer: any Tokenizer,
        inferenceEngine: any InferenceEngine,
        samplingConfiguration: SamplingConfiguration,
        options: InferenceOptions,
        stopSequences: StopSequences,
        with continuation: AsyncThrowingStream<GenerationResult, any Error>.Continuation
    ) async throws {
        CLILogger.log("🔄 Starting vanilla decoding generation")

        let inputTokens = try PromptUtils.maybeApplyTokenizerChatTemplate(input, tokenizer: tokenizer).map(Int32.init)
        CLILogger.log("Input tokens: \(inputTokens.prefix(10))... (showing first 10)")

        var generatedTokenCount = 0
        var newlyGeneratedTokens: [Int] = []
        var recentTokens: [Int32] = []
        var pendingText = ""

        // Step 0 is Prompt (prefill), steps 1+ are Extend (inter-token timing)
        var inferenceSpan: ProfileSpan? = InstrumentsProfiler.beginPrompt(
            tokens: inputTokens.count
        )

        // Single loop over unified engine stream
        for try await output in try inferenceEngine.generate(
            with: inputTokens,
            samplingConfiguration: samplingConfiguration,
            inferenceOptions: options
        ) {
            try Task.checkCancellation()
            let step = generatedTokenCount

            // End the inference span (Prompt for step 0, Extend for steps 1+)
            inferenceSpan?.end()
            inferenceSpan = nil

            CLILogger.log("✅ Generated token ID: \(output.tokenId)", level: 2)

            // Begin token decoding span (sync - no await between begin/end)
            let decodingSpan = InstrumentsProfiler.beginDecode(step: step)

            // Decode text incrementally — hold back trailing bytes that
            // don't form complete UTF-8 characters (e.g. partial emoji).
            newlyGeneratedTokens.append(Int(output.tokenId))
            generatedTokenCount += 1

            let fullDecode = tokenizer.decode(tokens: newlyGeneratedTokens)

            // Find how many trailing bytes might be an incomplete UTF-8
            // sequence. The tokenizer may produce U+FFFD replacement chars
            // for partial sequences — strip those from the emitted text and
            // re-try on the next token when more bytes arrive.
            let safeEnd = Self.safeUTF8Prefix(of: fullDecode)
            let emittable = String(fullDecode[fullDecode.startIndex..<safeEnd])

            let newText: String
            if emittable.count > pendingText.count,
                emittable.hasPrefix(pendingText)
            {
                newText = String(emittable.dropFirst(pendingText.count))
                pendingText = emittable
            } else if emittable != pendingText {
                newText = emittable
                pendingText = emittable
            } else {
                newText = ""
            }

            // Reset buffer on newline to bound re-decode cost to one paragraph.
            if newText.hasSuffix("\n") {
                newlyGeneratedTokens = []
                pendingText = ""
            }

            // Check stop sequences before yielding — don't emit EOS tokens as text.
            recentTokens.append(output.tokenId)
            if recentTokens.count > stopSequences.maxLength {
                recentTokens.removeFirst()
            }

            if stopSequences.matches(recentTokens: recentTokens) {
                CLILogger.log("✅ Stop sequence detected at tokens: \(recentTokens)", level: 2)
                decodingSpan.end()
                break
            }

            if !newText.isEmpty {
                let result = GenerationResult(
                    text: newText,
                    tokenId: output.tokenId,
                    rawLogits: output.logits
                )
                continuation.yield(result)
            }

            CLILogger.log("✅ Generated newText: \(newText)", level: 2)

            // End token decoding span
            decodingSpan.end()

            // Log token generation event for Instruments
            InstrumentsProfiler.logTokenGeneration(tokenIndex: step, token: newText)

            // Begin extend span for the next token (step 1+ = generation phase)
            inferenceSpan = InstrumentsProfiler.beginExtend(
                step: step + 1,
                tokens: inputTokens.count + generatedTokenCount
            )
        }

        // End the last extend span
        inferenceSpan?.end()
        inferenceSpan = nil

        // Flush any remaining buffered text (final incomplete sequence now complete)
        let finalDecode = tokenizer.decode(tokens: newlyGeneratedTokens)
        if finalDecode.count > pendingText.count, finalDecode.hasPrefix(pendingText) {
            let remaining = String(finalDecode.dropFirst(pendingText.count))
            if !remaining.isEmpty {
                continuation.yield(GenerationResult(text: remaining, tokenId: 0, rawLogits: nil))
            }
        }

        await PerformanceMetrics.shared.setGeneratedTokenCount(generatedTokenCount)

        continuation.finish()
    }

    // MARK: - UTF-8 Safety

    /// Returns the end index of the longest prefix of `text` that contains
    /// only complete UTF-8 characters (no trailing U+FFFD replacement chars
    /// that indicate the tokenizer produced an incomplete byte sequence).
    private static func safeUTF8Prefix(of text: String) -> String.Index {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            if text[prev] == "\u{FFFD}" {
                end = prev
            } else {
                break
            }
        }
        return end
    }
}

#endif  // canImport(CoreAI)
