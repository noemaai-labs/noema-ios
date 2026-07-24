# J-Space Lens — adding a true Jacobian lens

The J-Space Lens (Mac chat → **brain** toolbar icon) works out of the box in **logit-lens**
mode with no setup. To upgrade a model to the **true Jacobian lens** (the `Jacobian` / `Diff`
modes), you load a *lens bundle* for that model. Anthropic publishes fitted lenses, but as
PyTorch `.pt` pickles — which can't be read on-device — so you convert one to a Noema bundle
first, then load it. This page covers both.

> TL;DR
> ```bash
> pip install torch safetensors huggingface_hub pyyaml
> python scripts/jspace_convert_lens.py gemma-3-12b --out ~/jlens/gemma-3-12b
> ```
> Then in Noema Mac: **brain icon → Jacobian Lens → Load lens bundle…** → pick `~/jlens/gemma-3-12b`.

---

## Background: logit lens vs Jacobian lens

- **Logit lens (default, on-device, no bundle):** each layer's residual is decoded through the
  model's own unembedding — `W_U · norm(h)`. It shows the tokens a layer is disposed to say and
  needs no fitting. This is what you get with the lens enabled and no bundle loaded.
- **Jacobian lens (needs a bundle):** decodes through `W_U · norm(Jₗ · h)`, where `Jₗ` is an
  averaged input→output Jacobian **fit offline** on the model's full-precision weights. It
  surfaces content a layer is disposed to say *now or later*. `Diff` shows Jacobian minus logit —
  the "silent"/future content the raw logit lens misses.

Noema only ever *applies* a pre-fit `Jₗ`; it never fits one. Fitting is the expensive offline
step Anthropic already did.

---

## Prerequisites

A machine with Python (this does **not** run on-device):

```bash
pip install torch safetensors huggingface_hub pyyaml
```

No GPU is needed — the converter only unpickles the lens and rewrites it. It does download the
lens `.pt` (1–3.5 GB) unless you pass a local file.

---

## Step 1 — Convert a published lens

