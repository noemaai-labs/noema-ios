#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Tokenizers

// MARK: - Prompt Input Types

/// Represents the source of prompt input
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public enum PromptInput {
    case text(String)
    case rawTokens(RawTokensInput)

    /// Load prompt text from a file
    public static func fromTextFile(path: String) throws -> PromptInput {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PromptInputError.fileNotFound(path)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        return .text(text)
    }

    /// Load pre-tokenized tokens from a JSON file
    public static func fromRawTokensFile(path: String) throws -> PromptInput {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PromptInputError.fileNotFound(path)
        }

        let data = try Data(contentsOf: url)
        let container = try JSONDecoder().decode(RawTokensInput.self, from: data)
        return .rawTokens(container)
    }
}

// MARK: - Prompt Input Errors

/// Errors for prompt input loading
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public enum PromptInputError: Error, LocalizedError {
    case fileNotFound(String)
    case mutuallyExclusive

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .mutuallyExclusive:
            return "Only one of --prompt, --prompt-file, or --raw-tokens may be specified"
        }
    }
}

// MARK: - Raw Tokens Input

/// JSON structure for pre-tokenized input: {"tokens": [1, 2, 3, ...]}
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct RawTokensInput: Codable, Sendable {
    public let tokens: [Int32]

    public init(tokens: [Int32]) {
        self.tokens = tokens
    }

    /// Represents a preview of raw tokens input
    public struct Preview: Sendable {
        /// Number of tokens in the input
        public let tokenCount: Int
        /// Decoded text (may be truncated)
        public let decodedText: String
        /// Whether the decoded text was truncated
        public let isTruncated: Bool

        /// Returns a formatted summary string
        public var summary: String {
            let suffix = isTruncated ? "..." : ""
            return "(\(tokenCount) tokens) \(decodedText)\(suffix)"
        }
    }

    /// Returns a preview with decoded text using the provided tokenizer
    /// - Parameters:
    ///   - tokenizer: Tokenizer to decode tokens
    ///   - maxChars: Maximum characters to show in preview (default: 100)
    /// - Returns: Preview containing token count and decoded text
    public func preview(using tokenizer: any Tokenizer, maxChars: Int = 100) -> Preview {
        let intTokens = tokens.map { Int($0) }
        let decodedText = tokenizer.decode(tokens: intTokens)

        let isTruncated = decodedText.count > maxChars
        let truncatedText =
            isTruncated
            ? String(decodedText.prefix(maxChars))
            : decodedText

        return Preview(
            tokenCount: tokens.count,
            decodedText: truncatedText,
            isTruncated: isTruncated
        )
    }
}

// MARK: - Prompt Input Resolver

/// Resolves prompt input from CLI options
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct PromptInputResolver {
    /// Resolve the effective prompt from CLI options (mutually exclusive)
    /// - Parameters:
    ///   - prompt: Direct prompt string (optional)
    ///   - promptFile: Path to text file (optional)
    ///   - rawTokens: Path to JSON tokens file (optional)
    ///   - default: Default prompt if none specified (required - caller must provide)
    /// - Returns: Resolved PromptInput
    /// - Throws: PromptInputError.mutuallyExclusive if multiple sources specified
    public static func resolve(
        prompt: String?,
        promptFile: String?,
        rawTokens: String?,
        `default`: String
    ) throws -> PromptInput {
        // Count how many sources are specified
        let sources = [prompt, promptFile, rawTokens].compactMap { $0 }

        if sources.count > 1 {
            throw PromptInputError.mutuallyExclusive
        }

        // Handle raw tokens (JSON file with pre-tokenized tokens)
        if let rawTokensPath = rawTokens {
            return try PromptInput.fromRawTokensFile(path: rawTokensPath)
        }

        // Handle prompt file (text file)
        if let promptFilePath = promptFile {
            return try PromptInput.fromTextFile(path: promptFilePath)
        }

        // Handle direct prompt or fallback to default
        return .text(prompt ?? `default`)
    }
}

#endif  // canImport(CoreAI)
