---
title: Optimizing key-value caching in language model sessions
description: Prevent repeated token processing by preserving the cached state across turns.
source: https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions
timestamp: 2026-06-08T20:17:54.761Z
---

**Navigation:** [Foundationmodels](/documentation/foundationmodels)

**Article**

# Optimizing key-value caching in language model sessions

> Prevent repeated token processing by preserving the cached state across turns.

## Overview

When using a language model session for multi-turn conversations, model providers might maintain a key-value (KV) cache of previously processed tokens. This cache allows the model to skip reprocessing content it’s already seen, so each new turn only processes the tokens you add. Because the cache can affect processing latency and costs associated with using generated and cached tokens, it’s up to the model provider to determine how they manage the cache. How you structure and manage your session determines whether the provider preserves or invalidates that cache.

Some workflows require the prefix to change between turns. Dynamic instructions provide a declarative way to conditionally include or exclude instructions and tools based on application state. A profile pairs dynamic instructions with session-level configuration like the model and temperature, and a dynamic profile orchestrates transitions between profiles. When you use these APIs, how you structure your dynamic instructions directly affects how much of the cache the system preserves between turns.

For more information about using dynamic instructions, see [composing-dynamic-sessions-with-instructions-and](/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles).

## Set up a stable session foundation

A session typically arranges its content into a token sequence with a specific order, like instructions appearing at the top, tool definitions coming next, and then transcript entries follow at the end. Each cached value in the sequence depends on every token that precedes it. When a token changes at any position, the system recomputes the cached values from that point forward. Each segment that the system recomputes adds latency that a person experiences while waiting for a response.

Appending new content at the end of the sequence — through calls to respond or stream methods — is a cache-friendly operation, because all preceding cached values remain valid. For example, the following table shows each turn reusing previously computed values from the cache:

