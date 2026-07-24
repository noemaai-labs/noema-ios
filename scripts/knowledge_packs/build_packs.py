#!/usr/bin/env python3
"""
Knowledge Packs build-farm + publisher.

Fetches the public-domain sources for Noema's Knowledge Packs, extracts and
cleans the text SERVER-SIDE, emits one clean `.txt` per source file, and
(optionally) uploads the result to the public Hugging Face dataset repo the
in-app catalog points at.

Output layout matches `KnowledgePackCatalog` exactly:
    <out>/<pack-id>/<file-name>.txt
e.g.  out/wilderness-survival/fm21-76-survival.txt

The app downloads these files and runs its existing on-device
Extract→Compress→Embed pipeline — we ship CLEAN TEXT, never vectors, so the
user's own embedding model is used. Keep the extraction tooling SERVER-SIDE.

Confirmed sources (all U.S.-gov public domain / CC0):
  • Survival / land-nav  → Internet Archive OCR text (_djvu.txt) of FM 21-76 & FM 3-25.26
  • First aid            → Internet Archive OCR text of FM 4-25.11 + CDC water-safety page
  • Preparedness         → Ready.gov hazard pages (public domain)
  • Travel               → factbook/factbook.json (per-country JSON, CC0)

Usage:
    pip install requests huggingface_hub wordninja   # wordninja optional: OCR word-repair
    python3 build_packs.py --out build/knowledge-packs
    python3 build_packs.py --out build/knowledge-packs --upload NoemaAI-labs/knowledge-packs
    python3 build_packs.py --out build/knowledge-packs --only travel-factbook
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import unicodedata
from dataclasses import dataclass, field
from typing import Callable, Optional

try:
    import requests
except ImportError:
    sys.exit("Missing dependency: pip install requests")

try:
    # Optional: reconstructs run-together OCR words ("firemaking" -> "fire making").
    # Without it the repair still de-spaces character-spaced scans, but won't split
    # words that the OCR merged onto one line.
    import wordninja as _WORDNINJA  # type: ignore
except ImportError:
    _WORDNINJA = None

UA = {"User-Agent": "NoemaKnowledgePacks/1.0 (+https://noemaai.com)"}


# --------------------------------------------------------------------------- #
# Text cleaning
# --------------------------------------------------------------------------- #

_LIGATURES = {"ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl"}

_ALNUM_RE = re.compile(r"[A-Za-z0-9]")


def _looks_char_spaced(text: str, sample_tokens: int = 6000) -> bool:
    """Detect OCR that emitted one character per token — e.g. the archive.org
    djvu scan of FM 21-76, where the page reads "D E P A R T M E N T" with every
    glyph on its own token and words split across newlines. Flags text where
    >40% of whitespace-delimited tokens are a single alphabetic character."""
    tokens = text.split()
    if not tokens:
        return False
    sample = tokens[:sample_tokens]
    singles = sum(1 for t in sample if len(t) == 1 and t.isalpha())
    return singles / len(sample) > 0.4


def _despace_line(line: str) -> str:
    """Collapse runs of single-character tokens on one line into a blob, leaving
    real multi-character tokens untouched: "D E P A R T M E N T" -> "DEPARTMENT",
    "a r e t h e d e c i d i n g" -> "arethedeciding"."""
    out: list[str] = []
    blob: list[str] = []
    for tok in line.split():
        if len(tok) == 1:
            blob.append(tok)
        else:
            if blob:
                out.append("".join(blob))
                blob = []
            out.append(tok)
    if blob:
        out.append("".join(blob))
    return " ".join(out)


def _segment_token(tok: str) -> list[str]:
    """Split a run-together alphabetic blob ("informationisfirst") back into
    words with wordninja when it is installed; otherwise return it unchanged."""
    if _WORDNINJA is None:
        return [tok]
    letters = sum(1 for c in tok if c.isalpha())
    if letters >= 6 and letters / len(tok) >= 0.8 and tok.replace("'", "").isalpha():
        return _WORDNINJA.split(tok) or [tok]
    return [tok]


def _is_glyph_noise(tok: str) -> bool:
    """True for OCR furniture that is mostly non-alphanumeric symbols (e.g.
    "ftf\\.*'~", "«#") so it never reaches the embedder as a "word"."""
    alnum = len(_ALNUM_RE.findall(tok))
    return alnum == 0 or alnum / len(tok) < 0.5


def repair_ocr_spacing(text: str) -> str:
    """Reconstruct readable prose from per-character-spaced OCR. Treats every
    newline as a token boundary and blank lines as paragraph boundaries (the
    layout archive.org djvu OCR uses), de-spaces single-character runs, splits
    run-together blobs with wordninja, and drops pure-symbol glyph noise.

    No-op for already-clean sources — only invoked when _looks_char_spaced()."""
    paragraphs: list[str] = []
    current: list[str] = []
    for raw_line in text.split("\n"):
        line = raw_line.strip()
        if not line:
            if current:
                paragraphs.append(" ".join(current))
                current = []
            continue
        for tok in _despace_line(line).split():
            if _is_glyph_noise(tok):
                continue
            current.extend(_segment_token(tok))
    if current:
        paragraphs.append(" ".join(current))
    return "\n\n".join(p for p in paragraphs if p.strip())


def clean_text(raw: str) -> str:
    """De-hyphenate line wraps, fix ligatures, normalize whitespace, collapse
    blank-line runs (keeping real paragraph breaks for the device chunker)."""
    text = unicodedata.normalize("NFC", raw)
    for lig, repl in _LIGATURES.items():
        text = text.replace(lig, repl)
    text = text.replace("­", "")  # soft hyphen

    # Repair per-character-spaced OCR scans BEFORE the rest of the pipeline runs.
    # On a clean source this is skipped entirely (detector returns False).
    if _looks_char_spaced(text):
        text = repair_ocr_spacing(text)

    lines = [ln.rstrip() for ln in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]

    reflowed: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if (i + 1 < len(lines) and re.search(r"[A-Za-z]-$", line)
                and re.match(r"^[a-z]", lines[i + 1].lstrip())):
            lines[i + 1] = line[:-1] + lines[i + 1].lstrip()
            i += 1
            continue
        reflowed.append(line)
        i += 1

    out: list[str] = []
    blanks = 0
    for ln in reflowed:
        collapsed = re.sub(r"[ \t]+", " ", ln).strip()
        if not collapsed:
            blanks += 1
            if blanks <= 2:
                out.append("")
        else:
            blanks = 0
            out.append(collapsed)
    return "\n".join(out).strip() + "\n"


def estimate_chunks(text: str, tokens_per_chunk: int = 1200) -> int:
    return max(1, round((len(text) / 4.0) / tokens_per_chunk))


def corpus_quality(text: str, sample_tokens: int = 20000) -> dict:
    """Cheap, dictionary-free signals for catching garbled OCR before it ships.
    A healthy English corpus has almost no single-character tokens, mostly
    word-like tokens, and a mean token length around 4-6 characters."""
    tokens = text.split()[:sample_tokens]
    n = max(len(tokens), 1)
    single = sum(1 for t in tokens if len(t) == 1 and t.isalpha())
    wordlike = sum(1 for t in tokens
                   if len(t) >= 2 and len(_ALNUM_RE.findall(t)) / len(t) >= 0.6)
    mean_len = sum(len(t) for t in tokens) / n
    return {
        "tokens": len(tokens),
        "single_char_ratio": round(single / n, 4),
        "alpha_word_ratio": round(wordlike / n, 4),
        "mean_token_len": round(mean_len, 2),
    }


def corpus_quality_failures(metrics: dict) -> list[str]:
    """Human-readable reasons a corpus is too garbled to ship (empty list = OK)."""
    reasons = []
    if metrics["single_char_ratio"] > 0.15:
        reasons.append(
            f"too many single-character tokens ({metrics['single_char_ratio']:.0%}) "
            "— looks like char-spaced/un-repaired OCR")
    if metrics["alpha_word_ratio"] < 0.55:
        reasons.append(f"too few word-like tokens ({metrics['alpha_word_ratio']:.0%})")
    if not (2.3 <= metrics["mean_token_len"] <= 14.0):
        reasons.append(f"implausible mean token length ({metrics['mean_token_len']})")
    return reasons


# --------------------------------------------------------------------------- #
# Extractors
# --------------------------------------------------------------------------- #

def _get(url: str, timeout: int = 120) -> bytes:
    resp = requests.get(url, headers=UA, timeout=timeout)
    resp.raise_for_status()
    return resp.content


def extract_plaintext(url: str) -> str:
    """Internet Archive OCR text (_djvu.txt) or any plain-text source."""
    return clean_text(_get(url).decode("utf-8", errors="replace"))


def _strip_html(raw: str) -> str:
    text = re.sub(r"(?is)<(script|style|nav|footer|header|form|svg).*?</\1>", " ", raw)
    text = re.sub(r"(?is)<br\s*/?>", "\n", text)
    text = re.sub(r"(?is)</(p|div|li|h[1-6]|tr)>", "\n", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = (text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
                .replace("&#39;", "'").replace("&nbsp;", " ").replace("&quot;", '"'))
    return text


def extract_html(url: str) -> str:
    return clean_text(_strip_html(_get(url).decode("utf-8", errors="replace")))


def extract_readygov(_seed: str) -> str:
    """Assemble the preparedness pack from several Ready.gov hazard pages
    (public-domain federal content)."""
    slugs = [
        "kit", "plan", "make-a-plan", "alerts", "evacuation", "shelter",
        "floods", "hurricanes", "tornadoes", "earthquakes", "wildfires",
        "extreme-heat", "winter-weather", "power-outages", "home-fires",
        "thunderstorms-lightning", "landslides-debris-flow",
    ]
    parts = []
    for slug in slugs:
        try:
            html = _get(f"https://www.ready.gov/{slug}", timeout=40).decode("utf-8", errors="replace")
            body = _strip_html(html)
            body = re.sub(r"(?s)Top\s*Skip to main content.*?(?=\n)", " ", body)
            parts.append(f"=== {slug.replace('-', ' ').title()} ===\n{body}")
        except Exception as exc:  # noqa: BLE001
            print(f"    (ready.gov/{slug} skipped: {exc})", file=sys.stderr)
    if not parts:
        raise ValueError("no ready.gov pages fetched")
    return clean_text("\n\n".join(parts))


_FACTBOOK_CATEGORIES = [
    "Introduction", "Geography", "People and Society", "Environment",
    "Government", "Economy", "Energy", "Communications", "Transportation",
    "Military and Security", "Space", "Terrorism", "Transnational Issues",
]


def _factbook_country_text(name: str, data: dict) -> str:
    lines = [f"\n=== {name} ==="]

    def walk(node, prefix):
        if isinstance(node, dict):
            txt = node.get("text")
            if isinstance(txt, str) and txt.strip():
                # Factbook "text" values embed HTML (<p>, <br>, <strong>…) — strip it.
                clean = re.sub(r"\s+", " ", _strip_html(txt)).strip()
                if clean:
                    label = prefix.strip(" :/")
                    lines.append(f"{label}: {clean}" if label else clean)
            for k, v in node.items():
                if k == "text":
                    continue
                walk(v, f"{prefix}{k} / ")
        elif isinstance(node, list):
            for it in node:
                walk(it, prefix)

    for cat in _FACTBOOK_CATEGORIES:
        if cat in data and isinstance(data[cat], dict):
            lines.append(f"\n## {cat}")
            walk(data[cat], "")
    return "\n".join(lines)


def extract_factbook(_seed: str) -> str:
    """Walk factbook/factbook.json on GitHub and flatten every country profile."""
    tree = json.loads(_get(
        "https://api.github.com/repos/factbook/factbook.json/git/trees/master?recursive=1",
        timeout=60).decode("utf-8"))
    if tree.get("truncated"):
        raise ValueError("GitHub tree response was truncated — cannot reliably enumerate all countries")
    paths = [t["path"] for t in tree.get("tree", [])
             if t["path"].endswith(".json") and "/" in t["path"]
             and not t["path"].startswith("meta/") and "package" not in t["path"]]
    paths.sort()
    out = []
    for idx, path in enumerate(paths):
        try:
            data = json.loads(_get(
                f"https://raw.githubusercontent.com/factbook/factbook.json/master/{path}",
                timeout=40).decode("utf-8"))
            gov = data.get("Government", {})
            cname = (gov.get("Country name", {}).get("conventional short form", {})
                        .get("text") or os.path.splitext(os.path.basename(path))[0].upper())
            out.append(_factbook_country_text(cname, data))
        except Exception as exc:  # noqa: BLE001
            print(f"    (factbook {path} skipped: {exc})", file=sys.stderr)
        if idx % 40 == 0:
            print(f"    ...factbook {idx}/{len(paths)}")
    # Guard against a partial fetch silently shipping a thin pack while the
    # catalog advertises ~260 places.
    if len(out) < 250:
        raise ValueError(f"only {len(out)} country profiles extracted; expected ~260 — aborting")
    return clean_text("\n".join(out))


# --------------------------------------------------------------------------- #
# Pack definitions — file names MUST match KnowledgePackCatalog.
# --------------------------------------------------------------------------- #

@dataclass
class Source:
    filename: str
    url: str
    extractor: Callable[[str], str]


@dataclass
class Pack:
    pack_id: str
    sources: list[Source] = field(default_factory=list)


IA = "https://archive.org/download"

PACKS: list[Pack] = [
    Pack("wilderness-survival", [
        Source("fm21-76-survival.txt",
               f"{IA}/FM21-76Survival1957/FM21-76Survival1957_djvu.txt", extract_plaintext),
        Source("fm3-25-26-land-nav.txt",
               f"{IA}/milmanual-fm-3-25.26-map-reading-and-land-navigation/fm_3-25.26_map_reading_and_land_navigation_djvu.txt",
               extract_plaintext),
    ]),
    Pack("first-aid", [
        Source("fm4-25-11-first-aid.txt",
               f"{IA}/FM4-25x11/FM4-25x11_djvu.txt", extract_plaintext),
    ]),
    Pack("emergency-prep", [
        Source("ready-gov-preparedness.txt", "ready.gov", extract_readygov),
    ]),
    Pack("travel-factbook", [
        Source("world-factbook.txt", "factbook", extract_factbook),
    ]),
]


# --------------------------------------------------------------------------- #
# Driver
# --------------------------------------------------------------------------- #

def build(out_dir: str, only: Optional[str]) -> tuple[int, dict]:
    failures = 0
    totals: dict[str, int] = {}
    for pack in PACKS:
        if only and pack.pack_id != only:
            continue
        pack_dir = os.path.join(out_dir, pack.pack_id)
        os.makedirs(pack_dir, exist_ok=True)
        for src in pack.sources:
            dest = os.path.join(pack_dir, src.filename)
            try:
                print(f"[{pack.pack_id}] {src.filename} <- {src.url}")
                text = src.extractor(src.url)
                if len(text.strip()) < 200:
                    raise ValueError(f"suspiciously short ({len(text)} chars)")
                metrics = corpus_quality(text)
                bad = corpus_quality_failures(metrics)
                if bad:
                    hint = "" if _WORDNINJA else " (install wordninja for OCR word-repair)"
                    raise ValueError("low-quality corpus — " + "; ".join(bad)
                                     + f" {metrics}{hint}")
                with open(dest, "w", encoding="utf-8") as fh:
                    fh.write(text)
                chunks = estimate_chunks(text)
                totals[pack.pack_id] = totals.get(pack.pack_id, 0) + chunks
                print(f"  -> {len(text):,} chars  (~{chunks} chunks)")
            except Exception as exc:  # noqa: BLE001
                failures += 1
                print(f"  !! FAILED {src.filename}: {exc}", file=sys.stderr)

    print("\n=== Per-pack estimated chunk totals (set KnowledgePackCatalog.chunkCount to match) ===")
    for pid, total in totals.items():
        print(f"  {pid}: ~{total}")
    if failures:
        print(f"\n{failures} source(s) failed.", file=sys.stderr)
    return failures, totals


def upload(out_dir: str, repo_id: str, only: Optional[str]) -> None:
    from huggingface_hub import HfApi
    api = HfApi()
    print(f"\nCreating/updating dataset repo {repo_id} …")
    api.create_repo(repo_id=repo_id, repo_type="dataset", exist_ok=True)
    # When building a single pack, publish ONLY that pack's folder so we never
    # re-publish stale, unvalidated sibling packs.
    folder = os.path.join(out_dir, only) if only else out_dir
    path_in_repo = only if only else "."
    print(f"Uploading {folder} → {path_in_repo} …")
    api.upload_folder(
        repo_id=repo_id, repo_type="dataset", folder_path=folder, path_in_repo=path_in_repo,
        commit_message=f"Publish Knowledge Pack text artifacts ({only or 'all'})")
    print(f"Done → https://huggingface.co/datasets/{repo_id}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Build & publish Noema Knowledge Pack text artifacts.")
    ap.add_argument("--out", default="build/knowledge-packs")
    ap.add_argument("--only")
    ap.add_argument("--upload", metavar="REPO_ID", help="e.g. NoemaAI-labs/knowledge-packs")
    args = ap.parse_args()
    failures, _ = build(args.out, args.only)
    if args.upload:
        if failures:
            print("Refusing to upload with failed sources. Fix them or run --only per pack.", file=sys.stderr)
            sys.exit(1)
        upload(args.out, args.upload, args.only)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
