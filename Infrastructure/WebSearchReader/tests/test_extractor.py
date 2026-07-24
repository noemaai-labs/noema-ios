import io

import pytest
from reportlab.pdfgen import canvas

from app.extractor import FetchFailure, WebExtractor, canonicalize_url


def test_canonical_url_removes_fragment_and_tracking_only():
    value = canonicalize_url("https://Example.com/story?id=7&utm_source=test&fbclid=x#part")
    assert value == "https://example.com/story?id=7"


@pytest.mark.asyncio
async def test_html_main_text_and_metadata(monkeypatch):
    extractor = WebExtractor()
    html = b"""
    <html><head><title>Evidence title</title><meta name="author" content="Ada"></head>
    <body><nav>Navigation that should not be evidence</nav><article>
    <h1>Evidence title</h1><p>The measured result was forty two percent in the controlled study.</p>
    <p>A second paragraph provides enough article text for reliable extraction.</p>
    </article></body></html>
    """

    async def fake_fetch(_):
        return html, "https://example.com/story", "html"

    monkeypatch.setattr(extractor, "_fetch", fake_fetch)
    document = await extractor.fetch_and_extract("https://example.com/story", "Fallback")
    await extractor.close()
    joined = " ".join(block.text for block in document.blocks)
    assert document.fetch_status == "read"
    assert document.content_type == "html"
    assert "forty two percent" in joined
    assert "Navigation that should not be evidence" not in joined
    assert document.content_hash


@pytest.mark.asyncio
async def test_pdf_has_page_aware_blocks(monkeypatch):
    buffer = io.BytesIO()
    pdf = canvas.Canvas(buffer)
    pdf.drawString(72, 720, "First page evidence about solar output.")
    pdf.showPage()
    pdf.drawString(72, 720, "Second page evidence about battery storage.")
    pdf.save()
    data = buffer.getvalue()

    extractor = WebExtractor()

    async def fake_fetch(_):
        return data, "https://example.com/report.pdf", "pdf"

    monkeypatch.setattr(extractor, "_fetch", fake_fetch)
    document = await extractor.fetch_and_extract("https://example.com/report.pdf", "Report")
    await extractor.close()
    assert {block.page for block in document.blocks} == {1, 2}
    assert any("battery storage" in block.text for block in document.blocks)


def test_empty_text_layer_is_reported():
    extractor = object.__new__(WebExtractor)
    buffer = io.BytesIO()
    pdf = canvas.Canvas(buffer)
    pdf.showPage()
    pdf.save()
    with pytest.raises(FetchFailure) as error:
        extractor._extract_pdf(buffer.getvalue(), "https://example.com/scan.pdf", "Scan")
    assert error.value.status == "no_text"
