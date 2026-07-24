#!/usr/bin/env python3
"""Convert a supported MoE GGUF into a Model.noema-paged/ package.

The package splits the model into:
  resident.gguf     -- all KV metadata plus every non-routed-expert tensor
                       (including tiny per-expert QAT scale vectors),
                       copied byte-for-byte (no dequantization)
  experts-000.bin   -- per-expert slices of the routed expert tensors, each
                       aligned to --alignment (split into -001 etc. only past
                       a 16 GiB boundary)
  manifest.json     -- formatVersion 1 record of offsets, lengths, xxh64s,
                       file sha256s and the package fingerprint

The build is atomic: everything is written into <final>.building-<pid>, every
record is re-read and verified against both its xxh64 and the source tensor
bytes, and only then is the directory renamed into place.

Split GGUFs: passing the FIRST shard of an llama.cpp split model
(NAME-00001-of-0000N.gguf) reads every shard, unions their tensors, takes the
KV metadata from shard 1 (minus the split.* bookkeeping keys, so the resident
GGUF loads as a single file) and names the package after NAME.
"""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

try:
    import gguf
    import xxhash
except ImportError as exc:
    sys.exit(f"error: missing required pip package ({exc}); pip install gguf xxhash")

TOOL_NAME = "make_paged_package.py"
TOOL_VERSION = "1"
NATIVE_CONTRACT_VERSION = 4
FORMAT_VERSION = 1
EXPECTED_ARCHS = ("qwen3moe", "qwen35moe", "gemma4")
MAX_PAYLOAD_FILE_BYTES = 16 * 1024 * 1024 * 1024  # 16 GiB

EXPERT_RE = re.compile(r"^blk\.(\d+)\.ffn_(gate_up|gate|up|down)_exps\.weight$")
# Per-expert `.scale` vectors stay resident and are indexed with real expert
# ids by the patched graph while only the large weights use paged slot ids.
# Input scales and biases do not yet have that explicit execution contract.
FORBIDDEN_RE = re.compile(r"^blk\.\d+\.ffn_.*_exps\.(input_scale|bias)$")
FAMILY_ORDER = ("gate", "up", "down", "gate_up")

# llama.cpp gguf-split shard naming and per-shard bookkeeping KV keys. The
# split.* keys must not survive into resident.gguf: it is written as a single
# file and a stale split.count would make llama.cpp look for missing shards.
SPLIT_SHARD_RE = re.compile(r"^(?P<base>.+)-(?P<no>\d{5})-of-(?P<count>\d{5})\.gguf$")
SPLIT_KV_KEYS = ("split.no", "split.count", "split.tensors.count")


def fail(msg: str):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def sha256_files(paths: list[Path]) -> str:
    """One digest over the byte concatenation of paths in order.

    For a single path this equals sha256_file(path), keeping single-file
    manifests byte-identical.
    """
    h = hashlib.sha256()
    for path in paths:
        with path.open("rb") as f:
            while chunk := f.read(1 << 20):
                h.update(chunk)
    return h.hexdigest()


def resolve_input_shards(input_path: Path) -> tuple[list[Path], str]:
    """Return (ordered shard paths, package base name).

    A plain GGUF maps to itself; the first shard of an llama.cpp split
    (NAME-00001-of-0000N.gguf) expands to all N sibling shards.
    """
    m = SPLIT_SHARD_RE.match(input_path.name)
    if m is None:
        base = input_path.name
        if base.endswith(".gguf"):
            base = base[: -len(".gguf")]
        return [input_path], base
    if int(m.group("no")) != 1:
        fail(f"pass the first shard of the split (…-00001-of-{m.group('count')}.gguf), "
             f"not {input_path.name}")
    count = int(m.group("count"))
    if count < 1:
        fail(f"invalid shard count in {input_path.name}")
    shards = [
        input_path.with_name(f"{m.group('base')}-{i:05d}-of-{count:05d}.gguf")
        for i in range(1, count + 1)
    ]
    for shard in shards:
        if not shard.is_file():
            fail(f"missing split shard: {shard}")
    return shards, m.group("base")


def xxh64_hex(data: bytes) -> str:
    return format(xxhash.xxh64(data, seed=0).intdigest(), "016x")


