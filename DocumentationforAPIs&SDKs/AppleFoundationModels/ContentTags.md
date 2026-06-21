# Categorizing and organizing data with content tags

Use the content tagging model to automatically generate descriptive tags from text.

Source: https://developer.apple.com/documentation/foundationmodels/categorizing-and-organizing-data-with-content-tags

## Overview

Apple's Foundation Models framework includes a specialized on-device system language model for content tagging. This model analyzes input text and produces categorizing tags using "one to a few lowercase words."

The content tagging model identifies four types of tags:

* **Topics** — e.g., "greet" for input text containing "hi," "hello," "yo"
* **Actions** — verbs describing what happens
* **Objects** — nouns of significance
* **Emotions** — sentiment or feeling detected in the text

## Use Cases

* Gathering statistics about popular topics in social apps
* Personalizing user experiences based on detected interests
* Automating content organization (email labeling, article classification)
* Identifying trends through tag aggregation
* Generating hashtags for posts or landmarks

## Initialization

Use `SystemLanguageModel(useCase: .contentTagging)` to get the specialized model:

```swift
let contentTaggingModel = SystemLanguageModel(useCase: .contentTagging)

guard contentTaggingModel.isAvailable else { return }

let session = LanguageModelSession(model: contentTaggingModel)
```

## Basic Usage

```swift
let session = LanguageModelSession(
    model: SystemLanguageModel(useCase: .contentTagging)
)

let response = try await session.respond(
    to: "The sunset painted the mountains in shades of orange and pink."
)
// response.content might be: "nature, sunset, mountains, scenic"
```

## Structured Tag Generation with Guided Generation

Define a `@Generable` struct to enforce tag count and type:

```swift
@Generable
struct TaggingResponse {
    @Guide(description: "A list of relevant content tags", .count(3...5))
    var tags: [String]
}

let stream = session.streamResponse(
    to: landmark.description,
    generating: TaggingResponse.self,
    options: GenerationOptions(sampling: .greedy)
)

for try await partial in stream {
    generatedTags = partial.content?.tags ?? []
}
```

## Instruction Importance

Instructions provided to the content tagging model produce more precise outcomes than instructions in the prompt. Use session-level instructions to customize tag behavior:

```swift
let session = LanguageModelSession(
    model: SystemLanguageModel(useCase: .contentTagging),
    instructions: "Generate tags related to travel and outdoor activities only."
)
```

## Avoiding Duplicate Tags and Improving Performance

Providing a `@Guide` with `maximumCount` prevents the model from generating duplicates and reduces unnecessary token consumption:

```swift
@Generable
struct CompactTags {
    @Guide(description: "Unique tags, no duplicates", .count(1...3))
    var tags: [String]
}
```

## Session Reuse Consideration

When reusing a `LanguageModelSession` for content tagging, the model may produce tags related to previous conversation turns due to context accumulation. Create a new session per tagging request if isolation is important:

```swift
// For isolation: one session per request
func generateTags(for text: String) async throws -> [String] {
    let session = LanguageModelSession(
        model: SystemLanguageModel(useCase: .contentTagging)
    )
    let response = try await session.respond(
        to: text,
        generating: TaggingResponse.self,
        options: GenerationOptions(sampling: .greedy)
    )
    return response.content?.tags ?? []
}
```

## When NOT to Use Content Tagging

This model works best for action, object, emotion, and topic identification. For other content types or for generating hashtags in a specific style (e.g., camelCase `#NatureSunset`), use the general `SystemLanguageModel.default` instead.

## Related

* Adding intelligent app features with generative models (sample code uses content tagging)
  [https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models](https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models)
* `SystemLanguageModel.UseCase`
  [https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/usecase](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/usecase)
