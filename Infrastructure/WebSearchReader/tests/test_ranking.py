from app.extractor import ExtractedBlock, ExtractedDocument
from app.ranking import rank_blocks


def test_bm25_and_phrase_boost_locate_evidence():
    document = ExtractedDocument(
        url="https://example.com",
        canonical_url="https://example.com/",
        title="Quarterly climate report",
        content_type="html",
        fetch_status="read",
        blocks=[
            ExtractedBlock(id="a", text="General introduction without the requested measurement."),
            ExtractedBlock(id="b", text="Global mean temperature increased by 1.2 degrees Celsius.", heading="Results"),
            ExtractedBlock(id="c", text="Appendix and acknowledgements."),
        ],
    )
    ranked = rank_blocks("global mean temperature 1.2 degrees", document)
    assert ranked[0][0].id == "b"
    assert ranked[0][1] > 0
