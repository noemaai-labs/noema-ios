import socket

import pytest

from app.security import PublicOnlyResolver, SourceReferenceSigner, UnsafeURLError, validate_public_url


@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1/",
        "http://2130706433/",
        "http://0x7f000001/",
        "http://%31%32%37.0.0.1/",
        "http://[::1]/",
        "http://[::ffff:127.0.0.1]/",
        "http://169.254.169.254/opc/v2/instance/",
        "http://10.0.0.1/",
        "http://172.17.0.1/",
        "http://192.0.2.1/",
        "http://224.0.0.1/",
        "http://metadata.google.internal/",
        "http://user:password@example.com/",
        "https://example.com:8443/",
        "file:///etc/passwd",
    ],
)
def test_rejects_unsafe_urls(url):
    with pytest.raises(UnsafeURLError):
        validate_public_url(url)


def test_accepts_and_normalizes_public_url():
    assert validate_public_url("HTTPS://Example.COM/path?q=1#fragment") == "https://example.com/path?q=1"


def test_source_reference_is_signed_and_expires():
    signer = SourceReferenceSigner("x" * 32)
    token = signer.sign("https://example.com/article", citation_index=7)
    reference = signer.verify(token)
    assert reference.url == "https://example.com/article"
    assert reference.citation_index == 7
    with pytest.raises(UnsafeURLError):
        signer.verify(token + "tampered")
    expired = signer.sign("https://example.com/article", ttl_seconds=-1)
    with pytest.raises(UnsafeURLError):
        signer.verify(expired)


@pytest.mark.asyncio
async def test_resolver_rejects_private_dns_answer(monkeypatch):
    class Loop:
        async def getaddrinfo(self, *args, **kwargs):
            return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("10.1.2.3", 443))]

    monkeypatch.setattr("app.security.asyncio.get_running_loop", lambda: Loop())
    with pytest.raises(UnsafeURLError):
        await PublicOnlyResolver().resolve("rebound.example", 443)


@pytest.mark.asyncio
async def test_resolver_rejects_mixed_public_private_dns_answers(monkeypatch):
    class Loop:
        async def getaddrinfo(self, *args, **kwargs):
            return [
                (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("93.184.216.34", 443)),
                (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("169.254.169.254", 443)),
            ]

    monkeypatch.setattr("app.security.asyncio.get_running_loop", lambda: Loop())
    with pytest.raises(UnsafeURLError):
        await PublicOnlyResolver().resolve("rebound.example", 443)
