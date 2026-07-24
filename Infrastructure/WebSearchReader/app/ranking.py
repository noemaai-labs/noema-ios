from __future__ import annotations

import math
import re

from rank_bm25 import BM25Okapi

from .extractor import ExtractedBlock, ExtractedDocument


TOKEN_PATTERN = re.compile(r"[\w'-]+", re.UNICODE)


def tokenize(value: str) -> list[str]:
    return [match.group(0).lower() for match in TOKEN_PATTERN.finditer(value)]


def rank_blocks(query: str, document: ExtractedDocument, limit: int = 3) -> list[tuple[ExtractedBlock, float]]:
    if not document.blocks:
        return []
    corpus = [tokenize(f"{block.heading or ''} {block.text}") for block in document.blocks]
    query_tokens = tokenize(query)
    if not query_tokens:
        return [(block, 0.0) for block in document.blocks[:limit]]
    bm25 = BM25Okapi(corpus)
    raw_scores = list(bm25.get_scores(query_tokens))
    phrase = " ".join(query_tokens)
    query_token_set = set(query_tokens)
    title_tokens = set(tokenize(document.title))
    for index, block in enumerate(document.blocks):
        block_tokens = tokenize(f"{block.heading or ''} {block.text}")
        normalized = " ".join(block_tokens)
        if phrase and phrase in normalized:
            raw_scores[index] += 3.0
        raw_scores[index] += 2.0 * len(query_token_set.intersection(block_tokens)) / max(1, len(query_token_set))
        raw_scores[index] += 0.25 * len(title_tokens.intersection(query_tokens))
        if block.heading:
            raw_scores[index] += 0.4 * len(set(tokenize(block.heading)).intersection(query_tokens))
    highest = max(raw_scores) if raw_scores else 0.0
    ordered = sorted(range(len(document.blocks)), key=lambda idx: raw_scores[idx], reverse=True)[:limit]
    return [
        (document.blocks[index], 0.0 if highest <= 0 else min(1.0, raw_scores[index] / highest))
        for index in ordered
    ]


def rank_documents(query: str, values: list[tuple[ExtractedDocument, float | None]]) -> list[ExtractedDocument]:
    scored: list[tuple[float, ExtractedDocument]] = []
    for document, search_score in values:
        block_scores = rank_blocks(query, document, limit=1)
        evidence = block_scores[0][1] if block_scores else 0.0
        source_score = 0.0 if search_score is None or not math.isfinite(search_score) else max(0.0, search_score)
        scored.append((evidence * 4.0 + min(source_score, 5.0), document))
    return [document for _, document in sorted(scored, key=lambda item: item[0], reverse=True)]
