# paxel-client image inspection

Image inspected without running a container:

- Image: `ghcr.io/yc-software/paxel-client:sha-b0b6660d786c`
- Digest: `sha256:e02a65e5cb6d0170627edc49cd59f6df80b12f17456d34ef806bd3894ba7d0bb`
- Source label: `https://github.com/yc-software/paxel`
- Source revision label: `b0b6660d786cdd42de5b6a810abf82fba07e4eef`
- Created: `2026-06-06T03:02:17.668564613Z`
- OS/arch: `linux/arm64`
- Base OS in exported rootfs: Debian GNU/Linux 13 `trixie`
- App version file: `0.3.35.10`
- Working dir: `/rails`
- User: `1000:1000`
- Entrypoint: `bin/client-entrypoint`
- Volume: `/transcripts`

Local artifacts:

- `Dockerfile`: best-effort reconstruction from `docker history --no-trunc`
- `rootfs.tar`: flattened filesystem exported from a stopped `docker create` container
- `rootfs/`: extracted filesystem for static inspection

Important caveat:

Docker images do not preserve the original Dockerfile. The history shows the final
runtime stage and two copied artifacts:

- `COPY --chown=rails:rails /usr/local/bundle /usr/local/bundle`
- `COPY --chown=rails:rails /rails /rails`

The earlier build stage that produced those directories is not recoverable from
the final image alone. The app comments refer to `Dockerfile.client`, but the
labeled GitHub repo returned `404` via `gh api` with the current credentials.

Runtime behavior observed statically:

- `bin/client-entrypoint` initializes a local SQLite schema with Rails, then runs
  `bin/rails client:analyze`.
- `config/database.yml` is client-specific and points production database roles
  at the local SQLite `DATABASE_URL`.
- `config/environments/production.rb` is a stripped client production config:
  no HTTP server-specific config, no mailer, no cloud storage, inline jobs,
  null cache, local Active Storage.
- `lib/tasks/analyze_local.rake` reads transcripts from `TRANSCRIPT_DIR`, defaulting
  to `/transcripts`, and can merge mounted sessions from Cursor, Codex, opencode,
  and Gemini session directories.
- `ClientPipeline` expects runtime env such as `YC_TOKEN`, `YC_API_KEY`,
  `YC_LLM_PROXY_URL`, and `YC_RESULTS_ENDPOINT` when doing proxy validation,
  LLM calls, and result upload.

Credential-oriented scan notes:

- No literal Anthropic/OpenAI/YC/AWS private token values were found in the Rails
  app source scan; matches were regexes, examples, or runtime env references.
- The image config bakes a `CLIENT_SENTRY_DSN`, also present in the reconstructed
  Dockerfile. Sentry DSNs are usually not secret, but this does identify the
  destination project.
- The app includes explicit scrubbers for common secrets before Sentry/reporting:
  YC tokens, Anthropic/OpenAI keys, GitHub tokens, JWTs, DB URLs, home paths,
  git remotes, emails, and several env-var secret patterns.
