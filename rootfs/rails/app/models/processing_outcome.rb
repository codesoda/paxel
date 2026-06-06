class ProcessingOutcome < ApplicationRecord
  # aggregate: per-project NarrativeAggregator call (scales with project count).
  # aggregate_overall: one-off overall-report aggregation (runs once per upload).
  # Split so HistoricalEtaCalibration's per-project median isn't polluted by
  # the longer one-off overall call.
  OPERATION_TYPES = %w[llm_call embed extract chunk score diarize review aggregate aggregate_overall ingest].freeze
  OUTCOMES = %w[success api_error timeout code_error rate_limited server_error].freeze

  belongs_to :processing_run

  scope :successes, -> { where(outcome: "success") }
  scope :failures, -> { where.not(outcome: "success") }
  scope :recent, -> { order(created_at: :desc) }

  def self.record_success(run, operation_type, duration_ms:, service_name: nil)
    create!(
      processing_run: run,
      operation_type: operation_type,
      outcome: "success",
      status: "completed",
      duration_ms: duration_ms,
      service_name: service_name,
      started_at: duration_ms ? Time.current - (duration_ms / 1000.0) : Time.current,
      completed_at: Time.current
    )
  end

  def self.record_failure(run, operation_type, error, duration_ms: nil, service_name: nil, will_retry: false)
    create!(
      processing_run: run,
      operation_type: operation_type,
      outcome: classify_error(error),
      status: "completed",
      duration_ms: duration_ms,
      service_name: service_name,
      error_class: error.class.name,
      error_message: error.message.to_s,
      error_backtrace: (error.backtrace || []).first(5).join("\n"),
      will_retry: will_retry,
      started_at: duration_ms ? Time.current - (duration_ms / 1000.0) : Time.current,
      completed_at: Time.current
    )
  end

  def self.classify_error(error)
    case error
    when Timeout::Error then "timeout"
    when NoMethodError, NameError, TypeError, ArgumentError then "code_error"
    else
      msg = error.message.to_s.downcase
      if msg.include?("rate limit") || error.class.name.include?("RateLimit")
        "rate_limited"
      elsif msg.include?("500") || msg.include?("502") || msg.include?("503") || error.class.name.include?("ServerError")
        "server_error"
      else
        "api_error"
      end
    end
  end

  def self.stats_for(operation_type, since: 7.days.ago)
    records = where(operation_type: operation_type).where("created_at >= ?", since)
    total = records.count
    return { total_calls: 0 } if total == 0

    successes = records.where(outcome: "success")
    durations = successes.where.not(duration_ms: nil).pluck(:duration_ms).sort

    {
      total_calls: total,
      success_count: successes.count,
      error_rate: ((total - successes.count).to_f / total * 100).round(1),
      avg_duration_ms: durations.any? ? (durations.sum / durations.size).round(0) : nil,
      p50_duration_ms: durations.any? ? durations[durations.size / 2].round(0) : nil,
      p95_duration_ms: durations.any? ? durations[(durations.size * 0.95).floor].round(0) : nil
    }
  end
end
