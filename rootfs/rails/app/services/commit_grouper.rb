class CommitGrouper
  CLUSTER_GAP = 2.hours
  MAX_COMBINED_DIFF = 500 * 1024 # 500KB
  MAX_INDIVIDUAL_DIFF = 100 * 1024 # 100KB

  SECRET_PATTERNS = [
    /(?:sk-[a-zA-Z0-9]{20,})/,
    /(?:AKIA[0-9A-Z]{16})/,
    /(?:ghp_[a-zA-Z0-9]{36})/,
    /(?:gho_[a-zA-Z0-9]{36})/,
    /(?:github_pat_[a-zA-Z0-9_]{22,})/,
    /(?:xox[bpsar]-[a-zA-Z0-9\-]+)/,
    /(?:password|passwd|secret|token)\s*[=:]\s*.+/i
  ].freeze

  def self.group!(project)
    new(project).group!
  end

  def initialize(project)
    @project = project
    @commit_diffs = project.commit_diffs || {}
    @grouped_shas = Set.new

    # Prefer author-filtered data for grouping (wider session date coverage).
    # Switch both commits AND numstat together to keep SHA alignment.
    if project.author_recent_commits.present?
      @commits = project.author_recent_commits
      @numstat = project.git_metrics&.dig("author_numstat") || {}
      Rails.logger.info("[CommitGrouper] Using author-filtered data: #{@commits.size} commits, #{@numstat.size} numstat entries")
    else
      @commits = project.recent_commits || []
      @numstat = project.git_metrics&.dig("numstat") || {}
    end
  end

  def group!
    create_pr_groups
    create_commit_clusters
    create_single_commit_groups
  end

  private

  def create_pr_groups
    sessions_with_pr = @project.transcript_sessions.where.not(pr_number: nil)
    sessions_with_pr.each do |session|
      pr_number = session.pr_number
      next if pr_number.blank?

      # Find commits that mention this PR
      pr_shas = @commits.select { |c| c["subject"]&.include?("##{pr_number}") }.map { |c| c["sha"] }

      diff = session.pr_diff.presence || combine_diffs(pr_shas)
      diff = strip_secrets(diff) if diff.present?

      dates = parse_commit_dates(pr_shas)

      cg = CommitGroup.find_or_create_by!(project: @project, pr_number: pr_number) do |g|
        g.group_type = "pr"
        g.title = "PR ##{pr_number}"
        g.branch = session.git_branch
        g.commit_shas = pr_shas
        g.combined_diff = diff&.truncate(MAX_COMBINED_DIFF, omission: "\n... [diff truncated]")
        g.diff_lines = diff&.lines&.count || 0
        assign_loc_stats(g, pr_shas, diff)
        g.earliest_commit_at = dates.first
        g.latest_commit_at = dates.last
      end

      @grouped_shas.merge(pr_shas)
    end
  end

  def create_commit_clusters
    ungrouped = @commits.reject { |c| @grouped_shas.include?(c["sha"]) }
    return if ungrouped.empty?

    # Sort by date
    sorted = ungrouped.sort_by { |c| safe_parse_date(c["date"]) || Time.at(0) }

    clusters = []
    current_cluster = [ sorted.first ]

    sorted.drop(1).each do |commit|
      prev_date = safe_parse_date(current_cluster.last["date"])
      curr_date = safe_parse_date(commit["date"])

      same_branch = true # commits from log are same repo, branch info not always available
      within_gap = prev_date && curr_date && ((curr_date - prev_date) * 86_400).abs <= CLUSTER_GAP.to_i

      if within_gap && same_branch
        current_cluster << commit
      else
        clusters << current_cluster if current_cluster.size > 1
        current_cluster = [ commit ]
      end
    end
    clusters << current_cluster if current_cluster.size > 1

    clusters.each do |cluster|
      shas = cluster.map { |c| c["sha"] }
      dates = parse_commit_dates(shas)
      diff = combine_diffs(shas)
      diff = strip_secrets(diff) if diff.present?
      title = "#{cluster.size} commits: #{cluster.first['subject']&.truncate(60)}"

      # Use earliest SHA as stable identifier for idempotency
      CommitGroup.find_or_create_by!(project: @project, group_type: "commit_cluster", commit_shas: shas) do |g|
        g.title = title
        g.branch = cluster.first["branch"]
        g.combined_diff = diff&.truncate(MAX_COMBINED_DIFF, omission: "\n... [diff truncated]")
        g.diff_lines = diff&.lines&.count || 0
        assign_loc_stats(g, shas, diff)
        g.earliest_commit_at = dates.first
        g.latest_commit_at = dates.last
      end

      @grouped_shas.merge(shas)
    end
  end

  def create_single_commit_groups
    ungrouped = @commits.reject { |c| @grouped_shas.include?(c["sha"]) }

    ungrouped.each do |commit|
      sha = commit["sha"]
      diff = @commit_diffs[sha]
      diff = strip_secrets(diff) if diff.present?
      date = safe_parse_date(commit["date"])

      CommitGroup.find_or_create_by!(project: @project, group_type: "single_commit", commit_shas: [ sha ]) do |g|
        g.title = commit["subject"]&.truncate(100)
        g.branch = commit["branch"]
        g.combined_diff = diff&.truncate(MAX_INDIVIDUAL_DIFF, omission: "\n... [diff truncated]")
        g.diff_lines = diff&.lines&.count || 0
        assign_loc_stats(g, [ sha ], diff)
        g.earliest_commit_at = date
        g.latest_commit_at = date
      end
    end
  end

  def combine_diffs(shas)
    parts = shas.filter_map { |sha| @commit_diffs[sha] }
    return nil if parts.empty?
    combined = parts.join("\n\n")
    combined.truncate(MAX_COMBINED_DIFF, omission: "\n... [combined diff truncated]")
  end

  def parse_commit_dates(shas)
    dates = shas.filter_map { |sha|
      commit = @commits.find { |c| c["sha"] == sha }
      safe_parse_date(commit&.dig("date")) if commit
    }.sort
    dates
  end

  def safe_parse_date(date_string)
    return nil if date_string.blank?
    DateTime.parse(date_string)
  rescue ArgumentError, Date::Error
    Rails.logger.warn("CommitGrouper: Could not parse date: #{date_string}")
    nil
  end

  def assign_loc_stats(group, shas, diff)
    matched = shas.filter_map { |sha| @numstat[sha] }
    if matched.any? && matched.size == shas.size
      # All SHAs found in numstat — use it (most accurate)
      group.insertions = matched.sum { |c| c["added"].to_i }
      group.deletions = matched.sum { |c| c["deleted"].to_i }
    elsif diff.present?
      # Partial numstat match or no numstat — parse the full diff
      stats = PrDiffStatsService.parse(diff)
      group.insertions = stats["insertions"] || 0
      group.deletions = stats["deletions"] || 0
    elsif matched.any?
      # No diff available but some numstat — use what we have
      group.insertions = matched.sum { |c| c["added"].to_i }
      group.deletions = matched.sum { |c| c["deleted"].to_i }
    end
  end

  def strip_secrets(text)
    SECRET_PATTERNS.reduce(text) { |t, pattern| t.gsub(pattern, "[REDACTED]") }
  end
end
