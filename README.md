# Noema

**Noema** brings large-language-model intelligence to your iPhone, iPad, Mac, and Apple Vision Pro while keeping all of your data and processing completely offline. By combining local AI models with curated textbooks and your own documents, it provides a powerful on-device knowledge assistant without sacrificing privacy.

## Key Features

### Offline models from Hugging Face
- **Integrated model search** – Browse the Hugging Face hub directly inside the app. The registry queries `https://huggingface.co/api/models` and returns records with metadata such as model ID, author, tags, and available quantization formats. A configurable endpoint (e.g. `hf-mirror.com`) is supported for regions where Hugging Face is unreachable.
- **One-tap downloads with progress** – The download manager emits `started`, `progress`, `verifying`, and `finished` events during each installation. Models are downloaded into the app's sandbox, verified, and cached so you can pause and resume downloads at any time.
- **Automatic dependency management** – For models that need extra files (configuration, tokenizers, multimodal projectors, etc.), the installer fetches and stores them alongside the weights.

### Open Textbook Library (OTL) integration
- Browse the Open Textbook Library from within Noema. A dedicated registry searches the catalog and caches the results locally.
- Import full textbooks. Downloaded PDFs or EPUBs are embedded on device and indexed for retrieval.

### Bring your own documents
- Add personal PDF, EPUB, TXT, MD, JSON, JSONL, CSV, and TSV files. The dataset detail view recognises supported formats and warns when a dataset contains only unsupported types.
- All documents are embedded into a local retrieval index for retrieval-augmented generation (RAG). Ask questions and Noema searches your documents and cites passages without sending anything to the cloud.

### Multi-backend model support
Noema runs several on-device model formats so you can pick the right balance of speed, memory, and quality. These are represented in the app's `ModelFormat` enum:

- **GGUF** – quantized weights run by the single bundled llama.cpp runtime, exposed through the local loopback server for chat and through its public C API for in-process helpers such as embeddings.
- **MLX** – Apple's Metal-accelerated format for running models natively on Apple Silicon (integrated via Swift Package Manager).
- **ExecuTorch (ET)** – PyTorch ExecuTorch models, with XNNPACK / CoreML / MPS backends.
- **CoreML / ANE (CML)** – CoreML model bundles that run on the Apple Neural Engine.
- **Apple Foundation Models (AFM)** – Apple's built-in on-device foundation model (Apple Intelligence), available on OS 26 and later with Apple Intelligence enabled.
- **CoreAI** – downloadable Apple on-device foundation-model bundles, available on OS 27 and later.

The RAM advisor heuristics estimate the working-set footprint for each format and compute whether a model fits the device's memory budget. Functions such as `fitsInRAM()` and `maxContextUnderBudget()` report whether a given model/context will run comfortably on your device.

### In-process and loopback inference
For GGUF, Noema ships one llama.cpp build through `NoemaLLamaServer`. This dynamic library provides both llama.cpp's public C API for in-process helpers and the embedded loopback HTTP server (`cpp-httplib`) used for the OpenAI-compatible local API. The app talks to the server over `127.0.0.1`, so chats, tokenization, and tool calls never leave the device.

### RAM check & model size helper
A built-in RAM adviser uses device-specific limits to estimate available memory. It multiplies the quantized weight size by a format-specific factor and adds an estimate for the key-value cache to determine whether a model of a given size and context length fits. It can also compute the maximum context length that fits under budget and surfaces this in the UI so you can pick an appropriate model and prompt length.

### Adaptive runtime presets
Runtime presets escalate KV-cache and context optimizations only as needed (Max Context, Battery Saver, Max Speed, and more), and you can save your own custom presets. An optional generation-diagnostics view reports total duration and token counts.

### Built-in tool calling and retrieval-augmented generation
Noema implements a flexible tool-calling system across the llama.cpp (server and in-process), MLX, and Apple Foundation Model backends. Tools can be invoked automatically during a chat to:
- **Web search** – a privacy-respecting hosted SearXNG metasearch endpoint (`search.noemaai.com`); no per-user API key required.
- **Document retrieval** – query your locally indexed datasets.
- **Custom functions** exposed through the app's tool registry.

When tool calling is enabled, the model issues structured tool calls and receives structured responses (JSON, plus the Qwen XML function-call dialect), making it easy to reach your documents and the web without exceeding context limits.

### Speculative decoding (MTP)
Noema supports draft/speculative decoding, including multi-token-prediction (MTP) draft heads for compatible GGUF models, with tunable draft parameters for faster generation.

### Voice input
WhisperKit-based on-device transcription lets you dictate prompts; audio is processed locally.

### Siri & App Intents
Noema integrates with App Intents and App Shortcuts so you can drive common actions (start a chat, search, explore models) from Siri and Spotlight.

### Live Activity for indexing
Embedding/indexing progress is surfaced on the Lock Screen and in the Dynamic Island via a Live Activity widget.

