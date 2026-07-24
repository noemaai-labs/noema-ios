#!/usr/bin/env python3
"""Convert an Anthropic Jacobian-lens .pt into a Noema on-device lens bundle.

The published lenses (https://huggingface.co/neuronpedia/jacobian-lens) ship as
PyTorch pickles that can't be unpickled on-device. This script transcodes one into
a directory Noema's J-Space Lens can load:

    <out>/jacobians.safetensors   # one [d, d] fp16 matrix per key "layer_<N>"
    <out>/manifest.json           # {baseModel, dModel, nLayers, sourceLayers,
                                   #  tieWordEmbeddings, finalLogitSoftcapping}

The .pt is a dict {"J": {layer: Tensor[d,d]}, "n_prompts", "source_layers", "d_model"}.
J_l[i,j] = d h_final[i] / d h_l[j]; the app applies it as `h @ J_l.T` on resid_post[l].

Usage:
    pip install torch safetensors huggingface_hub pyyaml
    # by HF folder name (auto-downloads the .pt from neuronpedia/jacobian-lens):
    python jspace_convert_lens.py qwen3.6-27b   --out ~/jlens/qwen3.6-27b
    python jspace_convert_lens.py gemma-3-12b    --out ~/jlens/gemma-3-12b
    # or from a local .pt you already have:
    python jspace_convert_lens.py --pt ./Qwen3.6-27B_jacobian_lens_n1000.pt \
        --base-model Qwen/Qwen3.6-27B --out ~/jlens/qwen3.6-27b
    # trim to a mid-layer band to shrink the bundle (start,end inclusive):
    python jspace_convert_lens.py qwen3.6-27b --band 20,44 --out ~/jlens/qwen-band

Precision note: the lens was fit on the model's PRETRAINED (base/-pt) fp weights.
Run it over an 8-bit or bf16 MLX build of that same base for a faithful readout;
4-bit adds rank noise.
"""
import argparse
import json
import os
import sys

REPO = "neuronpedia/jacobian-lens"
LENS_SUBDIR = "jlens/Salesforce-wikitext"

# folder name -> base HF model id (used when config.yaml is absent, e.g. qwen3.6-27b)
FOLDER_TO_BASE = {
    "qwen3.6-27b": "Qwen/Qwen3.6-27B",
    "gemma-3-12b": "google/gemma-3-12b-pt",
    "gemma-3-12b-it": "google/gemma-3-12b-it",
    "gemma-3-27b": "google/gemma-3-27b-pt",
    "llama3.1-8b": "meta-llama/Llama-3.1-8B",
    "qwen3.5-4b": "Qwen/Qwen3.5-4B",
}


def die(msg: str):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def find_and_download_pt(folder: str) -> str:
    from huggingface_hub import HfApi, hf_hub_download
    api = HfApi()
    files = api.list_repo_files(REPO)
    prefix = f"{folder}/{LENS_SUBDIR}/"
    candidates = [f for f in files if f.startswith(prefix) and "_jacobian_lens" in f and f.endswith(".pt")]
    if not candidates:
        die(f"no *_jacobian_lens*.pt under {prefix} in {REPO} (folders: try one of the model dirs)")
    remote = sorted(candidates)[0]
    print(f"downloading {remote} …")
    return hf_hub_download(REPO, remote)


def try_read_yaml_manifest(folder: str):
    """config.yaml exists for some models (not all). Returns dict or None."""
    from huggingface_hub import hf_hub_download
    try:
        import yaml
    except ImportError:
        return None
    try:
        path = hf_hub_download(REPO, f"{folder}/{LENS_SUBDIR}/config.yaml")
        with open(path) as fh:
            return yaml.safe_load(fh)
    except Exception:
        return None


