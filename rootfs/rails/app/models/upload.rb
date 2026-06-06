class Upload < ApplicationRecord
  # Status machine:
  #   pending -> extracting -> parsing -> analyzing -> aggregating -> complete
  #                                                               \-> failed (from any)

  belongs_to :user, optional: true
  belongs_to :committer, optional: true
  has_one_attached :archive
  has_many :projects, dependent: :destroy
  has_many :evidence_chunks, dependent: :destroy
  has_many :episodes, dependent: :destroy
  has_many :chat_conversations, dependent: :destroy
  has_many :decisions, dependent: :destroy
  has_many :llm_calls, dependent: :delete_all
  has_many :partner_notes, dependent: :destroy

  # service_name written by the (server-only) ChatStreamService — interactive
  # chat isn't part of report-production cost, so it's excluded from the per-upload
  # LLM totals below. Upload is a SHARED (client + server) model, so the name is
  # resolved through a `defined?` guard: this keeps the literal out of the
  # client-image whitelist scan (spec/docker/client_image_spec.rb) and is safe to
  # load in the client image, where ChatStreamService isn't compiled in.
  # (IS DISTINCT FROM below keeps the filter NULL-safe though service_name is NOT NULL.)
  CHAT_LLM_SERVICE = defined?(ChatStreamService) ? ChatStreamService.name : "ChatStreamService"

  STATUSES = %w[pending extracting parsing analyzing aggregating complete failed].freeze

  validates :slug, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  before_validation :generate_slug, on: :create

  # Live LLM totals for THIS upload's report-production calls (excludes
  # interactive chat). The stored total_*_cents / total_*_tokens columns are a
  # finalize-time snapshot that goes stale as post-finalize jobs (insights, judge,
  # narrative regen) add cost — read this for accurate per-upload display. (The
  # admin cost view aggregates the llm_calls table directly and is unaffected.)
  def current_llm_totals
    scope = llm_calls.where("service_name IS DISTINCT FROM ?", CHAT_LLM_SERVICE)
    {
      cost_cents: scope.sum(:cost_cents),
      input_tokens: scope.sum(:input_tokens),
      output_tokens: scope.sum(:output_tokens)
    }
  end

  def current_llm_cost_cents
    current_llm_totals[:cost_cents]
  end

  scope :recent, -> { order(created_at: :desc) }
  scope :complete, -> { where(status: "complete") }

  # Latest complete upload per user (deduped). Used by leaderboard + trajectory.
  # Two-step: subquery gets latest ID per user, outer query sorts by score.
  scope :latest_per_user, -> {
    latest_ids = Upload.complete
      .where(scoring_pipeline: "v3_behavior") # exclude re-scored uploads whose latest run failed but kept stale v3_results (audit W1)
      .where.not(v3_results: nil)
      .where.not(user_id: nil)
      .select("DISTINCT ON (user_id) id")
      .order("user_id, created_at DESC")
    where(id: latest_ids)
  }

  # Phase-aware progress. Without this, `aggregating` (server-side synthesis
  # after the client upload finishes) displays 100% because session-analysis
  # is already done at that point. Client pipeline reaches ~85%; the server
  # phase carries it to complete.
  def progress_percentage
    case status
    when "complete" then 100
    when "failed"   then 0
    when "pending", "extracting" then 2
    when "parsing" then 10
    when "analyzing"
      return 15 if total_sessions_count.zero?
      session_ratio = analyzed_sessions_count.to_f / total_sessions_count
      (15 + session_ratio * 70).round
    when "aggregating" then 90
    else
      return 0 if total_sessions_count.zero?
      ((analyzed_sessions_count.to_f / total_sessions_count) * 100).round
    end
  end

  def complete?
    status == "complete"
  end

  def failed?
    status == "failed"
  end

  def processing?
    !complete? && !failed?
  end

  def has_narratives?
    aggregate_narrative.present? || v3_results&.dig("axes").present?
  end

  # True only when v3_results came from a SUCCESSFUL v3 scoring run, so it is safe
  # to display/aggregate the score, band, and axes. A re-scored upload whose latest
  # run failed keeps scoring_pipeline="v3_failed" but still carries the PRIOR run's
  # v3_results in the column — displaying that is a stale/wrong score (audit W1).
  # Mirrors the inline gate already used in _score_tabs / _sidebar_nav.
  def v3_scores_displayable?
    scoring_pipeline == "v3_behavior" && v3_results.present?
  end

  # True when the code-quality dimensions describe the whole codebase / full git
  # history rather than just this builder's recent work (the analyzer scans the
  # working tree + full git log with no author filter). Used to suppress false
  # cross-modal "intention-action gap" divergences (ServerScoringJob#compute_cross_modal)
  # and to caveat the narrative's code-quality section so repo-wide metrics (file
  # counts, commit cadence, rescue/LOC totals) aren't attributed to the individual.
  # Signals: a very large tree (file_count >= 10_000) or the `git log -n 5000`
  # commit cap — both indicate a big/whole-history repo whose metrics are
  # whole-codebase, not the individual's; OR direct multi-contributor evidence
  # (more than one git author, or a repo commit count that dwarfs the uploader's
  # own author-scoped commits). The thresholds are intentionally the HARD scan
  # caps, not "large", so a big SOLO repo below them isn't mislabeled. (Pre-v3
  # uploads pinned file_count at exactly MAX_FILES=10000 because the file walk
  # was capped; v3+ reports the true count — see LocalCodeQualityAnalyzer finding
  # #4 — so the >= 10_000 test now reads as "≥10k-file repo", which is the same
  # whole-repo signal.)
  def code_quality_repo_wide?
    cq = v3_results&.dig("code_quality") || {}
    dims = cq["dimensions"] || {}
    return false if dims.blank?
    # Prefer the value cached by ServerScoringJob#import_code_quality from the
    # ORIGINAL whole-repo dims. #3a author-scoping rewrites commit_discipline.total_commits
    # (read below) to the uploader's own count; without this cache, a re-read after
    # scoping would flip the gate and silently disable cross-modal suppression + the
    # narrative repo-wide caveat. The computation below is the flag's source on first run.
    return cq["repo_wide"] if cq.key?("repo_wide")
    return true if cq["file_count"].to_i >= 10_000 # ≥10k-file repo → whole-repo metrics
    repo_commits = dims.dig("commit_discipline", "total_commits").to_i
    return true if repo_commits >= 5_000 # `git log -n 5000` cap → whole-history commit metrics
    projects.any? do |project|
      gm = project.git_metrics || {}
      authors = gm.dig("velocity", "authors")
      # NOTE: authors.size > 1 also fires on bot / co-author history
      # (dependabot[bot], Co-authored-by trailers), not only multi-human repos.
      next true if authors.is_a?(Hash) && authors.size > 1
      author_commits = gm.dig("author_velocity", "commits").to_i
      author_commits.positive? && repo_commits > author_commits * 2
    end
  end

  # Analyzed main sessions grouped by the tool that produced them, e.g.
  # { "claude_code" => 5, "codex_cli" => 2 }. Same population as
  # analyzed_sessions_count (logical_roots with a completed narrative — see
  # FinalizeUploadJob's reconciliation), so the per-tool counts sum to the
  # headline count. Returns {} when no sessions resolved (e.g. client uploads
  # that shipped no stub sessions). Used by SlackNotifier for the completion
  # log. NB: this is a stricter population than ResultsHelper#per_tool_session_summary,
  # which counts main_sessions with no narrative filter — that one won't sum to
  # the headline count, so don't swap one for the other.
  def analyzed_tool_counts
    projects.joins(:transcript_sessions)
      .merge(TranscriptSession.logical_roots)
      .where(transcript_sessions: { narrative_status: %w[complete low_quality] })
      .group("transcript_sessions.agent_type")
      .count
  end

  # A report can only be shared publicly once it's a finished, viewable report.
  # The owner toggles `shared` on the report page (results#share); the gate here
  # keeps a pending/failed upload from being exposed via a stale public link.
  def shareable?
    complete? && has_narratives?
  end

  # Whether an anonymous (or non-owner) visitor may view this report. Sharing is
  # off by default and only meaningful for a finished report.
  def publicly_viewable?
    shared? && shareable?
  end

  # Typed view of the claims_v1 JSONB column. Returns nil when empty or
  # when schema_version doesn't match the current ClaimsStorage version —
  # callers (view fallback) render the legacy surface in that case.
  def claims_v1_deserialized
    @claims_v1_deserialized ||= Agentic::ClaimsStorage.deserialize(claims_v1)
  end

  # The most recent prior completed upload for the same user with a
  # non-empty claims_v1. Returns nil on the user's first upload — callers
  # should treat nil as "no diff yet" (the Phase 1 foundation handoff's
  # first-upload-is-wow-moment contract).
  #
  # Skips uploads with empty claims_v1 (pre-Phase-1 rows, or rows whose
  # scoring failed mid-flight and left claims_v1 = {}). Self-excluded via
  # id comparison so a rescore-in-flight doesn't diff against itself.
  def prior_complete_upload_with_claims
    return nil unless user_id.present?
    return nil unless created_at.present?
    self.class
      .where(user_id: user_id, status: "complete")
      .where.not(id: id)
      .where.not(claims_v1: {})
      .where("created_at < ?", created_at)
      .order(created_at: :desc)
      .first
  end

  # Compact spine summary for injection into narrative service prompts.
  # Returns a short multi-line text block grounding the LLM in the spine's
  # current claims (mode, shift_or_watchpoint, recognition). Returns nil
  # when claims_v1 is empty — callers should skip the block in that case.
  #
  # Used by V3NarrativeAggregator, BuilderProfileService, and
  # BuilderInsightsService so all three narrative surfaces reference the
  # same spine that the results page renders, instead of re-synthesizing
  # parallel views from raw signals.
  def spine_summary_for_prompt
    claims = claims_v1_deserialized
    return nil unless claims

    mode = claims[:operating_mode]
    sow = claims[:shift_or_watchpoint]
    rec = claims[:recognition] || []

    lines = []
    lines << "Operating mode: #{mode.mode} (#{mode.confidence} confidence)" if mode
    lines << "Mode reasoning: #{mode.reasoning}" if mode && mode.reasoning.present?

    # Orchestrator density: one line when the scorer actually picked
    # :orchestrator. Cached on parallelism_signals so the read is a single
    # JSONB column — no re-walk of session_events. No new section; just an
    # extra fact the polish prompt can quote.
    if mode && mode.mode == :orchestrator && parallelism_signals.is_a?(Hash)
      d = parallelism_signals["dispatch_with_committed_return_count"].to_i
      c = parallelism_signals["concurrent_pairs_with_ships_count"].to_i
      r = parallelism_signals["review_separation_count"].to_i
      lines << "Dispatch pattern: #{d} dispatch(es) returned committed code, #{c} concurrent pair(s) shipped independently, #{r} reviewer/implementer split."
    end

    case sow
    when Agentic::OperatingShift
      delta = sow.expected_delta || {}
      lines << "Spine: Shift (confidence #{sow.confidence})."
      lines << "Mechanism: #{sow.mechanism}" if sow.mechanism.present?
      lines << "Measurement target: #{sow.measurement_target}" if sow.measurement_target.present?
      if delta[:metric].present?
        lines << "Expected delta: #{delta[:metric]} from #{delta[:from]} to #{delta[:to]}"
      end
    when Agentic::Watchpoint
      lines << "Spine: Watchpoint (abstention — evidence too thin for a Shift)."
      lines << "What we watch: #{sow.what_we_watch}" if sow.what_we_watch.present?
      lines << "Why we abstained: #{sow.why}" if sow.why.present?
    end

    if rec.any?
      types = rec.map(&:event_type).tally.map { |t, n| n > 1 ? "#{t}×#{n}" : t.to_s }.join(", ")
      lines << "Recognition: #{rec.size} span#{'s' if rec.size != 1} (#{types})"
      # G15: include authored Recognition prose when present so downstream
      # prompts (BuilderProfileService, BuilderInsightsService) can quote
      # concrete observed moves instead of only the event-type tally.
      # Tier 2 Direction A authored these per span; without this line they
      # were effectively unreadable by the cascade. Take first 5 to keep
      # the spine block under ~800 tokens even on dense uploads.
      #
      # Normalize whitespace before injecting: if ClaimsBuilderService
      # ever returns a multi-line prose string, the raw value would
      # introduce extra prompt structure for just this upload. Collapse
      # internal whitespace runs to single spaces so every entry renders
      # as exactly one bullet line.
      prose = claims[:recognition_prose]
      if prose.is_a?(Array) && prose.compact.any?
        prose.compact.take(5).each do |p|
          normalized = p.to_s.gsub(/\s+/, " ").strip
          lines << "- #{normalized}" unless normalized.empty?
        end
      end
    end

    return nil if lines.empty?
    lines.join("\n")
  end

  # --- Prompt versioning ---

  # Returns stage group names whose prompt versions are outdated,
  # including cascaded downstream stages.
  def stale_stages
    PromptVersionRegistry.stale_stages(prompt_versions)
  end

  # True if all stages match current prompt versions.
  def prompt_versions_current?
    stale_stages.empty?
  end

  # Record sync stage prompt versions at pipeline completion.
  # Only records versions for stages that actually produced results.
  # Stages that failed are left unversioned so they show as stale.
  # Async stages (insights, judge) record themselves via record_stage_version!
  # Uses atomic JSONB merge to avoid race conditions with async jobs.
  def record_prompt_versions!
    versions = PromptVersionRegistry.sync_versions
    # Don't record scoring/narrative versions if V3 scoring failed
    if v3_scoring_status.present? && v3_scoring_status != "complete"
      versions = versions.except("episode_scoring", "narratives")
    end
    versions["recorded_at"] = Time.current.iso8601
    merge_prompt_versions!(versions)
  end

  # Record a single async stage version (called by background jobs).
  # Uses atomic JSONB merge to avoid race conditions with other writers.
  def record_stage_version!(stage)
    version = PromptVersionRegistry.version_for(stage)
    merge_prompt_versions!(stage => version)
  end

  # Mark a stage as not applicable for this upload (e.g., judge for client uploads).
  # Skipped stages are not considered stale.
  def skip_stage!(stage)
    merge_prompt_versions!(stage => PromptVersionRegistry::SKIPPED)
  end

  private

  # Atomically merge keys into prompt_versions JSONB column.
  # Uses PostgreSQL || operator to avoid read-modify-write races.
  def merge_prompt_versions!(new_data)
    if connection_pg?
      Upload.where(id: id).update_all([
        "prompt_versions = COALESCE(prompt_versions, '{}'::jsonb) || ?::jsonb",
        new_data.to_json
      ])
      reload
    else
      # SQLite fallback (dev/test/client): read-modify-write is acceptable
      raw = Upload.where(id: id).pick(:prompt_versions)
      current = raw.is_a?(String) ? (JSON.parse(raw) rescue {}) : (raw || {})
      Upload.where(id: id).update_all(prompt_versions: current.merge(new_data).to_json)
      reload
    end
  end

  public

  # Snapshot current results before overwriting (capped at 3 entries).
  MAX_PREVIOUS_RESULTS = 3

  def snapshot_results!
    snapshot = {
      "snapshotted_at" => Time.current.iso8601,
      "prompt_versions" => prompt_versions,
      "v3_results" => v3_results,
      "aggregate_narrative" => aggregate_narrative&.truncate(50_000),
      "claims_v1" => claims_v1,
      "builder_profile_data" => builder_profile_data,
      "builder_profile_narrative" => builder_profile_narrative&.truncate(50_000),
      "verdict_line" => verdict_line,
      "chat_greeting" => chat_greeting&.truncate(10_000),
      "growth_edge" => growth_edge&.truncate(10_000),
      "builder_profile_roast" => builder_profile_roast&.truncate(10_000),
      "builder_profile_vague_prompts" => builder_profile_vague_prompts
    }
    history = (previous_results || []).last(MAX_PREVIOUS_RESULTS - 1)
    update!(previous_results: history + [ snapshot ])
  end

  def log_step(step, message)
    entry = { "at" => Time.current.iso8601, "step" => step, "msg" => message }
    if connection_pg?
      Upload.where(id: id).update_all([ "processing_log = processing_log || ?::jsonb", [ entry ].to_json ])
    else
      raw = Upload.where(id: id).pick(:processing_log)
      current_log = raw.is_a?(String) ? (JSON.parse(raw) rescue []) : (raw || [])
      Upload.where(id: id).update_all(processing_log: (current_log + [ entry ]).to_json)
    end
  end

  def connection_pg?
    self.class.connection.adapter_name.downcase.include?("postgresql")
  end

  private

  def generate_slug
    self.slug ||= loop do
      candidate = SecureRandom.alphanumeric(8).downcase
      break candidate unless Upload.exists?(slug: candidate)
    end
  end
end
