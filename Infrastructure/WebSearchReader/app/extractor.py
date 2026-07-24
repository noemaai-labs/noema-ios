from __future__ import annotations

import asyncio
import hashlib
import io
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit

import aiohttp
from cachetools import TTLCache
from pypdf import PdfReader
from trafilatura import extract
from trafilatura.metadata import extract_metadata

from .security import PublicOnlyResolver, UnsafeURLError, validate_public_url


HTML_LIMIT = 8 * 1024 * 1024
PDF_LIMIT = 20 * 1024 * 1024
TEXT_LIMIT = 4 * 1024 * 1024
MAX_PDF_PAGES = 100
TRACKING_KEYS = {"fbclid", "gclid", "mc_cid", "mc_eid"}


@dataclass
class ExtractedBlock:
    id: str
    text: str
    heading: str | None = None
    line_start: int | None = None
    line_end: int | None = None
    page: int | None = None


@dataclass
class ExtractedDocument:
    url: str
    canonical_url: str
    title: str
    content_type: str
    fetch_status: str
    blocks: list[ExtractedBlock] = field(default_factory=list)
    author: str | None = None
    published_at: str | None = None
    fetched_at: str | None = None
    content_hash: str | None = None


class FetchFailure(Exception):
    def __init__(self, status: str, message: str):
        super().__init__(message)
        self.status = status


def canonicalize_url(raw_url: str) -> str:
    parsed = urlsplit(validate_public_url(raw_url))
    filtered = []
    for key, value in parse_qsl(parsed.query, keep_blank_values=True):
        lowered = key.lower()
        if lowered.startswith("utm_") or lowered in TRACKING_KEYS:
            continue
        filtered.append((key, value))
    path = parsed.path or "/"
    return urlunsplit((parsed.scheme, parsed.netloc.lower(), path, urlencode(filtered, doseq=True), ""))


def _block_id(text: str, page: int | None, line_start: int | None) -> str:
    seed = f"{page or 0}:{line_start or 0}:{text}".encode("utf-8")
    return hashlib.sha256(seed).hexdigest()[:16]