def compute_fingerprint(file_sha256s: list[str]) -> str:
    """sha256 over the newline-joined file sha256 hex strings (resident first).

    Must match NoemaPagedPackageManifest.computeFingerprint on the Swift side.
    """
    return hashlib.sha256("\n".join(file_sha256s).encode("utf-8")).hexdigest()


def kv_int(reader: "gguf.GGUFReader", key: str) -> int:
    field = reader.fields.get(key)
    if field is None:
        fail(f"input GGUF is missing required KV {key!r}")
    value = field.contents()
    if not isinstance(value, int):
        fail(f"KV {key!r} is not an integer (got {value!r})")
    return value


def copy_metadata(reader: "gguf.GGUFReader", writer: "gguf.GGUFWriter") -> None:
    """Copy every KV field verbatim, preserving the original GGUF value types."""
    for field in reader.fields.values():
        # Virtual fields (GGUF.version/tensor_count/kv_count) and
        # general.architecture (written by GGUFWriter.__init__) must be skipped.
        if field.name.startswith("GGUF."):
            continue
        if field.name == gguf.Keys.General.ARCHITECTURE:
            continue
        if field.name in SPLIT_KV_KEYS:
            continue
        if not field.types:
            fail(f"KV {field.name!r} has no type information")
        if field.name == "general.alignment":
            # add_custom_alignment both writes the KV and updates the writer's
            # data alignment; copying it verbatim would desync the two.
            writer.add_custom_alignment(int(field.contents()))
            continue
        main_type = field.types[0]
        sub_type = None
        if main_type == gguf.GGUFValueType.ARRAY:
            if len(field.types) != 2:
                fail(f"KV {field.name!r} is a nested array; cannot copy verbatim")
            sub_type = field.types[-1]
        writer.add_key_value(field.name, field.contents(), main_type, sub_type=sub_type)


def write_resident(reader: "gguf.GGUFReader", arch: str, resident_path: Path,
                   non_expert_tensors: list) -> None:
    writer = gguf.GGUFWriter(str(resident_path), arch=arch)
    copy_metadata(reader, writer)
    for tensor in non_expert_tensors:
        # Raw byte-for-byte copy: the reader exposes quantized tensors as uint8
        # arrays in byte-shape, which add_tensor_info converts back to element
        # counts (quant_shape_from_byte_shape) under the original raw_dtype.
        writer.add_tensor(tensor.name, tensor.data, raw_dtype=tensor.tensor_type)
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file(progress=False)
    writer.close()


class PayloadWriter:
    """Writes aligned per-expert slices across 16 GiB-capped payload files."""

    def __init__(self, build_dir: Path, alignment: int):
        self.build_dir = build_dir
        self.alignment = alignment
        self.paths: list[Path] = []
        self.file = None
        self._open_next()

    def _open_next(self) -> None:
        if self.file is not None:
            self.file.close()
        path = self.build_dir / f"experts-{len(self.paths):03d}.bin"
        self.paths.append(path)
        self.file = path.open("wb")

    def append(self, data: bytes) -> tuple[int, int]:
        """Write one aligned record; returns (file_index, offset)."""
        pos = self.file.tell()
        padded = (pos + self.alignment - 1) // self.alignment * self.alignment
        if padded + len(data) > MAX_PAYLOAD_FILE_BYTES and pos > 0:
            self._open_next()
            padded = 0
        if padded > self.file.tell():
            self.file.write(b"\x00" * (padded - self.file.tell()))
        self.file.write(data)
        return len(self.paths) - 1, padded

    def close(self) -> None:
        if self.file is not None:
            self.file.close()
            self.file = None


