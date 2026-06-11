module AnthropicClient
  extend ActiveSupport::Concern
  include ConcurrentProcessing

  # Shared utility: extract plain text from a system prompt that may be
  # a String or an array of content blocks (prompt caching format).
  # Used by AnthropicClient, ProxyCallValidator, and LlmProxyController.
  def self.extract_system_text(system)
    case system
    when String then system
    when Array then system.filter_map { |b| b[:text] || b["text"] }.join
    else system.to_s
    end
  end

  # Contract handshake called once at the top of ClientPipeline#run!. The
  # client computes its own current-signature set (via the ProxyCallValidator
  # that ships in the Docker image) and POSTs it to /api/v1/proxy/preflight.
  # On contract drift the server returns 403 with machine-readable diagnostic
  # fields, and we raise PaxelLlmError::ClientOutOfDate so analyze_local.rake's
  # footer block can print actionable guidance instead of burning 10 narrative
  # calls against the circuit breaker.
  #
  # Behavior:
  #   - 200 ok + no warning      → return :ok
  #   - 200 ok + warning=legacy  → return :legacy (client keeps working through
  #                                the legacy-accepted grace window)
  #   - 403 code=client_out_of_date → raise PaxelLlmError::ClientOutOfDate with
  #                                   a message carrying both contract_version
  #                                   hashes + sample missing signatures
  #   - 404                      → return :skipped (old server / new client;
  #                                fail-open safety net for a mis-deployed
  #                                or old-version proxy). Logs at WARN level
  #                                so a spike in 404s shows up in Sentry/GCL
  #                                — in the steady state Bun forwards
  #                                `/api/v1/proxy/preflight` via
  #                                `services/llm-proxy/proxy.ts`, so 404
  #                                here means the Bun deploy has drifted
  #                                from the Rails release.
  #   - 5xx / network            → return :skipped (transient; the subsequent
  #                                /validate + /health checks already fail
  #                                loudly if the proxy is really down)
  #
  # Set ENV["PAXEL_SKIP_PREFLIGHT"] == "1" to bypass entirely. Useful during
  # dev-mode iteration where the client image keeps getting rebuilt.
  def self.preflight_signatures!(base_url:, token:, logger: nil)
    return :skipped if ENV["PAXEL_SKIP_PREFLIGHT"] == "1"

    log = logger || ->(msg) { Rails.logger&.info(msg) }
    sigs = begin
      ProxyCallValidator.current_signatures.to_a
    rescue StandardError => e
      # Missing prompt constant, name collision, etc. Fail-open so a local
      # iteration bug doesn't brick uploads; the server-side validator
      # still catches bad signatures on real /v1/messages calls.
      log.call("  Preflight: could not compute local signatures (#{e.class}: #{e.message}); skipping")
      return :skipped
    end

    url = URI.join(base_url.chomp("/") + "/", "api/v1/proxy/preflight")

    # Retry loop for the Bun drain 503 window. Bun returns a short 503 +
    # Retry-After while flushing in-flight on SIGTERM (see
    # services/llm-proxy/proxy.ts). The previous 5xx→:skipped behavior
    # fell through to the 10-narrative circuit on a legitimately transient
    # proxy bounce; respecting Retry-After for up to ~15s total is the
    # right trade-off (preflight budget stays small, drain usually
    # completes within a few seconds).
    max_drain_retries = 3
    drain_retry_count = 0
    response = nil

    loop do
      begin
        response = post_preflight_request(url, sigs, token)
      rescue StandardError => e
        log.call("  Preflight: network error (#{e.class.name.demodulize}); skipping")
        return :skipped
      end

      break unless response.code.to_i == 503 && drain_retry_count < max_drain_retries

      drain_retry_count += 1
      retry_after = (response["Retry-After"] || response["retry-after"]).to_i
      wait = [ [ retry_after, 1 ].max, 5 ].min
      log.call("  Preflight: proxy draining (HTTP 503); retrying in #{wait}s (attempt #{drain_retry_count}/#{max_drain_retries})")
      sleep(wait)
    end

    # If we exited the loop on 503 it means the retry budget was exhausted
    # (the break condition is `response.code != 503 OR drain_retry_count >=
    # max`). Surface that distinctly from a plain 5xx so ops can tell a
    # long-draining proxy from a proxy that's cleanly down.
    if response.code.to_i == 503 && drain_retry_count >= max_drain_retries
      log.call("  Preflight: proxy still draining after #{max_drain_retries} retries; skipping")
    end

    case response.code.to_i
    when 200
      payload = JSON.parse(response.body) rescue {}
      warn_if_bun_signatures_stale(payload, log)
      if payload["warning"] == "legacy"
        log.call("  Preflight: legacy signatures accepted (rebuild soon to avoid future failures)")
        return :legacy
      end
      log.call("  Preflight: contract matches (#{payload["contract_version"]})")
      :ok
    when 404
      # Log at WARN level + Rails.logger.warn so ops can monitor 404 volume
      # in Sentry / GCL — steady state with Bun forwarding enabled should
      # be 0. A spike means the Bun deploy drifted from the Rails release.
      # The 404→:skipped fail-open keeps the pipeline moving but it is
      # explicitly NOT silent.
      warning_msg = "Preflight: server does not expose /api/v1/proxy/preflight (proxy route missing or old server); skipping"
      log.call("  #{warning_msg}")
      Rails.logger.warn("[AnthropicClient.preflight_signatures!] #{warning_msg} (url=#{url})")
      :skipped
    when 403
      payload = JSON.parse(response.body) rescue {}
      if payload["code"] == "client_out_of_date"
        expected = payload["expected_contract_version"].to_s
        got = payload["client_contract_version"].to_s
        missing = Array(payload["missing_signatures"]).first(3)
        user_action = "Rebuild the client image to pick up the latest prompt contract. "
        user_action += "Expected contract #{expected.presence || "<unknown>"}, your client has #{got.presence || "<unknown>"}."
        user_action += " Unknown signatures: #{missing.join(", ")}." if missing.any?
        raise PaxelLlmError::ClientOutOfDate.new(
          "Client prompt signatures do not match server contract",
          user_action: user_action,
          http_status: 403,
          proxy_code: "client_out_of_date",
          body_preview: scrubbed_body_preview(response.body)
        )
      end
      # 403 for a non-contract reason (revoked token, other). Let the next
      # /validate call surface it — don't block here.
      log.call("  Preflight: 403 without client_out_of_date code; skipping (/validate will surface auth errors)")
      :skipped
    when 500..599
      log.call("  Preflight: server error HTTP #{response.code}; skipping")
      :skipped
    else
      log.call("  Preflight: unexpected HTTP #{response.code}; skipping")
      :skipped
    end
  end

  # Helpers for preflight_signatures! — split out so the main method reads
  # as a clean switch on the response code without transport details mixed in.

  def self.post_preflight_request(url, sigs, token)
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = (url.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 10

    body = JSON.generate({ client_signatures: sigs, client_version: ENV["PAXEL_CLIENT_VERSION"].to_s })
    request = Net::HTTP::Post.new(url.request_uri)
    request["Content-Type"] = "application/json"
    request["X-YC-Token"] = token.to_s
    # Stamp the client release the server sees (Bun forwards it to Rails
    # and re-emits it on signature-mismatch Sentry events) so an ops
    # "mismatches spiked post-deploy" triage can pivot from request to
    # image version without re-identifying the user.
    release = AnthropicClient.paxel_release rescue nil
    request["x-paxel-client-release"] = release.to_s if release.present?
    request.body = body

    http.request(request)
  end

  # Bun augments 200 preflight responses with cache-age fields so the client
  # can detect "Rails is fresh but Bun's hourly signature cache is stale."
  # Warn loudly so a user who hits "preflight ok but /v1/messages 403" has
  # a breadcrumb. Not a hard fail — a warning buys ops time to debug while
  # the PR #675 follow-up (synchronous Bun cache invalidation) lands.
  def self.warn_if_bun_signatures_stale(payload, log)
    return unless payload.is_a?(Hash) && payload["bun_signatures_stale"] == true
    age_s = (payload["bun_signatures_age_ms"].to_i / 1000.0).round(0)
    interval_s = (payload["bun_signatures_refresh_interval_ms"].to_i / 1000.0).round(0)
    msg = "Preflight OK against Rails, but the Bun proxy's cached signatures are #{age_s}s old (refresh interval #{interval_s}s). "
    msg += "If narrative calls start 403ing with unknown_signature, wait ~#{(interval_s / 60.0).ceil} min for the next refresh and retry."
    log.call("  ⚠️  #{msg}")
    Rails.logger.warn("[AnthropicClient.preflight_signatures!] bun_signatures_stale age_s=#{age_s} interval_s=#{interval_s}")
  end

  # Mirror the body_preview helper applied elsewhere (normalize_sdk_error
  # branches call PaxelLlmError::Base.scrub via #initialize, but that only
  # handles token / PII redaction — the raw slice can still carry
  # invalid-encoding bytes that blow up downstream formatters). First 400
  # chars is enough context for the error footer without risking oversized
  # output.
  def self.scrubbed_body_preview(raw)
    safe = raw.to_s.dup.force_encoding("UTF-8")
    safe = safe.scrub("?") unless safe.valid_encoding?
    safe[0, 400]
  end

  private

  MAX_LLM_RETRIES = 5
  OVERLOAD_MAX_RETRIES = 10 # 529 "overloaded" is guaranteed transient — wait longer
  LLM_REQUEST_TIMEOUT = 300 # seconds — hard wall clock safety net per LLM call
  SLOW_CALL_THRESHOLD_MS = 30_000 # 30s — log a warning for calls slower than this
  MIN_RETRY_WAIT_S = 1.0 # floor on wait_for's return; jitter already ensures ≥1s on the exponential path, but this keeps any future code path that returns a shorter base honest
  LLM_HEARTBEAT_INTERVAL = 15 # seconds — print "still working" so users know we're not stuck

  # Wraps anthropic_client.messages.create and normalizes every failure into an
  # PaxelLlmError::*. Downstream callers rescue PaxelLlmError::Retryable /
  # Fatal — NEVER raw Anthropic::Errors::*. Regression context: the Anthropic
  # Ruby SDK 1.35's APIStatusError.for crashes with TypeError on non-conforming
  # error bodies (`body.dig(:error, :type)` on a String); see
  # anthropic-1.35.0/lib/anthropic/errors.rb:139. That TypeError bypassed this
  # method's old narrow rescue and tripped the 10-strike circuit breaker in
  # ClientPipeline#analyze_sessions. Now every SDK exception + parse failure
  # lands in normalize_sdk_error.
  #
  # Retry behavior: Retryable → sleep (jittered, clamped, honors Retry-After)
  # and retry up to retry_budget_for(err) times. Fatal → re-raise immediately;
  # caller decides whether to fail fast (analyze_sessions) or fall back.
  def call_llm(heartbeat_label: nil, heartbeat: true, **params)
    # Eval-only model override. The model-comparison harness
    # (ModelComparisonEval) sets this thread-local to run the SAME prompt
    # against a different model (e.g. "gpt-5.5-high") without editing the 24
    # eval adapters. Inert in production — nothing outside the eval runner
    # ever sets it. Per-thread + restored by the runner around each
    # call_service, so the Opus judge (run outside that scope) keeps its own
    # model. Applied before record_llm_call so LlmCall.model + cost reflect
    # the model actually called.
    if (override = Thread.current[:eval_model_override]).present?
      params[:model] = override
    end
    params[:system] = cacheable_system(params[:system])
    # Forward the current session id (set by ClientPipeline#analyze_sessions,
    # or by a server-side caller via `Thread.current[:paxel_session_id]`) to
    # the Bun LLM proxy so proxy-side Sentry events and LlmCall rows can
    # be correlated back to the same conversation without exposing a token.
    # The SDK merges `extra_headers` onto every request.
    session_id = Thread.current[:paxel_session_id]
    if session_id.present?
      headers = params[:extra_headers] || {}
      params[:extra_headers] = headers.merge("x-paxel-session-id" => session_id.to_s)
    end
    retries = 0
    heartbeat_thread = nil
    started = nil

    # Narrow rescue: only the SDK invocation + its immediate response-shape
    # check are wrapped. Post-success bookkeeping (record_llm_call,
    # log_call_telemetry) has its own internal error handling; keeping it
    # OUTSIDE the broad rescue means a bug in the recorder surfaces as a real
    # exception rather than being silently normalized to a ProtocolViolation
    # and retried.
    response = begin
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      heartbeat_thread = heartbeat ? start_llm_heartbeat(started, heartbeat_label) : nil
      r = Timeout.timeout(LLM_REQUEST_TIMEOUT, LlmTimeoutError) do
        if dispatch_to_openai?(params[:model])
          # Server-side native OpenAI path (Responses API). Returns an
          # Anthropic-shaped response, so the shape check + record_llm_call +
          # extract_* below all work unchanged. OpenaiClient raises
          # PaxelLlmError directly (rescued below). The `defined?` guard means
          # this branch is dead in the client Docker image (which doesn't ship
          # OpenaiClient) — there a gpt model would instead flow to
          # the Bun proxy via the SDK path, which translates it.
          OpenaiClient.create(**params)
        else
          anthropic_client.messages.create(**params)
        end
      end
      # Sanity check for 200 responses with non-message bodies — e.g. Cloudflare
      # interstitials or WAF HTML that the SDK decodes into an empty object.
      # Catching here prevents an obscure NoMethodError further downstream in
      # response.content.map{...}.
      unless r.respond_to?(:content)
        raise PaxelLlmError::ProtocolViolation.new(
          "Empty / non-message response from upstream",
          user_action: PaxelLlmError::Base.default_user_action(nil),
        )
      end
      r
    # Anthropic::Errors::Error (not just APIError) catches both APIError AND
    # ConversionError. TypeError / NoMethodError / JSON::ParserError catch the
    # originating bug's shape (and future SDK parse regressions).
    # PaxelLlmError::Retryable is added so a transient error from the native
    # OpenAI path (OpenaiClient raises pre-normalized PaxelLlmError)
    # reuses this same retry loop. Fatal OpenAI errors are NOT in this list, so
    # they propagate immediately (no retry) — matching the Anthropic Fatal path.
    # PaxelLlmError::Retryable is in the client image (paxel_llm_error.rb), so
    # this rescue clause is client-safe.
    rescue Anthropic::Errors::Error, Anthropic::Errors::APIConnectionError,
           LlmTimeoutError, TypeError, NoMethodError, JSON::ParserError,
           PaxelLlmError::Retryable => e
      stop_llm_heartbeat(heartbeat_thread); heartbeat_thread = nil
      # An error from OpenaiClient is already a normalized
      # PaxelLlmError — don't re-run it through the Anthropic SDK normalizer.
      normalized = e.is_a?(PaxelLlmError::Base) ? e : safe_normalize_sdk_error(e, params)

      if normalized.is_a?(PaxelLlmError::Retryable)
        retries += 1
        budget = retry_budget_for(normalized)
        if retries > budget
          record_llm_event("failure", error_class: normalized.class.name,
            error_message: normalized.message.to_s.first(500),
            model: params[:model], attempt: retries)
          $stderr.puts "⚠ LLM #{e.class.name.demodulize} after #{retries} attempts, giving up"
          $stderr.flush
          raise normalized
        end
        wait = wait_for(normalized, retries)
        record_llm_event("retry", error_class: normalized.class.name,
          error_message: normalized.message.to_s.first(500),
          model: params[:model], attempt: retries, wait: wait)
        Rails.logger.info("[LLM] #{e.class} (attempt #{retries}/#{budget}), waiting #{wait}s | #{self.class.name}")
        $stderr.puts "⚠ LLM #{e.class.name.demodulize} (attempt #{retries}/#{budget}), retrying in #{wait}s..."
        $stderr.flush
        llm_retry_wait(wait)
        retry
      else
        record_llm_event("failure", error_class: normalized.class.name,
          error_message: normalized.message.to_s.first(500), model: params[:model])
        raise normalized
      end
    ensure
      stop_llm_heartbeat(heartbeat_thread)
    end

    duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
    record_llm_call(params, response, duration)
    record_failover_events(params, response)
    log_call_telemetry(params, response, duration)
    response
  end

  # A response that arrived via OpenaiClient#create's in-call provider failover
  # carries the failed attempts in failover_from. Record each as an LlmEvent
  # ("failover", provider = the provider that FAILED; the serving provider is
  # on the paired LlmCall row) so brownout spillover is queryable from
  # telemetry — previously a successful failover left only a Rails.logger.warn
  # line, invisible to the llm_events forensics used on 2026-06-07.
  # safe_constantize (the dispatch_to_openai? pattern) keeps this client-safe:
  # the client image doesn't ship OpenaiClient, so the guard is false there.
  # An is_a? check — NOT respond_to? — so the suite's strict-args response
  # doubles (which raise on unexpected respond_to? probes) stay untouched.
  def record_failover_events(params, response)
    klass = "OpenaiClient".safe_constantize
    return unless klass && response.is_a?(klass::Response)
    Array(response.failover_from).each do |f|
      record_llm_event("failover",
        error_class: f[:error_class], error_message: f[:error_message],
        model: params[:model], provider: f[:provider])
    end
  rescue => e
    Rails.logger.warn("Failover event recording failed: #{e.class} - #{e.message}")
  end

  # Guard: the normalizer itself must never escape as a non-PaxelLlmError. A
  # pathological exception object whose respond_to? raises would otherwise
  # break the contract. Fall back to Fatal with the invariant fields populated.
  def safe_normalize_sdk_error(e, params)
    normalize_sdk_error(e, params)
  rescue => normalize_error
    rid = (extract_request_id(e) rescue nil)
    PaxelLlmError::Fatal.new(
      "SDK error normalization failed: #{e.class}: #{e.message.to_s.first(100)} " \
      "(normalize raised #{normalize_error.class})",
      request_id: rid,
      user_action: PaxelLlmError::Base.default_user_action(rid),
    )
  end

  # Map SDK exceptions → PaxelLlmError::*. Inspects structured data only
  # (status, body.error.type, body.error.code, response headers) — no
  # string-matching on SDK internal messages.
  def normalize_sdk_error(e, params)
    case e
    # --- retryable ---
    when Anthropic::Errors::RateLimitError
      PaxelLlmError::Retryable.new(e.message, http_status: 429, upstream_type: "rate_limit_error",
        request_id: extract_request_id(e), retry_after: extract_retry_after(e))
    when Anthropic::Errors::APIConnectionError, Anthropic::Errors::APITimeoutError, LlmTimeoutError
      PaxelLlmError::Retryable.new(e.message)
    when Anthropic::Errors::InternalServerError
      status = e.respond_to?(:status) ? e.status : 500
      PaxelLlmError::Retryable.new(e.message,
        http_status: status,
        upstream_type: extract_body_type(e) || "api_error",
        proxy_code: extract_body_code(e),
        request_id: extract_request_id(e),
        retry_after: extract_retry_after(e))
    # --- fatal, specific ---
    when Anthropic::Errors::PermissionDeniedError
      code = extract_body_code(e)
      rid = extract_request_id(e)
      case code
      when "client_out_of_date"
        PaxelLlmError::ClientOutOfDate.new(e.message, http_status: 403, proxy_code: code,
          request_id: rid, user_action: rebuild_user_action)
      when "quota_exceeded"
        PaxelLlmError::QuotaExceeded.new(e.message, http_status: 403, proxy_code: code,
          request_id: rid, user_action: quota_user_action)
      when "model_not_allowed"
        # Deploy-window race: when a new model string (e.g. gpt-5.5-none) ships,
        # the Bun proxy can briefly serve a stale allowlist it cached before
        # Rails rolled out — and a model-allowlist miss has no self-heal. If THIS
        # client already considers the model valid (it's in our own
        # ALLOWED_MODELS), the rejection is almost certainly that transient skew,
        # so retry rather than let a single Fatal instantly trip the circuit and
        # discard the run. A genuinely-unknown model stays Fatal.
        if model_known_to_client?(params[:model])
          PaxelLlmError::Retryable.new(e.message, http_status: 403,
            upstream_type: "model_not_allowed_stale", proxy_code: code,
            request_id: rid, retry_after: extract_retry_after(e))
        else
          PaxelLlmError::ModelNotAllowed.new(e.message, http_status: 403, proxy_code: code,
            request_id: rid, user_action: model_not_allowed_user_action)
        end
      when "system_prompt_missing"
        PaxelLlmError::SystemPromptMissing.new(e.message, http_status: 403, proxy_code: code,
          request_id: rid, user_action: system_prompt_missing_user_action)
      else
        decoded = decode_body(e)
        PaxelLlmError::Fatal.new(e.message, http_status: 403, upstream_type: "permission_error",
          proxy_code: code, request_id: rid,
          body_preview: body_preview(decoded[:text]),
          response_content_type: decoded[:content_type],
          user_action: PaxelLlmError::Base.default_user_action(rid))
      end
    when Anthropic::Errors::AuthenticationError
      code = extract_body_code(e)
      rid = extract_request_id(e)
      if code == "quota_exceeded"
        PaxelLlmError::QuotaExceeded.new(e.message, http_status: 401, proxy_code: code,
          request_id: rid, user_action: quota_user_action)
      elsif code == "validation_unavailable"
        # The proxy returns 401 + validation_unavailable when it could not reach
        # Rails to validate the token after its own retries (it fails CLOSED).
        # The token itself is almost certainly fine — this is a transient
        # server-side outage (Rails deploy/restart, brief overload, or a
        # Rack::Attack throttle on the validate endpoint). Treat it as Retryable
        # so a momentary blip mid-run doesn't trip the circuit breaker and
        # discard a long, mostly-complete run (a single Fatal trips it instantly).
        # The proxy does not cache this result, so each retry re-validates
        # against a possibly-recovered Rails. Incident: req_514204fcc688
        # (2026-06-03), Sentry PAXEL-LLM-PROXY-9 / -1 (849 prior events).
        PaxelLlmError::Retryable.new(e.message, http_status: 401,
          upstream_type: "validation_unavailable", proxy_code: code,
          request_id: rid, retry_after: extract_retry_after(e))
      else
        # Non-JSON 401s (e.g. an ALB fixed-response on the validate_token
        # path) need the same body_preview plumbing as the 403 fall-through.
        # Without this, a non-JSON 401 loses the preview and we regress to
        # ARGUS-CLIENT-1 on a different status code.
        decoded = decode_body(e)
        PaxelLlmError::AuthFailed.new(e.message, http_status: 401, proxy_code: code,
          request_id: rid,
          body_preview: body_preview(decoded[:text]),
          response_content_type: decoded[:content_type],
          user_action: auth_user_action)
      end
    when Anthropic::Errors::BadRequestError
      code = extract_body_code(e)
      status = e.respond_to?(:status) ? e.status : 400
      rid = extract_request_id(e)
      if code == "input_too_large" || status == 413
        PaxelLlmError::InputTooLarge.new(e.message, http_status: status, proxy_code: code,
          request_id: rid, user_action: input_too_large_user_action)
      elsif code == "content_filtered"
        # The proxy (openai-translate.ts) tags an OpenAI/Foundry input
        # content-moderation 400 with this code. Non-fatal + non-retryable so the
        # pipeline skips this session rather than failing the whole upload.
        PaxelLlmError::ContentFiltered.new(e.message, http_status: status, proxy_code: code,
          request_id: rid, user_action: content_filtered_user_action)
      else
        decoded = decode_body(e)
        PaxelLlmError::Fatal.new(e.message, http_status: status, upstream_type: extract_body_type(e),
          proxy_code: code, request_id: rid,
          body_preview: body_preview(decoded[:text]),
          response_content_type: decoded[:content_type],
          user_action: PaxelLlmError::Base.default_user_action(rid))
      end
    when Anthropic::Errors::UnprocessableEntityError,
         Anthropic::Errors::NotFoundError,
         Anthropic::Errors::ConflictError
      status = e.respond_to?(:status) ? e.status : 400
      rid = extract_request_id(e)
      decoded = decode_body(e)
      PaxelLlmError::Fatal.new(e.message, http_status: status, upstream_type: extract_body_type(e),
        proxy_code: extract_body_code(e), request_id: rid,
        body_preview: body_preview(decoded[:text]),
        response_content_type: decoded[:content_type],
        user_action: PaxelLlmError::Base.default_user_action(rid))
    # --- generic APIStatusError fallback (future-proof new status codes) ---
    when Anthropic::Errors::APIStatusError
      status = e.respond_to?(:status) ? e.status : nil
      rid = extract_request_id(e)
      if status && (status == 408 || status == 429 || (500..599).cover?(status))
        PaxelLlmError::Retryable.new(e.message, http_status: status, upstream_type: extract_body_type(e),
          proxy_code: extract_body_code(e), request_id: rid,
          retry_after: extract_retry_after(e))
      else
        decoded = decode_body(e)
        PaxelLlmError::Fatal.new(e.message, http_status: status, upstream_type: extract_body_type(e),
          proxy_code: extract_body_code(e), request_id: rid,
          body_preview: body_preview(decoded[:text]),
          response_content_type: decoded[:content_type],
          user_action: PaxelLlmError::Base.default_user_action(rid))
      end
    # --- protocol parse / SDK internal breakage: preserve backtrace + cause ---
    when Anthropic::Errors::ConversionError, TypeError, NoMethodError, JSON::ParserError
      # A parse/protocol error's message can embed a fragment of the response
      # body — scrub credentials before it reaches the log or the user-facing
      # error string.
      safe_msg = SecretScrubber.scrub(e.message.to_s)
      Rails.logger.error(
        "[AnthropicClient] ProtocolViolation caused by #{e.class}: #{safe_msg}\n" \
        "#{e.backtrace&.first(5)&.join("\n")}"
      )
      rid = extract_request_id(e)
      violation = PaxelLlmError::ProtocolViolation.new(
        "Proxy returned an unexpected response shape (#{e.class}: #{safe_msg.first(100)})",
        request_id: rid,
        user_action: PaxelLlmError::Base.default_user_action(rid),
      )
      # Preserve the SDK-internal backtrace on the normalized error. Ruby's
      # native .cause is set automatically when call_llm does `raise normalized`.
      violation.set_backtrace(e.backtrace) if e.backtrace
      violation
    else
      rid = (e.respond_to?(:request_id) ? e.request_id : nil)
      PaxelLlmError::Fatal.new(
        "Unhandled SDK error: #{e.class}: #{e.message.to_s.first(100)}",
        request_id: rid,
        user_action: PaxelLlmError::Base.default_user_action(rid),
      )
    end
  end

  # True if THIS client's own allowlist recognizes `model`. Lets us treat a
  # proxy "model_not_allowed" as a transient deploy-window skew (retry) rather
  # than a fatal bad model. ProxyCallValidator ships in the client image and is
  # already used by .preflight_signatures!, so this reference is client-safe.
  def model_known_to_client?(model)
    return false if model.blank?
    defined?(ProxyCallValidator) && ProxyCallValidator::ALLOWED_MODELS.include?(model.to_s)
  rescue StandardError
    false
  end

  def extract_request_id(e)
    headers = e.respond_to?(:headers) ? e.headers : nil
    return nil unless headers.is_a?(Hash)
    headers["x-request-id"] || headers["X-Request-Id"]
  rescue
    nil
  end

  def extract_retry_after(e)
    headers = e.respond_to?(:headers) ? e.headers : nil
    return nil unless headers.is_a?(Hash)
    val = headers["retry-after"] || headers["Retry-After"]
    val&.to_i&.positive? ? val.to_i : nil
  rescue
    nil
  end

  # 500-char cap on the body_preview string that flows to CLI footer,
  # upload.error_message, and Sentry extra.
  BODY_PREVIEW_LIMIT = 500

  # Decode an Anthropic SDK error's response body into {hash, text,
  # content_type}. StringIO appears when the SDK's decode_content sees a
  # non-JSON content-type (text/plain "Forbidden" from an ALB fixed-response,
  # HTML interstitials, etc.) — see anthropic-*/lib/anthropic/internal/util.rb.
  # An application/json response with an *unparseable* body lands as a String.
  # Memoized on the exception object so extract_body_code + extract_body_type
  # don't reparse twice per error.
  def decode_body(e)
    cached = e.instance_variable_get(:@paxel_decoded_body)
    return cached if cached

    raw = e.respond_to?(:body) ? e.body : nil
    ct  = extract_content_type(e)
    result =
      if raw.is_a?(Hash)
        { hash: raw, text: nil, content_type: ct }
      else
        text = extract_text_body(raw)
        if text.nil? || text.empty?
          { hash: nil, text: nil, content_type: ct }
        else
          parsed = (JSON.parse(text) rescue nil)
          if parsed.is_a?(Hash)
            { hash: parsed, text: text, content_type: ct }
          else
            { hash: nil, text: text, content_type: ct }
          end
        end
      end
    e.instance_variable_set(:@paxel_decoded_body, result)
    result
  rescue
    { hash: nil, text: nil, content_type: nil }
  end

  def extract_content_type(e)
    return nil unless e.respond_to?(:headers)
    headers = e.headers
    return nil unless headers.is_a?(Hash)
    headers["content-type"] || headers["Content-Type"]
  rescue
    nil
  end

  def extract_text_body(raw)
    case raw
    when StringIO
      raw.rewind rescue nil
      raw.read
    when String
      raw
    end
  end

  # Flatten whitespace + cap at BODY_PREVIEW_LIMIT with ellipsis. Nil-safe
  # and UTF-8-safe (edge layers can return gzipped / binary / mis-declared
  # bodies; without `.scrub("?")` the downstream gsub would raise
  # Encoding::CompatibilityError and safe_normalize_sdk_error would eat the
  # preview).
  def body_preview(text)
    return nil if text.nil? || text.to_s.empty?
    safe = text.to_s.dup.force_encoding("UTF-8")
    safe = safe.scrub("?") unless safe.valid_encoding?
    flat = safe.gsub(/\s+/, " ").strip
    return nil if flat.empty?
    flat.length > BODY_PREVIEW_LIMIT ? "#{flat[0, BODY_PREVIEW_LIMIT]}…" : flat
  end

  def extract_body_type(e)
    hash = decode_body(e)[:hash]
    return nil unless hash.is_a?(Hash)
    hash.dig("error", "type") || hash.dig(:error, :type)
  rescue
    nil
  end

  def extract_body_code(e)
    hash = decode_body(e)[:hash]
    return nil unless hash.is_a?(Hash)
    hash.dig("error", "code") || hash.dig(:error, :code)
  rescue
    nil
  end

  # True upstream overload — HTTP 529 OR body.error.type=="overloaded_error".
  # Some upstreams (non-Anthropic providers behind the proxy) return
  # overloaded_error with a 503 status, so we must not gate on 529 alone.
  # queue_overflow (503 with proxy_code="queue_overflow") is short-term
  # proxy backpressure, not upstream overload — excluded here.
  def real_overload?(err)
    return false if err.proxy_code == "queue_overflow"
    err.upstream_type == "overloaded_error" || err.http_status == 529
  end

  def retry_budget_for(err)
    real_overload?(err) ? OVERLOAD_MAX_RETRIES : MAX_LLM_RETRIES
  end

  def wait_for(err, attempt)
    # Respect server-supplied Retry-After (proxy sets it on queue_overflow and
    # concurrent-limit 429; Anthropic sets it on RateLimit). Otherwise
    # exponential backoff capped at 60s so a large retry budget can't produce
    # 1024s (17min) waits at attempt=10. Jitter spreads reconnect storms.
    retry_after = err.retry_after&.to_i if err.respond_to?(:retry_after)
    base = if retry_after && retry_after > 0
      retry_after
    else
      [ 2**attempt, 60 ].min
    end
    [ base + rand(3), MIN_RETRY_WAIT_S ].max
  end

  # User-facing action text. Env-aware so dev runs (bin/upload sets
  # PAXEL_CLIENT_MODE=dev) and public curl|bash runs get the right command.
  # `pull_client_image` auto-fetches the latest client image on every
  # invocation, so re-running the top-level CLI is sufficient to refresh
  # — no explicit "force rebuild" flag is needed anymore.
  def rebuild_user_action
    if ENV["PAXEL_CLIENT_MODE"] == "dev"
      "Your Paxel client image is out of date. Re-run `bin/upload` to pick up the latest client image."
    else
      "Your Paxel client image is out of date. Go back to your Paxel dashboard and re-run the shown `curl | bash` command to pick up the latest client image."
    end
  end

  def auth_user_action
    if ENV["PAXEL_CLIENT_MODE"] == "dev"
      "Your Paxel token is invalid or expired. Re-login at localhost:3000 and copy the token into ~/.paxel/token, then re-run `bin/upload`."
    else
      "Your Paxel token is invalid or expired. Go back to your Paxel dashboard and re-run the shown `curl | bash` command to refresh it."
    end
  end

  def quota_user_action
    "Your daily LLM quota is exhausted. Try again after midnight UTC, or email paxel@ycombinator.com."
  end

  # 400 content_filtered — the model provider's input safety filter declined this
  # session (GPT-only; usually the cybersecurity filter on security-research
  # transcripts). Non-fatal + non-retryable: the session is skipped and the rest
  # of the report is unaffected, so the action is informational. Not env-aware —
  # nothing to re-run or rebuild.
  def content_filtered_user_action
    "The model provider's safety filter declined this session — usually because it " \
      "contained security-research content — so it was skipped. The rest of your report " \
      "is unaffected. If most of your sessions were skipped, email paxel@ycombinator.com."
  end

  def input_too_large_user_action
    if ENV["PAXEL_CLIENT_MODE"] == "dev"
      "Your transcript exceeded the proxy's input size limit. Try `bin/upload --since 2m` or `--commits 500` to analyze a smaller slice."
    else
      "Your transcript exceeded the proxy's input size limit. Re-run the shown `curl | bash` command from your Paxel dashboard, appending `-s -- --since 2m` or `-s -- --commits 500` to analyze a smaller slice."
    end
  end

  # 403 model_not_allowed — proxy's allowed_models set doesn't include the
  # model the client requested. Causes: (a) client too old (proxy removed the
  # old model from the allowlist), (b) client too new (proxy hasn't picked up
  # the new model yet), or (c) developer typo in the model string. A rebuild
  # fixes (a) and often (b); (c) needs a code fix, not a rebuild. Always fall
  # back to email escalation if rebuild doesn't resolve it.
  def model_not_allowed_user_action
    if ENV["PAXEL_CLIENT_MODE"] == "dev"
      "The Paxel proxy does not recognize this model. Re-run `bin/upload` to pick up " \
        "the latest client image. If the error persists, email " \
        "paxel@ycombinator.com and include the Request id shown above."
    else
      "The Paxel proxy does not recognize this model. Re-run the shown `curl | bash` from " \
        "your Paxel dashboard to pick up the latest client image. " \
        "If the error persists, email paxel@ycombinator.com with the Request id above."
    end
  end

  # 403 system_prompt_missing — the client sent an empty or malformed system
  # prompt. A well-behaved client never hits this, so seeing it indicates a
  # client-side bug (usually a prompt-builder regression). A rebuild may help
  # if the bug has already been fixed upstream; otherwise, escalate.
  def system_prompt_missing_user_action
    if ENV["PAXEL_CLIENT_MODE"] == "dev"
      "The Paxel client sent an empty system prompt — this indicates a client " \
        "bug. Re-run `bin/upload` to pick up the latest client image. If the error persists, email " \
        "paxel@ycombinator.com with the Request id shown above so we can investigate."
    else
      "The Paxel client sent an empty system prompt — this indicates a client bug. " \
        "Go back to your Paxel dashboard and re-run the shown `curl | bash` command. " \
        "If the error persists, email paxel@ycombinator.com with the Request id shown above."
    end
  end

  def llm_retry_wait(seconds)
    sleep(seconds)
  end

  # Custom error class so Timeout doesn't catch unrelated StandardErrors
  class LlmTimeoutError < StandardError; end

  # Heartbeat thread prints progress every 15s so users know the pipeline isn't stuck.
  # label can be a String ("classifying decisions") or a callable (-> { "batch 3/5" })
  # for dynamic context that updates each tick.
  def start_llm_heartbeat(started, label = nil)
    return nil if Rails.env.test?

    Thread.new do
      loop do
        sleep(LLM_HEARTBEAT_INTERVAL)
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(0).to_i
        context = label.respond_to?(:call) ? label.call : label
        msg = context ? "→ #{context} (#{elapsed}s)" : "→ Still working... (#{elapsed}s)"
        $stderr.puts msg
        $stderr.flush
      end
    rescue
      # heartbeat never crashes business logic
    end
  end

  def stop_llm_heartbeat(thread)
    thread&.kill
    thread&.join(1)
  rescue
    # never crash on heartbeat cleanup
  end

  def log_call_telemetry(params, response, duration)
    usage = extract_usage(response)
    model = params[:model]
    caller_name = self.class.name
    in_tok = usage[:input_tokens]
    out_tok = usage[:output_tokens]

    if duration >= SLOW_CALL_THRESHOLD_MS
      Rails.logger.warn("[LLM] SLOW #{(duration / 1000).round(1)}s | #{caller_name} | model=#{model} | in=#{in_tok} out=#{out_tok}")
    else
      Rails.logger.info("[LLM] #{(duration / 1000).round(1)}s | #{caller_name} | model=#{model} | in=#{in_tok} out=#{out_tok}")
    end
  rescue => e
    # telemetry never crashes business logic
    nil
  end

  # Wraps a string system prompt in the array-of-content-blocks format with
  # cache_control for Anthropic prompt caching. Returns non-strings unchanged
  # (idempotent if already wrapped).
  def cacheable_system(text)
    return text unless text.is_a?(String) && text.present?
    [ { type: "text", text: text, cache_control: { type: "ephemeral" } } ]
  end

  def record_llm_call(params, response, duration)
    return unless defined?(LlmCall) && LlmCall.table_exists?

    usage = extract_usage(response)
    upload = @upload || @session&.project&.upload

    cache_creation = usage[:cache_creation_input_tokens]
    cache_read = usage[:cache_read_input_tokens]

    if cache_read.to_i > 0
      Rails.logger.info("[LlmCall] cache hit: #{self.class.name} read=#{cache_read} write=#{cache_creation.to_i}")
    end

    system_prompt = AnthropicClient.extract_system_text(params[:system])
    messages = params[:messages]
    response_text = extract_text(response)
    response_raw = response.content.map { |b|
      { type: b.type, text: b.respond_to?(:text) ? b.text : nil }
    }

    LlmCall.create!(
      upload: upload,
      service_name: self.class.name,
      model: params[:model],
      provider: llm_call_provider(params, response),
      max_tokens: params[:max_tokens],
      system_prompt: system_prompt,
      messages: messages,
      response_text: response_text,
      response_raw: response_raw,
      stop_reason: response.respond_to?(:stop_reason) ? response.stop_reason : nil,
      input_tokens: usage[:input_tokens],
      output_tokens: usage[:output_tokens],
      cache_creation_input_tokens: cache_creation,
      cache_read_input_tokens: cache_read,
      cost_cents: compute_cost_cents(
        usage[:input_tokens], usage[:output_tokens], params[:model],
        cache_creation: cache_creation, cache_read: cache_read
      ),
      duration_ms: duration
    )
  rescue => e
    Rails.logger.warn("LlmCall recording failed (#{self.class.name}): #{e.class} - #{e.message}")
  end

  # Which upstream actually served this call, for LlmCall.provider.
  #   - Native OpenAI path (OpenaiClient::Response) → the resolved provider name
  #     ("openai" / "azure_openai"). Accurate per call.
  #   - Proxy-routed (client image, or any server with YC_LLM_PROXY_URL set) →
  #     nil: the Anthropic-shaped response doesn't reveal which upstream the
  #     proxy chose. LlmTpmMonitor's COALESCE fallback handles these.
  #   - Server-direct Anthropic SDK call → "anthropic" (hits api.anthropic.com).
  #
  # Detects the OpenAI path by class (not respond_to?) so strict response doubles
  # in specs don't choke; `defined?` keeps it safe in the client image, which
  # doesn't ship OpenaiClient (and never produces an OpenaiClient::Response).
  def llm_call_provider(params, response)
    prov = response.provider if defined?(OpenaiClient::Response) && response.is_a?(OpenaiClient::Response)
    return prov if prov.present?
    return nil if ENV["YC_LLM_PROXY_URL"].present?
    # Server-direct: Anthropic SDK → "anthropic". A native gpt call always has a
    # provider above, but if one were ever blank, fall back by model (mirrors
    # LlmTpmMonitor::SERVER_PROVIDER_SQL) rather than mislabeling it "anthropic".
    params[:model].to_s.start_with?("gpt-") ? "openai" : "anthropic"
  end

  def anthropic_client
    @anthropic_client ||= begin
      config = { timeout: 120 }
      config[:api_key] = ENV["YC_API_KEY"] || Rails.application.credentials.dig(:anthropic, :api_key)
      config[:base_url] = ENV["YC_LLM_PROXY_URL"] if ENV["YC_LLM_PROXY_URL"].present?
      # Fail closed (PAXEL-CLIENT-H). YC_API_KEY (the upload script sets it to the YC
      # proxy token, `-e YC_API_KEY=$YC_TOKEN`, alongside YC_LLM_PROXY_URL) is NOT a
      # valid Anthropic key — it must go through the proxy. So if there's no proxy
      # base_url AND either no key at all OR a YC proxy token, the SDK would default
      # to api.anthropic.com and send nothing / the YC token → cryptic 401 and a
      # silent proxy bypass. Raise an actionable error instead. Server runs use a real
      # Anthropic credential (sk-ant-, no YC_API_KEY) and may legitimately call
      # api.anthropic.com directly, so this only trips on a misconfigured client run
      # (empty proxy override / alternate run path / stale upload script).
      if config[:base_url].blank? && (config[:api_key].blank? || ENV["YC_API_KEY"].present?)
        raise PaxelLlmError::Fatal.new(
          "LLM proxy not configured: YC_LLM_PROXY_URL is unset.",
          user_action: "Re-run the latest command from your Paxel dashboard " \
            "(curl -fsSL https://paxel.ycombinator.com/upload.sh | bash). " \
            "If it keeps happening, email paxel@ycombinator.com.",
        )
      end
      client = Anthropic::Client.new(**config)
      # The SDK's Client#initialize (anthropic-1.35.0/lib/anthropic/client.rb:108-139)
      # exposes no default-headers option; it hardcodes anthropic-version only.
      # We tag every outbound request with the Paxel release so proxy-side Sentry
      # events (ARGUS-CLIENT-1 follow-up) can pivot on the image/server that made
      # the call.
      existing = client.instance_variable_get(:@headers) || {}
      client.instance_variable_set(
        :@headers,
        existing.merge("x-paxel-client-release" => AnthropicClient.paxel_release)
      )
      client
    end
  end

  def self.paxel_release
    @paxel_release ||= begin
      value = File.read(File.expand_path("../../../VERSION", __dir__)).strip
      value.empty? ? "unknown" : value
    rescue StandardError
      "unknown"
    end
  end

  # Tier → model string. Single source of truth so labels and logs (e.g.
  # the client pipeline's per-step model tags) can resolve a model without
  # including this concern. An unknown tier (incl :default) falls back to
  # the quality model, matching the prior case-statement behavior.
  #
  # GPT-first (2026-06): every tier is gpt-5.5 at reasoning effort "none". NOTE:
  # a BARE "gpt-5.5" (no suffix) does NOT mean no reasoning — OpenAI/Foundry
  # default it to MEDIUM, which costs 2-4x latency + tokens with no quality gain
  # on these extraction/writing surfaces (measured on a real 20-candidate
  # decision batch: bare/medium = 39s + 1552 reasoning tok vs none = 9.5s + 0).
  # So we pin "-none" explicitly here instead of relying on the default. The
  # tier KEYS are kept so callers
  # (anthropic_model(:fast) etc.) and the swap-back path stay untouched: when a
  # future Anthropic model beats gpt-5.5 (e.g. a Haiku 5 / Sonnet 5), restore
  # the per-tier Claude ids below and the whole pipeline routes back to Claude
  # — the Anthropic SDK path, the proxy's Responses-API translation layer, and
  # dispatch_to_openai? all remain wired for exactly that.
  #   Previous Claude mapping (reference / fast rollback):
  #     fast: "claude-haiku-4-5", quality: "claude-sonnet-4-6", opus: "claude-opus-4-7"
  # Per-tier GPT differentiation (e.g. gpt-5.4-mini for :fast) can come later.
  MODELS = {
    fast: "gpt-5.5-none",
    quality: "gpt-5.5-none",
    opus: "gpt-5.5-none"
  }.freeze

  # Pipeline model resolver — hard-coded via MODELS the same way the Claude
  # tiers used to be (no env override). Chat is NOT routed here (its model is
  # set by ChatController); the eval model-comparison override still wins via
  # Thread.current[:eval_model_override] in call_llm.
  def anthropic_model(tier = :default)
    MODELS.fetch(tier, MODELS[:quality])
  end

  # Like #anthropic_model but pins an explicit reasoning effort, replacing the
  # tier's default suffix. For the rare surface that genuinely benefits from
  # reasoning — e.g. JudgeService, an evaluative meta-critic — unlike the
  # pipeline's extraction/writing surfaces, which run at "none". The effort
  # rides the model-string SUFFIX so it works on BOTH the native OpenAI path
  # AND the SDK->proxy path (a reasoning_effort: param would only reach the
  # native path). On a future Claude swap-back the base has no effort suffix,
  # so this returns it unchanged (reasoning would then need thinking config).
  def anthropic_model_with_effort(tier, effort)
    base = MODELS.fetch(tier, MODELS[:quality]).sub(/-(none|low|medium|high|xhigh)\z/, "")
    base.start_with?("gpt-") ? "#{base}-#{effort}" : base
  end

  # Should this call be served by the native server-side OpenAI client instead
  # of the Anthropic SDK?
  #   - Not a GPT model        → no (Anthropic SDK).
  #   - YC_LLM_PROXY_URL set    → no: the SDK already points at the Bun proxy,
  #     which translates gpt-* itself. This is the client Docker image's case
  #     (the upload script always sets YC_LLM_PROXY_URL) AND any server told to
  #     route through the proxy — honoring the documented "via proxy" path.
  #   - else (server-direct)    → yes, when OpenaiClient is loadable.
  # safe_constantize triggers Zeitwerk autoload on the server but returns nil —
  # never NameError — in the client image, which doesn't ship the class (a
  # second belt to the YC_LLM_PROXY_URL guard above). When dispatched but no
  # OpenAI key is configured, OpenaiClient raises a clear Fatal rather
  # than silently 404ing against Anthropic.
  def dispatch_to_openai?(model)
    return false unless model.to_s.start_with?("gpt-")
    return false if ENV["YC_LLM_PROXY_URL"].present?
    klass = "OpenaiClient".safe_constantize
    klass.present? && klass.handles?(model)
  end

  def extract_text(response)
    response.content.filter_map { |block|
      block.text if block.respond_to?(:text)
    }.join
  end

  def extract_usage(response)
    usage = response.usage
    {
      input_tokens: usage&.input_tokens || 0,
      output_tokens: usage&.output_tokens || 0,
      cache_creation_input_tokens: usage&.respond_to?(:cache_creation_input_tokens) ? usage.cache_creation_input_tokens : nil,
      cache_read_input_tokens: usage&.respond_to?(:cache_read_input_tokens) ? usage.cache_read_input_tokens : nil
    }
  end

  def record_llm_event(event_type, error_class:, error_message:, model:, attempt: nil, wait: nil, provider: nil)
    return unless defined?(LlmEvent) && LlmEvent.table_exists?
    # Fire-and-forget: don't block the retry/error path with a DB write
    attrs = {
      event_type: event_type,
      source: "anthropic_llm",
      service_name: self.class.name,
      model: model,
      # Use the caller-supplied provider when known (e.g. "failover" events name
      # the exact provider that failed, azure_openai vs openai); otherwise
      # derive from the model so GPT retry/failure rows aren't mislabeled
      # "anthropic" on the native OpenAI path.
      provider: provider || (model.to_s.start_with?("gpt-") ? "openai" : "anthropic"),
      error_class: error_class,
      error_message: error_message,
      retry_attempt: attempt,
      max_retries: MAX_LLM_RETRIES,
      wait_seconds: wait,
      upload_id: (@upload || @session&.project&.upload)&.id
    }
    if Rails.env.test?
      LlmEvent.create!(attrs) rescue nil
    else
      Thread.new { LlmEvent.create!(attrs) rescue nil }
    end
  rescue => e
    Rails.logger.warn("LlmEvent recording failed: #{e.class} - #{e.message}")
  end

  def compute_cost_cents(input_tokens, output_tokens, model, cache_creation: nil, cache_read: nil)
    # GPT branches MUST precede the Anthropic ones so a gpt-* model doesn't
    # fall through to the Sonnet `else` (cost-data corruption). Rates in cents
    # per 1K tokens ($/MTok ÷ 10), OpenAI list pricing as of 2026-06, mirroring
    # the proxy's DEFAULT_RATES. gpt-5.5 $5/$30 (cached $0.50); gpt-5.4-mini
    # $0.75/$4.50 (cached $0.075).
    rates = case model
    when /gpt-5\.4-mini/ then { input: 0.075, output: 0.45, cache_write: 0.075, cache_read: 0.0075 }
    when /gpt-5\.5/      then { input: 0.5, output: 3.0, cache_write: 0.5, cache_read: 0.05 }
    when /opus/  then { input: 0.5, output: 2.5, cache_write: 0.625, cache_read: 0.05 }   # $5/$25 per MTok
    when /haiku/ then { input: 0.1, output: 0.5, cache_write: 0.125, cache_read: 0.01 }   # $1/$5 per MTok
    else              { input: 0.3, output: 1.5, cache_write: 0.375, cache_read: 0.03 }   # $3/$15 per MTok (Sonnet)
    end
    cost = input_tokens * rates[:input] + output_tokens * rates[:output]
    cost += (cache_creation || 0) * rates[:cache_write]
    cost += (cache_read || 0) * rates[:cache_read]
    (cost / 1000.0).ceil
  end
end
