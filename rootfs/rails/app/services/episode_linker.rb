class EpisodeLinker
  include LinkingStrategy

  def initialize(upload)
    @upload = upload
  end

  def self.link!(upload)
    new(upload).link!
  end

  def link!
    # Idempotent: destroy existing episodes in batches
    @upload.episodes.in_batches.destroy_all

    projects = @upload.projects.includes(
      transcript_sessions: :commit_group_sessions,
      commit_groups: :commit_group_sessions
    )

    # Logical-root sessions only — exclude same-tool subagents AND cross-tool
    # children. Cross-tool children ride in their parent's episode (see
    # docs/designs/CROSS_TOOL_SESSION_LINKING.md §7.1). The `triggered_by_id`
    # check is null-safe for pre-Phase-2 uploads (column null on every row).
    all_sessions = projects.flat_map { |p|
      p.transcript_sessions.reject { |s| s.is_subagent || s.triggered_by_id.present? }
    }

    # Get all commit groups
    all_commit_groups = projects.flat_map(&:commit_groups)

    return 0 if all_commit_groups.empty? && all_sessions.empty?

    matched_sessions = Set.new
    matched_commit_groups = Set.new

    # Build episodes seeded from commit groups
    all_commit_groups.each do |cg|
      episode = @upload.episodes.create!(
        episode_type: classify_episode(cg),
        confidence: 0.0
      )

      # Attach commit group
      EpisodeCommitGroup.create!(
        episode: episode,
        commit_group: cg,
        link_type: "direct",
        link_confidence: 1.0
      )
      matched_commit_groups << cg.id

      # Find matching sessions
      confidences = []
      all_sessions.each do |session|
        next if matched_sessions.include?(session.id)

        link_result = best_link(cg, session)
        next unless link_result

        link_type, confidence = link_result
        EpisodeSession.create!(
          episode: episode,
          transcript_session: session,
          link_type: link_type,
          link_confidence: confidence
        )
        matched_sessions << session.id
        confidences << confidence
      end

      episode.update!(confidence: confidences.any? ? (confidences.sum / confidences.size).round(2) : 0.5)
    end

    # Orphan sessions become session-only episodes
    orphan_sessions = all_sessions.reject { |s| matched_sessions.include?(s.id) }
    orphan_sessions.each do |session|
      episode = @upload.episodes.create!(
        episode_type: "session_only",
        confidence: 0.3
      )
      EpisodeSession.create!(
        episode: episode,
        transcript_session: session,
        link_type: nil,
        link_confidence: 0.3
      )
    end

    @upload.episodes.count
  end

  private

  def classify_episode(commit_group)
    title = (commit_group.title || "").downcase
    if title.start_with?("fix")
      "bugfix"
    elsif title.include?("refactor")
      "refactor"
    elsif title.start_with?("feat") || title.include?("add")
      "feature"
    elsif title.include?("infra") || title.include?("ci") || title.include?("deploy")
      "infrastructure"
    else
      "implementation"
    end
  end
end
