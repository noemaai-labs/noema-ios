# Noema Next Steps Ideas

Generated from the repository state on 2026-05-31.

## Current State Snapshot

Noema is already more than a simple chat shell. The app has a SwiftUI tab shell for Chat, Stored datasets, Explore, and Settings; onboarding and guided walkthroughs; model and dataset managers; model downloads; document ingestion; local retrieval; tool middleware; remote backend support; CloudKit relay plumbing; Whisper transcription; and a WidgetKit scaffold for indexing progress.

The local LLM runtime is broad and actively evolving:

- **GGUF runs through llama.cpp via `NoemaLLamaServer` loopback.** `ChatVM` starts the embedded server for GGUF loads, then `NoemaLlamaClient` talks to `/completion` and `/v1/chat/completions`. This is now the single GGUF execution path.
- **Leap is not used for GGUF.** The code explicitly forces `.gguf` for `.gguf` paths and reserves ExecuTorch/Leap-style paths for ET `.pte` model programs.
- **GGUF runtime supports serious knobs.** Context length, GPU layer count, CPU threads, KV cache offload, mmap, warmup, Flash Attention, K/V quantization, seed, sampling, RoPE scaling, logit bias, prompt cache env vars, tensor overrides, MoE active expert overrides, and MTP draft settings are represented in `ModelSettings`.
- **GGUF vision exists.** Projector discovery checks sibling projectors and merged projector metadata. Image attachments are normalized/re-encoded and sent as OpenAI-style image URL content to the loopback server.
- **Template-specific behavior exists.** The bridge uses template-driven support for Qwen 3.5 and Gemma 4, including Jinja templates and reasoning settings.
- **MTP speculative decoding exists but is still a power feature.** MTP settings are surfaced and passed to the bridge when an embedded MTP head or sidecar exists. Runtime diagnostics can record draft token counts and acceptance.
- **Helper-model speculative decoding is partly modeled.** Settings can describe a helper draft model and env vars are set on non-macOS, but this looks less first-class than MTP in the loopback bridge.
- **MLX, ET, CML, and AFM paths are present.** MLX has text/VLM client selection, ET resolves `.pte` plus tokenizer artifacts and exposes repair flows, CML/ANE has a full resolver/runtime path, and AFM uses Apple Foundation Models where supported.
- **Benchmarking exists.** `ModelBenchmarkService` measures prompt rate, generation rate, time to first token, memory deltas, and speculative timing metadata.
- **RAG is mature enough to build product workflows on.** Dataset ingestion, chunk retrieval, full-content-vs-RAG injection info, citations, and dataset status all exist.
- **Tooling is broad.** The app has web retrieval, Python execution, memory tools, and tool gating by backend/format, with different strategies for llama.cpp, MLX, ET, AFM, and remote sessions.
- **Remote backends are no longer an afterthought.** LM Studio, Ollama, Noema relay, CloudKit relay, remote model listings, remote load/eject, and LAN/cloud transport state are represented.

## Product North Star

Noema can become the private operating layer for personal knowledge: local models, local documents, local tools, local memories, and optional user-owned remote compute, all orchestrated by a device-aware runtime that explains what it is doing.

## Runtime And Local LLM Ideas

