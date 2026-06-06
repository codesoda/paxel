class TranscriptSession < ApplicationRecord
  # Status machine:
  #   pending -> chunked -> complete
  #      \-> no_transcript (JSONL file not found on disk)
  #                \-> too_short (skip)
  #                \-> failed
  #
  # Narrative status machine:
  #   pending -> analyzing -> complete
  #                 \-> failed
  #   (also: "skipped" for sessions < 1000 tokens, "low_quality" for weak narratives)

  belongs_to :project
  belongs_to :parent_session, class_name: "TranscriptSession", optional: true
  belongs_to :triggered_by, class_name: "TranscriptSession", optional: true, foreign_key: :triggered_by_id
  has_many :chunks, dependent: :destroy
  has_many :subagent_sessions, class_name: "TranscriptSession", foreign_key: :parent_session_id, dependent: :destroy
  has_many :cross_tool_children, class_name: "TranscriptSession", foreign_key: :triggered_by_id, dependent: :nullify
  has_many :commit_group_sessions, dependent: :destroy
  has_many :commit_groups, through: :commit_group_sessions
  has_many :decisions, dependent: :destroy
  has_many :episode_sessions, dependent: :destroy
  has_many :plan_files, dependent: :destroy
  has_many :episodes, through: :episode_sessions

  STATUSES = %w[pending chunked analyzing complete failed too_short no_transcript].freeze
  NARRATIVE_STATUSES = %w[pending analyzing complete failed skipped low_quality].freeze
  SESSION_INTENTS = %w[shipping exploration ambiguous].freeze
  AGENT_TYPES = %w[claude_code codex_cli gemini_cli cursor opencode].freeze
  CROSS_TOOL_ORIGINS = %w[claude_code cursor unknown].freeze
  TRIGGERED_BY_CONFIDENCES = %w[high medium low].freeze

  # Parallelism detection splits on a short gap (15 min) so idle tabs left open
  # don't inflate "concurrent" counts. Distinct from SessionSignalExtractor's
  # ACTIVE_GAP_MINUTES=90, which is calibrated for commit-cadence work-session
  # duration. Consumed by TranscriptChunker (producer of active_time_windows)
  # and ParallelismAnalyzer (overlap + review_separation computation).
  PARALLELISM_GAP_MINUTES = 15
  validates :session_id, presence: true
  validates :session_id, uniqueness: { scope: :project_id }
  validates :status, inclusion: { in: STATUSES }
  validates :narrative_status, inclusion: { in: NARRATIVE_STATUSES }, allow_nil: true
  validates :session_intent, inclusion: { in: SESSION_INTENTS }, allow_nil: true
  validates :agent_type, inclusion: { in: AGENT_TYPES }
  validates :cross_tool_origin, inclusion: { in: CROSS_TOOL_ORIGINS }, allow_nil: true
  validates :triggered_by_confidence, inclusion: { in: TRIGGERED_BY_CONFIDENCES }, allow_nil: true
  validate :no_self_triggered_by                          # invariant 2
  validate :triggered_by_excluded_for_subagents           # invariant 1: is_subagent ⇒ triggered_by_id IS NULL
  validate :triggered_by_must_be_main_session             # invariant 3: parent cannot be is_subagent
  validate :triggered_by_id_requires_cross_tool_origin    # invariant 6: triggered_by_id NOT NULL ⇒ cross_tool_origin NOT NULL

  scope :analyzable, -> { where.not(status: %w[too_short no_transcript]) }
  scope :completed, -> { where(status: "complete") }
  scope :main_sessions, -> { where(is_subagent: false) }
  scope :subagents, -> { where(is_subagent: true) }
  # logical_roots — main user-initiated sessions: not a same-tool subagent and not
  # a cross-tool child. The migration target for the 21+ ad-hoc `is_subagent: false`
  # filters across consumers (see docs/designs/CROSS_TOOL_SESSION_LINKING.md §7).
  scope :logical_roots, -> { where(is_subagent: false, triggered_by_id: nil) }
  # Inverse of logical_roots: Claude internal subagents OR linked cross-tool
  # children. The "M" in user-facing "N main + M subagent" rollups.
  scope :non_logical_roots, -> { where("is_subagent = TRUE OR triggered_by_id IS NOT NULL") }
  scope :with_narrative, -> { where.not(narrative: nil) }
  scope :narrative_complete, -> { where(narrative_status: "complete") }
  scope :narrative_pending, -> { where(narrative_status: "pending") }

  # Per-upload guard for downstream consumer changes (Phase 3-5 of the cross-tool
  # linking design). Returns true iff at least one session in the upload has
  # cross_tool_origin set — i.e., the upload was processed by a client that
  # emitted cross-tool linking metadata. Old uploads (no row has cross_tool_origin)
  # keep legacy is_subagent-only behavior; new uploads get the new logical_roots
  # path. Implemented as EXISTS so it's O(1) regardless of upload size.
  def self.cross_tool_linking_active?(upload)
    where(project_id: upload.projects.select(:id)).where.not(cross_tool_origin: nil).exists?
  end

  # JSONB event scopes (use existing GIN index on session_events)
  scope :with_event_type, ->(type) {
    where("session_events @> ?", [ { type: type } ].to_json)
  }

  # Exact path match only — does not support wildcards or directory prefix matching
  scope :touching_file, ->(path) {
    where("session_events @> ? OR session_events @> ?",
      [ { type: "file_edit", path: path } ].to_json,
      [ { type: "file_create", path: path } ].to_json)
  }

  # EXISTS subquery because GIN @> cannot filter on cast expressions like (->>'failed')::int > 0
  scope :with_test_failures, -> {
    where("EXISTS (SELECT 1 FROM jsonb_array_elements(session_events) elem WHERE elem->>'type' = 'test_run' AND (elem->>'failed')::int > 0)")
  }

  scope :with_errors, -> {
    where("session_events @> ?", [ { type: "error_encountered" } ].to_json)
  }

  # Normalize session_events keys to strings (EventExtractor stores symbol keys in-memory,
  # but JSONB serialization converts to strings; this handles both paths)
  def session_events
    raw = super
    return [] unless raw.is_a?(Array)
    raw.filter_map { |e| e.stringify_keys if e.is_a?(Hash) }
  end

  def events_of_type(type)
    session_events.select { |e| e["type"] == type.to_s }
  end

  def event_git_shas
    events_of_type("git_commit").filter_map { |e| e["sha"] }
  end

  def event_git_commits
    events_of_type("git_commit")
  end

  def event_branches
    events_of_type("git_branch_switch").filter_map { |e| e["branch"] }
  end

  def files_modified
    events_of_type("file_edit") + events_of_type("file_create")
  end

  def test_results
    events_of_type("test_run")
  end

  def error_events
    events_of_type("error_encountered")
  end

  def ghost?
    status == "pending" && chunks.empty?
  end

  def has_plan_files?
    plan_files.any?
  end

  def latest_plan_files
    plan_files.latest_versions
  end

  def condensed_text
    chunks.order(:position).pluck(:content).join("\n")
  end

  def condensed_token_estimate
    chunks.sum(:token_estimate)
  end

  private

  # Cross-tool linking invariants — see docs/designs/CROSS_TOOL_SESSION_LINKING.md §10.1.

  def no_self_triggered_by
    errors.add(:triggered_by_id, "cannot reference self") if triggered_by_id.present? && triggered_by_id == id
  end

  def triggered_by_excluded_for_subagents
    return unless is_subagent && triggered_by_id.present?

    errors.add(:triggered_by_id, "cannot be set on a subagent (is_subagent=true)")
  end

  def triggered_by_must_be_main_session
    return unless triggered_by_id.present? && triggered_by&.is_subagent

    errors.add(:triggered_by_id, "parent must be a main session (not a subagent)")
  end

  def triggered_by_id_requires_cross_tool_origin
    return unless triggered_by_id.present? && cross_tool_origin.blank?

    errors.add(:cross_tool_origin, "must be set when triggered_by_id is present")
  end
end
