# Infers a developer's timezone from their git commit timestamps, and is the
# shared source of truth for "which commits are the uploader's" across the
# builder profile (BuilderMetrics reads #uploader_timestamps for the commit
# heatmap + peak hour, so inference and attribution never disagree).
#
# Git's %aI format preserves the author's local timezone offset (e.g., -07:00).
# This service extracts those offsets from the uploader's commits and picks the
# most common non-UTC offset. Returns nil if all commits are UTC or insufficient
# data exists — we never guess, since the product surfaces night-work patterns
# (Night Owl, 3AM index) as meaningful signal. A developer who commits mostly
# from a UTC box (CI / devcontainer) but occasionally from their real local
# machine is correctly homed to that local offset.
#
# Commit source, most-precise-first (see #collect_uploader_commit_rows):
#   1. author_recent_commits — `git log --author`-filtered to the uploader.
#   2. recent_commits filtered by the uploader's known git emails (the raw log
#      is ALL authors, so this strips teammates on a shared repo).
#   3. git_metrics numstat — the only commit-level source on `--all` aggregate
#      uploads, where recent_commits is never set.
#
# Usage:
#   result = TimezoneInferrer.infer(upload)
#   result.utc_offset_seconds  # => -25200
#   result.offset_string       # => "-07:00"
#   result.confidence          # => "high"
#
class TimezoneInferrer
  Result = Struct.new(:utc_offset_seconds, :offset_string, :confidence, keyword_init: true)

  MIN_COMMITS = 3

  def self.infer(upload)
    new(upload).infer
  end

  # Uploader-scoped commit instants (parsed Time objects with their original
  # offsets preserved). Shared with BuilderMetrics so the heatmap / peak hour
  # bucket the SAME commits this service infers the timezone from.
  def self.uploader_timestamps(upload)
    new(upload).uploader_timestamps
  end

  def initialize(upload)
    @upload = upload
  end

  def infer
    non_utc = uploader_timestamps.map(&:utc_offset).reject(&:zero?)

    return nil if non_utc.size < MIN_COMMITS

    best_offset = non_utc.tally.max_by { |_, count| count }.first

    Result.new(
      utc_offset_seconds: best_offset,
      offset_string: format_offset(best_offset),
      confidence: "high"
    )
  end

  def uploader_timestamps
    @uploader_timestamps ||= collect_uploader_commit_rows.filter_map do |commit|
      parse_commit_time(commit["date"] || commit["timestamp"])
    end
  end

  private

  def uploader_emails
    emails = Set.new

    # Primary: committer identity emails from identity matching system
    if @upload.committer_id.present? && defined?(CommitterIdentity)
      @upload.committer.committer_identities.each do |identity|
        emails << identity.git_email.downcase if identity.git_email.present?
      end
    end

    # Fallback: upload user's email (User model unavailable in client Docker image)
    if emails.empty? && defined?(User) && @upload.user.present?
      emails << @upload.user.email.downcase
    end

    emails
  end

  # Resolve the uploader's commits across all projects, preferring the most
  # precise author-scoped source available. Falls back to all commits only when
  # no uploader identity is known (anonymous upload / unresolved identity).
  def collect_uploader_commit_rows
    emails = uploader_emails
    rows = []

    @upload.projects.each do |project|
      # 1. author_recent_commits is already --author filtered to the uploader.
      author_commits = project.author_recent_commits
      if author_commits.present?
        rows.concat(author_commits)
        next
      end

      # 2. recent_commits is the full (all-authors) log — filter to the uploader.
      recent = project.recent_commits
      if recent.present?
        rows.concat(filter_by_email(recent, emails))
        next
      end

      # 3. --all aggregate uploads carry no recent_commits; numstat is the only
      #    commit-level source (each entry has date + email).
      numstat = project.git_metrics&.dig("numstat")
      if numstat.is_a?(Hash) && numstat.any?
        rows.concat(filter_by_email(numstat.values, emails))
      end
    end

    rows
  end

  # Keep only the uploader's commits when we know their emails; otherwise pass
  # everything through (we can't attribute, so don't drop data).
  def filter_by_email(commits, emails)
    return commits if emails.empty?
    commits.select { |c| emails.include?((c["email"] || "").to_s.downcase) }
  end

  def parse_commit_time(raw)
    return nil if raw.blank?
    Time.parse(raw)
  rescue ArgumentError, TypeError
    nil
  end

  def format_offset(seconds)
    sign = seconds >= 0 ? "+" : "-"
    abs = seconds.abs
    hours = abs / 3600
    minutes = (abs % 3600) / 60
    "#{sign}%02d:%02d" % [ hours, minutes ]
  end
end