- ✅ Build a **Model Doctor** screen that runs load, prompt, image, tool, and unload probes and produces a human-readable compatibility report.
- ✅ Add a **first-run auto-tuner** that benchmarks context length, KV quantization, thread count, GPU layer policy, and Flash Attention for each installed model.
- ✅ Add a **Safe Context Slider** that marks "fits comfortably", "borderline", and "likely crash" zones using `ModelRAMAdvisor`.
- ✅ Add a **Runtime Timeline** showing load start, mmap, KV allocation, prompt processing, first token, generation, tools, and unload.
- ✅ Add a **MTP acceptance dashboard** with draft tokens, accepted tokens, acceptance rate, and speed delta against non-MTP baseline.
- ✅ Add **one-tap MTP validation** that checks embedded heads, sidecars, file naming, bridge start options, and model compatibility.
- ✅ Add a **Speculative Decoding Wizard** that recommends MTP vs helper-model speculation based on installed models.
- ✅ Add **helper draft model pairing** that finds smaller same-architecture GGUFs already installed.
- Add a **prompt cache manager** with cache size, cache path, hit-rate estimate, clear button, and per-chat enablement. A dedicated Settings screen showing the on-disk size of the llama.cpp prompt cache, an estimated hit rate based on recent conversations, a one-tap clear button, and a per-chat toggle to opt individual conversations out of caching.
- ✅ Add **per-model runtime presets**: Battery Saver, Balanced, Max Speed, Max Context, Vision Heavy, Tool Heavy.
- ✅ Add a **live memory pressure meter** during model loading and generation.
- Add **automatic context fallback** when a GGUF load fails from memory pressure, suggesting a smaller context without silently changing saved settings. When a load fails with an OOM signal, a sheet offers to retry with a recommended smaller context length; the saved setting is untouched so the user's preferred value is preserved for future hardware.
- ✅ Add a **background unload policy** that unloads large models after inactivity but keeps lightweight ET/CML models ready.
- ✅ Add **token latency sparklines** to show stalls, thermal throttling, and prompt-processing phases.
- ✅ Add **thermal-aware generation mode** that reduces threads or output limits when the device heats up.
- ✅ Add **battery-aware generation mode** that auto-switches from GGUF to ET/CML/AFM when available.
- ✅ Add **GGUF metadata inspector** for architecture, context training length, tokenizer, chat template, MoE, projector, and MTP support.
- ✅ Add **chat template preview** so users can see how messages render before generation.
- ✅ Add **template override diffing** showing curated vs extracted vs default prompt templates.
- ✅ Add **model load receipts** containing bridge argv, selected template, env knobs, memory estimate, and readiness probe status.
- ✅ Add **local server health view** for loopback port, health endpoint status, loading progress, and last diagnostics.
- ✅ Add **structured error remediation** for loopback failures: lower context, disable Flash Attention, disable KV offload, switch K/V quant, remove projector, repair model.
- ✅ Add **model unload verification** that confirms memory actually returns after eject.
- ✅ Add **vision projector matching UI** that lets users pair, replace, or validate `.mmproj`/projector GGUFs.
- ✅ Add **multi-image budget estimator** before sending large image sets to VLMs.
- ✅ Add **image preflight thumbnails** showing normalized dimensions and file sizes before prompt submission.
- Add a **vision benchmark suite** with OCR, chart reading, scene description, and multi-image comparison. A structured benchmark mode in the Model Doctor that runs a fixed set of VLM probes (a printed-text OCR image, a bar chart, a scene photograph, and a two-image comparison); each probe shows pass/fail and the model's generated answer so users can evaluate vision quality without crafting their own tests.
- Add an **offline model leaderboard on device** using user-run benchmarks, never uploaded unless explicitly exported. A ranked table in Explore built from the user's own stored benchmark runs (prompt rate, generation rate, TTFT, vision scores); never synced remotely, with an explicit export-to-JSON button for sharing.
- ✅ Add **per-device recommended model shelf** based on real benchmark results instead of static curated ordering.
- ✅ Add **developer diagnostics export** that bundles logs, load receipts, benchmark JSON, and model metadata without user chats.

## Chat Experience Ideas

- Add **conversation workspaces** with pinned models, datasets, tools, and system prompt presets. Named slots (e.g. "Thesis", "Work Project", "Travel") that persist a model selection, active datasets, enabled tools, and a system prompt together; switching workspaces swaps all four at once without touching global settings.
- Add **branching conversations** from any assistant or user message (partially implemented). The fork action exists but the branch tree UI — showing the conversation history as a navigable tree with ancestor threads visible as read-only — remains to be built.
- Add **message-level regenerate with changed settings** and a side-by-side output comparison (Noema Mac). A per-message action that opens a compact settings popover (temperature, context, model) and on confirm regenerates only that turn; both the original and new responses are shown side by side with a "keep this one" button.
- Add **local debate mode** where two installed models answer and a third model synthesizes (Noema Mac only). A special conversation type where the user enters a question, two installed models each generate a position, and an optional third model produces a synthesis or verdict; the whole exchange is shown as a structured three-panel thread.
- Add **answer audit mode** that asks the model to mark unsupported claims. A one-tap action on any assistant message that re-sends it with an instruction to annotate each claim as "supported", "inferred", or "unsupported"; the annotations are rendered as inline badges on the original response text.
- ✅ Add **automatic follow-up suggestions** grounded in the active dataset.
- Add **conversation compaction controls** that show what will be summarized or dropped before context overflow. Before the context window fills, a warning banner appears showing exactly which earlier messages will be summarised or dropped, with a per-message keep/drop toggle and a "compact now" button so the user controls what is preserved.
- ✅ Add **visual context meter** with system prompt, history, retrieved chunks, tool results, images, and reserved output tokens.
- ✅ Add **"pin this message into memory"** with explicit user approval and scope selection.
- Add **temporary memory mode** for the current project only. A toggle in the chat header that scopes any memories saved during the conversation to the current chat only; when the chat closes those memories are discarded without affecting the global memory store.
- ✅ Add **private scratchpad notes** attached to a chat but never sent unless referenced.
- ✅ Add **per-chat local persona/system prompt** with inheritance from global defaults.
- Add **chat snapshots** that freeze model, settings, datasets, and prompts for reproducibility. A "snapshot" action that freezes the current conversation's model, settings, active datasets, and system prompt into a named restorable checkpoint, so the user can return to an exact configuration later regardless of subsequent global settings changes.
- ✅ Add **inline tool activity cards** with arguments, elapsed time, result preview, and retry.
- Add **failed tool recovery** that lets the user edit tool arguments and rerun. When a tool call returns an error, an inline card shows the failed arguments with editable fields and a retry button; the corrected call is re-run and the conversation continues as if the first attempt had succeeded.
- Add **"continue offline" handoff** when a remote backend disconnects, switching to the best local model. When a remote backend drops mid-conversation, a banner offers to switch to the best locally installed model that fits in RAM; the conversation history is preserved and the new model is loaded automatically.
- Add **"continue on Mac" handoff** when a local mobile model is too small for the task. On iPhone or iPad, a button appears when the active model is near its RAM limit offering to hand off to the Mac relay; the relay loads the same model if available and the conversation resumes with full context.
- ✅ Add **voice-first chat mode** with local Whisper input and spoken responses.
- Add **meeting mode** as a dedicated top-level tab that records/transcribes locally, summarizes, and extracts actions. The tab runs Whisper transcription continuously in the background, then on stop presents a structured summary (key points, decisions, action items) generated locally; the transcript and summary are saved as a dataset entry.
- Add a **document Q&A sidebar** for asking about the currently open dataset file (Noema Mac only). A slide-in panel in the Datasets tab that lets the user ask questions about a single open file without entering a full chat; the panel maintains a short Q&A history tied to that file and uses it as the sole retrieval source.
- Add **message bookmarks** and semantic search across previous chats. A bookmark action on any message that saves it to a local index; a search screen across all bookmarked and recent messages lets the user find past answers by meaning rather than exact text.
- ✅ Add **chat-to-note conversion** into a clean local Markdown note.
- ✅ Add **answer export packs**: Markdown, PDF, DOCX, citations JSON, and prompt receipt.

