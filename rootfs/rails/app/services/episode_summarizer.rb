# Parallel Haiku LLM calls to summarize and score episodes.
# Pre-loads all data into memory before spawning futures (R6).
# Uses Concurrent::ImmediateExecutor in test env (R7).
class EpisodeSummarizer
  include AnthropicClient
  include JsonExtractor
  include PipelineCircuitBreaker

  PROMPT_VERSION = "v15" # calibration fix: execution_leverage scores outcome-per-input (not raw volume); full 1-10 scale via CALIBRATION_GUIDANCE. Cascades episode_scoring -> narratives/agentic_polish/profile/insights (see prompt_version_registry.rb). Change history in git log.
  MAX_RETRIES = 3
  MAX_CONCURRENCY = (v = ENV["PAXEL_EPISODE_CONCURRENCY"].to_i; v > 0 ? v : 20)
  # Per-plan-file content cap. All other episode input fields already
  # truncate (narratives 50K, code_reviews 30K, user_highlights 10K);
  # plan_file content was unbounded and caused a 413 `input_too_large`
  # on a heavy planning-docs episode (see
  # docs/handoffs/2026-04-24-episode-input-size.md). If a single plan
  # exceeds this cap it's still useful signal — the Planning axis
  # needs to see structure + first few decisions, not the whole file.
  PLAN_FILE_CONTENT_LIMIT = 5_000
  SCORE_AXES = %w[execution_leverage steering engineering_quality product_thinking planning].freeze
  # Back-compat: old LLM responses may still name the axis "throughput"
  # (prior prompt version) — accept either in parse_response and store
  # under the new key.
  AXIS_ALIASES = { "throughput" => "execution_leverage" }.freeze

  ScoringResult = Struct.new(:results, :stats, keyword_init: true)
  API_FAILURE = :api_failure # sentinel to distinguish API errors from parse failures

  def initialize(upload)
    @upload = upload
  end

  def summarize(episodes, velocity_context: nil, language_band: nil, heartbeat: true, &progress)
    empty_stats = { scored: 0, skipped_no_evidence: 0, failed_no_json: 0, failed_api: 0, total: 0 }
    return ScoringResult.new(results: [], stats: empty_stats) if episodes.empty?

    @heartbeat = heartbeat

    # Pre-load all episode data into memory (R6)
    episode_data = preload_episode_data(episodes)

    # Filter out episodes with no scorable content
    scorable, skipped = episode_data.partition { |d| scorable_episode?(d) }

    if skipped.any?
      Rails.logger.info("EpisodeSummarizer: Skipping #{skipped.size}/#{episode_data.size} episodes with no scorable content")
    end

    stats = {
      scored: 0,
      skipped_no_evidence: skipped.size,
      failed_no_json: 0,
      failed_api: 0,
      total: episode_data.size
    }

    return ScoringResult.new(results: [], stats: stats) if scorable.empty?

    total = scorable.size

    prompt = V3ScoringPromptBuilder.build_episode_prompt(
      nil,
      velocity_context: velocity_context,
      language_band: language_band
    )

    # Run parallel futures with bounded thread pool
    completed = Concurrent::AtomicFixnum.new(0)
    failed_no_json = Concurrent::AtomicFixnum.new(0)
    failed_api = Concurrent::AtomicFixnum.new(0)
    # Circuit breaker trips when non-fatal failures accumulate past the
    # threshold (see `PipelineCircuitBreaker`). The motivating case: auth
    # expires mid-pipeline and every Retryable call burns its full budget
    # before returning API_FAILURE — without the breaker, 10+ parallel
    # episodes each waste ~300s of retry before the upload gives up.
    # Fatal errors still propagate directly (see collector rescue below),
    # preserving the existing external contract that callers catch
    # `PaxelLlmError::Fatal` (rake footer, Sentry init, spec at
    # `episode_summarizer_spec.rb` "re-raises PaxelLlmError::Fatal").
    breaker = build_circuit_breaker(stage: "episode")

    with_thread_pool(MAX_CONCURRENCY) do |executor|
      futures = scorable.map do |data|
        Concurrent::Promises.future_on(executor) do
          next if breaker.tripped?

          result = summarize_single(data, prompt)
          case result
          when API_FAILURE
            fa = failed_api.increment
            # Retryable-after-budget: Retryable was already rescued + logged
            # inside `summarize_single`, which returned the sentinel. Wrap
            # in a StandardError for the breaker's trip-string; actual
            # retry detail lives in the per-episode Rails.logger.warn.
            breaker.failure!(
              error: StandardError.new("call_llm retry budget exhausted (Retryable)"),
              item_id: data[:episode_id],
              failed_count: fa,
            )
          when nil
            # Parse failure (LLM returned non-JSON). Not a service failure —
            # call succeeded, output was unparseable. Don't feed the breaker.
            failed_no_json.increment
          else
            breaker.success!
          end
          n = completed.increment
          actual_result = (result == API_FAILURE) ? nil : result
          title = actual_result&.dig("title") || data[:first_prompts]&.first.to_s.truncate(60)
          progress&.call(n, total, title)
          actual_result
        end
      end

      # Collect results, skip failures
      results = []
      futures.each_with_index do |future, idx|
        begin
          # 600s per-future ceiling. Per CLAUDE.md's Anthropic timeout budget,
          # AnthropicClient#call_llm can legitimately take ~300s under overload
          # + retry; a 120s cap raised Concurrent::TimeoutError on legitimate
          # overload waits and tripped the breaker, causing v3_scoring_status=
          # "timeout" on heavy legacy uploads (100-650 episodes). 600s covers
          # the 300s overload budget + pool queue + buffer. Diagnosed against
          # the 11 v3-blocked uploads in the rescore_legacy cohort 2026-04-26.
          result = future.value!(600)
          if result
            results << result
            # Persist scores to episode record for incremental re-uploads
            persist_episode_scores(result)
          end
        rescue => e
          # Record to the breaker before deciding Fatal-vs-log. `failure!`
          # trips immediately on Fatal, so accumulated Fatals raise the
          # wrapped `PipelineCircuitBroken` below if other futures had
          # started — but the usual path is Fatal re-raises here and
          # bypasses `raise_if_tripped!` entirely (preserves the existing
          # "EpisodeSummarizer re-raises PaxelLlmError::Fatal" spec).
          fa = failed_api.increment
          item_id = scorable[idx]&.dig(:episode_id)
          breaker.failure!(error: e, item_id: item_id, failed_count: fa)
          raise if defined?(PaxelLlmError) && e.is_a?(PaxelLlmError::Fatal)
          log_ctx = e.is_a?(PaxelLlmError::Base) ? e.log_context : ""
          Rails.logger.warn("EpisodeSummarizer: Episode #{idx} failed: #{e.class} - #{e.message}#{log_ctx}")
        end
      end

      stats[:scored] = results.size
      stats[:failed_no_json] = failed_no_json.value
      stats[:failed_api] = failed_api.value
      # Surface accumulated non-fatal failures as a single PipelineCircuitBroken
      # exception so callers can handle it the same way as the narrative
      # breaker (rake footer + Sentry already know the class).
      breaker.raise_if_tripped!(fallback_count: failed_api.value)
      ScoringResult.new(results: results, stats: stats)
    end
  end

  private

  def scorable_episode?(data)
    data[:narratives].present? ||
      data[:code_reviews].present? ||
      data[:decision_summary].present? ||
      data[:user_highlights].present? ||
      data[:plan_files]&.any? ||
      data[:signals]&.any? ||
      data[:dispatch_count].to_i.positive?
  end

  def persist_episode_scores(result)
    episode = Episode.find_by(id: result["episode_id"])
    return unless episode
    episode.update_columns(
      scores: result["scores"],
      confidence: result["confidence"],
      title: result["title"]&.truncate(160)
    )
  rescue => e
    Rails.logger.debug("EpisodeSummarizer: Could not persist scores for #{result['episode_id']}: #{e.message}")
  end

  def preload_episode_data(episodes)
    episodes.map do |episode|
      # v9: preload subagent_sessions + their commit_group_sessions so
      # ParallelismAnalyzer.dispatch_with_committed_return_count doesn't N+1
      # on heavy-orchestration episodes. Each dispatching main session
      # would otherwise trigger 1 query for subagent_sessions + 1 per
      # child for commit_group_sessions.any?.
      sessions = episode.transcript_sessions.includes(
        :chunks, :plan_files, subagent_sessions: :commit_group_sessions
      )
      commit_groups = episode.commit_groups

      narratives = sessions.filter_map { |s| s.narrative }.join("\n---\n")
      signals = sessions.filter_map { |s| s.session_signals }.compact
      code_reviews = commit_groups.filter_map { |cg| cg.code_review }.join("\n---\n")
      user_highlights = sessions.filter_map { |s| s.user_highlights }.join("\n---\n")
      first_prompts = sessions.filter_map { |s| s.first_prompt }

      # Load decision exchanges for this episode's sessions
      session_ids = sessions.map(&:id)
      decisions = Decision.where(transcript_session_id: session_ids)
        .where.not(significance: "tactical")
        .includes(:outcome_analyses)
        .order(:event_index)
      decision_summary = summarize_decisions(decisions)

      # Plan file evidence for Planning axis. Two bounds applied:
      #   1. Each file's content truncated to PLAN_FILE_CONTENT_LIMIT.
      #   2. Episode-wide dedup by filename — `PlanFile.latest_versions`
      #      is scoped per-session, so the SAME plan appearing across
      #      multiple sessions in one episode used to be repeated.
      #      `uniq { ... }` keeps the first occurrence (version_count
      #      still reflects that session's own history).
      # Pre-fix, a heavy-planning-docs episode could trip Anthropic's
      # 413 input_too_large (see 2026-04-24 handoff).
      plan_file_data = sessions.flat_map { |s|
        s.plan_files.latest_versions.map { |pf|
          { filename: pf.filename,
            version_count: s.plan_files.for_file(pf.filename).count,
            content: pf.content.to_s.truncate(PLAN_FILE_CONTENT_LIMIT) }
        }
      }.uniq { |pf| pf[:filename] }

      session_intents = sessions.filter_map { |s| s.session_intent }.tally

      # v8+: Structured subagent dispatch stats per episode. Feeds the
      # Execution Leverage rubric (v3_scoring_prompt_builder.rb:32-35
      # already references "dispatched subagents produce committed output"
      # as the 7-10 anchor) with actual numbers instead of relying on
      # narrative-text inference. logical roots only — same-tool subagents
      # surface via ParallelismAnalyzer.subagent_shipped?, cross-tool
      # children narrate within their parent (Phase 4 of cross-tool linking)
      # so excluding them here avoids double-counting dispatches.
      dispatch_count, dispatch_with_committed_return_ratio =
        compute_dispatch_stats(sessions.reject { |s| s.is_subagent || s.triggered_by_id.present? })

      {
        episode_id: episode.id,
        episode_type: episode.episode_type,
        narratives: narratives.truncate(50_000),
        code_reviews: code_reviews.truncate(30_000),
        signals: signals,
        user_highlights: user_highlights.truncate(10_000),
        first_prompts: first_prompts,
        session_count: sessions.size,
        commit_group_count: commit_groups.size,
        # Author-real LOC for THIS episode, summed from its commit groups (numstat).
        # Grounds the episode prompt so the LLM stops inventing "~100K LOC" on episodes
        # that have no LOC anchor in their narratives/code_reviews (#12b).
        added_lines: commit_groups.sum { |cg| cg.insertions.to_i },
        deleted_lines: commit_groups.sum { |cg| cg.deletions.to_i },
        decision_summary: decision_summary,
        plan_files: plan_file_data,
        session_intents: session_intents,
        dispatch_count: dispatch_count,
        dispatch_with_committed_return_ratio: dispatch_with_committed_return_ratio
      }
    end
  end

  # Returns [dispatch_count, dispatch_with_committed_return_ratio] for the
  # main sessions of an episode.
  #
  # dispatch_count: sum of session_events where type == "subagent_dispatch"
  #   across the episode's main sessions. 0 when no dispatches in episode.
  # dispatch_with_committed_return_ratio: of main sessions that DID dispatch,
  #   the fraction where ≥1 dispatch matched a subagent_return AND ≥1 child
  #   subagent session shipped committed code. Delegates to
  #   ParallelismAnalyzer so the episode-level signal matches the
  #   upload-level orchestrator gate exactly. nil when no dispatches.
  #
  # v9 correctness note (fixes v8 bug flagged in post-merge review): v8 used
  # "main session has any git_commit" as the ship proxy, which falsely
  # produced 1.0 for orchestration theater — a parent that dispatched
  # research subagents returning nothing, then committed unrelated code,
  # scored the same as a clean orchestrator.
  def compute_dispatch_stats(main_sessions)
    # TranscriptSession#session_events already filters to string-keyed
    # Hashes (transcript_session.rb:70-74), so no is_a? guards needed.
    dispatching_sessions = main_sessions.select do |s|
      s.session_events.any? { |e| e["type"] == "subagent_dispatch" }
    end
    return [ 0, nil ] if dispatching_sessions.empty?

    total_dispatches = dispatching_sessions.sum do |s|
      s.session_events.count { |e| e["type"] == "subagent_dispatch" }
    end
    return [ 0, nil ] if total_dispatches.zero?

    with_committed_return = ParallelismAnalyzer.dispatch_with_committed_return_count(dispatching_sessions)
    ratio = (with_committed_return.to_f / dispatching_sessions.size).round(2)
    [ total_dispatches, ratio ]
  end

  def summarize_single(data, system_prompt)
    input = build_episode_input(data)
    retries = 0
    episode_hint = data[:first_prompts]&.first.to_s.truncate(40).presence || data[:episode_id].to_s[0..7]

    begin
      # Rate limit retries are handled by call_llm (AnthropicClient concern)
      response = call_llm(
        model: anthropic_model(:fast),
        max_tokens: 1024,
        system: system_prompt,
        messages: [ { role: "user", content: input } ],
        heartbeat_label: "Scoring \"#{episode_hint}\"...",
        heartbeat: @heartbeat
      )

      text = extract_text(response)
      usage = extract_usage(response)
      parsed = parse_response(text)

      unless parsed
        Rails.logger.debug("EpisodeSummarizer: Episode #{data[:episode_id].to_s[0..7]} — LLM returned no valid scores")
        return nil
      end

      parsed.merge(
        "episode_id" => data[:episode_id],
        "type" => data[:episode_type],
        "input_tokens" => usage[:input_tokens],
        "output_tokens" => usage[:output_tokens],
        "retries" => retries,
        "raw_response" => text
      )
    rescue Timeout::Error => e
      # call_llm already retries Retryable errors internally (up to its budget)
      # and normalizes everything else to PaxelLlmError::*. The only thing we
      # retry at this layer is a bare Timeout::Error escaping out of
      # episode-scoring orchestration (not the LLM call itself).
      retries += 1
      if retries <= MAX_RETRIES
        sleep(retries * 2)
        retry
      end
      Rails.logger.warn("EpisodeSummarizer: Failed after #{MAX_RETRIES} retries: #{e.class}")
      API_FAILURE
    rescue PaxelLlmError::Fatal
      # Fatal LLM errors propagate — the caller (EpisodeSummarizer#score) will
      # re-raise them so the pipeline + rake footer can surface user_action.
      raise
    rescue PaxelLlmError::Retryable => e
      # call_llm already exhausted its retry budget. Record and return the
      # sentinel so the pipeline completes with `failed_api` counts instead
      # of crashing — scoring is best-effort per episode. log_context
      # surfaces request_id / proxy_code for support triage (PR #680).
      Rails.logger.warn("EpisodeSummarizer: LLM retry budget exhausted: #{e.class} - #{e.message.to_s.truncate(80)}#{e.log_context}")
      API_FAILURE
    end
  end

  def build_episode_input(data)
    parts = []
    parts << "Episode type: #{data[:episode_type]}"
    parts << "Sessions: #{data[:session_count]}, Commit groups: #{data[:commit_group_count]}"

    # Ground episode LOC so the LLM never invents a figure. Emitted ONLY when the
    # episode has commit groups carrying real numstat — a 0-commit (session_only)
    # episode gets NO LOC line, and the writing rule forbids inventing one (#12b).
    if data[:commit_group_count].to_i.positive? && (data[:added_lines].to_i + data[:deleted_lines].to_i).positive?
      parts << "Code volume: +#{data[:added_lines].to_i}/-#{data[:deleted_lines].to_i} lines (from this episode's commits)"
    end

    if data[:episode_type] == "session_only" && data[:session_intents].present?
      tally = data[:session_intents]
      max_count = tally.values.max
      winners = tally.select { |_, c| c == max_count }.keys
      dominant_intent = winners.size == 1 ? winners.first : "ambiguous"
      parts << "Session intent: #{dominant_intent}"
    end

    # Drop the injected Codex system preamble and de-dup so episode scoring never
    # reads N identical "duplicate, zero-direction" first prompts (audit CL41). The
    # discoverer now derives a real first prompt for fresh sessions; this also guards
    # already-persisted pre-fix sessions on re-score without re-discovery.
    clean_first_prompts = Array(data[:first_prompts])
      .reject { |p| p.to_s.lstrip.start_with?("You are Codex") }
      .uniq
    if clean_first_prompts.any?
      parts << "First prompts: #{clean_first_prompts.first(5).join(' | ')}"
    end

    if data[:narratives].present?
      parts << "## Session Narratives\n#{data[:narratives]}"
    end

    if data[:code_reviews].present?
      parts << "## Code Reviews\n#{data[:code_reviews]}"
    end

    if data[:user_highlights].present?
      parts << "## User Highlights\n#{data[:user_highlights]}"
    end

    if data[:decision_summary].present?
      parts << "## Decision Exchanges\n#{data[:decision_summary]}"
    end

    if data[:plan_files].present? && data[:plan_files].any?
      plan_parts = data[:plan_files].map { |pf|
        "### #{pf[:filename]} (#{pf[:version_count]} version(s))\n#{pf[:content]}"
      }
      parts << "## Plan Files\n#{plan_parts.join("\n\n")}"
    end

    if data[:signals].any?
      signals_summary = summarize_signals(data[:signals])
      parts << "## Session Signals\n#{signals_summary}"
    end

    # v8+: structured dispatch stats for the EL axis. Only emitted when the
    # episode has dispatches — a zero-dispatch episode carries no signal
    # and would waste tokens + tempt the rubric toward low-EL framing even
    # when the episode legitimately doesn't orchestrate.
    if data[:dispatch_count].to_i.positive?
      ratio = data[:dispatch_with_committed_return_ratio]
      ratio_str = ratio.nil? ? "n/a" : format("%.2f", ratio)
      parts << "## Subagent Dispatch Activity\nDispatches: #{data[:dispatch_count]} | Committed-return ratio: #{ratio_str} (fraction of dispatching main sessions where the dispatch→return→ship loop closed at least once; 1.0 = all, 0.0 = none)"
    end

    parts.join("\n\n")
  end

  def summarize_decisions(decisions)
    return nil if decisions.empty?

    lines = decisions.first(10).map do |d|
      outcome = d.outcome_analyses.order(analyzed_at: :desc).first
      signal = outcome ? " -> #{outcome.outcome_signal}" : ""
      tags = []
      tags << "COUNTER-PROPOSAL" if d.proposal_type == "counter_proposal"
      tags << "PROACTIVE-INSIGHT" if d.proposal_type == "proactive_insight"
      tags << "AGENT-RECOGNIZED" if d.agent_recognized?
      tag_str = tags.any? ? " [#{tags.join(', ')}]" : ""
      chain_info = d.in_chain? ? " [chain #{d.chain_position}]" : ""
      "[#{d.domain}/#{d.significance}#{tag_str}#{chain_info}] Agent: #{d.proposal_text.to_s.truncate(100)} | Dev: #{d.response_text.to_s.truncate(100)}#{signal}"
    end

    counter_count = decisions.count { |d| d.proposal_type == "counter_proposal" }
    proactive_count = decisions.count { |d| d.proposal_type == "proactive_insight" }
    recognized_count = decisions.count(&:agent_recognized?)
    chain_count = decisions.select(&:in_chain?).map(&:exchange_chain_id).uniq.size

    summary = "#{decisions.size} decision exchange(s) detected."
    summary += " #{counter_count} counter-proposal(s)." if counter_count > 0
    summary += " #{proactive_count} proactive insight(s)." if proactive_count > 0
    summary += " #{recognized_count} agent-recognized." if recognized_count > 0
    summary += " #{chain_count} exchange chain(s)." if chain_count > 0
    "#{summary}\n#{lines.join("\n")}"
  end

  def summarize_signals(signals_list)
    aggregated = Hash.new(0)
    signals_list.each do |signals|
      next unless signals.is_a?(Hash)
      %w[kill_decisions self_corrections hypothesis_driven domain_corrections
         debugging_messages architecture_discussions product_references
         imperative_prompts review_checks critiques].each do |key|
        aggregated[key] += signals[key].to_i
      end
    end
    aggregated.select { |_, v| v > 0 }.map { |k, v| "#{k}: #{v}" }.join(", ")
  end

  def parse_response(text)
    # Strip proxy nonce comments before parsing (<!-- yc_verify:req_id:hmac -->)
    clean_text = text.gsub(/<!--\s*yc_verify:[^>]+-->/, "").strip
    parsed = extract_json(clean_text)
    return nil unless parsed

    # Validate and clamp scores
    scores = parsed["scores"]
    return nil unless scores.is_a?(Hash)

    # Normalize any legacy axis keys the LLM may emit while the v6→v7
    # prompt cache rolls over.
    AXIS_ALIASES.each do |legacy, canonical|
      scores[canonical] ||= scores.delete(legacy) if scores.key?(legacy)
    end

    SCORE_AXES.each do |axis|
      val = scores[axis]
      if val.is_a?(Numeric)
        scores[axis] = val.to_f.clamp(1.0, 10.0)
      elsif val.is_a?(String) && val.match?(/\A[\d.]+\z/)
        scores[axis] = val.to_f.clamp(1.0, 10.0)
      else
        scores.delete(axis)
      end
    end

    {
      "title" => parsed["title"].to_s.truncate(160),
      "facts" => parsed["facts"].to_s,
      "interpretation" => parsed["interpretation"].to_s,
      "counterweight" => parsed["counterweight"].to_s,
      "confidence" => (parsed["confidence"] || 0.5).to_f.clamp(0.0, 1.0),
      "scores" => scores
    }
  rescue JSON::ParserError => e
    Rails.logger.warn("EpisodeSummarizer: JSON parse failed: #{e.message}")
    nil
  end
end
