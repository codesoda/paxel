class VelocityMetricsService
  TEST_PATH_PATTERN = %r{(?:test|spec|__tests__|_test\.go|_test\.rb|\.test\.|\.spec\.)}i

  def self.compute(project)
    new(project).compute
  end

  # Compute velocity filtered to specific author names/emails.
  # Returns a subset of the full velocity metrics for that contributor only.
  def self.compute_for_author(project, author_names: [], author_emails: [])
    new(project).compute_for_author(author_names, author_emails)
  end

  # Public: the project's numstat hash ({sha => commit}) filtered to a set of
  # author names/emails (case-insensitive match on author OR email). Exposed so
  # AuthorScopedGitDims author-scopes code-quality git dimensions through the SAME
  # identity-match implementation velocity uses (one source of truth, no drift).
  # Returns {} when there is no numstat.
  def self.filtered_numstat(project, author_names: [], author_emails: [])
    new(project).filtered_numstat(author_names, author_emails)
  end

  # Compute and store author velocity on a project's git_metrics.
  # Returns the author_velocity hash, or nil if not computable.
  def self.compute_and_store_author_velocity!(project, committer)
    return nil unless committer

    identities = committer.committer_identities
      .where.not(match_method: %w[unmatched excluded manual_excluded])
    author_names = identities.pluck(:git_name).compact
    author_emails = identities.pluck(:git_email).compact
    return nil if author_names.empty? && author_emails.empty?

    author_velocity = compute_for_author(
      project, author_names: author_names, author_emails: author_emails
    )
    return nil if author_velocity.blank?

    gm = project.git_metrics || {}
    gm["author_velocity"] = author_velocity
    gm["author_velocity_status"] = "resolved"
    project.update!(git_metrics: gm)
    author_velocity
  end

  def initialize(project)
    @project = project
  end

  def compute
    return {} if no_data_sources?

    {
      "insertions" => total_insertions,
      "deletions" => total_deletions,
      "net_loc" => total_insertions - total_deletions,
      "loc_per_day" => loc_per_day,
      "test_insertions" => test_insertions,
      "test_deletions" => test_deletions,
      "test_ratio" => safe_ratio(test_insertions, total_insertions),
      "authors" => author_breakdown,
      "peak_day" => peak_day_stats,
      "daily_loc" => daily_loc_breakdown,
      "ship_to_revert_ratio" => ship_to_revert,
      "data_source" => data_source,
      "date_range_days" => date_range_days
    }
  end

  def compute_for_author(author_names, author_emails)
    return {} if no_data_sources?

    # Filter numstat to only commits by the specified author
    filtered = filter_numstat_by_author(author_names, author_emails)
    return {} if filtered.empty?

    ins = filtered.values.sum { |c| c["added"].to_i }
    del = filtered.values.sum { |c| c["deleted"].to_i }
    dates = filtered.values.filter_map { |c| Date.parse(c["date"]) rescue nil }
    days = dates.any? ? ((dates.max - dates.min).to_i + 1) : 1

    test_ins = filtered.values.sum do |c|
      (c["files"] || []).sum do |f|
        path = f["path"] || f["file"]
        path.to_s.match?(TEST_PATH_PATTERN) ? f["added"].to_i : 0
      end
    end

    {
      "insertions" => ins,
      "deletions" => del,
      "net_loc" => ins - del,
      "loc_per_day" => (ins - del) / [ days, 1 ].max,
      "test_insertions" => test_ins,
      "test_ratio" => safe_ratio(test_ins, ins),
      "commits" => filtered.size,
      "date_range_days" => days
    }
  end

  # Public instance form of the class method above.
  def filtered_numstat(author_names, author_emails)
    filter_numstat_by_author(author_names, author_emails)
  end

  private

  def filter_numstat_by_author(author_names, author_emails)
    return {} unless use_numstat?

    name_set = Set.new(author_names.map(&:downcase))
    email_set = Set.new(author_emails.map { |e| e&.downcase }.compact)

    numstat_data.select do |_sha, commit|
      author = commit["author"]&.downcase
      email = commit["email"]&.downcase
      name_set.include?(author) || (email && email_set.include?(email))
    end
  end

  def no_data_sources?
    numstat_data.blank? && @project.commit_diffs.blank?
  end

  def data_source
    numstat_data.present? ? "numstat" : "diff_parsing"
  end

  # --- Numstat-based computation (preferred) ---

  def numstat_data
    @numstat_data ||= @project.git_metrics&.dig("numstat") || {}
  end

  def use_numstat?
    numstat_data.present?
  end

  # --- Aggregated stats ---

  def total_insertions
    @total_insertions ||= if use_numstat?
      numstat_data.values.sum { |c| c["added"].to_i }
    else
      diff_stats.sum { |s| s["insertions"].to_i }
    end
  end

  def total_deletions
    @total_deletions ||= if use_numstat?
      numstat_data.values.sum { |c| c["deleted"].to_i }
    else
      diff_stats.sum { |s| s["deletions"].to_i }
    end
  end

  def test_insertions
    @test_insertions ||= if use_numstat?
      numstat_data.values.sum do |commit|
        (commit["files"] || []).sum do |f|
          (f["path"] || f["file"]).to_s.match?(TEST_PATH_PATTERN) ? f["added"].to_i : 0
        end
      end
    else
      diff_stats.sum { |s| s["test_insertions"].to_i }
    end
  end

  def test_deletions
    @test_deletions ||= if use_numstat?
      numstat_data.values.sum do |commit|
        (commit["files"] || []).sum do |f|
          (f["path"] || f["file"]).to_s.match?(TEST_PATH_PATTERN) ? f["deleted"].to_i : 0
        end
      end
    else
      diff_stats.sum { |s| s["test_deletions"].to_i }
    end
  end

  def date_range_days
    @date_range_days ||= begin
      dates = commit_dates
      return 0 if dates.empty?
      ((dates.max - dates.min).to_i + 1)
    end
  end

  def loc_per_day
    (total_insertions - total_deletions) / [ date_range_days, 1 ].max
  end

  def author_breakdown
    if use_numstat?
      by_author = Hash.new { |h, k| h[k] = { "insertions" => 0, "deletions" => 0, "commits" => 0 } }
      numstat_data.each_value do |commit|
        author = commit["author"] || "unknown"
        by_author[author]["insertions"] += commit["added"].to_i
        by_author[author]["deletions"] += commit["deleted"].to_i
        by_author[author]["commits"] += 1
      end
      by_author
    else
      {}
    end
  end

  def daily_loc_breakdown
    by_date = Hash.new { |h, k| h[k] = { "date" => k, "insertions" => 0, "deletions" => 0, "commits" => 0 } }

    if use_numstat?
      numstat_data.each_value do |commit|
        date = parse_date(commit["date"])&.to_s
        next unless date
        by_date[date]["insertions"] += commit["added"].to_i
        by_date[date]["deletions"] += commit["deleted"].to_i
        by_date[date]["commits"] += 1
      end
    end

    by_date.values.sort_by { |d| d["date"] }
  end

  def peak_day_stats
    daily = daily_loc_breakdown
    return nil if daily.empty?
    daily.max_by { |d| d["insertions"] }
  end

  def ship_to_revert
    commits = @project.recent_commits
    return nil if commits.blank?

    reverts = (@project.git_metrics&.dig("reverts") || 0).to_i
    total = commits.size
    ships = total - reverts

    return nil if total == 0
    safe_ratio(ships, total)
  end

  # --- Diff-based fallback ---

  def diff_stats
    @diff_stats ||= begin
      return [] if @project.commit_diffs.blank?
      @project.commit_diffs.values.map do |diff_text|
        PrDiffStatsService.parse(diff_text)
      end
    end
  end

  # --- Helpers ---

  def commit_dates
    @commit_dates ||= if use_numstat?
      numstat_data.values.filter_map { |c| parse_date(c["date"]) }
    else
      (@project.recent_commits || []).filter_map { |c| parse_date(c["date"] || c["timestamp"]) }
    end
  end

  def parse_date(date_str)
    return nil unless date_str
    Date.parse(date_str.to_s) rescue nil
  end

  def safe_ratio(a, b)
    b.zero? ? 0.0 : (a.to_f / b).round(3)
  end
end
