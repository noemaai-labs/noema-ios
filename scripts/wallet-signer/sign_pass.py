#!/usr/bin/env python3
"""Noema Wallet pass signer.

This server implements:

    GET  /v1/wallet/app-attest/challenge
    POST /v1/wallet/app-attest/register
    POST /v1/wallet/passes/sign

The public app never receives the internal signer token. Nginx injects that
token, while App Attest proves the final signing request came from Noema.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import zlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from zipfile import ZIP_DEFLATED, ZipFile

import cbor2
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa, utils
from cryptography.x509.oid import ObjectIdentifier


PASS_TYPE_IDENTIFIER = os.environ.get(
    "NOEMA_PASS_TYPE_IDENTIFIER",
    "pass.com.noemaai.noema.transport",
)
TEAM_IDENTIFIER = os.environ.get("NOEMA_TEAM_IDENTIFIER", "XX3Z6V9TU9")
SIGNER_TOKEN = os.environ.get("NOEMA_WALLET_SIGNER_TOKEN", "")
P12_PATH = os.environ.get("NOEMA_PASS_P12", "")
P12_PASSWORD = os.environ.get("NOEMA_PASS_P12_PASSWORD", "")
PASS_CERT_PATH = os.environ.get("NOEMA_PASS_CERT", "")
WWDR_CERT_PATH = os.environ.get("NOEMA_WWDR_CERT", "")
ASSETS_DIR = os.environ.get("NOEMA_PASS_ASSETS_DIR", "")
HOST = os.environ.get("NOEMA_WALLET_SIGNER_HOST", "127.0.0.1")
PORT = int(os.environ.get("NOEMA_WALLET_SIGNER_PORT", "8787"))
APP_ATTEST_APP_ID = os.environ.get("NOEMA_APP_ATTEST_APP_ID", f"{TEAM_IDENTIFIER}.arminproducts.Noema")
APP_ATTEST_ROOT_CERT = os.environ.get("NOEMA_APP_ATTEST_ROOT_CERT", "")
APP_ATTEST_STORE = os.environ.get(
    "NOEMA_APP_ATTEST_STORE",
    "/var/lib/noema-wallet-signer/app-attest-keys.json",
)
REQUIRE_APP_ATTEST = os.environ.get("NOEMA_REQUIRE_APP_ATTEST", "true").lower() != "false"
CHALLENGE_TTL_SECONDS = int(os.environ.get("NOEMA_APP_ATTEST_CHALLENGE_TTL_SECONDS", "300"))
LOGO_ASSET_NAMES = frozenset({"logo.png", "logo@2x.png", "logo@3x.png"})
GENERATED_ICON_ASSET_NAMES = frozenset({"icon.png", "icon@2x.png", "icon@3x.png"})

APP_ATTEST_NONCE_OID = ObjectIdentifier("1.2.840.113635.100.8.2")
ATTEST_REQUEST_ID_HEADER = "X-Noema-Attest-Request-ID"
ATTEST_ATTEMPT_HEADER = "X-Noema-Attest-Attempt"
ATTEST_CLIENT_DATA_HEADER = "X-Noema-App-Attest-Client-Data"
ATTEST_CLIENT_DATA_HASH_HEADER = "X-Noema-App-Attest-Client-Data-Hash"
CHALLENGES: dict[str, dict[str, Any]] = {}
CHALLENGE_LOCK = threading.Lock()
KEY_STORE_LOCK = threading.Lock()


class SignerError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def app_attest_error(code: str, status: int = 401, **context: Any) -> None:
    log_app_attest("reject", code=code, **context)
    raise SignerError(status, code)


class NoemaWalletSigner(BaseHTTPRequestHandler):
    server_version = "NoemaWalletSigner/1.1"

    def do_GET(self) -> None:
        self.attest_request_id = request_id_from_headers(self.headers)
        self.attest_attempt = attempt_from_headers(self.headers)
        if self.path.startswith("/v1/wallet/app-attest/challenge"):
            try:
                self.authorize()
                purpose = self.query_param("purpose") or "assert"
                if purpose not in {"register", "assert"}:
                    raise SignerError(400, "Invalid App Attest challenge purpose.")
                challenge = issue_challenge(purpose)
                log_app_attest("challenge", request_id=self.attest_request_id, attempt=self.attest_attempt, purpose=purpose)
                self.send_json(200, {"challenge": challenge, "expiresIn": CHALLENGE_TTL_SECONDS})
            except SignerError as error:
                self.send_text(error.status, error.message)
            except Exception as error:
                self.send_text(500, f"App Attest challenge failed: {error}")
            return
        self.send_text(404, "Not found")

    def do_POST(self) -> None:
        self.attest_request_id = request_id_from_headers(self.headers)
        self.attest_attempt = attempt_from_headers(self.headers)
        try:
            if self.path.rstrip("/") == "/v1/wallet/app-attest/register":
                self.authorize()
                body = self.read_body()
                payload = parse_json_body(body)
                register_app_attest_key(payload, request_id=self.attest_request_id, attempt=self.attest_attempt)
                self.send_json(200, {"registered": True})
                return

            if self.path.rstrip("/") == "/v1/wallet/passes/sign":
                self.authorize()
                body = self.read_body()
                verify_app_attest_assertion(self.headers, body)
                payload = parse_json_body(body)
                pkpass = build_pkpass(payload)
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.apple.pkpass")
                self.send_header("Content-Length", str(len(pkpass)))
                self.end_headers()
                self.wfile.write(pkpass)
                return

            self.send_text(404, "Not found")
        except SignerError as error:
            self.send_text(error.status, error.message)
        except Exception as error:
            self.send_text(500, f"Wallet signing failed: {error}")

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.address_string()} - {fmt % args}")

    def authorize(self) -> None:
        if not SIGNER_TOKEN:
            raise SignerError(500, "NOEMA_WALLET_SIGNER_TOKEN is not configured.")
        value = self.headers.get("Authorization", "")
        expected = f"Bearer {SIGNER_TOKEN}"
        if value != expected:
            raise SignerError(401, "Invalid signer token.")

    def query_param(self, name: str) -> str | None:
        from urllib.parse import parse_qs, urlsplit

        values = parse_qs(urlsplit(self.path).query).get(name)
        return values[0] if values else None

    def read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            raise SignerError(400, "Missing request body.")
        return self.rfile.read(length)

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if getattr(self, "attest_request_id", ""):
            self.send_header(ATTEST_REQUEST_ID_HEADER, self.attest_request_id)
        self.end_headers()
        self.wfile.write(data)

    def send_text(self, status: int, message: str) -> None:
        data = message.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        if getattr(self, "attest_request_id", ""):
            self.send_header(ATTEST_REQUEST_ID_HEADER, self.attest_request_id)
        self.end_headers()
        self.wfile.write(data)


def parse_json_body(data: bytes) -> dict[str, Any]:
    try:
        value = json.loads(data.decode("utf-8"))
    except json.JSONDecodeError as error:
        raise SignerError(400, f"Invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise SignerError(400, "Request body must be a JSON object.")
    return value


def issue_challenge(purpose: str) -> str:
    cleanup_challenges()
    raw = secrets.token_bytes(32)
    encoded = base64url_encode(raw)
    with CHALLENGE_LOCK:
        CHALLENGES[encoded] = {
            "raw": raw,
            "purpose": purpose,
            "expires": time.time() + CHALLENGE_TTL_SECONDS,
        }
    return encoded


def consume_challenge(encoded: str, purpose: str) -> bytes:
    cleanup_challenges()
    with CHALLENGE_LOCK:
        entry = CHALLENGES.pop(encoded, None)
    if not entry:
        raise SignerError(401, "Missing or expired App Attest challenge.")
    if entry.get("purpose") != purpose:
        raise SignerError(401, "App Attest challenge purpose mismatch.")
    if float(entry.get("expires", 0)) < time.time():
        raise SignerError(401, "Expired App Attest challenge.")
    return entry["raw"]


def cleanup_challenges() -> None:
    now = time.time()
    with CHALLENGE_LOCK:
        expired = [key for key, value in CHALLENGES.items() if float(value.get("expires", 0)) < now]
        for key in expired:
            CHALLENGES.pop(key, None)


def register_app_attest_key(payload: dict[str, Any], request_id: str = "", attempt: str = "") -> None:
    if not REQUIRE_APP_ATTEST:
        return
    key_id = require_string(payload, "keyId")
    challenge = require_string(payload, "challenge")
    attestation_object = base64url_decode(require_string(payload, "attestationObject"))
    challenge_bytes = consume_challenge(challenge, "register")
    client_data_hash = hashlib.sha256(challenge_bytes).digest()
    public_key, sign_count, metadata = verify_attestation_object(key_id, attestation_object, client_data_hash)
    store_registered_key(key_id, public_key, sign_count, metadata=metadata, verified=False)
    log_app_attest(
        "register",
        request_id=request_id,
        attempt=attempt,
        key=key_reference(key_id),
        sign_count=sign_count,
        environment=metadata.get("environment"),
        key_id_match=metadata.get("keyIDMatch"),
        public_key_fingerprint=metadata.get("publicKeyFingerprint"),
    )


def verify_app_attest_assertion(headers: Any, body: bytes) -> None:
    if not REQUIRE_APP_ATTEST:
        return
    request_id = request_id_from_headers(headers)
    attempt = attempt_from_headers(headers)
    key_id = headers.get("X-Noema-App-Attest-Key-ID", "")
    challenge = headers.get("X-Noema-App-Attest-Challenge", "")
    assertion_header = headers.get("X-Noema-App-Attest-Assertion", "")
    body_hash_header = headers.get("X-Noema-Body-SHA256", "")
    client_data_mode = safe_header_value(headers.get(ATTEST_CLIENT_DATA_HEADER, ""))
    claimed_client_data_hash_header = headers.get(ATTEST_CLIENT_DATA_HASH_HEADER, "")
    if not key_id or not challenge or not assertion_header or not body_hash_header:
        app_attest_error("app_attest_missing_assertion", request_id=request_id, attempt=attempt, key=key_reference(key_id))

    stored = load_registered_key(key_id, request_id=request_id, attempt=attempt)
    challenge_bytes = consume_challenge(challenge, "assert")
    body_hash = hashlib.sha256(body).digest()
    canonical_client_data_hash = hashlib.sha256(challenge_bytes + body_hash).digest()
    claimed_client_data_hash = validate_claimed_client_data_hash(
        claimed_client_data_hash_header,
        canonical_client_data_hash,
        request_id=request_id,
        attempt=attempt,
        key=key_reference(key_id),
        body_hash=hash_prefix(body_hash),
    )
    try:
        claimed_body_hash = base64url_decode(body_hash_header)
    except SignerError:
        app_attest_error("app_attest_body_hash_mismatch", request_id=request_id, attempt=attempt, key=key_reference(key_id), body_hash=hash_prefix(body_hash))
    if body_hash != claimed_body_hash:
        app_attest_error(
            "app_attest_body_hash_mismatch",
            request_id=request_id,
            attempt=attempt,
            key=key_reference(key_id),
            body_hash=hash_prefix(body_hash),
        )

    try:
        assertion = cbor2.loads(base64url_decode(assertion_header))
    except Exception:
        app_attest_error("app_attest_malformed_assertion", request_id=request_id, attempt=attempt, key=key_reference(key_id))
    if not isinstance(assertion, dict):
        app_attest_error("app_attest_malformed_assertion", request_id=request_id, attempt=attempt, key=key_reference(key_id))
    authenticator_data = assertion.get("authenticatorData")
    signature = assertion.get("signature")
    if not isinstance(authenticator_data, bytes) or not isinstance(signature, bytes):
        app_attest_error("app_attest_malformed_assertion", request_id=request_id, attempt=attempt, key=key_reference(key_id))

    parsed = parse_authenticator_data(authenticator_data, expect_attested_credential=False)
    verify_rp_id_hash(parsed["rp_id_hash"])
    public_key = serialization.load_pem_public_key(stored["publicKey"].encode("utf-8"))

    verification = verify_assertion_signature_for_client_data_hash(
        public_key,
        signature,
        authenticator_data,
        canonical_client_data_hash,
    )
    if not verification.passed:
        app_attest_error(
            "app_attest_signature_invalid",
            request_id=request_id,
            attempt=attempt,
            key=key_reference(key_id),
            auth_data_len=len(authenticator_data),
            signature_len=len(signature),
            sign_count=parsed["sign_count"],
            stored_sign_count=stored.get("signCount", 0),
            body_hash=hash_prefix(body_hash),
            client_data_mode=client_data_mode or "absent",
            claimed_client_data_hash=hash_prefix(claimed_client_data_hash) if claimed_client_data_hash else "absent",
            canonical_client_data_hash=hash_prefix(canonical_client_data_hash),
            authenticator_data=hash_prefix(authenticator_data),
            signature=hash_prefix(signature),
            public_key_fingerprint=stored.get("publicKeyFingerprint"),
            environment=stored.get("environment"),
            key_id_match=stored.get("keyIDMatch"),
            verifier_branches=verification.summary,
        )

    if parsed["sign_count"] <= int(stored.get("signCount", 0)):
        app_attest_error(
            "app_attest_stale_counter",
            request_id=request_id,
            attempt=attempt,
            key=key_reference(key_id),
            sign_count=parsed["sign_count"],
            stored_sign_count=stored.get("signCount", 0),
        )
    store_registered_key(key_id, public_key, parsed["sign_count"], metadata=stored, verified=True)
    log_app_attest(
        "assert",
        request_id=request_id,
        attempt=attempt,
        key=key_reference(key_id),
        auth_data_len=len(authenticator_data),
        signature_len=len(signature),
        sign_count=parsed["sign_count"],
        stored_sign_count=stored.get("signCount", 0),
        body_hash=hash_prefix(body_hash),
        client_data_mode=client_data_mode or "absent",
        claimed_client_data_hash=hash_prefix(claimed_client_data_hash) if claimed_client_data_hash else "absent",
        canonical_client_data_hash=hash_prefix(canonical_client_data_hash),
        nonce=hash_prefix(hashlib.sha256(authenticator_data + verification.client_data_hash).digest()),
        nonce_message=verification.nonce_message_result.label,
        direct_concat=verification.direct_result.label,
        prehashed_nonce=verification.prehashed_result.label,
        environment=stored.get("environment"),
        key_id_match=stored.get("keyIDMatch"),
        public_key_fingerprint=stored.get("publicKeyFingerprint"),
    )


def verify_attestation_object(key_id: str, attestation_object: bytes, client_data_hash: bytes) -> tuple[Any, int, dict[str, Any]]:
    attestation = cbor2.loads(attestation_object)
    if attestation.get("fmt") != "apple-appattest":
        app_attest_error("app_attest_invalid_format", key=key_reference(key_id))
    auth_data = attestation.get("authData")
    att_stmt = attestation.get("attStmt")
    if not isinstance(auth_data, bytes) or not isinstance(att_stmt, dict):
        app_attest_error("app_attest_malformed_attestation", key=key_reference(key_id))

    parsed = parse_authenticator_data(auth_data, expect_attested_credential=True)
    verify_rp_id_hash(parsed["rp_id_hash"])
    public_key = public_key_from_cose(parsed["cose_key"])
    key_id_match = verify_key_id(key_id, parsed["credential_id"], public_key)

    certs = att_stmt.get("x5c")
    if not isinstance(certs, list) or len(certs) < 2 or not all(isinstance(cert, bytes) for cert in certs):
        app_attest_error("app_attest_missing_certificate_chain", key=key_reference(key_id))
    leaf = x509.load_der_x509_certificate(certs[0])
    chain = [x509.load_der_x509_certificate(cert) for cert in certs[1:]]
    verify_attestation_chain(leaf, chain)
    if leaf.public_key().public_numbers() != public_key.public_numbers():
        app_attest_error("app_attest_certificate_key_mismatch", key=key_reference(key_id))
    verify_attestation_nonce(leaf, auth_data, client_data_hash)
    metadata = {
        "aaguid": aaguid_value(parsed["aaguid"]),
        "environment": app_attest_environment(parsed["aaguid"]),
        "keyIDMatch": key_id_match,
        "publicKeyFingerprint": public_key_fingerprint(public_key),
    }
    return public_key, parsed["sign_count"], metadata


def verify_attestation_chain(leaf: x509.Certificate, chain: list[x509.Certificate]) -> None:
    if not APP_ATTEST_ROOT_CERT:
        raise SignerError(500, "NOEMA_APP_ATTEST_ROOT_CERT is not configured.")
    root = load_certificate(Path(APP_ATTEST_ROOT_CERT))
    now = datetime.now(timezone.utc)
    for cert in [leaf, *chain, root]:
        not_before = getattr(cert, "not_valid_before_utc", cert.not_valid_before.replace(tzinfo=timezone.utc))
        not_after = getattr(cert, "not_valid_after_utc", cert.not_valid_after.replace(tzinfo=timezone.utc))
        if now < not_before or now > not_after:
            raise SignerError(401, "Expired App Attest certificate.")

    issuers = chain + [root]
    child = leaf
    for issuer in issuers:
        verify_certificate_signature(child, issuer)
        if issuer.subject == root.subject:
            return
        child = issuer
    raise SignerError(401, "Invalid App Attest certificate chain.")


def verify_certificate_signature(child: x509.Certificate, issuer: x509.Certificate) -> None:
    public_key = issuer.public_key()
    try:
        if isinstance(public_key, rsa.RSAPublicKey):
            public_key.verify(
                child.signature,
                child.tbs_certificate_bytes,
                padding.PKCS1v15(),
                child.signature_hash_algorithm,
            )
        elif isinstance(public_key, ec.EllipticCurvePublicKey):
            public_key.verify(
                child.signature,
                child.tbs_certificate_bytes,
                ec.ECDSA(child.signature_hash_algorithm),
            )
        else:
            raise SignerError(401, "Unsupported App Attest certificate key.")
    except InvalidSignature as error:
        raise SignerError(401, "Invalid App Attest certificate signature.") from error


def verify_attestation_nonce(leaf: x509.Certificate, auth_data: bytes, client_data_hash: bytes) -> None:
    expected = hashlib.sha256(auth_data + client_data_hash).digest()
    try:
        extension = leaf.extensions.get_extension_for_oid(APP_ATTEST_NONCE_OID)
    except x509.ExtensionNotFound as error:
        raise SignerError(401, "Missing App Attest nonce.") from error
    value = getattr(extension.value, "value", b"")
    if expected not in app_attest_nonce_values(value):
        raise SignerError(401, "Invalid App Attest nonce.")


def app_attest_nonce_values(data: bytes) -> list[bytes]:
    if len(data) == 32:
        return [data]
    values: list[bytes] = []

    def read_length(offset: int) -> tuple[int, int]:
        if offset >= len(data):
            raise ValueError("Missing ASN.1 length.")
        first = data[offset]
        offset += 1
        if first < 0x80:
            return first, offset
        count = first & 0x7F
        if count == 0 or count > 4 or offset + count > len(data):
            raise ValueError("Invalid ASN.1 length.")
        return int.from_bytes(data[offset:offset + count], "big"), offset + count

    def walk(start: int, end: int) -> None:
        offset = start
        while offset < end:
            tag = data[offset]
            offset += 1
            length, offset = read_length(offset)
            content_end = offset + length
            if content_end > end:
                raise ValueError("Invalid ASN.1 content length.")
            content = data[offset:content_end]
            if tag == 0x04 and len(content) == 32:
                values.append(content)
            if tag & 0x20:
                walk(offset, content_end)
            offset = content_end

    try:
        walk(0, len(data))
    except ValueError:
        return []
    return values


class SignatureVerificationResult:
    def __init__(self, passed: bool, label: str) -> None:
        self.passed = passed
        self.label = label


class AssertionVerificationResult:
    def __init__(
        self,
        passed: bool,
        client_data_hash: bytes,
        nonce_message_result: SignatureVerificationResult,
        direct_result: SignatureVerificationResult,
        prehashed_result: SignatureVerificationResult,
        summary: str,
    ) -> None:
        self.passed = passed
        self.client_data_hash = client_data_hash
        self.nonce_message_result = nonce_message_result
        self.direct_result = direct_result
        self.prehashed_result = prehashed_result
        self.summary = summary


def verify_assertion_signature_for_client_data_hash(
    public_key: Any,
    signature: bytes,
    authenticator_data: bytes,
    client_data_hash: bytes,
) -> AssertionVerificationResult:
    nonce_message_result = verify_assertion_signature_nonce_message(public_key, signature, authenticator_data, client_data_hash)
    direct_result = verify_assertion_signature_direct(public_key, signature, authenticator_data, client_data_hash)
    prehashed_result = verify_assertion_signature_prehashed_nonce(public_key, signature, authenticator_data, client_data_hash)
    summary = ";".join(
        [
            f"nonce_message:{nonce_message_result.label}",
            f"direct_concat:{direct_result.label}",
            f"prehashed_nonce:{prehashed_result.label}",
        ]
    )
    return AssertionVerificationResult(
        nonce_message_result.passed,
        client_data_hash,
        nonce_message_result,
        direct_result,
        prehashed_result,
        summary,
    )


def verify_assertion_signature_nonce_message(public_key: Any, signature: bytes, authenticator_data: bytes, client_data_hash: bytes) -> SignatureVerificationResult:
    nonce = hashlib.sha256(authenticator_data + client_data_hash).digest()
    return verify_ecdsa_with_supported_encodings(public_key, signature, nonce, ec.ECDSA(hashes.SHA256()), label_prefix="nonce_message")


def verify_assertion_signature_direct(public_key: Any, signature: bytes, authenticator_data: bytes, client_data_hash: bytes) -> SignatureVerificationResult:
    message = authenticator_data + client_data_hash
    return verify_ecdsa_with_supported_encodings(public_key, signature, message, ec.ECDSA(hashes.SHA256()), label_prefix="direct")


def verify_assertion_signature_prehashed_nonce(public_key: Any, signature: bytes, authenticator_data: bytes, client_data_hash: bytes) -> SignatureVerificationResult:
    nonce = hashlib.sha256(authenticator_data + client_data_hash).digest()
    return verify_ecdsa_with_supported_encodings(
        public_key,
        signature,
        nonce,
        ec.ECDSA(utils.Prehashed(hashes.SHA256())),
        label_prefix="prehashed",
    )


def verify_ecdsa_with_supported_encodings(public_key: Any, signature: bytes, message: bytes, algorithm: Any, label_prefix: str) -> SignatureVerificationResult:
    try:
        public_key.verify(signature, message, algorithm)
        return SignatureVerificationResult(True, f"{label_prefix}_der_pass")
    except InvalidSignature:
        pass

    if len(signature) == 64:
        raw_signature = utils.encode_dss_signature(
            int.from_bytes(signature[:32], "big"),
            int.from_bytes(signature[32:], "big"),
        )
        try:
            public_key.verify(raw_signature, message, algorithm)
            return SignatureVerificationResult(True, f"{label_prefix}_raw64_pass")
        except InvalidSignature:
            return SignatureVerificationResult(False, f"{label_prefix}_raw64_fail")
    return SignatureVerificationResult(False, f"{label_prefix}_der_fail")


def parse_authenticator_data(data: bytes, expect_attested_credential: bool) -> dict[str, Any]:
    if len(data) < 37:
        raise SignerError(401, "Invalid App Attest authenticator data.")
    rp_id_hash = data[:32]
    flags = data[32]
    sign_count = int.from_bytes(data[33:37], "big")
    result: dict[str, Any] = {
        "rp_id_hash": rp_id_hash,
        "flags": flags,
        "sign_count": sign_count,
    }
    if not expect_attested_credential:
        return result

    if len(data) < 55:
        raise SignerError(401, "Invalid App Attest credential data.")
    credential_id_length = int.from_bytes(data[53:55], "big")
    credential_start = 55
    credential_end = credential_start + credential_id_length
    if len(data) <= credential_end:
        raise SignerError(401, "Invalid App Attest credential length.")
    cose_key = cbor2.loads(data[credential_end:])
    result.update(
        {
            "aaguid": data[37:53],
            "credential_id": data[credential_start:credential_end],
            "cose_key": cose_key,
        }
    )
    return result


def verify_rp_id_hash(value: bytes) -> None:
    expected = hashlib.sha256(APP_ATTEST_APP_ID.encode("utf-8")).digest()
    if value != expected:
        app_attest_error("app_attest_app_id_mismatch")


def public_key_from_cose(cose_key: Any) -> ec.EllipticCurvePublicKey:
    if not isinstance(cose_key, dict):
        raise SignerError(401, "Invalid App Attest public key.")
    if cose_key.get(1) != 2 or cose_key.get(3) != -7 or cose_key.get(-1) != 1:
        raise SignerError(401, "Invalid App Attest COSE key parameters.")
    x = cose_key.get(-2)
    y = cose_key.get(-3)
    if not isinstance(x, bytes) or not isinstance(y, bytes) or len(x) != 32 or len(y) != 32:
        raise SignerError(401, "Invalid App Attest elliptic curve key.")
    numbers = ec.EllipticCurvePublicNumbers(
        int.from_bytes(x, "big"),
        int.from_bytes(y, "big"),
        ec.SECP256R1(),
    )
    return numbers.public_key()


def verify_key_id(key_id: str, credential_id: bytes, public_key: ec.EllipticCurvePublicKey) -> str:
    decoded = decode_key_id(key_id)
    numbers = public_key.public_numbers()
    uncompressed = (
        b"\x04"
        + numbers.x.to_bytes(32, "big")
        + numbers.y.to_bytes(32, "big")
    )
    public_key_hash = hashlib.sha256(uncompressed).digest()
    credential_matches = decoded == credential_id
    public_key_matches = decoded == public_key_hash
    if not credential_matches or not public_key_matches:
        app_attest_error(
            "app_attest_key_binding_mismatch",
            key=key_reference(key_id),
            decoded_len=len(decoded),
            credential_len=len(credential_id),
            credential_id=hash_prefix(credential_id),
            public_key_hash=hash_prefix(public_key_hash),
        )
    return "credential_id+public_key_hash"


def decode_key_id(key_id: str) -> bytes:
    try:
        return base64url_decode(key_id)
    except SignerError:
        try:
            return base64.b64decode(key_id, validate=True)
        except Exception as error:
            raise SignerError(401, "Invalid App Attest key identifier.") from error


def load_certificate(path: Path) -> x509.Certificate:
    if not path.is_file():
        raise SignerError(500, f"{path} does not point to a file.")
    data = path.read_bytes()
    try:
        return x509.load_pem_x509_certificate(data)
    except ValueError:
        return x509.load_der_x509_certificate(data)


def require_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value:
        raise SignerError(400, f"Missing {key}.")
    return value


def public_key_fingerprint(public_key: Any) -> str:
    data = public_key.public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return hashlib.sha256(data).hexdigest()


def aaguid_value(aaguid: bytes) -> str:
    try:
        value = aaguid.decode("ascii")
        if value.isprintable():
            return value
    except UnicodeDecodeError:
        pass
    return aaguid.hex()


def app_attest_environment(aaguid: bytes) -> str:
    if aaguid == b"appattestsandbox" or aaguid == b"appattestdevelop":
        return "development"
    if aaguid == b"appattest" + (b"\x00" * 7) or aaguid == b"appattest":
        return "production"
    return "unknown"


def app_attest_environment_from_value(value: Any) -> str:
    if not isinstance(value, str):
        return "unknown"
    if value in {"appattestsandbox", "appattestdevelop"}:
        return "development"
    if value == "appattest" or value.startswith("appattest0000000"):
        return "production"
    return "unknown"


def request_id_from_headers(headers: Any) -> str:
    value = headers.get(ATTEST_REQUEST_ID_HEADER, "") if headers else ""
    if not isinstance(value, str):
        return ""
    filtered = "".join(ch for ch in value if ch.isalnum() or ch in "-_")
    return filtered[:64]


def attempt_from_headers(headers: Any) -> str:
    value = headers.get(ATTEST_ATTEMPT_HEADER, "") if headers else ""
    return value if value in {"1", "2"} else ""


def safe_header_value(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    filtered = "".join(ch for ch in value if ch.isalnum() or ch in "-_+./")
    return filtered[:80]


def decode_optional_client_data_hash(value: Any) -> bytes | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        decoded = base64url_decode(value)
    except SignerError:
        raise SignerError(401, "app_attest_client_data_hash_mismatch")
    if len(decoded) != 32:
        raise SignerError(401, "app_attest_client_data_hash_mismatch")
    return decoded


def validate_claimed_client_data_hash(value: Any, canonical_client_data_hash: bytes, **context: Any) -> bytes | None:
    try:
        claimed = decode_optional_client_data_hash(value)
    except SignerError:
        app_attest_error(
            "app_attest_client_data_hash_mismatch",
            canonical_client_data_hash=hash_prefix(canonical_client_data_hash),
            **context,
        )
    if claimed is not None and claimed != canonical_client_data_hash:
        app_attest_error(
            "app_attest_client_data_hash_mismatch",
            claimed_client_data_hash=hash_prefix(claimed),
            canonical_client_data_hash=hash_prefix(canonical_client_data_hash),
            **context,
        )
    return claimed


def key_reference(key_id: str | None) -> str:
    if not key_id:
        return "missing"
    return f"{key_id[:6]}:{hashlib.sha256(key_id.encode('utf-8')).hexdigest()[:12]}"


def hash_prefix(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:12]


def log_app_attest(event: str, **fields: Any) -> None:
    safe_fields = " ".join(
        f"{key}={value}"
        for key, value in sorted(fields.items())
        if value is not None
    )
    print(f"app_attest event={event} {safe_fields}", flush=True)


def load_key_store() -> dict[str, Any]:
    path = Path(APP_ATTEST_STORE)
    if not path.is_file():
        return {"keys": {}}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"keys": {}}
    return value if isinstance(value, dict) else {"keys": {}}


def store_registered_key(
    key_id: str,
    public_key: Any,
    sign_count: int,
    metadata: dict[str, Any] | None = None,
    verified: bool = False,
) -> None:
    pem = public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode("utf-8")
    metadata = dict(metadata or {})
    if metadata.get("environment") in {None, "unknown"}:
        inferred_environment = app_attest_environment_from_value(metadata.get("aaguid"))
        if inferred_environment != "unknown":
            metadata["environment"] = inferred_environment
    with KEY_STORE_LOCK:
        store = load_key_store()
        keys = store.setdefault("keys", {})
        previous = keys.get(key_id, {}) if isinstance(keys.get(key_id), dict) else {}
        now = int(time.time())
        entry = {
            **previous,
            **(metadata or {}),
            "publicKey": pem,
            "publicKeyFingerprint": public_key_fingerprint(public_key),
            "signCount": sign_count,
            "updatedAt": now,
        }
        if verified:
            entry["lastVerifiedAt"] = now
        else:
            entry.setdefault("registeredAt", now)
        keys[key_id] = entry
        path = Path(APP_ATTEST_STORE)
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(store, separators=(",", ":"), sort_keys=True), encoding="utf-8")
        temp.replace(path)


def load_registered_key(key_id: str, request_id: str = "", attempt: str = "") -> dict[str, Any]:
    with KEY_STORE_LOCK:
        store = load_key_store()
    keys = store.get("keys", {})
    if not isinstance(keys, dict) or key_id not in keys:
        app_attest_error("app_attest_unknown_key", request_id=request_id, attempt=attempt, key=key_reference(key_id))
    value = keys[key_id]
    if not isinstance(value, dict):
        app_attest_error("app_attest_invalid_key_store_entry", request_id=request_id, attempt=attempt, key=key_reference(key_id))
    return value


def base64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def base64url_decode(value: str) -> bytes:
    try:
        padded = value + ("=" * ((4 - len(value) % 4) % 4))
        return base64.urlsafe_b64decode(padded.encode("ascii"))
    except Exception as error:
        raise SignerError(400, "Invalid base64url value.") from error


def build_pkpass(payload: dict[str, Any]) -> bytes:
    validate_environment()
    pass_json = payload.get("passJSON")
    if not isinstance(pass_json, dict):
        raise SignerError(400, "Missing passJSON object.")

    pass_json = dict(pass_json)
    if pass_json.get("passTypeIdentifier") != PASS_TYPE_IDENTIFIER:
        raise SignerError(400, "passTypeIdentifier does not match signer configuration.")
    if pass_json.get("teamIdentifier") != TEAM_IDENTIFIER:
        raise SignerError(400, "teamIdentifier does not match signer configuration.")

    with tempfile.TemporaryDirectory(prefix="noema-wallet-pass-") as workspace:
        root = Path(workspace)
        pass_dir = root / "pass"
        pass_dir.mkdir()

        (pass_dir / "pass.json").write_text(
            json.dumps(pass_json, ensure_ascii=False, separators=(",", ":"), sort_keys=True),
            encoding="utf-8",
        )
        install_assets(pass_dir)

        manifest = create_manifest(pass_dir)
        (pass_dir / "manifest.json").write_text(
            json.dumps(manifest, separators=(",", ":"), sort_keys=True),
            encoding="utf-8",
        )

        cert_pem = root / "pass-cert.pem"
        key_pem = root / "pass-key.pem"
        extract_identity(Path(P12_PATH), P12_PASSWORD, cert_pem, key_pem, Path(PASS_CERT_PATH) if PASS_CERT_PATH else None)
        wwdr_pem = root / "wwdr.pem"
        normalize_certificate(Path(WWDR_CERT_PATH), wwdr_pem)
        sign_manifest(pass_dir / "manifest.json", pass_dir / "signature", cert_pem, key_pem, wwdr_pem)

        output = root / "signed.pkpass"
        zip_pass(pass_dir, output)
        return output.read_bytes()


def validate_environment() -> None:
    missing = [
        name
        for name, value in [
            ("NOEMA_PASS_P12", P12_PATH),
            ("NOEMA_PASS_P12_PASSWORD", P12_PASSWORD),
            ("NOEMA_WWDR_CERT", WWDR_CERT_PATH),
        ]
        if not value
    ]
    if missing:
        raise SignerError(500, f"Missing signer environment: {', '.join(missing)}")
    for name, path in [("NOEMA_PASS_P12", P12_PATH), ("NOEMA_WWDR_CERT", WWDR_CERT_PATH)]:
        if not Path(path).is_file():
            raise SignerError(500, f"{name} does not point to a file.")


def extract_identity(p12_path: Path, password: str, cert_pem: Path, key_pem: Path, pass_cert: Path | None) -> None:
    if pass_cert is not None:
        if not pass_cert.is_file():
            raise SignerError(500, "NOEMA_PASS_CERT does not point to a file.")
        normalize_certificate(pass_cert, cert_pem)
    else:
        run_openssl(
            "pkcs12",
            "-in",
            str(p12_path),
            "-clcerts",
            "-nokeys",
            "-passin",
            f"pass:{password}",
            "-out",
            str(cert_pem),
        )
    run_openssl(
        "pkcs12",
        "-in",
        str(p12_path),
        "-nocerts",
        "-nodes",
        "-passin",
        f"pass:{password}",
        "-out",
        str(key_pem),
    )
    key_pem.chmod(0o600)
    validate_key_matches_certificate(key_pem, cert_pem)


def validate_key_matches_certificate(key_pem: Path, cert_pem: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="noema-wallet-keycheck-") as workspace:
        root = Path(workspace)
        key_public = root / "key.pub"
        cert_public = root / "cert.pub"
        run_openssl("rsa", "-in", str(key_pem), "-pubout", "-out", str(key_public))
        run_openssl("x509", "-in", str(cert_pem), "-pubkey", "-noout", "-out", str(cert_public))
        if key_public.read_bytes() != cert_public.read_bytes():
            raise SignerError(500, "The .p12 private key does not match the pass certificate.")


def normalize_certificate(source: Path, destination_pem: Path) -> None:
    result = subprocess.run(
        ["openssl", "x509", "-in", str(source), "-inform", "PEM", "-out", str(destination_pem), "-outform", "PEM"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode == 0:
        return
    run_openssl(
        "x509",
        "-in",
        str(source),
        "-inform",
        "DER",
        "-out",
        str(destination_pem),
        "-outform",
        "PEM",
    )


def sign_manifest(manifest: Path, signature: Path, cert_pem: Path, key_pem: Path, wwdr_cert: Path) -> None:
    run_openssl(
        "smime",
        "-binary",
        "-sign",
        "-certfile",
        str(wwdr_cert),
        "-signer",
        str(cert_pem),
        "-inkey",
        str(key_pem),
        "-in",
        str(manifest),
        "-out",
        str(signature),
        "-outform",
        "DER",
    )


def run_openssl(*args: str) -> None:
    result = subprocess.run(
        ["openssl", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise SignerError(500, f"OpenSSL failed: {detail}")


def create_manifest(pass_dir: Path) -> dict[str, str]:
    manifest: dict[str, str] = {}
    for path in sorted(pass_dir.iterdir()):
        if path.name in {"manifest.json", "signature"} or not path.is_file():
            continue
        manifest[path.name] = hashlib.sha1(path.read_bytes()).hexdigest()
    return manifest


def zip_pass(pass_dir: Path, output: Path) -> None:
    with ZipFile(output, "w", ZIP_DEFLATED) as archive:
        for path in sorted(pass_dir.iterdir()):
            if path.is_file():
                archive.write(path, path.name)


def install_assets(pass_dir: Path) -> None:
    if ASSETS_DIR:
        source = Path(ASSETS_DIR)
        if not source.is_dir():
            raise SignerError(500, "NOEMA_PASS_ASSETS_DIR does not point to a directory.")
        for path in source.iterdir():
            if path.is_file() and path.suffix.lower() == ".png" and not is_reserved_generated_asset(path.name):
                shutil.copy2(path, pass_dir / path.name)

    write_png(pass_dir / "icon.png", 29, 29)
    write_png(pass_dir / "icon@2x.png", 58, 58)
    write_png(pass_dir / "icon@3x.png", 87, 87)


def is_reserved_generated_asset(name: str) -> bool:
    normalized = name.lower()
    return normalized in LOGO_ASSET_NAMES or normalized in GENERATED_ICON_ASSET_NAMES


def is_logo_asset(name: str) -> bool:
    return name.lower() in LOGO_ASSET_NAMES


def write_png(path: Path, width: int, height: int) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    rows = []
    for y in range(height):
        row = bytearray([0])
        for _ in range(width):
            row.extend((0, 0, 0, 0))
        rows.append(bytes(row))
    raw = b"".join(rows)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(png)


def main() -> None:
    validate_app_attest_environment()
    server = ThreadingHTTPServer((HOST, PORT), NoemaWalletSigner)
    print(f"Noema Wallet signer listening on http://{HOST}:{PORT}")
    print(f"Pass Type ID: {PASS_TYPE_IDENTIFIER}")
    print(f"Team ID: {TEAM_IDENTIFIER}")
    print(f"App Attest required: {REQUIRE_APP_ATTEST}")
    server.serve_forever()


def validate_app_attest_environment() -> None:
    if REQUIRE_APP_ATTEST and not APP_ATTEST_ROOT_CERT:
        raise SignerError(500, "NOEMA_APP_ATTEST_ROOT_CERT is not configured.")


if __name__ == "__main__":
    main()
