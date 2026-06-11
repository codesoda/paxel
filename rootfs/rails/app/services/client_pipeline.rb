# Client-side analysis pipeline for Docker container.
#
# Runs the deterministic + LLM analysis steps locally, then packages
# results for upload to the YC server. All LLM calls go through the
# YC API proxy (set via YC_LLM_PROXY_URL).
#
# Pipeline:
#   ▶ Discover projects
#   ▶ Parse & chunk transcripts
#   ▶ Session narratives (LLM, 20 threads)
#   ▶ Episode construction (deterministic)
#   ▶ Steering traces (deterministic)
#   ▶ Decision intelligence (LLM, non-fatal)
#   ▶ Episode scoring (LLM)
#   ▶ Package & upload results (decisions regex-redacted before upload)
#
# Usage:
#   log = ->(msg) { puts msg }
#   result = ClientPipeline.new(
#     transcript_dir: "/path/to/transcripts",
#     results_endpoint: "https://paxel.yc.com/api/v1/results",
#     token: "yk_abc123",
#     logger: log,
#     verbose: true
#   ).run!
class ClientPipeline
  include ConcurrentProcessing
  include PipelineCircuitBreaker

  class PipelineAuthError < StandardError; end

  # Carries the underlying PaxelLlmError that tripped the circuit breaker so
  # the rake-task footer (`lib/tasks/analyze_local.rake`) can surface
  # `user_action` + `request_id` to the user's terminal. Without this, the
  # previous error path printed an opaque "10 consecutive failures" with no
  # actionable guidance.
  #
  # Defined HERE (not in the `PipelineCircuitBreaker` concern) so `.name`
  # stays `"ClientPipeline::PipelineCircuitBroken"` — Ruby bakes the name
  # from the first constant assignment, and Sentry groups errors by class
  # name. Defining inside the concern would have renamed to
  # `"PipelineCircuitBreaker::PipelineCircuitBroken"` and fragmented
  # historical Sentry issues. The concern's `Breaker#raise_if_tripped!`
  # references this class via lazy const lookup at raise time.
  class PipelineCircuitBroken < StandardError
    attr_reader :original_error, :session_id

    def initialize(message, original_error: nil, session_id: nil)
      super(message)
      @original_error = original_error
      @session_id = session_id
    end
  end

  class PipelineNoResults < StandardError
    # original_error carries the last per-session PaxelLlmError so the rake-task
    # footer (analyze_local.rake) and the client_pipeline_fatal Sentry handler
    # can surface the real cause + request_id, instead of a hardcoded
    # "check proxy/token" message (PAXEL-CLIENT-17). Mirrors PipelineCircuitBroken.
    attr_reader :original_error

    def initialize(message, original_error: nil)
      super(message)
      @original_error = original_error
    end
  end

  # Benign, expected outcome: discovery + chunking ran but no session ended up
  # analyzable (all `too_short` / `no_transcript`). The host script already
  # pre-skips repos with *zero* sessions (upload_script.text.erb:~4147), so this
  # only fires when a repo HAD sessions but they were too short — common in
  # `--all` runs across many short-session repos. NOT a failure: the run! rescue
  # suppresses the Sentry capture for this class (it carried zero actionable
  # signal — issue PAXEL-CLIENT-T was 6 of these from one `--all` run), and the
  # rake entrypoint exits EXIT_NO_ANALYZABLE_SESSIONS so the host shows a
  # friendly "skipping" line instead of "Analysis failed, email support".
  class NoAnalyzableSessions < StandardError; end

  # Container exit code the rake entrypoint (lib/tasks/analyze_local.rake) uses
  # to signal NoAnalyzableSessions to the host upload script. Kept in sync with
  # the literal `3` in upload_script.text.erb's run_docker_analysis by
  # cross-reference comment only (no automated guard). Distinct from 1 (generic
  # failure) and 2 (token reauth) already used by the host contract.
  EXIT_NO_ANALYZABLE_SESSIONS = 3
  # Analysis finished but the results upload to the server failed (non-fatal — a failed
  # upload used to be logged as a ⚠ yet the run still exited 0, so the user saw "Upload
  # complete!" with nothing at /reports — PAXEL: wadoodabdul). Two distinct codes so the
  # host script's message matches reality:
  #   4 = the upload was stashed for replay (transient 5xx/429/network, complete
  #       payload) — the next run auto-replays it, so "saved locally, will auto-upload".
  #   5 = the upload failed with NO replay artifact (permanent 4xx, an unwritable stash,
  #       or a payload that can't replay) — nothing to auto-retry, so "re-run to retry".
  EXIT_UPLOAD_DEFERRED = 4
  EXIT_UPLOAD_FAILED = 5

  NONCE_PATTERN = /<!-- yc_verify:([^:]+):([^\ ]+) -->/.freeze
  # Upper bound on the combined numstat shipped for an `--all` aggregate upload.
  # Velocity is computed over the full union first; only the serialized payload is
  # capped (to the newest commits by date) so a many-repo union doesn't dwarf a
  # single-project payload. See collect_git_data_aggregate.
  AGGREGATE_NUMSTAT_CAP = 2_000
  # Positive-integer env parse that falls back to default on blank or
  # non-numeric values. Raw .to_i returns 0 for "abc" / "" — 0 threads = no
  # work happens, a silent showstopper.
  def self.positive_env_int(var, default)
    raw = ENV[var].to_s.strip
    val = Integer(raw, 10) rescue nil
    val && val > 0 ? val : default
  end
  # Set via PAXEL_NARRATIVE_CONCURRENCY for dev tuning. Default 20 is the
  # published-safe value; the LLM proxy and Anthropic rate limits both impose
  # upstream throttling, so bumping past 40 usually saturates against those
  # rather than helping latency.
  MAX_NARRATIVE_CONCURRENCY = positive_env_int("PAXEL_NARRATIVE_CONCURRENCY", 20)
  # CIRCUIT_BREAKER_THRESHOLD lives in the `PipelineCircuitBreaker` concern
  # (included above). `ClientPipeline::CIRCUIT_BREAKER_THRESHOLD` still
  # resolves through the ancestor chain — verified by
  # `client_pipeline_spec.rb:343` which references it externally.

  attr_reader :upload, :results, :upload_deferred, :upload_failed

  def initialize(transcript_dir:, results_endpoint: nil, token: nil, logger: nil, verbose: false)
    @transcript_dir = transcript_dir
    @results_endpoint = results_endpoint || ENV["YC_RESULTS_ENDPOINT"]
    @token = token || ENV["YC_TOKEN"]
    @log = logger || ->(msg) { puts msg }
    @verbose = verbose
    @upload_deferred = false
    @upload_failed = false
    @upload_stashed = false
    @nonces = Concurrent::Array.new
    # Eager init — extract_nonces_from runs on MAX_NARRATIVE_CONCURRENCY threads,
    # so `||=` would race: two threads see nil, each create their own
    # AtomicFixnum, one side's increments get lost.
    @nonces_from_sessions = Concurrent::AtomicFixnum.new(0)
    @sessions_yielding_nonces = Concurrent::AtomicFixnum.new(0)
    @results = {}
  end

  def run!
    @pipeline_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @pipeline_start_time = Time.current
    # PAXEL_STEP_OFFSET lets the bash wrapper prepend its own preflight phases
    # (prereq check, sign-in, image pull) so the user sees one continuous
    # [Step N/total] counter instead of two disjoint ones.
    step_offset = self.class.positive_env_int("PAXEL_STEP_OFFSET", 0)
    @step_number = step_offset
    @total_steps = STEP_WEIGHTS.size + step_offset
    @completed_weights = 0.0
    @total_weight = STEP_WEIGHTS.values.sum.to_f

    # Reset once per pipeline; per-step hit rates are reported via deltas so
    # steps 11/12/14 don't mix with step 7's counts.
    LlmResultCache.reset_stats! if LlmResultCache.available?

    validate_prerequisites!

    # Reuse or create Upload record for incremental analysis
    @upload = Upload.where(source: "client_pipeline").order(created_at: :desc).first
    if @upload
      log "  Upload: #{@upload.slug} (incremental)"
      @upload.update!(status: "extracting")
    else
      @upload = Upload.create!(
        slug: SecureRandom.alphanumeric(8).downcase,
        status: "extracting",
        source: "client_pipeline"
      )
      log "  Upload: #{@upload.slug}"
    end

    # Discover projects and sessions (incremental — skips unchanged files)
    run_step("Discovering projects and sessions") do
      @upload.update!(status: "parsing")
      # Debug-only: sidecar presence for scatter diagnosis. Never user-facing.
      sidecar_path = File.join(@transcript_dir, "_metadata.json")
      Rails.logger.debug do
        if File.exist?(sidecar_path)
          parsed = JSON.parse(File.read(sidecar_path)) rescue nil
          dir_count = parsed&.dig("directories")&.size || 0
          with_remote = parsed&.dig("directories")&.count { |_, v| v["git_remote"].to_s != "" } || 0
          "[ClientPipeline] Sidecar: #{dir_count} dirs, #{with_remote} with git_remote"
        else
          "[ClientPipeline] Sidecar: NOT FOUND at #{sidecar_path} (Projects will scatter)"
        end
      end
      TranscriptDiscoverer.new(@upload, @transcript_dir).discover!
      project_count = @upload.projects.count
      total_sessions = @upload.projects.sum { |p| p.transcript_sessions.count }
      pending_sessions = @upload.projects.sum { |p| p.transcript_sessions.where(status: "pending").count }
      # Debug: per-project breakdown
      debug_section("Project Details (#{project_count} projects)", @upload.projects.map { |p|
        sessions = p.transcript_sessions
        agents = sessions.group(:agent_type).count
        "#{p.display_name || p.encoded_name}  sessions=#{sessions.count}  pending=#{sessions.where(status: 'pending').count}  agents=#{agents.map { |k, v| "#{k || 'unknown'}:#{v}" }.join(',')}"
      })

      # Per-project breakdown. Precompute counts once (was N+1 via repeated
      # transcript_sessions.count), then cap stdout at the top TOP_N projects by
      # total session volume and collapse the tail into one summary line. Full
      # breakdown remains in debug_section above for file logs.
      project_rollups = @upload.projects.map do |p|
        name = p.display_name || p.encoded_name
        sessions = p.transcript_sessions
        # Cross-tool children (Codex sessions launched by Claude Code) join
        # subagents in the "M" bucket so users see honest counts of what they
        # invoked themselves vs. what was triggered automatically.
        main_count = sessions.merge(TranscriptSession.logical_roots).count
        sub_count = sessions.merge(TranscriptSession.non_logical_roots).count
        {
          name: name,
          encoded_name: p.encoded_name,
          main_count: main_count,
          sub_count: sub_count,
          total: main_count + sub_count
        }
      end.sort_by { |r| -r[:total] }

      main_total = project_rollups.sum { |r| r[:main_count] }
      sub_total = project_rollups.sum { |r| r[:sub_count] }

      top_n = 15
      shown = project_rollups.first(top_n)
      tail = project_rollups.drop(top_n)

      # Disambiguate collisions (e.g. many workspaces collapsing to "v1") by
      # appending the last 2 encoded_name segments only for names that repeat
      # among the shown rows.
      name_counts = shown.each_with_object(Hash.new(0)) { |r, h| h[r[:name]] += 1 }
      shown.each do |r|
        display = r[:name]
        if name_counts[r[:name]] > 1 && r[:encoded_name].present?
          hint = r[:encoded_name].split("-").reject(&:empty?).last(2).join("-")
          display = "#{display} (#{hint})" unless hint == r[:name]
        end
        parts = [ "#{r[:main_count]} main" ]
        parts << "#{r[:sub_count]} subagent" if r[:sub_count] > 0
        log "  #{display}: #{parts.join(', ')}"
      end

      if tail.any?
        tail_main = tail.sum { |r| r[:main_count] }
        tail_sub = tail.sum { |r| r[:sub_count] }
        tail_parts = [ "#{tail_main} main" ]
        tail_parts << "#{tail_sub} subagent" if tail_sub > 0
        log "  + #{tail.size} more projects: #{tail_parts.join(', ')}"
      end

      project_label = project_count == 1 ? "1 project" : "#{project_count} projects"
      # Show the TOTAL session count, then the main/subagent split, so this line
      # is unambiguous AND uses the same "(N main + M subagent)" vocabulary as the
      # Parsing step below. "main" = logical_roots (sessions you started yourself);
      # "subagent" = non_logical_roots (Claude subagents + cross-tool children).
      shown_total = main_total + sub_total
      summary = "#{project_label}, #{shown_total} #{"session".pluralize(shown_total)}"
      summary += " (#{main_total} main + #{sub_total} subagent)" if sub_total > 0
      summary += " (#{pending_sessions} new/modified)" if pending_sessions < total_sessions
      summary
    end

    # Collect git data from host-provided _git/ directory
    run_step("Reading your git history") do
      collect_git_data
    end

    # Chunk all pending sessions (mains + subagents). Previously subagents were
    # skipped up front with status: too_short so their sidechain-only content
    # couldn't pollute narratives. Post PR #597 the chunker processes subagent
    # JSONLs correctly (keeps isSidechain entries for is_subagent=true rows),
    # so we pass them through the same chunk + analyze path. Orchestrator
    # scoring needs subagent rows with narratives + git_commit events to
    # populate dispatch_with_committed_return_count. Short subagents still
    # mark too_short via the normal MIN_CHUNK_TOKENS gate.
    pending_total = @upload.projects.sum { |p| p.transcript_sessions.where(status: "pending").count }
    # Split the SAME way the Discovering step does — logical_roots (sessions you
    # started yourself) vs non_logical_roots (subagents + cross-tool children) —
    # so the "N main + M subagent" counts are consistent across the two steps.
    # is_subagent alone would reclassify cross-tool children (is_subagent=false
    # but triggered_by_id set) as "main" here, contradicting the Discovering line.
    pending_main = @upload.projects.sum { |p| p.transcript_sessions.where(status: "pending").merge(TranscriptSession.logical_roots).count }
    pending_sub = pending_total - pending_main
    if pending_total > 0
      chunked_before = @upload.projects.sum { |p| p.transcript_sessions.where(status: "chunked").count }
      short_before = @upload.projects.sum { |p| p.transcript_sessions.where(status: "too_short").count }
      no_file_before = @upload.projects.sum { |p| p.transcript_sessions.where(status: "no_transcript").count }
      run_step("Parsing transcripts") do
        chunk_sessions_with_progress
        newly_chunked = @upload.projects.sum { |p| p.transcript_sessions.where(status: "chunked").count } - chunked_before
        newly_short = @upload.projects.sum { |p| p.transcript_sessions.where(status: "too_short").count } - short_before
        no_file = @upload.projects.sum { |p| p.transcript_sessions.where(status: "no_transcript").count } - no_file_before
        parts = [ "#{newly_chunked} analyzable" ]
        parts << "#{newly_short} too short" if newly_short > 0
        parts << "#{no_file} no transcript file" if no_file > 0
        suffix = pending_sub > 0 ? " (#{pending_main} main + #{pending_sub} subagent)" : ""
        "#{pending_total} sessions parsed#{suffix} (#{parts.join(', ')})"
      end
    else
      skip_step("Parsing transcripts")
      log "✓ Parsing transcripts: all sessions up to date (skipped)"
    end

    analyzable = @upload.projects.flat_map { |p| p.transcript_sessions.where(status: "chunked") }
    # total_sessions_count is the denominator for user-facing framing
    # (V3NarrativeAggregator, ChatContextBuilder, SessionCountFramer,
    # BuilderInsightsService) and is logical-roots-only — sessions the
    # user invoked themselves, excluding both Claude internal subagents
    # AND cross-tool children (Codex sessions launched by Claude Code).
    # subagent_sessions_count tracks the rest (semantic shift 2026-04-26:
    # column now means "non-logical-roots", which includes cross-tool children).
    # remaining_sessions_count stays at full analyzable count because
    # AnalyzeSessionJob fires once per analyzable session — gate denominator
    # is "all work" while user-facing count is "what you did yourself".
    analyzable_main, analyzable_sub = analyzable.partition { |s| !s.is_subagent && s.triggered_by_id.nil? }
    @upload.update!(
      status: "analyzing",
      total_sessions_count: analyzable_main.size,
      subagent_sessions_count: analyzable_sub.size,
      remaining_sessions_count: analyzable.size
    )

    if analyzable.empty?
      @upload.update!(status: "failed", error_message: "No analyzable sessions found")
      # Typed (not bare RuntimeError) so the rescue below can suppress the Sentry
      # capture and the rake entrypoint can exit with a benign-skip code. See
      # NoAnalyzableSessions.
      raise NoAnalyzableSessions, "No analyzable sessions found in #{@transcript_dir}"
    end

    # Preflight LLM check
    preflight_llm_check!

    # Session narratives (LLM via proxy, with persistent cache)
    run_step("Summarizing each session [#{cloud_model_label(AnthropicClient::MODELS[:quality])}]") do
      result = with_cache_stats("SessionNarrativeAnalyzer", "SessionNarrativeAnalyzer:multi") do
        analyze_sessions(analyzable)
      end
      result
    end

    # Group commits so EpisodeLinker can classify episode types
    run_step("Grouping git commits by session") do
      count = 0
      @upload.projects.each do |project|
        next unless project.recent_commits.present?
        CommitGrouper.group!(project)
        count += project.commit_groups.count
      end
      "#{count} commit groups"
    end

    # Episode construction (deterministic)
    run_step("Grouping sessions into multi-day work streams") do
      count = EpisodeLinker.link!(@upload)
      "#{count} work streams"
    end

    # Steering traces (deterministic)
    run_step("Extracting steering traces") do
      count = SteeringTraceExtractor.extract!(@upload)
      "#{count} sessions traced"
    end

    # Decision intelligence (non-fatal — upload still works without it)
    decision_steps_total = 3
    decision_steps_started = 0
    begin
      @upload.projects.each do |project|
        next if project.repository.present?
        remote = project.git_remote.presence || "local://#{project.encoded_name}"
        project.update!(repository: Repository.find_or_create_for(remote))
      end

      decision_steps_started += 1
      run_step("Extracting decision exchanges [#{cloud_model_label(DecisionClassifier::MODEL)}]") do
        main_sessions = @upload.projects.flat_map { |p| p.transcript_sessions.main_sessions.to_a }
        step_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        count = with_cache_stats("DecisionClassifier") do
          DecisionExchangeExtractor.extract!(@upload, skip_embedding: true, heartbeat: false) do |done, total, session|
            log_item_progress(done, total, step_start, session_blurb(session))
          end
        end

        # Debug: decision classification breakdown
        all_decisions = @upload.decisions.reload
        if all_decisions.any?
          by_type = all_decisions.group(:decision_type).count
          by_proposal = all_decisions.group(:proposal_type).count
          debug_section("Decision Details", [
            "Total: #{all_decisions.count}",
            "By type: #{by_type.map { |k, v| "#{k || 'unclassified'}=#{v}" }.join(', ')}",
            "By proposal: #{by_proposal.map { |k, v| "#{k}=#{v}" }.join(', ')}"
          ])
        end

        "#{count} decisions"
      end

      # Regex-redact decision text before upload (runs here, not during packaging)
      decision_steps_started += 1
      run_step("Redacting code before upload") do
        decisions = @upload.decisions.reload.to_a
        if decisions.any?
          raw_texts = decisions.map { |d| { proposal: d.proposal_text, response: d.response_text } }
          step_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          redacted_texts = with_cache_stats("DecisionTextRedactor") do
            DecisionTextRedactor.redact_batch(raw_texts) do |done, total|
              log_item_progress(done, total, step_start)
            end
          end
          decisions.each_with_index do |d, i|
            d.update_columns(
              redacted_proposal_text: redacted_texts[i][:proposal],
              redacted_response_text: redacted_texts[i][:response]
            )
          end
          "#{decisions.size} decisions redacted"
        else
          "no decisions to redact"
        end
      end

      decision_steps_started += 1
      run_step("Linking decisions to outcomes") do
        count = InSessionAnalyzer.analyze!(@upload)
        "#{count} outcomes"
      end
      @dig_status = "extracted"
    rescue => e
      if defined?(Sentry) && Sentry.initialized?
        Sentry.capture_exception(e, level: :warning, tags: sentry_pipeline_tags(stage: "decision_intelligence"))
      end
      remaining_decision_steps = decision_steps_total - decision_steps_started
      @total_steps -= remaining_decision_steps if remaining_decision_steps.positive?
      log "✗ Decision intelligence failed (non-fatal): #{e.class}: #{e.message}"
      @dig_status = "skipped: #{e.class}"
    end

    # Code quality analysis (non-fatal — works without repo mount)
    begin
      run_step("Analyzing code quality") do
        step_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @code_quality = LocalCodeQualityAnalyzer.analyze do |done, total, detail|
          log_item_progress(done, total, step_start, detail)
        end
        # Debug: code quality details
        if @code_quality[:status] == "complete"
          dims = @code_quality[:dimensions]&.keys || []
          debug_section("Code Quality Details", [
            "Status: #{@code_quality[:status]}",
            "Files analyzed: #{@code_quality[:file_count]}",
            "Dimensions: #{dims.join(', ')}"
          ])
        end

        if @code_quality[:status] == "complete"
          "#{@code_quality[:file_count]} files, #{@code_quality[:dimensions]&.keys&.size} dimensions"
        else
          @code_quality[:status]
        end
      end
    rescue => e
      if defined?(Sentry) && Sentry.initialized?
        Sentry.capture_exception(e, level: :warning, tags: sentry_pipeline_tags(stage: "code_quality"))
      end
      log "✗ Code quality analysis failed (non-fatal): #{e.class}: #{e.message}"
      @code_quality = { status: "error", error: e.message }
    end

    # Episode summarization (LLM via proxy)
    episodes = @upload.episodes.reload
    episode_summaries = []
    if episodes.any?
      run_step("Scoring episodes across 5 axes [#{cloud_model_label(AnthropicClient::MODELS[:fast])}]") do
        step_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        scoring_result = EpisodeSummarizer.new(@upload).summarize(episodes, heartbeat: false) do |n, total, title|
          # title is usually the LLM-generated episode title, but falls back to
          # the raw first_prompt when scoring fails (episode_summarizer.rb) —
          # sanitize it (scrub + single-line) like the other blurbs.
          log_item_progress(n, total, step_start, sanitize_blurb(title).truncate(50))
        end
        episode_summaries = scoring_result.results
        stats = scoring_result.stats

        # Debug: per-episode scoring details (only freshly scored, not DB-cached)
        ep_token_lines = episode_summaries.filter_map { |es|
          next unless es["input_tokens"]
          retries_info = es["retries"].to_i > 0 ? "  retries=#{es['retries']}" : ""
          "#{es['episode_id'].to_s[0..7]}  in=#{es['input_tokens']}  out=#{es['output_tokens']}#{retries_info}  title=#{es['title'].to_s.truncate(40)}"
        }
        if ep_token_lines.any?
          total_in = episode_summaries.sum { |es| es["input_tokens"].to_i }
          total_out = episode_summaries.sum { |es| es["output_tokens"].to_i }
          retry_eps = episode_summaries.count { |es| es["retries"].to_i > 0 }
          ep_token_lines << "TOTAL: in=#{total_in}  out=#{total_out}  episodes_with_retries=#{retry_eps}"
          debug_section("Episode Scoring Token Usage (#{episode_summaries.size} episodes)", ep_token_lines)
        end

        # Build status line with breakdown
        parts = [ "#{stats[:scored]} scored" ]
        parts << "#{stats[:skipped_no_evidence]} skipped (no evidence)" if stats[:skipped_no_evidence] > 0
        parts << "#{stats[:failed_no_json]} failed (no JSON)" if stats[:failed_no_json] > 0
        parts << "#{stats[:failed_api]} failed (API)" if stats[:failed_api] > 0
        "#{parts.join(', ')} (#{stats[:total]} total work streams)"
      end

      if episode_summaries.empty? && episodes.any? && stats[:skipped_no_evidence] < stats[:total]
        raise PipelineNoResults, "All #{episodes.size} episode scores failed."
      end
    else
      skip_step("Scoring episodes across 5 axes")
      log "✓ Scoring episodes across 5 axes: no work streams to score (skipped)"
    end

    # Package results
    # If no new episodes were scored (all cached), load existing scores from DB.
    # EpisodeSummarizer persists scores to episode.scores after each run.
    if episode_summaries.empty? && @upload.episodes.any?
      episode_summaries = @upload.episodes.select { |ep| ep.scores.present? }.map do |ep|
        {
          "episode_id" => ep.id.to_s,
          "title" => ep.title,
          "type" => ep.episode_type,
          "scores" => ep.scores,
          "confidence" => ep.confidence
        }
      end
    end

    run_step("Assembling your report") do
      @results = package_results(
        episode_summaries: episode_summaries,
        session_count: analyzable.count { |s| !s.is_subagent && s.triggered_by_id.nil? }
      )
      @upload.update!(status: "complete")
      "#{@nonces.size} nonces"
    end

    # Upload to server (if configured, non-fatal)
    unless @results_endpoint.present? && @token.present?
      skip_step("Uploading results")
    end
    if @results_endpoint.present? && @token.present?
      upload_result = nil
      run_step("Uploading results") do
        upload_result = upload_results!
        handle_upload_result(upload_result)
      end
      record_upload_outcome(upload_result)
    end

    # Debug: final step timings summary
    debug_section("Step Timings", (@step_timings || []).map { |t|
      status_icon = t[:status] == "ok" ? "✓" : "✗"
      line = "#{status_icon} #{t[:duration_s].to_s.rjust(6)}s  #{t[:step]}"
      line += "  ERROR: #{t[:error]}" if t[:error]
      line
    })

    @results
  rescue => e
    # sentry-ruby 6.5.0 tracks captured exception objects; the outer rake
    # rescue also captures and will be deduped. Keeping both = defense-in-depth
    # for any future direct caller of this service.
    # NoAnalyzableSessions is an expected, benign outcome (sessions present but
    # all too short to analyze) — carries zero actionable signal, so it never
    # reaches Sentry. The upload is still marked failed below + re-raised; only
    # the capture is suppressed. The rake entrypoint turns it into a friendly
    # host-side "skipping" line. (issue PAXEL-CLIENT-T)
    if defined?(Sentry) && Sentry.initialized? && !e.is_a?(NoAnalyzableSessions)
      # Breaker-scoped tags: the session id that tripped the breaker flows
      # from `PipelineCircuitBroken#session_id` into the Sentry event so YC
      # admins can click through to the specific upload + session. We also
      # pull request_id/proxy_code/http_status from the wrapped
      # PaxelLlmError (PipelineCircuitBroken#original_error) so client-side
      # events link back to the proxy Sentry project even when Ruby's
      # `.cause` is empty (the breaker is raised outside any rescue).
      src_llm = e.respond_to?(:original_error) && e.original_error.is_a?(PaxelLlmError::Base) ? e.original_error : nil
      tags = sentry_pipeline_tags(
        stage: "client_pipeline_fatal",
        session_id: (e.respond_to?(:session_id) ? e.session_id : nil),
        request_id: src_llm&.request_id,
        proxy_code: src_llm&.proxy_code,
        http_status: src_llm&.http_status,
        **sentry_llm_error_tags(src_llm),
      )
      extra = sentry_llm_error_extra(src_llm)
      Sentry.capture_exception(e, tags: tags, extra: extra)
    end
    src_llm_for_store = e.respond_to?(:original_error) && e.original_error.is_a?(PaxelLlmError::Base) ? e.original_error : nil
    # e.message can be a raw (non-PaxelLlmError) exception string; scrub
    # credentials before it lands in error_message (shown on the results page +
    # to admins). body_preview is already scrubbed at PaxelLlmError construction.
    safe_message = scrub_secret_text(e.message.to_s)
    stored_msg = if src_llm_for_store&.body_preview
      "#{safe_message}\n\nResponse body: #{src_llm_for_store.body_preview}".truncate(500)
    else
      safe_message.truncate(500)
    end
    @upload&.update(status: "failed", error_message: stored_msg)
    raise
  end

  private

  # Common Sentry tags for every client-pipeline capture. Callers may add
  # stage-specific tags via keyword args. `upload_slug` is always included
  # when available so YC admins can filter/click through to the user; other
  # correlation tags (`session_id`, `request_id`) are set by callers at the
  # specific point in the pipeline where those are known.
  def sentry_pipeline_tags(**extra)
    { upload_slug: @upload&.slug }.compact.merge(extra.compact)
  end

  # Low-cardinality tags + full-text extra for an PaxelLlmError, so YC admins
  # can pivot by content-type / "does the error carry a body" in Sentry while
  # the full scrubbed preview lives in event.extra (no 200-char tag cap).
  # Nil-safe; empty hashes when err is not an PaxelLlmError::Base.
  def sentry_llm_error_tags(err)
    return {} unless err.is_a?(PaxelLlmError::Base)
    {
      response_content_type: err.response_content_type,
      body_preview_present:  err.body_preview ? "1" : "0"
    }.compact
  end

  def sentry_llm_error_extra(err)
    return {} unless err.is_a?(PaxelLlmError::Base) && err.body_preview
    { response_body_preview: err.body_preview }
  end

  # Label a step with the model it actually calls. Pass the model string
  # for that step — do NOT share one label across steps: the pipeline runs
  # Haiku (episodes, decisions) AND Sonnet (session narratives), so a
  # single label misreports two of the three cloud steps.
  def cloud_model_label(model)
    # Strip the reasoning-effort suffix (e.g. "gpt-5.5-none") — the effort level
    # is an internal routing detail, not something the user needs in a step label.
    "cloud: #{model.to_s.sub(/-(none|low|medium|high|xhigh)\z/, '')}"
  end

  def preflight_llm_check!
    proxy_url = ENV["YC_LLM_PROXY_URL"]
    unless proxy_url.present?
      log "  LLM proxy: no proxy URL configured, using direct Anthropic API"
      return
    end

    log "  Checking LLM proxy connection..."
    # Hit the proxy's /health endpoint — avoids system prompt/signature/model validation.
    # Checks what we actually need: proxy is running + signatures are loaded.
    # During a proxy deploy we may see a mix of:
    #   (a) HTTP 503 with body["status"]=="draining" — proxy handler's
    #       deliberate response so preflight callers back off (per proxy.ts)
    #   (b) Errno::ECONNREFUSED / ECONNRESET / ETIMEDOUT / SocketError —
    #       ALB-level connection reset in the narrow window between the
    #       draining task closing its listener and the fresh task's
    #       target-group health check turning green
    # Both are transient. Retry with backoff for either. Other non-2xx
    # responses are fatal on the first attempt; network errors after the
    # retry budget fall through to the method-level rescue that raises
    # PipelineAuthError("Cannot connect to LLM proxy…").
    health_url = URI.join(proxy_url.chomp("/").sub(%r{/v1/messages\z}, ""), "/health")
    response = nil
    body = {}
    max_attempts = 3
    transient_net_errors = [ Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
                             SocketError, Net::OpenTimeout, Net::ReadTimeout ]
    max_attempts.times do |attempt|
      begin
        http = Net::HTTP.new(health_url.host, health_url.port)
        http.use_ssl = (health_url.scheme == "https")
        http.open_timeout = 5
        http.read_timeout = 5
        response = http.get(health_url.request_uri)
        body = JSON.parse(response.body) rescue {}
      rescue *transient_net_errors => e
        # Network flap during proxy deploy. Retry if budget allows; otherwise
        # re-raise so the method-level rescue converts to PipelineAuthError.
        raise if attempt == max_attempts - 1
        wait = 2 * (attempt + 1)
        log "  LLM proxy unreachable (#{e.class.name.demodulize}); retrying in #{wait}s..."
        sleep(wait)
        next
      end

      break if response.is_a?(Net::HTTPSuccess)
      # 503 + status=="draining" = proxy rolling. Back off and retry; any
      # other non-2xx is fatal on the first attempt.
      draining = response.code.to_i == 503 && body["status"] == "draining"
      break unless draining && attempt < max_attempts - 1
      wait = 2 * (attempt + 1) # 2s, 4s
      log "  LLM proxy draining (deploy in progress); retrying in #{wait}s..."
      sleep(wait)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise PipelineAuthError,
        "LLM proxy health check failed (HTTP #{response.code}): #{response.body.to_s.truncate(200)}. " \
        "Is the proxy running at #{proxy_url}?"
    end

    unless body["signatures_loaded"]
      raise PipelineAuthError,
        "LLM proxy is running but has no signatures loaded. " \
        "The proxy needs to fetch signatures from the server first."
    end

    log "  LLM proxy: connected (signatures loaded)"

    # Validate the user's token before starting expensive LLM work
    token = ENV["YC_API_KEY"]
    if token.present?
      base_url = proxy_url.chomp("/").sub(%r{/v1/messages\z}, "")
      validate_url = URI.join(base_url, "/validate")
      val_http = Net::HTTP.new(validate_url.host, validate_url.port)
      val_http.use_ssl = (validate_url.scheme == "https")
      val_http.open_timeout = 5
      val_http.read_timeout = 10
      val_req = Net::HTTP::Post.new(validate_url.path)
      val_req["Content-Type"] = "application/json"
      val_req["x-api-key"] = token
      val_req["x-paxel-client-release"] = AnthropicClient.paxel_release
      # Retry transient network blips on /validate the same way the /health check
      # above does (2s/4s backoff). /validate triggers a Rails callback, so it is
      # the most timeout-prone preflight step; one slow round-trip should not kill
      # the whole upload (PAXEL-CLIENT-16).
      val_response = nil
      max_attempts.times do |attempt|
        begin
          val_response = val_http.request(val_req)
        rescue *transient_net_errors => e
          raise if attempt == max_attempts - 1
          wait = 2 * (attempt + 1)
          log "  Token validation slow (#{e.class.name.demodulize}); retrying in #{wait}s..."
          sleep(wait)
          next
        end
        break
      end

      unless val_response.is_a?(Net::HTTPSuccess)
        val_body = JSON.parse(val_response.body) rescue {}
        reason = val_body["reason"]
        message = case reason
        when "expired" then "Your upload token has expired. Get a new upload command from your dashboard."
        when "revoked" then "Your upload token has been revoked. Get a new upload command from your dashboard."
        when "daily_cost_exceeded" then "Daily usage limit reached. Try again tomorrow."
        when "daily_calls_exceeded" then "Daily call limit reached. Try again tomorrow."
        when "exhausted" then "This token has reached its maximum usage. Get a new upload command."
        when "proxy_exhausted" then "This token has reached its proxy call limit. Get a new upload command."
        when "not_found" then "Token not recognized. Get a new upload command from your dashboard."
        when "validation_unavailable" then "Token validation service is temporarily unavailable. Try again in a moment."
        else "Token validation failed. Try a new upload command from your dashboard."
        end
        raise PipelineAuthError, message
      end
      log "  LLM proxy: token validated"

      # Contract-version handshake (PR #674): verify the client's prompt
      # signatures match the server's current-allowed set BEFORE any
      # narrative/scoring calls. On drift, fail cleanly in ~200ms instead of
      # burning 10 narrative calls against the circuit breaker. 404/network
      # errors fall through without blocking (old server / new client). See
      # AnthropicClient.preflight_signatures! for the full branch table.
      AnthropicClient.preflight_signatures!(
        base_url: base_url,
        token: token,
        logger: ->(msg) { log(msg) }
      )
    end
  rescue PaxelLlmError::ClientOutOfDate
    # Let the rake-task footer format the "What happened / What to do" block.
    # Don't wrap in PipelineAuthError — that would drop the contract hashes.
    raise
  rescue PipelineAuthError
    raise
  rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ETIMEDOUT => e
    # A timeout means the proxy was reachable but slow (busy / deploying), not
    # down — don't tell the user "Is the proxy running?" (PAXEL-CLIENT-16).
    raise PipelineAuthError,
      "LLM proxy at #{proxy_url} did not respond in time (#{e.class.name.demodulize}). " \
      "It is likely temporarily busy or deploying — re-run in a moment."
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError => e
    raise PipelineAuthError,
      "Cannot connect to LLM proxy at #{proxy_url}: #{e.message}. Is the proxy running?"
  rescue => e
    log "  LLM proxy warning: #{e.class} — #{e.message}. Continuing anyway (may be transient)."
  end

  def validate_prerequisites!
    unless Dir.exist?(@transcript_dir)
      raise "Transcript directory not found: #{@transcript_dir}"
    end

    jsonl_files = Dir.glob(File.join(@transcript_dir, "**", "*.jsonl"))
    if jsonl_files.empty?
      raise "No JSONL files found in #{@transcript_dir}"
    end

    log "  Found #{jsonl_files.size} JSONL files"
  end

  # Weights for overall progress bar ETA. Calibrated from aggregated step
  # timings across 44 production uploads (2026-03/04). 1 weight ≈ 30s typical.
  #
  # NOTE: insertion order here does NOT match run_step call order in run!.
  # User-visible [Step N/total] numbers follow call order, not this hash.
  # Example: "Grouping git commits" is #3 here but the 5th run_step call.
  # Don't build docs or UI off STEP_WEIGHTS.keys — walk run! or grep run_step.
  STEP_WEIGHTS = {
    "Discovering projects and sessions" => 1,
    "Reading your git history" => 1,
    "Grouping git commits by session" => 1,
    "Parsing transcripts" => 3,
    "Summarizing each session" => 6,
    "Grouping sessions into multi-day work streams" => 1,
    "Extracting steering traces" => 1,
    "Extracting decision exchanges" => 20,
    "Redacting code before upload" => 15,
    "Linking decisions to outcomes" => 1,
    "Analyzing code quality" => 5,
    "Scoring episodes across 5 axes" => 8,
    "Assembling your report" => 1,
    "Uploading results" => 1
  }.freeze

  # Braille spinner + sub-cell block ramp for the TTY progress footer.
  # PARTIAL_BLOCKS[0] is unused (empty); 1..7 are eighth-width left blocks so
  # the overall bar fills smoothly between full █ cells.
  SPINNER_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".chars.freeze
  PARTIAL_BLOCKS = [ "", "▏", "▎", "▍", "▌", "▋", "▊", "▉" ].freeze

  # Run a named step with timing and consistent formatting.
  #
  # TTY: the current step and live progress bars render in a sticky footer
  # (PipelineLogger#set_footer); only the ✓/✗ completion line scrolls into the
  # permanent log above it. Non-TTY: ▶ start + ✓/✗ end lines plus → progress to
  # stderr, exactly as before (CI, piped, or redirected output).
  def run_step(label)
    @step_number = (@step_number || 0) + 1
    @total_steps ||= STEP_WEIGHTS.size
    @total_weight ||= STEP_WEIGHTS.values.sum.to_f
    @completed_weights ||= 0.0
    @cur_step_label = label
    @cur_step_weight = STEP_WEIGHTS[step_base_name(label)] || 1
    @cur_item = nil
    @last_item_progress_at = nil
    @prev_progress_done = nil      # reset tail-aware ETA anchors per step
    @prev_progress_elapsed = nil
    if footer_enabled?
      refresh_progress_footer
    else
      log "▶ [Step #{@step_number}/#{@total_steps}] #{label}"
    end
    step_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    if defined?(Sentry) && Sentry.initialized?
      Sentry.add_breadcrumb(Sentry::Breadcrumb.new(category: "pipeline.step", message: label, level: "info"))
    end

    result = yield

    duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_start).round(1)
    icon = result.to_s.start_with?("upload failed") ? "⚠" : "✓"
    log "#{icon} [Step #{@step_number}/#{@total_steps}] #{label}: #{result} (#{format_duration_human(duration)})"
    emit_overall_eta(label)
    @upload&.log_step("client_pipeline", "#{label}: #{result}")
    record_step_timing(label, duration, "ok")
  rescue => e
    duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_start).round(1)
    if defined?(Sentry) && Sentry.initialized?
      Sentry.add_breadcrumb(Sentry::Breadcrumb.new(category: "pipeline.step", message: "#{label} failed: #{e.class}", level: "error"))
    end
    log "✗ #{label} FAILED: #{e.class}: #{e.message} (#{format_duration_human(duration)})"
    record_step_timing(label, duration, "error", "#{e.class}: #{e.message}")
    raise
  end

  def record_step_timing(label, duration, status, error = nil)
    @step_timings ||= []
    entry = { step: label, duration_s: duration, status: status }
    # step_timings ships in client_telemetry; the error is a raw exception
    # message — scrub credentials before it crosses the wire.
    entry[:error] = scrub_secret_text(error).truncate(200) if error
    @step_timings << entry
  end

  # Snapshots per-service cache counters around `yield` and logs the delta.
  # Use one call per step so hit rates don't get mixed across steps (step 7's
  # reset-then-summary pattern wiped counters that step 11/12/14 would have
  # needed).
  def with_cache_stats(*service_names)
    return yield unless LlmResultCache.available?

    before = service_names.to_h { |n| [ n, [ LlmResultCache.hits_for(n), LlmResultCache.misses_for(n) ] ] }
    yield
  ensure
    # ensure: still log partial deltas when the step raises, so we don't lose
    # visibility on "step failed after N cache hits" scenarios.
    if LlmResultCache.available? && before
      service_names.each do |name|
        h0, m0 = before[name]
        hits = LlmResultCache.hits_for(name) - h0
        misses = LlmResultCache.misses_for(name) - m0
        total = hits + misses
        next if total == 0
        pct = (hits * 100.0 / total).round(0)
        log "  Response cache [#{name}]: #{hits}/#{total} cache hits (#{pct}%)"
      end
    end
  end

  def chunk_sessions_with_progress
    total = 0
    done = 0
    step_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    total_filtered_commands = 0
    total_filtered_tool_only = 0

    sessions = []
    @upload.projects.find_each do |project|
      # Chunk mains AND subagents — subagent rows need chunks so narrative
      # analysis can run and produce content for ParallelismAnalyzer's
      # dispatch_with_committed_return detection (see PR #597 + followup).
      project.transcript_sessions.where(status: "pending").find_each do |ts|
        sessions << [ project, ts ]
      end
    end
    total = sessions.size

    no_jsonl = 0
    sessions.each do |project, ts|
      jsonl_path = find_jsonl(project, ts)
      unless jsonl_path
        ts.update!(status: "no_transcript")
        no_jsonl += 1
        next
      end
      chunker = TranscriptChunker.new(ts, jsonl_path, extract_dir: @transcript_dir)
      chunker.chunk!
      total_filtered_commands += chunker.filtered_local_commands_count
      total_filtered_tool_only += chunker.filtered_tool_only_count
      done += 1
      log_item_progress(done, total, step_start, "session #{ts.session_id[0..7]}") if @verbose
      log_item_progress(done, total, step_start) unless @verbose
    end

    debug("Chunking filters: #{total_filtered_commands} local commands removed, #{total_filtered_tool_only} tool-only turns removed")
    debug("#{no_jsonl} sessions had no transcript file on disk") if no_jsonl > 0

    # Debug: per-session details after chunking (only pending sessions, no extra queries)
    all_sessions = @upload.projects.flat_map { |p| p.transcript_sessions.where(status: "chunked").to_a }
    debug_section("Session Details (#{all_sessions.size} chunked)", all_sessions.map { |s|
      line = "#{s.session_id[0..7]}  msgs=#{s.message_count}  agent=#{s.agent_type || 'unknown'}  status=#{s.status}"
      line += "  subagent" if s.is_subagent
      line
    })
  end

  def find_jsonl(project, ts)
    search_dir = ts.source_dir.presence || project.encoded_name

    if ts.is_subagent && ts.parent_session_id
      parent_id = ts.parent_session.session_id
      candidates = Dir.glob(File.join(@transcript_dir, search_dir, parent_id, "subagents", "#{ts.session_id}.{jsonl,json}"))
      candidates.first
    else
      candidates = Dir.glob(File.join(@transcript_dir, search_dir, "**", "#{ts.session_id}.{jsonl,json}"))
      candidates.reject { |p| p.include?("/subagents/") || p.include?("/tool-results/") }.first
    end
  end

  def analyze_sessions(sessions)
    # Dual atomic counter: `completed` drives remaining_sessions_count
    # (gate denominator — every analyzable session decrements one), while
    # `logical_completed` drives analyzed_sessions_count (user-facing
    # ratio — only logical roots count toward "X of Y sessions analyzed"
    # because total_sessions_count is logical-roots-only). Without the
    # split, analyzed_sessions_count would exceed total_sessions_count
    # for cross-tool-heavy uploads and the progress bar would show >100%.
    completed = Concurrent::AtomicFixnum.new(0)
    logical_completed = Concurrent::AtomicFixnum.new(0)
    failed = Concurrent::AtomicFixnum.new(0)
    # Track content-filter rejections separately so an all-filtered run (every
    # session declined by the provider's safety filter) fails with the right
    # guidance instead of the generic "check proxy/token" PipelineNoResults.
    content_filtered = Concurrent::AtomicFixnum.new(0)
    # Last per-session LLM error, so an all-failed run can blame the real cause
    # (transient overload vs genuinely-unknown) instead of hardcoding
    # "check proxy/token" (PAXEL-CLIENT-17).
    last_error = Concurrent::AtomicReference.new(nil)
    # Disk-full is a global, unrecoverable environment condition (the SQLite write at
    # session.update! hits "database or disk is full" / ENOSPC). Flag it so the run
    # fails fast with a clear "out of disk space" message instead of N cryptic
    # per-session failures landing on the generic "check proxy/token" guidance — and
    # so the user isn't shown only the secondary "cannot rollback" symptom (PAXEL-CLIENT-2E).
    disk_full = Concurrent::AtomicBoolean.new(false)
    breaker = build_circuit_breaker(stage: "narrative")
    total = sessions.size
    step_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    progress_mutex = Mutex.new

    with_thread_pool(MAX_NARRATIVE_CONCURRENCY) do |executor|
      futures = sessions.map do |session|
        Concurrent::Promises.future_on(executor) do
          # Skip not-yet-started work once the breaker tripped OR the disk filled.
          # disk_full short-circuits immediately (don't wait for the breaker's
          # consecutive-failure threshold) so a full disk doesn't burn ~10 more
          # paid LLM calls whose session.update! can't possibly succeed.
          next if breaker.tripped? || disk_full.true?

          # Thread-local lets `AnthropicClient#call_llm` forward the session id
          # to the proxy via `x-paxel-session-id`, so proxy-side Sentry events
          # can tag the same session. Reset in the ensure at end of future.
          Thread.current[:paxel_session_id] = session.session_id
          analyzer = SessionNarrativeAnalyzer.new
          result = analyzer.analyze(session, session_label: session.session_id[0..7], heartbeat: false)
          session.update!(
            narrative: result[:narrative],
            narrative_status: result[:narrative].split.size < SessionNarrativeAnalyzer::MIN_QUALITY_WORDS ? "low_quality" : "complete",
            narrative_raw_response: result[:raw_response],
            narrative_input_tokens: result[:input_tokens],
            narrative_output_tokens: result[:output_tokens],
            narrative_model: result[:model],
            narrative_completed_at: Time.current,
            session_intent: result[:session_intent]
          )
          extract_nonces_from(session)
          breaker.success!
          is_logical_root = !session.is_subagent && session.triggered_by_id.nil?
          logical_completed.increment if is_logical_root
          c = completed.increment
          begin
            progress_mutex.synchronize do
              # Read both atomics inside the mutex — guarantees we write
              # the latest observed values, not an out-of-order stale read
              # where a non-logical session captures lc=0 before a logical
              # session's increment lands and overwrites the higher value.
              lc = logical_completed.value
              done = [ c + failed.value, total ].min
              @upload.update!(
                analyzed_sessions_count: lc,
                remaining_sessions_count: [ total - c - failed.value, 0 ].max
              )
              # Show the session's own first prompt live (like episode scoring
              # shows the episode title), regardless of verbose — it's the
              # "fun" signal of what's being summarized right now.
              log_item_progress(done, total, step_start, session_blurb(session))
            end
          rescue => progress_err
            debug("Progress update failed for #{session.session_id[0..7]}: #{progress_err.class} - #{progress_err.message.to_s.truncate(200)}")
          end
        rescue => e
          f = failed.increment
          disk_full.make_true if disk_full_error?(e)
          content_filtered.increment if defined?(PaxelLlmError) && e.is_a?(PaxelLlmError::ContentFiltered)
          last_error.set(e) if defined?(PaxelLlmError) && e.is_a?(PaxelLlmError::Base)
          # Trip logic — consecutive-count threshold or any PaxelLlmError::Fatal
          # — lives in `PipelineCircuitBreaker::Breaker#failure!` (shared with
          # EpisodeSummarizer). Fatal errors fail-fast because they won't
          # recover by retrying 9 more sessions.
          breaker.failure!(error: e, item_id: session.session_id, failed_count: f)
          # Per-session Sentry capture (at :warning so non-fatal retries
          # don't spam error-level). Tagged with session_id + upload_slug so
          # YC admins can correlate to the affected user and email them.
          # request_id threads the correlation through to the proxy
          # Sentry project when the error is an PaxelLlmError.
          if defined?(Sentry) && Sentry.initialized?
            Sentry.capture_exception(e, level: :warning,
              tags: sentry_pipeline_tags(
                stage: "narrative",
                session_id: session.session_id,
                request_id: (e.respond_to?(:request_id) ? e.request_id : nil),
                **sentry_llm_error_tags(e),
              ),
              extra: sentry_llm_error_extra(e))
          end
          progress_mutex.synchronize do
            # Always persist errors to log file for admin debugging
            debug("✗ #{session.session_id[0..7]}: #{e.class} - #{e.message.to_s.truncate(200)}")
            if @verbose
              progress_stderr("✗ #{session.session_id[0..7]}: #{e.class} - #{e.message.to_s.truncate(80)}")
            end
            log_item_progress([ completed.value + f, total ].min, total, step_start) unless @verbose
          end
        ensure
          Thread.current[:paxel_session_id] = nil
        end
      end
      futures.each { |f| f.wait!(360) }
    end

    # Disk-full supersedes the breaker/all-failed branches below — surface the real,
    # actionable cause (Sentry's secondary "cannot rollback - no transaction is active"
    # masks it). Fires whether the breaker tripped on consecutive disk-full failures
    # or only some writes failed before the disk filled.
    if disk_full.true?
      raise PipelineNoResults,
        "Out of disk space — the disk Docker uses for its working database filled up " \
        "mid-run. Free up space on that disk and re-run (cached work resumes)."
    end

    breaker.raise_if_tripped!(fallback_count: failed.value)

    if completed.value == 0 && total > 0
      # All-filtered run: every session was declined by the model provider's
      # content safety filter (usually security-research content). The proxy +
      # token are fine, so the generic "check proxy/token" message would
      # misdirect — give the content-filter guidance instead.
      if content_filtered.value.positive? && content_filtered.value == failed.value
        raise PipelineNoResults,
          "All #{total} sessions were declined by the model provider's content safety " \
          "filter — usually security-research content. Nothing could be analyzed. " \
          "If most of your work is security-related, email paxel@ycombinator.com."
      end
      le = last_error.get
      if defined?(PaxelLlmError) && le.is_a?(PaxelLlmError::Retryable)
        raise PipelineNoResults.new(
          "All #{total} narrative generations failed — the model provider was overloaded " \
          "or slow and retries were exhausted. This is usually transient; re-run the same command.",
          original_error: le)
      end
      # Genuinely-unknown failure (raw error, empty narrative, DB error, or a
      # Fatal that didn't trip the breaker): keep the generic guidance, but still
      # thread the error so the rake footer + Sentry can correlate (PAXEL-CLIENT-17).
      raise PipelineNoResults.new(
        "All #{total} narrative generations failed. " \
        "Check LLM proxy connection and token validity.",
        original_error: le)
    end

    # Debug: narrative analysis summary
    # `consecutive_failures` was part of the old local-variable breaker; the
    # debug line kept the tail-of-run value, which was only informational
    # (breaker already decided trip/no-trip above). Omitting it keeps the
    # refactor behavior-preserving elsewhere without leaking breaker state.
    debug("Narrative analysis: #{completed.value} ok, #{failed.value} failed")

    # Debug: per-session token usage (single batch query, no per-session reload)
    fresh_sessions = TranscriptSession.where(id: sessions.map(&:id))
      .where.not(narrative_input_tokens: nil)
      .select(:id, :session_id, :narrative_input_tokens, :narrative_output_tokens, :narrative_model, :narrative_status)
    token_lines = fresh_sessions.map { |s|
      "#{s.session_id[0..7]}  in=#{s.narrative_input_tokens}  out=#{s.narrative_output_tokens}  model=#{s.narrative_model}  status=#{s.narrative_status}"
    }
    total_in = fresh_sessions.sum(:narrative_input_tokens)
    total_out = fresh_sessions.sum(:narrative_output_tokens)
    token_lines << "TOTAL: in=#{total_in}  out=#{total_out}"
    debug_section("Narrative Token Usage (#{sessions.size} sessions)", token_lines)

    succeeded = completed.value
    failed_count = failed.value
    summary = "#{succeeded}/#{total} summaries"
    summary += " (#{failed_count} failed)" if failed_count > 0
    summary
  end

  # True when an error (or anything in its cause chain) is a disk-full / no-space
  # condition. SQLite raises SQLite3::FullException ("database or disk is full");
  # ActiveRecord wraps it in StatementInvalid with the real cause reachable via
  # #cause; a raw filesystem write raises Errno::ENOSPC. Walk the cause chain and
  # sniff the message so the wrapped form is caught too.
  def disk_full_error?(error)
    err = error
    while err
      return true if defined?(SQLite3::FullException) && err.is_a?(SQLite3::FullException)
      return true if err.is_a?(Errno::ENOSPC)

      msg = err.message.to_s
      return true if msg.include?("database or disk is full") || msg.include?("No space left on device")

      err = err.cause
    end
    false
  end

  # Read git data collected by the host bash script (Docker can't see host git repos).
  # Host writes _git/[encoded]_commits.jsonl and _git/[encoded]_numstat.txt.
  def collect_git_data
    # `--all` writes per-repo git into the bind-mounted sidecar (/paxel_sidecar/_git),
    # not @transcript_dir/_git. The report contract is single-project, so sum every
    # repo into one carrier (collect_git_data_aggregate). Gated on CLIENT_MODE so a
    # stray /paxel_sidecar on the Rails server can never trigger it.
    agg_dir = aggregate_git_dir
    if agg_dir && !File.directory?(File.join(@transcript_dir, "_git")) && File.directory?(agg_dir)
      return collect_git_data_aggregate(agg_dir)
    end

    git_dir = File.join(@transcript_dir, "_git")

    # Read _metadata.json for git_remote per project directory
    metadata_file = File.join(@transcript_dir, "_metadata.json")
    metadata = if File.exist?(metadata_file)
      JSON.parse(File.read(metadata_file)) rescue {}
    else
      {}
    end

    # Map project names to git_remotes from metadata
    dir_metadata = metadata.fetch("directories", {})

    return "no git data directory" unless File.directory?(git_dir) || dir_metadata.any?

    projects_updated = 0
    @upload.projects.each do |project|
      # Find git_remote from metadata (match by project name in directory path)
      dir_metadata.each do |dir_key, dir_info|
        if dir_key.include?(project.encoded_name) || dir_key.include?(project.display_name.to_s)
          remote = dir_info["git_remote"]
          project.git_remote = remote if remote.present? && project.git_remote.blank?
        end
      end

      encoded = project.encoded_name.gsub(/[^a-zA-Z0-9_-]/, "_")

      # Parse total repo commit count (from git rev-list --count HEAD)
      count_file = Dir.glob(File.join(git_dir, "*_commit_count.txt")).first ||
                   File.join(git_dir, "#{encoded}_commit_count.txt")
      if (count_content = safe_git_read(count_file))
        total_repo_commits = count_content.strip.to_i
        if total_repo_commits > 0
          project.git_metrics ||= {}
          project.git_metrics["total_repo_commits"] = total_repo_commits
        end
      end

      # Parse commits (TSV — see #parse_commits_tsv; the .jsonl name is historical).
      # `*_commits.jsonl` ALSO matches `*_author_commits.jsonl` (author-filtered), which
      # sorts first — exclude it so recent_commits is the team-wide log, not the subset.
      commits_file = Dir.glob(File.join(git_dir, "*_commits.jsonl"))
                        .reject { |f| f.end_with?("_author_commits.jsonl") }.first ||
                     File.join(git_dir, "#{encoded}_commits.jsonl")
      if (commits_content = safe_git_read(commits_file))
        commits = parse_commits_tsv(commits_content, source: "recent_commits")
        project.recent_commits = commits if commits.any?
      end

      # Parse numstat (reuse ProcessUploadJob's format). Same author-file glob
      # collision as commits above — exclude `*_author_numstat.txt` so total_commits
      # (= numstat.size) stays team-wide and consistent with recent_commits.
      numstat_file = Dir.glob(File.join(git_dir, "*_numstat.txt"))
                        .reject { |f| f.end_with?("_author_numstat.txt") }.first ||
                     File.join(git_dir, "#{encoded}_numstat.txt")
      if (numstat_content = safe_git_read(numstat_file))
        numstat = parse_numstat_file(numstat_content)
        if numstat.any?
          project.git_metrics ||= {}
          project.git_metrics["numstat"] = numstat
          project.git_metrics["total_commits"] = numstat.size
        end
      end

      # Parse author-filtered commits (for episode linking — wider date range)
      author_commits_path = File.join(git_dir, "#{encoded}_author_commits.jsonl")
      if (author_commits_content = safe_git_read(author_commits_path))
        author_commits = parse_commits_tsv(author_commits_content, source: "author_commits")
        project.author_recent_commits = author_commits if author_commits.any?
      end

      # Parse author-filtered numstat (for CommitGrouper LOC stats)
      author_numstat_path = File.join(git_dir, "#{encoded}_author_numstat.txt")
      if (author_numstat_content = safe_git_read(author_numstat_path))
        author_numstat = parse_numstat_file(author_numstat_content)
        if author_numstat.any?
          project.git_metrics ||= {}
          project.git_metrics["author_numstat"] = author_numstat
        end
      end

      # Compute velocity metrics from numstat (mirrors ProcessUploadJob)
      if project.git_metrics&.dig("numstat").present?
        velocity = VelocityMetricsService.compute(project)
        project.git_metrics["velocity"] = velocity if velocity.present?
      end

      project.save! if project.changed?
      projects_updated += 1 if project.recent_commits.present? || project.git_metrics&.dig("numstat").present?
    end

    "#{projects_updated} projects with git data"
  end

  # Parse a tab-separated commit log (sha, short, author, email, date, subject)
  # into recent_commits-shaped hashes. The upload script emits this format (subject
  # LAST) so a raw git %s subject containing a quote/backslash/control char can't
  # corrupt the line — the previous JSON-per-line format dropped those commits
  # silently via `rescue nil`, making total_commits (numstat) disagree with
  # recent_commits (audit C13). split with limit 6 keeps any stray tab inside the
  # subject. A line with <6 fields is genuinely malformed and counted as dropped;
  # when any are dropped we fail loud with a PII-free Sentry warning (no subject
  # text, only the count) instead of silently losing data.
  def parse_commits_tsv(content, source:)
    lines = content.to_s.each_line.map { |l| l.chomp }.reject { |l| l.strip.empty? }
    commits = lines.filter_map do |line|
      parts = line.split("\t", 6)
      next if parts.size < 6
      { "sha" => parts[0], "short" => parts[1], "author" => parts[2],
        "email" => parts[3], "date" => parts[4], "subject" => parts[5] }
    end
    dropped = lines.size - commits.size
    if dropped.positive? && defined?(Sentry) && Sentry.initialized?
      Sentry.capture_message(
        "client git commit parse dropped malformed line(s)",
        level: :warning,
        tags: sentry_pipeline_tags(stage: "git_commits_parse", source: source, dropped: dropped)
      )
    end
    commits
  end

  # Read a git-data file tolerantly. These files live under a bind-mounted
  # /transcripts (--all) or the archive sidecar, so one can vanish between
  # Dir.glob/File.exist? and the read (TOCTOU) or sit on an unreadable mount.
  # Git metrics are non-essential — a single missing/unreadable file must NOT sink
  # the whole upload (PAXEL-CLIENT-1N/1P: an unrescued IO.read ENOENT in
  # collect_git_data did exactly that). Returns nil; every caller skips on nil.
  def safe_git_read(path)
    # encoding: "UTF-8" + scrub: a numstat/commits file can carry a non-UTF-8
    # author name or filename, and the client Docker image has no locale
    # (default_external = ASCII-8BIT, under which scrub is a no-op), so a bare
    # File.read leaves invalid bytes that crash a later line.strip in
    # parse_numstat_file / parse_commits_tsv (Encoding::CompatibilityError) and
    # sink the whole upload (PAXEL-CLIENT-2H). Mirrors GeminiNormalizer#replay_records.
    File.read(path, encoding: "UTF-8").scrub
  rescue SystemCallError, IOError => e
    debug("collect_git_data: skipping unreadable git file #{File.basename(path.to_s)}: #{e.class}")
    nil
  end

  # Source dir for `--all` aggregate git data, bind-mounted read-only by the host.
  # Gated on CLIENT_MODE=1 (baked into Dockerfile.client) so a stray /paxel_sidecar
  # on the Rails server can never feed server-side uploads (mirrors
  # TranscriptDiscoverer#secondary_sidecar_path). A method so specs can stub it.
  def aggregate_git_dir
    return nil unless ENV["CLIENT_MODE"] == "1"
    "/paxel_sidecar/_git"
  end

  # `--all` aggregate: SUM every repo's git into one carrier project so the
  # single-project report contract carries the builder's total output across all
  # repos. Deliberately does NOT set recent_commits — CommitGrouper/EpisodeLinker
  # would otherwise cluster cross-repo commits by time and mislink them to
  # sessions in other repos (the linker has no repo check). Velocity is derived
  # from numstat alone, so the engineering-quality signal is preserved.
  def collect_git_data_aggregate(git_dir)
    numstat_files = Dir.glob(File.join(git_dir, "*_numstat.txt")).sort
    combined_numstat = {}
    numstat_files.each do |f|
      content = safe_git_read(f)
      next unless content
      repo_token = File.basename(f).sub(/_numstat\.txt\z/, "")
      parse_numstat_file(content).each do |sha, entry|
        # Namespace by repo so a fork + upstream sharing a sha don't collide.
        # VelocityMetricsService sums values, so the key shape is irrelevant.
        combined_numstat["#{repo_token}:#{sha}"] = entry
      end
    end

    return "no aggregate git data" if combined_numstat.empty?

    total_repo_commits = Dir.glob(File.join(git_dir, "*_commit_count.txt")).sum do |f|
      (safe_git_read(f) || "0").strip.to_i
    end
    repo_count = numstat_files.size

    carrier = @upload.projects.order(:id).first
    return "no project to carry aggregate git" unless carrier

    carrier.git_metrics ||= {}
    carrier.git_metrics["numstat"] = combined_numstat
    carrier.git_metrics["total_commits"] = combined_numstat.size
    carrier.git_metrics["total_repo_commits"] = total_repo_commits if total_repo_commits.positive?
    # Client-only flag (NOT in the package_results slice) so packaging ships a
    # neutral git_remote + aggregate project_name instead of one arbitrary repo's
    # identity (which would mis-register a Repository server-side).
    carrier.git_metrics["aggregate_repo_count"] = repo_count

    # Velocity over the FULL union, THEN cap the shipped numstat so a many-repo
    # union doesn't dwarf a single-project payload.
    velocity = VelocityMetricsService.compute(carrier)
    carrier.git_metrics["velocity"] = velocity if velocity.present?
    if combined_numstat.size > AGGREGATE_NUMSTAT_CAP
      carrier.git_metrics["numstat"] =
        combined_numstat.sort_by { |_sha, e| e["date"].to_s }.last(AGGREGATE_NUMSTAT_CAP).to_h
    end

    carrier.save! if carrier.changed?
    "aggregated git from #{repo_count} #{'repo'.pluralize(repo_count)} (#{combined_numstat.size} commits)"
  end

  # Parse numstat text in COMMIT_BOUNDARY format (same as ProcessUploadJob)
  def parse_numstat_file(content)
    numstat = {}
    current_sha = nil
    current_entry = nil

    content.each_line do |line|
      line = line.strip
      next if line.empty?

      if line.start_with?("COMMIT_BOUNDARY")
        rest = line.sub("COMMIT_BOUNDARY ", "")
        parts = rest.split(" ", 3)
        current_sha = parts[0]
        date = parts[1]
        author_part = parts[2] || ""

        if author_part =~ /\A(.+?)\s+<([^>]+)>\z/
          author = $1
          email = $2
        else
          author = author_part
          email = nil
        end

        current_entry = { "added" => 0, "deleted" => 0, "date" => date, "author" => author, "email" => email, "files" => [] }
        numstat[current_sha] = current_entry
      elsif current_entry && line =~ /\A(\d+|-)\t(\d+|-)\t(.+)\z/
        added = ($1 == "-" ? 0 : $1.to_i)
        deleted = ($2 == "-" ? 0 : $2.to_i)
        current_entry["added"] += added
        current_entry["deleted"] += deleted
        current_entry["files"] << { "file" => $3, "added" => added, "deleted" => deleted }
      end
    end

    numstat
  end

  def extract_nonces_from(session)
    text = session.narrative_raw_response || session.narrative || ""
    # Count this session's own matches before appending — diffing @nonces.size
    # across the scan would credit other threads' concurrent appends to this
    # session (extract_nonces_from runs inside MAX_NARRATIVE_CONCURRENCY).
    matches = text.scan(NONCE_PATTERN)
    matches.each do |request_id, hmac|
      @nonces << "#{request_id}:#{hmac}"
    end
    if matches.any?
      @nonces_from_sessions.update { |v| v + matches.size }
      @sessions_yielding_nonces.increment
    end
  end

  # Pull the first proxy request_id out of an LLM raw_response for the
  # server-side ResultVerifier. An episode's raw_response can legitimately
  # contain zero nonces (cache hit — LlmResultCache strips them, see
  # reference_llm_cache_nonce_stripping memory) in which case we return nil
  # and the server falls back to legacy index-matched verification.
  def extract_first_request_id(raw)
    match = raw.to_s.match(NONCE_PATTERN)
    match && match[1]
  end

  def package_results(episode_summaries:, session_count:)
    # Extract nonces from episode summaries too
    nonces_before_episodes = @nonces.size
    episodes_yielding_nonces = 0
    episode_summaries.each do |summary|
      raw = summary["raw_response"] || ""
      before = @nonces.size
      raw.scan(NONCE_PATTERN).each do |request_id, hmac|
        @nonces << "#{request_id}:#{hmac}"
      end
      episodes_yielding_nonces += 1 if @nonces.size > before
    end
    nonces_from_episodes = @nonces.size - nonces_before_episodes
    session_nonces = @nonces_from_sessions&.value || 0
    sessions_with_nonces = @sessions_yielding_nonces&.value || 0
    log "  Nonce sources: #{session_nonces} from #{sessions_with_nonces} sessions, #{nonces_from_episodes} from #{episodes_yielding_nonces}/#{episode_summaries.size} episodes"

    # order(:id).first is a STABLE carrier — must match the project
    # collect_git_data_aggregate wrote the combined metrics onto (plain .first
    # has no default order, so producer and shipper could disagree).
    project = @upload.projects.order(:id).first
    git_metrics = project&.git_metrics || {}
    # Stamped by collect_git_data_aggregate when `--all` summed >1 repo into the
    # carrier; ship a neutral remote + aggregate name (not one repo's identity).
    aggregate_repos = git_metrics["aggregate_repo_count"]

    # Fresh query to pick up narratives written by analyze_sessions thread pool.
    # Must bypass AR association cache — threads wrote on separate DB connections.
    project_ids = Project.where(upload_id: @upload.id).pluck(:id)
    session_summaries = {}
    session_metadata = {}
    TranscriptSession.where(project_id: project_ids).where.not(narrative: [ nil, "" ]).includes(:parent_session, :triggered_by).find_each do |ts|
      # Narratives are LLM-generated from already-scrubbed chunks, but the
      # generated prose is never itself run through SecretScrubber — close that
      # at the boundary (fail-closed). Scrub the full text, THEN truncate, so a
      # secret straddling the 2000-char cut still matches.
      session_summaries[ts.session_id] = scrub_secret_text(ts.narrative).truncate(2000)
      session_metadata[ts.session_id] = {
        message_count: ts.message_count,
        first_prompt: scrub_secret_text(ts.first_prompt)&.truncate(200),
        session_created_at: ts.session_created_at&.iso8601,
        session_modified_at: ts.session_modified_at&.iso8601,
        is_subagent: ts.is_subagent,
        parent_session_id: ts.parent_session&.session_id,
        session_signals: ts.session_signals,
        session_events: truncate_events_for_upload(ts.session_events),
        dispatch_metadata: ts.dispatch_metadata.presence,
        quality_flags: ts.quality_flags.presence,
        # ParallelismAnalyzer uses active_time_windows (15-min gap-split) for
        # overlap detection. Without this round-trip, server-side imports fall
        # back to the coarse session_created_at..session_modified_at span,
        # which counts long idle windows as overlap and can inflate
        # concurrent_pairs_with_ships past the Orchestrator threshold.
        active_time_windows: ts.active_time_windows.presence,
        user_highlights: scrub_secret_text(ts.user_highlights)&.truncate(UPLOAD_USER_HIGHLIGHTS_LIMIT),
        steering_trace: ts.steering_trace,
        agent_type: ts.agent_type,
        session_intent: ts.session_intent,
        # Cross-tool session linking (Phase 2). The wire-level field uses the
        # parent's session_id (string) — server resolves to triggered_by_id
        # (uuid) in a 3rd pass on its own row ids. See
        # docs/designs/CROSS_TOOL_SESSION_LINKING.md §4.3.
        cross_tool_origin: ts.cross_tool_origin,
        triggered_by_session_id: ts.triggered_by&.session_id,
        triggered_by_confidence: ts.triggered_by_confidence
      }.compact
    end
    log("  Session summaries: #{session_summaries.size} sessions with narratives")

    # Preload episodes with their session joins to avoid N+1
    episode_map = @upload.episodes.includes(episode_sessions: :transcript_session).index_by { |e| e.id.to_s }

    {
      episode_scores: episode_summaries.map { |es|
        ep = episode_map[es["episode_id"]]
        {
          episode_id: es["episode_id"],
          # Origin request_id so the server's ResultVerifier can match
          # submitted scores against the correct proxy_log by id instead
          # of by array position. Position-based matching was racy under
          # parallel EpisodeSummarizer scoring (created_at order ≠
          # submission order) and produced spurious score_verified=false
          # + 180-day retention holds. See results_controller.rb:155-161.
          # Falls back to nil for cache-hit episodes whose raw_response
          # had nonces stripped by LlmResultCache; server treats nil
          # submitters as the legacy index-matched path.
          request_id: extract_first_request_id(es["raw_response"]),
          title: es["title"],
          type: es["type"],
          scores: es["scores"],
          confidence: es["confidence"],
          session_ids: ep&.episode_sessions&.map { |es_join|
            {
              session_id: es_join.transcript_session.session_id,
              link_type: es_join.link_type,
              link_confidence: es_join.link_confidence
            }
          } || []
        }
      },
      session_summaries: session_summaries,
      session_metadata: session_metadata,
      git_metrics: git_metrics.slice("velocity", "numstat", "total_commits", "total_repo_commits", "loc_stats"),
      git_remote: aggregate_repos ? nil : project&.git_remote,
      recent_commits: aggregate_repos ? [] : scrub_commit_subjects(project&.recent_commits),
      session_count: session_count,
      subagent_session_count: @upload.projects.sum { |p| p.transcript_sessions.merge(TranscriptSession.non_logical_roots).where(status: "chunked").count },
      project_name: aggregate_repos ? "All projects (#{aggregate_repos} #{'repo'.pluralize(aggregate_repos)})" : (project&.display_name || project&.encoded_name),
      nonces: @nonces.uniq,
      decisions: package_decisions,
      decisions_status: @dig_status || "not_run",
      code_quality: scrub_code_quality(@code_quality),
      client_telemetry: package_telemetry
    }
    # plan_files / plan_metrics are intentionally NOT merged into the payload.
    # `Api::V1::ResultsController#build_v3_results` has never included them in
    # the hardcoded key subset, so the server drops them silently; packaging
    # them wastes bandwidth and keeps a potential raw-content leak path alive
    # if diarized_content is ever nil. The full PD pipeline is scheduled for
    # removal in PR 2.
  end

  def package_decisions
    decisions = @upload.decisions.includes(:transcript_session, :outcome_analyses).to_a
    return [] if decisions.empty?

    decisions.map do |d|
      {
        session_id: d.transcript_session.session_id,
        proposal_text: safe_redact_for_upload(d.redacted_proposal_text, d.proposal_text),
        response_text: safe_redact_for_upload(d.redacted_response_text, d.response_text),
        proposal_type: d.proposal_type,
        decision_type: d.decision_type,
        law_key: d.law_key,
        classification_confidence: d.classification_confidence,
        decision_narrative: scrub_secret_text(d.decision_narrative),
        option_count: d.option_count,
        response_word_count: d.response_word_count,
        domain: d.domain,
        significance: d.significance,
        reversibility: d.reversibility,
        event_index: d.event_index,
        agent_recognized: d.agent_recognized,
        outcome: d.outcome_analyses.first&.then { |oa|
          { signal: oa.outcome_signal, confidence: oa.confidence, evidence: scrub_secret_text(oa.evidence_text) }
        }
      }
    end
  rescue => e
    Rails.logger.warn("ClientPipeline: decision packaging failed: #{e.message}")
    []
  end

  # Fail-closed text selection for the upload payload. Pick the pre-redacted
  # value if present, else regex-redact the raw value at packaging time so raw
  # code identifiers / file paths never cross the wire even when
  # DecisionTextRedactor was skipped, errored, or never ran. Then compose
  # SecretScrubber OVER the result: DecisionTextRedactor strips code/paths but
  # is NOT a credential scrubber, and the redacted_* columns were produced by
  # DecisionTextRedactor too — so a pasted API key in a decision exchange would
  # otherwise survive both the column and the fallback.
  def safe_redact_for_upload(redacted, raw)
    base = redacted.presence || DecisionTextRedactor.regex_redact(raw.to_s)
    scrub_secret_text(base)
  end

  # Fail-closed credential scrub for any free-text field at the UPLOAD
  # boundary. Independent of upstream source-time scrubbing (legacy rows,
  # PAXEL_TOOL_OUTPUT_SCRUB=0, DecisionTextRedactor-only paths). Runs at
  # package time — after scoring — so it never changes scoring inputs (no
  # PROMPT_VERSION cascade). nil passes through (keeps .compact semantics);
  # non-strings pass through; when the scrubber is disabled the text is
  # returned unchanged.
  def scrub_secret_text(text)
    return text unless text.is_a?(String) && SecretScrubber.enabled?
    SecretScrubber.scrub(text)
  end

  # Scrub credential strings out of commit subjects before upload. Author /
  # email are intentionally retained (disclosed verbatim on the data-handling
  # page, like numstat author/email); only the free-text subject — which can
  # carry a pasted secret — is scrubbed. Done at the boundary, not at
  # ingestion, so client-side scoring (CommitGrouper/CommitClassifier) keeps
  # operating on the raw subject and its behavior is unchanged.
  def scrub_commit_subjects(commits)
    return [] unless commits.is_a?(Array)
    commits.map do |c|
      next c unless c.is_a?(Hash) && c["subject"].is_a?(String)
      c.merge("subject" => scrub_secret_text(c["subject"]))
    end
  end

  # Scrub the free-text `error` message (raw e.message from a failed analyzer
  # run) out of the uploaded code_quality hash. Handles symbol- or string-keyed
  # error from either ClientPipeline's rescue or LocalCodeQualityAnalyzer.
  def scrub_code_quality(cq)
    return { status: "not_run" } if cq.blank?
    return cq unless cq.is_a?(Hash)
    out = cq.dup
    [ :error, "error" ].each do |k|
      out[k] = scrub_secret_text(out[k]) if out[k].is_a?(String)
    end
    out
  end

  def package_telemetry
    pipeline_duration = if @pipeline_start
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @pipeline_start).round(1)
    end

    # LLM call stats from client-side LlmCall table
    llm_stats = if defined?(LlmCall) && LlmCall.table_exists? && @upload
      calls = LlmCall.where(upload_id: @upload.id)
      {
        total_calls: calls.count,
        total_duration_ms: calls.sum(:duration_ms).round(0),
        slow_calls: calls.where("duration_ms > ?", AnthropicClient::SLOW_CALL_THRESHOLD_MS).count,
        by_service: calls.group(:service_name).count,
        by_model: calls.group(:model).count,
        total_input_tokens: calls.sum(:input_tokens),
        total_output_tokens: calls.sum(:output_tokens),
        total_cost_cents: calls.sum(:cost_cents),
        avg_duration_ms: calls.average(:duration_ms)&.round(0),
        p95_duration_ms: calls.order(:duration_ms).offset((calls.count * 0.95).to_i).limit(1).pick(:duration_ms),
        slowest_call: calls.order(duration_ms: :desc).limit(1).pick(:service_name, :duration_ms, :model)
          &.then { |svc, dur, mdl| { service: svc, duration_ms: dur, model: mdl } }
      }
    else
      {}
    end

    # Docker/system info
    system_info = {
      ruby_version: RUBY_VERSION,
      rails_env: Rails.env,
      pid: Process.pid
    }

    {
      # The client's LOCAL upload slug (shown in the client's own output). The
      # server generates its OWN, unrelated slug, so without this there is no way
      # to map a user-reported client id ("I uploaded ttkkkiyu") to the server
      # upload. Carried in telemetry (already stored server-side) — no new column.
      client_slug: @upload&.slug,
      pipeline_duration_s: pipeline_duration,
      host_estimate_minutes: ENV["PAXEL_HOST_ESTIMATE_MINUTES"]&.to_i,
      step_timings: @step_timings || [],
      llm_stats: llm_stats,
      orphan_recovery_count: read_orphan_recovery_count,
      recovery_breakdown: read_recovery_breakdown,
      system_info: system_info,
      collected_at: Time.current.iso8601
    }.compact
  rescue => e
    Rails.logger.warn("ClientPipeline: telemetry packaging failed: #{e.message}")
    { error: scrub_secret_text("telemetry packaging failed: #{e.class}: #{e.message}") }
  end

  # Read orphan-recovery count from the upload archive's _metadata.json
  # sidecar, falling back to PAXEL_ORPHAN_RECOVERY_COUNT env var for
  # ALL_PROJECTS=1 Docker mode (which bind-mounts the original CLAUDE_DIR
  # and has no archive sidecar — see upload_script's run_docker_analysis).
  # Returns 0 if all sources are absent / unparseable / wrong type.
  # Defensive coercion so a malformed value doesn't bubble up into
  # `package_telemetry`'s outer rescue and nuke the entire telemetry hash.
  def read_orphan_recovery_count
    path = File.join(@transcript_dir, "_metadata.json")
    if File.exist?(path)
      parsed = JSON.parse(File.read(path))
      if parsed.is_a?(Hash) && parsed.key?("orphan_recovery_count")
        return Integer(parsed["orphan_recovery_count"], exception: false) || 0
      end
    end
    Integer(ENV["PAXEL_ORPHAN_RECOVERY_COUNT"], exception: false) || 0
  rescue JSON::ParserError, Errno::ENOENT, IOError
    Integer(ENV["PAXEL_ORPHAN_RECOVERY_COUNT"], exception: false) || 0
  end

  # Recovery-source breakdown buckets. These match the source labels
  # written to _RMDC_LOG_FILE by upload_script.text.erb's
  # _log_recovery_source (with hyphens transformed to underscores for
  # JSON key friendliness). Reader always returns this six-key shape
  # with Integer 0 defaults — prod consumers can `dig` without `|| 0`.
  DEFAULT_RECOVERY_BREAKDOWN = {
    "ancestor" => 0,
    "worktree_list" => 0,
    "jj_workspace_list" => 0,
    "project_cache" => 0,
    "conductor_backfill" => 0,
    "unresolvable" => 0
  }.freeze

  # Read recovery_breakdown from the upload archive's _metadata.json
  # sidecar, falling back to PAXEL_RECOVERY_BREAKDOWN env var (CSV
  # format: `k1:v1,k2:v2,...`) for ALL_PROJECTS=1 Docker mode.
  #
  # ALWAYS returns the six-key hash with Integer values (0 defaults for
  # absent buckets). Sidecar-present-but-malformed, env-only, or total
  # absence all fall through to the all-zeros default. This stable
  # shape lets `package_telemetry`'s `.compact` preserve the field
  # (non-empty hash is truthy) and lets downstream consumers dig
  # without nil checks.
  def read_recovery_breakdown
    DEFAULT_RECOVERY_BREAKDOWN.merge(parse_recovery_breakdown_raw)
  rescue JSON::ParserError, Errno::ENOENT, IOError
    DEFAULT_RECOVERY_BREAKDOWN.merge(parse_recovery_breakdown_csv(ENV["PAXEL_RECOVERY_BREAKDOWN"]))
  end

  def parse_recovery_breakdown_raw
    path = File.join(@transcript_dir, "_metadata.json")
    if File.exist?(path)
      parsed = JSON.parse(File.read(path))
      value = parsed.is_a?(Hash) ? parsed["recovery_breakdown"] : nil
      return coerce_recovery_breakdown_hash(value) if value.is_a?(Hash)
    end
    parse_recovery_breakdown_csv(ENV["PAXEL_RECOVERY_BREAKDOWN"])
  end

  def coerce_recovery_breakdown_hash(hash)
    hash.each_with_object({}) do |(k, v), out|
      key = k.to_s
      next unless DEFAULT_RECOVERY_BREAKDOWN.key?(key)
      out[key] = Integer(v, exception: false) || 0
    end
  end

  def parse_recovery_breakdown_csv(csv)
    return {} if csv.nil? || csv.empty?
    csv.split(",").each_with_object({}) do |pair, out|
      k, v = pair.split(":", 2)
      key = k.to_s
      next unless DEFAULT_RECOVERY_BREAKDOWN.key?(key)
      out[key] = Integer(v, exception: false) || 0
    end
  end

  # Retries the final results POST 3 times on connection errors or 5xx.
  # Same X-Idempotency-Key across attempts so Rails returns the same
  # Upload row instead of creating a duplicate. Respects Retry-After
  # when the server supplies it; otherwise falls back to UPLOAD_BACKOFF.
  UPLOAD_MAX_ATTEMPTS = 3
  UPLOAD_BACKOFF_S = [ 1, 3, 10 ].freeze

  # Bumped on any package_results shape change that breaks backward-compat
  # replay of a stashed upload. PendingUploadReplayService compares the
  # stashed pipeline_version against this and quarantines on mismatch.
  #
  # Note: removing plan_files / plan_metrics from the payload (commit 69a36511)
  # does NOT require a version bump — the server's build_v3_results has never
  # whitelisted those keys, so stashed v1 payloads still import identically
  # whether or not those keys are present. The bump gate is "does the server
  # behave differently replaying this payload than it did at upload time";
  # removing keys the server already ignored is a no-op under that rule.
  #
  # v2: the F3 fail-closed credential scrub at the upload boundary. A v1 stash
  # on disk was packaged BEFORE that scrub, so it can carry unredacted
  # credentials in narratives / decision text / commit subjects / error fields.
  # Bumping forces PendingUploadReplayService to quarantine pre-fix stashes to
  # failed/ instead of replaying the raw payload (pending_upload_replay_service.rb:111).
  #
  # v3: client-side accuracy fixes that a stashed payload bakes in and cannot be
  # corrected server-side (the raw transcript + repo aren't uploaded), so a pre-v3
  # replay would import known-wrong data:
  #   • CodexNormalizer now surfaces apply_patch → file_edit/file_create events and
  #     update_plan → a plan signal. A pre-v3 stash flattened both to Bash, so its
  #     session_events carry the false "0 plans" / "no file edits" Codex profile.
  #   • LocalCodeQualityAnalyzer classifies on the full tree (cap applies to content
  #     reads only). A pre-v3 stash has truncated code-quality counts (test_file_count,
  #     median_file_length) from the byte-sorted first-MAX_FILES sample.
  # Quarantining a pre-v3 stash means the user re-runs and gets correct data — the
  # right outcome, since replaying it would reproduce the exact bugs this fixes.
  PIPELINE_VERSION = 3

  # Per-event text cap applied ONLY to the outbound upload payload. Full text
  # (EventExtractor::MAX_TEXT_LENGTH = 10K, MAX_THINKING_LENGTH = 20K,
  # MAX_BASH_LENGTH = 5K) stays in client SQLite for in-container scoring;
  # server-side consumers of session_events only need short prefixes.
  # in_session_analyzer.rb:59 matches REVERSAL_INDICATORS against
  # user_directive text (short phrases — "wait,", "actually,", "scratch that");
  # other consumers (scoring_context_builder, parallelism_analyzer,
  # agentic_proficiency_scorer) read structural fields only. 2K is generous
  # for both. Without this cap, a single session with 100 thinking events at
  # 20K each = 2 MB, and ~250-session uploads were hitting tens of MB POSTs
  # that motivated the resumable-upload work (PR #626).
  UPLOAD_EVENT_TEXT_LIMIT = 2_000

  # user_highlights is built in TranscriptChunker#extract_and_save_signals
  # as up to 50 × 2K per-message truncated highlights joined with "\n---\n",
  # producing up to ~100K per session. Across 250 sessions that's ~25 MB
  # — the biggest remaining payload contributor once session_events text
  # is capped. Server consumers re-truncate to 2K (BuilderProfileService
  # #collect_user_highlights) or 10K (EpisodeSummarizer), so the
  # full-blob round-trip is waste. Cap at 10K for the upload, leaving the
  # DB value intact for future consumers that may want the full set.
  UPLOAD_USER_HIGHLIGHTS_LIMIT = 10_000

  def upload_results!
    client_request_id = SecureRandom.uuid
    conn = Faraday.new(url: @results_endpoint) do |f|
      f.request :json
      f.response :json
      # Read timeout 60s (bumped from 30s on 2026-04-23). Server-side POST
      # handling for typical payloads completes in <1.5s (verified on a 27 KB
      # 3-session fixture), but dev-mode bin/dev's Puma can queue requests
      # behind SolidQueue jobs for 20-30s during a backfill. Prod is unaffected
      # since web + worker tiers run in separate ECS services, but the extra
      # headroom costs nothing and the replay service at 120s already
      # acknowledges real payloads need more slack.
      f.options.timeout = 60
    end

    # Defense in depth: strip NUL bytes from the whole payload before upload.
    # Postgres rejects U+0000 in jsonb/text, so a NUL in any field (e.g. a code
    # snippet captured in a decision) would 500 the server's Upload.create!.
    # Sanitizing the ivar once also cleans the copy stash_failed_upload! persists
    # below. The authoritative fix is server-side; this keeps the payload clean
    # at the source. See PAXEL-CLIENT-K.
    @results = NullByteSanitizer.sanitize(@results)

    last_error = nil
    UPLOAD_MAX_ATTEMPTS.times do |attempt|
      begin
        response = conn.post do |req|
          req.headers["X-YC-Token"] = @token
          req.headers["X-Idempotency-Key"] = client_request_id
          req.headers["Content-Type"] = "application/json"
          req.body = @results
        end

        payload_size = @results.to_json.bytesize rescue 0
        debug("Upload attempt #{attempt + 1}/#{UPLOAD_MAX_ATTEMPTS}: HTTP #{response.status}, payload #{(payload_size / 1024.0).round(1)}KB")

        if response.status == 201 || response.status == 200
          body = response.body
          @server_upload_slug = body["slug"]
          return { ok: true, slug: body["slug"], results_url: body["results_url"], idempotent_replay: body["idempotent_replay"] }
        end

        # 4xx (except 429) is a bad request — don't retry, fail fast.
        if response.status >= 400 && response.status < 500 && response.status != 429
          debug("Upload response body: #{response.body.to_s.truncate(500)}")
          capture_upload_4xx_to_sentry(response, client_request_id)
          return { ok: false, status: response.status, body: response.body }
        end

        # 5xx or 429 — retry if budget left
        last_error = { status: response.status, body: response.body }
        if attempt < UPLOAD_MAX_ATTEMPTS - 1
          retry_after = response.headers["retry-after"].to_i
          wait = retry_after > 0 ? retry_after : UPLOAD_BACKOFF_S[attempt]
          debug("Upload attempt #{attempt + 1} got #{response.status}; retrying in #{wait}s")
          sleep wait
        end
      rescue Faraday::Error => e
        debug("Upload attempt #{attempt + 1} error: #{e.class} - #{e.message}")
        last_error = { error: "#{e.class} - #{e.message}" }
        if attempt < UPLOAD_MAX_ATTEMPTS - 1
          sleep UPLOAD_BACKOFF_S[attempt]
        end
      end
    end

    debug("Upload: exhausted #{UPLOAD_MAX_ATTEMPTS} attempts")
    failure = last_error ? { ok: false, **last_error } : { ok: false, error: "upload failed" }
    capture_upload_exhausted_to_sentry(failure, client_request_id)
    stash_failed_upload!(client_request_id: client_request_id, failure: failure) if stashable?(failure)
    failure
  end

  # Returns the user-facing status line for run_step("Uploading results").
  # Extracted so specs can exercise the exact production flow rather than
  # duplicating the if/else inline — past inline copies in specs silently
  # drifted from the real code.
  def handle_upload_result(result)
    if result[:ok]
      "uploaded → #{result[:results_url]}"
    else
      "upload failed: #{format_upload_failure_detail(result)}"
    end
  end

  # Classify a failed upload so the rake/host script reports it honestly instead of
  # "Upload complete!" (PAXEL: wadoodabdul — a failed upload is logged as a ⚠ by
  # run_step but the run still exits 0). Distinguishes:
  #   - deferred: the upload was stashed for replay (transient 5xx/429/network with a
  #     complete payload) — the next run auto-uploads it.
  #   - failed: no replay artifact (permanent 4xx, an unwritable stash, or a payload
  #     that can't replay) — there's nothing to auto-retry, so the user must re-run.
  # @upload_stashed is set true by stash_failed_upload! only when the replay artifact
  # actually persisted. upload_result is nil only if run_step rescued mid-upload (so far
  # impossible — upload_results! rescues Faraday errors itself — but treated as a
  # non-stashed failure for safety).
  def record_upload_outcome(upload_result)
    return if upload_result && upload_result[:ok]
    @upload_deferred = @upload_stashed
    @upload_failed = !@upload_stashed
  end

  # Prefer the server's `"error"` field (e.g. "Verification failed: No
  # nonces matched proxy logs") over the bare status code — the user needs
  # to see *what* went wrong, not just that it did. Type-guarded against
  # string bodies (returned for non-JSON error pages) and nil bodies.
  def format_upload_failure_detail(result)
    body = result[:body]
    server_reason = body.is_a?(Hash) ? body["error"] : nil
    result[:error] || server_reason || "HTTP #{result[:status]}"
  end

  # Client-side Sentry capture for a 4xx response from /api/v1/results.
  #
  # This pairs with the server-side capture in
  # Api::V1::ResultsController#capture_verification_failure_to_sentry. The
  # server is the primary source of truth for 422 reasons (it has the full
  # verification state); this client-side capture exists so we still see
  # failures when the client never reaches Rails (DNS, proxy, TLS), and
  # so we can correlate the client's attempt timeline with the server's
  # rejection reason via `client_request_id`. The fingerprint buckets by
  # status code so retries across a deploy don't flood Sentry.
  def capture_upload_4xx_to_sentry(response, client_request_id)
    return unless defined?(Sentry) && Sentry.initialized?

    body = response.body
    parsed_error = body.is_a?(Hash) ? body["error"] : nil
    Sentry.with_scope do |scope|
      scope.set_fingerprint([ "client_pipeline_upload_4xx", response.status.to_s ])
      scope.set_tags(sentry_pipeline_tags(
        stage: "upload_results",
        http_status: response.status
      ))
      scope.set_extras(
        status: response.status,
        error: parsed_error,
        body_preview: body.to_s.truncate(1000),
        client_request_id: client_request_id
      )
      Sentry.capture_message(
        "[ClientPipeline] Upload rejected (HTTP #{response.status})",
        level: :error
      )
    end
  rescue StandardError => e
    debug("Sentry capture failed: #{e.class} - #{e.message}")
  end

  # Client-side Sentry capture for a terminal upload failure (all retries
  # exhausted — network / timeout / 5xx). Fires after
  # UPLOAD_MAX_ATTEMPTS attempts have failed. 4xx responses are captured
  # separately in capture_upload_4xx_to_sentry and don't reach here (they
  # return early without hitting the retry loop's exhaustion branch).
  def capture_upload_exhausted_to_sentry(failure, client_request_id)
    return unless defined?(Sentry) && Sentry.initialized?
    return if failure[:status] && failure[:status] >= 400 && failure[:status] < 500 && failure[:status] != 429

    fingerprint_key = failure[:error] ? failure[:error].to_s.split(" - ").first : "status_#{failure[:status]}"
    Sentry.with_scope do |scope|
      scope.set_fingerprint([ "client_pipeline_upload_exhausted", fingerprint_key.to_s ])
      scope.set_tags(sentry_pipeline_tags(
        stage: "upload_results_exhausted",
        http_status: failure[:status]
      ))
      scope.set_extras(
        status: failure[:status],
        error: failure[:error],
        body_preview: failure[:body].to_s.truncate(1000),
        client_request_id: client_request_id,
        max_attempts: UPLOAD_MAX_ATTEMPTS
      )
      Sentry.capture_message(
        "[ClientPipeline] Upload failed after #{UPLOAD_MAX_ATTEMPTS} attempts: #{failure[:error] || "HTTP #{failure[:status]}"}",
        level: :error
      )
    end
  rescue StandardError => e
    debug("Sentry capture failed: #{e.class} - #{e.message}")
  end

  # Retryable-shape check: stash only failures the next bin/upload could
  # plausibly replay. 400/401/403/404/422 are permanent rejections (the
  # 4xx fast-fail path at line ~1488 short-circuits before we get here
  # for those).
  def stashable?(failure)
    return false unless payload_complete?
    return true if failure[:error].present?
    status = failure[:status]
    return false if status.nil?
    status >= 500 || status == 429
  end

  # Mirrors server validation: episode_scores non-empty (results_controller
  # rejects the POST otherwise) AND nonces present (server verifies these
  # against proxy_logs; a stash without them would 422 on replay).
  def payload_complete?
    @results.is_a?(Hash) &&
      @results[:episode_scores].is_a?(Array) && @results[:episode_scores].any? &&
      @results[:nonces].is_a?(Array) && @results[:nonces].any?
  end

  def stash_failed_upload!(client_request_id:, failure:)
    PendingUploadStash.write!(
      payload: @results,
      client_request_id: client_request_id,
      url: @results_endpoint,
      endpoint_source: detect_endpoint_source,
      token_fingerprint: Digest::SHA256.hexdigest(@token.to_s),
      last_error: failure,
      attempt_count: UPLOAD_MAX_ATTEMPTS,
      pipeline_version: ClientPipeline::PIPELINE_VERSION
    )
    # The replay artifact persisted -> this failure is deferred, not lost. The rescue
    # branches below (disk full / unwritable / other) leave this false so run! reports
    # an honest "re-run to retry" instead of promising an auto-replay that can't happen.
    @upload_stashed = true
    # Env-aware next-run hint mirrors AnthropicClient's dev/prod remediation
    # pattern (app/models/concerns/anthropic_client.rb:581-598). Mode-neutral
    # phrasing keeps the sentence natural when the command name is elided.
    next_run_hint = ENV["PAXEL_CLIENT_MODE"] == "dev" ? "`bin/upload`" : "upload"
    log "  Upload failed after #{UPLOAD_MAX_ATTEMPTS} retries. Saved locally — your next #{next_run_hint} will auto-replay."
  rescue PendingUploadStash::DiskFullError => e
    log "  Upload failed AND local stash failed: #{e.message}. Free disk space and retry."
  rescue Errno::EACCES, Errno::EPERM, Errno::EROFS, Errno::ENOTDIR => e
    # Stash dir not writable — same uid-mismatch class as the cache (non-root
    # container vs. host-owned 0700 ~/.paxel/data). The run still finished, but
    # the resumable-upload stash couldn't be saved, so the next run can't auto-
    # replay. Surface it plainly instead of swallowing into a file-only debug.
    # Non-fatal — never mask the original upload failure.
    log "  Upload failed, and it couldn't be saved for an automatic retry — ~/.paxel/data isn't writable inside the container. Your next run will re-analyze from scratch."
    debug("stash_failed_upload! unwritable: #{e.class}: #{e.message}")
  rescue StandardError => e
    # Never let stash-persistence errors mask the original upload failure — but
    # don't fail silently either; the user loses auto-replay and should know.
    log "  Upload failed, and it couldn't be saved for an automatic retry (#{e.class}). Your next run will re-analyze from scratch."
    debug("stash_failed_upload! swallowed #{e.class}: #{e.message}")
  end

  def detect_endpoint_source
    return "env" if ENV["YC_RESULTS_ENDPOINT"].present?
    return "localhost" if @results_endpoint.to_s.match?(/host\.docker\.internal|localhost|127\.0\.0\.1/)
    "production"
  end

  # Produce a shallow-copied session_events array with known text-heavy
  # fields capped at UPLOAD_EVENT_TEXT_LIMIT. Pure function — does NOT mutate
  # the DB-stored session_events (which remain at full resolution for local
  # scoring). Only fires on fields present; event types without text
  # (file_edit, git_commit, subagent_dispatch, etc.) pass through unchanged.
  def truncate_events_for_upload(events)
    return events unless events.is_a?(Array)
    text_keys = %w[text message command]
    events.map do |event|
      next event unless event.is_a?(Hash)
      # Fail-closed boundary backstop: scrub credentials AND length-cap the
      # text-bearing fields. EventExtractor already scrubs at the source; this
      # covers legacy rows / PAXEL_TOOL_OUTPUT_SCRUB=0 so the upload payload
      # matches the disclosed "scrubbed at the upload boundary" contract.
      # Only changed keys are merged, so untouched events keep their identity.
      touched = text_keys.each_with_object({}) do |key, memo|
        value = event[key]
        next unless value.is_a?(String)
        scrubbed = scrub_secret_text(value)
        scrubbed = scrubbed.truncate(UPLOAD_EVENT_TEXT_LIMIT) if scrubbed.length > UPLOAD_EVENT_TEXT_LIMIT
        memo[key] = scrubbed if scrubbed != value
      end
      touched.empty? ? event : event.merge(touched)
    end
  end

  # Sanitize free text for a live progress blurb: scrub credentials, strip C0
  # control chars, and collapse whitespace to one line (NO truncation — callers
  # truncate after any fallback logic). Every progress blurb that can carry the
  # developer's own text routes through this, because:
  #   - the footer goes to stdout and the non-footer path to stderr, and either
  #     can be redirected to a file or captured by CI — so a pasted token must
  #     not flash in the terminal or land in a log (fail-closed, matching the
  #     upload-boundary scrub). Scrub the RAW text so a secret straddling a
  #     later truncation is still caught.
  #   - PipelineLogger joins footer lines with "\n" and does cursor math, so a
  #     raw newline or escape sequence would add a physical row or scramble the
  #     footer. The byte-range class only matches U+0000–U+001F/U+007F, so
  #     multi-byte UTF-8 (emoji, CJK) passes through and the logger's fit_width
  #     handles its display width.
  def sanitize_blurb(text)
    scrub_secret_text(text.to_s).gsub(/[\x00-\x1f\x7f]/, " ").gsub(/\s+/, " ").strip
  end

  # One-line label for the session currently being summarized / scanned, shown
  # live in the progress footer the same way episode scoring shows the episode
  # title. Uses the developer's own first prompt — the clearest "what was this
  # about" signal. Falls back to a short session id when there's no usable
  # prompt (blank, or the injected "You are Codex" preamble, which is
  # boilerplate, not a real instruction — same guard EpisodeSummarizer uses).
  def session_blurb(session)
    return "" unless session
    prompt = sanitize_blurb(session.first_prompt)
    prompt = "" if prompt.start_with?("You are Codex")
    (prompt.presence || "session #{session.session_id.to_s[0..7]}").truncate(50)
  end

  # tqdm-style progress bar: 42%|████████░░░░░░░░░░░░| 21/50 [01:23<01:45, 0.7 it/s]
  # Reports every ~10% or every ~3 seconds, whichever comes first.
  def log_item_progress(done, total, step_start, detail = nil)
    return if total == 0

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - step_start

    # Always show first, last, and every ~10% milestone
    pct = ((done.to_f / total) * 100).round(0)
    pct_milestone = done == 1 || done == total || (done * 10 / total) != ((done - 1) * 10 / total)
    # Also show if ≥3 seconds since last progress line
    time_milestone = (@last_item_progress_at.nil? || (elapsed - @last_item_progress_at) >= 3)

    return unless pct_milestone || time_milestone

    @last_item_progress_at = elapsed
    # Tail-aware ETA: with a fast body + slow tail, the cumulative average
    # (elapsed/done) badly underestimates the remaining tail — episode scoring
    # showed "~7s left" while the last ~15 of 659 streams took minutes. Blend in
    # the recent per-item rate (since the previous progress line) and take the
    # SLOWER of the two so the estimate (and the s/it readout) rise as
    # throughput drops instead of underpromising. Concurrent writers (the
    # scoring callback fires from the future pool) only ever push the estimate
    # UP via the max, so a race degrades to the cumulative average — never to a
    # bogus tiny ETA.
    cumulative_rate = done > 0 ? (elapsed / done) : 0
    recent_rate =
      if @prev_progress_done && done > @prev_progress_done
        (elapsed - @prev_progress_elapsed.to_f) / (done - @prev_progress_done)
      else
        cumulative_rate
      end
    @prev_progress_done = done
    @prev_progress_elapsed = elapsed
    rate = [ cumulative_rate, recent_rate ].max
    remaining = (total - done) * rate * 1.2  # conservative: underpromise, overdeliver
    items_per_sec = (rate > 0) ? (1.0 / rate) : 0

    bar = progress_bar(pct)
    elapsed_str = format_duration(elapsed)
    remaining_str = format_duration(remaining)
    rate_str = items_per_sec >= 1 ? "%.1f it/s" % items_per_sec : "%.1fs/it" % rate

    if footer_enabled?
      @cur_item = { done: done, total: total, rate: rate_str, detail: detail, remaining: remaining }
      refresh_progress_footer
    else
      msg = "→ %3d%%|#{bar}| #{done}/#{total} [#{elapsed_str}<#{remaining_str}, #{rate_str}]" % pct.to_i
      msg += " #{detail}" if detail
      # Non-TTY: one tqdm-style line per milestone (no in-place repaint).
      $stderr.puts msg
      $stderr.flush
    end
  end

  # Emit overall pipeline progress after each step completes.
  def emit_overall_eta(label)
    weight = STEP_WEIGHTS[step_base_name(label)] || 1
    @completed_weights = (@completed_weights || 0) + weight
    return unless @pipeline_start && @completed_weights > 0

    if footer_enabled?
      # Step done: drop the in-step detail; the overall bar now reflects the
      # newly-completed weight on the next footer paint.
      @cur_item = nil
      refresh_progress_footer
      return
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @pipeline_start
    pct = ((@completed_weights / @total_weight) * 100).round(0)
    rate = elapsed / @completed_weights
    remaining = (@total_weight - @completed_weights) * rate * 1.2
    if remaining > 5
      bar = progress_bar(pct)
      $stderr.puts "⏱ Overall: #{pct.to_i}%|#{bar}| [#{format_duration(elapsed)}<#{format_duration(remaining)}]"
    elsif pct < 100
      bar = progress_bar(pct)
      $stderr.puts "⏱ Overall: #{pct.to_i}%|#{bar}| wrapping up"
    end
    $stderr.flush
  rescue
    # Never crash on progress reporting
  end

  def progress_bar(pct, width = 20)
    filled = (pct / 100.0 * width).round
    "#{"█" * filled}#{"░" * (width - filled)}"
  end

  # True only when the logger can render a sticky footer AND stdout is a TTY
  # (container ran with `docker run -t`). A plain-lambda logger (specs) or a
  # non-TTY run (CI, piped) returns false → the old line-by-line output.
  def footer_enabled?
    @log.respond_to?(:set_footer) && @log.respond_to?(:tty?) && @log.tty?
  end

  # Repaint the two-line live footer: current step + in-step detail on line 1,
  # the smooth overall progress bar + ETA on line 2. Cheap and best-effort —
  # never lets a rendering hiccup break the pipeline.
  def refresh_progress_footer
    return unless footer_enabled?

    @spin_i = @spin_i.to_i + 1
    spinner = SPINNER_FRAMES[@spin_i % SPINNER_FRAMES.size]
    label = step_base_name(@cur_step_label.to_s)
    counter = "[#{@step_number}/#{@total_steps}]"
    line1 = +"#{ansi('36', spinner)} #{ansi('2;37', counter)} #{label}"
    if @cur_item
      line1 << "  #{@cur_item[:done]}/#{@cur_item[:total]}"
      line1 << "  #{ansi('2;37', @cur_item[:rate])}" if @cur_item[:rate]
      line1 << "  #{ansi('2;37', @cur_item[:detail])}" if @cur_item[:detail]
    end

    # Smooth overall percent: completed step weights plus the fraction of the
    # current step that's done, so the hero bar inches forward within a step
    # instead of only jumping at step boundaries.
    frac = (@cur_item && @cur_item[:total].to_i.positive?) ? @cur_item[:done].to_f / @cur_item[:total] : 0.0
    done_weight = (@completed_weights || 0.0) + (@cur_step_weight.to_f * frac)
    opct = (@total_weight.to_f.positive? ? (done_weight / @total_weight * 100.0) : 0.0).clamp(0.0, 100.0)
    elapsed = @pipeline_start ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @pipeline_start) : 0.0
    eta = ""
    if opct > 2 && opct < 100
      # Floor the overall ETA by the current step's own tail-aware remaining:
      # the pipeline can't finish before the in-flight step does, so a slow tail
      # (whose step remaining is minutes) can no longer render a bogus "~7s left"
      # from the optimistic from-start linear estimate.
      linear_remaining = elapsed * (100 - opct) / opct
      step_remaining = @cur_item && @cur_item[:remaining].to_f
      remaining = (step_remaining && step_remaining > linear_remaining) ? step_remaining : linear_remaining
      eta = " · ~#{format_duration(remaining)} left"
    end
    line2 = "  #{ansi('32', smooth_progress_bar(opct))} " \
            "#{ansi('1', "#{opct.round}%")}  " \
            "#{ansi('2;37', "#{format_duration(elapsed)} elapsed#{eta}")}"

    @log.set_footer([ line1, line2 ])
  rescue
    # Never let progress rendering break the pipeline
  end

  # Sub-cell-resolution bar (eighth-block ramp) for the overall footer line.
  def smooth_progress_bar(pct, width = 24)
    units = pct.to_f.clamp(0, 100) / 100.0 * width
    full = [ units.floor, width ].min
    bar = +("█" * full)
    cells = full
    if cells < width
      idx = ((units - full) * 8).round
      if idx >= 8
        bar << "█"
        cells += 1
      elsif idx.positive?
        bar << PARTIAL_BLOCKS[idx]
        cells += 1
      end
    end
    bar << ("░" * (width - cells)) if cells < width
    bar
  end

  # Wrap text in an ANSI SGR sequence (footer-only — never written to file).
  def ansi(code, text)
    "\e[#{code}m#{text}\e[0m"
  end

  # Footer-safe stderr emit. With the live footer active, routes through the
  # logger so the line scrolls above it instead of desyncing the cursor math.
  def progress_stderr(msg)
    if @log.respond_to?(:stderr_line)
      @log.stderr_line(msg)
    else
      $stderr.puts msg
      $stderr.flush
    end
  end

  # Skip a step that won't run this pipeline invocation.
  # Adjusts both the step counter and total weight so emit_overall_eta
  # doesn't stall waiting for work that was never started.
  def skip_step(label)
    @total_steps -= 1
    @total_weight -= (STEP_WEIGHTS[step_base_name(label)] || 1)
  end

  def step_base_name(label)
    label.sub(/\s*\[.*\]\z/, "")
  end

  def format_duration(seconds)
    return "00:00" if seconds <= 0
    mins = (seconds / 60).to_i
    secs = (seconds % 60).to_i
    format("%02d:%02d", mins, secs)
  end

  def format_duration_human(seconds)
    return "0s" if seconds <= 0
    mins = (seconds / 60).to_i
    secs = (seconds % 60).round(1)
    if mins > 0
      "#{mins}m #{secs.to_i}s"
    elsif secs >= 10
      "#{secs.to_i}s"
    else
      "#{secs}s"
    end
  end

  def log(message)
    @log.call(message)
  rescue
    # Never crash on logging
  end

  # File-only debug logging. No-ops gracefully when @log is a plain lambda
  # (e.g. in specs or non-Rake callers that don't use PipelineLogger).
  def debug(message)
    @log.debug(message) if @log.respond_to?(:debug)
  rescue
    # Never crash on logging
  end

  def debug_section(header, lines)
    @log.debug_section(header, lines) if @log.respond_to?(:debug_section)
  rescue
    # Never crash on logging
  end
end