## Dataset And RAG Ideas

- ✅ Add **RAG Inspector** showing query rewrite, retrieved chunks, scores, trimmed chunks, and injected context.
- Add a **chunk browser** with search, previews, source file, token estimate, and reindex status. A scrollable list inside a dataset's detail view showing every indexed chunk with its source file, character range, token count estimate, embedding freshness, and a reindex-this-chunk button; supports full-text search across all chunks in the dataset.
- ✅ Add **dataset health check** for unsupported files, failed parses, stale embeddings, and missing active embedding model.
- Add **incremental reindexing** when files change instead of full rebuilds. When a source file changes on disk, only the affected chunks are re-embedded rather than the whole dataset; a file watcher or a manual "sync changed files" button drives this, and a small "N chunks updated" badge appears on the dataset.
- Add a **dataset diff view** showing added/removed/changed chunks after reindex. After a reindex, a summary screen lists chunks added, removed, or meaningfully changed (by cosine distance of their new vs old embedding), giving the user confidence that the index reflects the latest document state.
- Add an **OCR pipeline** for scanned PDFs and images. A processing step during ingestion that detects image-only PDF pages or standalone image files and runs an on-device OCR pass (Vision framework or a small local model) to extract text before chunking and embedding.
- Add **table extraction** for PDFs, CSVs, TSVs, and spreadsheets. A structured extraction pass during ingestion that detects tables and converts them to Markdown table syntax, so tabular data is retrievable in a readable form rather than as a blob of whitespace-separated values.
- Add an **EPUB chapter map** with semantic chapter selection. An EPUB ingestion UI that displays the book's chapter tree and lets the user select which chapters to index, enabling chapter-granular dataset builds without importing the entire book.
- Add **dataset tags and smart collections**. A tagging UI on the dataset list where users assign free-form tags; smart collections are saved tag queries (e.g. "all datasets tagged 'legal'") that automatically include matching datasets when RAG is active.
- Add **dataset-level system prompts** such as "answer as a tutor" or "quote legal clauses exactly". A text field in each dataset's settings that appends a role instruction to the system prompt whenever that dataset is active, without requiring the user to edit the global system prompt.
- Add **source reliability labels** controlled by the user. A per-file or per-dataset reliability rating ("primary source", "reference", "draft", "unverified") set by the user and surfaced alongside citations so the model and user can weight conflicting information appropriately.
- ✅ Add a **conflicting-source detector** for datasets with inconsistent claims.
- Add **multi-dataset routing** where the app chooses which dataset to search based on the question. A classifier layer before retrieval that scores each active dataset's relevance to the incoming query and retrieves only from the top-ranked datasets, preventing noise from unrelated collections from polluting the context.
- Add **full-document reading mode** for small documents that fit in context. When a document fits within the model's context limit, an option to bypass RAG and inject the entire text verbatim as a system-level reference block, trading retrieval precision for full coverage.
- Add **query expansion controls** for exact search vs semantic broad search. A toggle in RAG settings between "exact / keyword" mode (BM25-style) and "semantic / broad" mode (embedding similarity), plus a hybrid slider, giving power users control over retrieval recall vs precision.
- Add a **local concept map** generated from a dataset. A generated graph view (nodes = key concepts, edges = relationships) produced by asking the loaded model to extract entities and connections from a dataset's chunks; rendered as an interactive canvas for navigating large knowledge bases.
- Add **flashcard generation** from textbook chapters. A dataset action that prompts the model to produce question/answer pairs from a selected chapter or set of chunks, stores them in a local deck, and presents them in a swipe-based review UI with spaced repetition tracking.
- Add **practice quiz mode** with answers cited to source pages. A structured quiz session where the model generates multiple-choice or short-answer questions from the active dataset, checks the user's answers, and cites the source page for each correct answer.
- Add **paper review mode** extracting claims, methods, datasets, limitations, and follow-up experiments. A dataset action on an academic PDF that produces a structured extraction formatted as a collapsible outline with inline citations, covering claims, methodology, datasets used, stated limitations, and proposed follow-up experiments.
- Add **legal brief mode** for facts, issues, rules, analysis, and cited excerpts. A dataset action that produces a structured brief from legal documents — facts, issues raised, applicable rules, analysis, and relevant excerpts with paragraph citations — formatted for quick review without reading the full text.
- Add a **dataset sharing package** that exports source files, index metadata, and citations while preserving privacy. An export action that bundles the source files, the chunk manifest (but not the raw embeddings), and a citation index into a signed ZIP that a recipient can import; no chat history is included.
- Add **encrypted dataset vaults** with per-vault passcodes or biometrics. A vault option when creating a dataset that encrypts the source files and the embedding index on disk behind a per-vault passcode or biometric; the vault must be unlocked before it appears in the RAG context.
- ✅ Add **dataset indexing Live Activity** beyond the current widget scaffold.

