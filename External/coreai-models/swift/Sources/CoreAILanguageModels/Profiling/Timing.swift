#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation

// MARK: - ContinuousClock Timing Utilities

/// Extension to convert Duration to common time units.
///
/// Example usage:
/// ```swift
/// let start = ContinuousClock.now
/// // ... do work ...
/// let elapsed = (ContinuousClock.now - start).inMilliseconds
/// print("Elapsed: \(elapsed)ms")
/// ```
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension Duration {
    /// Duration in seconds as a Double.
    public var inSeconds: Double {
        let (secs, attoseconds) = self.components
        return Double(secs) + Double(attoseconds) / 1e18
    }

    /// Duration in milliseconds as a Double.
    public var inMilliseconds: Double {
        inSeconds * 1000.0
    }
}

#endif  // canImport(CoreAI)
