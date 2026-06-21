# Managing the context window

Manage the tokens available to a session so the model can always process new requests.

Source: https://developer.apple.com/documentation/foundationmodels/managing-the-context-window

## Overview

Apple's on-device foundation model operates within a fixed **context window of 4096 tokens per session** (32K tokens when using Private Cloud Compute). Each interaction — including prompts, instructions, tool definitions, schemas, and responses — consumes tokens from this budget.

Understanding and managing the context window is essential for building reliable AI features in your app.

## Token Fundamentals

Token representation varies by language:

* Latin alphabet languages: typically 3–4 characters per token
* Multibyte languages (Chinese, Japanese, Korean, Vietnamese): typically 1 character per token

Use `SystemLanguageModel.tokenCount(for:)` to measure prompt token consumption and `SystemLanguageModel.contextSize` to retrieve maximum supported tokens.

## Profiling in Xcode

Access the Foundation Models instrument via:

1. Product > Profile
2. Select Foundation Models template
3. Click Record Trace to capture interactions

The instrument displays a timeline where "the width of each component on the timeline indicates latency." It reveals opportunities for optimization including prompt reduction, response limiting, generable type management, and session segmentation.

## Token Optimization Strategies

### Concise Prompts

* Use imperative verbs ("Generate..." or "List...")
* Include only necessary information
* Limit to three paragraphs maximum
* Eliminate indirect language and jargon

### Limiting Model Output

Specify desired response length: "In three sentences..." or use `@Guide` macros with `maximumCount(_:)` for generable arrays.

Important caveat: "Limiting tokens can cause the model to generate incomplete or grammatically incorrect responses."

### Simplifying Generable Types

Keep types focused with clear property names. Add `@Guide` descriptions selectively, as they increase schema size sent to the model.

Test without `@Guide` annotations first, then add them only for unclear properties.

### Efficient Tool Usage

* Limit tool descriptions to short phrases
* Provide 3–5 tools maximum per request
* Consider retrieving needed information directly rather than via tool calling

For complex workflows, split tool generation across sessions: generate arguments in one session, execute tools, then process output in a new session.

### Reducing Schema Repetition

Setting `includeSchemaInPrompt` to `false` can reduce redundant schema information, potentially saving hundreds of tokens per request when making similar requests. This optimization is effective after initial model interactions establish context.

## Handling Context Overflow

When `LanguageModelError.contextSizeExceeded(_:)` is thrown:

1. Create a new session with preserved context
2. Summarize original transcript or extract key entries
3. Initialize new session with condensed transcript

Preserve "the first and last entry" because the first typically contains instructions and the last contains recent context.

## Multi-Session Task Division

For large tasks exceeding context limits:

1. Split content into context-window-sized chunks
2. Summarize each chunk in separate sessions
3. Include previous summaries in subsequent prompts for continuity
4. Combine final summaries in a new session

This chunking approach maintains narrative flow while respecting token constraints.

## Related API References

* `LanguageModelSession`
  [https://developer.apple.com/documentation/foundationmodels/languagemodelsession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
* `LanguageModelError.contextSizeExceeded(_:)`
  [https://developer.apple.com/documentation/foundationmodels/languagemodelerror/contextsizeexceeded(_:)](https://developer.apple.com/documentation/foundationmodels/languagemodelerror/contextsizeexceeded(_:))
* `SystemLanguageModel.tokenCount(for:)`
  [https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/tokencount(for:)](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/tokencount(for:))
* `SystemLanguageModel.contextSize`
  [https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize)
* `GenerationOptions.maximumResponseTokens`
  [https://developer.apple.com/documentation/foundationmodels/generationoptions/maximumresponsetokens](https://developer.apple.com/documentation/foundationmodels/generationoptions/maximumresponsetokens)
* Optimizing key-value caching in language model sessions
  [https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions](https://developer.apple.com/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions)