## Explore And Model Library Ideas

- ✅ Add **model install recommendations by task**, not just by format.
- ✅ Add **"works on my device" badges** based on benchmark and RAM advisor data.
- ✅ Add **download plan preview** listing weights, tokenizers, projectors, sidecars, and expected disk use.
- ✅ Add **model dependency graph** for tokenizer/config/projector/MTP files.
- ✅ Add **repair all models** action for missing tokenizers, projectors, config files, and stale partial downloads.
- ✅ Add **model collections**: tiny fast, reasoning, vision, coding, math, multilingual, tool-capable.
- Add a **"try before full install" remote probe** through LM Studio/Ollama when available. When a Mac running LM Studio or Ollama is detected on the LAN, a "Try it" button on the Explore model card lets the user send a single prompt to that remotely hosted model before committing to a multi-GB local download.
- ✅ Add **curated model notes** explaining best settings per model family.
- ✅ Add **quant comparison view** showing size, quality expectation, speed, RAM, and context tradeoffs.
- ✅ Add **MoE-specific guidance** for active experts, memory estimates, and expected behavior.
- ✅ Add **model aliases** so users can rename installed models.
- ✅ Add **duplicate detector** for same model/quant installed from different repos.
- ✅ Add **storage cleanup assistant** ranked by reclaimable space and last used date.
- ✅ Add **download scheduling** for overnight Wi-Fi/charging.
- Add **LAN model pull** from a Mac relay to iPhone/iPad. A transfer flow that discovers a Mac relay on the local network and streams a GGUF file over LAN directly into the iPhone/iPad model directory, showing per-file progress and resuming partial transfers across sessions.
- Add an **import wizard** for local GGUF, MLX folders, ET folders, and CML bundles. A step-by-step sheet triggered by dropping a file or folder onto the app that identifies the model format, validates required sidecar files, flags missing projectors or tokenizers, and registers the model in the local library.
- ✅ Add **model provenance page** with repo, license, files, checksums, install date, and local path.
- ✅ Add **license warning surface** before downloading restrictive models.
- ✅ Add **offline Explore cache** containing previously viewed models and docs.
- ✅ Add **model update checker** that compares installed files against repo revisions.

## Tools And Agentic Workflow Ideas

