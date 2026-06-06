# Traces immediate outcomes for decisions within the same session.
#
# For each Decision, scans forward in session_events from the decision's
# event_index until the next agent_proposal or end of session. Tracks
# test results, errors, commits, and reversal patterns.
#
# Creates OutcomeAnalysis(temporal_layer: "immediate") for each decision.
#
class InSessionAnalyzer
  include TranscriptPatterns

  def self.analyze!(upload)
    new(upload).analyze!
  end

  def initialize(upload)
    @upload = upload
  end

  def analyze!
    count = 0
    @upload.decisions.includes(:transcript_session).find_each do |decision|
      outcome = analyze_decision(decision)
      if outcome
        count += 1
      end
    end
    count
  end

  private

  def analyze_decision(decision)
    events = decision.transcript_session.session_events
    start_idx = decision.event_index + 1
    return nil if start_idx >= events.size

    test_runs = []
    errors = 0
    commits = 0
    reversed = false

    (start_idx...events.size).each do |i|
      event = events[i]
      # Stop at next agent_proposal (next decision boundary)
      break if event["type"] == "agent_proposal"

      case event["type"]
      when "test_run"
        test_runs << {
          passed: event["passed"].to_i,
          failed: event["failed"].to_i
        }
      when "error_encountered"
        errors += 1
      when "git_commit"
        commits += 1
      when "user_directive"
        if event["text"].to_s.match?(REVERSAL_INDICATORS)
          reversed = true
        end
      end
    end

    # Determine outcome signal
    signal = determine_signal(test_runs, errors, commits, reversed)

    evidence = build_evidence(test_runs, errors, commits, reversed)

    OutcomeAnalysis.create!(
      decision: decision,
      analyzer_type: "in_session",
      temporal_layer: "immediate",
      evidence_text: evidence,
      outcome_signal: signal,
      confidence: calculate_confidence(test_runs, errors, commits, reversed),
      analyzed_at: Time.current
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("InSessionAnalyzer: failed for decision #{decision.id}: #{e.message}")
    nil
  end

  def determine_signal(test_runs, errors, commits, reversed)
    return "negative" if reversed

    has_passing_tests = test_runs.any? { |t| t[:passed] > 0 && t[:failed] == 0 }
    has_failing_tests = test_runs.any? { |t| t[:failed] > 0 }
    last_test = test_runs.last

    # If the LAST test run passes, the decision led to a good outcome
    # regardless of errors or earlier failures along the way.
    if last_test && last_test[:failed] == 0 && last_test[:passed] > 0
      return "positive"
    end

    # Still failing at the end = negative
    return "negative" if last_test && last_test[:failed] > 0

    # No tests but committed = likely positive (developer was satisfied)
    return "positive" if commits > 0 && !has_failing_tests

    # Errors without resolution signals = mixed (development in progress)
    return "mixed" if errors > 0

    # No signal at all
    "neutral"
  end

  def calculate_confidence(test_runs, errors, commits, reversed)
    # More signal events = higher confidence
    signal_count = test_runs.size + (errors > 0 ? 1 : 0) + (commits > 0 ? 1 : 0) + (reversed ? 1 : 0)
    case signal_count
    when 0 then 0.3
    when 1 then 0.5
    when 2 then 0.7
    else 0.9
    end
  end

  def build_evidence(test_runs, errors, commits, reversed)
    parts = []
    if test_runs.any?
      total_passed = test_runs.sum { |t| t[:passed] }
      total_failed = test_runs.sum { |t| t[:failed] }
      parts << "#{test_runs.size} test run(s): #{total_passed} passed, #{total_failed} failed"
    end
    parts << "#{errors} error(s) encountered" if errors > 0
    parts << "#{commits} commit(s) made" if commits > 0
    parts << "User reversed direction" if reversed
    parts << "No signal events after decision" if parts.empty?
    parts.join(". ")
  end
end
