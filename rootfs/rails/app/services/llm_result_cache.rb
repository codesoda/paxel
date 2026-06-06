# Persistent LLM result cache backed by a separate SQLite file.
#
# Keyed by SHA256(model + prompt + input), scope-independent — works across
# projects, --all, --since, and directory changes. Survives Docker container
# restarts via a dedicated Docker named volume mounted at /rails/cache. The
# volume (not a host bind mount) is deliberate: the container runs non-root
# (uid 1000) and a host-owned 0700 bind mount is unwritable when the host uid
# != 1000 (native Linux / CI / cloud), which silently disabled the cache and
# caused repeated full re-spend. A fresh named volume inherits the image dir's
# uid-1000 ownership (Dockerfile.client chowns /rails/cache), so the container
# can always write it. See upload_script.text.erb + warn_if_unavailable!.
#
# Design:
#   - Raw SQLite3 connection (not ActiveRecord) so it's independent of the
#     main pipeline DB and its force: :cascade schema load.
#   - WAL mode + busy_timeout for concurrent read safety with 20 narrative threads.
#   - Mutex serializes writes (fast, ~1ms per write).
#   - All errors swallowed — cache is best-effort. Corruption or permission
#     errors degrade to cache misses, never crash the pipeline.
#   - Never caches nil/empty results to prevent permanent failures on resume.
#
# Usage:
#   LlmResultCache.setup!
#   cached = LlmResultCache.fetch(service_name: "Foo", input_text: text, prompt_text: prompt, model: model)
#   LlmResultCache.store(service_name: "Foo", input_text: text, prompt_text: prompt, model: model, result: data)
#
module LlmResultCache
  # Dedicated cache volume (see header). The path lives in its OWN directory,
  # separate from /rails/data (the pending-upload stash), so the cache can move
  # to a uid-robust named volume without relocating the sensitive stash payload.
  CACHE_DB_PATH = ENV.fetch("PAXEL_CACHE_DB", "/rails/cache/llm_cache.sqlite3")

  # Only these SQLite error classes indicate on-disk corruption worth
  # quarantining. Transient BusyException / IOException / FullException
  # should fail open (disable cache for this run) without renaming a
  # healthy file aside.
  CORRUPTION_ERRORS = [ SQLite3::NotADatabaseException, SQLite3::CorruptException ].freeze

  class << self
    def setup!
      # Idempotent: if a prior handle exists (e.g. test re-setup or programmatic
      # reopen), close it cleanly before opening a new one. Otherwise the old
      # SQLite3::Database leaks until GC runs.
      close_db_cleanly! if @db
      @unavailable_reason = nil
      open_db_with_recovery!
      @mutex = Mutex.new
      @hits = Concurrent::AtomicFixnum.new(0)
      @misses = Concurrent::AtomicFixnum.new(0)
      @hits_by_service = Concurrent::Map.new
      @misses_by_service = Concurrent::Map.new
    rescue => e
      Rails.logger.warn("[LlmResultCache] Setup failed: #{e.class}: #{e.message}") if defined?(Rails)
      @db = nil
      @unavailable_reason = classify_unavailable_reason
    end

    # Opens the cache DB. If the file is corrupt (e.g. SIGINT during WAL
    # checkpoint zeroed the header, producing "file is not a database"), move
    # the broken files aside and create a fresh one. Losing the cache is
    # acceptable; losing the ability to ever cache again would silently
    # regress every upload's runtime.
    #
    # Transient SQLite errors (busy, IO, full) do NOT quarantine — those can
    # happen on a healthy DB and renaming would destroy real data.
    def open_db_with_recovery!
      open_db!
    rescue *CORRUPTION_ERRORS => e
      Rails.logger.warn("[LlmResultCache] Cache file corrupt (#{e.class}: #{e.message}) — moving aside and rebuilding") if defined?(Rails)
      quarantine_corrupt_files!
      open_db!
    end

    def open_db!
      @db = SQLite3::Database.new(CACHE_DB_PATH)
      @db.execute("PRAGMA journal_mode=WAL")
      @db.execute("PRAGMA busy_timeout=5000")
      # synchronous=FULL fsyncs the main DB after each checkpoint, narrowing
      # the window where SIGINT/SIGTERM can leave a half-written header.
      # Cost: slightly slower writes. Negligible for a cache where writes
      # are gated on multi-second LLM calls.
      @db.execute("PRAGMA synchronous=FULL")
      # Checkpoint WAL more aggressively — default 1000 pages is ~4MB of
      # pending state. 100 pages ~= 400KB keeps the corruption window small
      # across the many kill/restart cycles a dev loop produces.
      @db.execute("PRAGMA wal_autocheckpoint=100")
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS cache_entries (
          input_hash TEXT NOT NULL,
          service_name TEXT NOT NULL,
          result_json TEXT NOT NULL,
          input_tokens INTEGER,
          output_tokens INTEGER,
          model TEXT,
          created_at TEXT NOT NULL,
          last_used_at TEXT NOT NULL,
          PRIMARY KEY (input_hash, service_name)
        )
      SQL
      install_shutdown_hook!
    end

    # Ruby's at_exit fires on normal exit, Kernel#exit, and when an unhandled
    # Interrupt (Ctrl+C) or SignalException (SIGTERM / docker stop) propagates
    # up. Only SIGKILL / OOM bypass it. Flushing the WAL here ensures the
    # next container start reads a clean, checkpointed main file.
    def install_shutdown_hook!
      return if @shutdown_hook_installed
      @shutdown_hook_installed = true
      at_exit { close_db_cleanly! }
    end

    def close_db_cleanly!
      return unless @db
      @db.execute("PRAGMA wal_checkpoint(TRUNCATE)") rescue nil
      @db.close rescue nil
      @db = nil
    end

    def quarantine_corrupt_files!
      ts = Time.now.strftime("%Y%m%d%H%M%S")
      [ CACHE_DB_PATH, "#{CACHE_DB_PATH}-wal", "#{CACHE_DB_PATH}-shm" ].each do |path|
        next unless File.exist?(path)
        File.rename(path, "#{path}.corrupt.#{ts}")
      rescue StandardError
        # Best-effort: if rename fails (permissions, read-only FS), continue
        # and let open_db! raise a clean error on the retry. Never crash setup.
      end
    end

    def available?
      @db.present?
    end

    # Low-cardinality, PII-free reason the cache is unavailable (or nil when
    # available). Never the raw exception message — that can contain home-dir
    # paths/uids. One of: :dir_unwritable, :unknown.
    def unavailable_reason
      @unavailable_reason
    end

    # Surface a non-functional cache LOUDLY. The cache is best-effort and never
    # crashes the run, but a silently-disabled cache means every run re-pays for
    # identical work, and a large history can burn the daily cost cap before
    # finishing — producing zero output. That failure mode was invisible (one
    # buried Rails.logger.warn) and took forensics to find on a real user.
    #
    # Emits a prominent user-facing warning AND exactly one fingerprinted,
    # PII-free Sentry *warning* per process. For the client, Sentry is the only
    # telemetry channel back to YC (its stdout/logs stay on the user's machine),
    # so this is how we ever learn the fleet is hitting it. Fingerprinted +
    # once-per-run + warning-level keeps it a single grouped signal, not the
    # per-occurrence error noise the team has repeatedly had to suppress.
    def warn_if_unavailable!(logger: nil)
      return if available?

      reason = unavailable_reason || :unknown
      if logger
        logger.call("")
        logger.call("⚠ Result cache unavailable — this run can't reuse results from previous runs.")
        logger.call("  Re-runs and large histories will be slower, cost more, and may hit your")
        logger.call("  daily limit before finishing.")
        logger.call("  The cache directory isn't writable inside the container.") if reason == :dir_unwritable
        logger.call("")
      end
      report_unavailable_to_sentry(reason)
      nil
    end

    # Run a block with cache reads bypassed (writes still happen for inspection).
    # Used by eval runner to ensure fresh LLM calls.
    def with_bypass(&block)
      prev = Thread.current[:llm_cache_bypass]
      Thread.current[:llm_cache_bypass] = true
      block.call
    ensure
      Thread.current[:llm_cache_bypass] = prev
    end

    def bypass?
      Thread.current[:llm_cache_bypass] == true
    end

    def fetch(service_name:, input_text:, prompt_text:, model:, prompt_version: nil)
      if bypass?
        record_miss(service_name)
        return nil
      end

      unless @db
        record_miss(service_name)
        return nil
      end

      hash = compute_hash(input_text, prompt_text, model, prompt_version)
      row = @mutex.synchronize do
        @db.get_first_row(
          "SELECT result_json FROM cache_entries WHERE input_hash = ? AND service_name = ?",
          [ hash, service_name ]
        )
      end

      if row
        # Update last_used_at for LRU cleanup (best-effort, don't block on failure)
        @mutex.synchronize do
          @db.execute(
            "UPDATE cache_entries SET last_used_at = ? WHERE input_hash = ? AND service_name = ?",
            [ Time.now.iso8601, hash, service_name ]
          )
        end rescue nil
        record_hit(service_name)
        JSON.parse(row[0])
      else
        record_miss(service_name)
        nil
      end
    rescue => e
      record_miss(service_name)
      nil # cache read failure = cache miss, never crash
    end

    def store(service_name:, input_text:, prompt_text:, model:, result:, prompt_version: nil, input_tokens: nil, output_tokens: nil)
      return unless @db
      return if result.nil? || (result.respond_to?(:empty?) && result.empty?)

      # Strip proxy nonce comments from cached results — nonces are one-time
      # signatures that must come from fresh LLM calls, not from cache.
      clean_result = strip_nonces(result)

      hash = compute_hash(input_text, prompt_text, model, prompt_version)
      now = Time.now.iso8601
      @mutex.synchronize do
        @db.execute(<<~SQL, [ hash, service_name, clean_result.to_json, input_tokens, output_tokens, model, now, now ])
          INSERT OR REPLACE INTO cache_entries
            (input_hash, service_name, result_json, input_tokens, output_tokens, model, created_at, last_used_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end
    rescue => e
      nil # cache write failure = no cache, never crash
    end

    def cleanup!(max_age_days: 30)
      return unless @db
      cutoff = (Time.now - max_age_days * 86400).iso8601
      @mutex.synchronize do
        @db.execute("DELETE FROM cache_entries WHERE last_used_at < ?", [ cutoff ])
      end
    rescue => e
      nil
    end

    # --- Stats ---

    def hits
      @hits&.value || 0
    end

    def misses
      @misses&.value || 0
    end

    def hits_for(service_name)
      @hits_by_service&.fetch(service_name, nil)&.value || 0
    end

    def misses_for(service_name)
      @misses_by_service&.fetch(service_name, nil)&.value || 0
    end

    def reset_stats!
      @hits = Concurrent::AtomicFixnum.new(0)
      @misses = Concurrent::AtomicFixnum.new(0)
      @hits_by_service = Concurrent::Map.new
      @misses_by_service = Concurrent::Map.new
    end

    def stats_summary
      total = hits + misses
      return "no cache activity" if total == 0
      pct = total > 0 ? (hits * 100.0 / total).round(0) : 0
      "#{hits}/#{total} cache hits (#{pct}%)"
    end

    private

    # Map a setup failure to a low-cardinality, PII-free reason code. We classify
    # by probing the cache directory rather than parsing the exception message
    # (which can contain home-dir paths / uids). The dominant real-world cause is
    # an unwritable cache dir (non-root container vs. host-owned bind mount).
    def classify_unavailable_reason
      dir = File.dirname(CACHE_DB_PATH)
      return :dir_unwritable unless File.directory?(dir) && File.writable?(dir)

      :unknown
    rescue StandardError
      :unknown
    end

    # One fingerprinted, warning-level Sentry message per process. PII-free:
    # only the reason code travels, never the path/message. Guarded so telemetry
    # can never break the pipeline, and skipped entirely when Sentry isn't wired.
    def report_unavailable_to_sentry(reason)
      return unless defined?(Sentry) && Sentry.initialized?
      return if @unavailable_reported

      @unavailable_reported = true
      Sentry.with_scope do |scope|
        scope.set_fingerprint([ "client_cache_unavailable" ])
        scope.set_tags(cache_reason: reason.to_s)
        Sentry.capture_message("Client LLM result cache unavailable (#{reason})", level: :warning)
      end
    rescue StandardError
      nil
    end

    NONCE_PATTERN = /<!-- yc_verify:[^>]+ -->\n?/.freeze

    def compute_hash(input_text, prompt_text, model, prompt_version = nil)
      # prompt_version guards against stale cache hits when a service bumps
      # PROMPT_VERSION for a scoring/logic change the prompt text alone doesn't
      # capture. Legacy callers pass nil and the hash degrades to the prior
      # shape so pre-versioned entries stay readable until the caller opts in.
      version_segment = prompt_version ? "\n---VERSION---\n#{prompt_version}" : ""
      Digest::SHA256.hexdigest("#{model}\n---PROMPT---\n#{prompt_text}#{version_segment}\n---INPUT---\n#{input_text}")
    end

    # Recursively strip proxy nonce comments from any string values in the result.
    # Nonces are one-time HMAC signatures — caching them causes stale nonces to be
    # resubmitted on subsequent runs, triggering tampering false positives.
    def strip_nonces(obj)
      case obj
      when String
        obj.gsub(NONCE_PATTERN, "")
      when Hash
        obj.transform_values { |v| strip_nonces(v) }
      when Array
        obj.map { |v| strip_nonces(v) }
      else
        obj
      end
    end

    def record_hit(service_name)
      @hits&.increment
      counter = @hits_by_service&.compute_if_absent(service_name) { Concurrent::AtomicFixnum.new(0) }
      counter&.increment
    end

    def record_miss(service_name)
      @misses&.increment
      counter = @misses_by_service&.compute_if_absent(service_name) { Concurrent::AtomicFixnum.new(0) }
      counter&.increment
    end
  end
end
