# Classifies decision exchanges using Haiku LLM instead of regex pattern matching.
#
# Pipeline position: called by DecisionExchangeExtractor after pairing candidates.
# Replaces regex-based detect_counter_proposal with semantic LLM classification.
#
# Flow:
#   candidates[] ──▶ batch(20) ──▶ Haiku LLM ──▶ classifications[]
#       │                              │                 │
#       │                              ▼                 ▼
#       │                         parse JSON       is_decision: true/false
#       │                              │           decision_type
#       │                              ▼           confidence
#       │                         on failure:      narrative
#       │                         return []
#       │                         (caller falls back to regex)
#       ▼
#   candidates not in classifications → handled by caller's fallback
#
class DecisionClassifier
  include AnthropicClient
  include TranscriptPatterns

  PROMPT_VERSION = "v5" # v5 (2026-06-05): GPT-first migration (#1022) — MODEL → gpt-5.5 (effort none) + appended calibration-corrections block fixing gpt-5.5's measured failure modes (passive-agreement over-detected as a decision, option_selection↔strategic_redirect confusion, confidence under-calling). Recovers + exceeds Haiku on the decision_classifier fixtures: 97.5% vs 95% deterministic (gpt-5.5-none, Opus judge, n=40). classification_system_prompt is client-signed → old Haiku-prompt sig 4890a2e1f641690b graced in ProxyCallValidator. Client-side → dormant until client rebuild, new-uploads-only. Change type: quality improvement + model migration. | v4: calibration fix — anti-pattern + wrong-target guidance for 3 rhetorical laws (reject-lazy-workaround, demand-before-after-proof, challenge-the-constraint) per 2026-04-26 90-sample hand-grade in rhetorical_laws_handgrade_2026_04_26.md
  BATCH_SIZE = 20
  # GPT-first (#1022): route via the central swap-back map (currently gpt-5.5, effort none).
  # Was hardcoded "claude-haiku-4-5"; using MODELS.fetch keeps the log label (client_pipeline.rb
  # cloud_model_label(MODEL)) + cache key + call_llm consistent and follows a future swap-back.
  MODEL = AnthropicClient::MODELS.fetch(:fast)
  # Bumped 500 → 2_000 (2026-04-23, TODOS.md v1.0 Tier 2) — classifier
  # made worse calls on truncated input; 2K covers most decision texts
  # without blowing up batch token count.
  MAX_TEXT_LENGTH = 2_000

  # Used by ProxyCallValidator to compute the known signature
  def self.system_prompt_for_validation
    new(upload: nil).send(:classification_system_prompt)
  end

  def initialize(upload:)
    @upload = upload
  end

  def classify(candidates, heartbeat: true)
    return [] if candidates.empty?

    @heartbeat = heartbeat
    results = []
    @total_batches = (candidates.size.to_f / BATCH_SIZE).ceil
    @current_batch = 0
    candidates.each_slice(BATCH_SIZE).with_index(1) do |batch, batch_num|
      @current_batch = batch_num
      Rails.logger.info("[DecisionClassifier] Batch #{batch_num}/#{@total_batches} (#{batch.size} candidates)")
      batch_results = classify_batch(batch)
      results.concat(batch_results)
      Rails.logger.info("[DecisionClassifier] Batch #{batch_num}/#{@total_batches} done, #{batch_results.size} classified")
    end
    results
  rescue StandardError => e
    # Fatal LLM errors must propagate so the rake footer can show user_action
    # and request_id. Decision classification is best-effort for everything
    # else (returns [] so the pipeline continues without decision data).
    raise if defined?(PaxelLlmError) && e.is_a?(PaxelLlmError::Fatal)
    Rails.logger.error("[DecisionClassifier] Classification failed: #{e.class}: #{e.message}")
    []
  end

  private

  def classify_batch(batch)
    prompt = build_prompt(batch)
    system = classification_system_prompt

    # Check LLM result cache
    cached = LlmResultCache.fetch(
      service_name: "DecisionClassifier",
      input_text: prompt,
      prompt_text: system,
      model: MODEL,
      prompt_version: PROMPT_VERSION
    )
    return cached.map(&:symbolize_keys) if cached

    # Cache miss — call LLM
    response = call_llm(
      model: MODEL,
      system: system,
      messages: [ { role: "user", content: prompt } ],
      max_tokens: batch.size * 100,
      heartbeat_label: -> { "Classifying decisions, batch #{@current_batch}/#{@total_batches}..." },
      heartbeat: @heartbeat
    )

    results = parse_response(response, batch.size)

    LlmResultCache.store(
      service_name: "DecisionClassifier",
      input_text: prompt,
      prompt_text: system,
      model: MODEL,
      prompt_version: PROMPT_VERSION,
      result: results
    )

    results
  rescue JSON::ParserError => e
    Rails.logger.warn("[DecisionClassifier] Batch JSON parse failed: #{e.message}")
    []
  end

  def classification_system_prompt
    <<~PROMPT
      You classify decision exchanges between a human developer and an AI coding agent.

      For each exchange, determine:

      1. is_decision (boolean): Did the human exercise genuine judgment?
         TRUE when the human: redirected the approach, caught something the agent missed,
         made a product/architecture decision, or chose between meaningful alternatives.
         FALSE when the human: gave routine instructions ("commit and push"),
         acknowledged completed work ("looks good"), continued a session,
         or the agent was reporting results rather than proposing options.

      2. decision_type (string, only if is_decision=true):
         Classify by the SUBSTANCE of what was decided, not the conversational mechanic:
         - strategic_redirect: Human changes the technical approach, architecture, or implementation strategy.
           Key signal: the WHAT or HOW of the work changes direction.
           Examples: "Use Elasticsearch instead of Postgres FTS", "Put validation in the model, not controller"
         - technical_catch: Human identifies a specific bug, performance issue, security flaw, or missing test coverage
           that the agent missed or didn't consider.
           Key signal: something WRONG or MISSING is caught.
           Examples: "That token isn't hashed", "This retry will mask connection pool exhaustion"
         - product_insight: Human makes a decision grounded in user needs, UX, or product behavior —
           regardless of whether it's phrased as a redirect.
           Key signal: the decision is about WHAT USERS EXPERIENCE, not about technical implementation.
           Examples: "Users shouldn't see stack traces", "Add autocomplete for better UX"
         - option_selection: Human picks from explicitly presented options WITHOUT adding significant
           new constraints or reasoning. If they pick an option AND add conditions/constraints
           that reshape the execution, classify as strategic_redirect instead.
           Key signal: agent said "option 1, 2, or 3?" and human said "option 2".

      3. confidence: high, medium, or low
         - high: the classification is clear-cut with no reasonable alternative interpretation
         - medium: there are two plausible types but one is stronger
         - low: genuinely ambiguous, could reasonably be classified differently

      4. narrative (string, only if is_decision=true):
         One sentence explaining what the developer decided and why it mattered.
         Be specific — name the technical choice, not "the developer made a decision."

      5. law_key (string, only if is_decision=true):
         Which Law of Vibe Coding does this decision most closely match?
         Return the kebab-case key, or null if none match well. Only match if the
         decision clearly demonstrates the cognitive pattern. Most decisions won't
         match any law. Don't force-fit.

      ## Laws Catalog

      #{DecisionLawCatalog.compact_prompt}

      ## Direction-Sensitive Laws — Anti-Pattern Guidance

      For these three rare-moves laws, the most common misclassification is matching
      the OPPOSITE direction of the law. Same surface words ("no", "instead", "why?"),
      inverted intent. Always check the direction before matching one of these three.

      reject-lazy-workaround
        Match when: developer REFUSES an agent's capability-degrading workaround and
          demands the real fix. Agent has hit a wall; developer says "no, fix it"
          or "find the root cause" — preserving capability.
        Don't match (anti-pattern, opposite direction): developer ACCEPTS the workaround.
          "no, let's not touch the sync logic — just exclude that field" is the builder
          PICKING the exclusion, not refusing it. Same "no, let's not" surface words,
          inverted intent.

      demand-before-after-proof
        Match when: developer demands a controlled re-run on the SAME inputs to compare
          before/after. "Run v8 on the same 10 uploads we ran v7 on" — apples-to-apples.
        Don't match (anti-pattern, opposite direction): developer EXPLICITLY OPTS OUT
          of the re-run. "Push it through without the eval re-run" / "skip the eval
          suite, the samples look fine" is the OPPOSITE of demand. Builder shipping
          without before/after data.

      challenge-the-constraint
        Match when: developer QUESTIONS a premise the agent treats as fixed. "Why does
          this need to go in the reports table?" — one question collapses the approach.
          The premise being questioned is the agent's framing, not just an
          implementation detail.
        Don't match (anti-pattern, opposite direction): developer ACCEPTS the constraint
          and picks within it. "The proxy ceiling is fixed; pick A or B" is
          option_selection within frame, not premise-questioning. "We have to ship by
          Friday so just shim it" accepts the deadline as fixed.

      ## Examples

      Exchange: Agent: "Here are three options for the auth flow: 1) JWT tokens 2) Session cookies 3) OAuth"
      Developer: "go with option 2, session cookies"
      → {"index":0,"is_decision":true,"decision_type":"option_selection","confidence":"high","narrative":"Chose session cookies over JWT and OAuth for auth flow","law_key":null}

      Exchange: Agent: "I've committed the changes and pushed to the branch."
      Developer: "commit and merge to origin main no PR needed"
      → {"index":1,"is_decision":false}

      Exchange: Agent: "The figures page shows avg bias of the articles. Here's what the data supports..."
      Developer: "that's meaningless — it tells you about the articles, not about how the figure is portrayed"
      → {"index":2,"is_decision":true,"decision_type":"product_insight","confidence":"high","narrative":"Identified that article-level bias metrics are meaningless for per-figure analysis","law_key":"spot-the-nonsequitur"}

      Exchange: Agent: "Done. Two things: 1. Branch is up to date 2. Added Git Branches section to CLAUDE.md"
      Developer: "Continue from where you left off."
      → {"index":3,"is_decision":false}

      Exchange: Agent: "The test is failing because the mock doesn't match the actual API response format."
      Developer: "don't mock the database in these tests — we got burned last quarter"
      → {"index":4,"is_decision":true,"decision_type":"strategic_redirect","confidence":"high","narrative":"Rejected mock-based testing in favor of real database integration tests based on prior incident","law_key":"iron-rule"}

      Exchange: Agent: "I've implemented the retry logic with exponential backoff."
      Developer: "wait — that retry will mask the connection pool exhaustion we're seeing in prod"
      → {"index":5,"is_decision":true,"decision_type":"technical_catch","confidence":"high","narrative":"Caught that retry logic would mask connection pool exhaustion bug instead of surfacing it","law_key":"one-level-deeper"}

      Exchange: Agent: "For the error page, I'll show the full stack trace and error message."
      Developer: "No, users shouldn't see stack traces. Show a friendly error page with a unique error ID."
      → {"index":6,"is_decision":true,"decision_type":"product_insight","confidence":"high","narrative":"Decided to show user-friendly error page with reference ID instead of raw stack traces","law_key":"enforce-safety-rails"}

      Exchange: Agent: "I can investigate the root cause or revert the change."
      Developer: "Revert now, investigate later. Uptime is the priority."
      → {"index":7,"is_decision":true,"decision_type":"strategic_redirect","confidence":"medium","narrative":"Prioritized uptime by choosing immediate revert over root-cause investigation","law_key":null}

      Exchange: Agent: "Tightened the redaction rules. Patch matches our three samples."
      Developer: "Now grab a random upload from a different user and check if the patch handles a case we didn't design for."
      → {"index":8,"is_decision":true,"decision_type":"strategic_redirect","confidence":"high","narrative":"Asked for generalization check on a fresh upload, not a same-inputs comparison","law_key":null}

      Exchange: Agent: "Bumped the summarizer prompt to v6. The new output reads cleaner on the three samples I checked."
      Developer: "Skip the eval suite. The new outputs look better. Ship it — we'll catch any regression in next week's review."
      → {"index":9,"is_decision":true,"decision_type":"strategic_redirect","confidence":"high","narrative":"Chose to ship without controlled before/after eval, accepting eyeball validation","law_key":null}

      Return a JSON array with one object per exchange, indexed by position.

      ## CALIBRATION CORRECTIONS (apply these to every classification; where they conflict with examples above, these win)

      These correct three systematic gpt-5.5 errors. They override any conflicting guidance above.

      1. PASSIVE AGREEMENT IS NOT A DECISION.
      If the user merely assents to, approves, or greenlights what the AI already proposed ("ok", "sounds good", "go ahead", "yes do that", "lgtm", "perfect", "ship it") WITHOUT adding a constraint, choosing among alternatives, catching a problem, or changing direction, set is_decision=false. A decision requires the human to exercise judgment the AI did not already make for them. Approving a single AI proposal when no alternative was on the table is acceptance, not a decision. (Selecting among multiple options, or approving while adding a real constraint, correction, or scope change, IS a decision.)

      2. option_selection VS strategic_redirect.
      Use option_selection when the user CHOSE one of two or more concrete options that were on the table (the AI offered them, or the user names the alternatives), e.g. which approach, scope, library, or implementation to use, even if they justified the pick with a tradeoff or a "ship the smaller scope now, harden later" rationale. Use strategic_redirect when the user REVERSES COURSE or changes the goal/direction of work already underway, including choosing to revert, roll back, or abandon the current approach, even when that was framed as picking from offered options. Rule of thumb: choosing which of the offered paths to take is option_selection; undoing or turning away from the path already in progress is strategic_redirect.

      3. CONFIDENCE: DO NOT UNDER-CALL.
      Use confidence=high when the user's message unambiguously shows the decision: an explicit choice, a clear directive, a direct rejection or correction, or a specific named option selected. A decision can be short and still be high-confidence; brevity is not ambiguity. Reserve medium for genuinely borderline cases where the decision is only implied or the user's intent is partly ambiguous. Use low only when inferring a decision from weak signal. Do not default to medium out of caution.
    PROMPT
  end

  def build_prompt(batch)
    lines = batch.each_with_index.map do |candidate, idx|
      agent = candidate[:agent_text].to_s.truncate(MAX_TEXT_LENGTH)
      user = candidate[:user_text].to_s.truncate(MAX_TEXT_LENGTH)
      "Exchange #{idx}:\nAgent: #{agent}\nDeveloper: #{user}\n"
    end
    "Classify these #{batch.size} exchanges:\n\n#{lines.join("\n")}"
  end

  def parse_response(response, expected_count)
    text = extract_text(response)
    parsed = extract_json_array(text)
    return [] unless parsed.is_a?(Array) && parsed.any?

    parsed.first(expected_count).map do |item|
      law_key = item["law_key"]
      law_key = nil unless DecisionLawCatalog.keys.include?(law_key)
      {
        index: item["index"].to_i,
        is_decision: item["is_decision"] == true,
        decision_type: item["decision_type"],
        confidence: item["confidence"],
        narrative: item["narrative"],
        law_key: law_key
      }
    end
  rescue JSON::ParserError => e
    Rails.logger.warn("[DecisionClassifier] JSON parse failed: #{e.message}")
    []
  end

  # Robust JSON array extraction with multiple fallback strategies
  def extract_json_array(text)
    return nil if text.blank?

    # Strategy 1: Direct [...] regex match
    begin
      if (match = text.match(/\[.*?\]/m))
        parsed = JSON.parse(match[0])
        return parsed if parsed.is_a?(Array)
      end
    rescue JSON::ParserError
      # Fall through to next strategy
    end

    # Strategy 2: Strip markdown fences and retry
    stripped = text.gsub(/```(?:json)?\s*/i, "").gsub(/```/, "")
    begin
      if (match = stripped.match(/\[.*?\]/m))
        parsed = JSON.parse(match[0])
        return parsed if parsed.is_a?(Array)
      end
    rescue JSON::ParserError
      # Fall through to next strategy
    end

    # Strategy 3: Try parsing individual {...} objects into an array
    # Only accept objects that have the required "index" field to avoid
    # misapplying stray JSON fragments as classification results
    objects = stripped.scan(/\{[^{}]*\}/m)
    if objects.any?
      items = objects.filter_map do |obj|
        parsed = JSON.parse(obj) rescue nil
        parsed if parsed.is_a?(Hash) && parsed.key?("index")
      end
      return items if items.any?
    end

    nil
  end
end
