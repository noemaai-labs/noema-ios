# Origami: Crafting a dynamic tutorial for Apple Intelligence

Build multimodal, agentic craft-learning experiences using Dynamic Profile, Private Cloud Compute, and image analysis.

Source: https://developer.apple.com/documentation/foundationmodels/origami-crafting-a-dynamic-tutorial-for-apple-intelligence

Availability: iOS 27.0+, iPadOS 27.0+, macOS 27.0+, Mac Catalyst 27.0+ (Beta)
Xcode: 27.0+

Requires: Device supporting Apple Intelligence; Apple Intelligence & Siri enabled in Settings

## Overview

The Origami sample demonstrates how to build interactive craft-learning experiences using Foundation Models, Private Cloud Compute, and multimodal prompts. The app helps users learn origami by:

1. **Brainstorm phase** — user submits photos of supplies or inspiration; app suggests craft projects
2. **Coach phase** — user photographs progress; app analyzes and provides step-by-step feedback
3. **Term lookup phase** — fast on-device lookups for origami terminology

## Key Technical Approaches

### Multimodal Prompting Pattern

Images and text are treated as peer elements within a single prompt:

```swift
let prompt = Prompt {
    Attachment(image: progressPhoto, label: "current-step")
    Attachment(image: referencePhoto, label: "target-step")
    "Compare the current step photo to the target step. What needs adjustment?"
}

let response = try await session.respond(to: prompt, generating: CoachFeedback.self)
```

Key practices:
* Wrap `UIImage` or `NSImage` in an `Attachment`
* Assign stable, unique labels so the model can reference specific photos
* Place attachments directly in the `Prompt` alongside text

### Dynamic Session Configuration via DynamicProfile

The sample uses three modes managed by a `DynamicProfile`:

| Mode | Purpose | Model | Temperature |
|------|---------|-------|-------------|
| `.brainstorm` | Generate varied project ideas | on-device | 1.0 (high creativity) |
| `.tutorial` | Evaluate progress photos, generate steps | PCC (or on-device) | Lower (focused) |
| `.term` | Fast terminology lookups | on-device | Default |

```swift
struct OrigamiProfile: DynamicProfile {
    @AppStorage("mode") var mode: OrigamiMode = .brainstorm
    let serverModel = PrivateCloudComputeLanguageModel()

    var body: some DynamicProfile {
        switch mode {
        case .brainstorm:
            Profile {
                BrainstormInstructions()
            }
            .temperature(1.0)

        case .tutorial:
            if #available(iOS 27.0, macOS 27.0, *),
               case .available = serverModel.availability {
                Profile(model: serverModel) {
                    TutorialInstructions()
                }
                .reasoningLevel(.deep)
            } else {
                Profile {
                    TutorialInstructions()
                }
            }

        case .term:
            Profile {
                TermLookupInstructions()
            }
        }
    }
}

let session = LanguageModelSession(profile: OrigamiProfile())
```

### Structured Output with Guidance

Response types use `@Generable` with `@Guide` annotations to steer behavior:

```swift
@Generable
struct CoachFeedback: Codable {
    @Guide(description: "List of adjustments the user needs to make")
    var sections: [CoachSection]

    @Guide(description: "True ONLY if the photo clearly shows the step is complete")
    var isCurrentStepComplete: Bool
}

@Generable
struct CoachSection: Codable {
    var heading: String
    var details: String
}
```

`isCurrentStepComplete` acts as a small classifier — the app uses it to automatically advance the tutorial when the step is confirmed complete.

### Streaming Strategies

Two patterns depending on content type:

**Progressive rendering** (effective for lists):

```swift
var ideas: [CraftIdea] = []

let stream = session.streamResponse(
    to: prompt,
    generating: [CraftIdea].self
)

for try await partial in stream {
    ideas = partial.content ?? []  // update SwiftUI list as items arrive
}
```

**Buffering** (better for prose that shouldn't rewrite mid-sentence):

```swift
var feedback: CoachFeedback?

let stream = session.streamResponse(to: prompt, generating: CoachFeedback.self)
var finalResponse: CoachFeedback?
for try await partial in stream {
    finalResponse = partial.content
}
feedback = finalResponse  // display only when complete
```

### Private Cloud Compute Integration

To route tutorial coaching through PCC for deeper reasoning:

1. Swap to `PrivateCloudComputeLanguageModel()` in the tutorial profile
2. Add the managed `com.apple.developer.private-cloud-compute` entitlement
3. `.tutorial` mode activates `.reasoningLevel(.deep)` for complex photo analysis

```swift
// In DynamicProfile body:
if #available(iOS 27.0, *) {
    let pccModel = PrivateCloudComputeLanguageModel()
    if case .available = pccModel.availability {
        Profile(model: pccModel) {
            TutorialInstructions()
        }
        .reasoningLevel(.deep)
        .contextOptions(ContextOptions(reasoningLevel: .deep))
    }
}
```

### Two-Pass Generation

The sample uses two-pass generation to leverage session memory:

```swift
// Pass 1: Analyze and classify the progress photo (image + text)
let analysis = try await session.respond(
    to: Prompt {
        Attachment(image: progressPhoto, label: "progress")
        "Analyze the origami progress. Is step 3 complete?"
    },
    generating: StepAnalysis.self
)

// Pass 2: Generate coaching feedback using the analysis (text only, no image needed)
let feedback = try await session.respond(
    to: "Based on your analysis, what guidance should the user receive?",
    generating: CoachFeedback.self
)
```

### ImageReference for Linking Outputs to Inputs

Use `ImageReference` in response types to link outputs back to specific input photos:

```swift
@Generable
struct CraftSuggestion {
    var title: String
    var description: String
    @Guide(description: "Label of the supply photo that inspired this idea")
    var inspiredBy: ImageReference
}
```

This keeps "the input picture and the output structure connected by name," allowing the model to reference specific photos in structured responses.

## Related

* Composing dynamic sessions with instructions and profiles
  [https://developer.apple.com/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles](https://developer.apple.com/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles)
* Analyzing images with multimodal prompting
  [https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting)
* Adding server-side intelligence with Private Cloud Compute
  [https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
* `DynamicProfile` (protocol)
  [https://developer.apple.com/documentation/foundationmodels/dynamicprofile](https://developer.apple.com/documentation/foundationmodels/dynamicprofile)
* `ImageReference`
  [https://developer.apple.com/documentation/foundationmodels/imagereference](https://developer.apple.com/documentation/foundationmodels/imagereference)
