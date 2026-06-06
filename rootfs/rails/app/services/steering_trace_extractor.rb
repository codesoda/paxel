class SteeringTraceExtractor
  include TranscriptPatterns

  # Steering actions detected from user_directive events
  STEERING_ACTIONS = {
    explore: /let's (try|explore|look at|investigate|check)|what if|how about|i wonder/i,
    constrain: /\b(must|should|always|never|require|constraint|rule)\b.*\b(use|follow|apply|enforce)\b/i,
    delegate: /\b(implement|build|create|write|add|fix|update|deploy|run|test|make)\b/i,
    inspect: /\b(show me|let me see|what does|how does|look at|check|verify|review)\b/i,
    reject: /\b(no|wrong|bad|don't|stop|that's not|revert|undo|scratch that|kill)\b/i,
    redirect: REDIRECT_INDICATORS,
    verify: /\b(test|verify|check|confirm|make sure|does it|is it|run the)\b/i,
    ship: /\b(ship|deploy|push|release|merge|commit|done|good to go|looks good)\b/i,
    debug: /\b(why|error|fail|bug|broken|wrong|issue|crash|exception|trace)\b/i,
    recover: /\b(fix|resolve|recover|restore|rollback|patch|workaround|fallback)\b/i
  }.freeze

  def self.extract!(upload)
    new(upload).extract!
  end

  def initialize(upload)
    @upload = upload
  end

  def extract!
    sessions = @upload.projects
      .flat_map { |p| p.transcript_sessions.logical_roots }

    count = 0
    sessions.each do |session|
      user_events = session.events_of_type("user_directive")
      trace = if user_events.any?
        extract_trace_from_events(user_events)
      else
        { actions: [], action_counts: {}, total_actions: 0 }
      end
      # Use update_column to avoid StaleObjectError and callbacks
      TranscriptSession.where(id: session.id).update_all(steering_trace: trace.to_json)
      count += 1 if trace[:actions].any?
    end
    count
  end

  def extract_trace_from_events(events)
    actions = []
    action_counts = Hash.new(0)

    events.each_with_index do |event, idx|
      text = event["text"].to_s.strip.truncate(500)
      next if text.blank?

      STEERING_ACTIONS.each do |action_type, pattern|
        if text.match?(pattern)
          actions << { type: action_type.to_s, line: idx, text: text.truncate(200) }
          action_counts[action_type.to_s] += 1
        end
      end
    end

    {
      actions: actions.first(100),
      action_counts: action_counts,
      total_actions: actions.size
    }
  end
end
