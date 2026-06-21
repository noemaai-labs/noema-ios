---
title: Adding server-side intelligence with Private Cloud Compute
description: Access a larger context window and stronger reasoning by routing session requests through Private Cloud Compute.
source: https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute
timestamp: 2026-06-08T20:15:43.771Z
---

**Navigation:** [Foundationmodels](/documentation/foundationmodels)

**Article**

# Adding server-side intelligence with Private Cloud Compute

> Access a larger context window and stronger reasoning by routing session requests through Private Cloud Compute.

## Overview

The on-device Apple Intelligence model is useful for apps that need an always-available solution that doesn’t require a network connection. However, you may find that the feature you build needs more capabilities than the on-device model provides. The server-based model — accessed through Private Cloud Compute (PCC) — provides a larger 32K-token context size and stronger reasoning for handling long documents or extended multiturn conversations.

Typically, you need to handle authentication and manage API keys with server models. You don’t need to handle either when you use PCC. People just need a device that supports Apple Intelligence and gets a daily request limit. People can upgrade their iCloud+ subscription to get more access when they want it.

> [!IMPORTANT]
> To develop with PCC you must meet certain eligibility requirements. To learn more and request access to the managed entitlement, see [](https://developer.apple.com/private-cloud-compute/).

## Use the server-based Apple Intelligence model

Choosing when to use PCC depends on your feature and is best made after evaluating your feature. This process helps you understand the quality of your specific feature, and whether it meets your expectations when using the on-device model. Start with the on-device model and evaluate it with the [Evaluations](/documentation/Evaluations) framework. If you determine your feature needs more reasoning capability or context size, then use PCC.

| Capability | `SystemLanguageModel` |  | `PrivateCloudComputeLanguageModel` |
| --- | --- | --- | --- |
| Preserves privacy | ✅ |  | ✅ |
| Works offline | ✅ |  | 🚫 |
| Usage limits | Unlimited |  | Limit per day |
| Reasoning | Not supported |  | Multiple levels |
| Context size | 4K |  | 32K |

To use the server-based model, you change a single line of code that you apply when creating your [Language Model Session](/documentation/foundationmodels/languagemodelsession). The framework uses a unified API regardless of which model you prompt. The respond methods — along with any tools and instructions you configure — carry over without any modification.

Because both [Private Cloud Compute Language Model](/documentation/foundationmodels/privatecloudcomputelanguagemodel) and [System Language Model](/documentation/foundationmodels/systemlanguagemodel) conform to the [Language Model](/documentation/foundationmodels/languagemodel) protocol, you can pass either to [init(model:tools:instructions:)](/documentation/foundationmodels/languagemodelsession/init(model:tools:instructions:)). To route a session through PCC, instantiate it with  [Private Cloud Compute Language Model](/documentation/foundationmodels/privatecloudcomputelanguagemodel):

```swift
// Create a session with the server-side model.
let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
```

Because [Private Cloud Compute Language Model](/documentation/foundationmodels/privatecloudcomputelanguagemodel) is available on iOS 27, macOS 27, watchOS 27, and visionOS 27 or later, use the appropriate available check when initializing a session and fall back to the on-device model on prior versions.

```swift
if #available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *) {
    // Create a session using the server-based model.
} else {
    // Use the on-device model on older versions.
}
```

Using PCC requires a network connection, so if the request fails because the network connection is unavailable, retry the request using the on-device model. PCC is only available on devices that support Apple Intelligence, so check [availability-swift.property](/documentation/foundationmodels/privatecloudcomputelanguagemodel/availability-swift.property) before performing your request:

```swift
let model = PrivateCloudComputeLanguageModel()

switch model.availability {
case .available:
    // Show your intelligence UI.
case .unavailable(.deviceNotEligible):
    // Show an alternative UI.
case .unavailable(.systemNotReady):
    // PCC isn't ready to serve requests.
case .unavailable(let other):
    // The model is unavailable for an unknown reason.
}
```

> [!NOTE]
> To use either the on-device model or the model on PCC, people need to turn on Apple Intelligence on their device. For a list of supported devices, see [](https://www.apple.com/apple-intelligence/).

## Handle usage limits from using PCC

A [Private Cloud Compute Language Model](/documentation/foundationmodels/privatecloudcomputelanguagemodel)  provides a [Language Model Error](/documentation/foundationmodels/languagemodelerror) that you use to proactively respond to usage quota scenarios, like when a person is approaching their request limit per day. When a person approaches or exceeds the daily quota, the framework provides a direct path for you to add system UI so the person can subscribe to iCloud+ to get more access.

Instead of presenting an alert that a person can dismiss, add UI to clearly communicate the current status of a person’s daily usage. Use [status-swift.property](/documentation/foundationmodels/privatecloudcomputelanguagemodel/quotausage-swift.struct/status-swift.property) to determine whether a person is below their quota, approaching it, or if they exceeded it, then display the appropriate UI message:

```swift
let model = PrivateCloudComputeLanguageModel()

// Depending on the quota state, display a label to keep a person aware
// of the status of their daily limit.
if model.quotaUsage.isLimitReached {
    Text("Usage limit exceeded")
        .foregroundStyle(Color.red)
} else if case .belowLimit(let info) = model.quotaUsage.status {
    if info.isApproachingLimit {
        Text("Nearing usage limit")
            .foregroundStyle(Color.orange)
    }
}
    
// Display a button in your UI to present the available upgrade options.
if let suggestion = model.quotaUsage.limitIncreaseSuggestion {
    Button("Show options") {
        suggestion.show()
    }
}
```

A person might encounter their usage limit when they are interacting with your session. When that occurs, the framework throws a [quotaLimitReached(_:)](/documentation/foundationmodels/privatecloudcomputelanguagemodel/error/quotalimitreached(_:)) error to indicate that a person exhausted their allotment of requests for the day. Unlike rate limiting, where a person waits for a period of time before trying again, exceeding the daily quota means a person either waits for their usage quota to refresh or they upgrade to a higher tier. Use [reset Date](/documentation/foundationmodels/privatecloudcomputelanguagemodel/quotausage-swift.struct/resetdate) to inspect when a person’s quota refreshes. This value is empty when the reset date isn’t known or when the person is well below their limit.

When a person exceeds the limit, display a message in your app so they know about it and can choose to upgrade for more access. The following shows three ways for presenting a usage limit message to a person:

![Three iPhone screens side by side, each showing a different presentation style](https://docs-assets.developer.apple.com/published/36860c7b8ff8a800d3a6193fdce9f565/adding-server-side-intelligence-with-private-cloud-compute-usage-message%402x.png)

To test your app’s experience when encountering usage limits, the Xcode Scheme navigator provides options that simulate approaching and exceeding the limit.

To configure a simulated usage limit option in Xcode:

1. Choose Product > Scheme > Edit Scheme.
2. Select the Run page and choose the Options tab.
3. Select either “Approaching Quota Usage Limit” or “Quota Usage Limit Reached” from the “Simulated Apple Foundation Models Availability” drop-down menu.
4. Click Close and run your project.

## Enable extended reasoning

Reasoning allows the model to spend more effort to explore the prompt you provide. This effort generates extra text that the model uses when it generates a response. The framework provides three reasoning levels, [light](/documentation/foundationmodels/contextoptions/reasoninglevel-swift.enum/light), [moderate](/documentation/foundationmodels/contextoptions/reasoninglevel-swift.enum/moderate), and [deep](/documentation/foundationmodels/contextoptions/reasoninglevel-swift.enum/deep). A lower reasoning effort reduces latency, while deeper reasoning trades latency for more analysis on complex, multi-step problems.

Use [Context Options](/documentation/foundationmodels/contextoptions) to configure how much reasoning effort to apply before producing a response:

```swift
let response = try await session.respond(
    to: "What are the tradeoffs in this architecture?",
    contextOptions: ContextOptions(reasoningLevel: .deep)
)
```

To determine what reasoning level to use, evaluate your feature by starting with [moderate](/documentation/foundationmodels/contextoptions/reasoninglevel-swift.enum/moderate). Use [deep](/documentation/foundationmodels/contextoptions/reasoninglevel-swift.enum/deep) when you determine the task needs additional reasoning, like when you’re making architectural decisions with many competing constraints. Deep reasoning is slower, but it spends more time catching things that the other levels miss.

The more reasoning you apply causes the model to use more of the context window to generate the reasoning text it uses for the response. Reasoning segments reflect the model’s intermediate reasoning and don’t appear in the final response content. Reviewing them helps you understand why the model produced a particular answer, which is useful when debugging complex prompts.

## Private Cloud Compute

- [com.apple.developer.private-cloud-compute](/documentation/BundleResources/Entitlements/com.apple.developer.private-cloud-compute)
- [PrivateCloudComputeLanguageModel](/documentation/foundationmodels/privatecloudcomputelanguagemodel)

---

*Extracted by [sosumi.ai](https://sosumi.ai) - Making Apple docs AI-readable.*
*This is unofficial content. All documentation belongs to Apple Inc.*