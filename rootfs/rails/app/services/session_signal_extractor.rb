class SessionSignalExtractor
  # Bumped 2K → 20K (2026-04-23) in lockstep with TranscriptChunker::MAX_USER_TEXT_LENGTH.
  # The regex patterns below are simple alternations — linear in text length,
  # no nested quantifiers that could backtrack catastrophically — so 10× the
  # input size is ~10× the scan time, still well under 1ms per session.
  MAX_TEXT_FOR_REGEX = 20_000

  # Gap threshold for active-duration calculation. Deltas between
  # consecutive message timestamps above this are treated as idle time
  # (user walked away, session left open overnight, etc.) and excluded
  # from duration_minutes. Chosen to match BuilderMetrics::SESSION_GAP_MINUTES
  # which uses the same threshold for commit-stream work-session splitting.
  ACTIVE_GAP_MINUTES = 90

  # Pattern constants — each tested independently
  CRITIQUE_PATTERNS = /rate me|evaluate|how am i doing|critique|review my|what do you think of my/i
  SELF_CORRECTION_PATTERNS = /\bactually\b|wait,|no,\s|let me rethink|scratch that|on second thought/i
  KILL_PATTERNS = /\bdelete\b|\bremove\b|\bdrop\b|\bkill\b|get rid of|rip out|revert/i
  HYPOTHESIS_PATTERNS = /i think.*because|my theory is|i suspect|probably.*caused by|the issue is likely/i
  DOMAIN_CORRECTION_PATTERNS = /that's not how|actually it should|no,.*works like|you're wrong about/i
  # Genuine product-thinking signal. Tightened to drop bare "user" (matches
  # routine "user auth / user input") and bare "experience" (too broad), which
  # made Product Thinker fire in ~79% of uploads. Requires a real product term.
  PRODUCT_PATTERNS = /\bcustomer\b|\bUX\b|user experience|onboarding|\bfriction\b|pain point|product decision|user need|user research/i
  NARRATIVE_PATTERNS = /story|narrative|context|framework|profile|comprehensive|big picture/i
  REVIEW_PATTERNS = /looks wrong|check if|verify|doesn't look right|are you sure|let me see/i
  CONFIRMATION_PATTERNS = /should i proceed|shall i|do you want me to|is that ok/i
  # Genuine architecture-discussion signal. Tightened to drop generic coding terms
  # (service, pattern, extract, layer, separate, concern) that match nearly every
  # session and made The Architect fire in ~68% of uploads. Requires a real
  # architecture term (architecture, abstraction, coupling, modular, …).
  ARCHITECTURE_PATTERNS = /\barchitect(?:ure|ural)\b|\babstraction\b|\bdecoupl|\bcoupling\b|separation of concerns|design pattern|\bmodular|refactor into/i
  DEBUGGING_PATTERNS = /why|broken|error|fail|bug|wrong|issue|crash|exception|stack trace/i
  # Standalone gratitude toward the agent. Deliberately excludes "please" -- it
  # overwhelmingly prefixes instructions ("please refactor X") rather than
  # expressing courtesy, so counting it would inflate the "thank-yous" card.
  # "thanks(?! to)" drops attribution ("thanks to the new parser…"), which is not
  # courtesy toward the agent. count_matches counts MESSAGES that thank (not raw
  # phrase occurrences), so the card copy says "in N messages", not "N times".
  GRATITUDE_PATTERNS = /\bthank you\b|\bthanks\b(?! to\b)|\bthx\b|\bappreciate (?:it|that|this|you|the)\b/i

  IMPERATIVE_VERBS = %w[add build create implement write fix update refactor deploy run test make delete remove].freeze

  # --- Report-card candidate GATHERING (forward-only) ---
  # We do NOT judge here. These methods gather a small, scrubbed candidate set
  # from the raw prompts (the only place they exist) for a server-side LLM
  # (FunFactCardCurator) to judge into the go-to / cryptic / crash-out cards.

  # Short prompts (deduped, with counts) → go-to + cryptic candidates.
  SHORT_PROMPT_MAX_WORDS = 8
  MAX_REPEATED_PROMPTS   = 40

  # Crash-out candidates: a BROAD heat filter (profanity, repeated "stop",
  # multiple "!", or sustained shouting). Deliberately over-inclusive — the LLM
  # picks the real crash-out downstream; this only narrows thousands of messages.
  MAX_CHARGED_MESSAGES = 8
  # User-frustration signal (Anthropic's regex). Written single-line with
  # non-capturing groups so the intentional phrase-spaces ("piece of shit",
  # "what the hell") survive — /x would strip them. Broad recall for candidate
  # gathering; the LLM (FunFactCardCurator) decides which is a real crash-out.
  FRUSTRATION_REGEX = /\b(?:wtf|wth|ffs|omfg|shit(?:ty|tiest)?|dumbass|horrible|awful|piss(?:ed|ing)? off|piece of (?:shit|crap|junk)|what the (?:fuck|hell)|fucking? (?:broken|useless|terrible|awful|horrible)|fuck you|screw (?:this|you)|so frustrating|this sucks|damn it)\b/i
  # Uppercase tokens that are legitimately all-caps, excluded from shout detection.
  CAPS_ALLOWLIST = %w[I OK PR CI UI UX API URL URI SQL JSON HTML CSS YAML TODO FIXME LGTM WIP CLI SDK AWS DB].freeze

  def self.extract(user_messages:, first_timestamp:, last_timestamp:,
                   tool_count:, assistant_count:, git_commits:, tools_used:,
                   pr_diff: nil, events: nil, message_timestamps: nil)
    new.extract(
      user_messages: user_messages, first_timestamp: first_timestamp,
      last_timestamp: last_timestamp, tool_count: tool_count,
      assistant_count: assistant_count, git_commits: git_commits,
      tools_used: tools_used, pr_diff: pr_diff, events: events,
      message_timestamps: message_timestamps
    )
  end

  def extract(user_messages:, first_timestamp:, last_timestamp:,
              tool_count:, assistant_count:, git_commits:, tools_used:,
              pr_diff: nil, events: nil, message_timestamps: nil)
    texts = user_messages.map { |m| m[:text].to_s.truncate(MAX_TEXT_FOR_REGEX) }

    signals = {}
    signals.merge!(extract_quantitative(user_messages, first_timestamp, last_timestamp,
                                        tool_count, assistant_count, git_commits, tools_used,
                                        message_timestamps))
    signals.merge!(extract_event_signals(events))
    signals.merge!(extract_delegation(texts))
    signals.merge!(extract_feedback_loops(texts))
    signals.merge!(extract_decision_making(texts))
    signals.merge!(extract_domain_knowledge(texts))
    signals.merge!(extract_product_thinking(texts))
    signals.merge!(extract_communication(texts, user_messages))
    signals.merge!(extract_prompt_types(texts))
    signals.merge!(extract_repeated_prompts(user_messages))
    signals.merge!(extract_charged_messages(user_messages))
    signals.merge!(extract_pr_stats(pr_diff)) if pr_diff.present?
    signals
  end

  # Pure class-method duration calc for backfill use. Callers pass an
  # array of timestamp strings; returns active minutes (gap-split on
  # ACTIVE_GAP_MINUTES). Returns 0 for <2 parsable timestamps.
  def self.active_duration_minutes(message_timestamps)
    new.send(:compute_duration, nil, nil, message_timestamps)
  end

  private

  # --- Quantitative signals ---

  def extract_quantitative(user_messages, first_timestamp, last_timestamp,
                           tool_count, assistant_count, git_commits, tools_used,
                           message_timestamps = nil)
    duration_minutes = compute_duration(first_timestamp, last_timestamp, message_timestamps)
    user_msg_count = user_messages.size
    total_user_words = user_messages.sum { |m| m[:word_count] || 0 }
    avg_prompt_length = user_msg_count > 0 ? (total_user_words.to_f / user_msg_count).round(1) : 0

    {
      "user_message_count" => user_msg_count,
      "total_user_words" => total_user_words,
      "avg_prompt_length_words" => avg_prompt_length,
      "tool_count" => tool_count,
      "assistant_count" => assistant_count,
      "duration_minutes" => duration_minutes,
      "messages_per_minute" => duration_minutes > 0 ? (user_msg_count.to_f / duration_minutes).round(2) : 0,
      "tools_per_message" => user_msg_count > 0 ? (tool_count.to_f / user_msg_count).round(2) : 0,
      "git_commit_count" => git_commits&.size || 0,
      "unique_tools" => tools_used&.uniq&.size || 0,
      "plan_mode_used" => tools_used&.include?("EnterPlanMode") || false,
      "task_tool_used" => tools_used&.include?("Task") || false,
      "worktree_used" => tools_used&.include?("EnterWorktree") || false
    }
  end

  # Active duration: sum of deltas between consecutive message timestamps,
  # dropping deltas above ACTIVE_GAP_MINUTES (treated as idle time — session
  # left open overnight, user walked away, etc.). Falls back to naive
  # last-first span when a full timestamp list is not available (callers
  # that only have boundary timestamps, and unit tests pre-dating this
  # change).
  def compute_duration(first_ts, last_ts, message_timestamps = nil)
    parsed = parse_timestamps(message_timestamps)
    if parsed.size >= 2
      parsed.sort!
      active_seconds = 0.0
      parsed.each_cons(2) do |a, b|
        delta = b - a
        active_seconds += delta if delta <= ACTIVE_GAP_MINUTES * 60
      end
      return (active_seconds / 60.0).round(1)
    end

    return 0 unless first_ts && last_ts
    begin
      first = Time.parse(first_ts.to_s)
      last = Time.parse(last_ts.to_s)
    rescue ArgumentError, TypeError
      return 0
    end
    ((last - first) / 60.0).round(1)
  end

  def parse_timestamps(list)
    return [] unless list.is_a?(Array)
    list.filter_map do |ts|
      next if ts.nil? || ts.to_s.empty?
      begin
        Time.parse(ts.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end

  # --- Event-derived signals ---

  def extract_event_signals(events)
    return {} unless events.is_a?(Array) && events.any?

    file_count = events.count { |e| t = e["type"] || e[:type]; t == "file_edit" || t == "file_create" }
    test_events = events.select { |e| t = e["type"] || e[:type]; t == "test_run" }
    error_count = events.count { |e| t = e["type"] || e[:type]; t == "error_encountered" }

    total_passed = test_events.sum { |e| (e["passed"] || e[:passed]).to_i }
    total_failed = test_events.sum { |e| (e["failed"] || e[:failed]).to_i }
    total_tests = total_passed + total_failed

    plan_creates = events.count { |e| t = e["type"] || e[:type]; t == "file_create" && (e["path"] || e[:path]).to_s.match?(EventExtractor::PLAN_PATH_PATTERN) }

    signals = {
      "files_modified_count" => file_count,
      "test_run_count" => test_events.size,
      "error_count" => error_count
    }
    signals["plan_file_count"] = plan_creates if plan_creates > 0

    if total_tests > 0
      signals["test_pass_rate"] = (total_passed.to_f / total_tests).round(3)
    end

    signals.merge!(extract_tdd_discipline(events))
    signals.merge!(extract_recovery_speed(events))
    signals.merge!(extract_error_retry_ratio(events))

    signals
  end

  # TDD discipline: ratio of test-first sequences vs implementation-first
  def extract_tdd_discipline(events)
    first_test_idx = nil
    first_edit_idx = nil

    events.each_with_index do |e, i|
      type = e["type"] || e[:type]
      if type == "test_run" && first_test_idx.nil?
        first_test_idx = i
      elsif (type == "file_edit" || type == "file_create") && first_edit_idx.nil?
        # Plan-file writes are not implementation work. Codex's update_plan now
        # surfaces as a file_create at a synthetic plan path (CodexNormalizer,
        # finding #5), and Claude plan-mode writes .claude/plans/*.md the same way;
        # counting either as the "first edit" would falsely flip a planned session
        # to impl-first. Skip plan paths (plan_creates above still counts them).
        path = (e["path"] || e[:path]).to_s
        first_edit_idx = i unless path.match?(EventExtractor::PLAN_PATH_PATTERN)
      end
    end

    return {} unless first_test_idx || first_edit_idx

    test_first = first_test_idx && (first_edit_idx.nil? || first_test_idx < first_edit_idx)
    { "tdd_discipline_ratio" => test_first ? 1.0 : 0.0 }
  end

  # Recovery speed: median events from error_encountered to next successful test_run or git_commit
  def extract_recovery_speed(events)
    recovery_distances = []
    events.each_with_index do |e, i|
      type = e["type"] || e[:type]
      next unless type == "error_encountered"

      # Scan forward for recovery signal
      ((i + 1)...events.size).each do |j|
        jtype = events[j]["type"] || events[j][:type]
        if jtype == "test_run" && (events[j]["passed"] || events[j][:passed]).to_i > 0
          recovery_distances << (j - i)
          break
        elsif jtype == "git_commit"
          recovery_distances << (j - i)
          break
        end
      end
    end

    return {} if recovery_distances.empty?

    sorted = recovery_distances.sort
    median =
      if sorted.size.odd?
        sorted[sorted.size / 2]
      else
        (sorted[sorted.size / 2 - 1] + sorted[sorted.size / 2]) / 2.0
      end

    { "recovery_speed" => median.round(1) }
  end

  # Error retry ratio: consecutive identical bash commands after error / total errors
  def extract_error_retry_ratio(events)
    error_count = 0
    retried_errors = 0

    events.each_with_index do |e, i|
      type = e["type"] || e[:type]
      next unless type == "error_encountered"
      error_count += 1

      # Look at the bash command that caused this error (previous event)
      # and check if the same command appears after the error
      prev_cmd = nil
      (i - 1).downto(0) do |j|
        jtype = events[j]["type"] || events[j][:type]
        if jtype == "bash_command"
          prev_cmd = events[j]["command"] || events[j][:command]
          break
        end
      end
      next unless prev_cmd

      # Check next few events for same command
      ((i + 1)..[ i + 5, events.size - 1 ].min).each do |j|
        jtype = events[j]["type"] || events[j][:type]
        if jtype == "bash_command" && (events[j]["command"] || events[j][:command]) == prev_cmd
          retried_errors += 1
          break
        end
      end
    end

    return {} if error_count.zero?

    { "error_retry_ratio" => (retried_errors.to_f / error_count).round(3) }
  end

  # --- Delegation signals ---

  def extract_delegation(texts)
    {
      "imperative_prompts" => count_imperative(texts),
      "confirmation_requests" => count_matches(texts, CONFIRMATION_PATTERNS),
      "kill_decisions" => count_matches(texts, KILL_PATTERNS),
      "review_checks" => count_matches(texts, REVIEW_PATTERNS)
    }
  end

  def count_imperative(texts)
    texts.count do |t|
      first_word = t.strip.split(/\s+/).first&.downcase
      IMPERATIVE_VERBS.include?(first_word)
    end
  end

  # --- Feedback loop signals ---

  def extract_feedback_loops(texts)
    {
      "self_corrections" => count_matches(texts, SELF_CORRECTION_PATTERNS),
      "critiques" => count_matches(texts, CRITIQUE_PATTERNS),
      "domain_corrections" => count_matches(texts, DOMAIN_CORRECTION_PATTERNS)
    }
  end

  # --- Decision-making signals ---

  def extract_decision_making(texts)
    {
      "hypothesis_driven" => count_matches(texts, HYPOTHESIS_PATTERNS),
      "debugging_messages" => count_matches(texts, DEBUGGING_PATTERNS),
      "architecture_discussions" => count_matches(texts, ARCHITECTURE_PATTERNS)
    }
  end

  # --- Domain knowledge signals ---

  def extract_domain_knowledge(texts)
    {
      "narrative_framing" => count_matches(texts, NARRATIVE_PATTERNS)
    }
  end

  # --- Product thinking signals ---

  def extract_product_thinking(texts)
    {
      "product_references" => count_matches(texts, PRODUCT_PATTERNS)
    }
  end

  # --- Communication signals ---

  def extract_communication(texts, user_messages)
    substantive = user_messages.count { |m| (m[:word_count] || 0) > 15 }
    terse = user_messages.count { |m| (m[:word_count] || 0) <= 5 }
    {
      "substantive_messages" => substantive,
      "terse_messages" => terse,
      "substantive_ratio" => user_messages.size > 0 ? (substantive.to_f / user_messages.size).round(2) : 0,
      "courtesy_messages" => count_matches(texts, GRATITUDE_PATTERNS)
    }
  end

  # --- Prompt type classification ---

  def extract_prompt_types(texts)
    types = Hash.new(0)
    texts.each do |text|
      type = classify_prompt(text)
      types[type] += 1
    end
    { "prompt_types" => types }
  end

  def classify_prompt(text)
    stripped = text.strip.downcase
    first_word = stripped.split(/\s+/).first

    return "directive" if IMPERATIVE_VERBS.include?(first_word)
    return "question" if stripped.end_with?("?") || stripped.start_with?("how", "what", "why", "where", "when", "can you", "could you")
    return "correction" if stripped.match?(SELF_CORRECTION_PATTERNS) || stripped.match?(DOMAIN_CORRECTION_PATTERNS)
    return "debugging" if stripped.match?(DEBUGGING_PATTERNS)
    return "review" if stripped.match?(REVIEW_PATTERNS)
    "other"
  end

  # --- Report-card signals (forward-only) ---

  # Short-prompt frequency map → go-to + cryptic candidates. BuilderMetrics /
  # FunFactCardCurator merge these across the upload; a server LLM picks the
  # go-to phrase and the most cryptic prompt. Capped + scrubbed so only a small,
  # credential-free sample of short prompts leaves the machine.
  def extract_repeated_prompts(user_messages)
    counts = Hash.new(0)
    examples = {}
    user_messages.each do |m|
      wc = m[:word_count].to_i
      next if wc.zero? || wc > SHORT_PROMPT_MAX_WORDS
      norm = normalize_prompt(m[:text])
      next if norm.length < 2
      counts[norm] += 1
      examples[norm] ||= SecretScrubber.scrub(m[:text].to_s).strip.truncate(80)
    end
    return {} if counts.empty?

    top = counts.sort_by { |norm, c| [ -c, norm ] }.first(MAX_REPEATED_PROMPTS)
    { "repeated_prompts" => top.map { |norm, c| { "norm" => norm, "count" => c, "example" => examples[norm] } } }
  end

  def normalize_prompt(text)
    text.to_s.downcase.gsub(/[^a-z0-9 ]+/, " ").squeeze(" ").strip
  end

  # Crash-out candidates: a small, scrubbed sample of "charged" messages for the
  # LLM to judge. The heat filter is intentionally broad (recall over precision) —
  # the LLM, not this regex, decides which (if any) is a real crash-out.
  def extract_charged_messages(user_messages)
    out = []
    user_messages.each do |m|
      text = m[:text].to_s.strip
      next if text.empty? || text.length > 280
      next unless charged?(text)
      out << SecretScrubber.scrub(text).strip.truncate(200)
      break if out.size >= MAX_CHARGED_MESSAGES
    end
    out.uniq!
    out.empty? ? {} : { "charged_messages" => out }
  end

  def charged?(text)
    return true if text.match?(FRUSTRATION_REGEX)
    return true if text.count("!") >= 2
    shouts = text.scan(/\b[A-Z][A-Z']{2,}\b/).reject { |w| CAPS_ALLOWLIST.include?(w) }
    shouts.size >= 2
  end

  # --- PR diff stats (Issue 1C: single writer) ---

  def extract_pr_stats(pr_diff)
    { "pr_stats" => PrDiffStatsService.parse(pr_diff) }
  end

  # --- Helpers ---

  def count_matches(texts, pattern)
    texts.count { |t| t.match?(pattern) }
  end
end
