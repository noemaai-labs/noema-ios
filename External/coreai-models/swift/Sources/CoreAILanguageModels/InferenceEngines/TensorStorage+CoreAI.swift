#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAI
// Re-export CoreAIShared so external consumers (image-segmenter CLI, etc.)
// transitively get its symbols (NDArray helpers like `fillNDArray`).
@_exported import CoreAIShared
import Foundation
import Metal

// MARK: - Growing Logits Buffer

/// Growing GPU-backed logits buffer that starts small and grows via exponential doubling.
/// Minimizes startup memory by allocating only what's needed.
///
/// Strategy:
/// - Initial: allocate averageExpectedPromptSize tokens (256 = ~77MB for 151K vocab)
/// - Subsequent growth: uses exponential growth (2x) for efficiency
/// - Stays at current capacity during decode (layout changes but storage unchanged)
///
/// Note:
/// - Does not preserve data when storage grows.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
struct GrowingLogitsBuffer: ~Copyable {
    let name: String
    let device: MTLDevice
    let vocabSize: Int
    let maxCapacity: Int
    let scalarType: NDArray.ScalarType

    private let baseDescriptor: NDArrayDescriptor
    private(set) var metalBuffer: MTLBuffer
    private(set) var currentCapacity: Int

    /// Current buffer size in bytes
    var currentByteCount: Int {
        1 * currentCapacity * vocabSize * scalarType.byteSize
    }

    init(
        device: MTLDevice,
        descriptor: InferenceFunctionDescriptor,
        name: String,
        vocabSize: Int,
        maxCapacity: Int,
        initialCapacity: Int = 1
    ) throws {
        guard let valueDesc = descriptor.outputDescriptor(of: name) else {
            throw InferenceRuntimeError.invalidArgument(
                "No descriptor for output '\(name)' in function descriptor")
        }
        guard case .ndArray(let baseDesc) = valueDesc else {
            throw InferenceRuntimeError.invalidArgument(
                "Descriptor for '\(name)' is not an ndArray type")
        }

        let capacity = max(1, min(initialCapacity, maxCapacity))
        let resolved = baseDesc.resolvingDynamicDimensions([1, capacity, vocabSize])
        let byteCount = resolved.minimumByteCount

        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw InferenceRuntimeError.genericError(
                "Failed to allocate logits buffer of \(byteCount) bytes for '\(name)'")
        }

        self.device = device
        self.vocabSize = vocabSize
        self.maxCapacity = maxCapacity
        self.scalarType = baseDesc.scalarType
        self.name = name
        self.currentCapacity = capacity
        self.baseDescriptor = baseDesc
        self.metalBuffer = buffer
    }

    /// Ensure the buffer can hold logits for the given context length.
    /// Returns true if the buffer grew, false if capacity was already sufficient.
    @discardableResult
    mutating func ensureCapacity(forContextLength contextLength: Int) throws -> Bool {
        guard contextLength > currentCapacity else { return false }

        var newCapacity = currentCapacity
        while newCapacity < contextLength {
            newCapacity *= 2
        }
        newCapacity = min(newCapacity, maxCapacity)

        guard newCapacity > currentCapacity else { return false }

        let resolved = baseDescriptor.resolvingDynamicDimensions([1, newCapacity, vocabSize])
        let byteCount = resolved.minimumByteCount

        guard let newBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw InferenceRuntimeError.genericError(
                "Failed to grow logits buffer from \(currentCapacity) to \(newCapacity) tokens (\(byteCount) bytes)")
        }

        self.metalBuffer = newBuffer
        self.currentCapacity = newCapacity
        return true
    }
}

#endif  // canImport(CoreAI)
