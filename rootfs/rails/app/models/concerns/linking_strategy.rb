# Shared 4-tier priority linking between sessions and commit-based sources.
# Used by EvidenceLinker (commits <-> sessions) and EpisodeLinker (episodes <-> sessions).
module LinkingStrategy
  extend ActiveSupport::Concern

  TIMESTAMP_TOLERANCE = 1.hour

  # Returns [link_type, confidence] or nil if no match.
  # source must respond to: pr_number, commit_shas, branch, earliest_commit_at, latest_commit_at
  # session must respond to: pr_number, git_commits, git_branch, session_created_at, session_modified_at
  def best_link(source, session)
    # Priority 1: PR match
    if source.pr_number.present? && session.pr_number == source.pr_number
      return [ "pr_match", 1.0 ]
    end

    # Priority 2: SHA match — prefer session_events, fallback to git_commits
    source_shas = source.respond_to?(:commit_shas) ? (source.commit_shas || []) : []
    session_shas = session.respond_to?(:event_git_shas) ? session.event_git_shas : []
    if session_shas.empty?
      session_shas = (session.git_commits || []).map { |c| c.is_a?(Hash) ? c["sha"] : c.to_s }
      Rails.logger.info("LinkingStrategy: fallback to git_commits for session #{session.id}") if session_shas.any?
    end
    if session_shas.any? && (source_shas & session_shas).any?
      return [ "sha_match", 0.9 ]
    end

    # Priority 3: Branch match — prefer event_branches, fallback to git_branch
    source_branch = source.respond_to?(:branch) ? source.branch : nil
    session_branch = session.respond_to?(:event_branches) ? session.event_branches.last : nil
    session_branch ||= session.git_branch
    if source_branch.present? && session_branch.present? && source_branch == session_branch
      return [ "branch_match", 0.7 ]
    end

    # Priority 4: Timestamp overlap
    if timestamp_overlap?(source, session)
      return [ "timestamp_overlap", 0.5 ]
    end

    nil
  end

  def timestamp_overlap?(source, session)
    session_start, session_end = session_time_range(session)
    return false if session_start.nil? || session_end.nil?

    commit_start = source.respond_to?(:earliest_commit_at) ? source.earliest_commit_at : nil
    commit_end = source.respond_to?(:latest_commit_at) ? source.latest_commit_at : nil
    commit_start ||= commit_end
    commit_end ||= commit_start
    return false if commit_start.nil?

    session_start -= TIMESTAMP_TOLERANCE
    session_end += TIMESTAMP_TOLERANCE

    session_start <= commit_end && commit_start <= session_end
  end

  def session_time_range(session)
    if session.session_created_at.present? && session.session_modified_at.present?
      return [ session.session_created_at, session.session_modified_at ]
    end

    # Try event timestamps first
    if session.respond_to?(:event_git_commits)
      event_timestamps = session.event_git_commits.filter_map { |e|
        ts = e["timestamp"]
        Time.parse(ts) rescue nil if ts
      }.sort
      return [ event_timestamps.first, event_timestamps.last ] if event_timestamps.any?
    end

    # Fallback to git_commits
    timestamps = (session.git_commits || []).filter_map { |c|
      ts = c.is_a?(Hash) ? c["timestamp"] : nil
      Time.parse(ts) rescue nil if ts
    }.sort

    return [ nil, nil ] if timestamps.empty?
    [ timestamps.first, timestamps.last ]
  end
end
