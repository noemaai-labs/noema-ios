from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .extractor import ExtractedDocument, FetchFailure, WebExtractor, canonicalize_url
from .models import Candidate, ErrorResponse, Operation, Passage, RetrieveRequest, RetrieveResponse, Source
from .ranking import rank_blocks, rank_documents, tokenize
from .security import SourceReferenceSigner, UnsafeURLError


def _passage(block, relevance: float | None = None) -> Passage:
    return Passage(
        id=block.id,
        text=block.text,
        heading=block.heading,
        line_start=block.line_start,
        line_end=block.line_end,
        page=block.page,
        relevance=relevance,
    )


def _source_from_document(
    candidate: Candidate,
    document: ExtractedDocument,
    citation_index: int,
    source_ref: str,
    query: str,
    passage_limit: int = 3,
) -> Source:
    ranked = rank_blocks(query, document, limit=passage_limit)
    return Source(
        citation_index=citation_index,
        source_ref=source_ref,
        title=document.title or candidate.title,
        url=document.url,
        canonical_url=document.canonical_url,
        domain=urlsplit(document.canonical_url).hostname or "",
        snippet=candidate.snippet,
        engine=candidate.engine,
        engines=candidate.engines,
        author=document.author,
        published_at=document.published_at or candidate.published_at,
        fetched_at=document.fetched_at,
        content_type=document.content_type,
        fetch_status="read",
        content_hash=document.content_hash,
        passages=[_passage(block, score) for block, score in ranked],
    )