### Noema Teams (enterprise)
Optional enterprise workspaces let organizations manage members, distribute approved models and datasets, and enforce policy. Teams is billed and managed server-side; the consumer app stays fully functional offline.

### Localization
The interface and accessibility labels are translated into 11 languages: English, Arabic, German, Spanish, French, Hindi, Japanese, Korean, Romanian, Turkish, and Simplified Chinese.

### Privacy-first & offline
All inference happens on your device. The app never sends your chats, files, or downloaded models to any server. Web search is opt-in and routes only your query (not your data) to the search endpoint, and offline mode disables network access entirely. Combined with Apple sandboxing, this keeps your data private.

---

## Getting Started

### Requirements
- **iPhone / iPad** – iOS / iPadOS 18 or later, Apple Silicon (A12 Bionic or newer).
- **Mac** – macOS 26 (Tahoe) or later, Apple Silicon.
- **Apple Vision Pro** – visionOS 26 or later.
- Apple Foundation Models / CoreAI features require OS 26+ / 27+ respectively, with Apple Intelligence available on the device.
- Enough free storage for downloaded models and datasets (models range from a few hundred megabytes to multiple gigabytes; textbooks vary by file size).

### Installation
```bash
git clone https://github.com/armin976/Noema.git
cd Noema
git -c protocol.file.allow=always submodule update --init --recursive External/NoemaLLamaServer
```
Open the Xcode project (`Noema.xcodeproj`) and choose the **Noema** target for iPhone/iPad/Vision Pro, or the **NoemaMac** target for macOS.

Because GGUF and MLX inference run on-device with Metal, deploy to a physical device (or an Apple Silicon Mac) rather than the iOS simulator for full functionality.

Once the app launches, visit the **Explore** tab to search and install a model. Use the **Datasets** tab to import textbooks or add your own documents. The **Settings** tab exposes advanced options including context length, runtime presets, tool calling, and offline mode.

#### macOS debug builds
The project uses the `NoemaLLamaServer` SwiftPM package build for llama.cpp, so `NoemaMac` no longer relies on an embedded `llama.framework` that needs manual re-signing.

### Configuration
- **Web search** – built in; it uses the hosted SearXNG endpoint by default and requires no per-user key. The endpoint and engine are configurable in Settings.
- **Hugging Face endpoint** – optionally point downloads at a mirror (e.g. `hf-mirror.com`) via Settings or the `HF_ENDPOINT` environment variable. Your Hugging Face token is only ever sent to official Hugging Face hosts.

---

## Vision (Images) with llama.cpp

Noema supports vision-capable GGUF models via its embedded llama.cpp runner. If you want a quick sanity check from the command line, here are minimal examples that match how Noema wires things under the hood.

Minimal working command:

```
llama-cli \
  -m /path/to/vision-model.gguf \
  --mmproj /path/to/matching-projector.gguf \
  --image /path/to/photo.jpg \
  -p "Describe the scene."
```

With sensible performance knobs:

```
llama-cli \
  -m /path/to/vision-model.gguf \
  --mmproj /path/to/matching-projector.gguf \
  --image /path/to/photo.jpg \
  -p "Describe the scene." \
  -c 8192 \
  -t 8 \
  -ngl 99
```

Multiple images (repeat `--image` in the order you want the model to see them):

```
llama-cli \
  -m /path/to/vision-model.gguf \
  --mmproj /path/to/matching-projector.gguf \
  --image img1.jpg \
  --image img2.png \
  -p "Compare the two images."
```

Order of operations in Noema (mirrors the CLI):

1. Pick a vision-capable GGUF and its matching projector GGUF.
2. Load the model. If the GGUF doesn't embed a projector, Noema will auto-discover a sibling `*.gguf` projector or use the one you configured.
3. Attach one or more images; Noema preserves the order. Up to five per message.
4. Type your text prompt and send.
5. Tune performance in Settings: context (`-c` → `LLAMA_CONTEXT_SIZE`), threads (`-t` → `LLAMA_THREADS`), and GPU offload on Apple Silicon (`-ngl` → `LLAMA_N_GPU_LAYERS`).

Notes:
- You do not need to resize images yourself; llama.cpp preprocesses each image to what the model expects.
- Projectors: If your llama.cpp build supports external projectors, Noema passes `mmproj` to the runner. If not, use merged VLM weights.

---

## Contributing
Contributions are welcome! Feel free to open issues or pull requests to improve features, add new tools, or fix bugs. For substantial changes, please discuss your ideas in an issue first.

---

## License
This project is licensed under the [MIT License](LICENSE).

---

## Acknowledgements
Noema builds upon open-source communities including llama.cpp, MLX, ExecuTorch, WhisperKit, SearXNG, and the Open Textbook Library. Huge thanks to these projects for making offline AI on Apple devices possible.
