#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAIShared
import Foundation
import Tokenizers

/// Options for tokenizer resolution.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct TokenizerOptions: Sendable {
    /// Directory to search for locally cached tokenizers.
    public var tokenizersDirectory: String?

    /// Check local caches (HF cache, tokenizers directory) before downloading.
    public var preferCached: Bool

    public init(
        tokenizersDirectory: String? = nil,
        preferCached: Bool = true
    ) {
        self.tokenizersDirectory = tokenizersDirectory
        self.preferCached = preferCached
    }
}

/// Resolves and loads tokenizers from local caches or HuggingFace Hub.
///
/// Resolution order (when `preferCached` is true):
/// 1. HuggingFace local cache (`~/Documents/huggingface/models/...`)
/// 2. Custom tokenizers directory (`tokenizersDirectory` or `~/.coreai-models/tokenizers`)
/// 3. HuggingFace Hub download (network)
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct TokenizerLoader {
    /// Load a tokenizer by HuggingFace model ID or local path.
    ///
    /// - Parameters:
    ///   - identifier: HuggingFace model ID (e.g., "Qwen/Qwen3-0.6B") or local path
    ///   - options: Resolution options controlling cache behavior
    /// - Returns: A loaded tokenizer
    public static func load(
        identifier: String,
        options: TokenizerOptions = .init()
    ) async throws -> any Tokenizer {
        CLILogger.log("Loading tokenizer: \(identifier)", component: "Tokenizer")

        if options.preferCached {
            // 1. HuggingFace local cache (~/Documents/huggingface/models/...)
            let hfCacheBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appending(component: "huggingface")
                .appending(component: "models")
                .appending(path: identifier)

            if FileManager.default.fileExists(atPath: hfCacheBase.appending(path: "tokenizer.json").path) {
                CLILogger.log("Found tokenizer in HF cache: \(hfCacheBase.path)", component: "Tokenizer")
                if let tokenizer = try? await AutoTokenizer.from(modelFolder: hfCacheBase) {
                    CLILogger.log("Tokenizer loaded from HF cache (offline)", component: "Tokenizer")
                    return tokenizer
                }
                CLILogger.log("Failed to load from HF cache, falling back...", component: "Tokenizer")
            }

            // 2. Custom tokenizers directory
            let tokenizersDirectory =
                options.tokenizersDirectory
                ?? NSString(string: "~/.coreai-models/tokenizers").expandingTildeInPath
            let lastComponent = identifier.split(separator: "/").last.map(String.init) ?? identifier
            let fullPath = (tokenizersDirectory as NSString).appendingPathComponent(lastComponent)
            let folderURL = URL(fileURLWithPath: fullPath)

            if FileManager.default.fileExists(atPath: folderURL.appending(path: "tokenizer.json").path) {
                CLILogger.log("Found tokenizer in tokenizers dir: \(fullPath)", component: "Tokenizer")
                if let tokenizer = try? await AutoTokenizer.from(modelFolder: folderURL) {
                    CLILogger.log("Tokenizer loaded from local tokenizer folder", component: "Tokenizer")
                    return tokenizer
                }
                CLILogger.log("Failed to load from tokenizers dir, falling back...", component: "Tokenizer")
            }
        }

        // 3. HuggingFace Hub download
        CLILogger.log("Loading tokenizer from HF Hub...", component: "Tokenizer")
        let tokenizer = try await AutoTokenizer.from(pretrained: identifier)
        CLILogger.log("Tokenizer loaded from HF Hub", component: "Tokenizer")
        return tokenizer
    }
}

#endif  // canImport(CoreAI)
