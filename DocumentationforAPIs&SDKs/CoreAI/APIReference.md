# Core AI API Reference

Quick reference for all Core AI types, with descriptions and availability.

Source: https://developer.apple.com/documentation/coreai

All APIs: iOS 27.0+ Beta, iPadOS 27.0+, Mac Catalyst 27.0+, tvOS 27.0+, visionOS 27.0+

---

## AIModel

```swift
struct AIModel: Sendable, SendableMetatype
```

A specialized `.aimodel` asset for running inference on a device. Lightweight — does not store weights or intermediate buffers (those live in `InferenceFunction`).

**Key init:**
```swift
init(contentsOf url: URL, options: SpecializationOptions) async throws
init(resolvingBookmark data: Data) throws  // load from cache without original .aimodel
```

**Key methods:**
```swift
func loadFunction(named name: String) async throws -> InferenceFunction
func functionDescriptor(for name: String) -> InferenceFunctionDescriptor
var functionNames: [String]
static func specialize(contentsOf:options:cache:cachePolicy:) async throws -> AIModel
var bookmarkData: Data
static var deviceArchitectureName: String  // e.g. "apple_a18_pro"
```

---

## AIModelAsset

```swift
struct AIModelAsset
```

Inspect model metadata without specializing (which is expensive). Use to validate an `.aimodel` file before committing to loading it.

**Key init:**
```swift
init(contentsOf url: URL) throws
static func isValid(at url: URL) -> Bool
```

**Key members:**
```swift
var metadata: Metadata
func summary(includingStatistics: Bool) throws -> Summary?
var url: URL
func updateMetadata(_ metadata: Metadata) throws
func removeDerivedArtifacts() throws
```

**Supporting types:** `AIModelAsset.FunctionDescriptor`, `AIModelAsset.Metadata`, `AIModelAsset.Summary`, `AIModelAsset.ValueDescriptor`

---

## AIModelCache

```swift
class AIModelCache: Sendable, SendableMetatype
```

Stores specialized model artifacts so they don't need to be re-compiled on every launch.

**Access:**
```swift
static var default: AIModelCache
init(appGroup: String)  // share across app suite
```

**Retrieval:**
```swift
func model(for url: URL, options: SpecializationOptions) throws -> AIModel?
```

**Deletion:**
```swift
func deleteEntries(for url: URL) throws
func deleteEntry(for url: URL, options: SpecializationOptions) throws
func deleteEntry(referencedBy bookmarkData: Data) throws
func deleteAll() throws  // removes all entries for current build version
```

---

## SpecializationOptions

```swift
struct SpecializationOptions: Equatable, Hashable, Sendable, SendableMetatype
```

Configure which compute units are used during specialization.

**Presets:**
```swift
static var `default`: SpecializationOptions  // all available compute units
static var cpuOnly: SpecializationOptions    // CPU only
```

**Custom:**
```swift
init(preferredComputeUnitKind: ComputeUnitKind)
```

**Properties:**
```swift
var allowedComputeUnitKinds: Set<ComputeUnitKind>
var preferredComputeUnitKind: ComputeUnitKind?
var expectFrequentReshapes: Bool  // optimize for variable-length models
```

---

## ComputeUnitKind

```swift
enum ComputeUnitKind: Equatable, Hashable, Sendable, SendableMetatype
```

Hardware compute unit available for model inference.

**Cases:**
```swift
case cpu           // Central Processing Unit
case gpu           // Graphics Processing Unit
case neuralEngine  // Apple Neural Engine
```

**Property:**
```swift
static var availableKinds: Set<ComputeUnitKind>  // available on current device
```

---

## InferenceFunction

```swift
struct InferenceFunction: Sendable
```

Executes inference. Holds all model weights and intermediate buffers. Conforms to `Sendable` — concurrent calls allocate extra buffers automatically.

**Synchronous:**
```swift
func run(
    inputs: Inputs,
    states: MutableViews,
    outputViews: inout MutableViews
) throws
```

**Async / GPU (via ComputeStream):**
```swift
func encode(
    inputs: Inputs,
    states: AsyncMutableViews,
    outputViews: inout AsyncMutableViews,
    to stream: ComputeStream
) throws -> AsyncOutputs
```