def build_records(expert_tensors: dict, n_expert: int, payload: PayloadWriter) -> list[dict]:
    records = []
    for layer in sorted(expert_tensors):
        families = expert_tensors[layer]
        for family in FAMILY_ORDER:
            if family not in families:
                continue
            tensor = families[family]
            ne = [int(d) for d in tensor.shape]  # GGUF ne order, ne0 first
            if len(ne) != 3:
                fail(f"{tensor.name}: expected 3 dims, got ne={ne}")
            if ne[-1] != n_expert:
                fail(f"{tensor.name}: last ne dim {ne[-1]} != expert_count {n_expert}")
            raw = tensor.data.tobytes()
            if len(raw) != tensor.n_bytes:
                fail(f"{tensor.name}: raw byte count {len(raw)} != n_bytes {tensor.n_bytes}")
            if len(raw) % n_expert != 0:
                fail(f"{tensor.name}: {len(raw)} bytes not divisible by {n_expert} experts")
            per_expert = len(raw) // n_expert
            block_size, type_size = gguf.GGML_QUANT_SIZES[tensor.tensor_type]
            if ne[0] % block_size != 0:
                fail(f"{tensor.name}: ne0 {ne[0]} not divisible by block size {block_size}")
            row_size = ne[0] // block_size * type_size
            if per_expert != row_size * ne[1]:
                fail(
                    f"{tensor.name}: per-expert size {per_expert} != "
                    f"row_size({row_size}) * ne1({ne[1]})"
                )
            for expert in range(n_expert):
                chunk = raw[expert * per_expert:(expert + 1) * per_expert]
                file_index, offset = payload.append(chunk)
                records.append({
                    "layer": layer,
                    "family": family,
                    "expert": expert,
                    "file": file_index,
                    "offset": offset,
                    "length": per_expert,
                    "xxh64": xxh64_hex(chunk),
                    "ggmlType": int(tensor.tensor_type),
                    "ne": [ne[0], ne[1]],
                })
    return records


