# Generating Swift data structures with guided generation

Define Swift types that the model fills in, getting structured output with compile-time safety.

Source: https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation

## Overview

Apple's Foundation Models framework offers **guided generation** to ensure model responses conform to expected formats. Rather than parsing raw strings, developers define Swift types that structure output, with the framework using "constrained sampling" to guarantee valid results.

## The `@Generable` Macro

Apply `@Generable` to structs, actors, or enums to make them producible by the model:

* `@Generable(description:)` — applied to type declarations; description helps the model understand the type's purpose
* `@Guide(description:)` — applied to stored properties; guides constrain how that field is generated

Properties generate in the order they're declared.

## Basic Example

```swift
@Generable(description: "Basic profile information about a cat")
struct CatProfile {
    var name: String

    @Guide(description: "The age of the cat", .range(0...20))
    var age: Int

    @Guide(description: "A one sentence profile about the cat's personality")
    var profile: String
}

let session = LanguageModelSession()
let response = try await session.respond(
    to: "Generate a cute rescue cat",
    generating: CatProfile.self
)
let cat = response.content  // CatProfile instance, always valid
```

## Guide Constraints

`@Guide` supports multiple constraint types that can be stacked:

```swift
@Generable
struct Recipe {
    @Guide(description: "The recipe name")
    var name: String

    @Guide(description: "Difficulty level", .anyOf(["easy", "medium", "hard"]))
    var difficulty: String

    @Guide(.count(3...5))
    var ingredients: [String]

    @Guide(description: "Cooking time in minutes", .range(5...120))
    var cookingTime: Int
}
```

Available guide constraints:

* `.range(_:)` — restricts numeric values to a range
* `.anyOf(_:)` — restricts string values to an enumeration
* `.count(_:)` — restricts array count (exact or range)
* `.maximumCount(_:)` — maximum array elements
* `.pattern(_:)` — restricts strings to a regex pattern

## Generable Enumerations

```swift
@Generable
enum Sentiment {
    case positive
    case neutral
    case negative
}

let response = try await session.respond(
    to: "Classify the sentiment: 'This is amazing!'",
    generating: Sentiment.self,
    options: GenerationOptions(sampling: .greedy)
)
// response.content == .positive
```

## Nested Structures

```swift
@Generable
struct Itinerary {
    @Guide(description: "An exciting name for the trip.")
    let title: String

    @Guide(.count(3))
    let days: [DayPlan]
}

@Generable
struct DayPlan {
    let title: String

    @Guide(.count(3))
    let activities: [Activity]
}

@Generable
struct Activity {
    let type: Kind
    let title: String
    let description: String
}

@Generable
enum Kind {
    case sightseeing
    case foodAndDining
    case shopping
    case hotelAndLodging
}
```

## Partially Generated Types for Streaming

The `@Generable` macro automatically creates a `PartiallyGenerated` variant where every property is optional, for use with streaming:

```swift
var partialItinerary: Itinerary.PartiallyGenerated?

let stream = session.streamResponse(
    generating: Itinerary.self,
    includeSchemaInPrompt: false,
    options: GenerationOptions(sampling: .greedy)
) {
    "Generate a 3-day trip to Kyoto."
}

for try await partial in stream {
    partialItinerary = partial.content  // update UI progressively
}
```

## Guided Generation with Reasoning

Place a reasoning field first in structures so the model's thinking doesn't contaminate the output:

```swift
@Generable
struct ReasonableAnswer {
    var reasoningSteps: String  // model puts its plan here first
    @Guide(description: "The final answer only.")
    var answer: MyCustomGenerableType
}
```

## Dynamic Schemas

For runtime-determined structures, use `DynamicGenerationSchema`:

```swift
var schema = DynamicGenerationSchema(name: "product")
schema.addProperty(name: "title", type: .string)
schema.addProperty(name: "price", type: .number, guide: .range(0...9999))

let generationSchema = GenerationSchema(schema)
let response = try await session.respond(
    to: "Generate a product listing",
    generating: generationSchema
)

// Decode via GeneratedContent
let title = response.content?.value(String.self, forProperty: "title")
```

## Supported Base Types

* `Bool`, `Int`, `Float`, `Double`, `Decimal`
* `String`
* `Array` (of any Generable type)
* Custom `@Generable` structs, actors, and enums

## Error Handling

When the model refuses to generate a structured type, it throws `GenerationError.refusal(_:_:)` instead of returning a refusal string:

```swift
do {
    let response = try await session.respond(
        to: "List five key points about: \(topic)",
        generating: [String].self
    )
} catch LanguageModelSession.GenerationError.refusal(let refusal, _) {
    if let message = try? await refusal.explanation {
        // Display the refusal message
    }
}
```

## Related

* `Generable` protocol
  [https://developer.apple.com/documentation/foundationmodels/generable](https://developer.apple.com/documentation/foundationmodels/generable)
* `GenerationSchema`
  [https://developer.apple.com/documentation/foundationmodels/generationschema](https://developer.apple.com/documentation/foundationmodels/generationschema)
* `DynamicGenerationSchema`
  [https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema](https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema)
* `GenerationGuide`
  [https://developer.apple.com/documentation/foundationmodels/generationguide](https://developer.apple.com/documentation/foundationmodels/generationguide)
* `GeneratedContent`
  [https://developer.apple.com/documentation/foundationmodels/generatedcontent](https://developer.apple.com/documentation/foundationmodels/generatedcontent)
* Expanding generation with tool calling
  [https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling)
