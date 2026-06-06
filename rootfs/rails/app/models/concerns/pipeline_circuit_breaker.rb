# Short-circuit a parallel processing loop when failures accumulate past a
# threshold. Used by `ClientPipeline#analyze_sessions` (narrative generation)
# and `EpisodeSummarizer#summarize` (episode scoring) to fail-fast when auth
# expires or the proxy misbehaves mid-run, instead of burning 5-15 minutes of
# retries per worker.
#
# Trip conditions (ordered by priority):
#   1. `PaxelLlmError::Fatal` on any iteration — these don't recover from
#      retrying N more sessions; surface the actionable error immediately.
#   2. Consecutive non-fatal failures ≥ threshold — the retry budget is
#      exhausted across enough adjacent workers that the next one is
#      almost certainly going to fail too.
#   3. Rolling failure rate > `rate_failure_threshold` over the last
#      `rate_window_size` attempts — catches the "limping at 10% success"
#      pattern where a rare successful attempt keeps resetting the
#      consecutive-count gate while the pipeline still produces
#      misleadingly-partial results.
#
# Usage:
#   include PipelineCircuitBreaker
#
#   breaker = build_circuit_breaker(stage: "narrative")
#   with_thread_pool(20) do |executor|
#     futures = items.map do |item|
#       Concurrent::Promises.future_on(executor) do
#         next if breaker.tripped?
#         begin
#           process(item)
#           breaker.success!
#         rescue => e
#           f = failed.increment
#           breaker.failure!(error: e, item_id: item.id, failed_count: f)
#         end
#       end
#     end
#     futures.each { |f| f.wait!(360) }
#   end
#   breaker.raise_if_tripped!(fallback_count: failed.value)
#
# Extracted from `ClientPipeline` so `EpisodeSummarizer` — which previously
# had no breaker — can fail-fast on the same auth-expiry / proxy-misbehavior
# patterns that were catching `ClientPipeline`.
module PipelineCircuitBreaker
  extend ActiveSupport::Concern

  CIRCUIT_BREAKER_THRESHOLD = 10

  # Rolling-rate guard — catches the "10% success rate" pattern the
  # consecutive-count gate misses because the rare success keeps resetting
  # it. Window size + threshold picked so:
  #   * You need at least a meaningful sample (50 outcomes) before the
  #     gate activates at all — avoids flapping on small-N runs.
  #   * ≥90% failures = "virtually all failures" — preserves headroom for
  #     recoverable transient errors (< 10% error rates don't trip).
  # Comparison is inclusive (`>=`): the TODO's motivating example "9 fail
  # / 1 succeed / repeat" is exactly 90% failures. A strict `>` threshold
  # would miss it — and pigeonhole forces any strict `>90%` pattern to
  # contain a 10-consecutive run that the consecutive gate already
  # catches, making a strict rate gate functionally dead code. Inclusive
  # `>=` closes the gap. (Codex dual-review of PR #667 caught this.)
  RATE_WINDOW_SIZE = 50
  RATE_FAILURE_THRESHOLD = 0.9

  # Trip-reason tags used in the raised error message so the rake footer
  # + Sentry grouping can surface WHY the breaker fired (consecutive run,
  # rolling rate, or a single Fatal).
  TRIP_REASON_CONSECUTIVE = :consecutive
  TRIP_REASON_RATE = :rate
  TRIP_REASON_FATAL = :fatal

  # The `PipelineCircuitBroken` exception class is defined in
  # `app/services/client_pipeline.rb` (its original location from before
  # this concern was extracted). Keeping the definition there preserves
  # `.name == "ClientPipeline::PipelineCircuitBroken"` — Ruby bakes the
  # name from the first constant assignment, so defining here would have
  # changed it to `"PipelineCircuitBreaker::PipelineCircuitBroken"` and
  # fragmented Sentry grouping across the pre/post-extraction boundary.
  # `Breaker#raise_if_tripped!` references `ClientPipeline::...` via
  # lazy const lookup, resolved through Rails autoload at raise time.

  class Breaker
    attr_reader :stage, :threshold, :rate_window_size, :rate_failure_threshold

    def initialize(stage:,
                   threshold: CIRCUIT_BREAKER_THRESHOLD,
                   rate_window_size: RATE_WINDOW_SIZE,
                   rate_failure_threshold: RATE_FAILURE_THRESHOLD)
      @stage = stage
      @threshold = threshold
      @rate_window_size = rate_window_size
      @rate_failure_threshold = rate_failure_threshold
      @consecutive_failures = Concurrent::AtomicFixnum.new(0)
      @circuit_broken = Concurrent::AtomicBoolean.new(false)
      @trip_count = Concurrent::AtomicReference.new(nil)
      @trip_item_id = Concurrent::AtomicReference.new(nil)
      @trip_error_msg = Concurrent::AtomicReference.new(nil)
      @trip_original_error = Concurrent::AtomicReference.new(nil)
      @trip_reason = Concurrent::AtomicReference.new(nil)
      # Rolling window: array of booleans (true = failure). Guarded by
      # `@rate_mutex` because both slot writes AND the index advance need
      # to be atomic together — two AtomicFixnums would TOCTOU-race (one
      # thread advances the index, another reads a stale slot). The
      # critical section is a single array assignment + one modular
      # increment, so contention is negligible vs. the work per iteration.
      # Note: `failure!` acquires this mutex TWICE per call — once inside
      # `record_rate_outcome` and once inside `rate_tripped?`. Do NOT
      # fold the two into a single acquisition: the record-BEFORE-check
      # ordering is load-bearing (the current iteration's outcome must
      # be counted before we decide whether the current rate trips).
      @rate_mutex = Mutex.new
      @rate_window = []
      @rate_write_idx = 0
    end

    def tripped?
      @circuit_broken.true?
    end

    # Reset consecutive count AND record the success in the rolling
    # window. Safe to call from any worker.
    def success!
      @consecutive_failures.value = 0
      record_rate_outcome(failure: false)
    end

    # Record a failure; may trip the breaker. Returns true iff THIS call
    # flipped the breaker from closed → open (i.e. the trip-state snapshot
    # below belongs to this caller's error).
    #
    # `item_id` is captured in the trip snapshot so Sentry + rake footer
    # can correlate the trip to a specific session/episode. `failed_count`
    # is captured at trip time so the raised error reports the count that
    # tripped the breaker, not the TOTAL failures after in-flight workers
    # finish their rescue blocks.
    def failure!(error:, item_id:, failed_count:)
      cf = @consecutive_failures.increment
      record_rate_outcome(failure: true)
      is_fatal = defined?(PaxelLlmError) && error.is_a?(PaxelLlmError::Fatal)

      reason = if is_fatal
        TRIP_REASON_FATAL
      elsif cf >= @threshold
        TRIP_REASON_CONSECUTIVE
      elsif rate_tripped?
        TRIP_REASON_RATE
      end
      return false unless reason

      # `make_true` is compare-and-set: returns true only for the single
      # thread that flipped the flag false → true. Guarantees exactly one
      # worker wins and stores its trip snapshot; the pre-check +
      # two-step assignment would TOCTOU-race with other workers also
      # past the threshold check.
      return false unless @circuit_broken.make_true

      @trip_reason.set(reason)
      @trip_count.set(failed_count)
      @trip_item_id.set(item_id)
      req_tag = (error.respond_to?(:request_id) && error.request_id) ? " [req=#{error.request_id}]" : ""
      @trip_error_msg.set("#{error.class}: #{error.message.to_s.truncate(100)}#{req_tag}")
      # Preserve the PaxelLlmError so the rake footer can emit user_action
      # + request_id on its dedicated lines.
      @trip_original_error.set(error) if defined?(PaxelLlmError) && error.is_a?(PaxelLlmError::Base)
      true
    end

    # Raise `ClientPipeline::PipelineCircuitBroken` if the breaker tripped
    # during the run. `fallback_count` is used when no worker claimed the
    # trip snapshot (shouldn't happen under normal flow, defensive).
    # Const lookup is lazy — resolves through Rails autoload at raise
    # time, so this concern file can load before `client_pipeline.rb`
    # (e.g., from isolated concern specs).
    def raise_if_tripped!(fallback_count:)
      return unless @circuit_broken.true?
      count = @trip_count.get || fallback_count
      reason_str = case @trip_reason.get
      when TRIP_REASON_FATAL
        "fatal error, threshold #{@threshold}"
      when TRIP_REASON_RATE
        "rate >= #{(@rate_failure_threshold * 100).to_i}% over last #{@rate_window_size}, threshold #{@threshold}"
      else
        # Consecutive or defensive fallback. Keeps the legacy "threshold N"
        # copy so `client_pipeline_spec.rb:343` + rake-footer string-matchers
        # continue to match.
        "threshold #{@threshold}"
      end
      raise ClientPipeline::PipelineCircuitBroken.new(
        "#{count} #{@stage} failure#{count == 1 ? '' : 's'} tripped the circuit " \
        "(#{reason_str}). Last error: #{@trip_error_msg.get}",
        original_error: @trip_original_error.get,
        session_id: @trip_item_id.get,
      )
    end

    private

    def record_rate_outcome(failure:)
      @rate_mutex.synchronize do
        if @rate_window.size < @rate_window_size
          @rate_window << failure
        else
          @rate_window[@rate_write_idx] = failure
          @rate_write_idx = (@rate_write_idx + 1) % @rate_window_size
        end
      end
    end

    def rate_tripped?
      @rate_mutex.synchronize do
        return false if @rate_window.size < @rate_window_size
        failures = @rate_window.count(true)
        (failures.to_f / @rate_window.size) >= @rate_failure_threshold
      end
    end
  end

  private

  def build_circuit_breaker(stage:, threshold: CIRCUIT_BREAKER_THRESHOLD,
                             rate_window_size: RATE_WINDOW_SIZE,
                             rate_failure_threshold: RATE_FAILURE_THRESHOLD)
    Breaker.new(
      stage: stage,
      threshold: threshold,
      rate_window_size: rate_window_size,
      rate_failure_threshold: rate_failure_threshold,
    )
  end
end
