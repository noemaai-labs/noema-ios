# Foundation Models

Perform tasks with the on-device model that specializes in language understanding, structured output, and tool calling.

Availability:

* iOS 26.0+
* iPadOS 26.0+
* Mac Catalyst 26.0+
* macOS 26.0+
* visionOS 26.0+

## Overview

The Foundation Models framework provides access to Apple's on-device large language model that powers Apple Intelligence to help you perform intelligent tasks specific to your use case. The text-based on-device model identifies patterns that allow for generating new text that's appropriate for the request you make, and it can make decisions to call code you write to perform specialized tasks.

Key capabilities:

* Generate text content based on requests you make. The on-device model excels at a diverse range of text generation tasks, like summarization, entity extraction, text understanding, refinement, dialog for games, generating creative content, and more.
* Generate entire Swift data structures with guided generation. With the `@Generable` macro, you can define custom data structures and the framework provides strong guarantees that the model generates instances of your type.
* Expand the model's capabilities with tool calling. Use `Tool` to create custom tools that the model can call to assist with handling your request. For example, the model can call a tool that searches a local or online database for information, or calls a service in your app.
* Analyze images alongside text with multimodal prompting (Beta). Attach images to prompts for image classification, document summarization, accessibility descriptions, and more.
* Adapt sessions dynamically with Dynamic Profiles (Beta). Compose reusable `DynamicInstructions` and `Profile` types to switch model behavior at runtime without reinitializing sessions.
* Route requests through Private Cloud Compute (Beta) for a larger 32K-token context window and stronger reasoning.

Requirements:

