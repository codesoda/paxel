# Replays stashed uploads on the next `bin/upload` invocation.
#
# Invoked from `lib/tasks/pending_uploads.rake` inside a minimal Docker
# container that the bash wrapper spawns when `PendingUploadStash.list`
# returns non-empty. The task does not re-enter the fresh-pipeline path;
# a successful replay exits with the materialized upload and the user
# re-runs `bin/upload` for a fresh analysis.
#
# Replay gates (in order, each one short-circuits on failure):
#   1. Endpoint mismatch — stashed URL vs current YC_RESULTS_ENDPOINT.
#      Guards against a localhost stash accidentally replaying to prod.
#   2. Pipeline version mismatch — stashed PIPELINE_VERSION vs current.
#      Guards against a schema change between stash and replay.
#   3. Excessive retries — attempt_count >= MAX_REPLAY_ATTEMPTS. Stops a
#      stuck stash (server-side issue that never resolves or a payload
#      Rails never surfaces via 4xx) from blocking the replay queue on
#      every future bin/upload.
#
# Server-side idempotency is scoped by user_id (for user-associated
# tokens) or api_token_id (for standalone admin tokens). Token rotation
# mid-stash is therefore safe — a replay under a rotated token hits the
# same idempotency record as the original. The historical Gate 2
# (token-fingerprint mismatch) was removed in the
# AddScopedIdempotencyAndProxyLogIndexes migration, since its original
# purpose (prevent duplicate Uploads across a token rotation) is now
# handled server-side.
#
# After gates pass, POST the payload (plain JSON, no gzip — server has
# no request-body decompression middleware) and map the response to a
# structured Result the rake task converts to an exit code.
class PendingUploadReplayService
  # Per-stash total-attempts ceiling before auto-quarantine. `attempt_count`
  # on an Entry is the cumulative HTTP-POST count against the server: fresh
  # stashes seed 3 (one was written after UPLOAD_MAX_ATTEMPTS burn). Each
  # deferred replay adds 1 via touch! for 5xx/429. The seeded-plus-10
  # threshold gives ~10 user-visible bin/upload replays before eviction:
  # a legitimately-slow server outage doesn't evict; a poisoned stash that
  # never clears stops blocking the queue after 10 user-driven retries.
  #
  # 401/403 responses DO NOT bump attempt_count — that's a user-side
  # credential issue (reauth_required handles it separately) and would
  # otherwise let a pre-reauth retry loop eat a recoverable stash.
  #
  # Distinct from ClientPipeline::UPLOAD_MAX_ATTEMPTS (= 3), which bounds
  # in-process retries per bin/upload invocation. This constant bounds
  # cross-invocation retries for a single stashed entry.
  MAX_REPLAY_ATTEMPTS = 13

  Result = Struct.new(:replayed, :deferred, :quarantined, :reauth_required, keyword_init: true) do
    def empty?
      (replayed + deferred + quarantined).empty?
    end

    def exit_code
      # 0: nothing left for next bin/upload to retry (all replayed and/or quarantined)
      # 1: at least one stash deferred (transient server error) — next run retries
      # 2: re-authentication required (current token got 401/403)
      return 2 if reauth_required
      return 1 if deferred.any?
      0
    end
  end

  class << self
    def replay_all!(logger: nil, token: nil, current_endpoint: nil)
      new(logger: logger, token: token, current_endpoint: current_endpoint).replay_all!
    end
  end

  def initialize(logger: nil, token: nil, current_endpoint: nil)
    @log = logger || ->(msg) { puts msg }
    @token = token || read_token_file
    @current_endpoint = current_endpoint || ENV["YC_RESULTS_ENDPOINT"].presence
    @result = Result.new(replayed: [], deferred: [], quarantined: [], reauth_required: false)
  end

  def replay_all!
    PendingUploadStash.prune_expired!
    PendingUploadStash.prune_failed!

    entries = PendingUploadStash.list
    if entries.empty?
      log_line("[paxel] no pending uploads")
      return @result
    end

    entries.each { |entry| replay_one(entry) }
    @result
  end

  private

  def replay_one(entry)
    # Gate 1: endpoint must match the current invocation. A stash created
    # against localhost (host.docker.internal) should not silently POST to
    # prod, even if the token happens to be the same.
    if @current_endpoint && entry.url && !endpoints_match?(entry.url, @current_endpoint)
      PendingUploadStash.quarantine!(
        entry,
        reason: "endpoint_mismatch",
        response_body: "stashed=#{entry.url} current=#{@current_endpoint}"
      )
      @result.quarantined << entry.client_request_id
      log_entry(entry, "endpoint changed (stashed: #{entry.endpoint_source}); quarantined")
      return
    end

    # Gate 2: pipeline version. Integer-normalize so a string "1" from an
    # older meta file still compares equal to the current integer constant.
    stashed_version = entry.pipeline_version.to_i
    if stashed_version != ClientPipeline::PIPELINE_VERSION
      PendingUploadStash.quarantine!(entry, reason: "pipeline_version_mismatch")
      @result.quarantined << entry.client_request_id
      log_entry(entry, "stashed with client v#{stashed_version}, current v#{ClientPipeline::PIPELINE_VERSION}; quarantined")
      return
    end

    # Gate 3: excessive retries. A stash whose retries have climbed past the
    # threshold is stuck — quarantine so it stops blocking the replay queue.
    if entry.attempt_count.to_i >= MAX_REPLAY_ATTEMPTS
      PendingUploadStash.quarantine!(
        entry,
        reason: "excessive_retries",
        response_body: "attempt_count=#{entry.attempt_count} last_error=#{entry.last_error.to_s[0, 450]}"
      )
      @result.quarantined << entry.client_request_id
      log_entry(entry, "attempted #{entry.attempt_count} times (>= #{MAX_REPLAY_ATTEMPTS}); quarantined")
      return
    end

    payload =
      begin
        PendingUploadStash.read_payload(entry)
      rescue PendingUploadStash::CorruptStashError => e
        PendingUploadStash.quarantine!(entry, reason: "corrupt_payload", response_body: e.message.to_s[0, 500])
        @result.quarantined << entry.client_request_id
        log_entry(entry, "payload unreadable (#{e.message.to_s[0, 80]}); quarantined")
        return
      end

    response = post_plain(payload: payload, url: entry.url, client_request_id: entry.client_request_id)
    handle_response(entry, response)
  rescue Faraday::Error => e
    PendingUploadStash.touch!(
      entry,
      last_attempt_at: Time.current,
      attempt_count: entry.attempt_count.to_i + 1,
      last_error: "#{e.class}: #{e.message}"
    )
    @result.deferred << entry.client_request_id
    log_entry(entry, "network error (#{e.class.name.split("::").last}); deferred")
  rescue StandardError => e
    # A non-Faraday exception (filesystem permission error during
    # quarantine!/touch!, a server body that's tagged application/json but
    # malformed, etc.) must not kill the replay loop for every remaining
    # entry. Defer this one and let the next bin/upload retry.
    begin
      PendingUploadStash.touch!(
        entry,
        last_attempt_at: Time.current,
        attempt_count: entry.attempt_count.to_i + 1,
        last_error: "#{e.class}: #{e.message.to_s[0, 200]}"
      )
    rescue StandardError
      # touch! itself failed — nothing we can do; move on to the next entry.
    end
    @result.deferred << entry.client_request_id
    log_entry(entry, "unexpected error (#{e.class}); deferred")
  end

  def handle_response(entry, response)
    case response.status
    when 200, 201
      PendingUploadStash.delete!(entry)
      idempotent = response.body.is_a?(Hash) && response.body["idempotent_replay"]
      @result.replayed << entry.client_request_id
      log_entry(entry, idempotent ? "replayed (server already had it)" : "replayed (#{response.body.is_a?(Hash) ? response.body["slug"] : ""})")
    when 401, 403
      # DO NOT bump attempt_count here: 401/403 is a user-side credential
      # issue (reauth_required signals to the CLI to re-auth and re-run),
      # not a server-side retry attempt in the sense Gate 4 cares about.
      # Bumping would let a pre-reauth retry loop accumulate toward the
      # excessive_retries cap and eventually evict a recoverable stash
      # that a fresh token would've replayed cleanly.
      PendingUploadStash.touch!(
        entry,
        last_attempt_at: Time.current,
        attempt_count: entry.attempt_count.to_i,
        last_error: "HTTP #{response.status}"
      )
      @result.reauth_required = true
      @result.deferred << entry.client_request_id
      log_entry(entry, "auth failed (HTTP #{response.status}); keeping for re-auth")
    when 429
      # Rate limited — transient. Keep for next run.
      PendingUploadStash.touch!(
        entry,
        last_attempt_at: Time.current,
        attempt_count: entry.attempt_count.to_i + 1,
        last_error: "HTTP 429"
      )
      @result.deferred << entry.client_request_id
      log_entry(entry, "rate limited (HTTP 429); will retry next run")
    when 400..499
      # Any other 4xx is a permanent rejection (413 Payload Too Large,
      # 415 Unsupported Media Type, 404 Not Found, 422 Unprocessable, etc.).
      # Quarantine so subsequent bin/uploads don't re-POST the same rejected
      # body forever and block new runs from replaying other pending entries.
      PendingUploadStash.quarantine!(
        entry,
        reason: "permanent_4xx",
        response_status: response.status,
        response_body: response.body.to_s[0, 500]
      )
      @result.quarantined << entry.client_request_id
      log_entry(entry, "server rejected (HTTP #{response.status}); quarantined")
    else
      # 5xx / anything else — keep for next run
      PendingUploadStash.touch!(
        entry,
        last_attempt_at: Time.current,
        attempt_count: entry.attempt_count.to_i + 1,
        last_error: "HTTP #{response.status}"
      )
      @result.deferred << entry.client_request_id
      log_entry(entry, "deferred (HTTP #{response.status}); will retry next run")
    end
  end

  def post_plain(payload:, url:, client_request_id:)
    # Plain JSON. Server parses request.raw_post at results_controller.rb
    # with no Rack::Deflater-style request-body decompression, so sending
    # Content-Encoding: gzip would 400 or silently drop the body.
    conn = Faraday.new(url: url) do |f|
      f.request :json
      f.response :json
      # read timeout 120s for tens-of-MB payloads on slow networks.
      f.options.timeout = 120
      # connect timeout 30s — paired with the 120s read so net_http's
      # default 60s open_timeout doesn't silently extend the overall budget.
      f.options.open_timeout = 30
    end

    conn.post do |req|
      req.headers["X-YC-Token"] = @token
      req.headers["X-Idempotency-Key"] = client_request_id
      req.headers["Content-Type"] = "application/json"
      req.body = payload
    end
  end

  def endpoints_match?(a, b)
    ua = URI.parse(a.to_s)
    ub = URI.parse(b.to_s)
    ua.host == ub.host && ua.port == ub.port && ua.path.chomp("/") == ub.path.chomp("/")
  rescue URI::InvalidURIError
    false
  end

  def read_token_file
    return ENV["YC_TOKEN"] if ENV["YC_TOKEN"].present?
    path = ENV["PAXEL_TOKEN_FILE"].presence || File.expand_path("~/.paxel/token")
    File.read(path).strip
  rescue Errno::ENOENT
    if ENV["PAXEL_CLIENT_MODE"] == "dev"
      raise "No API token found. Run `bin/upload` interactively first to authenticate."
    else
      raise "No API token found. Get a fresh `curl | bash` command from your Paxel dashboard."
    end
  end

  def log_line(msg)
    @log.call(msg)
  end

  def log_entry(entry, msg)
    id = entry.client_request_id.to_s[0, 8]
    @log.call("[paxel] replay #{id}…: #{msg}")
  end
end
