import os

import pytest

os.environ.setdefault("READER_REF_SIGNING_KEY", "test-signing-key-that-is-at-least-32-bytes")

from fastapi.testclient import TestClient

from app.extractor import ExtractedBlock, ExtractedDocument, FetchFailure
from app.main import app


def readable_document():
    return ExtractedDocument(
        url="https://example.com/article",
        canonical_url="https://example.com/article",
        title="Readable article",
        content_type="html",
        fetch_status="read",
        author="Ada Example",
        published_at="2026-01-01",
        fetched_at="2026-07-14T00:00:00Z",
        content_hash="abc123",
        blocks=[
            ExtractedBlock(id="one", text="Opening context for the article.", heading="Introduction", line_start=1, line_end=2),
            ExtractedBlock(id="two", text="The located evidence says the result is 42 percent.", heading="Results", line_start=3, line_end=4),
        ],
    )


def test_research_open_and_find(monkeypatch):
    with TestClient(app) as client:
        async def fake_extract(url, fallback_title=""):
            return readable_document()

        monkeypatch.setattr(app.state.extractor, "fetch_and_extract", fake_extract)
        research = client.post(
            "/v1/web/retrieve",
            json={
                "operation": "research",
                "query": "result 42 percent",
                "candidates": [{"title": "Candidate", "url": "https://example.com/article", "snippet": "A result"}],
            },
        )
        assert research.status_code == 200
        body = research.json()
        assert body["version"] == 2
        assert body["sources"][0]["fetch_status"] == "read"
        assert body["sources"][0]["passages"][0]["id"] == "two"
        source_ref = body["sources"][0]["source_ref"]

        opened = client.post("/v1/web/retrieve", json={"operation": "open", "source_ref": source_ref})
        assert opened.status_code == 200
        assert len(opened.json()["sources"][0]["passages"]) == 2

        found = client.post(
            "/v1/web/retrieve",
            json={"operation": "find", "source_ref": source_ref, "pattern": "42 percent"},
        )
        assert found.status_code == 200
        assert found.json()["sources"][0]["passages"][0]["id"] == "two"


def test_blocked_source_remains_visible_as_metadata(monkeypatch):
    with TestClient(app) as client:
        async def blocked(url, fallback_title=""):
            raise FetchFailure("blocked", "blocked")

        monkeypatch.setattr(app.state.extractor, "fetch_and_extract", blocked)
        response = client.post(
            "/v1/web/retrieve",
            json={
                "operation": "research",
                "query": "current event",
                "candidates": [{"title": "Blocked", "url": "https://example.com/blocked", "snippet": "Search metadata"}],
            },
        )
        assert response.status_code == 200
        source = response.json()["sources"][0]
        assert source["fetch_status"] == "blocked"
        assert source["snippet"] == "Search metadata"


@pytest.mark.parametrize("status", ["snippet_only", "blocked", "unsupported", "too_large", "timeout", "no_text"])
def test_research_preserves_each_non_read_fetch_status(monkeypatch, status):
    with TestClient(app) as client:
        async def failed(url, fallback_title=""):
            raise FetchFailure(status, status)

        monkeypatch.setattr(app.state.extractor, "fetch_and_extract", failed)
        response = client.post(
            "/v1/web/retrieve",
            json={
                "operation": "research",
                "query": "status fixture",
                "candidates": [{"title": "Fixture", "url": "https://example.com/status", "snippet": "metadata"}],
            },
        )
        assert response.status_code == 200
        assert response.json()["sources"][0]["fetch_status"] == status


def test_rejects_invalid_operation_fields():
    with TestClient(app) as client:
        response = client.post("/v1/web/retrieve", json={"operation": "find", "source_ref": "x"})
        assert response.status_code == 422
        assert response.json() == {
            "version": 2,
            "error": "request validation failed",
            "code": "invalid_request",
        }


def test_open_error_uses_versioned_envelope(monkeypatch):
    with TestClient(app) as client:
        async def timed_out(url, fallback_title=""):
            raise FetchFailure("timeout", "source fetch timed out")

        monkeypatch.setattr(app.state.extractor, "fetch_and_extract", timed_out)
        source_ref = app.state.signer.sign("https://example.com/article", citation_index=4)
        response = client.post("/v1/web/retrieve", json={"operation": "open", "source_ref": source_ref})
        assert response.status_code == 422
        assert response.json() == {
            "version": 2,
            "error": "source fetch timed out",
            "code": "timeout",
        }


def test_open_paginates_and_find_has_fuzzy_fallback(monkeypatch):
    document = readable_document()
    document.blocks = [
        ExtractedBlock(
            id=f"block-{index}",
            text=(f"Section {index} discusses retrieval evidence. " + "x" * 650),
            heading=f"Section {index}",
            line_start=index * 2 + 1,
            line_end=index * 2 + 2,
        )
        for index in range(8)
    ]
    with TestClient(app) as client:
        async def fake_extract(url, fallback_title=""):
            return document

        monkeypatch.setattr(app.state.extractor, "fetch_and_extract", fake_extract)
        source_ref = app.state.signer.sign("https://example.com/article", citation_index=3)
        first = client.post(
            "/v1/web/retrieve",
            json={"operation": "open", "source_ref": source_ref, "max_evidence_chars": 2_000},
        ).json()["sources"][0]
        assert first["citation_index"] == 3
        assert first["next_cursor"] is not None
        second = client.post(
            "/v1/web/retrieve",
            json={"operation": "open", "source_ref": source_ref, "cursor": first["next_cursor"]},
        ).json()["sources"][0]
        assert second["passages"][0]["id"] != first["passages"][0]["id"]

        fuzzy = client.post(
            "/v1/web/retrieve",
            json={"operation": "find", "source_ref": source_ref, "pattern": "retrieval supporting evidence"},
        ).json()["sources"][0]
        assert fuzzy["passages"]