* To use the on-device language model, people need to turn on Apple Intelligence on their device.
* For a list of supported devices, see Apple Intelligence:
  [https://www.apple.com/apple-intelligence/](https://www.apple.com/apple-intelligence/)

Policy and usage:

* For more information about acceptable usage of the Foundation Models framework, see:
  [https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework)

## Related videos

* Meet the Foundation Models framework (WWDC25):
  [https://developer.apple.com/videos/play/wwdc2025/286](https://developer.apple.com/videos/play/wwdc2025/286)
* Deep dive into the Foundation Models framework (WWDC25):
  [https://developer.apple.com/videos/play/wwdc2025/301](https://developer.apple.com/videos/play/wwdc2025/301)
* Code-along: Bring on-device AI to your app using the Foundation Models framework (WWDC25):
  [https://developer.apple.com/videos/play/wwdc2025/259](https://developer.apple.com/videos/play/wwdc2025/259)

## Topics

### Essentials

* Generating content and performing tasks with Foundation Models
  [https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
* Adding intelligent app features with generative models
  [https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models](https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models)
* Revision history / What's new in Foundation Models
  [https://developer.apple.com/documentation/updates/foundationmodels](https://developer.apple.com/documentation/updates/foundationmodels)

### Sessions and Prompts

* Prompting an on-device foundation model
  [https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model)
* Managing the context window
  [https://developer.apple.com/documentation/foundationmodels/managing-the-context-window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
* Updating prompts for new model versions
  [https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions](https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions)
* Analyzing the runtime performance of your Foundation Models app
  [https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app](https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app)
* `LanguageModelSession` (class)
  [https://developer.apple.com/documentation/foundationmodels/languagemodelsession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
* `Instructions` (struct)
  [https://developer.apple.com/documentation/foundationmodels/instructions](https://developer.apple.com/documentation/foundationmodels/instructions)
* `Prompt` (struct)
  [https://developer.apple.com/documentation/foundationmodels/prompt](https://developer.apple.com/documentation/foundationmodels/prompt)
* `Transcript` (struct)
  [https://developer.apple.com/documentation/foundationmodels/transcript](https://developer.apple.com/documentation/foundationmodels/transcript)
* `GenerationOptions` (struct)
  [https://developer.apple.com/documentation/foundationmodels/generationoptions](https://developer.apple.com/documentation/foundationmodels/generationoptions)
* `ContextOptions` (struct)
  [https://developer.apple.com/documentation/foundationmodels/contextoptions](https://developer.apple.com/documentation/foundationmodels/contextoptions)

### Prompt Attachments (Beta)

* Analyzing images with multimodal prompting
  [https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting)
* `Attachment` (struct)
  [https://developer.apple.com/documentation/foundationmodels/attachment](https://developer.apple.com/documentation/foundationmodels/attachment)
* `ImageAttachment` (struct)
  [https://developer.apple.com/documentation/foundationmodels/imageattachment](https://developer.apple.com/documentation/foundationmodels/imageattachment)
* `ImageReference` (struct)
  [https://developer.apple.com/documentation/foundationmodels/imagereference](https://developer.apple.com/documentation/foundationmodels/imagereference)

### Dynamic Profiles (Beta)

* Composing dynamic sessions with instructions and profiles
  [https://developer.apple.com/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles](https://developer.apple.com/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles)
* Origami: Crafting a dynamic tutorial for Apple Intelligence (sample code)
  [https://developer.apple.com/documentation/foundationmodels/origami-crafting-a-dynamic-tutorial-for-apple-intelligence](https://developer.apple.com/documentation/foundationmodels/origami-crafting-a-dynamic-tutorial-for-apple-intelligence)
* `DynamicInstructions` (protocol)
  [https://developer.apple.com/documentation/foundationmodels/dynamicinstructions](https://developer.apple.com/documentation/foundationmodels/dynamicinstructions)
* `Profile` (struct)
  [https://developer.apple.com/documentation/foundationmodels/profile](https://developer.apple.com/documentation/foundationmodels/profile)
* `DynamicProfile` (protocol)
  [https://developer.apple.com/documentation/foundationmodels/dynamicprofile](https://developer.apple.com/documentation/foundationmodels/dynamicprofile)
* `@SessionProperty` (macro)
  [https://developer.apple.com/documentation/foundationmodels/sessionproperty](https://developer.apple.com/documentation/foundationmodels/sessionproperty)

### Structured Output (Guided Generation)

* Generating Swift data structures with guided generation
  [https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
* `Generable` (protocol)
  [https://developer.apple.com/documentation/foundationmodels/generable](https://developer.apple.com/documentation/foundationmodels/generable)
* `GenerationSchema` (struct)
  [https://developer.apple.com/documentation/foundationmodels/generationschema](https://developer.apple.com/documentation/foundationmodels/generationschema)
* `DynamicGenerationSchema` (struct)
  [https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema](https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema)
* `GenerationGuide` (enum)
  [https://developer.apple.com/documentation/foundationmodels/generationguide](https://developer.apple.com/documentation/foundationmodels/generationguide)
* `GeneratedContent` (struct)
  [https://developer.apple.com/documentation/foundationmodels/generatedcontent](https://developer.apple.com/documentation/foundationmodels/generatedcontent)

### Tool Calling

* Expanding generation with tool calling
  [https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling)
* `Tool` (protocol)
  [https://developer.apple.com/documentation/foundationmodels/tool](https://developer.apple.com/documentation/foundationmodels/tool)
* `ToolCallMode` (enum)
  [https://developer.apple.com/documentation/foundationmodels/toolcallmode](https://developer.apple.com/documentation/foundationmodels/toolcallmode)

### System Language Model

* Supporting languages and locales with Foundation Models
  [https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)
* Categorizing and organizing data with content tags
  [https://developer.apple.com/documentation/foundationmodels/categorizing-and-organizing-data-with-content-tags](https://developer.apple.com/documentation/foundationmodels/categorizing-and-organizing-data-with-content-tags)
* `SystemLanguageModel` (class)
  [https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
* `SystemLanguageModel.UseCase` (struct)
  [https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/usecase](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/usecase)

### Private Cloud Compute (Beta)

* Adding server-side intelligence with Private Cloud Compute
  [https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
* `PrivateCloudComputeLanguageModel` (class) — iOS 27+, macOS 27+
  [https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel)
* `com.apple.developer.private-cloud-compute` (entitlement)
  [https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.private-cloud-compute](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.private-cloud-compute)

### Performance and KV Cache

* Optimizing key-value caching in language model sessions
  [https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions](https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions)

### Custom Adapter

* Loading and using a custom adapter with Foundation Models
  [https://developer.apple.com/documentation/foundationmodels/loading-and-using-a-custom-adapter-with-foundation-models](https://developer.apple.com/documentation/foundationmodels/loading-and-using-a-custom-adapter-with-foundation-models)

### Custom Language Model Provider (Beta)

* `LanguageModel` (protocol)
  [https://developer.apple.com/documentation/foundationmodels/languagemodel](https://developer.apple.com/documentation/foundationmodels/languagemodel)
* `LanguageModelCapabilities` (struct)
  [https://developer.apple.com/documentation/foundationmodels/languagemodelcapabilities](https://developer.apple.com/documentation/foundationmodels/languagemodelcapabilities)
* `LanguageModelExecutor` (protocol)
  [https://developer.apple.com/documentation/foundationmodels/languagemodelexecutor](https://developer.apple.com/documentation/foundationmodels/languagemodelexecutor)
* `LanguageModelExecutorGenerationChannel` (struct)
  [https://developer.apple.com/documentation/foundationmodels/languagemodelexecutorgenerationchannel](https://developer.apple.com/documentation/foundationmodels/languagemodelexecutorgenerationchannel)
* `LanguageModelExecutorGenerationRequest` (struct)
  [https://developer.apple.com/documentation/foundationmodels/languagemodelexecutorgenerationrequest](https://developer.apple.com/documentation/foundationmodels/languagemodelexecutorgenerationrequest)

### Safety

* Improving the safety of generative model output
  [https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output)
* `SystemLanguageModel.Guardrails` (struct)
  [https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/guardrails](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/guardrails)

### Feedback

* `LanguageModelFeedback` (struct)
  [https://developer.apple.com/documentation/foundationmodels/languagemodelfeedback](https://developer.apple.com/documentation/foundationmodels/languagemodelfeedback)

### Token Usage (Beta)

* `LanguageModelSession.Usage` (struct)
  [https://developer.apple.com/documentation/foundationmodels/languagemodelsession/usage](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/usage)
