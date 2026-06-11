# Validates that proxy requests match known client pipeline call signatures.
# Unknown signatures are rejected to prevent abuse of the LLM proxy.
#
#   KNOWN CALL SIGNATURES (full prompt hash):
#   ──────────────────────────────────────────
#   SessionNarrativeAnalyzer  → SYSTEM_PROMPT (narrative generation)
#   SessionNarrativeAnalyzer  → MERGE_SYSTEM_PROMPT (multi-pass merge)
#   EpisodeSummarizer         → V3ScoringPromptBuilder output (episode scoring)
#
#   VALIDATION:
#   ───────────
#   1. Model must be on the allowlist
#   2. Full system prompt SHA256 must match a known hash (current OR legacy)
#   3. Unknown signatures are logged and rejected with 403
#
#   SECURITY: Hashing the FULL prompt (not a prefix) prevents attackers from
#   copying a valid prefix and changing instructions after it.
#
#   LEGACY ACCEPTANCE:
#   ──────────────────
#   Old client Docker images in the wild carry prompt text from prior releases.
#   When a prompt rotates, those images would otherwise start failing with 403
#   "Unknown call signature" immediately. LEGACY_ACCEPTED_SIGNATURES is an
#   ENV-driven set of rotated-out hashes that still pass validation for a
#   bounded window (typically 14 days after a release), giving users time to
#   pull the new image.
#
#   Populate via: YC_PROXY_LEGACY_SIGNATURES="sig1,sig2,sig3"
#   Each accepted legacy signature emits a warning log so ops can track
#   usage and decide when to prune.
class ProxyCallValidator
  # GPT families + reasoning-effort suffixes. Reasoning levels ride the model
  # string (e.g. "gpt-5.5-high"); the Bun proxy parses the suffix into an
  # OpenAI reasoning.effort (services/llm-proxy/lib/provider-routing.ts
  # parseOpenAiModel + REASONING_EFFORTS — keep these two lists in sync).
  # Every variant a caller may send must be allowlisted or the proxy 403s
  # `model_not_allowed` before forwarding. Adding GPT here is server-side
  # only: the client never checks the allowlist, and ALLOWED_MODELS is not
  # part of the prompt-signature contract, so no client rebuild / signature
  # rotation is needed.
  GPT_FAMILIES = %w[ gpt-5.5 gpt-5.4-mini ].freeze
  REASONING_EFFORTS = %w[ none low medium high xhigh ].freeze
  GPT_MODELS = GPT_FAMILIES.flat_map do |fam|
    [ fam ] + REASONING_EFFORTS.map { |e| "#{fam}-#{e}" }
  end.freeze

  ALLOWED_MODELS = (%w[
    claude-haiku-4-5-20251001
    claude-haiku-4-5
    claude-sonnet-4-20250514
    claude-sonnet-4-6-20250603
    claude-sonnet-4-6
  ] + GPT_MODELS).freeze

  # Hard-coded legacy signatures from recently-rotated prompts. Each entry
  # should carry a "remove on or after" date — when no clients are expected
  # to still send the prior prompt, drop the entry via a one-line PR.
  # Comma-separated additional sigs via ENV are merged in for ad-hoc use.
  HARDCODED_LEGACY_SIGNATURES = %w[
    ceeeefab4da71672
    4890a2e1f641690b
    d0abbc52ededa9f2
    9be49ebdb88c7494
    53aa3251517def32
    48788c0bd60fe4a6
    2a4fc217cd58a29e
    690533c700f904f4
  ].freeze
  # ^ d0abbc52ededa9f2: SessionNarrativeAnalyzer MERGE_SYSTEM_PROMPT (pre-v5) — rotated 2026-06-05
  #   to sync its section names ("What the Developer Decided") + 520-word ceiling with the v5
  #   SYSTEM_PROMPT. Only the multi-pass (>60K-token) narrative path uses it. Remove on/after 2026-06-19.
  # ^ ceeeefab4da71672: SessionNarrativeAnalyzer SYSTEM_PROMPT v4 (the #1020 untrusted-frame
  #   prompt) — rotated to v5 on 2026-06-05 (GPT-specific refresh on top of #1022's gpt-5.5
  #   routing). Keeps client images on the v4 prompt validating until they pull the v5 image.
  #   Remove on or after 2026-06-19 — ~14d for client image churn.
  # ^ 4890a2e1f641690b: DecisionClassifier classification prompt v4 (the Haiku-era prompt) —
  #   rotated to v5 on 2026-06-05 (gpt-5.5 migration + calibration-corrections block).
  #   Remove on or after 2026-06-19.
  # ^ 9be49ebdb88c7494: SessionNarrativeAnalyzer SYSTEM_PROMPT v3 (rotated to v4 on
  #   2026-06-05 — added the untrusted-input frame, T1.2). Keeps old client images'
  #   session-narrative calls validating until they pull the v4 image.
  #   Remove on or after 2026-06-19 — ~14d for client image churn.
  #   (Dropped f5900d428a30d96f — DecisionClassifier v3, past its 2026-05-10 date.)
  # ^ The next four are EpisodeSummarizer episode-prompt signatures. v11-v13 were
  #   rotated out by the v14 calibration merge (#988, the "## Calibration"
  #   full-scale section); v14 itself was rotated out 22 minutes later by #982's
  #   CRITICAL_FRAMING rewrite (v15) and was MISSED at the time — any client
  #   image published from that window 403s on episode scoring without it.
  #   Whichever prompt the currently-published client image carries, this keeps
  #   its episode scoring working until it pulls a v15+ image.
  #   Remove on or after 2026-06-19.
  #     53aa3251517def32 — episode prompt v11 (pre-#976/#980 base)
  #     48788c0bd60fe4a6 — episode prompt v12 (#980 planning reword)
  #     2a4fc217cd58a29e — episode prompt v13 (#976 LOC grounding)
  #     690533c700f904f4 — episode prompt v14 (#988 calibration; verified from
  #       `git show 53a45a57:` + Digest::SHA256[0..15], matches the graced v13
  #       recomputed the same way)

  LEGACY_ACCEPTED_SIGNATURES = (HARDCODED_LEGACY_SIGNATURES.to_set +
                                 ENV["YC_PROXY_LEGACY_SIGNATURES"].to_s.split(",").map(&:strip).reject(&:empty?).to_set).freeze

  def self.validate(system_prompt:, model:, max_tokens: nil)
    new.validate(system_prompt: system_prompt, model: model, max_tokens: max_tokens)
  end

  # Public accessor used by the preflight endpoint. The client computes its
  # own signature set by running the SAME prompt-building code (it ships
  # with the client image), then POSTs the set to compare against what the
  # server currently accepts.
  def self.current_signatures
    new.send(:known_signatures).dup.freeze
  end

  def self.legacy_accepted_signatures
    LEGACY_ACCEPTED_SIGNATURES
  end

  # 16-char truncated SHA256 of the sorted current-signature set. Stable
  # as long as the underlying prompt code is byte-identical; client +
  # server compute this independently and compare.
  def self.contract_version
    hashes = current_signatures.to_a.sort.join("\n")
    Digest::SHA256.hexdigest(hashes)[0..15]
  end

  def validate(system_prompt:, model:, max_tokens: nil)
    unless ALLOWED_MODELS.include?(model)
      return { valid: false, reason: "Model not allowed: #{model}" }
    end

    # Extract text from array format (prompt caching sends system as content blocks)
    prompt_text = AnthropicClient.extract_system_text(system_prompt)

    if prompt_text.blank?
      return { valid: false, reason: "System prompt required" }
    end

    signature = Digest::SHA256.hexdigest(prompt_text)[0..15]

    if known_signatures.include?(signature)
      return { valid: true, signature: signature, scope: "current" }
    end

    if LEGACY_ACCEPTED_SIGNATURES.include?(signature)
      # Accept but warn. Ops can count these in logs to decide when to prune
      # the legacy window. The client gets a successful request; the
      # client-visible deprecation warning header + rake footer ship in the
      # next PR alongside the preflight handshake.
      Rails.logger.warn("[ProxyCallValidator] Legacy signature accepted: #{signature} len=#{system_prompt.length}")
      return { valid: true, signature: signature, scope: "legacy" }
    end

    Rails.logger.warn("[ProxyCallValidator] Unknown call signature: #{signature} len=#{system_prompt.length}")
    { valid: false, reason: "Unknown call signature" }
  end

  private

  def known_signatures
    @known_signatures ||= compute_known_signatures
  end

  def compute_known_signatures
    signatures = Set.new

    # SessionNarrativeAnalyzer — main narrative prompt
    signatures << Digest::SHA256.hexdigest(SessionNarrativeAnalyzer::SYSTEM_PROMPT)[0..15]

    # SessionNarrativeAnalyzer — multi-pass merge prompt
    if SessionNarrativeAnalyzer.const_defined?(:MERGE_SYSTEM_PROMPT)
      signatures << Digest::SHA256.hexdigest(SessionNarrativeAnalyzer::MERGE_SYSTEM_PROMPT)[0..15]
    end

    # EpisodeSummarizer (V3ScoringPromptBuilder)
    es_prompt = V3ScoringPromptBuilder.build_episode_prompt(nil)
    signatures << Digest::SHA256.hexdigest(es_prompt)[0..15]

    # DecisionClassifier — dynamic prompt includes law catalog
    if defined?(DecisionClassifier)
      signatures << Digest::SHA256.hexdigest(DecisionClassifier.system_prompt_for_validation)[0..15]
    end

    signatures
  end
end