- ✅ Add a **Tool Store** page for enabling, disabling, and testing local tools.
- ✅ Add **tool permissions per chat**: web, Python, memory, dataset retrieval — toggled in the bar above the input box.
- ✅ Add **dry-run tool mode** where the assistant proposes tool calls and waits for approval before executing.
- Add **Python notebook tool output** with tables, charts, files, and execution logs. When the Python tool runs code that produces tabular data, matplotlib figures, or file outputs, the results are rendered inline in the chat as a styled table, an image, or a downloadable file link rather than raw printed text.
- Add a **local chart renderer** for Python-generated plots. A built-in renderer that accepts a Vega-Lite or simple JSON chart spec produced by the Python tool or the model and renders it as a native SwiftUI chart in the conversation, without requiring a web view.
- Add **tool result pinning** so retrieved data stays available across follow-up turns. A pin icon on any tool result card (web page, Python output, dataset chunk) that locks it into the context for subsequent turns even after it would normally scroll out of the active window, useful for multi-step research tasks.
- ✅ Add **tool-call simulator tests** for each backend/model family.
- ✅ Add **OpenAI-style native tool calls for loopback** where supported, falling back to prompt-based calls.
- Add **JSON schema constrained output UI** for extracting structured data from documents. A schema editor in the chat or dataset detail view where the user describes the shape of data they want extracted (field names, types, required/optional); the model is instructed to respond only with valid JSON matching that schema, and the output is rendered as a structured form.
- Add **automation recipes**: summarize this folder weekly, quiz me daily, watch this dataset for changes. A Shortcuts-style recipe builder where the user defines a trigger (e.g. "every Monday morning", "when a new file is added to this folder") and an action (summarise, quiz, send a digest to Notes); recipes run as background jobs and notify on completion.
- Add **offline web archive search** by importing saved pages or browser exports. An import flow accepting Safari's webarchive exports or a folder of saved HTML files; they are parsed, stripped, chunked, and embedded like any other dataset so the user can retrieve from previously visited pages without a live connection.
- ✅ Add **local calculator and unit converter tools** as fast deterministic tools.
- Add **file transformation tools**: convert PDF to Markdown, CSV to chart, transcript to minutes. A set of deterministic tools the model can call (or the user can trigger directly): PDF-to-Markdown extraction, CSV-to-chart, audio transcript-to-structured-minutes, and image-to-OCR-text, each running locally and returning the result as a dataset entry or a downloadable file.
- ✅ Add **private memory review inbox** showing proposed memories before saving.
- Add **memory expiry dates** and per-memory scopes. A date picker on each saved memory entry that schedules automatic deletion; the memory store periodically prunes expired entries and shows an expiry badge in the memory review UI.
- Add a **memory conflict detector** when a new memory contradicts an old one. Before saving a new memory, a semantic similarity check against existing memories flags potential contradictions and asks the user whether to replace, merge, or keep both.
- Add an **agent plan view** with editable steps for longer local workflows. Before executing a multi-step agentic task, the model's planned steps are shown as an editable checklist; the user can reorder, remove, or edit any step before approving execution, and progress is shown step by step as the agent runs.
- Add **interruptible agent tasks** where users can approve each action. During an active multi-step agentic run, a persistent banner shows the current step and a pause button; tapping pause suspends execution after the current tool call completes and presents the remaining plan for review or editing before resuming.
- ✅ Add a **background task queue** for indexing, transcription, summarization, and benchmark jobs.
- ✅ Add **local notification summaries** for completed background jobs.

## Remote And Relay Ideas

- ✅ Add **local-vs-remote router** that chooses local, LAN relay, or cloud relay based on privacy, model size, network, and battery.
- ✅ Add **relay readiness panel** showing host device, active model, transport, streaming support, and queue depth.
- Add a **Mac relay model scheduler** that keeps a requested model warm during a mobile session. A setting on the Mac relay that accepts a schedule from a mobile device ("keep Llama-3-8B warm from 8am–10pm") and pre-loads the requested model before the mobile session connects, eliminating the cold-start wait on the mobile side.
- Add **handoff prompt receipt** so the remote machine receives the same system prompt, datasets, and tool availability. When routing a conversation to a relay or remote backend, the current system prompt, active dataset names, enabled tools, and conversation history digest are transmitted alongside the generation request so the remote model has the same context as a local session would.
- Add **remote eject policies** per backend: never, on disconnect, after inactivity, on battery. A per-remote-backend setting controlling whether the relay unloads the model automatically (never / on disconnect / after N minutes idle / when battery drops below a threshold), preventing the Mac from keeping large models warm unnecessarily.
- ✅ Add **remote download manager** for LM Studio endpoints, currently GGUF-focused, with progress and retry UI.
- ✅ Add **LAN-first fallback to CloudKit** with explicit privacy explanation.
- Add a **remote tool compatibility matrix** for LM Studio, Ollama, Noema relay, and cloud relay. A read-only table in remote backend settings showing which tools (web, Python, memory, dataset retrieval) are available for each configured backend, with a warning badge when the active chat uses a tool the selected remote backend cannot handle.
- Add **remote latency comparison** against local model benchmarks. A line in the relay readiness panel showing measured round-trip latency and tokens-per-second for the remote backend alongside the local benchmark result for the same model, so the user can make an informed routing choice.
- Add a **pairing QR code** for Mac/iPhone relay setup. A QR code displayed on the Mac relay screen that encodes the relay URL, auth token, and local network address; scanning it on iPhone/iPad adds and configures the relay backend in one step without manual URL entry.
- ✅ Add **relay audit log** of commands, loads, generations, ejects, and failures.
- Add **per-backend model settings sync** so context and sampling travel with remote models. A "sync settings with remote" toggle per remote backend that serialises the current ModelSettings (context length, temperature, sampling parameters) into the remote request so the remote session uses identical generation config to the local one.

