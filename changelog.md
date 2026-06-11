# Changelog

This repository tracks extracted Rails app snapshots from
`ghcr.io/yc-software/paxel-client`.

## 0.3.39.2

Image:

- Digest: `sha256:cedd66c5b16c38fcfce26386d905c1cc2da9cddd0c1a8384336d14f8d5475c2b`
- Source revision: `ee65db59a834cb0b55048bd17855b4472b22c722`

Changes from `0.3.39.1`:

- Bumped the packaged client version to `0.3.39.2`; the extracted Rails filesystem otherwise matches the previous snapshot.

## 0.3.39.1

Image:

- Digest: `sha256:5c5759b6763cca306cba30383d637c89a7c80926f5bde568a43c637f4be40f99`
- Source revision: `a294a3a69589301774b04cb9e923344d8fc8652a`

Changes from `0.3.38.3`:

- Added the local client upload slug to packaged telemetry as `client_slug`, making user-reported client upload IDs easier to correlate with server-side uploads.
- Updated the generated client schema to version `2026_06_07_060000`, adding `raw_payload_blob_key` on uploads for raw payload blob tracking.

## 0.3.38.3

Image:

- Digest: `sha256:2bb9abc2c50fe5bd63854529a20d979b518647ca117a5d4b96e7c2c9e017b943`
- Source revision: `c3e5b68d66a1bdd87944049a77c5ba88a4aab782`

Changes from `0.3.38.0`:

- Added Paxel/YC API token redaction in `SecretScrubber` for `yk_` tokens that match the production token shape.
- Redacts matching tokens to `[REDACTED_YC_TOKEN]` before transcript-derived text can reach LLM prompts or uploaded payloads.

## 0.3.38.0

Image:

- Digest: `sha256:8dfd0a87f1405cf6c71dffd3827904dcc33ea79adda4a6d2e68a0af3e7925205`
- Source revision: `73e3d40b89212a5c1d3e4a2bfa7b1bc1b61c6e40`

Changes from `0.3.35.10`:

- Increased the client SQLite busy timeout from 5 seconds to 30 seconds to reduce write contention failures during concurrent narrative and LLM-call writes.
- Added tolerant git sidecar reads in `ClientPipeline`, so missing or unreadable git metric files are skipped instead of aborting the upload.
- Switched Codex, Gemini, opencode, and format detection transcript reads to explicit UTF-8 handling so invalid bytes can be scrubbed reliably in the Docker image.
- Added rescue paths around unreadable or oddly encoded transcript files so one bad file does not sink the whole upload.
- Hardened `TranscriptChunker` null-byte cleanup by scrubbing invalid UTF-8 before deleting NUL bytes.
