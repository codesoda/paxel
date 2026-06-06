class LlmEvent < ApplicationRecord
  belongs_to :upload, optional: true

  scope :retries, -> { where(event_type: "retry") }
  scope :failures, -> { where(event_type: "failure") }
  scope :timeouts, -> { where(event_type: "timeout") }
  scope :since, ->(time) { where("created_at >= ?", time) }
  scope :by_source, ->(source) { where(source: source) }
  scope :by_provider, ->(provider) { where(provider: provider) }

  def self.counts_by_type(since: nil)
    scope = since ? where("created_at >= ?", since) : all
    scope.group(:event_type).count
  end

  def self.counts_by_error_class(since: nil)
    scope = since ? where("created_at >= ?", since) : all
    scope.group(:error_class).count
  end
end
