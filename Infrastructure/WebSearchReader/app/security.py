from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import socket
import time
from dataclasses import dataclass
from urllib.parse import urlsplit, urlunsplit

from aiohttp.abc import AbstractResolver


class UnsafeURLError(ValueError):
    pass


def _is_public_address(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    return address.is_global and not (
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_multicast
        or address.is_reserved
        or address.is_unspecified
    )


def validate_public_url(raw_url: str) -> str:
    try:
        parsed = urlsplit(raw_url)
    except ValueError as exc:
        raise UnsafeURLError("invalid URL") from exc
    if parsed.scheme.lower() not in {"http", "https"}:
        raise UnsafeURLError("only HTTP and HTTPS URLs are supported")
    if parsed.username is not None or parsed.password is not None:
        raise UnsafeURLError("credentials in URLs are not allowed")
    if not parsed.hostname:
        raise UnsafeURLError("URL host is required")
    hostname = parsed.hostname.rstrip(".").lower()
    if "%" in hostname:
        raise UnsafeURLError("encoded hostnames are not allowed")
    if hostname in {"localhost", "metadata", "metadata.google.internal"}:
        raise UnsafeURLError("local and metadata hosts are not allowed")
    if hostname.endswith((".localhost", ".local", ".internal")):
        raise UnsafeURLError("local hostnames are not allowed")
    try:
        port = parsed.port
    except ValueError as exc:
        raise UnsafeURLError("invalid URL port") from exc
    expected = 443 if parsed.scheme.lower() == "https" else 80
    if port is not None and port != expected:
        raise UnsafeURLError("only standard HTTP and HTTPS ports are allowed")
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        # libc accepts legacy integer/octal/short IPv4 spellings that
        # ipaddress intentionally rejects (for example 2130706433). Never let
        # those forms bypass the literal-address check in the resolver.
        try:
            socket.inet_aton(hostname)
        except OSError:
            pass
        else:
            raise UnsafeURLError("non-canonical numeric IP addresses are not allowed")
    else:
        if not _is_public_address(hostname):
            raise UnsafeURLError("non-public IP addresses are not allowed")
    netloc = hostname
    if ":" in hostname:
        netloc = f"[{hostname}]"
    return urlunsplit((parsed.scheme.lower(), netloc, parsed.path or "/", parsed.query, ""))


class PublicOnlyResolver(AbstractResolver):
    """Resolve once per connection and return only validated public addresses.

    aiohttp connects to one of the returned addresses while preserving the original
    hostname for Host/SNI, preventing the validation/connect DNS-rebinding gap.
    """

    async def resolve(self, host: str, port: int = 0, family: int = socket.AF_UNSPEC):
        loop = asyncio.get_running_loop()
        infos = await loop.getaddrinfo(
            host,
            port,
            family=family,
            type=socket.SOCK_STREAM,
            proto=socket.IPPROTO_TCP,
        )
        results: list[dict[str, object]] = []
        seen: set[tuple[int, str]] = set()
        for resolved_family, _, proto, _, sockaddr in infos:
            address = sockaddr[0]
            key = (resolved_family, address)
            if key in seen:
                continue
            seen.add(key)
            if not _is_public_address(address):
                raise UnsafeURLError("hostname resolves to a non-public address")
            results.append(
                {
                    "hostname": host,
                    "host": address,
                    "port": port,
                    "family": resolved_family,
                    "proto": proto,
                    "flags": socket.AI_NUMERICHOST,
                }
            )
        if not results:
            raise UnsafeURLError("hostname did not resolve")
        return results

    async def close(self) -> None:
        return None


def _b64encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _b64decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


@dataclass(frozen=True)
class SourceReference:
    url: str
    expires_at: int
    citation_index: int = 1


class SourceReferenceSigner:
    def __init__(self, secret: str | None = None):
        value = secret or os.environ.get("READER_REF_SIGNING_KEY", "")
        if len(value.encode("utf-8")) < 32:
            raise RuntimeError("READER_REF_SIGNING_KEY must contain at least 32 bytes")
        self._key = value.encode("utf-8")

    def sign(self, url: str, ttl_seconds: int = 86_400, citation_index: int = 1) -> str:
        payload = json.dumps(
            {
                "url": validate_public_url(url),
                "exp": int(time.time()) + ttl_seconds,
                "citation_index": max(1, citation_index),
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        signature = hmac.new(self._key, payload, hashlib.sha256).digest()
        return f"{_b64encode(payload)}.{_b64encode(signature)}"

    def verify(self, token: str) -> SourceReference:
        try:
            encoded_payload, encoded_signature = token.split(".", 1)
            payload = _b64decode(encoded_payload)
            signature = _b64decode(encoded_signature)
            expected = hmac.new(self._key, payload, hashlib.sha256).digest()
            if not hmac.compare_digest(signature, expected):
                raise UnsafeURLError("invalid source reference")
            decoded = json.loads(payload)
            expires_at = int(decoded["exp"])
            if expires_at < int(time.time()):
                raise UnsafeURLError("source reference expired")
            url = validate_public_url(str(decoded["url"]))
            return SourceReference(
                url=url,
                expires_at=expires_at,
                citation_index=max(1, int(decoded.get("citation_index", 1))),
            )
        except UnsafeURLError:
            raise
        except Exception as exc:
            raise UnsafeURLError("invalid source reference") from exc
