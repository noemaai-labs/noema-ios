#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation

/// Resolves model asset paths by searching a configurable list of directories.
///
/// ## Precedence (highest wins)
///
/// 1. **Command line** (`--model`) — most specific, per-invocation override
/// 2. **Environment variable** (`COREAI_MODEL_PATH`, colon-separated) — session/system preference
/// 3. **Default** — `./`, `./exports/`, `~/.coreai-models/`
///
/// This follows standard Unix convention: explicit flags override environment,
/// environment overrides defaults. Users can always narrow scope without unsetting variables.
///
/// ## Resolution
///
/// Given a name or path, searches each directory in order for an exact match.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct ModelPaths: Sendable {
    public let searchPaths: [String]

    public static let defaultSearchPaths = [".", "./exports", "~/.coreai-models"]
    public static let environmentVariable = "COREAI_MODEL_PATH"

    /// Initialize with explicit search paths (command-line override).
    /// Falls back to env var, then defaults.
    public init(override: String? = nil) {
        if let override {
            self.searchPaths = override.split(separator: ":").map(String.init)
        } else if let envPath = ProcessInfo.processInfo.environment[Self.environmentVariable] {
            self.searchPaths = envPath.split(separator: ":").map(String.init)
        } else {
            self.searchPaths = Self.defaultSearchPaths
        }
    }

    /// Resolve a model name or path to an existing URL.
    ///
    /// - Parameter nameOrPath: Model name (e.g. "qwen3_0_6b_4bit") or path
    /// - Returns: URL to the resolved model asset, or nil if not found
    public func resolve(_ nameOrPath: String) -> URL? {
        let expanded = NSString(string: nameOrPath).expandingTildeInPath

        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            return nil
        }

        for dir in searchPaths {
            let expandedDir = NSString(string: dir).expandingTildeInPath
            let base = URL(fileURLWithPath: expandedDir)

            let exact = base.appendingPathComponent(nameOrPath)
            if FileManager.default.fileExists(atPath: exact.path) {
                return exact
            }
        }

        return nil
    }

    /// Human-readable error describing where we searched.
    public func notFoundError(for nameOrPath: String) -> String {
        let expanded = searchPaths.map { NSString(string: $0).expandingTildeInPath }
        return "Model '\(nameOrPath)' not found. Searched: \(expanded.joined(separator: ", "))"
    }
}

#endif  // canImport(CoreAI)
