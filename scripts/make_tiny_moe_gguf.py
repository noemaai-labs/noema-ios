#!/usr/bin/env python3
"""Generate a synthetic tiny MoE GGUF fixture for Noema Overfit parity testing.

Supports --arch qwen3moe (default), --arch qwen35moe, and --arch gemma4.
Weights are seeded-random; only routing/logit determinism matters, not text
quality. The fixture is small enough to commit and fast to load, and exercises
the full routed-expert tensor layout of its architecture (separate gate/up/down
expert tensors in every case).

qwen35moe (Qwen3.5 MoE) is a hybrid: with full_attention_interval = 2 the
fixture gets one linear-attention (gated delta net) layer 0 and one full
IMRoPE attention layer 1, both with routed experts PLUS the always-resident
shared expert (ffn_*_shexp + scalar gate ffn_gate_inp_shexp). Q projections
carry a fused output gate (out dim = head_dim * n_head * 2), matching
llama.cpp's llama_model_qwen35moe::load_arch_tensors.

Tokenizer choice: a degenerate "llama" (SPM) tokenizer without <0xXX> byte
tokens is unsafe -- llama.cpp's SPM byte fallback (llama_vocab::byte_to_token)
throws for any character not covered by a vocab piece, so arbitrary ASCII
prompts could abort. Instead we write a "gpt2" (BPE) tokenizer whose 256-entry
vocab is exactly the GPT-2 byte-to-unicode alphabet: with no effective merges,
llama.cpp deterministically tokenizes every input byte to the single token
whose id equals the byte value. (The gguf writer rejects empty arrays, and
llama.cpp requires tokenizer.ggml.merges to exist, so we write one no-op merge
over the byte-0x00 symbol, which never appears in text prompts.)

Outputs:
  <out>/tiny-<arch>-f16.gguf
  <out>/tiny-<arch>-q8_0.gguf   (if the installed gguf package can quantize Q8_0)
"""

import argparse
import sys
from pathlib import Path

import numpy as np

try:
    import gguf
except ImportError:
    sys.exit("error: the 'gguf' pip package is required (pip install gguf)")

# Model hyperparameters (fixed by the Stage 1 parity spec).
N_LAYER = 2
N_EMBD = 64
N_HEAD = 4
N_HEAD_KV = 2
HEAD_DIM = 16          # key_length / value_length
N_FF = 128             # dense fallback feed_forward_length
N_EXPERT = 8
N_EXPERT_USED = 2
EXPERT_FF = 96         # expert_feed_forward_length
CTX_LEN = 512
ROPE_THETA = 10000.0
RMS_EPS = 1e-6
N_VOCAB = 256

# qwen35moe extras (shared expert + gated delta net linear attention).
SHEXP_FF = 96              # expert_shared_feed_forward_length (ne0 % 32 == 0 keeps Q8_0 legal)
SSM_D_CONV = 4
SSM_D_STATE = 16           # GDN head dim (K and V)
SSM_N_GROUP = 2            # K heads
SSM_DT_RANK = 4            # V heads
SSM_D_INNER = SSM_D_STATE * SSM_DT_RANK  # 64
FULL_ATTN_INTERVAL = 2     # layer 0 = linear attention, layer 1 = full attention
ROPE_SECTIONS = [4, 2, 2, 0]  # IMRoPE sections, sum == n_rot/2 == HEAD_DIM/2

# gemma4 extras. The production 26B-A4B checkpoint uses the same `gemma4`
# GGUF architecture and routed tensor names; the tiny fixture keeps two layers
# so stock-vs-paged parity remains fast while still executing Gemma 4's shared
# dense MLP + routed GELU MoE graph.
GEMMA4_SWA = 128
GEMMA4_SWA_PATTERN = [True, False]

WEIGHT_STD = 0.02


def bytes_to_unicode() -> dict[int, str]:
    """GPT-2 byte -> unicode char mapping (must match llama.cpp's BPE alphabet)."""
    bs = (
        list(range(ord("!"), ord("~") + 1))
        + list(range(ord("¡"), ord("¬") + 1))
        + list(range(ord("®"), ord("ÿ") + 1))
    )
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, [chr(c) for c in cs]))