def _fallback_source(candidate: Candidate, citation_index: int, source_ref: str | None, status: str) -> Source:
    canonical = canonicalize_url(str(candidate.url))
    return Source(
        citation_index=citation_index,
        source_ref=source_ref,
        title=candidate.title,
        url=str(candidate.url),
        canonical_url=canonical,
        domain=urlsplit(canonical).hostname or "",
        snippet=candidate.snippet,
        engine=candidate.engine,
        engines=candidate.engines,
        published_at=candidate.published_at,
        fetch_status=status,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.extractor = WebExtractor()
    app.state.signer = SourceReferenceSigner()
    app.state.research_semaphore = asyncio.Semaphore(2)
    yield
    await app.state.extractor.close()


app = FastAPI(title="Noema Web Reader", version="1.0.0", docs_url=None, redoc_url=None, lifespan=lifespan)


@app.middleware("http")
async def privacy_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


@app.exception_handler(UnsafeURLError)
async def unsafe_url_handler(_: Request, exc: UnsafeURLError):
    return JSONResponse(
        status_code=400,
        content=ErrorResponse(error=str(exc), code="unsafe_url").model_dump(),
    )


@app.exception_handler(RequestValidationError)
async def validation_error_handler(_: Request, __: RequestValidationError):
    return JSONResponse(
        status_code=422,
        content=ErrorResponse(error="request validation failed", code="invalid_request").model_dump(),
    )


@app.exception_handler(HTTPException)
async def http_error_handler(_: Request, exc: HTTPException):
    code = "request_failed"
    message = "request failed"
    if isinstance(exc.detail, dict):
        code = str(exc.detail.get("code") or code)
        message = str(exc.detail.get("error") or message)
    elif exc.detail:
        message = str(exc.detail)
    return JSONResponse(
        status_code=exc.status_code,
        content=ErrorResponse(error=message, code=code).model_dump(),
        headers=exc.headers,
    )


@app.exception_handler(Exception)
async def unexpected_error_handler(_: Request, __: Exception):
    return JSONResponse(
        status_code=500,
        content=ErrorResponse(error="reader request failed", code="internal_error").model_dump(),
    )


@app.get("/healthz")
async def healthz():
    return {"status": "ok", "version": 1}


@app.post("/v1/web/retrieve", response_model=RetrieveResponse)
async def retrieve(payload: RetrieveRequest, request: Request) -> RetrieveResponse:
    if payload.operation == Operation.research:
        try:
            async with request.app.state.research_semaphore:
                return await asyncio.wait_for(_research(payload, request), timeout=25)
        except asyncio.TimeoutError:
            raise HTTPException(status_code=504, detail={"code": "research_timeout", "error": "research timed out"})
    if payload.operation == Operation.open:
        return await _open(payload, request)
    return await _find(payload, request)


async def _research(payload: RetrieveRequest, request: Request) -> RetrieveResponse:
    extractor: WebExtractor = request.app.state.extractor
    signer: SourceReferenceSigner = request.app.state.signer
    candidates = payload.candidates[:6]

    async def load(candidate: Candidate):
        try:
            document = await extractor.fetch_and_extract(str(candidate.url), candidate.title)
            return candidate, document, None
        except FetchFailure as exc:
            return candidate, None, exc.status
        except UnsafeURLError:
            return candidate, None, "blocked"

    loaded = await asyncio.gather(*(load(candidate) for candidate in candidates))
    readable = [(document, candidate.score) for candidate, document, _ in loaded if document is not None]
    ranked_documents = rank_documents(payload.query or "", readable)
    document_order = {document.canonical_url: index for index, document in enumerate(ranked_documents)}
    loaded.sort(
        key=lambda item: (
            0 if item[1] is not None else 1,
            document_order.get(item[1].canonical_url, 10_000) if item[1] is not None else 10_000,
        )
    )

    sources: list[Source] = []
    warnings: list[str] = []
    evidence_chars = 0
    for candidate, document, failure_status in loaded:
        if len(sources) >= payload.desired_sources:
            break
        try:
            source_ref = signer.sign(str(candidate.url), citation_index=len(sources) + 1)
        except UnsafeURLError:
            source_ref = None
        citation_index = len(sources) + 1
        if document is None:
            status = failure_status or "snippet_only"
            sources.append(_fallback_source(candidate, citation_index, source_ref, status))
            warnings.append(f"Source {citation_index} could not be read ({status}); only search metadata is available.")
            continue
        source = _source_from_document(
            candidate,
            document,
            citation_index,
            source_ref or signer.sign(document.canonical_url, citation_index=citation_index),
            payload.query or "",
        )
        allowed_passages: list[Passage] = []
        for passage in source.passages:
            if evidence_chars + len(passage.text) > payload.max_evidence_chars:
                break
            allowed_passages.append(passage)
            evidence_chars += len(passage.text)
        source.passages = allowed_passages
        sources.append(source)

    return RetrieveResponse(operation=Operation.research, sources=sources, warnings=warnings)


async def _document_from_ref(payload: RetrieveRequest, request: Request) -> tuple[ExtractedDocument, str, int]:
    signer: SourceReferenceSigner = request.app.state.signer
    extractor: WebExtractor = request.app.state.extractor
    reference = signer.verify(payload.source_ref or "")
    try:
        document = await extractor.fetch_and_extract(reference.url)
    except FetchFailure as exc:
        raise HTTPException(status_code=422, detail={"code": exc.status, "error": str(exc)})
    return document, payload.source_ref or "", reference.citation_index


async def _open(payload: RetrieveRequest, request: Request) -> RetrieveResponse:
    document, source_ref, citation_index = await _document_from_ref(payload, request)
    try:
        start = max(0, int(payload.cursor or "0"))
    except ValueError:
        raise HTTPException(status_code=400, detail={"code": "invalid_cursor", "error": "cursor is invalid"})
    selected = []
    char_count = 0
    index = start
    while index < len(document.blocks) and char_count < min(payload.max_evidence_chars, 8_000):
        block = document.blocks[index]
        if selected and char_count + len(block.text) > min(payload.max_evidence_chars, 8_000):
            break
        selected.append(block)
        char_count += len(block.text)
        index += 1
    source = Source(
        citation_index=citation_index,
        source_ref=source_ref,
        title=document.title,
        url=document.url,
        canonical_url=document.canonical_url,
        domain=urlsplit(document.canonical_url).hostname or "",
        author=document.author,
        published_at=document.published_at,
        fetched_at=document.fetched_at,
        content_type=document.content_type,
        fetch_status="read",
        content_hash=document.content_hash,
        passages=[_passage(block) for block in selected],
        next_cursor=str(index) if index < len(document.blocks) else None,
    )
    return RetrieveResponse(operation=Operation.open, sources=[source])


async def _find(payload: RetrieveRequest, request: Request) -> RetrieveResponse:
    document, source_ref, citation_index = await _document_from_ref(payload, request)
    pattern = (payload.pattern or "").strip().lower()
    exact = [block for block in document.blocks if pattern in block.text.lower()]
    if exact:
        matches = [(block, 1.0) for block in exact[:10]]
    else:
        matches = rank_blocks(payload.pattern or "", document, limit=5)
        query_tokens = set(tokenize(payload.pattern or ""))
        matches = [(block, score) for block, score in matches if query_tokens.intersection(tokenize(block.text))]
    source = Source(
        citation_index=citation_index,
        source_ref=source_ref,
        title=document.title,
        url=document.url,
        canonical_url=document.canonical_url,
        domain=urlsplit(document.canonical_url).hostname or "",
        author=document.author,
        published_at=document.published_at,
        fetched_at=document.fetched_at,
        content_type=document.content_type,
        fetch_status="read",
        content_hash=document.content_hash,
        passages=[_passage(block, score) for block, score in matches],
    )
    warnings = [] if matches else ["No matching passage was found in the readable source."]
    return RetrieveResponse(operation=Operation.find, sources=[source], warnings=warnings)