![A three-column diagram showing key-value cache reuse across Turn 1, Turn 2,](https://docs-assets.developer.apple.com/published/e92eae1d2e8e0917fe3e8a51c932966c/optimizing-key-value-caching-in-language-model-sessions-cached%402x.png)

Because the instructions and tool definitions form a stable prefix, the system caches them once and reuses them across every turn. A change to the instructions, for example, invalidates the cache for the tool definitions and the entire transcript. A change deep in the transcript, by contrast, only invalidates the values that follow it.

The second turn in the following example, however, doesn’t benefit from reusing cached tokens when you modify the beginning of the transcript. Turn three recovers because the prefix is stable again.

![A three-column diagram showing key-value cache invalidation. Pink blocks mark](https://docs-assets.developer.apple.com/published/3389b91a095997c0ebbf33557197fe38/optimizing-key-value-caching-in-language-model-sessions-compute%402x.png)

An effective way to preserve cached context is to establish a stable prefix when creating the session. Use [init(profile:history:)](/documentation/foundationmodels/languagemodelsession/init(profile:history:)) to define your instructions and tools up front, and don’t change them over the lifetime of the session. Place any content that varies between interactions toward the end of your instructions rather than at the beginning.

When the session is about to receive its first prompt, call [prewarm(promptPrefix:)](/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:)) to precompute the prefix into the cache before the first call to [respond(to:options:)](/documentation/foundationmodels/languagemodelsession/respond(to:options:)) arrives:

```swift
let session = LanguageModelSession(
    tools: [RecipeDatabaseTool()],
    instructions: """
        You are a helpful cooking assistant. Suggest recipes \
        based on available ingredients and dietary preferences.
        """
)

// Perform a key-value cache computation for the instructions, tools, and the 
// provided prefix before sending the person's request.
session.prewarm(
    promptPrefix: "Suggest a recipe using"
)
```

Prewarming works best when there’s time to finish loading the model and caching the prompt before a request. Prewarm the model when you know usage is at least one or two seconds in the future. That way, when the first call to [respond(to:options:)](/documentation/foundationmodels/languagemodelsession/respond(to:options:)) occurs, the cached portion is already warm and only the remaining tokens need computation. This eliminates the need to compute every segment on the first turn and prevents unnecessary latency.

## Consider model accuracy from transcript modification

Modifying the transcript impacts model accuracy because there’s no reliable way for the model to distinguish between information that never existed and information that did exist but was removed from the context. A model treats whatever’s in the context as the complete picture and reasons confidently from incomplete evidence. Carefully consider when and how you modify session history. Not only does modifying session history incur a cache invalidation, several categories of accuracy problems occur:

When you use tools, changing them not only involves accuracy problems, but incurs a performance hit from cache invalidations. Adding or removing tools midsession changes the token sequence at the beginning of the transcript, which invalidates the cached values for all of the entries after that point. When you use [Dynamic Instructions](/documentation/foundationmodels/dynamicinstructions), define the tools you need up front and keep that set unchanged.

Carefully consider when to remove a tool because the [Transcript](/documentation/foundationmodels/transcript) can contain entries that reference the [Tool](/documentation/foundationmodels/tool) name and output, which impact the model’s accuracy. Removing a tool the model previously used can cause the model to produce unexpected results because it sees references in the transcript for a tool that no longer exists in its tool definitions. If you do remove any tools, also remove any associated output that refers to them so the model doesn’t see any references.

Adding a new tool late in a conversation can produce unexpected behavior. The model follows patterns established in earlier turns and might not incorporate a newly available tool into its responses.

## Preserve the cache with dynamic instructions

The framework re-evaluates a [Dynamic Instructions](/documentation/foundationmodels/dynamicinstructions) body before each model request. When the resolved instructions or tools change between turns the system updates the prefix and invalidates any cached values.

Place instructions and tools that remain constant at the top of your [Dynamic Instructions](/documentation/foundationmodels/dynamicinstructions) body, and group conditional content at the bottom. The framework flattens the resolved instructions and tool definitions in the order you declare them, so content that appears first in the body occupies earlier positions in the token sequence. Keeping static content first means the system can reuse the cached values for those tokens even when a later condition changes.

```swift
struct PresentationInstructions: DynamicInstructions {
    var isEditingImage: Bool = false

    var body: some DynamicInstructions {
        // Static elements that are always present and cached across turns.
        Instructions {
            "You help create presentations."
        }
        ListSlidesTool()
        AddSlideTool()
        
        // Place a conditional at the end to minimize invalidation
        // when an event toggles it.        
        if isEditingImage {
            ImageEditingInstructions()
        }
    }
}
```

> [!NOTE]
> Placing the conditional content before the static instructions and tools invalidates the cached values and leads to unnecessary recomputation.

Design your dynamic profiles so transitions between your profiles occur at natural boundaries in the conversation rather than on every turn. Switching from one profile to another typically changes the entire prefix — which invalidates the cache for the full transcript — so treat it as a deliberate reset.

## Prefer stateless history transforms

Attach input filters to a profile with the [historyTransform(_:)](/documentation/foundationmodels/languagemodelsession/dynamicprofile/historytransform(_:)) modifier to transform the transcript before each model request. Prefer stateless transforms over stateful ones because they don’t modify the global transcript, so they’re easier to understand with respect to cache consistency.

A stateless filter produces the same output for the same input. A stateless transform that drops entries, like truncating to recent history, invalidates parts of the cache for the entries it removes. However, a transform that replaces content in-place, like removing debug metadata, can preserve cache consistency because the model sees the same token sequence each time.

```swift
Profile {
   // The instructions and tools for the profile.
}
.historyTransform { history in
    // Remove debug text from the history. The model sees the same number of
    // entries in the same order so previously cached tokens remain valid.
    clearDebugFromHistory(history)
}
```

When you use a stateful filter, the output varies between turns and changes the token sequence unpredictably. This activates a cache invalidation even when the original transcript hasn’t changed. For example, a stateful transform within a callback like `onResponse` modifies the transcript between turns, so every subsequent model request recomputes from the point of change:

```swift
// Define a session property to access the history for the session.
@SessionProperty(\.history) 
var history

Profile {
    // The instructions and tools for the profile.
}
.onResponse {
    // Compress the history and incur the cache invalidation on the next request.
    if history.count > 100 {
        history = history.suffix(50)
    }
}
```

## Manage transcript growth within the context window

Every element in the session — instructions, tool definitions, and all transcript entries — counts toward the context size. As the conversation grows, the transcript eventually approaches the available context.

Defer removing entries from the transcript until the context window is nearly full, then consolidate the context in a single operation rather than trimming incrementally after each turn. Frequent small edits to the middle of the transcript force repeated cache invalidations that increase latency, while a single consolidation step incurs the recomputation cost only once.

When you do trim, removing only the most recent entries is cheaper than modifying earlier ones because it invalidates fewer cached values. If you need to remove older entries, consider summarizing the conversation and starting a fresh session with that summary as context.

When the transcript grows beyond the context window, the framework throws [contextSizeExceeded(_:)](/documentation/foundationmodels/languagemodelerror/contextsizeexceeded(_:)). To recover, summarize the conversation and update the session [transcript](/documentation/foundationmodels/languagemodelsession/transcript) by accessing the history from `@SessionProperty`.

For more information about managing the context window, see [managing-the-context](/documentation/foundationmodels/managing-the-context-window).

## Restore sessions from saved transcripts

If preserving the full conversation history matters more than the first-response latency, like when a person expects to continue exactly where they left off, consider rehydrating a session from a previous state. Persist a session’s [transcript](/documentation/foundationmodels/languagemodelsession/transcript) and use it when initializing a session with [init(model:tools:transcript:)](/documentation/foundationmodels/languagemodelsession/init(model:tools:transcript:)) or [init(profile:history:)](/documentation/foundationmodels/languagemodelsession/init(profile:history:))

The session starts without a KV cache, so the model reprocesses the full transcript on the first call to [respond(to:options:)](/documentation/foundationmodels/languagemodelsession/respond(to:options:)) or [prewarm(promptPrefix:)](/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:)). The following creates a new session from a saved transcript and prewarms it to begin rebuilding the cache:

