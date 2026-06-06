# Reconstructed from:
#   ghcr.io/yc-software/paxel-client:sha-b0b6660d786c
#   digest: sha256:e02a65e5cb6d0170627edc49cd59f6df80b12f17456d34ef806bd3894ba7d0bb
#
# Docker images do not preserve the original Dockerfile verbatim. This file is
# reconstructed from `docker image inspect` and `docker history --no-trunc`.
# The final image history shows copied artifacts from earlier build stages, but
# not the original commands used inside those stages.

FROM ruby:3.4.8-slim AS runtime

WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl \
      git \
      libjemalloc2 \
      libsqlite3-0 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LD_PRELOAD=/usr/local/lib/libjemalloc.so \
    DATABASE_URL=sqlite3:///rails/tmp/client.sqlite3?timeout=5000 \
    SECRET_KEY_BASE=client-only-no-credentials-needed \
    TRANSCRIPT_DIR=/transcripts \
    CLIENT_MODE=1

ARG CLIENT_SENTRY_DSN=https://68a510bcb38fa29dd7148f1cf0849aaf@o4506690008121344.ingest.us.sentry.io/4511260138733568
ENV CLIENT_SENTRY_DSN=${CLIENT_SENTRY_DSN}

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p /rails/tmp /rails/data /rails/cache /transcripts && \
    chown -R rails:rails /rails/tmp /rails/data /rails/cache

# These two COPY layers came from an earlier build stage. The final image does
# not contain enough history to reconstruct the original bundler/assets build.
COPY --from=build --chown=rails:rails /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=rails:rails /rails /rails

USER 1000:1000
VOLUME ["/transcripts"]
ENTRYPOINT ["bin/client-entrypoint"]