## Multimodal Ideas

- Add **camera ask mode** for quick local VLM questions. A camera button in the chat composer that opens a live viewfinder; the user frames a subject, taps ask, and the captured image plus any typed or dictated question is sent to the loaded VLM without leaving the chat view.
- Add **screenshot explain mode** from Photos or Share Sheet. A Share Sheet extension and a Photos picker flow that accepts a screenshot or image, pre-fills a "What is this?" prompt, and routes the request to the best available vision model, returning an explanation directly in a minimal overlay without opening a full chat.
- ✅ Add **boarding pass/travel document assistant** building on the existing pass scanner work.
- Add **receipt and invoice extraction** with structured JSON output. A dedicated scan flow (camera or photo library) that sends the image to a VLM with a structured extraction prompt and returns a JSON object of line items, totals, vendor, and date rendered as a formatted card the user can copy or save.
- Add **whiteboard/photo-to-notes** mode. A capture flow for handwritten notes, whiteboard photos, or sketched diagrams that runs OCR and optionally a VLM pass to produce a clean Markdown note, preserving structure like headings and bullet lists where detectable.
- Add **chart critique mode** for images and PDFs. An image attachment action that prompts the loaded VLM to analyse a chart or graph: describing the data shown, identifying potentially misleading design choices (truncated axis, misleading scale), and summarising the main takeaway.
- Add a **multi-image comparison workspace** with labeled attachments. A message composer extension that accepts two or more labelled image attachments and routes them with a comparison prompt to the VLM, rendering the model's structured comparison as a formatted card with similarities, differences, and a verdict.
- Add **image redaction before sending to model** for faces, names, QR codes, and barcodes. A pre-send image editor that runs on-device Vision framework passes to detect and blur faces, recognised text (names, addresses, IDs), QR codes, and barcodes, with category toggles and a before/after preview before the image is included in the prompt.
- Add **local OCR fallback** when a selected model cannot read images. When the selected model does not support vision (no projector, ET text-only, etc.), image attachments are automatically passed through the Vision framework's on-device text recogniser and the extracted text is injected into the prompt with an "[OCR from image]" label rather than silently dropping the attachment.
- ✅ Add **vision model projector repair** if a VLM is installed without its projector.
- ✅ Add **image token/cost estimate** even though local, framed as memory and speed impact.

## Audio And Speech Ideas

- ✅ Add **local dictation composer** using Whisper models already represented in settings/tests.
- Add **live transcript with local summary**. A recording screen that runs continuous Whisper transcription in real time, displaying a rolling transcript as the user speaks; when the recording stops, the transcript is automatically sent to the loaded model for a local summarisation pass, and both the raw transcript and the summary are stored as a dataset entry.
- Add **speaker labels** using on-device diarization if feasible. A diarisation pass (on-device if feasible, otherwise a lightweight embedded model) that annotates the transcript with speaker change markers so meeting notes show "Speaker A: …" / "Speaker B: …" rather than an undifferentiated wall of text.
- Add **voice commands** for stop, regenerate, cite sources, switch dataset, and save memory. A set of wake-phrase or button-hold commands that are processed locally without a model roundtrip, triggering the corresponding in-app action immediately — stopping generation, regenerating the last response, or switching the active dataset by voice.
- ✅ Add **audio file import** for lectures, podcasts, interviews, and meetings.
- Add **transcript-to-flashcards** for studying. A post-transcription action that sends the transcript to the loaded model with a flashcard-generation prompt, producing a deck of question/answer pairs from lecture or podcast content, stored in the same flashcard system as dataset-generated decks.
- Add a **pronunciation coach** for language learning. A mode where the user reads a phrase aloud, Whisper transcribes it, and the model compares the transcription to the target phrase, identifying mispronounced segments and providing phonetic feedback.
- Add **read aloud with citations skipped or included**. A TTS pass (AVSpeechSynthesizer or a local TTS model) triggered per message or per full conversation that reads the assistant's response aloud, with a toggle to skip inline citation markers so the spoken output flows naturally.
- ✅ Add **offline voice pack manager** parallel to model manager.

## Privacy, Safety, And Trust Ideas

