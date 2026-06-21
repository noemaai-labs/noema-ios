# AGENTS.md

## Repository purpose
Noema is an offline-first iOS and iPadOS assistant that combines on-device large-language models with curated and user-supplied documents so private data never leaves the device. The README describes Hugging Face model search, retrieval-augmented datasets, tool-calling, RAM budgeting, and other core capabilities that the rest of the repository implements.【F:README.md†L3-L48】

## Top-level layout
- `Noema/` — Main SwiftUI application target. It wires shared view models into the root scene (`ContentView`) and tab-based shell (`MainView`), manages onboarding, download overlays, guided walkthroughs, and binds chat, model, dataset, and download managers that persist for the lifetime of the app.【F:Noema/ContentView.swift†L4-L74】【F:Noema/MainView+iOS.swift†L7-L150】
- `NoemaEmbeddingActivity/` — WidgetKit bundle scaffolded for Live Activities and lock-screen widgets around dataset indexing progress. It currently renders a simple timeline entry UI driven by an `AppIntent` configuration.【F:NoemaEmbeddingActivity/NoemaEmbeddingActivity.swift†L9-L89】
- `Sources/RollingThought/` — Reusable Swift package that exposes the rolling-thought transcript UI and view model used by the chat interface to stream and persist model tokens.【F:Sources/RollingThought/RollingThought.swift†L1-L111】【F:Sources/RollingThought/RollingThought.swift†L168-L183】
- `Sources/RelayKit/` — CloudKit relay helpers for syncing conversations across devices or server processes. `CloudKitRelay` encapsulates posting, polling, push-subscription management, and using an `InferenceProvider` to generate remote replies.【F:Sources/RelayKit/CloudKitRelay.swift†L4-L126】
- `Sources/NoemaPackages/` — Convenience module that re-exports the embedded llama XCFramework and RollingThought package for consumption by the app targets.【F:Sources/NoemaPackages/NoemaPackages.swift†L1-L10】
- `LMStudioRESTAPI.md`, `OllamaAPI.md`, and `OpenAIAPI.md` — Reference documentation for third-party endpoints supported by Noema’s remote backend adapters, including LM Studio’s REST interface with model discovery and chat/embedding endpoints.【F:LMStudioRESTAPI.md†L1-L146】

## Core systems inside `Noema/`
### UI composition and navigation
`ContentView` is the top-level SwiftUI entry point. It instantiates and injects `TabRouter`, `ChatVM`, `AppModelManager`, `DatasetManager`, `DownloadController`, and `GuidedWalkthroughManager`, handling splash and onboarding presentation before handing off to the main tab experience.【F:Noema/ContentView.swift†L4-L74】

`MainView` hosts the Chat, Stored datasets, Explore, and Settings tabs, layers global overlays for indexing and model-loading notifications, coordinates walkthrough highlights, and auto-loads the user’s preferred model while respecting offline (“off-grid”) mode.【F:Noema/MainView+iOS.swift†L42-L183】

### Model lifecycle and remote backends
`AppModelManager` extensions orchestrate local model metadata as well as user-configured remote inference backends. The remote-backend helper handles validation, persistence, deduplication, optimistic updates, and asynchronous refresh of model listings (including special handling for Ollama host validation).【F:Noema/AppModelManager+RemoteBackends.swift†L4-L172】

Bridging code in `LlamaRunner.mm` connects Swift to llama.cpp/llava/clip implementations, negotiates KV cache quantization, and exposes compatibility shims for varying llama.cpp builds so on-device GGUF execution works across Apple toolchains.【F:Noema/LlamaRunner.mm†L1-L200】

### Inference backend policy
- GGUF must always load through the compiled llama.cpp path (`NoemaLlamaClient` / `LlamaRunner`).
- Leap SDK must not be used for GGUF loading.
- Leap SDK is allowed only for ExecuTorch `.bundle` (SLM) loading flows.

### Dataset ingestion and retrieval
`DatasetManager` discovers, selects, and tracks local datasets on disk, coalescing progress updates, resuming indexing pipelines, coordinating with the download controller to fetch embedding models, and cleaning up embeddings when users delete a dataset.【F:Noema/DatasetManager.swift†L6-L195】

### Tooling and streaming UI
The Rolling Thought module provides an observable view model that consumes async token streams, tracks logical completion, supports expansion/collapse, and persists thought “boxes” between launches—functionality consumed by the chat UI to display structured reasoning traces.【F:Sources/RollingThought/RollingThought.swift†L5-L111】【F:Sources/RollingThought/RollingThought.swift†L168-L213】

RelayKit’s CloudKit bridge allows the app or companion services to write and poll `RelayEnvelope` records, trigger server-side inference, and subscribe to changes so remote responses arrive in near real time.【F:Sources/RelayKit/CloudKitRelay.swift†L17-L126】

## Extending or integrating
- Use the Hugging Face, Open Textbook Library, and document-import features documented in the README when wiring new dataset sources or retrieval strategies; the design expects retrieval-augmented workflows rather than ever-larger model weights.【F:README.md†L7-L48】
- To integrate additional inference backends, follow the patterns in `AppModelManager+RemoteBackends.swift`—validate drafts, persist configuration through `RemoteBackendsStore`, and surface connection summaries so the UI can report success or failure.【F:Noema/AppModelManager+RemoteBackends.swift†L18-L172】
- When adding new streaming visualizations or reasoning inspectors, build on the `RollingThoughtViewModel` protocol-based token streaming so the chat interface retains consistent state restoration semantics.【F:Sources/RollingThought/RollingThought.swift†L5-L213】
- For cloud relays or shared conversations, hook into `CloudKitRelay` by providing an `InferenceProvider` implementation. The helper already manages CloudKit records, subscriptions, and error handling for pending responses.【F:Sources/RelayKit/CloudKitRelay.swift†L17-L126】

## Localization
- All new UI strings (titles, headings, menus, buttons, alerts, tooltips, section labels) must be added to `Localizable.strings` for every supported language.
- Use `LocalizedStringKey` (e.g., `Text("Some Key")`) instead of hard-coded literals so translations apply automatically.
- Ensure new features honor the in-app language override in Settings and default to the system language on first launch.
- Do not add sentence-style explanatory text under obvious settings. Keep inline explanations only for vague or risky controls, and put longer descriptions behind a question-mark help affordance.

## Additional assets
- Xcode project files (`Noema.xcodeproj`, `Info.plist` variants) configure iOS, visionOS, and widget targets plus entitlements required for local networking, downloads, and potential relay services.
- `Makefile` and documentation markdown files at the root assist with building, packaging, or referencing third-party APIs when extending the app.

## Linting
- For small UI fixes, there is no need to run a build through xcode,
