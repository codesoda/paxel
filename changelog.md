# Changelog

This repository tracks extracted Rails app snapshots from
`ghcr.io/yc-software/paxel-client`.

## 0.3.41.0

Image:

- Digest: `sha256:552c9b434600a16736005a64cba427e12d91548bd95ef6eabc139847dc9bce7f`
- Source revision: `2d130e1522c8de1c7159f2a7e9989f40f89fd397`

Changes from `0.3.40.2`:

- Bumped the packaged client version to `0.3.41.0`; the extracted Rails filesystem otherwise matches the previous snapshot.

## 0.3.40.2

Image:

- Digest: `sha256:2d5afc62ad9ab903138694320137e7c397166bac3c46e19d24d1de1f8a34035c`
- Source revision: `5b8e13899b9aced8c021c4ebf5e01a659fce2757`

Changes from `0.3.40.1`:

- Uses the sidecar-provided working directory for transcript projects without a git remote, preserving the real local path for cwd-named buckets.

## 0.3.40.1

Image:

- Digest: `sha256:39a7af270a303e656e2a429b6f462bf872a9868b6de6e5646004abe8ba9ad0e4`
- Source revision: `538632349c39d12354c6b491d9fb64cf93a99dd4`

Changes from `0.3.40.0`:

- Bumped the packaged client version to `0.3.40.1`; the extracted Rails filesystem otherwise matches the previous snapshot.

## 0.3.40.0

Image:

- Digest: `sha256:2ec573b4f6710f093346a8849497521a2ad81bd6d4d7b047f6df48bc1d09e621`
- Source revision: `78ba4fd2011eb5b157588c1bcb5ce447cff06410`

Changes from `0.3.39.5`:

- Bumped the packaged client version to `0.3.40.0`; the extracted Rails filesystem otherwise matches the previous snapshot.

## 0.3.39.5

Image:

- Digest: `sha256:95fa6a8d4a62cd37514b682b3bd0eed4ca631e98af519bf8c26c2774e09698c8`
- Source revision: `3a9ffe174d1b2ab87b8aa8cd0b035ba5eb0474ff`

Changes from `0.3.39.4`:

- Bumped the packaged client version to `0.3.39.5`; the extracted Rails filesystem otherwise matches the previous snapshot.

## 0.3.39.4

Image:

- Digest: `sha256:425a41fd3be66b397fff30d2e2741e02d725e884c3347cc4fa9b9bf2142756f2`
- Source revision: `b27ddb75a14be306379649299c601d622d5b9eca`

Changes from `0.3.39.3`:

- Bumped the packaged client version to `0.3.39.4`; the extracted Rails filesystem otherwise matches the previous snapshot.

## 0.3.39.3

Image:

- Digest: `sha256:7d33786d27241ffe96798d1c9f68365f33dcc63fd10fdf48e08fd11554c6dcc6`
- Source revision: `59444121d8e210c13fcb17fc8eb02c30bd1303d0`

Changes from `0.3.39.2`:

- Added disk-full detection during narrative processing, short-circuiting queued work and raising a clear out-of-disk-space error instead of cascading session failures.
- Retries blank narrative LLM responses once and avoids caching blank single-pass or multi-pass narrative results.
- Treats unreadable transcript sidecar files and session index files as skippable metadata failures instead of aborting discovery.

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
