# Single owner of orchestration + parallelism signals for an upload.
#
# Consumed by:
#   - AgenticProficiencyScorer (Orchestrator mode gate + spine density)
#   - synthetic_datasets/ArchetypeMetrics (concurrent_subagent_pairs delegate)
#   - synthetic_datasets/ArchetypeClassifier (rubric_gamer predicate)
#   - admin dashboard orchestration panel
#   - /status endpoint reads cached Upload#parallelism_signals instead of
#     recomputing — keep the instance-level work server-side + post-scoring
#
# All four signals honor Manifesto Rule 3: concurrency without closure scores
# zero. Every count below is outcome-gated.
class ParallelismAnalyzer
  attr_reader :upload

  def initialize(upload)
    @upload = upload
  end

  # Memoized snapshot. Persisted onto Upload.parallelism_signals by
  # ServerScoringJob after scoring so /status + admin don't recompute.
  def signals
    @signals ||= {
      "dispatch_with_committed_return_count" => dispatch_with_committed_return_count,
      "concurrent_pairs_with_ships_count" => concurrent_pairs_with_ships_count,
      "review_separation_count" => review_separation_count,
      "orphan_subagent_count" => orphan_subagent_count,
      "dispatch_count" => total_dispatch_count,
      "return_count" => total_return_count,
      "subagent_count" => subagent_sessions.size,
      # Phase 5 — cross-tool delegation signals fed to AgenticProficiencyScorer
      # via spine_context. Counted SEPARATELY from internal subagent dispatches
      # (dispatch_with_committed_return_count above) so attribution stays clear
      # in claims_v1 reasoning. The scorer combines these with the internal
      # count when computing the Orchestrator gate; see classify_mode +
      # cross_tool_credit for the diminishing-returns formula.
      "cross_tool_delegation_count" => cross_tool_delegation_count,
      "cross_tool_child_completed_count" => cross_tool_child_completed_count
    }
  end

  # Main sessions with (a) at least one dispatch that was matched by a
  # `subagent_return` event via tool_use_id AND (b) at least one child
  # subagent session that shipped committed code. Both halves are required:
  # without the matched-return half, `run_in_background: true` tasks that
  # never produced a tool_result would still count even though the
  # "committed return" contract says the parent observed the result.
  # "Shipped" proxy: the subagent session itself has a git_commit event
  # OR is linked via commit_group_sessions to a commit group.
  def dispatch_with_committed_return_count
    self.class.dispatch_with_committed_return_count(main_sessions)
  end

  # Class-level variant for callers that need the same count over a bounded
  # subset of main sessions (e.g. per-episode in EpisodeSummarizer) without
  # constructing an analyzer scoped to the whole upload. Identical semantics
  # to the instance method; both route through the same predicate so the
  # episode-level EL signal always matches the upload-level orchestrator
  # gate exactly.
  def self.dispatch_with_committed_return_count(main_sessions)
    main_sessions.count do |main|
      dispatches = main.events_of_type("subagent_dispatch")
      next false if dispatches.empty?
      return_ids = main.events_of_type("subagent_return").filter_map { |e| e["tool_use_id"] }.to_set
      next false if return_ids.empty?
      next false unless dispatches.any? { |d| return_ids.include?(d["tool_use_id"]) }
      children = main.subagent_sessions.to_a
      next true if children.any? { |child| subagent_shipped?(child) }
      parent_committed_after_return?(main)
    end
  end

  # True when main.session_events contains a git_commit positioned after a
  # subagent_return. Client-pipeline fallback: EpisodeSummarizer runs
  # locally (client_pipeline.rb:467) before EvidenceLinker/
  # CommitGroupSession links exist, so when the parent integrates returned
  # subagent code into its own commit, the child has no ship signal yet.
  # Weaker proxy, but the outer matched-return check in
  # dispatch_with_committed_return_count already rules out the v8 theater
  # pattern (unrelated parent commit, no matched returns).
  def self.parent_committed_after_return?(main)
    events = main.session_events
    return false if events.empty?
    first_return_idx = events.find_index { |e| e["type"] == "subagent_return" }
    return false unless first_return_idx
    events[(first_return_idx + 1)..].any? { |e| e["type"] == "git_commit" }
  end

  # Exposed at the class level so EpisodeSummarizer and other callers can
  # score child subagent ship-status consistently with the instance scorer.
  def self.subagent_shipped?(session)
    return true if session.event_git_commits.any?
    session.commit_group_sessions.any?
  end

  # Pairs of concurrent subagent sessions (same parent, active-interval overlap
  # at PARALLELISM_GAP_MINUTES) where BOTH siblings shipped independently. A
  # pair only counts if both sides have an outcome; parallel junk doesn't.
  def concurrent_pairs_with_ships_count
    pairs = 0
    # Skip the nil-parent bucket: orphan subagents (parent_session_id = nil)
    # from different true parents would otherwise land in the same "siblings"
    # group and produce false pair counts on malformed uploads.
    subagent_sessions.reject { |s| s.parent_session_id.nil? }
      .group_by(&:parent_session_id).each_value do |siblings|
      next if siblings.size < 2
      siblings.combination(2).each do |a, b|
        next unless active_windows_overlap?(a, b)
        next unless subagent_shipped?(a) && subagent_shipped?(b)
        pairs += 1
      end
    end
    pairs
  end

  # Implementer/reviewer separation signal per orchestrator_mode/calibration.md:
  # "same feature touched by two distinct session_ids of the same parent" is the
  # load-bearing heuristic. We proxy "same feature" as two subagent sessions of
  # the same parent that share ≥1 commit_group via commit_group_sessions. Keeps
  # the signal session-level (not file-level) per the ratified card.
  def review_separation_count
    count = 0
    # Skip the nil-parent bucket for the same reason as concurrent_pairs —
    # orphans mustn't pair with each other.
    subagent_sessions.reject { |s| s.parent_session_id.nil? }
      .group_by(&:parent_session_id).each_value do |siblings|
      next if siblings.size < 2
      siblings.combination(2).each do |a, b|
        shared = a.commit_groups.pluck(:id) & b.commit_groups.pluck(:id)
        count += 1 if shared.any?
      end
    end
    count
  end

  # Admin-triage signal: subagents that couldn't be linked to a parent. Exposed
  # in parallelism_signals so the dashboard panel doesn't need its own query.
  def orphan_subagent_count
    subagent_sessions.count { |s| s.parent_session_id.nil? }
  end

  # Phase 5 — count of PARENT main sessions with ≥1 cross-tool child whose
  # narrative is "complete" or "low_quality". Outcome-gated per Manifesto
  # Rule 3: a Codex session that didn't produce analyzable text shouldn't
  # credit the parent. low_quality is included to align with timeline + the
  # CrossToolNarrativeEnricher (FinalizeUploadJob/ServerScoringJob), both of
  # which surface low-quality children as supporting beats. Distinct from
  # cross_tool_child_completed_count (the child total used for diminishing-
  # returns calculation in AgenticProficiencyScorer.cross_tool_credit).
  def cross_tool_delegation_count
    main_sessions.count do |main|
      main.cross_tool_children.any? { |c| %w[complete low_quality].include?(c.narrative_status) }
    end
  end

  # Phase 5 — total count of CROSS-TOOL CHILDREN across all parents with
  # narratives that completed (or low_quality). Fed to cross_tool_credit
  # for the sqrt-tapered diminishing-returns formula past
  # CROSS_TOOL_DIMINISHING_AT children.
  def cross_tool_child_completed_count
    main_sessions.sum do |main|
      main.cross_tool_children.count { |c| %w[complete low_quality].include?(c.narrative_status) }
    end
  end

  # Totals used by admin aggregates + the Orchestrator reasoning line.
  def total_dispatch_count
    main_sessions.sum { |s| s.dispatch_metadata&.dig("dispatch_count").to_i }
  end

  def total_return_count
    main_sessions.sum { |s| s.dispatch_metadata&.dig("return_count").to_i }
  end

  private

  def main_sessions
    # logical_roots — exclude subagents AND cross-tool children. Cross-tool
    # children are synchronously dispatched, NOT genuine concurrent work.
    @main_sessions ||= upload.projects
      .flat_map { |p| p.transcript_sessions.includes(:subagent_sessions).logical_roots.to_a }
  end

  def subagent_sessions
    @subagent_sessions ||= upload.projects
      .flat_map { |p| p.transcript_sessions.where(is_subagent: true).to_a }
  end

  # A subagent session counts as "shipped" if either (a) it emitted at least one
  # git_commit event on its own, or (b) it's joined to ≥1 commit_group via
  # commit_group_sessions (the parent committed files the subagent produced).
  # Delegates to the class method so instance + class use the same rule.
  def subagent_shipped?(session)
    self.class.subagent_shipped?(session)
  end

  # Active-interval overlap test. Each session's active_time_windows is an
  # array of [start_iso, end_iso] pairs after PARALLELISM_GAP_MINUTES=15 gap-
  # split in TranscriptChunker. Two sessions "overlap" if ANY of a's windows
  # intersects ANY of b's windows. Falls back to session_created_at ..
  # session_modified_at span only when active_time_windows is empty — a safety
  # net for sessions chunked before active_time_windows existed; these
  # legacy sessions will still match on the coarse span but won't benefit from
  # the 15-min tightening.
  def active_windows_overlap?(a, b)
    a_windows = parse_windows(a)
    b_windows = parse_windows(b)
    return false if a_windows.empty? || b_windows.empty?
    a_windows.any? do |a_start, a_end|
      b_windows.any? do |b_start, b_end|
        [ a_end, b_end ].min >= [ a_start, b_start ].max
      end
    end
  end

  def parse_windows(session)
    raw = session.active_time_windows
    if raw.is_a?(Array) && raw.any?
      raw.filter_map do |pair|
        next unless pair.is_a?(Array) && pair.size == 2
        start_t = Time.parse(pair[0].to_s) rescue nil
        end_t = Time.parse(pair[1].to_s) rescue nil
        [ start_t, end_t ] if start_t && end_t
      end
    elsif session.session_created_at && session.session_modified_at
      [ [ session.session_created_at, session.session_modified_at ] ]
    else
      []
    end
  end
end
