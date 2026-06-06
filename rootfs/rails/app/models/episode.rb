class Episode < ApplicationRecord
  belongs_to :upload
  has_many :episode_sessions, dependent: :destroy
  has_many :episode_commit_groups, dependent: :destroy
  has_many :transcript_sessions, through: :episode_sessions
  has_many :commit_groups, through: :episode_commit_groups

  EPISODE_TYPES = %w[implementation bugfix refactor infrastructure feature commit_only session_only].freeze

  validates :upload, presence: true

  AGENT_TYPE_LABELS = {
    "claude_code" => "Claude Code",
    "codex_cli" => "Codex",
    "gemini_cli" => "Gemini",
    "cursor" => "Cursor",
    "opencode" => "opencode"
  }.freeze

  def inferred_tool_type
    agent_types = transcript_sessions.distinct.pluck(:agent_type)
    labels = agent_types.filter_map { |t| AGENT_TYPE_LABELS[t] }
    return labels.sort.join(" + ") if labels.any?

    tools = transcript_sessions.flat_map { |s| s.tools_used || [] }.uniq
    tools.any? ? "AI Tool" : "Unknown"
  end
end
