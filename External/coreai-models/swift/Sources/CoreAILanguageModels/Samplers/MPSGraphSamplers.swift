#if canImport(CoreAI)
// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Metal
import MetalPerformanceShadersGraph

// MARK: - Core AI MPSGraph Samplers
//
// GPU-accelerated token sampling for Core AI's pipelined inference engine.
// These samplers use MPSGraph's runAsync with completion handlers for
// non-blocking execution, enabling true GPU pipelining.
//
// ## Design Decisions
//
// ### Protocol-Based Architecture
// Both argmax (greedy) and TopK (probabilistic) samplers conform to the
// `MPSGraphSampler` protocol, enabling runtime selection based on temperature:
// - temperature == 0: Argmax sampler (deterministic, fastest)
// - temperature > 0:  TopK sampler (probabilistic, more creative)
//
// The factory pattern (`MPSGraphSamplerFactory`) selects the appropriate sampler
// once at generation start, with the sampler cached for the entire generation.
//
// ### Fixed Vocab Size at Compile Time
// Unlike MPSGraphInferenceEngine which uses dynamic shape `[1, -1]` for the
// vocab dimension, these samplers fix the vocab size at compile time. This
// enables better MPSGraph optimization and eliminates runtime shape inference.
//
// ### Temperature at Init (Immutable)
// Temperature is baked into the TopK sampler at initialization rather than
// per-call. This matches the caching pattern where the sampler is created
// once and reused. Changing temperature requires engine reset + new sampler.
//
// ### Slice Handling for Prefill
// The `encodeWithSlice` method handles multi-token prefill scenarios by
// extracting the last token's logits using a blit encoder before sampling.
// This is critical for efficient prefill where we only need to sample from
// the final position.
//
// ### Comparison with MPSGraphInferenceEngine
// | Feature              | MPSGraphInferenceEngine | Core AI Samplers        |
// |---------------------|-------------------------|----------------------|
// | Sampling types      | Argmax only             | Argmax + TopK        |
// | Vocab shape         | Dynamic [1, -1]         | Fixed [1, vocabSize] |
// | Temperature         | N/A (greedy only)       | At init (immutable)  |
// | Slice handling      | N/A                     | Blit + encode        |
// | Testing hooks       | None                    | testingOnlyRandomOverride |
// | Buffer allocation   | Per-call                | Pre-allocated        |
//
// ### Why Not Use MPSGraphInferenceEngine's Sampler?
// 1. Core AI needs TopK sampling with temperature for creative generation
// 2. Core AI uses ComputeStream's Metal3 queue (withMetal3Queue), not direct
//    command queue - we need sampler methods that take a queue parameter
// 3. CoreAI.s pipelined architecture requires completion handlers for yielding
//    tokens without blocking the main inference loop
// 4. Fixed vocab size enables better graph optimization for large vocabs
//    (150K+ for Qwen models)

// MARK: - MPSGraph Sampler Protocol

/// Protocol for GPU-based token samplers using MPSGraph.
///
/// Both argmax (greedy) and TopK (probabilistic) samplers conform to this protocol,
/// enabling a single sampler to be selected at engine init time based on configuration.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
protocol MPSGraphSampler: AnyObject, Sendable {
    /// The vocabulary size this sampler was compiled for
    var vocabSize: Int { get }

    /// Encode sampling for single-token decode.
    ///
    /// - Parameters:
    ///   - queue: The command queue
    ///   - logitsBuffer: MTLBuffer containing Float16 logits
    ///   - logitsOffset: Byte offset to the target token's logits
    ///   - outputBuffer: MTLBuffer to write the Int32 result
    ///   - outputOffset: Byte offset for the output
    ///   - completion: Called with the sampled token when GPU completes
    func encode(
        to queue: MTLCommandQueue,
        logitsBuffer: MTLBuffer,
        logitsOffset: Int,
        outputBuffer: MTLBuffer,
        outputOffset: Int,
        completion: @escaping (Int32) -> Void
    )