**Inspection:**
```swift
var descriptor: InferenceFunctionDescriptor
```

**Collection types:**
```swift
InferenceFunction.Inputs          // named input values
InferenceFunction.Outputs         // result values
InferenceFunction.MutableViews    // in-place updatable state refs
InferenceFunction.AsyncMutableViews
InferenceFunction.AsyncValue
InferenceFunction.AsyncMutableValue
```

---

## InferenceFunctionDescriptor

```swift
struct InferenceFunctionDescriptor: Sendable, SendableMetatype
```

Describes the signature of an inference function: names and descriptors for all inputs, outputs, and states.

```swift
var name: String
var inputNames: [String]
var outputNames: [String]
var stateNames: [String]
var inputCount: Int
var outputCount: Int

func inputDescriptor(of name: String) -> InferenceValue.Descriptor
func outputDescriptor(of name: String) -> InferenceValue.Descriptor
func stateDescriptor(of name: String) -> InferenceValue.Descriptor
```

Obtain via `model.functionDescriptor(for:)` or `function.descriptor`.

---

## InferenceValue

```swift
struct InferenceValue
```

Wraps either an `NDArray` or a `CVPixelBuffer` for use as inference input or output.

```swift
init(_ pixelBuffer: CVPixelBuffer)
var ndArray: NDArray?
var pixelBuffer: CVPixelBuffer?   // consumes the value
var kind: Kind                     // .ndArray or .pixelBuffer

// View types
InferenceValue.View
InferenceValue.MutableView
InferenceValue.NamedMutableViews
InferenceValue.Descriptor          // type + shape info
InferenceValue.Kind
```

---

## NDArray

```swift
struct NDArray: Sendable, SendableMetatype
    // also: InferenceValue.ViewRepresentable, InferenceValue.MutableViewRepresentable
```

A multidimensional array of scalar values. Data is described by shape, scalar type, and strides.

**Creating:**
```swift
init(shape: [Int], scalarType: NDArray.ScalarType)
init(shape: [Int], scalarType: NDArray.ScalarType, strides: [Int])
init(descriptor: NDArrayDescriptor)
```

**Inspecting:**
```swift
var shape: [Int]
var scalarType: NDArray.ScalarType
var strides: [Int]
```

**Accessing data:**
```swift
func view<T>(as type: T.Type) -> NDArray.View<T>          // read-only typed view
func mutableView<T>(as type: T.Type) -> NDArray.MutableView<T>  // writable typed view
func rawView() -> NDArray.RawView                          // type-erased read-only
func mutableRawView() -> NDArray.MutableRawView            // type-erased writable
```

**Common scalar types (`NDArray.ScalarType`):**

| Case | Bits | Use |
|------|------|-----|
| `.float32` | 32 | Standard float |
| `.float16` | 16 | Half precision |
| `.bfloat16` | 16 | Brain float (training-friendly) |
| `.int8` | 8 | Quantized signed |
| `.uint8` | 8 | Quantized unsigned / image pixels |
| `.int4` | 4 | Aggressive quantization |
| `.uint4` | 4 | Aggressive quantization |

---

## NDArrayDescriptor

```swift
struct NDArrayDescriptor
```

Describes shape and preferred strides for an `NDArray`. Obtain from `InferenceValue.Descriptor.ndArrayDescriptor` to allocate output tensors matching the model's expected shape.

---

## ImageDescriptor

```swift
struct ImageDescriptor: Equatable, Sendable, SendableMetatype
```

Describes an image input's dimensions and pixel format.

```swift
var width: Int
var height: Int
var pixelFormatType: OSType   // four-character code (e.g., kCVPixelFormatType_32BGRA)
```

---

## ComputeStream

```swift
class ComputeStream
```

A stream of work to be run asynchronously on GPU. Use with `encode(inputs:states:outputViews:to:)` to pipeline multiple inferences based on read/write dependencies.

```swift
init()                                      // empty stream
init(commandQueue: MTLCommandQueue)         // integrate with existing Metal pipeline

func currentWorkCompleted()                 // blocks until all encoded work finishes
```

---

## AssetError

```swift
enum AssetError
```

Errors thrown when loading or inspecting `.aimodel` / `.aimodelc` files.

Common cases: metadata corruption, duplicate function names, unsupported model version, invalid feature specification.
