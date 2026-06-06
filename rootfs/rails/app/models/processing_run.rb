# Status transitions:
#   running ──┬──▶ completed  (job finished normally)
#             ├──▶ failed     (job raised error)
#             ├──▶ stale      (no heartbeat for STALE_THRESHOLD)
#             └──▶ timeout    (job exceeded time limit)
class ProcessingRun < ApplicationRecord
  STALE_THRESHOLD = 45.minutes
  STATUSES = %w[running completed failed stale timeout].freeze

  SECRET_PATTERNS = [
    /(?:sk-[a-zA-Z0-9]{20,})/,                    # OpenAI/Anthropic API keys
    /(?:AKIA[0-9A-Z]{16})/,                        # AWS access keys
    /(?:ghp_[a-zA-Z0-9]{36})/,                     # GitHub personal access tokens
    /(?:gho_[a-zA-Z0-9]{36})/,                     # GitHub OAuth tokens
    /(?:github_pat_[a-zA-Z0-9_]{22,})/,            # GitHub fine-grained tokens
    /(?:xox[bpsar]-[a-zA-Z0-9\-]+)/,               # Slack tokens
    /(?:password|passwd|secret|token)\s*[=:]\s*.+/i # Password assignments
  ].freeze

  belongs_to :upload
  belongs_to :trackable, polymorphic: true, optional: true
  has_many :outcomes, class_name: "ProcessingOutcome", dependent: :delete_all

  validates :job_class, presence: true
  validates :started_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :stale, -> { where(status: "stale") }
  scope :for_upload, ->(id) { where(upload_id: id) }
  scope :recent, -> { order(created_at: :desc) }

  def mark_completed!
    now = Time.current
    rows = ProcessingRun.where(id: id, status: "running")
                        .update_all(status: "completed", completed_at: now, duration_ms: ((now - started_at) * 1000).to_i)
    rows > 0
  end

  def mark_failed!(error)
    now = Time.current
    attrs = {
      status: "failed",
      completed_at: now,
      duration_ms: ((now - started_at) * 1000).to_i,
      error_class: error.class.name,
      error_message: sanitize_error_message(error.message.to_s),
      backtrace: (error.backtrace || []).first(10).join("\n")
    }
    ProcessingRun.where(id: id, status: "running").update_all(attrs)
  end

  def mark_stale!
    ProcessingRun.where(id: id, status: "running")
                 .update_all(status: "stale", completed_at: Time.current)
  end

  def mark_timeout!
    now = Time.current
    ProcessingRun.where(id: id, status: "running")
                 .update_all(status: "timeout", completed_at: now, duration_ms: ((now - started_at) * 1000).to_i)
  end

  def heartbeat!(new_step = nil)
    attrs = { last_heartbeat_at: Time.current }
    attrs[:step] = new_step if new_step
    update_columns(attrs)
  end

  def stale?
    status == "running" && (last_heartbeat_at || started_at) < STALE_THRESHOLD.ago
  end

  private

  def sanitize_error_message(message)
    SECRET_PATTERNS.reduce(message) { |msg, pattern| msg.gsub(pattern, "[REDACTED]") }
  end
end
