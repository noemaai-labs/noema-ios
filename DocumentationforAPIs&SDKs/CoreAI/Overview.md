# Core AI

Run inference on custom `.aimodel` files directly on Apple silicon using hardware-accelerated compute.

Source: https://developer.apple.com/documentation/coreai

Availability: iOS 27.0+ Beta, iPadOS 27.0+, Mac Catalyst 27.0+, tvOS 27.0+, visionOS 27.0+

## Overview

Core AI is Apple's low-level inference framework for loading and running custom AI models on-device. Unlike the Foundation Models framework (which gives you access to Apple's built-in language model), Core AI lets you bring your own model as an `.aimodel` file and run it directly against CPU, GPU, and Neural Engine.

Key properties:
* **Privacy** — inference runs entirely on-device, no network required
* **Hardware acceleration** — dispatches work across CPU, GPU, and Neural Engine automatically
* **Specialization** — compiles a portable `.aimodel` into device-specific code for maximum performance
* **Low overhead** — `AIModel` instances are lightweight; weights live in `InferenceFunction`

## When to use Core AI vs. Foundation Models

| Need | Use |
|------|-----|
| On-device LLM (Apple Intelligence) | `FoundationModels` framework |
| PCC server-side LLM with reasoning | `FoundationModels` + `PrivateCloudComputeLanguageModel` |
| Your own custom `.aimodel` (vision, audio, embeddings, etc.) | **Core AI** |
| Existing Core ML model | `CoreML` framework |

## Topics

### Getting Started

* Integrating on-device AI models in your app with Core AI
  [https://developer.apple.com/documentation/coreai/integrating-on-device-ai-models-in-your-app-with-core-ai](https://developer.apple.com/documentation/coreai/integrating-on-device-ai-models-in-your-app-with-core-ai)

### Model Loading and Specialization

* Managing model specialization and caching
  [https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching](https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching)
* Compiling Core AI models ahead of time
  [https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time](https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time)
* `AIModel` (struct)
  [https://developer.apple.com/documentation/coreai/aimodel](https://developer.apple.com/documentation/coreai/aimodel)
* `AIModelAsset` (struct)
  [https://developer.apple.com/documentation/coreai/aimodelasset](https://developer.apple.com/documentation/coreai/aimodelasset)
* `AIModelCache` (class)
  [https://developer.apple.com/documentation/coreai/aimodelcache](https://developer.apple.com/documentation/coreai/aimodelcache)
* `SpecializationOptions` (struct)
  [https://developer.apple.com/documentation/coreai/specializationoptions](https://developer.apple.com/documentation/coreai/specializationoptions)
* `ComputeUnitKind` (enum)
  [https://developer.apple.com/documentation/coreai/computeunitkind](https://developer.apple.com/documentation/coreai/computeunitkind)

### Running Inference

* `InferenceFunction` (struct)
  [https://developer.apple.com/documentation/coreai/inferencefunction](https://developer.apple.com/documentation/coreai/inferencefunction)
* `InferenceFunctionDescriptor` (struct)
  [https://developer.apple.com/documentation/coreai/inferencefunctiondescriptor](https://developer.apple.com/documentation/coreai/inferencefunctiondescriptor)
* `InferenceValue` (struct)
  [https://developer.apple.com/documentation/coreai/inferencevalue](https://developer.apple.com/documentation/coreai/inferencevalue)
* `NDArray` (struct)
  [https://developer.apple.com/documentation/coreai/ndarray](https://developer.apple.com/documentation/coreai/ndarray)
* `NDArrayDescriptor` (struct)
  [https://developer.apple.com/documentation/coreai/ndarraydescriptor](https://developer.apple.com/documentation/coreai/ndarraydescriptor)
* `ImageDescriptor` (struct)
  [https://developer.apple.com/documentation/coreai/imagedescriptor](https://developer.apple.com/documentation/coreai/imagedescriptor)
* `ComputeStream` (class)
  [https://developer.apple.com/documentation/coreai/computestream](https://developer.apple.com/documentation/coreai/computestream)

### Debugging and Profiling

* Inspecting, debugging, and profiling Core AI models
  [https://developer.apple.com/documentation/coreai/inspecting-debugging-and-profiling-core-ai-models](https://developer.apple.com/documentation/coreai/inspecting-debugging-and-profiling-core-ai-models)
* Monitoring model performance with the debug gauge
  [https://developer.apple.com/documentation/coreai/monitoring-model-performance-with-the-debug-gauge](https://developer.apple.com/documentation/coreai/monitoring-model-performance-with-the-debug-gauge)
* Analyzing model runtime performance with Instruments
  [https://developer.apple.com/documentation/coreai/analyzing-model-runtime-performance-with-instruments](https://developer.apple.com/documentation/coreai/analyzing-model-runtime-performance-with-instruments)
* Inspecting Core AI models with Core AI Debugger
  [https://developer.apple.com/documentation/coreai/inspecting-core-ai-models-with-core-ai-debugger](https://developer.apple.com/documentation/coreai/inspecting-core-ai-models-with-core-ai-debugger)
* Validating inference correctness against a reference run
  [https://developer.apple.com/documentation/coreai/validating-inference-correctness-against-a-reference-run](https://developer.apple.com/documentation/coreai/validating-inference-correctness-against-a-reference-run)

### Errors

* `AssetError` (enum)
  [https://developer.apple.com/documentation/coreai/asseterror](https://developer.apple.com/documentation/coreai/asseterror)