    /// Encode sampling with slice support for prefill.
    ///
    /// - Parameters:
    ///   - queue: The command queue
    ///   - logitsBuffer: Full logits buffer [1, queryLen, vocabSize]
    ///   - queryLength: Number of tokens in the query
    ///   - outputBuffer: Where to write the result
    ///   - outputOffset: Byte offset in output buffer
    ///   - completion: Called with sampled token
    func encodeWithSlice(
        to queue: MTLCommandQueue,
        logitsBuffer: MTLBuffer,
        queryLength: Int,
        outputBuffer: MTLBuffer,
        outputOffset: Int,
        completion: @escaping (Int32) -> Void
    )
}

// MARK: - Sampler Factory

/// Factory for creating the appropriate MPSGraph sampler based on configuration.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
enum MPSGraphSamplerFactory {
    /// Create a sampler appropriate for the given sampling configuration.
    ///
    /// - Parameters:
    ///   - device: Metal device
    ///   - vocabSize: Vocabulary size
    ///   - config: Sampling configuration (temperature determines sampler type)
    /// - Returns: An MPSGraphSampler instance
    ///
    /// Selection logic:
    /// - temperature == 0: Returns argmax sampler (greedy, deterministic)
    /// - temperature > 0: Returns TopK sampler (probabilistic)
    static func makeSampler(
        device: MTLDevice,
        vocabSize: Int,
        temperature: Double
    ) throws -> any MPSGraphSampler {
        if temperature == 0 {
            return try MPSGraphArgmaxSampler(device: device, vocabSize: vocabSize)
        } else {
            return try MPSGraphTopKSampler(
                device: device,
                vocabSize: vocabSize,
                k: 40,
                temperature: Float(temperature)
            )
        }
    }
}

// MARK: - MPSGraph Argmax Sampler

/// MPSGraph-based argmax sampler using Apple's optimized reductionArgMaximum.
///
/// This sampler builds an MPSGraph with argmax operation at init time and uses
/// `runAsync` with completion handlers for non-blocking sampling.
///
/// ## Usage with Core AI's ComputeStream
/// ```swift
/// computeStream.withMetal3Queue { queue in
///     mpsGraphSampler.encode(
///         to: queue,
///         logitsBuffer: logitsBuffer,
///         vocabSize: vocabSize,
///         queryLength: 1,
///         outputBuffer: tokenBuffer,
///         completion: { token in
///             continuation.yield(token)
///         }
///     )
/// }
/// ```
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
final class MPSGraphArgmaxSampler: @unchecked Sendable {
    private let device: MTLDevice
    private let mpsDevice: MPSGraphDevice
    private let graph: MPSGraph
    private let inputPlaceholder: MPSGraphTensor
    private let outputTensor: MPSGraphTensor
    private let executable: MPSGraphExecutable

    /// The vocabulary size this sampler was compiled for
    let vocabSize: Int

    // Pre-allocated objects reused every step to avoid ~70µs of CPU object creation.
    // MPSGraphTensorData wraps MTLBuffer references — safe to reuse when buffers match.
    private var cachedInputData: MPSGraphTensorData?
    private var cachedOutputData: MPSGraphTensorData?
    private var cachedInputBuffer: MTLBuffer?
    private var cachedOutputBuffer: MTLBuffer?

    /// Initialize the MPSGraph argmax sampler.
    /// - Parameters:
    ///   - device: Metal device
    ///   - vocabSize: Vocabulary size (fixed for compilation)
    init(device: MTLDevice, vocabSize: Int) throws {
        self.device = device
        self.mpsDevice = MPSGraphDevice(mtlDevice: device)
        self.vocabSize = vocabSize

        // Build the argmax graph
        let graph = MPSGraph()
        self.graph = graph

        // Input: logits for a single token position [1, vocabSize] as Float16
        // Match MPSGraphInferenceEngine pattern: [1, vocabSize] with axis 1 reduction
        let inputPlaceholder = graph.placeholder(
            shape: [1, vocabSize as NSNumber],
            dataType: .float16,
            name: "logits"
        )
        self.inputPlaceholder = inputPlaceholder

        // Argmax along axis 1 (vocab dimension) - returns Int64
        // No reshape needed! Just reduce along the vocab dimension.
        let argmaxInt64 = graph.reductionArgMaximum(
            with: inputPlaceholder,
            axis: 1,  // axis 1 = vocab dimension in [1, vocabSize]
            name: "argmax"
        )

        // Cast to Int32 for token ID
        let outputTensor = graph.cast(
            argmaxInt64,
            to: .int32,
            name: "token_id"
        )
        self.outputTensor = outputTensor

        // Compile to executable
        let feeds: [MPSGraphTensor: MPSGraphShapedType] = [
            inputPlaceholder: MPSGraphShapedType(
                shape: [1, vocabSize as NSNumber],
                dataType: .float16
            )
        ]

        let targetTensors = [outputTensor]

        let compilationDescriptor = MPSGraphCompilationDescriptor()
        // Enable optimizations
        compilationDescriptor.optimizationLevel = .level0

        self.executable = graph.compile(
            with: mpsDevice,
            feeds: feeds,
            targetTensors: targetTensors,
            targetOperations: nil,
            compilationDescriptor: compilationDescriptor
        )
    }