The converter is `scripts/jspace_convert_lens.py` in this repo. It pulls a lens from
[`neuronpedia/jacobian-lens`](https://huggingface.co/neuronpedia/jacobian-lens) and writes a
Noema bundle.

**By HuggingFace folder name** (auto-downloads the `.pt`):

```bash
python scripts/jspace_convert_lens.py gemma-3-12b   --out ~/jlens/gemma-3-12b
python scripts/jspace_convert_lens.py qwen3.6-27b   --out ~/jlens/qwen3.6-27b
```

The folder name is a top-level directory in the `neuronpedia/jacobian-lens` repo. Published
families include (not exhaustive): `gemma-2-*`, `gemma-3-*`, `gemma-4-*`, `qwen3-*`,
`qwen3.5-*`, `qwen3.6-27b`, `llama3.1-8b`, `gpt2-small`, `pythia-70m-deduped`, `olmo-3-*`.

**From a local `.pt`** you already downloaded (specify the base model so the manifest is complete):

```bash
python scripts/jspace_convert_lens.py \
    --pt ./Qwen3.6-27B_jacobian_lens_n1000.pt \
    --base-model Qwen/Qwen3.6-27B \
    --out ~/jlens/qwen3.6-27b
```

**Trim to a mid-layer band** to shrink the bundle (inclusive `start,end`; the lens still works,
you just can't view/steer outside that band):

```bash
python scripts/jspace_convert_lens.py qwen3.6-27b --band 20,44 --out ~/jlens/qwen-band
```

**Overrides** (only needed when the base config can't be read, e.g. gated Gemma repos):
`--base-model <hf-id>`, `--tie` (force tied embeddings), `--softcap <float>` (final logit
softcapping). The converter prints the manifest it wrote.

---

## Step 2 — Load it in Noema

1. Load the target MLX model in Noema Mac.
2. Open the **J-Space Lens** panel (brain icon in the chat toolbar).
3. Under **Jacobian Lens**, click **Load lens bundle…** and select the output *directory*
   (e.g. `~/jlens/gemma-3-12b`).
4. If the lens's hidden size matches the loaded model, the **Jacobian** and **Diff** mode buttons
   un-gate and the panel shows the base model + fitted-layer count. Pick `Jacobian`, enable the
   lens, and send a message.

Keep the bundle somewhere Noema can read for the session (the matrices load lazily on the first
Jacobian-mode generation).

---

## What Noema accepts — bundle format

A bundle is a **directory** with exactly two files:

```
<bundle>/
├── manifest.json
└── jacobians.safetensors
```

### `manifest.json`

```jsonc
{
  "baseModel": "google/gemma-3-12b-pt",   // HF id the lens was fit on
  "dModel": 3840,                         // hidden size — MUST equal the loaded model's
  "nLayers": 48,                          // total transformer layers
  "sourceLayers": [0, 1, 2, /* … */ 46],  // 0-based block indices with a fitted Jₗ (resid_post)
  "tieWordEmbeddings": true,              // whether W_U == embed_tokens
  "finalLogitSoftcapping": null           // number for Gemma; null otherwise
}
```

Keys are camelCase and map 1:1 to Noema's `JSpaceLensManifest`. `finalLogitSoftcapping` may be
`null`.

### `jacobians.safetensors`

- One tensor per fitted layer, keyed **`layer_<N>`** (e.g. `layer_0`, `layer_1`, …) where `N` is
  the 0-based `resid_post` block index (matching `sourceLayers`).
- Each tensor is **`[dModel, dModel]`**, dtype **fp16**.
- Orientation: Noema applies it as `h @ Jₗ.T` on the residual — the converter writes `Jₗ` in the
  same orientation as the source `.pt` (`Jₗ[i,j] = ∂h_final[i]/∂h_source[j]`), so **don't
  transpose it yourself.**

The bundle does **not** include the model's norm or unembedding — Noema uses the loaded model's
own `norm` + `lm_head`/tied embedding at read time. The lens is purely the `Jₗ` matrices.

Sizes: `nLayers × dModel² × 2` bytes. Gemma-3-12B ≈ 1.4 GB; Qwen3.6-27B ≈ 3.3 GB. Trimming to a
band cuts this proportionally.

---

## Choosing a model + precision (fidelity matters)

The Jacobian was fit on the **pretrained base** model's **full-precision** weights, so the
readout is only as faithful as how close your on-device model's residual stream is to that:

- **Match the base.** The lens for `gemma-3-12b` was fit on `google/gemma-3-12b-**pt**`, not the
  `-it` instruct model. Prefer running the same base (or `-pt`) MLX build.
- **Prefer 8-bit or bf16.** 4-bit/5-bit quantization perturbs the residual stream and adds rank
  noise to the readout. Use an 8-bit or bf16 build of the base for a faithful lens.
- **Dimensions must match.** `manifest.dModel` must equal the loaded model's hidden size, or the
  panel reports a mismatch and keeps Jacobian mode off.
- **VLMs and hybrid architectures** (e.g. Qwen3.6-27B, which is a vision + MoE + linear-attention
  model) will *load* the lens if dimensions match, but the readout is degraded — the lens was fit
  on the plain text base, and steering is limited to dense-MLP layers. For these, the **logit
  lens is usually the more trustworthy tool.**

If you don't need the true Jacobian, the built-in logit lens needs none of this and runs on any
supported model.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `is not a JacobianLens file (no 'J' key)` | You pointed `--pt` at a *fitting checkpoint*, not a lens. Use the `*_jacobian_lens*.pt`. |
| Panel says dimension mismatch after loading | The lens `dModel` ≠ the loaded model's hidden size. Convert the lens for *this* model. |
| Jacobian/Diff stay greyed out | No dimension-matched lens is loaded, or the manifest is missing/invalid. |
| Model shows **UNSUPPORTED** in the panel | The architecture doesn't expose a standard residual stream + unembedding (or isn't an MLX model). Logit + Jacobian both require it. |
| Readout looks like noise | Likely a quant/precision mismatch — try an 8-bit/bf16 build of the exact base model. |

---

## See also

- `scripts/jspace_convert_lens.py` — the converter (its docstring has more examples).
- `JSPACE_LENS_DESIGN.md` (repo root) — architecture and the exact apply/steer math.
- Anthropic, *Verbalizable Representations Form a Global Workspace in Language Models*
  (transformer-circuits.pub/2026/workspace); lenses at HF `neuronpedia/jacobian-lens`.