- ✅ Add **Privacy Flight Recorder** showing what stayed local, what touched network, and why.
- ✅ Add **Off-Grid proof mode** that blocks all network and displays recent blocked attempts.
- ✅ Add **per-feature privacy labels** in Settings.
- ✅ Add **network kill-switch drill** to test Explore, web tools, remote backends, and downloads are blocked.
- ✅ Add **sensitive-data detector** before remote handoff.
- ✅ Add **local-only guarantee badges** per answer, indicating on-device (green), LAN relay (amber), or cloud (grey) on each message.
- Add **dataset encryption at rest** for imported personal docs. A per-dataset toggle that encrypts the source files, chunk store, and embedding index using a key derived from the user's device passcode or a separate passphrase; the dataset is unavailable until unlocked and cannot be read from a backup without the key.
- Add **biometric lock for selected chats/datasets**. A Face ID / Touch ID gate on individually selected chats or datasets that must be cleared before the content is displayed; locked items appear in the list as placeholder tiles with no text preview.
- Add **secure delete** for models, chats, datasets, embeddings, and temp files. A delete flow that overwrites file contents before unlinking so data is not recoverable from disk; surfaced as a "secure erase" option distinct from the standard delete.
- ✅ Add **model license and safety notes** surfaced at install and first load.
- Add **guardrail mode selection** for AFM and future local safety layers. A Settings toggle that activates Apple Foundation Models' built-in content guardrails for AFM sessions, and a separate toggle for a future local safety layer (keyword filter or small classifier) that can be applied to GGUF outputs before they are displayed.
- Add **answer uncertainty prompts** when sources are weak or absent. A per-session option that instructs the model to add a confidence qualifier ("I'm not certain about this", "No sources support this claim") when answering questions for which the active dataset has low retrieval scores or no relevant chunks.

## UI And Platform Ideas

- Add **iPad split-view research layout**: dataset/source on left, chat on right, citations below. A landscape-first layout on iPad where the dataset browser or source document occupies the leading third of the screen, the chat occupies the center, and a citations drawer slides in from the trailing edge, all within a single window scene.
- ✅ Add **Mac command center** for relay hosting, model library, and benchmarks.
- ✅ Add **visionOS model shelf** that shows local models, datasets, and live runtime status in space.
- Add **interactive onboarding sandbox** with a tiny bundled model or simulated generation. An onboarding step that runs a tiny bundled model (or a scripted mock if no model is installed yet) to let the user send one or two preset prompts and see the app generate a response, establishing the core interaction pattern before they download anything.
- Add **Settings search** across model, runtime, privacy, tools, and downloads settings. A search bar at the top of the Settings tab that filters across all sections and highlights matching rows with a brief path breadcrumb so users can find any option without browsing every section.
- ✅ Add **runtime status pill** visible in the chat composer.
- ✅ Add **model selector quick switcher** with recent models and load estimates.
- ✅ Add **download/indexing global activity center**.
- Add **compact mode** for small iPhones. A reduced-chrome layout for 375pt-wide screens that collapses the tab bar into a bottom drawer, shortens message bubbles, and hides secondary controls behind a single toolbar button to maximise reading area.
- Add **keyboard-first iPad shortcuts** for power users. A set of registered `UIKeyCommand` and SwiftUI `.keyboardShortcut` bindings for new chat (⌘N), switch model (⌘M), toggle dataset (⌘D), send message (⌘↩), regenerate (⌘R), and open settings (⌘,), surfaced in the system keyboard shortcuts overlay.
- Add **Share Sheet import flows** for PDFs, EPUBs, images, audio, and URLs. NSExtensionItem handlers for the share sheet that accept inputs from other apps and route them to the appropriate ingestion flow (dataset import, image attachment, audio transcription, or web retrieve) without requiring the user to navigate within Noema.
- Add **Spotlight indexing** for local chat titles and dataset names, not content unless opted in. A CoreSpotlight integration that indexes chat titles and dataset names so they appear in Spotlight results and can be opened directly to the relevant conversation or dataset from the home screen search.
- Add **Shortcuts actions** for ask model, summarize file, transcribe audio, search dataset. AppIntents implementing at least: "Ask model" (runs a prompt against the currently loaded model), "Summarise file" (imports a file and returns a summary), "Transcribe audio" (runs Whisper on an audio file), and "Search dataset" (returns top chunks for a query), all usable in Shortcuts automations.
- Add **Focus Filter integration** to enable Off-Grid mode automatically. A `FocusFilterIntent` that Noema registers so users can tie Off-Grid mode to a Focus (e.g. Sleep, Work); when that Focus activates, the network kill switch engages automatically and disengages when the Focus ends.
- ✅ Add **widget showing active model and indexing progress**.

## Developer And Quality Ideas

- ✅ Add **runtime fixture tests** for bridge request bodies across plain, chat, multimodal, reasoning, response format, and max token options.
- ✅ Add **golden prompt rendering tests** for every supported template source.
- ✅ Add **model settings migration tests** for every persisted setting.
- ✅ Add **loopback failure injection tests** for health timeout, loading progress stuck, non-200 responses, and server restart.
- ✅ Add **RAM advisor fixture suite** using real GGUF metadata samples.
- ✅ Add **ET artifact repair tests** with missing tokenizer, invalid tokenizer, missing `.pte`, and unsupported program.
- ✅ Add **snapshot tests** for model settings UI sections per format.
- Add **localization lint** that fails if UI strings are missing from any supported language. A build phase script (or Swift test target) that iterates every `.lproj` directory and checks that each key present in `en.lproj/Localizable.strings` also exists in every other supported language, failing the build if any translation is absent.
- ✅ Add **log redaction tests** to prevent prompts or private source snippets leaking into exported diagnostics.
- ✅ Add **benchmark result schema** and export/import tests.
- ✅ Add **fake local LLM backend** for deterministic UI tests.
- Add **CI smoke build matrix** for iOS, macOS, visionOS, and widget targets where feasible. A GitHub Actions (or Xcode Cloud) workflow that compiles the app for iOS simulator, macOS, visionOS simulator, and the widget extension on every pull request, without running the full test suite, to catch target-specific compilation breaks early.
- Add **generated documentation from code** for supported model formats and runtime settings. A DocC build target that generates browsable documentation from doc comments on public types in `ModelSettings`, the runtime client protocols, and the tool APIs, hosted as a static site so contributors can understand extension points without reading source.