```swift
let transcript = // Load a transcript you save from a previous conversation.

let session = LanguageModelSession(
    transcript: transcript
)

// Begin rebuilding the cache before the person's next prompt arrives --- at
// least one to two seconds in the future.
session.prewarm()
```

The reprocessing latency on the first call is proportional to the size of the restored transcript. If the saved transcript is large, consider trimming it to the most relevant entries before rehydrating.

## Profile cache performance with Instruments

Use the Foundation Models instrument to measure how your session uses tokens and where latency occurs. The instrument shows asset load times, token counts, and durations for each request, so you can identify whether cache invalidation is causing unexpected reprocessing. Use the instrument to determine your cache hit rate by dividing the cached input tokens by the total input tokens. When this rate is low between turns, it signals that the system invalidated the cache and the model reprocessed the full prefix.

For more information about profiling and optimization techniques with Instruments, see [analyzing-the-runtime-performance-of-your-foundation-models](/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app).

## Custom language model provider

- [LanguageModel](/documentation/foundationmodels/languagemodel)
- [LanguageModelCapabilities](/documentation/foundationmodels/languagemodelcapabilities)
- [LanguageModelExecutor](/documentation/foundationmodels/languagemodelexecutor)
- [LanguageModelExecutorGenerationChannel](/documentation/foundationmodels/languagemodelexecutorgenerationchannel)
- [LanguageModelExecutorGenerationRequest](/documentation/foundationmodels/languagemodelexecutorgenerationrequest)

---

*Extracted by [sosumi.ai](https://sosumi.ai) - Making Apple docs AI-readable.*
*This is unofficial content. All documentation belongs to Apple Inc.*