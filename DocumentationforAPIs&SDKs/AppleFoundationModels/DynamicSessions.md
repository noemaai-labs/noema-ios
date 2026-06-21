# Composing dynamic sessions with instructions and profiles

Adapt your session's model, tools, and instructions at runtime based on app state.

Source: https://developer.apple.com/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles

Availability: Beta (iOS 26.0+, iPadOS 26.0+, macOS 26.0+, visionOS 26.0+)

## Overview

The Dynamic Profile API lets you declaratively specify the instructions, tools, and model configuration that are active for the current state of your app. Instead of creating a new `LanguageModelSession` each time app state changes, you compose reusable `DynamicInstructions` and `Profile` types that re-evaluate before each model request.

Three composable layers:

* **Dynamic Instructions** — declare what instructions and tools are needed for the current app state; the body re-evaluates before each model request
* **Profile** — associates Dynamic Instructions with session-level properties like model, temperature, and reasoning level
* **Dynamic Profile** — orchestrates transitions between multiple domain-specific profiles using conditionals and nesting; a compiler constraint ensures exactly one Profile is active at any time

## Dynamic Instructions

Conform to `DynamicInstructions` to express which tools and instructions apply based on app state:

```swift
struct PresentationInstructions: DynamicInstructions {
    var isEditingImage: Bool = false

    var body: some DynamicInstructions {
        // Static elements — always present, cached across turns
        Instructions {
            "You help create presentations."
        }
        ListSlidesTool()
        AddSlideTool()

        // Conditional at the end minimizes cache invalidation
        if isEditingImage {
            ImageEditingInstructions()
        }
    }
}
```

Place instructions and tools that remain constant at the top of the body. The framework flattens the resolved token sequence in declaration order, so static content first means fewer cache invalidations when a condition changes.

## Profile

A `Profile` pairs `DynamicInstructions` with session-level configuration:

```swift
Profile {
    PresentationInstructions(isEditingImage: isEditing)
}
.temperature(isEditing ? 0.5 : 1.0)
.toolCallingMode(.allowed)
```

## Dynamic Profile

A `DynamicProfile` orchestrates switching between multiple profiles:

```swift
struct AppProfile: DynamicProfile {
    @AppStorage("mode") var mode: AppMode = .general

    var body: some DynamicProfile {
        switch mode {
        case .brainstorm:
            Profile {
                BrainstormInstructions()
            }
            .temperature(1.0)
        case .focused:
            Profile {
                FocusedInstructions()
            }
            .temperature(0.2)
        }
    }
}

let session = LanguageModelSession(profile: AppProfile())
```

## Modifier Precedence

Three-tier hierarchy (highest to lowest priority):

1. Call-site arguments (e.g., `options:` on `respond()`)
2. Innermost dynamic profile or profile modifier
3. Dynamic profile modifiers on the outer container

## Life Cycle Modifiers

Attach callbacks to profile events:

* `onActivate()` — runs when this profile becomes active
* `onDeactivate()` — runs when this profile becomes inactive
* `onPrompt()` — runs after a user prompt appends to the transcript
* `onResponse()` — runs after the model produces a response
* `onToolCall()` — runs when the model invokes a tool
* `onToolOutput()` — runs when a tool produces output

```swift
Profile {
    CoachInstructions()
}
.onResponse {
    // Log or post-process after every response
    analytics.record(event: .modelResponse)
}
```

## Session Properties

Use `@SessionProperty` to access read-write session state from within profiles:

```swift
@SessionProperty(\.history)
var history: [Transcript.Entry]

Profile {
    // ...
}
.onResponse {
    if history.count > 100 {
        history = history.suffix(50)
    }
}
```

Define custom session-scoped properties with the `@SessionPropertyEntry()` macro.

## History Transforms

Filter transcript entries before each model request using `historyTransform(_:)`:

```swift
Profile {
    // ...
}
.historyTransform { history in
    // Remove debug metadata — same token count, preserves cache
    clearDebugFromHistory(history)
}
```

Prefer stateless transforms (same input → same output) to avoid unexpected cache invalidation. Stateful transforms that modify the transcript between turns trigger recomputation on the next request.

## Restoring Sessions

Initialize a session from a saved transcript and profile:

```swift
let session = LanguageModelSession(
    profile: AppProfile(),
    history: savedTranscript
)
session.prewarm()
```

## Related

* Optimizing key-value caching in language model sessions
  [https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions](https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions)
* Origami: Crafting a dynamic tutorial for Apple Intelligence
  [https://developer.apple.com/documentation/foundationmodels/origami-crafting-a-dynamic-tutorial-for-apple-intelligence](https://developer.apple.com/documentation/foundationmodels/origami-crafting-a-dynamic-tutorial-for-apple-intelligence)
* `DynamicInstructions` (protocol)
  [https://developer.apple.com/documentation/foundationmodels/dynamicinstructions](https://developer.apple.com/documentation/foundationmodels/dynamicinstructions)
* `Profile` (struct)
  [https://developer.apple.com/documentation/foundationmodels/profile](https://developer.apple.com/documentation/foundationmodels/profile)
* `DynamicProfile` (protocol)
  [https://developer.apple.com/documentation/foundationmodels/dynamicprofile](https://developer.apple.com/documentation/foundationmodels/dynamicprofile)