## Big Creative Bets

- **Noema Lab:** a local experimentation workspace where users run prompts against multiple models, compare outputs, and save winning settings. A dedicated workspace tab (or Mac window) where users define a prompt, select two or more installed models, and run them in parallel; results appear in a side-by-side grid with per-model timing and a "save this config as a preset" button.
- **Private Personal Tutor:** dataset-backed study plans, flashcards, quizzes, progress tracking, and local explanations. A structured learning flow where the user selects a dataset (e.g. a textbook), sets a learning goal, and the app generates a curriculum with daily study modules, flashcard reviews, and progress checkpoints, all driven by the local model with no external service.
- **Local Research Analyst:** import papers, cluster them, map claims, find contradictions, and draft literature reviews with citations. An import-and-analyse workflow for collections of academic PDFs where the app clusters papers by topic using embedding similarity, surfaces contradicting claims across papers, and can draft a structured literature review citing specific passages, entirely on-device.
- **Travel Copilot:** parse boarding passes, hotel confirmations, maps, and local guides into an offline trip assistant. A pre-trip setup flow that ingests boarding passes, hotel confirmation PDFs, calendar events, and local guide datasets; the assembled context is available offline so the user can ask questions about gates, addresses, and logistics without connectivity.
- **Field Mode:** camera + voice + local model for places with no network. A simplified full-screen layout showing only camera, microphone, and a response area; intended for offline use where the user captures an image or speaks a question and gets a local model response without navigating the full app UI.
- **Model Sommelier:** ask what you want to do and Noema picks the smallest installed model that can do it well. A natural-language model picker where the user describes their task and the app recommends the smallest installed model that passes its own benchmarks for that task category, explaining why with a one-sentence rationale.
- **Knowledge Packs:** exportable bundles of datasets, prompts, settings, and recommended models for classes or teams. A packaging format and export/import flow for a bundle containing datasets, system prompt presets, recommended model configurations, and optional Shortcuts recipes; a teacher could export a "Biology 101 Pack" that students import to get a pre-configured study environment.
- **Local Agent Bench:** user-owned benchmark arena for models, tools, RAG, vision, and latency. A benchmark harness that runs agentic task suites (multi-step tool use, RAG-then-reason, multi-turn instruction following) against installed models and stores pass rates, step counts, and latencies in a persistent leaderboard visible in Explore.
- **Privacy Receipt Standard:** every answer can export a receipt proving which local/remote components were used. A signed export format for any assistant response that records which model generated it, whether it used local or remote compute, which dataset chunks were retrieved, and what tools were called, stored as a verifiable JSON receipt the user can share as provenance.
- **Noema Relay Mesh:** trusted personal devices cooperate, with mobile routing tasks to the Mac/iPad that has the right model loaded. A peer-to-peer coordination protocol where the user's trusted devices advertise their loaded models and available RAM over the LAN; the originating device routes generation requests to whichever peer has the best model for the task currently loaded, with automatic failover.

## Suggested Near-Term Implementation Order

1. ✅ **Model Doctor + load receipt export.** High leverage because the runtime is powerful but hard to inspect.
2. ✅ **RAG Inspector.** The app already tracks injection details, so the UI can make retrieval trustworthy quickly.
3. ✅ **Benchmark-driven model recommendations.** Existing benchmark service can become visible product value.
4. ✅ **MTP dashboard and validation.** The plumbing is present, and this differentiates local performance.
5. ✅ **Dataset health check and repair.** Users will trust local knowledge more if ingestion failures are obvious.
6. ✅ **Privacy Flight Recorder.** This reinforces Noema's core promise and clarifies local vs remote behavior.
7. ✅ **Model install/repair dependency graph.** This reduces support burden for tokenizers, projectors, and sidecars.
8. ✅ **Context budget meter in chat.** This makes RAG, images, tools, and history understandable before failures.
9. ✅ **Voice dictation/transcription workflow.** Whisper support already exists and can unlock a major mobile workflow.
10. ✅ **Mac/iOS relay readiness panel.** Remote backend support is mature enough to benefit from transparent state.