def verify_package(build_dir: Path, manifest: dict, expert_tensors: dict,
                   n_expert: int) -> None:
    payload_files = [
        (build_dir / entry["path"]).open("rb") for entry in manifest["expertFiles"]
    ]
    try:
        for record in manifest["records"]:
            f = payload_files[record["file"]]
            f.seek(record["offset"])
            chunk = f.read(record["length"])
            if len(chunk) != record["length"]:
                fail(f"verify: short read for record {record}")
            if record["offset"] % manifest["alignment"] != 0:
                fail(f"verify: record offset {record['offset']} not aligned")
            if xxh64_hex(chunk) != record["xxh64"]:
                fail(f"verify: xxh64 mismatch for record {record}")
            tensor = expert_tensors[record["layer"]][record["family"]]
            raw = tensor.data.tobytes()
            per_expert = len(raw) // n_expert
            expert = record["expert"]
            if chunk != raw[expert * per_expert:(expert + 1) * per_expert]:
                fail(f"verify: payload bytes differ from source for record {record}")
    finally:
        for f in payload_files:
            f.close()

    resident_path = build_dir / manifest["resident"]["path"]
    if resident_path.stat().st_size != manifest["resident"]["sizeBytes"]:
        fail("verify: resident.gguf size mismatch")
    resident_reader = gguf.GGUFReader(str(resident_path))
    for tensor in resident_reader.tensors:
        if EXPERT_RE.match(tensor.name):
            fail(f"verify: expert tensor {tensor.name} leaked into resident.gguf")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("input", type=Path, metavar="INPUT.gguf",
                    help="single GGUF, or the first shard of an llama.cpp split "
                         "(NAME-00001-of-0000N.gguf; siblings are read automatically)")
    ap.add_argument("--out", type=Path, required=True,
                    help="output directory (package created as OUTDIR/<basename>.noema-paged/)")
    ap.add_argument("--alignment", type=int, default=16384)
    ap.add_argument("--allow-any-arch", action="store_true",
                    help=f"dev only: accept architectures other than {'/'.join(EXPECTED_ARCHS)}")
    args = ap.parse_args()

    if not args.input.is_file():
        fail(f"input not found: {args.input}")
    if args.alignment <= 0:
        fail("--alignment must be positive")

    shard_paths, base = resolve_input_shards(args.input)
    readers = [gguf.GGUFReader(str(path)) for path in shard_paths]
    reader = readers[0]  # KV metadata comes from shard 1
    arch_field = reader.fields.get(gguf.Keys.General.ARCHITECTURE)
    if arch_field is None:
        fail("input GGUF has no general.architecture")
    arch = arch_field.contents()
    if arch not in EXPECTED_ARCHS and not args.allow_any_arch:
        fail(f"architecture {arch!r} is not one of {EXPECTED_ARCHS!r} (use --allow-any-arch for dev)")

    all_tensors = []
    seen_names: set[str] = set()
    for shard_index, shard_reader in enumerate(readers):
        for tensor in shard_reader.tensors:
            if tensor.name in seen_names:
                fail(f"tensor {tensor.name!r} appears in more than one shard")
            seen_names.add(tensor.name)
            all_tensors.append(tensor)
        if shard_index > 0:
            no_field = shard_reader.fields.get("split.no")
            if no_field is not None and int(no_field.contents()) != shard_index:
                fail(f"{shard_paths[shard_index].name}: split.no "
                     f"{int(no_field.contents())} != expected {shard_index}")

    for tensor in all_tensors:
        if FORBIDDEN_RE.match(tensor.name):
            fail(f"unsupported expert side-tensor present: {tensor.name}")

    n_expert = kv_int(reader, f"{arch}.expert_count")
    n_expert_used = kv_int(reader, f"{arch}.expert_used_count")
    block_count = kv_int(reader, f"{arch}.block_count")
    if n_expert <= 0 or n_expert_used <= 0:
        fail(f"expert_count ({n_expert}) and expert_used_count ({n_expert_used}) must be > 0")

    expert_tensors: dict[int, dict] = {}
    non_expert_tensors = []
    for tensor in all_tensors:
        m = EXPERT_RE.match(tensor.name)
        if m:
            layer, family = int(m.group(1)), m.group(2)
            expert_tensors.setdefault(layer, {})[family] = tensor
        else:
            non_expert_tensors.append(tensor)
    if not expert_tensors:
        fail("no routed expert tensors (blk.*.ffn_*_exps.weight) found")
    fused_gate_up = any("gate_up" in fams for fams in expert_tensors.values())

    final_dir = args.out / f"{base}.noema-paged"
    if final_dir.exists():
        fail(f"output already exists: {final_dir}")
    build_dir = args.out / f"{base}.noema-paged.building-{os.getpid()}"
    if build_dir.exists():
        fail(f"stale build directory exists: {build_dir}")
    build_dir.mkdir(parents=True)

    resident_path = build_dir / "resident.gguf"
    write_resident(reader, arch, resident_path, non_expert_tensors)

    payload = PayloadWriter(build_dir, args.alignment)
    records = build_records(expert_tensors, n_expert, payload)
    payload.close()

    manifest = {
        "formatVersion": FORMAT_VERSION,
        "createdBy": {
            "tool": TOOL_NAME,
            "toolVersion": TOOL_VERSION,
            "nativeContractVersion": NATIVE_CONTRACT_VERSION,
        },
        "source": {
            "fileName": args.input.name,
            "ggufSizeBytes": sum(path.stat().st_size for path in shard_paths),
            "ggufSha256": sha256_files(shard_paths),
        },
        "model": {
            "architecture": arch,
            "expertCount": n_expert,
            "expertsUsedDefault": n_expert_used,
            "moeLayerCount": len(expert_tensors),
            "totalLayerCount": block_count,
            "fusedGateUp": fused_gate_up,
        },
        "alignment": args.alignment,
        "resident": {
            "path": "resident.gguf",
            "sizeBytes": resident_path.stat().st_size,
            "sha256": sha256_file(resident_path),
        },
        "expertFiles": [
            {
                "path": path.name,
                "sizeBytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
            for path in payload.paths
        ],
        "records": records,
        "fingerprint": "",
    }
    if len(shard_paths) > 1:
        manifest["source"]["shardFileNames"] = [path.name for path in shard_paths]
    manifest["fingerprint"] = compute_fingerprint(
        [manifest["resident"]["sha256"]] + [f["sha256"] for f in manifest["expertFiles"]]
    )

    manifest_path = build_dir / "manifest.json"
    with manifest_path.open("w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    verify_package(build_dir, manifest, expert_tensors, n_expert)
    os.rename(build_dir, final_dir)

    total = sum(p.stat().st_size for p in final_dir.iterdir())
    print(f"wrote {final_dir}  ({total:,} bytes total)")
    print(f"  resident.gguf: {manifest['resident']['sizeBytes']:,} bytes")
    for entry in manifest["expertFiles"]:
        print(f"  {entry['path']}: {entry['sizeBytes']:,} bytes")
    print(
        f"  records: {len(records)}  "
        f"(moe layers: {len(expert_tensors)}, experts: {n_expert}, "
        f"fusedGateUp: {fused_gate_up})"
    )
    print(f"  fingerprint: {manifest['fingerprint']}")


if __name__ == "__main__":
    main()
