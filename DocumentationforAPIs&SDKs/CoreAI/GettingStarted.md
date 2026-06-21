# Integrating on-device AI models in your app with Core AI

Load, specialize, and run inference on `.aimodel` files using Apple's Core AI framework.

Source: https://developer.apple.com/documentation/coreai/integrating-on-device-ai-models-in-your-app-with-core-ai

Availability: iOS 27.0+ Beta, iPadOS 27.0+, Mac Catalyst 27.0+, tvOS 27.0+, visionOS 27.0+

## Overview

Core AI processes inference locally on-device, which:
* Preserves user privacy — no data leaves the device
* Enables offline functionality
* Eliminates per-inference costs

The workflow is: get an `.aimodel` file → add to Xcode → load → specialize → get an `InferenceFunction` → run inference.

## Prerequisites

**Install the Metal Toolchain** — builds that include `.aimodel` files fail with a missing Metal compiler error if this component isn't installed:

```
Xcode → Settings → Components → Metal Toolchain → Install
```

Or via command line:
```shell
xcodebuild -downloadComponent MetalToolchain
```

## Step 1: Add the Model to Your Project

Drag the `.aimodel` file into Xcode's Project Navigator, or use File > Add Files. Make sure to check the appropriate target(s).

Xcode's model viewer will then show parameter counts, storage sizes, metadata, numeric precision details, and function signatures — inspect these before writing any code.

## Step 2: Load the Model

`AIModel` instances are lightweight — they don't store weights or intermediate buffers. Loading triggers device-specific specialization (compilation for the current hardware):

```swift
import CoreAI

let modelURL = Bundle.main.url(forResource: "MyModel", withExtension: "aimodel")!

// Asynchronous — specialization happens here
let model = try await AIModel(contentsOf: modelURL, options: .default)
```

To avoid re-specializing on every launch, use caching (see `SpecializationAndCaching.md`).

## Step 3: Load an Inference Function

Most models expose a single inference function:

```swift
// Most models have one function — check descriptor for the name
print(model.functionNames)  // e.g., ["main", "encode", "decode"]

let function = try await model.loadFunction(named: "main")
```

The function holds all model weights and intermediate buffers. It conforms to `Sendable`, so you can call it concurrently from multiple tasks — the framework allocates extra buffers to support this.

## Step 4: Prepare Inputs

Inputs are `InferenceValue` instances wrapping either an `NDArray` or a pixel buffer (`CVPixelBuffer`).

### Tensor (NDArray) input

```swift
// Create a float32 tensor of shape [1, 3, 224, 224] (batch × channels × H × W)
var input = NDArray(shape: [1, 3, 224, 224], scalarType: .float32)

// Write data via a mutable typed view
input.mutableView(as: Float.self).withUnsafeMutableBufferPointer { buffer in
    // Fill buffer with your normalized pixel values
    fillPixelData(into: buffer)
}

let inputs = InferenceFunction.Inputs(["input": InferenceValue(input)])
```

### Pixel buffer input

```swift
// If the model accepts a CVPixelBuffer directly
let pixelBuffer: CVPixelBuffer = // ... your image
let inputs = InferenceFunction.Inputs(["image": InferenceValue(pixelBuffer)])
```

## Step 5: Allocate Outputs and Run

```swift
// Allocate output tensor matching the model's expected output shape
// (use functionDescriptor to discover shape at runtime)
let descriptor = model.functionDescriptor(for: "main")
let outputDesc = descriptor.outputDescriptor(of: "logits")
var output = NDArray(descriptor: outputDesc.ndArrayDescriptor!)

var outputViews = InferenceFunction.MutableViews(["logits": output.mutableView()])

// Synchronous inference
try function.run(
    inputs: inputs,
    states: .init(),
    outputViews: &outputViews
)

// Read result
let result = output.view(as: Float.self)
```

## Step 6: Inspect the Descriptor (Optional)

Use `InferenceFunctionDescriptor` to discover input/output names and shapes at runtime instead of hardcoding them:

```swift
let desc = function.descriptor

print("Inputs:", desc.inputNames)
print("Outputs:", desc.outputNames)

for name in desc.inputNames {
    let inputDesc = desc.inputDescriptor(of: name)
    print("  \(name):", inputDesc)
}
```

## Async / GPU Inference

For GPU-accelerated inference with a `MTLCommandQueue`, use `encode(inputs:states:outputViews:to:)`:

```swift
let stream = ComputeStream(commandQueue: metalCommandQueue)

let asyncOutputs = try function.encode(
    inputs: inputs,
    states: .init(),
    outputViews: &outputViews,
    to: stream
)

// Do other GPU work here, then wait
stream.currentWorkCompleted()
```

## NDArray Scalar Types

Core AI supports 40+ scalar types. Common ones:

| Type | `NDArray.ScalarType` |
|------|---------------------|
| 32-bit float | `.float32` |
| 16-bit float | `.float16` |
| Brain float 16 | `.bfloat16` |
| 8-bit int | `.int8` |
| 4-bit uint (quantized) | `.uint4` |

## Full Example: Image Classifier

```swift
import CoreAI
import CoreVideo

func classify(pixelBuffer: CVPixelBuffer) async throws -> [Float] {
    let modelURL = Bundle.main.url(forResource: "Classifier", withExtension: "aimodel")!

    // Use cache to avoid re-specializing
    let model: AIModel
    if let cached = try AIModelCache.default.model(for: modelURL, options: .default) {
        model = cached
    } else {
        model = try await AIModel(contentsOf: modelURL, options: .default)
    }

    let function = try await model.loadFunction(named: "main")

    let inputs = InferenceFunction.Inputs(["image": InferenceValue(pixelBuffer)])

    var output = NDArray(shape: [1, 1000], scalarType: .float32)
    var outputViews = InferenceFunction.MutableViews(["logits": output.mutableView()])

    try function.run(inputs: inputs, states: .init(), outputViews: &outputViews)

    return Array(output.view(as: Float.self))
}
```

## Related

* Managing model specialization and caching
  [https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching](https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching)
* Compiling Core AI models ahead of time
  [https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time](https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time)
* `AIModel`
  [https://developer.apple.com/documentation/coreai/aimodel](https://developer.apple.com/documentation/coreai/aimodel)
* `InferenceFunction`
  [https://developer.apple.com/documentation/coreai/inferencefunction](https://developer.apple.com/documentation/coreai/inferencefunction)
* `NDArray`
  [https://developer.apple.com/documentation/coreai/ndarray](https://developer.apple.com/documentation/coreai/ndarray)
