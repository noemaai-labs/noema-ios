#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation

/// Configuration for a specific model shape
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct ModelShapeConfig: Hashable, Sendable {
    /// Maximum context length supported by this shape
    public let maxContextLength: Int

    /// Query size (number of tokens processed per inference)
    public let querySize: Int

    /// Core AI function entrypoint name
    public let entrypoint: String

    public init(maxContextLength: Int, querySize: Int, entrypoint: String) {
        self.maxContextLength = maxContextLength
        self.querySize = querySize
        self.entrypoint = entrypoint
    }
}

/// Shape selector for Neural Engine models
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct ModelShapeSelector: Sendable {
    /// All available shapes parsed from entrypoints
    public private(set) var availableShapes: [ModelShapeConfig] = []

    public init() {}

    /// Parse available shapes from entrypoint names
    /// - Parameter entrypoints: List of available entrypoint names
    public mutating func parseShapes(from entrypoints: [String]) {
        availableShapes.removeAll()

        for entrypoint in entrypoints {
            // Parse extend_MAXCONTEXT_QUERYSIZE format
            if entrypoint.hasPrefix("extend_") {
                let parts = entrypoint.split(separator: "_")
                if parts.count == 3,
                    let maxContextLength = Int(parts[1]),
                    let querySize = Int(parts[2])
                {
                    availableShapes.append(
                        ModelShapeConfig(
                            maxContextLength: maxContextLength,
                            querySize: querySize,
                            entrypoint: entrypoint
                        ))
                }
            }
        }

        // Sort by max context length, then query size
        availableShapes.sort { lhs, rhs in
            if lhs.maxContextLength != rhs.maxContextLength {
                return lhs.maxContextLength < rhs.maxContextLength
            }
            return lhs.querySize < rhs.querySize
        }
    }

    /// Select optimal shape for given requirements
    /// - Parameters:
    ///   - currentSeqLength: Current sequence length (number of tokens in context)
    ///   - desiredQuerySize: Desired number of tokens to process
    /// - Returns: Shape config or nil if none fits
    public func selectShape(currentSeqLength: Int, desiredQuerySize: Int) -> ModelShapeConfig? {
        // Filter shapes that to fit current tokens and new tokens to process
        // totalContextLength <= contextLength where totalContextLength = step + queryLength
        let candidates = availableShapes.filter {
            // Check if after processing we'll still be within capacity
            // currentSeqLength + querySize <= maxContextLength
            ($0.maxContextLength >= currentSeqLength + $0.querySize) && ($0.querySize >= desiredQuerySize)
        }

        guard !candidates.isEmpty else {
            return nil
        }

        // Prefer: smallest maxContextLength, then largest querySize
        return candidates.min { lhs, rhs in
            if lhs.maxContextLength != rhs.maxContextLength {
                return lhs.maxContextLength < rhs.maxContextLength
            }
            return lhs.querySize > rhs.querySize  // Note: reversed for larger query
        }
    }

    /// Select shape for decode (prefer larger query sizes)
    /// - Parameters:
    ///   - currentSeqLength: Current sequence length (number of tokens in context)
    ///   - tokensToProcess: Number of tokens to process
    /// - Returns: Shape config or nil
    public func selectShapeForDecode(currentSeqLength: Int, tokensToProcess: Int) -> ModelShapeConfig? {
        // Try query sizes in descending order: 64, 16, 8
        for querySize in [64, 16, 8] where tokensToProcess <= querySize {
            if let shape = selectShape(currentSeqLength: currentSeqLength, desiredQuerySize: querySize) {
                return shape
            }
        }
        return nil
    }
}

#endif  // canImport(CoreAI)
