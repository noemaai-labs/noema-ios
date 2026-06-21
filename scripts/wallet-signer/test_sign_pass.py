#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import io
import json
import tempfile
import unittest
import zlib
from zipfile import ZipFile

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

import sign_pass


class AppAttestVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.private_key = ec.generate_private_key(ec.SECP256R1())
        self.public_key = self.private_key.public_key()
        self.authenticator_data = hashlib.sha256(b"authenticator").digest() + b"\x01" + (1).to_bytes(4, "big")
        self.client_data_hash = hashlib.sha256(b"client-data").digest()
        self.nonce = hashlib.sha256(self.authenticator_data + self.client_data_hash).digest()

    def test_nonce_message_signature_is_primary_success_path(self) -> None:
        signature = self.private_key.sign(self.nonce, ec.ECDSA(hashes.SHA256()))

        result = sign_pass.verify_assertion_signature_for_client_data_hash(
            self.public_key,
            signature,
            self.authenticator_data,
            self.client_data_hash,
        )

        self.assertTrue(result.passed)
        self.assertEqual(result.nonce_message_result.label, "nonce_message_der_pass")

    def test_direct_concat_signature_is_diagnostic_only(self) -> None:
        signature = self.private_key.sign(
            self.authenticator_data + self.client_data_hash,
            ec.ECDSA(hashes.SHA256()),
        )

        result = sign_pass.verify_assertion_signature_for_client_data_hash(
            self.public_key,
            signature,
            self.authenticator_data,
            self.client_data_hash,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.direct_result.label, "direct_der_pass")

    def test_prehashed_nonce_signature_is_diagnostic_only(self) -> None:
        signature = self.private_key.sign(
            self.nonce,
            ec.ECDSA(utils.Prehashed(hashes.SHA256())),
        )

        result = sign_pass.verify_assertion_signature_for_client_data_hash(
            self.public_key,
            signature,
            self.authenticator_data,
            self.client_data_hash,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.prehashed_result.label, "prehashed_der_pass")

    def test_claimed_client_data_hash_mismatch_is_stable_error(self) -> None:
        with self.assertRaises(sign_pass.SignerError) as error:
            sign_pass.validate_claimed_client_data_hash(
                sign_pass.base64url_encode(hashlib.sha256(b"wrong").digest()),
                self.client_data_hash,
                request_id="test-request",
            )

        self.assertEqual(error.exception.message, "app_attest_client_data_hash_mismatch")

    def test_cose_key_validation_rejects_wrong_parameters(self) -> None:
        numbers = self.public_key.public_numbers()
        valid_cose = {
            1: 2,
            3: -7,
            -1: 1,
            -2: numbers.x.to_bytes(32, "big"),
            -3: numbers.y.to_bytes(32, "big"),
        }

        self.assertIsInstance(sign_pass.public_key_from_cose(valid_cose), ec.EllipticCurvePublicKey)

        invalid_alg = dict(valid_cose)
        invalid_alg[3] = -257
        with self.assertRaises(sign_pass.SignerError):
            sign_pass.public_key_from_cose(invalid_alg)

        invalid_coordinate = dict(valid_cose)
        invalid_coordinate[-2] = invalid_coordinate[-2][1:]
        with self.assertRaises(sign_pass.SignerError):
            sign_pass.public_key_from_cose(invalid_coordinate)

    def test_key_binding_requires_credential_id_and_public_key_hash(self) -> None:
        numbers = self.public_key.public_numbers()
        uncompressed = b"\x04" + numbers.x.to_bytes(32, "big") + numbers.y.to_bytes(32, "big")
        key_hash = hashlib.sha256(uncompressed).digest()
        key_id = sign_pass.base64url_encode(key_hash)

        self.assertEqual(
            sign_pass.verify_key_id(key_id, key_hash, self.public_key),
            "credential_id+public_key_hash",
        )

        with self.assertRaises(sign_pass.SignerError) as error:
            sign_pass.verify_key_id(key_id, hashlib.sha256(b"wrong-credential").digest(), self.public_key)

        self.assertEqual(error.exception.message, "app_attest_key_binding_mismatch")

    def test_app_attest_nonce_values_extracts_exact_octet_string(self) -> None:
        nonce = hashlib.sha256(b"nonce").digest()
        wrapped = b"\x30\x24\xa1\x22\x04\x20" + nonce

        self.assertEqual(sign_pass.app_attest_nonce_values(wrapped), [nonce])
        self.assertEqual(sign_pass.app_attest_nonce_values(nonce), [nonce])
        self.assertEqual(sign_pass.app_attest_nonce_values(b"prefix" + nonce + b"suffix"), [])

    def test_default_assets_do_not_generate_visible_logo_block(self) -> None:
        old_assets_dir = sign_pass.ASSETS_DIR
        sign_pass.ASSETS_DIR = ""
        self.addCleanup(lambda: setattr(sign_pass, "ASSETS_DIR", old_assets_dir))
        with tempfile.TemporaryDirectory() as directory:
            from pathlib import Path

            pass_dir = Path(directory)
            sign_pass.install_assets(pass_dir)

            self.assertTrue((pass_dir / "icon.png").is_file())
            self.assertTrue((pass_dir / "icon@2x.png").is_file())
            self.assertTrue((pass_dir / "icon@3x.png").is_file())
            self.assert_png_is_fully_transparent((pass_dir / "icon.png").read_bytes())
            self.assertFalse((pass_dir / "logo.png").exists())
            self.assertFalse((pass_dir / "logo@2x.png").exists())
            self.assertFalse((pass_dir / "logo@3x.png").exists())

    def test_custom_assets_ignore_logo_images_so_logo_text_displays(self) -> None:
        old_assets_dir = sign_pass.ASSETS_DIR
        with tempfile.TemporaryDirectory() as source_directory, tempfile.TemporaryDirectory() as pass_directory:
            from pathlib import Path

            source = Path(source_directory)
            pass_dir = Path(pass_directory)
            (source / "icon.png").write_bytes(b"icon")
            (source / "icon@2x.png").write_bytes(b"icon2x")
            (source / "icon@3x.png").write_bytes(b"icon3x")
            (source / "logo.png").write_bytes(b"logo")
            (source / "logo@2x.png").write_bytes(b"logo2x")
            (source / "logo@3x.png").write_bytes(b"logo3x")
            (source / "LOGO@3X.PNG").write_bytes(b"logo3x-uppercase")

            sign_pass.ASSETS_DIR = source_directory
            self.addCleanup(lambda: setattr(sign_pass, "ASSETS_DIR", old_assets_dir))
            sign_pass.install_assets(pass_dir)

            self.assertTrue((pass_dir / "icon.png").is_file())
            self.assert_png_is_fully_transparent((pass_dir / "icon.png").read_bytes())
            self.assert_png_is_fully_transparent((pass_dir / "icon@2x.png").read_bytes())
            self.assert_png_is_fully_transparent((pass_dir / "icon@3x.png").read_bytes())
            self.assertFalse((pass_dir / "logo.png").exists())
            self.assertFalse((pass_dir / "logo@2x.png").exists())
            self.assertFalse((pass_dir / "logo@3x.png").exists())
            self.assertFalse((pass_dir / "LOGO@3X.PNG").exists())

    def test_logo_asset_detection_is_case_insensitive(self) -> None:
        self.assertTrue(sign_pass.is_logo_asset("logo.png"))
        self.assertTrue(sign_pass.is_logo_asset("LOGO@2X.PNG"))
        self.assertTrue(sign_pass.is_logo_asset("Logo@3x.PnG"))
        self.assertFalse(sign_pass.is_logo_asset("icon.png"))
        self.assertTrue(sign_pass.is_reserved_generated_asset("ICON@3X.PNG"))
        self.assertFalse(sign_pass.is_reserved_generated_asset("strip.png"))

    def test_pkpass_package_omits_logo_assets_but_preserves_header_text(self) -> None:
        old_assets_dir = sign_pass.ASSETS_DIR
        old_pass_type_identifier = sign_pass.PASS_TYPE_IDENTIFIER
        old_team_identifier = sign_pass.TEAM_IDENTIFIER
        with tempfile.TemporaryDirectory() as source_directory:
            from pathlib import Path

            source = Path(source_directory)
            (source / "icon.png").write_bytes(b"icon")
            (source / "icon@2x.png").write_bytes(b"icon2x")
            (source / "icon@3x.png").write_bytes(b"icon3x")
            (source / "logo.png").write_bytes(b"logo")
            (source / "logo@2x.png").write_bytes(b"logo2x")
            (source / "logo@3x.png").write_bytes(b"logo3x")
            (source / "strip.png").write_bytes(b"strip")

            sign_pass.ASSETS_DIR = source_directory
            sign_pass.PASS_TYPE_IDENTIFIER = "pass.com.noemaai.noema.transport"
            sign_pass.TEAM_IDENTIFIER = "XX3Z6V9TU9"
            original_validate_environment = sign_pass.validate_environment
            original_extract_identity = sign_pass.extract_identity
            original_normalize_certificate = sign_pass.normalize_certificate
            original_sign_manifest = sign_pass.sign_manifest
            self.addCleanup(lambda: setattr(sign_pass, "ASSETS_DIR", old_assets_dir))
            self.addCleanup(lambda: setattr(sign_pass, "PASS_TYPE_IDENTIFIER", old_pass_type_identifier))
            self.addCleanup(lambda: setattr(sign_pass, "TEAM_IDENTIFIER", old_team_identifier))
            self.addCleanup(lambda: setattr(sign_pass, "validate_environment", original_validate_environment))
            self.addCleanup(lambda: setattr(sign_pass, "extract_identity", original_extract_identity))
            self.addCleanup(lambda: setattr(sign_pass, "normalize_certificate", original_normalize_certificate))
            self.addCleanup(lambda: setattr(sign_pass, "sign_manifest", original_sign_manifest))
            sign_pass.validate_environment = lambda: None
            sign_pass.extract_identity = lambda *args, **kwargs: None
            sign_pass.normalize_certificate = lambda *args, **kwargs: None
            sign_pass.sign_manifest = lambda _manifest, signature, *_args: signature.write_bytes(b"signature")

            pkpass = sign_pass.build_pkpass(
                {
                    "passJSON": {
                        "description": "Trip pass generated from captured boarding pass",
                        "formatVersion": 1,
                        "organizationName": "Noema Travel Tools",
                        "logoText": "Boarding Pass",
                        "passTypeIdentifier": "pass.com.noemaai.noema.transport",
                        "serialNumber": "test-serial",
                        "teamIdentifier": "XX3Z6V9TU9",
                        "foregroundColor": "rgb(0,0,0)",
                        "backgroundColor": "rgb(255,218,61)",
                        "labelColor": "rgb(65,65,65)",
                        "boardingPass": {
                            "transitType": "PKTransitTypeAir",
                            "primaryFields": [],
                            "secondaryFields": [],
                            "auxiliaryFields": [],
                            "backFields": [],
                        },
                        "barcodes": [],
                    }
                }
            )

        with ZipFile(io.BytesIO(pkpass)) as archive:
            names = set(archive.namelist())
            packaged_pass = json.loads(archive.read("pass.json").decode("utf-8"))
            manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
            archive_icon = archive.read("icon.png")

        self.assertIn("icon.png", names)
        self.assertIn("strip.png", names)
        self.assert_png_is_fully_transparent(archive_icon)
        self.assertNotIn("logo.png", names)
        self.assertNotIn("logo@2x.png", names)
        self.assertNotIn("logo@3x.png", names)
        self.assertNotIn("logo.png", manifest)
        self.assertNotIn("logo@2x.png", manifest)
        self.assertNotIn("logo@3x.png", manifest)
        self.assertEqual(packaged_pass["logoText"], "Boarding Pass")
        self.assertEqual(packaged_pass["organizationName"], "Noema Travel Tools")
        self.assertEqual(packaged_pass["description"], "Trip pass generated from captured boarding pass")

    def assert_png_is_fully_transparent(self, data: bytes) -> None:
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        offset = 8
        width = height = None
        idat = bytearray()
        while offset < len(data):
            length = int.from_bytes(data[offset : offset + 4], "big")
            kind = data[offset + 4 : offset + 8]
            chunk = data[offset + 8 : offset + 8 + length]
            offset += 12 + length
            if kind == b"IHDR":
                width = int.from_bytes(chunk[0:4], "big")
                height = int.from_bytes(chunk[4:8], "big")
            elif kind == b"IDAT":
                idat.extend(chunk)
            elif kind == b"IEND":
                break
        self.assertIsNotNone(width)
        self.assertIsNotNone(height)
        raw = zlib.decompress(bytes(idat))
        row_length = 1 + int(width) * 4
        self.assertEqual(len(raw), row_length * int(height))
        for y in range(int(height)):
            row = raw[y * row_length : (y + 1) * row_length]
            self.assertEqual(row[0], 0)
            alphas = row[4::4]
            self.assertTrue(all(alpha == 0 for alpha in alphas))


if __name__ == "__main__":
    unittest.main()
