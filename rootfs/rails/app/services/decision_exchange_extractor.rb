# Detects decision exchanges from session_events and creates Decision records.
#
# A decision exchange is an agent_proposal event followed (within 1-3 events)
# by a user_directive event. The extractor collects candidate exchanges, then
# uses LLM classification (Haiku) to determine which are genuine decisions.
#
# Two-phase detection with LLM classification:
#
#   session_events
#     |
#     v
#   Pass 1: pair agent_proposal → user_directive (within 3 events)
#     |        collect as candidates
#     v
#   Pass 2: collect unpaired user_directives (proactive insight candidates)
#     |        noise filters: min words, session continuation, plan paste
#     v
#   LLM Classifier (Haiku, batches of 20)
#     |
#     ├── is_decision: true → Decision.create!
#     │     with decision_type, confidence, narrative
#     │
#     └── is_decision: false → skip (not a real decision)
#     |
#     v
#   FALLBACK: if LLM fails → regex classification (legacy behavior)
#     |
#     v
#   batch embed all decisions via EmbeddingService
#
class DecisionExchangeExtractor
  include TranscriptPatterns

  DOMAIN_PATTERNS = {
    "architecture" => /(?:service|model|controller|pattern|layer|schema|migration|database|api|endpoint|module|class|concern|interface)/i,
    "debugging" => /(?:error|bug|fix|broken|failing|exception|debug|root cause|stack trace|crash)/i,
    "scope" => /(?:scope|feature|priority|defer|cut|mvp|ship|phase|v1|v2|later|backlog)/i,
    "quality" => /(?:test|spec|coverage|refactor|validation|security|lint|type|safety)/i,
    "product" => /(?:user|customer|ux|ui|experience|flow|onboarding|design|layout)/i,
    "tooling" => /(?:ci|cd|deploy|docker|config|dependency|build|pipeline|infra)/i
  }.freeze

  ONE_WAY_PATTERNS = /(?:migration|schema|database|deploy|production|api.*contract|public.*interface|delete.*data|breaking.*change)/i
  REVERSIBLE_PATTERNS = /(?:config|env|style|format|lint|rename|variable|comment|log)/i

  # Max events to look forward for a user response after an agent proposal
  RESPONSE_WINDOW = 3
  # How many events around the response to search for agent_thinking amplification
  THINKING_SEARCH_WINDOW = 5
  # Minimum novel words (4+ chars, not in proposal) for counter-proposal detection
  MIN_NOVEL_WORDS = 3

  # Bumped 2026-04-23 per TODOS.md v1.0 Tier 1: decision exchanges are
  # the highest-signal transcript moments — the whole point of DIG.
  # Old 2000-char truncation cut proposals off mid-thought.
  MAX_EXCHANGE_TEXT_LENGTH = 10_000

  def self.extract!(upload, skip_embedding: false, heartbeat: true, &progress)
    new(upload, skip_embedding: skip_embedding, heartbeat: heartbeat).extract!(&progress)
  end

  # Retry embedding for decisions that failed to embed (e.g. after API outage)
  def self.backfill_embeddings!(upload)
    unembedded = Decision.where(upload_id: upload.id, embedding: nil)
    return 0 if unembedded.none?

    embedded_count = 0
    unembedded.each_slice(EMBED_BATCH_SIZE) do |batch|
      # EmbeddingService caps at 8K total — with proposal/response up
      # to 10K each, cap each half at ~3.5K so both contribute to the
      # embedding (otherwise response_text gets silently dropped and
      # similarity search becomes proposal-biased).
      texts = batch.map { |d| "#{d.proposal_text.to_s.truncate(3_800)}\n#{d.response_text.to_s.truncate(3_800)}" }
      embeddings = defined?(EmbeddingService) ? EmbeddingService.embed_batch(texts) : []
      if embeddings.empty?
        Rails.logger.warn("[DecisionExchangeExtractor] embed_batch returned empty for #{batch.size} decisions")
        next
      end

      batch.each_with_index do |decision, i|
        next unless embeddings[i]
        Decision.where(id: decision.id).update_all(embedding: embeddings[i].to_s)
        embedded_count += 1
      end
    end

    embedded_count
  end

  def initialize(upload, skip_embedding: false, heartbeat: true)
    @upload = upload
    @skip_embedding = skip_embedding
    @heartbeat = heartbeat
    @decisions = []
  end

  def extract!(&progress)
    # Clear prior decisions (idempotent on re-analyze)
    Decision.where(upload_id: @upload.id).destroy_all

    @upload.projects.each do |project|
      repository = project.repository
      next unless repository

      sessions = project.transcript_sessions.logical_roots.to_a
      extract_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sessions.each_with_index do |session, idx|
        # 3rd arg lets the client pipeline show a live "what's being scanned"
        # blurb in the progress footer. Block callers taking |done, total|
        # simply ignore it; the other extract! callers pass no block.
        progress&.call(idx + 1, sessions.size, session)
        if (idx % 5).zero? || idx == sessions.size - 1
          elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - extract_start).round(1)
          @upload.log_step("decisions", "Session #{idx + 1}/#{sessions.size} (#{elapsed}s elapsed, #{@decisions.size} decisions so far)")
        end
        session_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        extract_from_session(session, repository)
        session_dur = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - session_start) * 1000).round(1)
        Rails.logger.info("[DecisionExtractor] Session #{idx + 1}/#{sessions.size} #{session.session_id.first(8)}: #{session_dur}ms") if session_dur > 5000
      end
    end

    embed_decisions if @decisions.any? && !@skip_embedding
    @decisions.size
  end

  private

  def extract_from_session(session, repository)
    events = session.session_events
    return if events.empty?

    candidates = []

    # Pass 1: pair agent_proposal → user_directive candidates
    paired_indices = Set.new
    i = 0
    while i < events.size
      event = events[i]
      if event["type"] == "agent_proposal"
        response = find_response(events, i)
        if response
          paired_indices << response[:index]
          candidates << {
            agent_text: event["text"].to_s,
            user_text: response[:event]["text"].to_s,
            proposal_event: event,
            response_event: response[:event],
            event_index: i,
            response_index: response[:index],
            session: session,
            repository: repository,
            events: events,
            source: :paired
          }
        end
      end
      i += 1
    end

    # Pass 2: collect unpaired user_directives as proactive insight candidates
    events.each_with_index do |event, idx|
      next unless event["type"] == "user_directive"
      next if paired_indices.include?(idx)

      text = event["text"].to_s
      next if text.split(/\s+/).size < MIN_PROACTIVE_WORDS
      next if text.start_with?(SESSION_CONTINUATION_PREFIX)
      next if text.start_with?(PLAN_PASTE_PREFIX)

      context_text = find_nearby_thinking(events, idx)
      candidates << {
        agent_text: context_text || "",
        user_text: text,
        proposal_event: context_text ? { "text" => context_text } : nil,
        response_event: event,
        event_index: idx,
        response_index: idx,
        session: session,
        repository: repository,
        events: events,
        source: :unpaired
      }
    end

    return if candidates.empty?

    # Classify with LLM, fall back to regex on failure
    classifier = DecisionClassifier.new(upload: @upload)
    classifications = classifier.classify(candidates, heartbeat: @heartbeat)

    if classifications.any?
      create_classified_decisions(candidates, classifications)
    else
      Rails.logger.warn("[DecisionExchangeExtractor] LLM classification returned empty, falling back to regex")
      create_regex_decisions(candidates)
    end
  end

  def find_response(events, proposal_idx)
    search_end = [ proposal_idx + RESPONSE_WINDOW + 1, events.size ].min
    ((proposal_idx + 1)...search_end).each do |j|
      event = events[j]
      if event["type"] == "user_directive"
        return { event: event, index: j }
      end
      # Stop if we hit another agent_proposal (unanswered proposal)
      return nil if event["type"] == "agent_proposal"
    end
    nil
  end

  def create_decision(session:, repository:, proposal_event:, response_event:, event_index:, events: [], response_index: nil)
    proposal_text = proposal_event["text"].to_s
    response_text = response_event["text"].to_s
    combined = "#{proposal_text} #{response_text}"

    proposal_type = proposal_event["proposal_type"] || "question"
    significance = classify_significance(response_text, combined)

    # Counter-proposal: user rejects all options and redefines the problem
    is_counter_proposal = detect_counter_proposal(proposal_event, response_text)
    if is_counter_proposal
      proposal_type = "counter_proposal"
      significance = "strategic"
    end

    # Agent amplification: agent's thinking recognizes user insight as pivotal
    is_agent_recognized = detect_agent_amplification(events, response_index)
    if is_agent_recognized && significance != "strategic"
      significance = escalate_significance(significance)
    end

    Decision.create!(
      repository: repository,
      upload: @upload,
      transcript_session: session,
      proposal_text: proposal_text.truncate(MAX_EXCHANGE_TEXT_LENGTH),
      response_text: response_text.truncate(MAX_EXCHANGE_TEXT_LENGTH),
      proposal_type: proposal_type,
      option_count: proposal_event["option_count"],
      response_word_count: response_text.split(/\s+/).size,
      domain: classify_domain(combined),
      significance: significance,
      reversibility: classify_reversibility(combined),
      status: "open",
      event_index: event_index,
      agent_recognized: is_agent_recognized
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("DecisionExchangeExtractor: failed to create decision: #{e.message}")
    nil
  end

  def detect_counter_proposal(proposal_event, response_text)
    return false unless proposal_event["proposal_type"] == "options"

    # User must NOT reference any proposed option
    return false if OPTION_REFERENCE_PATTERNS.any? { |p| response_text.match?(p) }

    # Dual signal: novel words OR reversal indicator
    has_reversal = response_text.match?(REVERSAL_INDICATORS)

    proposal_words = proposal_event["text"].to_s.downcase.scan(/\b\w{4,}\b/).to_set
    response_words = response_text.downcase.scan(/\b\w{4,}\b/)
    novel_count = response_words.count { |w| !proposal_words.include?(w) }

    novel_count >= MIN_NOVEL_WORDS || has_reversal
  end

  def detect_agent_amplification(events, response_index)
    return false if events.empty? || response_index.nil?

    search_start = [ response_index - THINKING_SEARCH_WINDOW, 0 ].max
    search_end = [ response_index + THINKING_SEARCH_WINDOW, events.size - 1 ].min

    (search_start..search_end).any? do |i|
      event = events[i]
      next unless event["type"] == "agent_thinking"
      text = event["text"].to_s
      AMPLIFICATION_PATTERNS.any? { |p| text.match?(p) }
    end
  end

  def escalate_significance(current)
    case current
    when "tactical" then "moderate"
    when "moderate" then "strategic"
    else current
    end
  end

  def classify_domain(text)
    DOMAIN_PATTERNS.each do |domain, pattern|
      return domain if text.match?(pattern)
    end
    "general"
  end

  def classify_significance(response_text, combined_text)
    word_count = response_text.split(/\s+/).size
    domain = classify_domain(combined_text)

    if word_count > 30 && (domain == "architecture" || combined_text.match?(ONE_WAY_PATTERNS) || response_text.match?(/because|reason|since|given that/i))
      "strategic"
    elsif word_count > 15 || !%w[debugging tooling].include?(domain)
      "moderate"
    else
      "tactical"
    end
  end

  def classify_reversibility(text)
    if text.match?(ONE_WAY_PATTERNS)
      "one_way"
    elsif text.match?(REVERSIBLE_PATTERNS)
      "reversible"
    else
      "unknown"
    end
  end

  def find_nearby_thinking(events, user_idx)
    search_start = [ user_idx - THINKING_SEARCH_WINDOW, 0 ].max
    search_end = [ user_idx + THINKING_SEARCH_WINDOW, events.size - 1 ].min
    # Prefer preceding thinking (agent's current context)
    preceding = (search_start...user_idx).reverse_each.find { |i| events[i]["type"] == "agent_thinking" }
    return events[preceding]["text"].to_s if preceding
    following = ((user_idx + 1)..search_end).find { |i| events[i]["type"] == "agent_thinking" }
    return events[following]["text"].to_s if following
    nil
  end

  def create_proactive_insight(session:, repository:, user_event:, event_index:, context_text:)
    user_text = user_event["text"].to_s
    proposal_text = context_text.present? ? context_text : "[Proactive insight — no surrounding agent context]"
    combined = "#{proposal_text} #{user_text}"

    Decision.create!(
      repository: repository, upload: @upload, transcript_session: session,
      proposal_text: proposal_text.truncate(MAX_EXCHANGE_TEXT_LENGTH),
      response_text: user_text.truncate(MAX_EXCHANGE_TEXT_LENGTH),
      proposal_type: "proactive_insight", option_count: nil,
      response_word_count: user_text.split(/\s+/).size,
      domain: classify_domain(combined),
      significance: "strategic",
      reversibility: classify_reversibility(combined),
      status: "open", event_index: event_index, agent_recognized: true
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("DecisionExchangeExtractor: proactive_insight failed: #{e.message}")
    nil
  end

  # LLM-classified decision creation: only creates records for is_decision=true
  def create_classified_decisions(candidates, classifications)
    classification_map = classifications.index_by { |c| c[:index] }

    candidates.each_with_index do |candidate, idx|
      classification = classification_map[idx]
      next unless classification&.dig(:is_decision)

      combined = "#{candidate[:agent_text]} #{candidate[:user_text]}"
      proposal_type = candidate.dig(:proposal_event, "proposal_type") ||
                      (candidate[:source] == :unpaired ? "proactive_insight" : "options")

      decision = Decision.create!(
        repository: candidate[:repository],
        upload: @upload,
        transcript_session: candidate[:session],
        proposal_text: candidate[:agent_text].to_s.truncate(MAX_EXCHANGE_TEXT_LENGTH),
        response_text: candidate[:user_text].to_s.truncate(MAX_EXCHANGE_TEXT_LENGTH),
        proposal_type: proposal_type,
        decision_type: classification[:decision_type],
        law_key: classification[:law_key],
        classification_confidence: classification[:confidence],
        decision_narrative: classification[:narrative],
        option_count: candidate.dig(:proposal_event, "option_count"),
        response_word_count: candidate[:user_text].to_s.split(/\s+/).size,
        domain: classify_domain(combined),
        significance: infer_significance(classification),
        reversibility: classify_reversibility(combined),
        status: "open",
        event_index: candidate[:event_index],
        agent_recognized: candidate[:source] == :paired ?
          detect_agent_amplification(candidate[:events], candidate[:response_index]) : true
      )
      @decisions << decision
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("DecisionExchangeExtractor: classified decision failed: #{e.message}")
    end
  end

  def infer_significance(classification)
    case classification[:decision_type]
    when "strategic_redirect", "product_insight" then "strategic"
    when "technical_catch" then "moderate"
    when "option_selection" then "tactical"
    else "tactical"
    end
  end

  # Regex-based fallback when LLM classification fails
  def create_regex_decisions(candidates)
    candidates.each do |candidate|
      if candidate[:source] == :paired
        decision = create_decision(
          session: candidate[:session],
          repository: candidate[:repository],
          proposal_event: candidate[:proposal_event],
          response_event: candidate[:response_event],
          event_index: candidate[:event_index],
          events: candidate[:events],
          response_index: candidate[:response_index]
        )
        @decisions << decision if decision
      else
        # For unpaired candidates in fallback, use regex proactive insight detection
        next unless PROACTIVE_REFRAME_PATTERNS.any? { |p| candidate[:user_text].match?(p) }
        next unless detect_agent_amplification(candidate[:events], candidate[:response_index])

        decision = create_proactive_insight(
          session: candidate[:session],
          repository: candidate[:repository],
          user_event: candidate[:response_event],
          event_index: candidate[:event_index],
          context_text: candidate[:agent_text].presence
        )
        @decisions << decision if decision
      end
    end
  end

  # Outer paging batch size; EmbeddingService re-slices by provider.batch_limit.
  EMBED_BATCH_SIZE = 128

  def embed_decisions
    @decisions.each_slice(EMBED_BATCH_SIZE) do |batch|
      # EmbeddingService caps at 8K total — with proposal/response up
      # to 10K each, cap each half at ~3.5K so both contribute to the
      # embedding (otherwise response_text gets silently dropped and
      # similarity search becomes proposal-biased).
      texts = batch.map { |d| "#{d.proposal_text.to_s.truncate(3_800)}\n#{d.response_text.to_s.truncate(3_800)}" }
      embeddings = defined?(EmbeddingService) ? EmbeddingService.embed_batch(texts) : []
      next if embeddings.empty?

      batch.each_with_index do |decision, i|
        next unless embeddings[i]
        Decision.where(id: decision.id).update_all(embedding: embeddings[i].to_s)
      end
    end
  rescue => e
    Rails.logger.warn("DecisionExchangeExtractor: embedding failed: #{e.message}")
  end
end
