# Noema Wallet Signer

Minimal reference signer for Noema's boarding-pass Wallet flow.

The iOS app scans and edits passes locally. The final Wallet step sends the confirmed draft JSON to this signer:

```http
GET /v1/wallet/app-attest/challenge?purpose=register
POST /v1/wallet/app-attest/register
GET /v1/wallet/app-attest/challenge?purpose=assert
POST /v1/wallet/passes/sign
Accept: application/vnd.apple.pkpass
Content-Type: application/json
```

The app registers an App Attest key, binds each signing request to a one-time server challenge plus the exact JSON body, and the signer returns signed `.pkpass` bytes only after that assertion verifies.

For production, Noema calls the hosted HTTPS endpoint directly. Nginx injects the internal bearer token when proxying to the private signer container, so iOS users do not configure or see signer tokens. App Attest is what keeps that public endpoint limited to signed Noema iOS builds.

## Required Apple files

- Pass Type ID: `pass.com.noemaai.noema.transport`
- Team ID: `XX3Z6V9TU9`
- Pass Type ID certificate plus private key exported as `.p12`
- If the `.p12` contains only the private key, set `NOEMA_PASS_CERT` to the downloaded pass `.cer`
- Apple WWDR intermediate certificate as PEM or CER
- Apple App Attestation Root CA PEM when `NOEMA_REQUIRE_APP_ATTEST=true`

The `.cer` alone cannot sign passes. It must be paired with the private key created when the CSR was generated.

## Run locally

```sh
export NOEMA_WALLET_SIGNER_TOKEN="choose-a-long-random-token"
export NOEMA_PASS_P12="/Users/arminstamate/Documents/Armin Noema Wallet Pass.p12"
export NOEMA_PASS_CERT="/Users/arminstamate/Downloads/pass.cer"
export NOEMA_PASS_P12_PASSWORD="p12-password"
export NOEMA_WWDR_CERT="/Users/arminstamate/Documents/AppleWWDRCAG4.cer"
export NOEMA_APP_ATTEST_ROOT_CERT="/secure/path/Apple_App_Attestation_Root_CA.pem"
export NOEMA_APP_ATTEST_APP_ID="XX3Z6V9TU9.arminproducts.Noema"
export NOEMA_WALLET_SIGNER_HOST="127.0.0.1"
export NOEMA_WALLET_SIGNER_PORT="8787"

python3 -m pip install cbor2 cryptography
python3 scripts/wallet-signer/sign_pass.py
```

Then set Noema Settings -> Wallet Passes:

```text
Signer URL: http://<server-host>:8787
```

For normal production use, the app defaults to `https://search.noemaai.com` and no user setup is required. A local URL is only useful for developer override testing.

For local simulator-only signer testing, you can set `NOEMA_REQUIRE_APP_ATTEST=false`. Do not use that in production; simulators cannot provide real App Attest assertions.

App Attest failures return stable `app_attest_*` text codes and log only non-secret diagnostics such as request IDs, attempt numbers, key hash prefixes, counters, verifier branch results, key-binding metadata, and body-hash prefixes. The iOS client clears its stored App Attest key and retries once with a fresh request ID when a hosted signer verification code is returned.

## Assets

By default the signer creates transparent fallback icon PNG assets only. The app supplies plain pass header text through `logoText` instead of a fallback logo image. Logo PNGs are ignored so Wallet does not render a top-left logo block. For production, provide your own Wallet PNGs:

```sh
export NOEMA_PASS_ASSETS_DIR="/secure/path/pass-assets"
```

Every non-logo, non-icon `.png` in that folder is copied into the pass package. The signer writes transparent required icon files itself.

## Security notes

- Keep the `.p12`, password, and bearer token out of git.
- Keep the bearer token between the reverse proxy and signer; do not require regular iOS users to enter it.
- Keep `NOEMA_REQUIRE_APP_ATTEST=true` on the public signer.
- Rotate the token if it is exposed.
- Do not put the `.p12` or private key in the iOS app bundle.
- Deploy the signer over HTTPS outside local development.