def _paragraph_blocks(text: str, page: int | None = None) -> list[ExtractedBlock]:
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    blocks: list[ExtractedBlock] = []
    heading: str | None = None
    paragraph: list[str] = []
    start_line: int | None = None

    def flush(end_line: int) -> None:
        nonlocal paragraph, start_line
        content = " ".join(part.strip() for part in paragraph if part.strip())
        content = re.sub(r"\s+", " ", content).strip()
        if content:
            line_start = start_line or end_line
            blocks.append(
                ExtractedBlock(
                    id=_block_id(content, page, line_start),
                    text=content,
                    heading=heading,
                    line_start=line_start,
                    line_end=end_line,
                    page=page,
                )
            )
        paragraph = []
        start_line = None

    for index, line in enumerate(lines, start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            flush(max(1, index - 1))
            heading = stripped.lstrip("#").strip() or heading
            continue
        if not stripped:
            flush(max(1, index - 1))
            continue
        if start_line is None:
            start_line = index
        paragraph.append(stripped)
        if sum(len(part) for part in paragraph) >= 1_200:
            flush(index)
    flush(len(lines))
    return blocks


class WebExtractor:
    def __init__(self) -> None:
        self._resolver = PublicOnlyResolver()
        self._connector = aiohttp.TCPConnector(
            resolver=self._resolver,
            use_dns_cache=False,
            limit=6,
            limit_per_host=2,
            ttl_dns_cache=0,
        )
        timeout = aiohttp.ClientTimeout(total=15, connect=3, sock_connect=3, sock_read=10)
        self._session = aiohttp.ClientSession(
            connector=self._connector,
            timeout=timeout,
            trust_env=False,
            auto_decompress=True,
            headers={
                "User-Agent": "NoemaWebReader/1.0 (+https://noemaai.com)",
                "Accept": "text/html,application/xhtml+xml,application/pdf,text/plain;q=0.9,*/*;q=0.1",
            },
        )
        self._cache: TTLCache[str, ExtractedDocument] = TTLCache(maxsize=64, ttl=900)
        self._fetch_semaphore = asyncio.Semaphore(3)

    async def close(self) -> None:
        await self._session.close()

    async def fetch_and_extract(self, raw_url: str, fallback_title: str = "") -> ExtractedDocument:
        canonical = canonicalize_url(raw_url)
        cached = self._cache.get(canonical)
        if cached is not None:
            return cached
        async with self._fetch_semaphore:
            data, final_url, mime = await self._fetch(canonical)
        try:
            if mime == "pdf":
                document = await asyncio.to_thread(self._extract_pdf, data, final_url, fallback_title)
            elif mime == "html":
                document = await asyncio.to_thread(self._extract_html, data, final_url, fallback_title)
            elif mime == "text":
                document = await asyncio.to_thread(self._extract_text, data, final_url, fallback_title)
            else:
                raise FetchFailure("unsupported", "unsupported content type")
        except FetchFailure:
            raise
        except Exception as exc:
            raise FetchFailure("no_text", "content could not be extracted") from exc
        self._cache[document.canonical_url] = document
        if document.canonical_url != canonical:
            self._cache[canonical] = document
        return document

    async def _fetch(self, raw_url: str) -> tuple[bytes, str, str]:
        current = validate_public_url(raw_url)
        for _ in range(6):
            try:
                async with self._session.get(current, allow_redirects=False) as response:
                    if response.status in {301, 302, 303, 307, 308}:
                        location = response.headers.get("Location")
                        if not location:
                            raise FetchFailure("blocked", "redirect missing location")
                        current = validate_public_url(urljoin(current, location))
                        continue
                    if response.status in {401, 403, 407, 429, 451}:
                        raise FetchFailure("blocked", f"upstream returned HTTP {response.status}")
                    if response.status >= 400:
                        raise FetchFailure("blocked", f"upstream returned HTTP {response.status}")
                    content_type = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
                    if content_type in {"application/pdf", "application/x-pdf"}:
                        kind, limit = "pdf", PDF_LIMIT
                    elif content_type in {"text/html", "application/xhtml+xml", ""}:
                        kind, limit = "html", HTML_LIMIT
                    elif content_type.startswith("text/plain"):
                        kind, limit = "text", TEXT_LIMIT
                    else:
                        raise FetchFailure("unsupported", f"unsupported content type: {content_type or 'unknown'}")
                    content_length = response.content_length
                    if content_length is not None and content_length > limit:
                        raise FetchFailure("too_large", "source exceeds size limit")
                    chunks: list[bytes] = []
                    size = 0
                    async for chunk in response.content.iter_chunked(64 * 1024):
                        size += len(chunk)
                        if size > limit:
                            raise FetchFailure("too_large", "source exceeds size limit")
                        chunks.append(chunk)
                    data = b"".join(chunks)
                    if data.startswith(b"%PDF"):
                        kind = "pdf"
                    return data, str(response.url), kind
            except asyncio.TimeoutError as exc:
                raise FetchFailure("timeout", "source fetch timed out") from exc
            except UnsafeURLError:
                raise
            except aiohttp.ClientError as exc:
                raise FetchFailure("blocked", "source could not be fetched") from exc
        raise FetchFailure("blocked", "too many redirects")

    def _extract_html(self, data: bytes, url: str, fallback_title: str) -> ExtractedDocument:
        html = data.decode("utf-8", errors="replace")
        markdown = extract(
            html,
            url=url,
            output_format="markdown",
            include_comments=False,
            include_links=False,
            include_images=False,
            include_tables=True,
            favor_precision=True,
        )
        if not markdown or not markdown.strip():
            raise FetchFailure("no_text", "page did not contain readable article text")
        metadata = extract_metadata(html, default_url=url)
        title = (getattr(metadata, "title", None) or fallback_title or url).strip()
        author = getattr(metadata, "author", None)
        published_at = getattr(metadata, "date", None)
        blocks = _paragraph_blocks(markdown)
        if not blocks:
            raise FetchFailure("no_text", "page did not contain readable article text")
        return self._document(url, title, "html", blocks, author, published_at)

    def _extract_text(self, data: bytes, url: str, fallback_title: str) -> ExtractedDocument:
        text = data.decode("utf-8", errors="replace")
        blocks = _paragraph_blocks(text)
        if not blocks:
            raise FetchFailure("no_text", "document did not contain readable text")
        return self._document(url, fallback_title or url, "text", blocks)

    def _extract_pdf(self, data: bytes, url: str, fallback_title: str) -> ExtractedDocument:
        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted:
            try:
                if reader.decrypt("") == 0:
                    raise FetchFailure("unsupported", "encrypted PDF is unsupported")
            except Exception as exc:
                raise FetchFailure("unsupported", "encrypted PDF is unsupported") from exc
        if len(reader.pages) > MAX_PDF_PAGES:
            raise FetchFailure("too_large", "PDF exceeds page limit")
        blocks: list[ExtractedBlock] = []
        for page_index, page in enumerate(reader.pages, start=1):
            page_text = page.extract_text() or ""
            blocks.extend(_paragraph_blocks(page_text, page=page_index))
        if not blocks:
            raise FetchFailure("no_text", "PDF has no text layer")
        title = fallback_title
        try:
            title = (reader.metadata.title or fallback_title or url).strip()
        except Exception:
            title = fallback_title or url
        return self._document(url, title, "pdf", blocks)

    def _document(
        self,
        url: str,
        title: str,
        content_type: str,
        blocks: list[ExtractedBlock],
        author: str | None = None,
        published_at: str | None = None,
    ) -> ExtractedDocument:
        content_hash = hashlib.sha256("\n".join(block.text for block in blocks).encode("utf-8")).hexdigest()
        return ExtractedDocument(
            url=url,
            canonical_url=canonicalize_url(url),
            title=title,
            content_type=content_type,
            fetch_status="read",
            blocks=blocks,
            author=author,
            published_at=published_at,
            fetched_at=datetime.now(timezone.utc).isoformat(),
            content_hash=content_hash,
        )
