require "active_support/core_ext/integer/time"

# Client Docker image environment. The public paxel-client image runs a local
# CLI analysis pipeline (`bin/rails client:analyze`) — no HTTP server, no mailer,
# no cloud storage, no Solid* databases. This file is forked from
# config/environments/production.rb and COPYed OVER it in Dockerfile.client, so
# RAILS_ENV stays "production" (Bundler groups, every `*.yml` production: key, and
# `Rails.env.production?` all behave exactly as on the server). It deliberately
# OMITS the server's HTTP / mailer / host-allowlist / SSL / Cloudflare config so
# none of that infrastructure detail ships in the public image.
#
# Keep in sync with production.rb ONLY for settings the client pipeline actually
# reads. The Dockerfile build-time boot check eager-loads all client code, so a
# missing setting fails the build rather than shipping a broken image.
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true

  # Log to STDOUT (captured by the upload script and ~/.paxel/logs).
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.active_support.report_deprecations = false

  # CLI pipeline: no cache, no background jobs, local-only Active Storage.
  # client_schema.rb ships NO Solid Cache/Queue/Cable tables, so those backends
  # must NOT be wired here — null/inline/local keep the client self-contained.
  config.cache_store = :null_store
  config.active_job.queue_adapter = :inline
  config.active_storage.service = :local

  config.active_record.dump_schema_after_migration = false
  config.i18n.fallbacks = true
end
