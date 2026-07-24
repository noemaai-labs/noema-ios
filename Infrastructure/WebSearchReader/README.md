# Noema Web Search Reader

This service turns SearXNG candidates into bounded, addressable evidence for
`noema.web.retrieve`. It reads normal HTML, plain text, and PDFs with a text
layer. It intentionally does not run JavaScript, perform OCR, bypass paywalls,
or attempt to defeat anti-bot controls.

The Swift client performs SearXNG discovery and submits at most eight public
candidate URLs. Keeping discovery client-side means this container does not join
the shared SearXNG/service network.

## Local test

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
READER_REF_SIGNING_KEY=development-only-key-at-least-32-bytes pytest
```

## Deployment

Copy this directory into `/opt/noema-search/web-reader`, generate a random
`READER_REF_SIGNING_KEY` in the server-side environment, merge
`docker-compose.reader.yml` into the existing Compose project, and adapt the
Nginx template to the existing API-key variable/check. Validate with
`docker compose config`, `nginx -t`, and the internal health endpoint before
reloading Nginx. Never commit the generated key.