    /// Encode argmax sampling.
    ///
    /// This method uses MPSGraph's runAsync with a completion handler,
    /// providing non-blocking execution similar to our custom Metal kernel approach.
    ///
    /// - Parameters:
    ///   - queue: The command queue (from Core AI's ComputeStream via withMetal3Queue)
    ///   - logitsBuffer: MTLBuffer containing Float16 logits [1, queryLen, vocabSize]
    ///   - logitsOffset: Byte offset to the target token's logits
    ///   - outputBuffer: MTLBuffer to write the Int32 result
    ///   - outputOffset: Byte offset for the output
    ///   - completion: Called with the sampled token when GPU completes
    func encode(
        to queue: MTLCommandQueue,
        logitsBuffer: MTLBuffer,
        logitsOffset: Int,
        outputBuffer: MTLBuffer,
        outputOffset: Int,
        completion: @escaping (Int32) -> Void
    ) {
        // Reuse MPSGraphTensorData if buffers haven't changed (avoids object creation overhead)
        let inputData: MPSGraphTensorData
        if logitsBuffer === cachedInputBuffer, let cached = cachedInputData {
            inputData = cached
        } else {
            inputData = MPSGraphTensorData(
                logitsBuffer,
                shape: [1, vocabSize as NSNumber],
                dataType: .float16
            )
            cachedInputData = inputData
            cachedInputBuffer = logitsBuffer
        }

        let outputData: MPSGraphTensorData
        if outputBuffer === cachedOutputBuffer, let cached = cachedOutputData {
            outputData = cached
        } else {
            outputData = MPSGraphTensorData(
                outputBuffer,
                shape: [1 as NSNumber],
                dataType: .int32
            )
            cachedOutputData = outputData
            cachedOutputBuffer = outputBuffer
        }

        // Reuse pre-allocated execution descriptor, update completion handler
        let execDescriptor = MPSGraphExecutableExecutionDescriptor()
        execDescriptor.completionHandler = { [outputBuffer, outputOffset] (resultsDictionary, error) in
            if let error = error {
                print("MPSGraph argmax error: \(error)")
                completion(0)
                return
            }

            // Read result from output buffer
            let result = outputBuffer.contents()
                .advanced(by: outputOffset)
                .assumingMemoryBound(to: Int32.self)
                .pointee
            completion(result)
        }

        executable.runAsync(
            with: queue,
            inputs: [inputData],
            results: [outputData],
            executionDescriptor: execDescriptor
        )
    }

