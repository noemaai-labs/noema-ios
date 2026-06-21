# Whisper backends — Xcode integration steps

The Swift, Obj-C, and Obj-C++ files for the embedding device-fit badge, the
transcription engine factory, the AudioLM remote backend, WhisperKit
backend, and whisper.cpp backend are now in the repository. A few
Xcode-project steps are still required before the two Whisper backends
actually compile and link.

## 1. Add the new files to the Noema target

All of these files live under `Noema/Noema/` and must be members of the
`Noema` target (tick the checkbox in the File Inspector):

- `TranscriptionBackendFactory.swift`
- `AudioLMRemoteBackend.swift`
- `MediaAudioExtractor.swift`
- `WhisperModelCatalog.swift`
- `WhisperModelsView.swift`
- `WhisperKitTranscriptionBackend.swift`
- `WhisperCppTranscriptionBackend.swift`
- `WhisperCpp.h`
- `WhisperCpp.mm`

`WhisperCpp.h` also needs to be added to the bridging header; this was
already wired in `Noema-Bridging.h` via `#if __has_include("WhisperCpp.h")`.

## 2. WhisperKit (Phase 2) — add as Swift Package

1. **Xcode → File → Add Package Dependencies…**
2. URL: `https://github.com/argmaxinc/WhisperKit`
3. Pin rule: _Up to Next Minor from_ the latest stable tag (as of 2025,
   `0.12.0`). Confirm against upstream README.
4. Attach the `WhisperKit` product to the **Noema** target.

Platform minimums WhisperKit requires (per README):

- iOS 16.0+
- macOS 13.0+
- watchOS 10.0+
- visionOS 1.0+
- Swift 5.9+

Confirm the Noema target meets these before linking. If visionOS support
breaks, wrap the backend in `#if !os(visionOS)` around the `#if canImport(WhisperKit)`
block in both `WhisperKitTranscriptionBackend.swift` and
`TranscriptionBackendFactory.swift` so the engine is unavailable there
rather than failing to build.

## 3. whisper.cpp (Phase 3) — two paths

### 3a. SPM path (preferred)

1. **Xcode → File → Add Package Dependencies…**
2. URL: `https://github.com/ggerganov/whisper.spm` (this is a thin SPM
   wrapper maintained alongside whisper.cpp).
3. Pin to the latest release.
4. Attach the `whisper` product to the **Noema** target.
5. Under **Build Settings → Swift Compiler - Custom Flags → Active Compilation
   Conditions**, add `NOEMA_WHISPER_CPP` for every configuration.
6. Under **Build Settings → Apple Clang - Preprocessing → Preprocessor Macros**,
   add `NOEMA_WHISPER_CPP=1` for every configuration. This is what makes
   `WhisperCpp.mm` compile the real implementation (instead of the stub).
7. For GPU acceleration on Apple Silicon, append `WHISPER_USE_COREML=1`
   in addition to the above. The shim enables `params.use_gpu = true`
   when this is defined.

If the SPM wrapper does not expose `whisper.h` to the Noema target
directly, add the package's include path under **Build Settings → Header
Search Paths** (usually `${BUILT_PRODUCTS_DIR}/whisper/include`).

### 3b. Vendored-sources path (fallback)

If the SPM wrapper is unsuitable, add whisper.cpp as a sibling of
`NoemaLLamaServer` in `External/`:

```
cd External
git submodule add https://github.com/ggerganov/whisper.cpp NoemaWhisperCpp
```

Then create a sibling Swift package `External/NoemaWhisperCpp/Package.swift`
modeled on `External/NoemaLLamaServer/Package.swift`, expose a
library target that builds `whisper.cpp`/`whisper.h` with Metal support,
and add it as a local package dependency to the Noema Xcode project.
The preprocessor macros from step 3a still apply.

## 4. Info.plist — no changes required

`NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
are already present. No additional permissions are needed for WhisperKit
or whisper.cpp beyond these.

## 5. Build + smoke test checklist

1. Without either SPM dep linked: **project must still build**. The factory
   falls back to Apple Speech; `WhisperKitTranscriptionBackend` /
   `WhisperCppTranscriptionBackend` are skipped entirely via `#if` guards.
2. Add WhisperKit → build succeeds → Settings → Transcription picks up
   "WhisperKit" as available (no "(unavailable)" suffix).
3. Download `Whisper Tiny` from Settings → Whisper Model. Record 20s of
   speech. Partial text should stream; final transcript should be
   non-empty.
4. Add whisper.cpp + custom flags → build succeeds → "whisper.cpp"
   becomes available. Download the ggml .bin for the same logical model,
   select it as active, confirm transcription works with a video input
   (audio extraction path).
5. Configure a local OpenAI-compatible audio endpoint (e.g. whisper.cpp
   `server` running locally on port 8080), paste its URL in Settings →
   Remote Audio Endpoint, tap "Send Test Request". Then pick the
   Audio-LM engine and transcribe a real clip.

## 6. Known limitations / follow-ups

- Whisper-model downloads (`WhisperModelsView`) route through
  `BackgroundDownloadManager.shared` directly and are **not** represented
  in `DownloadController.items`, so they do not appear in the download
  overlay or the main "Active downloads" popup. This keeps the diff
  small; if you want Whisper downloads to show in the overlay, add a
  `DownloadController.WhisperItem` type mirroring `EmbeddingItem` and
  drive `WhisperModelsView` through a `startWhisper(recordID:runtime:)`
  method on `DownloadController`.
- WhisperKit models are fetched by the SDK itself on first transcription
  call. The "Download" button in `WhisperModelsView` for WhisperKit
  artifacts only reports an info message; actual prefetch is deferred
  to first transcription. If you want true prefetch, call
  `WhisperKit(model:downloadBase:modelRepo:)` in the background from
  the view (the init triggers the download).
- The `WhisperCpp.mm` shim uses `params.use_gpu = true` only when
  `WHISPER_USE_COREML` is defined. Pure Metal acceleration is on by
  default in modern whisper.cpp builds regardless of that flag.

## 7. Troubleshooting

- **Picker shows "(unavailable)"**: that engine's conditional compile
  flag / import is missing. Check the bullet list in step 1–3 above.
- **`Cannot find 'NoemaWhisperCpp'`**: `WhisperCpp.h` is not in the
  bridging header. Open `Noema-Bridging.h` and confirm the
  `#import "WhisperCpp.h"` line compiles (run Build; the error output
  will point at the exact `#if` it was skipped under).
- **`whisper_full_default_params` undefined**: the whisper.cpp headers
  were not found. Check Header Search Paths.
- **WhisperKit API drift**: the SDK occasionally renames initializers and
  decoding-option fields. If the backend fails to compile after adding
  WhisperKit, update the `WhisperKit(...)` init call and
  `DecodingOptions()` field names in `WhisperKitTranscriptionBackend.swift`
  to match the tag you pinned.
