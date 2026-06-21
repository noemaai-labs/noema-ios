# Compiling Core AI models ahead of time

Move the expensive model compilation step to your build machine to eliminate first-launch latency.

Source: https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time

## Overview

Core AI specialization has two phases:
1. **Compilation** — converts model operations into device-specific shader code (expensive, done once)
2. **Finalization** — links the compiled shaders for the exact device (fast, done at runtime)

Ahead-of-time (AOT) compilation moves phase 1 to your build machine using the `coreai-build` CLI tool. The result is a `.aimodelc` file that ships in your app bundle and loads ~10× faster than specializing at runtime.

## Prerequisites

Install the Metal Toolchain:

```shell
xcodebuild -downloadComponent MetalToolchain
```

Or via Xcode → Settings → Components → Metal Toolchain.

## Device Support

AOT compilation targets devices with Apple Intelligence support:
* iPhone or iPad with **A17 Pro chipset or later**
* Apple silicon Mac (M1+)

## Compilation with `coreai-build`

```shell
# Basic compilation for iOS
xcrun coreai-build compile MyModel.aimodel \
    --platform iOS \
    --output compiled/

# With preferred compute unit
xcrun coreai-build compile MyModel.aimodel \
    --platform iOS \
    --preferred-compute neuralEngine \
    --output compiled/

# See all options
xcrun coreai-build compile --help
```

Output files are named `MyModel.<arch>.aimodelc` — one per supported device architecture. Add all of them to your app bundle.

## Loading at Runtime

Query the current device architecture and load the matching compiled asset:

```swift
import CoreAI

let arch = AIModel.deviceArchitectureName
// e.g., "apple_a18_pro" or "apple_m4"

guard let assetURL = Bundle.main.url(
    forResource: "MyModel.\(arch)",
    withExtension: "aimodelc"
) else {
    // Fall back to runtime specialization from .aimodel
    let fallbackURL = Bundle.main.url(forResource: "MyModel", withExtension: "aimodel")!
    return try await AIModel(contentsOf: fallbackURL, options: .default)
}

// Loads nearly instantly — compilation is already done
let model = try await AIModel(contentsOf: assetURL, options: .default)
```

No other changes to your existing inference code are required.

## Integrating into Your Xcode Build

Add a Run Script build phase to compile models as part of your build:

```shell
# In Xcode: Build Phases → + → New Run Script Phase
for model in "${SRCROOT}/Models/"*.aimodel; do
    name=$(basename "$model" .aimodel)
    xcrun coreai-build compile "$model" \
        --platform iOS \
        --output "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/"
done
```

Or check in the pre-compiled `.aimodelc` files to your repo and reference them directly in Xcode's file targets.

## `.aimodel` vs `.aimodelc` in Your Bundle

| File | Contains | First Load |
|------|----------|------------|
| `.aimodel` | Portable weights + operations | Slow (full specialization) |
| `.aimodelc` | Pre-compiled shaders + weights | Fast (finalization only) |

Ship both when you need to support older devices that might not have a matching `.aimodelc`.

## Related

* Managing model specialization and caching
  [https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching](https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching)
* `AIModel.deviceArchitectureName`
  [https://developer.apple.com/documentation/coreai/aimodel/devicearchitecturename](https://developer.apple.com/documentation/coreai/aimodel/devicearchitecturename)
* `AIModelCache`
  [https://developer.apple.com/documentation/coreai/aimodelcache](https://developer.apple.com/documentation/coreai/aimodelcache)
* `SpecializationOptions`
  [https://developer.apple.com/documentation/coreai/specializationoptions](https://developer.apple.com/documentation/coreai/specializationoptions)
