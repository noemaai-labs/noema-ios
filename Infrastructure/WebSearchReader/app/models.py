from __future__ import annotations

from enum import Enum
from typing import Literal

from pydantic import BaseModel, Field, HttpUrl, model_validator


class Operation(str, Enum):
    research = "research"
    open = "open"
    find = "find"


class Candidate(BaseModel):
    title: str = Field(min_length=1, max_length=500)
    url: HttpUrl
    snippet: str = Field(default="", max_length=4_000)
    engine: str = Field(default="searxng", max_length=100)
    engines: list[str] = Field(default_factory=list, max_length=20)
    score: float | None = None
    published_at: str | None = Field(default=None, max_length=100)


class RetrieveRequest(BaseModel):
    operation: Operation = Operation.research
    query: str | None = Field(default=None, max_length=2_000)
    candidates: list[Candidate] = Field(default_factory=list, max_length=8)
    desired_sources: int = Field(default=3, ge=1, le=5)
    max_evidence_chars: int = Field(default=8_000, ge=2_000, le=20_000)
    source_ref: str | None = Field(default=None, max_length=8_192)
    cursor: str | None = Field(default=None, max_length=100)
    pattern: str | None = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def validate_operation_fields(self) -> "RetrieveRequest":
        if self.operation == Operation.research:
            if not (self.query or "").strip():
                raise ValueError("research requires a non-empty query")
            if not self.candidates:
                raise ValueError("research requires at least one candidate")
        elif self.operation == Operation.open:
            if not self.source_ref:
                raise ValueError("open requires source_ref")
        elif self.operation == Operation.find:
            if not self.source_ref:
                raise ValueError("find requires source_ref")
            if not (self.pattern or "").strip():
                raise ValueError("find requires a non-empty pattern")
        return self


class Passage(BaseModel):
    id: str
    text: str
    heading: str | None = None
    line_start: int | None = None
    line_end: int | None = None
    page: int | None = None
    relevance: float | None = None


class Source(BaseModel):
    citation_index: int
    source_ref: str | None = None
    title: str
    url: str
    canonical_url: str
    domain: str
    snippet: str = ""
    engine: str = "searxng"
    engines: list[str] = Field(default_factory=list)
    author: str | None = None
    published_at: str | None = None
    fetched_at: str | None = None
    content_type: Literal["html", "text", "pdf", "unknown"] = "unknown"
    fetch_status: Literal[
        "read", "snippet_only", "blocked", "unsupported", "too_large", "timeout", "no_text"
    ] = "snippet_only"
    content_hash: str | None = None
    passages: list[Passage] = Field(default_factory=list)
    next_cursor: str | None = None


class Capabilities(BaseModel):
    rich_retrieval: bool = True
    html: bool = True
    text_pdf: bool = True
    javascript: bool = False
    ocr: bool = False


class RetrieveResponse(BaseModel):
    version: int = 2
    operation: Operation
    sources: list[Source] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    capabilities: Capabilities = Field(default_factory=Capabilities)


class ErrorResponse(BaseModel):
    version: int = 2
    error: str
    code: str