def qwen35_layer_is_recurrent(i: int) -> bool:
    # Mirrors llama_model_qwen35moe::load_arch_hparams' fallback:
    # is_recr[i] = (i + 1) % full_attention_interval != 0
    return (i + 1) % FULL_ATTN_INTERVAL != 0


def build_tensors(rng: np.random.Generator, arch: str) -> list[tuple[str, np.ndarray, str]]:
    """Return (name, float32 data in numpy row-major order, kind) triples.

    numpy shape is the REVERSE of the GGUF ne order: GGUFWriter reverses the
    numpy shape when writing tensor info, so e.g. ffn_gate_exps must be numpy
    (n_expert, expert_ff, n_embd) to come out as GGUF ne [n_embd, expert_ff,
    n_expert]. kind: "weight" (quantizable), "norm"/"router" (kept F32).
    """

    def w(shape) -> np.ndarray:
        return rng.normal(0.0, WEIGHT_STD, size=shape).astype(np.float32)

    def norm(n: int) -> np.ndarray:
        # Centered at 1.0 so activations stay in a sane range; near-zero RMS
        # gains would collapse the residual stream into denormal territory and
        # make cross-backend parity comparisons flaky.
        return (1.0 + rng.normal(0.0, WEIGHT_STD, size=(n,))).astype(np.float32)

    def moe(tensors: list, p: str) -> None:
        tensors.append((p + "ffn_gate_inp.weight", w((N_EXPERT, N_EMBD)), "router"))
        tensors.append((p + "ffn_gate_exps.weight", w((N_EXPERT, EXPERT_FF, N_EMBD)), "weight"))
        tensors.append((p + "ffn_down_exps.weight", w((N_EXPERT, N_EMBD, EXPERT_FF)), "weight"))
        tensors.append((p + "ffn_up_exps.weight", w((N_EXPERT, EXPERT_FF, N_EMBD)), "weight"))

    tensors: list[tuple[str, np.ndarray, str]] = []
    tensors.append(("token_embd.weight", w((N_VOCAB, N_EMBD)), "weight"))

    if arch == "qwen3moe":
        for i in range(N_LAYER):
            p = f"blk.{i}."
            tensors.append((p + "attn_norm.weight", norm(N_EMBD), "norm"))
            tensors.append((p + "attn_q.weight", w((N_HEAD * HEAD_DIM, N_EMBD)), "weight"))
            tensors.append((p + "attn_k.weight", w((N_HEAD_KV * HEAD_DIM, N_EMBD)), "weight"))
            tensors.append((p + "attn_v.weight", w((N_HEAD_KV * HEAD_DIM, N_EMBD)), "weight"))
            tensors.append((p + "attn_output.weight", w((N_EMBD, N_HEAD * HEAD_DIM)), "weight"))
            tensors.append((p + "attn_q_norm.weight", norm(HEAD_DIM), "norm"))
            tensors.append((p + "attn_k_norm.weight", norm(HEAD_DIM), "norm"))
            tensors.append((p + "ffn_norm.weight", norm(N_EMBD), "norm"))
            moe(tensors, p)
    elif arch == "qwen35moe":
        key_dim = SSM_D_STATE * SSM_N_GROUP       # 32
        value_dim = SSM_D_STATE * SSM_DT_RANK     # 64
        conv_dim = key_dim * 2 + value_dim        # 128
        for i in range(N_LAYER):
            p = f"blk.{i}."
            tensors.append((p + "attn_norm.weight", norm(N_EMBD), "norm"))
            tensors.append((p + "post_attention_norm.weight", norm(N_EMBD), "norm"))
            if qwen35_layer_is_recurrent(i):
                # Gated delta net (linear attention) layer.
                tensors.append((p + "attn_qkv.weight", w((conv_dim, N_EMBD)), "weight"))
                tensors.append((p + "attn_gate.weight", w((value_dim, N_EMBD)), "weight"))
                # Identity-dominant depthwise conv (last tap ~= 1) so the
                # convolved q/k/v keep real signal instead of collapsing to
                # silu(~0); a pure-noise kernel would make the layer inert.
                conv = w((conv_dim, SSM_D_CONV))
                conv[:, -1] += 1.0
                tensors.append((p + "ssm_conv1d.weight", conv, "norm"))
                tensors.append((p + "ssm_dt.bias", w((SSM_DT_RANK,)), "norm"))
                # -A_log.exp(): must be negative so the delta-net decay stays < 1.
                ssm_a = -(0.5 + rng.uniform(0.0, 1.0, size=(SSM_DT_RANK,))).astype(np.float32)
                tensors.append((p + "ssm_a", ssm_a, "norm"))
                tensors.append((p + "ssm_beta.weight", w((SSM_DT_RANK, N_EMBD)), "weight"))
                tensors.append((p + "ssm_alpha.weight", w((SSM_DT_RANK, N_EMBD)), "weight"))
                tensors.append((p + "ssm_norm.weight", norm(SSM_D_STATE), "norm"))
                tensors.append((p + "ssm_out.weight", w((N_EMBD, value_dim)), "weight"))
            else:
                # Full attention layer; Q projection fuses query + output gate.
                tensors.append((p + "attn_q.weight", w((N_HEAD * HEAD_DIM * 2, N_EMBD)), "weight"))
                tensors.append((p + "attn_k.weight", w((N_HEAD_KV * HEAD_DIM, N_EMBD)), "weight"))
                tensors.append((p + "attn_v.weight", w((N_HEAD_KV * HEAD_DIM, N_EMBD)), "weight"))
                tensors.append((p + "attn_output.weight", w((N_EMBD, N_HEAD * HEAD_DIM)), "weight"))
                tensors.append((p + "attn_q_norm.weight", norm(HEAD_DIM), "norm"))
                tensors.append((p + "attn_k_norm.weight", norm(HEAD_DIM), "norm"))
            moe(tensors, p)
            # Shared expert (always resident, never paged).
            tensors.append((p + "ffn_gate_inp_shexp.weight", w((N_EMBD,)), "router"))
            tensors.append((p + "ffn_gate_shexp.weight", w((SHEXP_FF, N_EMBD)), "weight"))
            tensors.append((p + "ffn_up_shexp.weight", w((SHEXP_FF, N_EMBD)), "weight"))
            tensors.append((p + "ffn_down_shexp.weight", w((N_EMBD, SHEXP_FF)), "weight"))
    elif arch == "gemma4":
        # Gemma 4 names RoPE frequencies globally; create_tensor(..., i)
        # reuses this one tensor for every full-attention layer.
        tensors.append(("rope_freqs.weight", norm(HEAD_DIM // 2), "norm"))
        for i in range(N_LAYER):
            p = f"blk.{i}."
            tensors.append((p + "attn_norm.weight", norm(N_EMBD), "norm"))
            tensors.append((p + "attn_q.weight", w((N_HEAD * HEAD_DIM, N_EMBD)), "weight"))
            tensors.append((p + "attn_k.weight", w((N_HEAD_KV * HEAD_DIM, N_EMBD)), "weight"))
            tensors.append((p + "attn_v.weight", w((N_HEAD_KV * HEAD_DIM, N_EMBD)), "weight"))
            tensors.append((p + "attn_output.weight", w((N_EMBD, N_HEAD * HEAD_DIM)), "weight"))
            tensors.append((p + "attn_q_norm.weight", norm(HEAD_DIM), "norm"))
            tensors.append((p + "attn_k_norm.weight", norm(HEAD_DIM), "norm"))
            tensors.append((p + "post_attention_norm.weight", norm(N_EMBD), "norm"))

            # Gemma 4's ordinary dense MLP is always resident and is summed
            # with the routed GELU expert branch on MoE layers.
            tensors.append((p + "ffn_norm.weight", norm(N_EMBD), "norm"))
            tensors.append((p + "ffn_gate.weight", w((N_FF, N_EMBD)), "weight"))
            tensors.append((p + "ffn_up.weight", w((N_FF, N_EMBD)), "weight"))
            tensors.append((p + "ffn_down.weight", w((N_EMBD, N_FF)), "weight"))
            tensors.append((p + "post_ffw_norm.weight", norm(N_EMBD), "norm"))

            moe(tensors, p)
            # Gemma 4 QAT checkpoints (including UD_Q4_K_XL) carry one
            # per-expert output scale for each routed matrix. Keep the values
            # deliberately distinct so stock-vs-paged parity catches any
            # accidental use of rewritten slot ids to gather these vectors.
            scale = np.linspace(0.65, 1.35, N_EXPERT, dtype=np.float32)
            tensors.append((p + "ffn_gate_exps.scale", scale, "norm"))
            tensors.append((p + "ffn_up_exps.scale", scale[::-1].copy(), "norm"))
            tensors.append((p + "ffn_down_exps.scale", (scale * 0.9).astype(np.float32), "norm"))
            tensors.append((p + "ffn_gate_inp.scale", norm(N_EMBD), "norm"))
            tensors.append((p + "pre_ffw_norm_2.weight", norm(N_EMBD), "norm"))
            tensors.append((p + "post_ffw_norm_1.weight", norm(N_EMBD), "norm"))
            tensors.append((p + "post_ffw_norm_2.weight", norm(N_EMBD), "norm"))
    else:
        raise AssertionError(f"unknown arch {arch!r}")

    tensors.append(("output_norm.weight", norm(N_EMBD), "norm"))
    tensors.append(("output.weight", w((N_VOCAB, N_EMBD)), "weight"))
    return tensors


def write_model(path: Path, tensors: list[tuple[str, np.ndarray, str]],
                quant: str, arch: str) -> None:
    writer = gguf.GGUFWriter(str(path), arch=arch)

    writer.add_name(f"tiny-{arch}-fixture")
    writer.add_quantization_version(gguf.GGML_QUANT_VERSION)
    if quant == "q8_0":
        writer.add_file_type(gguf.LlamaFileType.MOSTLY_Q8_0)
    else:
        writer.add_file_type(gguf.LlamaFileType.MOSTLY_F16)

    writer.add_context_length(CTX_LEN)
    writer.add_embedding_length(N_EMBD)
    writer.add_block_count(N_LAYER)
    writer.add_feed_forward_length(N_FF)
    writer.add_head_count(N_HEAD)
    writer.add_head_count_kv(N_HEAD_KV)
    writer.add_key_length(HEAD_DIM)
    writer.add_value_length(HEAD_DIM)
    writer.add_rope_freq_base(ROPE_THETA)
    writer.add_layer_norm_rms_eps(RMS_EPS)
    # These use the arch-prefixed keys llama.cpp requires, e.g.
    # <arch>.expert_count / <arch>.expert_used_count /
    # <arch>.expert_feed_forward_length.
    writer.add_expert_count(N_EXPERT)
    writer.add_expert_used_count(N_EXPERT_USED)
    writer.add_expert_feed_forward_length(EXPERT_FF)

    if arch == "qwen35moe":
        # Everything llama_model_qwen35moe::load_arch_hparams reads: shared
        # expert width, IMRoPE sections (required, 4 entries), the five GDN
        # ssm.* keys (all required) and the attention-interval fallback that
        # marks layer 0 recurrent / layer 1 full attention. nextn_predict_layers
        # is intentionally absent (no MTP block in the fixture).
        writer.add_expert_shared_feed_forward_length(SHEXP_FF)
        writer.add_rope_dimension_sections(ROPE_SECTIONS)
        writer.add_ssm_conv_kernel(SSM_D_CONV)
        writer.add_ssm_inner_size(SSM_D_INNER)
        writer.add_ssm_state_size(SSM_D_STATE)
        writer.add_ssm_time_step_rank(SSM_DT_RANK)
        writer.add_ssm_group_count(SSM_N_GROUP)
        writer.add_uint32(f"{arch}.full_attention_interval", FULL_ATTN_INTERVAL)
    elif arch == "gemma4":
        writer.add_sliding_window(GEMMA4_SWA)
        writer.add_sliding_window_pattern(GEMMA4_SWA_PATTERN)
        writer.add_shared_kv_layers(0)
        writer.add_embedding_length_per_layer_input(0)
        writer.add_uint32(f"{arch}.attention.key_length_swa", HEAD_DIM)
        writer.add_uint32(f"{arch}.attention.value_length_swa", HEAD_DIM)

    byte_map = bytes_to_unicode()
    vocab = [byte_map[b] for b in range(N_VOCAB)]
    types = [int(gguf.TokenType.NORMAL)] * N_VOCAB
    for special in (0, 1, 2):  # unk / bos / eos double as byte tokens
        types[special] = int(gguf.TokenType.CONTROL)
    writer.add_tokenizer_model("gpt2")
    writer.add_tokenizer_pre("default")
    writer.add_token_list(vocab)
    writer.add_token_scores([0.0] * N_VOCAB)
    writer.add_token_types(types)
    # gguf's writer rejects empty arrays and llama.cpp requires the merges key,
    # so write a single no-op merge over the byte-0x00 symbol.
    writer.add_token_merges([f"{byte_map[0]} {byte_map[0]}"])
    writer.add_unk_token_id(0)
    writer.add_bos_token_id(1)
    writer.add_eos_token_id(2)
    writer.add_add_bos_token(False)
    writer.add_add_eos_token(False)

    for name, data, kind in tensors:
        if kind in ("norm", "router"):
            writer.add_tensor(name, data.astype(np.float32))
        elif quant == "f16":
            writer.add_tensor(name, data.astype(np.float16))
        elif quant == "q8_0":
            q = gguf.quants.quantize(data, gguf.GGMLQuantizationType.Q8_0)
            writer.add_tensor(name, q, raw_dtype=gguf.GGMLQuantizationType.Q8_0)
        else:
            raise AssertionError(f"unknown quant {quant!r}")

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file(progress=False)
    writer.close()


def verify(path: Path, arch: str) -> int:
    """Re-read the file and assert KV keys and GGUF ne order. Returns tensor count."""
    reader = gguf.GGUFReader(str(path))

    def kv(key: str):
        field = reader.fields.get(key)
        if field is None:
            raise AssertionError(f"{path.name}: missing KV {key}")
        return field.contents()

    checks = {
        "general.architecture": arch,
        f"{arch}.block_count": N_LAYER,
        f"{arch}.embedding_length": N_EMBD,
        f"{arch}.feed_forward_length": N_FF,
        f"{arch}.expert_count": N_EXPERT,
        f"{arch}.expert_used_count": N_EXPERT_USED,
        f"{arch}.expert_feed_forward_length": EXPERT_FF,
        f"{arch}.attention.head_count": N_HEAD,
        f"{arch}.attention.head_count_kv": N_HEAD_KV,
        f"{arch}.attention.key_length": HEAD_DIM,
        f"{arch}.attention.value_length": HEAD_DIM,
        "tokenizer.ggml.model": "gpt2",
    }
    if arch == "qwen35moe":
        checks.update({
            f"{arch}.expert_shared_feed_forward_length": SHEXP_FF,
            f"{arch}.ssm.conv_kernel": SSM_D_CONV,
            f"{arch}.ssm.inner_size": SSM_D_INNER,
            f"{arch}.ssm.state_size": SSM_D_STATE,
            f"{arch}.ssm.time_step_rank": SSM_DT_RANK,
            f"{arch}.ssm.group_count": SSM_N_GROUP,
            f"{arch}.full_attention_interval": FULL_ATTN_INTERVAL,
        })
    elif arch == "gemma4":
        checks.update({
            f"{arch}.attention.sliding_window": GEMMA4_SWA,
            f"{arch}.attention.shared_kv_layers": 0,
            f"{arch}.embedding_length_per_layer_input": 0,
            f"{arch}.attention.key_length_swa": HEAD_DIM,
            f"{arch}.attention.value_length_swa": HEAD_DIM,
        })
    for key, expect in checks.items():
        got = kv(key)
        if got != expect:
            raise AssertionError(f"{path.name}: {key} = {got!r}, expected {expect!r}")
    if len(kv("tokenizer.ggml.tokens")) != N_VOCAB:
        raise AssertionError(f"{path.name}: vocab size != {N_VOCAB}")
    if arch == "qwen35moe":
        sections = [int(v) for v in kv(f"{arch}.rope.dimension_sections")]
        if sections != ROPE_SECTIONS:
            raise AssertionError(f"{path.name}: rope sections {sections} != {ROPE_SECTIONS}")
    elif arch == "gemma4":
        pattern = [bool(v) for v in kv(f"{arch}.attention.sliding_window_pattern")]
        if pattern != GEMMA4_SWA_PATTERN:
            raise AssertionError(
                f"{path.name}: sliding-window pattern {pattern} != {GEMMA4_SWA_PATTERN}"
            )

    # tensor.shape from GGUFReader is the on-disk GGUF ne order (ne0 first).
    expect_ne = {
        "token_embd.weight": [N_EMBD, N_VOCAB],
        "output.weight": [N_EMBD, N_VOCAB],
        "blk.0.ffn_gate_exps.weight": [N_EMBD, EXPERT_FF, N_EXPERT],
        "blk.0.ffn_down_exps.weight": [EXPERT_FF, N_EMBD, N_EXPERT],
        "blk.0.ffn_up_exps.weight": [N_EMBD, EXPERT_FF, N_EXPERT],
        "blk.0.ffn_gate_inp.weight": [N_EMBD, N_EXPERT],
    }
    if arch == "qwen3moe":
        expect_ne.update({
            "blk.0.attn_q.weight": [N_EMBD, N_HEAD * HEAD_DIM],
            "blk.0.attn_k.weight": [N_EMBD, N_HEAD_KV * HEAD_DIM],
            "blk.0.attn_output.weight": [N_HEAD * HEAD_DIM, N_EMBD],
            "blk.0.attn_q_norm.weight": [HEAD_DIM],
        })
        per_layer = 12
    elif arch == "qwen35moe":
        key_dim = SSM_D_STATE * SSM_N_GROUP
        value_dim = SSM_D_STATE * SSM_DT_RANK
        expect_ne.update({
            # layer 0: gated delta net
            "blk.0.attn_qkv.weight": [N_EMBD, key_dim * 2 + value_dim],
            "blk.0.attn_gate.weight": [N_EMBD, value_dim],
            "blk.0.ssm_conv1d.weight": [SSM_D_CONV, key_dim * 2 + value_dim],
            "blk.0.ssm_dt.bias": [SSM_DT_RANK],
            "blk.0.ssm_a": [SSM_DT_RANK],
            "blk.0.ssm_beta.weight": [N_EMBD, SSM_DT_RANK],
            "blk.0.ssm_alpha.weight": [N_EMBD, SSM_DT_RANK],
            "blk.0.ssm_norm.weight": [SSM_D_STATE],
            "blk.0.ssm_out.weight": [value_dim, N_EMBD],
            # layer 1: full attention with fused Q gate
            "blk.1.attn_q.weight": [N_EMBD, N_HEAD * HEAD_DIM * 2],
            "blk.1.attn_k.weight": [N_EMBD, N_HEAD_KV * HEAD_DIM],
            "blk.1.attn_output.weight": [N_HEAD * HEAD_DIM, N_EMBD],
            "blk.1.attn_q_norm.weight": [HEAD_DIM],
            # shared expert
            "blk.0.ffn_gate_inp_shexp.weight": [N_EMBD],
            "blk.0.ffn_gate_shexp.weight": [N_EMBD, SHEXP_FF],
            "blk.0.ffn_up_shexp.weight": [N_EMBD, SHEXP_FF],
            "blk.0.ffn_down_shexp.weight": [SHEXP_FF, N_EMBD],
        })
        per_layer = None  # counted explicitly below
    else:
        expect_ne.update({
            "blk.0.attn_q.weight": [N_EMBD, N_HEAD * HEAD_DIM],
            "blk.0.attn_k.weight": [N_EMBD, N_HEAD_KV * HEAD_DIM],
            "blk.0.attn_output.weight": [N_HEAD * HEAD_DIM, N_EMBD],
            "blk.0.post_attention_norm.weight": [N_EMBD],
            "blk.0.ffn_gate.weight": [N_EMBD, N_FF],
            "blk.0.ffn_down.weight": [N_FF, N_EMBD],
            "blk.0.ffn_gate_inp.scale": [N_EMBD],
            "blk.0.ffn_gate_exps.scale": [N_EXPERT],
            "blk.0.ffn_up_exps.scale": [N_EXPERT],
            "blk.0.ffn_down_exps.scale": [N_EXPERT],
            "blk.0.pre_ffw_norm_2.weight": [N_EMBD],
            "rope_freqs.weight": [HEAD_DIM // 2],
        })
        per_layer = None
    by_name = {t.name: t for t in reader.tensors}
    for name, ne in expect_ne.items():
        t = by_name.get(name)
        if t is None:
            raise AssertionError(f"{path.name}: missing tensor {name}")
        got = [int(d) for d in t.shape]
        if got != ne:
            raise AssertionError(f"{path.name}: {name} ne = {got}, expected {ne}")

    if arch == "qwen3moe":
        expected_count = 3 + per_layer * N_LAYER
    elif arch == "qwen35moe":
        # per layer: 2 norms + (9 GDN | 6 attention) + 4 routed + 4 shexp
        expected_count = 3 + sum(
            2 + (9 if qwen35_layer_is_recurrent(i) else 6) + 4 + 4
            for i in range(N_LAYER)
        )
    else:
        # One shared RoPE tensor plus, per layer: 8 attention tensors,
        # 5 resident dense-MLP tensors, 4 routed tensors, 3 resident expert
        # scale vectors, and 4 MoE norms.
        expected_count = 3 + 1 + N_LAYER * (8 + 5 + 4 + 3 + 4)
    if len(reader.tensors) != expected_count:
        raise AssertionError(
            f"{path.name}: {len(reader.tensors)} tensors, expected {expected_count}"
        )
    return len(reader.tensors)


def main() -> None:
    default_out = Path(__file__).resolve().parents[2] / ".models" / "fixtures"
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--out", type=Path, default=default_out, help="output directory")
    ap.add_argument(
        "--seed", type=int, default=None,
        help="numpy default_rng seed (default: 43 for gemma4, otherwise 42)",
    )
    ap.add_argument("--arch", choices=("qwen3moe", "qwen35moe", "gemma4"), default="qwen3moe")
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    seed = args.seed if args.seed is not None else (43 if args.arch == "gemma4" else 42)
    tensors = build_tensors(np.random.default_rng(seed), args.arch)

    outputs: list[Path] = []
    f16_path = args.out / f"tiny-{args.arch}-f16.gguf"
    write_model(f16_path, tensors, "f16", args.arch)
    outputs.append(f16_path)

    q8_path = args.out / f"tiny-{args.arch}-q8_0.gguf"
    try:
        write_model(q8_path, tensors, "q8_0", args.arch)
        outputs.append(q8_path)
    except Exception as exc:  # gguf package without Q8_0 quantization support
        q8_path.unlink(missing_ok=True)
        print(f"note: skipped Q8_0 variant (gguf package cannot quantize Q8_0: {exc})")

    for path in outputs:
        count = verify(path, args.arch)
        print(f"wrote {path}  ({path.stat().st_size:,} bytes, {count} tensors)")


if __name__ == "__main__":
    main()
