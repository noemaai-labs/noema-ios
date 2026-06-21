#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

/// Maps logical graph-function roles to one or more physical function names.
///
/// Most bundles don't need this — the runtime probes `AIModel`'s function
/// list and matches against known role names by convention (`main`, `extend_<N>`,
/// `load_embeddings`, etc.). `FunctionMap` is the override for bundles whose
/// function names don't follow conventions, or where one logical role maps to
/// multiple physical functions (ANE chunked-static models with several
/// `extend_<N>` chunk sizes).
///
/// Always-array values: a single-name role uses a one-element list, keeping
/// the JSON shape uniform with multi-name roles.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public struct FunctionMap: Codable, Sendable, Equatable {
    public let entries: [String: [String]]

    public init(_ entries: [String: [String]]) {
        self.entries = entries
    }

    /// All physical names registered for `role`, or `[]` if not present.
    public func names(for role: String) -> [String] {
        entries[role] ?? []
    }

    /// First physical name registered for `role`, or `nil` if absent.
    public func name(for role: String) -> String? {
        entries[role]?.first
    }

    public init(from decoder: Decoder) throws {
        self.entries = try [String: [String]](from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try entries.encode(to: encoder)
    }
}

#endif  // canImport(CoreAI)