def read_base_config(base_model: str):
    """Best-effort fetch of the base model's config.json (tie / softcap / n_layers)."""
    from huggingface_hub import hf_hub_download
    try:
        path = hf_hub_download(base_model, "config.json")
        with open(path) as fh:
            cfg = json.load(fh)
        text = cfg.get("text_config", cfg)  # multimodal models nest text config
        return {
            "tie": bool(cfg.get("tie_word_embeddings", text.get("tie_word_embeddings", False))),
            "softcap": text.get("final_logit_softcapping", cfg.get("final_logit_softcapping")),
            "n_layers": text.get("num_hidden_layers", cfg.get("num_hidden_layers", 0)),
            "d_model": text.get("hidden_size", cfg.get("hidden_size", 0)),
        }
    except Exception as e:
        print(f"note: couldn't read {base_model} config.json ({e}); using CLI flags/defaults", file=sys.stderr)
        return None


def main():
    ap = argparse.ArgumentParser(description="Convert an Anthropic Jacobian-lens .pt to a Noema lens bundle.")
    ap.add_argument("folder", nargs="?", help="HF model folder in neuronpedia/jacobian-lens, e.g. qwen3.6-27b")
    ap.add_argument("--pt", help="path to a local *_jacobian_lens*.pt instead of downloading")
    ap.add_argument("--out", required=True, help="output bundle directory")
    ap.add_argument("--base-model", help="base HF model id (override / required with --pt when unknown)")
    ap.add_argument("--band", help="inclusive layer band lo,hi to keep (default: all fitted layers)")
    ap.add_argument("--tie", dest="tie", action="store_true", help="force tie_word_embeddings=true")
    ap.add_argument("--softcap", type=float, help="force final_logit_softcapping value")
    args = ap.parse_args()

    try:
        import torch
        from safetensors.torch import save_file
    except ImportError:
        die("pip install torch safetensors huggingface_hub pyyaml")

    pt_path = args.pt or (find_and_download_pt(args.folder) if args.folder else None)
    if not pt_path:
        die("provide a jacobian-lens folder name or --pt path")

    yaml_manifest = try_read_yaml_manifest(args.folder) if args.folder else None
    base_model = (args.base_model
                  or (yaml_manifest or {}).get("hf_model_name")
                  or FOLDER_TO_BASE.get(args.folder or "")
                  or "")

    print(f"loading {pt_path} …")
    ckpt = torch.load(pt_path, map_location="cpu", weights_only=True)
    if "J" not in ckpt:
        die(f"{pt_path} is not a lens file (no 'J' key). A fit checkpoint is not a lens.")
    J = ckpt["J"]
    d_model = int(ckpt.get("d_model", next(iter(J.values())).shape[-1]))
    source_layers = sorted(int(k) for k in J.keys())

    band = None
    if args.band:
        lo, hi = (int(x) for x in args.band.split(","))
        band = range(lo, hi + 1)
        source_layers = [l for l in source_layers if l in band]
        if not source_layers:
            die(f"band {args.band} selected no fitted layers (fitted: {min(J)}..{max(J)})")

    base_cfg = read_base_config(base_model) if base_model else None
    tie = args.tie or (base_cfg or {}).get("tie") or (yaml_manifest or {}).get("tie_word_embeddings") or False
    softcap = args.softcap if args.softcap is not None else (base_cfg or {}).get("softcap")
    n_layers = (base_cfg or {}).get("n_layers") or (max(source_layers) + 2)

    os.makedirs(args.out, exist_ok=True)
    tensors = {f"layer_{l}": J[l].to(torch.float16).contiguous() for l in source_layers}
    st_path = os.path.join(args.out, "jacobians.safetensors")
    save_file(tensors, st_path)

    manifest = {
        "baseModel": base_model or (args.folder or "unknown"),
        "dModel": d_model,
        "nLayers": int(n_layers),
        "sourceLayers": source_layers,
        "tieWordEmbeddings": bool(tie),
        "finalLogitSoftcapping": float(softcap) if softcap else None,
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)

    total_mb = sum(t.numel() * 2 for t in tensors.values()) / (1024 * 1024)
    print(f"wrote {len(tensors)} matrices ({total_mb:.0f} MB) to {st_path}")
    print(f"manifest: {json.dumps(manifest)}")
    print("Load this directory from Noema Mac → J-Space Lens → Load lens bundle…")


if __name__ == "__main__":
    main()
