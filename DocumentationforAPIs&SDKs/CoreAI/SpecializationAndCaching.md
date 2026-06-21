# Managing model specialization and caching

Optimize `.aimodel` files for the current device and cache the result to eliminate repeated compilation.

Source: https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching

## Overview

Core AI **specialization** converts a portable `.aimodel` file into device-specific executable code, targeting the available CPU, GPU, and Neural Engine. This is the most expensive operation in the model lifecycle. The framework caches the result automatically so subsequent app launches load the pre-compiled version instantly.

## Default Behavior

When you call `AIModel(contentsOf:options:)`, specialization happens automatically and the result is stored in `AIModelCache.default`. On the next launch, the cache is checked first.

```swift
// This specializes on first run, loads from cache on subsequent runs
let model = try await AIModel(contentsOf: modelURL, options: .default)
```

## Explicitly Checking the Cache

Check the cache before loading to avoid the async specialization wait in your hot path:

```swift
let cache = AIModelCache.default

if let cachedModel = try cache.model(for: modelURL, options: .default) {
    // Instant — already specialized for this device
    return cachedModel
} else {
    // First launch: specialize and cache automatically
    return try await AIModel(contentsOf: modelURL, options: .default)
}
```

## SpecializationOptions

Configure which compute units are targeted:

```swift
// Default: use all available units (CPU + GPU + Neural Engine)
let model = try await AIModel(contentsOf: modelURL, options: .default)

// CPU only (useful for debugging or reproducibility)
let cpuModel = try await AIModel(contentsOf: modelURL, options: .cpuOnly)

// Prefer a specific unit (others still allowed as fallback)
let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
let neModel = try await AIModel(contentsOf: modelURL, options: options)
```

Check what's available on the current device:
```swift
let available = ComputeUnitKind.availableKinds
// e.g., [.cpu, .gpu, .neuralEngine] on iPhone with A17 Pro+
```

## Frequent Reshapes

If your model performs frequent tensor reshapes (e.g., variable-length sequence models), enable the optimization hint:

```swift
var options = SpecializationOptions.default
options.expectFrequentReshapes = true
let model = try await AIModel(contentsOf: modelURL, options: options)
```

## Pre-Specializing Before First Use

Specialize during a background task (e.g., on first launch) so the model is ready when the user needs it:

```swift
func preSpecializeIfNeeded(modelURL: URL) async {
    guard (try? AIModelCache.default.model(for: modelURL, options: .default)) == nil else {
        return  // already cached
    }

    // Specialize explicitly — result is stored in cache
    _ = try? await AIModel.specialize(
        contentsOf: modelURL,
        options: .default,
        cache: .default,
        cachePolicy: .default
    )
}
```

## Cache Policies

| Policy | Behavior |
|--------|----------|
| `.default` | System may evict cached assets under storage pressure |
| `.persistent` | Cached assets are not evicted automatically; useful when the source `.aimodel` is removed after caching |

```swift
_ = try await AIModel.specialize(
    contentsOf: modelURL,
    options: .default,
    cache: .default,
    cachePolicy: .persistent   // don't delete even if .aimodel is gone
)
```

## Bookmark-Based Loading

After specialization, save `model.bookmarkData` to reload from cache without the original `.aimodel` file:

```swift
// Save
let bookmark = model.bookmarkData
UserDefaults.standard.set(bookmark, forKey: "modelBookmark")

// Restore
if let savedBookmark = UserDefaults.standard.data(forKey: "modelBookmark") {
    let model = try AIModel(resolvingBookmark: savedBookmark)
}
```

## Sharing Across Apps via App Groups

Use `AIModelCache(appGroup:)` with a shared container to avoid specializing the same model in multiple apps in your suite:

```swift
// In your entitlements: com.apple.security.application-groups = ["group.com.example.suite"]
let sharedCache = AIModelCache(appGroup: "group.com.example.suite")

if let model = try sharedCache.model(for: modelURL, options: .default) {
    return model
}
let model = try await AIModel.specialize(
    contentsOf: modelURL,
    options: .default,
    cache: sharedCache,
    cachePolicy: .default
)
```

## Cache Cleanup

Remove stale entries when a model is updated or no longer needed:

```swift
let cache = AIModelCache.default

// Remove all cached versions of one model
try cache.deleteEntries(for: modelURL)

// Remove a specific model+options combination
try cache.deleteEntry(for: modelURL, options: .default)

// Nuke everything for the current build version
try cache.deleteAll()
```

## Related

* `AIModel`
  [https://developer.apple.com/documentation/coreai/aimodel](https://developer.apple.com/documentation/coreai/aimodel)
* `AIModelCache`
  [https://developer.apple.com/documentation/coreai/aimodelcache](https://developer.apple.com/documentation/coreai/aimodelcache)
* `SpecializationOptions`
  [https://developer.apple.com/documentation/coreai/specializationoptions](https://developer.apple.com/documentation/coreai/specializationoptions)
* `ComputeUnitKind`
  [https://developer.apple.com/documentation/coreai/computeunitkind](https://developer.apple.com/documentation/coreai/computeunitkind)
* Compiling Core AI models ahead of time
  [https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time](https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time)
