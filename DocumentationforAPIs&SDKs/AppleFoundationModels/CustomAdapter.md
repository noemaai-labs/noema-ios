# Loading and using a custom adapter with Foundation Models

Specialize the behavior of the system language model by using a custom adapter you train.

Source: https://developer.apple.com/documentation/foundationmodels/loading-and-using-a-custom-adapter-with-foundation-models

## Overview

Custom adapters (LoRA-based fine-tuning layers) let you specialize the on-device Apple Intelligence model for your specific domain without replacing the full model. An adapter adjusts the model's behavior for a particular task — e.g., generating output in a proprietary format, following domain-specific conventions, or improving accuracy on a narrow topic — while keeping the base model's general capabilities.

Adapters are small files that ship with your app or are downloaded on demand.

## Loading an Adapter

Create a `SystemLanguageModel` with an adapter URL pointing to the compiled adapter resource:

```swift
let adapterURL = Bundle.main.url(
    forResource: "MyAdapter",
    withExtension: "mlmodelc"
)!

let model = SystemLanguageModel(adapter: adapterURL)

guard case .available = model.availability else {
    // Handle unavailability — adapter may need device support
    return
}

let session = LanguageModelSession(model: model)
```

## Availability Check

Custom adapters require the same Apple Intelligence prerequisites as the base model. Always check availability before using an adapter-based model:

```swift
switch model.availability {
case .available:
    // Proceed with the adapted model
case .unavailable(.appleIntelligenceNotEnabled):
    // Prompt user to enable Apple Intelligence
case .unavailable(.modelNotReady):
    // Show "try again later" message
case .unavailable(let reason):
    // Handle other reasons
}
```

## Adapter vs. General Model

Use an adapter when:
* Your prompts consistently follow a narrow, well-defined pattern
* You need output in a proprietary or structured format the base model handles inconsistently
* Quality from the base model + prompt engineering is insufficient for your use case

Use the base model (with careful prompting) when:
* The task is general-purpose (summarization, Q&A, classification)
* You need flexibility across many prompt styles
* Adapter training data isn't available

## Combining with Other Features

Adapted models support all standard `LanguageModelSession` features:

```swift
let session = LanguageModelSession(
    model: SystemLanguageModel(adapter: adapterURL),
    tools: [MyCustomTool()],
    instructions: "You specialize in structured financial analysis."
)

let response = try await session.respond(
    to: "Analyze the following balance sheet...",
    generating: FinancialAnalysis.self
)
```

## Training Custom Adapters

Apple provides tooling for training adapters using your own data. See Apple's developer resources on the Foundation Models framework for adapter training guidelines and the required data format.

Key considerations:
* Training data quality matters more than quantity
* Adapters are evaluated under the same safety framework as the base model
* Over-fitting to narrow training data can reduce general capability

## Related

* `SystemLanguageModel`
  [https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
* Generating content and performing tasks with Foundation Models
  [https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
* Improving the safety of generative model output
  [https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output)