    /// Encode argmax sampling with offset support.
    ///
    /// This version handles the logits offset by using a separate command buffer
    /// and copying the relevant slice to a temporary buffer if needed.
    ///
    /// - Parameters:
    ///   - queue: The command queue
    ///   - logitsBuffer: Full logits buffer [1, queryLen, vocabSize]
    ///   - queryLength: Number of tokens in the query
    ///   - outputBuffer: Where to write the result
    ///   - outputOffset: Byte offset in output buffer
    ///   - completion: Called with sampled token
    func encodeWithSlice(
        to queue: MTLCommandQueue,
        logitsBuffer: MTLBuffer,
        queryLength: Int,
        outputBuffer: MTLBuffer,
        outputOffset: Int,
        completion: @escaping (Int32) -> Void
    ) {
        // Calculate offset to last token's logits
        let logitsOffset = (queryLength - 1) * vocabSize * MemoryLayout<UInt16>.size

        // For single-token decode (queryLength = 1), offset is 0 and we can use direct binding
        if queryLength == 1 {
            encode(
                to: queue,
                logitsBuffer: logitsBuffer,
                logitsOffset: 0,
                outputBuffer: outputBuffer,
                outputOffset: outputOffset,
                completion: completion
            )
            return
        }

        // For multi-token (prefill), we need to handle the offset
        // Pattern: Commit blit separately, then use runAsync for sampling
        // This avoids the issue where encode() to MPSCommandBuffer commits internally

        // Create a temporary buffer for the single token's logits
        let sliceSize = vocabSize * MemoryLayout<UInt16>.size
        guard let tempBuffer = device.makeBuffer(length: sliceSize, options: .storageModeShared) else {
            completion(0)
            return
        }

        // Step 1: Create and commit blit command buffer separately
        guard let blitCmdBuffer = queue.makeCommandBuffer() else {
            completion(0)
            return
        }
        blitCmdBuffer.label = "MPSGraph Argmax Blit"

        guard let blitEncoder = blitCmdBuffer.makeBlitCommandEncoder() else {
            completion(0)
            return
        }
        blitEncoder.copy(
            from: logitsBuffer,
            sourceOffset: logitsOffset,
            to: tempBuffer,
            destinationOffset: 0,
            size: sliceSize
        )
        blitEncoder.endEncoding()
        blitCmdBuffer.commit()  // Commit blit immediately (GPU will order operations)

        // Step 2: Use runAsync for sampling (executes after blit due to GPU queue ordering)
        let inputData = MPSGraphTensorData(
            tempBuffer,
            shape: [1, vocabSize as NSNumber],
            dataType: .float16
        )

        let outputData = MPSGraphTensorData(
            outputBuffer,
            shape: [1 as NSNumber],
            dataType: .int32
        )

        // Set up execution descriptor with completion handler
        let execDescriptor = MPSGraphExecutableExecutionDescriptor()
        execDescriptor.completionHandler = { [outputBuffer, outputOffset] (_, error) in
            if let error = error {
                print("MPSGraph argmax error: \(error)")
                completion(0)
                return
            }

            let result = outputBuffer.contents()
                .advanced(by: outputOffset)
                .assumingMemoryBound(to: Int32.self)
                .pointee
            completion(result)
        }

        // Run async - GPU naturally orders this after the blit due to queue ordering
        executable.runAsync(
            with: queue,
            inputs: [inputData],
            results: [outputData],
            executionDescriptor: execDescriptor
        )
    }
}

// Conformance to MPSGraphSampler protocol
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension MPSGraphArgmaxSampler: MPSGraphSampler {}

// MARK: - MPSGraph Top-K Sampler

/// MPSGraph-based Top-K sampler with temperature scaling.
///
/// This sampler uses Apple's optimized `topK` operation combined with softmax
/// for probabilistic token sampling. Unlike greedy argmax, this enables:
/// - Temperature-controlled randomness
/// - Top-K filtering for quality/diversity tradeoff
///
/// ## Sampling Algorithm
/// 1. Extract Top-K logits and indices
/// 2. Apply temperature scaling: logits / temperature
/// 3. Apply softmax to get probabilities
/// 4. Sample using multinomial (cumsum + random comparison)
///
/// ## Usage with Core AI's ComputeStream
/// ```swift
/// computeStream.withMetal3Queue { queue in
///     topKSampler.encode(
///         to: queue,
///         logitsBuffer: logitsBuffer,
///         temperature: 0.7,
///         outputBuffer: tokenBuffer,
///         completion: { token in
///             continuation.yield(token)
///         }
///     )
/// }
/// ```
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
final class MPSGraphTopKSampler: @unchecked Sendable {
    private let device: MTLDevice
    private let mpsDevice: MPSGraphDevice
    private let graph: MPSGraph

    // Graph tensors
    private let logitsPlaceholder: MPSGraphTensor
    private let temperaturePlaceholder: MPSGraphTensor
    private let randomPlaceholder: MPSGraphTensor
    private let outputTensor: MPSGraphTensor

    private let executable: MPSGraphExecutable

