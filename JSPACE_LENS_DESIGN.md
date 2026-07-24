# J-Space Lens — design & implementation notes

Branch: `jspace-lens`. Status: v2 (MLX backend; logit-lens readout by default +
**true Jacobian lens** when a fitted `J_l` bundle is loaded; steer/swap interventions).
macOS-only UI. Builds green against **mlx-swift-lm 702e5a0 (3.0)** + mlx-swift 0.31.6.

## v2 additions (true Jacobian)

- `JSpaceJacobianLens.swift` — loads a converted lens bundle (`manifest.json` +
  `jacobians.safetensors`, keys `layer_<N>` → `[d,d]` fp16) and caches it.
- Readout transports the residual before unembedding when a lens is loaded:
  `unembed(h @ J_l.T)` (resid_post, row-vector orientation), with the Gemma logit
  softcap applied when the manifest sets it. `Diff` = Jacobian − Logit.
- **resid_post alignment**: J_l maps from a block's *output*, so layer `l` reads the
  residual captured at block `l+1`'s `input_layernorm` (`resid_post[l] == resid_pre[l+1]`).
  This also corrected the v1 logit-lens off-by-one.
- Steering with a lens uses the pulled-back readout direction `J_l.T · e(t)` per band
  layer (vs the flat embedding direction without a lens).
- `scripts/jspace_convert_lens.py` — off-device transcoder from Anthropic's published
  PyTorch `.pt` lenses (HF `neuronpedia/jacobian-lens`) to the on-device bundle.
- UI: `Jacobian`/`Diff` modes un-gate once a dimension-matched lens is loaded via
  "Load lens bundle…"; the panel shows base model + fitted-layer count.

Load a lens for the model you're running (e.g. Qwen3.6-27B or Gemma-3-12B, ideally
8-bit/bf16 to match the fp weights the lens was fit on) via the converter, then point
the panel at the output directory.

## mlx-swift-lm 3.0 migration (MLXBridge)

