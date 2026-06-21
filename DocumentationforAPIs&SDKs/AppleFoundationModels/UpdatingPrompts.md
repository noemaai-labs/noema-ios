# Updating prompts for new model versions

Test and manage your prompts when the system language model updates with new OS versions.

Source: https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions

## Overview

Apple's on-device system language model updates with OS releases. When a new version ships, you should "test the prompts your app uses against the old and new model versions to check whether there are unexpected differences in output."

The Foundation Models framework availability begins at iOS/macOS 26.0, eliminating the need to check for earlier versions.

## Strategies for Managing Prompt Versions

### Availability-Gated Prompt Variants

Use conditional compilation to serve different prompts based on OS version:

```swift
func summaryPrompt(for text: String) -> String {
    if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
        // Prompt tuned for the newer model version
        return "Summarize this in 2 sentences, highlighting the key insight: \(text)"
    } else {
        // Fallback prompt for the earlier model
        return "Provide a brief summary of the following: \(text)"
    }
}
```

### Separate Prompt Files with Version Naming

Store prompts in separate files rather than hardcoding them:

```
prompts/
  support-ticket-summarizer-v1.0.txt
  support-ticket-summarizer-v1.1.txt
  itinerary-generator-v2.0.txt
```

This makes it easy to diff changes across versions and roll back if a new prompt degrades quality.

### Xcode String Catalogs

Leverage Xcode's string catalog feature to manage and localize prompts centrally:

```swift
// In your .xcstrings catalog, add a key per prompt
let prompt = String(localized: "support_ticket_summary_prompt", table: "Prompts")
```

This approach allows updating prompts without code changes and supports localization for language-specific reliability.

### Server-Based Dynamic Prompt Fetching

Implement dynamic prompt fetching at runtime for maximum flexibility:

```swift
func fetchPrompt(named key: String) async throws -> String {
    let url = URL(string: "https://your-server.example/prompts/\(key)")!
    let (data, _) = try await URLSession.shared.data(from: url)
    return String(data: data, encoding: .utf8) ?? fallbackPrompts[key]!
}
```

Benefits:
* Enables much faster updates when needed (no App Store submission)
* Supports rollback capabilities if a prompt change causes regressions
* Allows A/B testing different prompt variants

## Testing Workflow

1. **Document baseline outputs** before updating prompts for the current model version
2. **Monitor Apple's Foundation Models release page** for upcoming OS betas
3. **Test in beta** using the developer beta program to catch prompt regressions early
4. **Re-run your full prompt test suite** with each new OS version, including adversarial safety tests
5. **Maintain changelogs** for prompt modifications

## When to Retest

* When a new iOS/macOS beta ships with a model update
* When Apple updates guardrails outside the regular OS cycle
* When your app's deployment target changes
* After any prompt modification, even small wording changes

## Related

* Prompting an on-device foundation model
  [https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model)
* Improving the safety of generative model output
  [https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output)
* Analyzing the runtime performance of your Foundation Models app
  [https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app](https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app)