    /// The vocabulary size this sampler was compiled for
    let vocabSize: Int

    /// The K value (number of top tokens to consider)
    let k: Int

    /// The temperature this sampler was configured with
    let temperature: Float

    /// Pre-allocated buffer for random value
    private let randomBuffer: MTLBuffer

    /// Pre-allocated buffer for temperature
    private let temperatureBuffer: MTLBuffer

    // Pre-allocated objects reused every step to avoid CPU object creation overhead.
    private var cachedLogitsData: MPSGraphTensorData?
    private var cachedOutputData: MPSGraphTensorData?
    private var cachedLogitsBuffer: MTLBuffer?
    private var cachedOutputBuffer: MTLBuffer?
    private let temperatureData: MPSGraphTensorData
    private let randomData: MPSGraphTensorData
    private let execDescriptor: MPSGraphExecutableExecutionDescriptor

    /// Testing only: Override random value for deterministic tests.
    /// When set, this value is used instead of generating a random number.
    /// Set to nil for production use.
    var testingOnlyRandomOverride: Float?

    /// Initialize the MPSGraph Top-K sampler.
    /// - Parameters:
    ///   - device: Metal device
    ///   - vocabSize: Vocabulary size (fixed for compilation)
    ///   - k: Number of top tokens to sample from (default: 40)
    ///   - temperature: Sampling temperature (default: 1.0)
    init(device: MTLDevice, vocabSize: Int, k: Int = 40, temperature: Float = 1.0) throws {
        self.device = device
        self.mpsDevice = MPSGraphDevice(mtlDevice: device)
        self.vocabSize = vocabSize
        self.k = k

        // Pre-allocate buffers
        guard let randomBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared),
            let temperatureBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared)
        else {
            throw MPSGraphSamplerError.bufferAllocationFailed
        }
        self.temperature = temperature
        self.randomBuffer = randomBuffer
        self.temperatureBuffer = temperatureBuffer

        // Build the Top-K sampling graph
        let graph = MPSGraph()
        self.graph = graph

        // Input: logits for a single token position [1, vocabSize] as Float16
        let logitsPlaceholder = graph.placeholder(
            shape: [1, vocabSize as NSNumber],
            dataType: .float16,
            name: "logits"
        )
        self.logitsPlaceholder = logitsPlaceholder

        // Temperature scalar [1]
        let temperaturePlaceholder = graph.placeholder(
            shape: [1 as NSNumber],
            dataType: .float32,
            name: "temperature"
        )
        self.temperaturePlaceholder = temperaturePlaceholder

        // Random value for sampling [1]
        let randomPlaceholder = graph.placeholder(
            shape: [1 as NSNumber],
            dataType: .float32,
            name: "random"
        )
        self.randomPlaceholder = randomPlaceholder

        // Cast logits to Float32 for numerical stability
        let logitsFloat32 = graph.cast(logitsPlaceholder, to: .float32, name: "logits_f32")

        // Get Top-K values and indices
        // topK returns a tuple: (values: [1, k], indices: [1, k])
        let topKResult = graph.topK(logitsFloat32, k: k, name: "topk")
        let topKValues = topKResult[0]  // [1, k]
        let topKIndices = topKResult[1]  // [1, k] as Int32

        // Apply temperature: values / temperature
        // Broadcast temperature to match shape
        let scaledValues = graph.division(topKValues, temperaturePlaceholder, name: "scaled")

        // Softmax over the K dimension (axis 1)
        let probabilities = graph.softMax(with: scaledValues, axis: 1, name: "probs")

        // Multinomial sampling via cumulative sum + random comparison
        // cumsum: [1, k] where each element is sum of probs up to that point
        let cumsum = graph.cumulativeSum(probabilities, axis: 1, exclusive: false, reverse: false, name: "cumsum")

        // Compare: cumsum >= random (broadcast random across k dimension)
        // This gives us a boolean mask where True means "this token or later"
        let randomBroadcast = graph.broadcast(randomPlaceholder, shape: [1, k as NSNumber], name: "random_broadcast")
        let mask = graph.greaterThanOrEqualTo(cumsum, randomBroadcast, name: "mask")

        // Convert mask to float and use argmax to find first True
        let maskFloat = graph.cast(mask, to: .float32, name: "mask_float")
        let selectedIdx = graph.reductionArgMaximum(with: maskFloat, axis: 1, name: "selected_idx")

        // Gather the token index from topKIndices using selectedIdx
        // selectedIdx is [1] with value 0..k-1
        // We need to index into topKIndices[0, selectedIdx] to get the actual token ID
        let selectedIdxInt32 = graph.cast(selectedIdx, to: .int32, name: "selected_idx_i32")

        // Flatten topKIndices to [k] and use gatherElements
        let indicesFlat = graph.reshape(topKIndices, shape: [k as NSNumber], name: "indices_flat")
        let selectedIdxFlat = graph.reshape(selectedIdxInt32, shape: [1 as NSNumber], name: "selected_flat")

        // Gather the actual token ID
        let outputTensor = graph.gatherAlongAxis(
            0,
            updates: indicesFlat,
            indices: selectedIdxFlat,
            name: "token_id"
        )
        self.outputTensor = outputTensor

        // Compile to executable
        let feeds: [MPSGraphTensor: MPSGraphShapedType] = [
            logitsPlaceholder: MPSGraphShapedType(shape: [1, vocabSize as NSNumber], dataType: .float16),
            temperaturePlaceholder: MPSGraphShapedType(shape: [1 as NSNumber], dataType: .float32),
            randomPlaceholder: MPSGraphShapedType(shape: [1 as NSNumber], dataType: .float32),
        ]

        let compilationDescriptor = MPSGraphCompilationDescriptor()
        compilationDescriptor.optimizationLevel = .level0

        self.executable = graph.compile(
            with: mpsDevice,
            feeds: feeds,
            targetTensors: [outputTensor],
            targetOperations: nil,
            compilationDescriptor: compilationDescriptor
        )

        // Pre-allocate tensor data for temperature and random buffers (never change)
        self.temperatureData = MPSGraphTensorData(
            temperatureBuffer,
            shape: [1 as NSNumber],
            dataType: .float32
        )
        self.randomData = MPSGraphTensorData(
            randomBuffer,
            shape: [1 as NSNumber],
            dataType: .float32
        )
        self.execDescriptor = MPSGraphExecutableExecutionDescriptor()
    }

    /// Encode Top-K sampling asynchronously (protocol conformance).
    ///
    /// Uses the temperature configured at init time.
    func encode(
        to queue: MTLCommandQueue,
        logitsBuffer: MTLBuffer,
        logitsOffset: Int,
        outputBuffer: MTLBuffer,
        outputOffset: Int,
        completion: @escaping (Int32) -> Void
    ) {
        // Write temperature to buffer (use configured temperature)
        temperatureBuffer.contents().assumingMemoryBound(to: Float.self).pointee = max(temperature, 0.01)

        // Use override if set (for testing), otherwise generate random value [0, 1)
        let randomValue = testingOnlyRandomOverride ?? Float.random(in: 0..<1)
        randomBuffer.contents().assumingMemoryBound(to: Float.self).pointee = randomValue

        // Reuse MPSGraphTensorData if buffers haven't changed
        let logitsData: MPSGraphTensorData
        if logitsBuffer === cachedLogitsBuffer, let cached = cachedLogitsData {
            logitsData = cached
        } else {
            logitsData = MPSGraphTensorData(
                logitsBuffer,
                shape: [1, vocabSize as NSNumber],
                dataType: .float16
            )
            cachedLogitsData = logitsData
            cachedLogitsBuffer = logitsBuffer
        }

        let outputData: MPSGraphTensorData
        if outputBuffer === cachedOutputBuffer, let cached = cachedOutputData {
            outputData = cached
        } else {
            outputData = MPSGraphTensorData(
                outputBuffer,
                shape: [1 as NSNumber],
                dataType: .int32
            )
            cachedOutputData = outputData
            cachedOutputBuffer = outputBuffer
        }

        // Reuse pre-allocated execution descriptor, update completion handler
        execDescriptor.completionHandler = { [outputBuffer, outputOffset] (_, error) in
            if let error = error {
                print("MPSGraph Top-K error: \(error)")
                completion(0)
                return
            }

            let result = outputBuffer.contents()
                .advanced(by: outputOffset)
                .assumingMemoryBound(to: Int32.self)
                .pointee
            completion(result)
        }

        // Run async — temperatureData and randomData are pre-allocated, buffer contents updated above
        executable.runAsync(
            with: queue,
            inputs: [logitsData, temperatureData, randomData],
            results: [outputData],
            executionDescriptor: execDescriptor
        )
    }

    /// Encode Top-K sampling with slice support for prefill scenarios (protocol conformance).
    ///
    /// Uses the temperature configured at init time.
    func encodeWithSlice(
        to queue: MTLCommandQueue,
        logitsBuffer: MTLBuffer,
        queryLength: Int,
        outputBuffer: MTLBuffer,
        outputOffset: Int,
        completion: @escaping (Int32) -> Void
    ) {
        // For single-token decode, use direct encoding
        if queryLength == 1 {
            encode(
                to: queue,
                logitsBuffer: logitsBuffer,
                logitsOffset: 0,
                outputBuffer: outputBuffer,
                outputOffset: outputOffset,
                completion: completion
            )
            return
        }

        // For multi-token (prefill), we need to handle the offset
        // Pattern: Commit blit separately, then use runAsync for sampling
        // This avoids the issue where encode() to MPSCommandBuffer commits internally

        let logitsOffset = (queryLength - 1) * vocabSize * MemoryLayout<UInt16>.size
        let sliceSize = vocabSize * MemoryLayout<UInt16>.size

        // Create a temporary buffer for the single token's logits
        guard let tempBuffer = device.makeBuffer(length: sliceSize, options: .storageModeShared) else {
            completion(0)
            return
        }

        // Step 1: Create and commit blit command buffer separately
        guard let blitCmdBuffer = queue.makeCommandBuffer() else {
            completion(0)
            return
        }
        blitCmdBuffer.label = "MPSGraph Top-K Blit"

        guard let blitEncoder = blitCmdBuffer.makeBlitCommandEncoder() else {
            completion(0)
            return
        }
        blitEncoder.copy(
            from: logitsBuffer,
            sourceOffset: logitsOffset,
            to: tempBuffer,
            destinationOffset: 0,
            size: sliceSize
        )
        blitEncoder.endEncoding()
        blitCmdBuffer.commit()  // Commit blit immediately (GPU will order operations)

        // Step 2: Use runAsync for sampling (executes after blit due to GPU queue ordering)
        // Write temperature and random to buffers (use configured temperature)
        temperatureBuffer.contents().assumingMemoryBound(to: Float.self).pointee = max(self.temperature, 0.01)
        let randomValue = testingOnlyRandomOverride ?? Float.random(in: 0..<1)
        randomBuffer.contents().assumingMemoryBound(to: Float.self).pointee = randomValue

        // Create tensor data (tempBuffer is unique per prefill call, can't cache)
        let logitsData = MPSGraphTensorData(tempBuffer, shape: [1, vocabSize as NSNumber], dataType: .float16)
        let outputData = MPSGraphTensorData(outputBuffer, shape: [1 as NSNumber], dataType: .int32)

        // Use a separate execution descriptor for prefill
        let prefillExecDescriptor = MPSGraphExecutableExecutionDescriptor()
        prefillExecDescriptor.completionHandler = { [outputBuffer, outputOffset] (_, error) in
            if let error = error {
                print("MPSGraph Top-K error: \(error)")
                completion(0)
                return
            }

            let result = outputBuffer.contents()
                .advanced(by: outputOffset)
                .assumingMemoryBound(to: Int32.self)
                .pointee
            completion(result)
        }

        // Run async - GPU naturally orders this after the blit due to queue ordering
        executable.runAsync(
            with: queue,
            inputs: [logitsData, temperatureData, randomData],
            results: [outputData],
            executionDescriptor: prefillExecDescriptor
        )
    }
}

// Conformance to MPSGraphSampler protocol
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
extension MPSGraphTopKSampler: MPSGraphSampler {}

// MARK: - Errors

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
enum MPSGraphSamplerError: Error {
    case bufferAllocationFailed
    case graphCompilationFailed
    case unsupportedDevice
}

#endif  // canImport(CoreAI)