702e5a0 is mlx-swift-lm 3.0: `loadContainer(configuration:)` was removed and Hub/tokenizer
loading moved to the macro-based `MLXHuggingFace` module. Since Noema loads MLX models
from local directories, `MLXBridge` now calls `loadContainer(from: modelDirectory,
using: LocalDirectoryTokenizerLoader())` (`MLXTokenizerLoader.swift` — a hand-rolled
`AutoTokenizer.from(modelFolder:)` + swift-transformers→MLXLMCommon `Tokenizer` adapter,
mirroring `MLXHuggingFace`'s macro). `decode(tokens:)` → `decode(tokenIds:)`. The
NoemaMac target now links the `Tokenizers` product (pbxproj), and `mlx-swift-lm` is
pinned to revision `702e5a0` (branch:main was backtracking to an older commit).

## What this is

A viewer + intervention surface for the model's **global workspace** — the small set
of "silent" concepts a transformer holds in its residual stream while it generates.
Inspired by Neuronpedia's *Jacobian Lens* demo and the paper it implements:

> Gurnee, Sofroniew, Lindsey et al., *Verbalizable Representations Form a Global
> Workspace in Language Models*, Transformer Circuits, 2026.
> https://transformer-circuits.pub/2026/workspace/index.html · code:
> https://github.com/anthropics/jacobian-lens

Two halves, both reachable in Noema Mac:

- **View** — at each layer, decode the residual stream into vocabulary tokens (the
  "J-Lens Readout" list). This is what the model is *disposed to say* at that depth.
- **Intervene** — edit those latent directions mid-forward-pass: **STEER** (add a
  token's direction), **SWAP** (`love → hate`). This *causally* changes the output.

## The honest on-device reality (why v1 is a logit lens)

The true **Jacobian lens** decodes through `W_U · J_l`, where `J_l` is an averaged
input→output Jacobian **fit offline** on full-precision weights (autograd, ~1000
prompts, GPU). Anthropic published fitted lenses only for Qwen3.6-27B / Gemma-3-12B —
models far larger than Noema runs on-device, and the fit does not transfer cleanly to
quantized weights.

So v1 ships the paper's **baseline that needs no fitting** — the **logit lens**
(`J_l = I`): decode each layer's residual through the model's own final norm +
unembedding. It is real, causal-adjacent, cheap, and runs fully on-device. The
mode picker exposes `Jacobian` / `Diff` but they are gated until a fitted `J_l` is
loaded for the model (the upgrade path below). Interventions (steer/swap) are
independent of the lens choice and work today.

## Backend & mechanism (MLX, no fork, no C++)

Chosen backend: **MLX** (in-process, introspectable `MLXNN` modules, real autograd).
The whole mechanism is the `QuantizedLinear.quantize` pattern — swap a leaf module in
via `Module.update(modules:)`:

- **Read the residual** — `JSpaceCaptureRMSNorm` replaces each block's
  `@ModuleInfo(key:"input_layernorm")`. That norm's *input* is the inter-block
  residual, so we capture it and forward to the real norm untouched (weights copied
  in). Verified `open` on `RMSNorm` for Llama/Qwen families.
- **Write the residual (steer)** — `JSpaceSteerLinear` wraps each band block's
  `mlp.down_proj`. Its *output* is folded into the residual by the skip connection, so
  adding a vector there injects a steering direction. It delegates to the original
  `Linear` (which may be `QuantizedLinear`) so quantized matmuls stay correct.
- **Readout** — logit lens = top-k of `unembed(finalNorm(h))`, computed by calling the
  model's *actual* `norm` + `lm_head` (or tied `embed_tokens.asLinear`) modules — not
  raw params — so quantized unembeddings decode correctly.
- **Direction vectors** — token `t`'s direction is its (unit) input embedding
  `embed_tokens(t)`. Swap `s→t` uses `unit(e_t) − unit(e_s)`.

Everything runs inside `ModelContainer.perform` on the generation thread; only Sendable
value types cross back to the UI via `JSpaceLensRuntime`.

### What v1 deliberately does not do
- Prefill positions aren't read (only single-token decode steps) to avoid pinning
  every layer's full-prompt activation.
- The layer **band** for the readout is honored live; **interventions** and the steer
  band are captured at generation start (apply on the next message), like sampling
  settings.
- ABLATE / exact coordinate-swap (pseudoinverse) are not in v1 — swap is the additive
  difference-vector approximation.

## Files

| File | Role |
|---|---|
| `Noema/JSpaceLensModel.swift` | Sendable data types + `JSpaceLensRuntime` (thread-safe UI↔gen-thread bridge). Pure Swift. |
| `Noema/JSpaceLensController.swift` | `@MainActor` `ObservableObject` singleton; owns knobs, mirrors config into the runtime, folds readout frames into a decaying aggregate. |
| `Noema/JSpaceMLXHooks.swift` | The white-box engine: capture/steer module subclasses, structure resolution, install/remove. `#if canImport(MLXLLM)`. |
| `Noema/JSpaceLensSidebar.swift` | macOS inspector, `IndustrialControls` dialect. |

Integration edits (minimal, gated):
- `MLXBridge.swift` — probe capability at load; install/remove hooks around generation.
- `MainView+macOS.swift` — `MacChatChromeState.showJSpaceLens`.
- `ChatView.swift` — mount `JSpaceLensSidebar` in `macChatContainer`; `brain` toggle in `macChatToolbar`.

New files are picked up automatically (the `Noema` group is a
`PBXFileSystemSynchronizedRootGroup`).

## Using it

1. Load an MLX model (dense Llama/Qwen family) on Mac.
2. Toolbar → `brain` icon opens the **J-Space Lens** inspector.
3. Toggle **Read the residual stream**, pick a layer **band** (defaults to the mid ⅓–⅔
   "workspace" band), send a message → the **J-Lens Readout** fills live.
4. On any readout token: **＋** steers toward it, **⇄** swaps it for a typed token.
   Interventions apply on the next message.

## Jacobian upgrade path (future)

`JSpaceLensMode.jacobian` is wired but gated. To light it up:
1. Fit `J_l` offline (Python, `anthropics/jacobian-lens`) on the model's fp weights, or
   download a published lens.
2. Ship the per-layer `d×d` matrices as an asset; load into the session.
3. Readout becomes `unembed(norm(J_l · h))`; direction vectors become rows of
   `W_U · J_l`. Everything else (hooks, UI, steering) is unchanged.
