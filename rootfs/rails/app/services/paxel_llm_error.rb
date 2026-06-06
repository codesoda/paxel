# Centralized error envelope for Paxel LLM gateway failures.
#
# Any exception escaping AnthropicClient#call_llm is normalized to one of these
# classes. Downstream code (ClientPipeline, EpisodeSummarizer, DecisionClassifier,
# analyze_local.rake) rescues PaxelLlmError::* — never raw Anthropic::Errors::*.
#
#   Base (abstract — all Paxel LLM errors)
#   ├── Retryable               — 429, 5xx, connection, overload; retried by call_llm
#   ├── ContentFiltered         — 400 code="content_filtered": the model provider's
#   │                             INPUT safety filter declined the content (GPT-only;
#   │                             e.g. security-research transcripts). NON-fatal +
#   │                             NON-retryable — the caller SKIPS the item and
#   │                             continues; a single one must NOT trip the circuit
#   │                             breaker (only Fatal does).
#   └── Fatal                   — user must do something; propagates to rake footer
#       ├── ClientOutOfDate     — 403 proxy_code="client_out_of_date" (signature drift)
#       ├── QuotaExceeded       — 401/403 proxy_code="quota_exceeded" (daily cap)
#       ├── AuthFailed          — 401 other
#       ├── InputTooLarge       — 413 proxy_code="input_too_large"
#       ├── ModelNotAllowed     — 403 proxy_code="model_not_allowed"
#       ├── SystemPromptMissing — 403 proxy_code="system_prompt_missing"
#       └── ProtocolViolation   — SDK parse failure (preserves original .cause)
#
# Every Fatal must populate #user_action. The rake footer prints:
#   What happened: <message>
#   What to do:    <user_action>
#   Request id:    <request_id || "n/a">
#
# Dependency direction: PaxelLlmError has zero deps on Anthropic SDK. Only
# AnthropicClient may import Anthropic::*; downstream code imports PaxelLlmError.
module PaxelLlmError
  # Authoritative redaction list for any response-body text that flows out of
  # the LLM error path (CLI footer, upload.error_message, Sentry extra). The
  # server-side Sentry beforeSend scrubber and the client-side
  # ClientSentryScrubber are defense-in-depth second layers for other string
  # surfaces on the event; body_preview is guaranteed-scrubbed here so every
  # consumer sees the same sanitized value. See privacy.html.erb §6.
  BODY_SCRUB_PATTERNS = [
    [ /sk-ant-[A-Za-z0-9_-]{20,}/,  "[REDACTED_ANTHROPIC]" ],
    [ /sk-[A-Za-z0-9_-]{20,}/,      "[REDACTED_OPENAI]"    ],
    # GitHub tokens (classic PAT gho_, fine-grained github_pat_, server-to-
    # server ghs_, OAuth ghu_, refresh ghr_, app ghi_). Pattern must come
    # before the Bearer regex since `Bearer ghp_...` would otherwise be
    # redacted as `Bearer [REDACTED]` without tagging the token class.
    [ /gh[pousir]_[A-Za-z0-9]{20,}/, "[REDACTED_GITHUB]"   ],
    [ /github_pat_[A-Za-z0-9_]{20,}/, "[REDACTED_GITHUB]"  ],
    [ /Bearer\s+[A-Za-z0-9._-]+/i,  "Bearer [REDACTED]"    ],
    [ /yk_[A-Za-z0-9_-]+/,          "[REDACTED_YC_TOKEN]"  ],
    [ /eyJ[A-Za-z0-9._-]{20,}/,     "[REDACTED_JWT]"       ],
    [ /[\w.+-]+@[\w-]+\.[\w.-]+/,   "[REDACTED_EMAIL]"     ],
    [ /\b\d{1,3}(\.\d{1,3}){3}\b/,  "[REDACTED_IP]"        ]
  ].freeze

  class Base < StandardError
    attr_reader :http_status, :upstream_type, :proxy_code, :request_id, :user_action, :retry_after,
                :body_preview, :response_content_type

    def initialize(message, http_status: nil, upstream_type: nil, proxy_code: nil,
                   request_id: nil, user_action: nil, retry_after: nil,
                   body_preview: nil, response_content_type: nil)
      super(message)
      @http_status            = http_status
      @upstream_type          = upstream_type
      @proxy_code             = proxy_code
      @request_id             = request_id
      @user_action            = user_action
      @retry_after            = retry_after
      @body_preview           = self.class.scrub(body_preview)
      @response_content_type  = response_content_type
    end

    # Cap on user_action length in #log_context output. Audited against every
    # user_action helper in anthropic_client.rb (prod branches where env-aware)
    # as of 2026-04-24:
    # model_not_allowed (240) > system_prompt_missing (235) > input_too_large (202)
    # > rebuild (190) > default (134) > auth (129) > quota (96).
    # 300 admits every current string whole with ~60 char headroom; any new
    # subclass whose user_action exceeds 300 will be silently truncated, so
    # paxel_llm_error_spec pins the "longest-in-use fits whole" invariant.
    # If a new subclass needs more than ~60 chars, bump the limit rather than
    # truncating — the promise is that user_action reaches support tickets.
    USER_ACTION_LOG_LIMIT = 300

    # Pipe-delimited suffix for log lines that concatenate exception context
    # onto a message string. Used by swallow-then-log rescue paths that can't
    # rely on Sentry to carry request_id / proxy_code / user_action (see
    # builder_profile_service.rb + judge_service.rb). Attr order is fixed:
    # request_id | proxy_code | http_status | user_action — pinned by spec so
    # grep / log parsers can rely on position.
    #
    # Returns "" when every attr is nil so callers can always write
    # "...#{e.message}#{e.log_context}" without a guard. Excludes body_preview
    # (length-bounded but still verbose — would blow up processing_log row
    # size), retry_after (Retryable-only; irrelevant once swallowed),
    # upstream_type (redundant with proxy_code), response_content_type
    # (Sentry diagnostics only).
    def log_context
      parts = []
      parts << "request_id=#{request_id}"   if request_id
      parts << "proxy_code=#{proxy_code}"   if proxy_code
      parts << "http_status=#{http_status}" if http_status
      parts << "user_action=#{user_action.to_s.truncate(USER_ACTION_LOG_LIMIT)}" if user_action
      parts.empty? ? "" : " | #{parts.join(' | ')}"
    end

    # Fallback remediation text any Fatal subclass can use when no more-specific
    # action applies. The rake footer prints request_id on its own line, so this
    # copy stays focused on what the user does next.
    def self.default_user_action(_request_id = nil)
      "Re-run the command shown on your Paxel dashboard. " \
        "If it still fails, email paxel@ycombinator.com (include the Request id shown above)."
    end

    # Redact tokens/emails/IPs in a response-body preview before it flows to
    # any consumer. Nil-safe; idempotent; called from #initialize so every
    # call-site inherits the guarantee.
    def self.scrub(text)
      return nil if text.nil?
      # Force UTF-8 with invalid-byte replacement so a binary / gzipped /
      # mis-declared-encoding response body can't raise
      # Encoding::CompatibilityError inside gsub. Without this, the
      # normalizer's outer rescue catches it and we lose the preview
      # entirely — which is the exact opposite of what this code exists to
      # prevent.
      safe = text.to_s.dup.force_encoding("UTF-8")
      safe = safe.scrub("?") unless safe.valid_encoding?
      return nil if safe.empty?
      BODY_SCRUB_PATTERNS.inject(safe) { |acc, (pat, repl)| acc.gsub(pat, repl) }
    end
  end

  class Retryable < Base; end

  # The model provider's INPUT content/safety filter declined this specific
  # request. Deterministic (retrying the same content won't help) AND
  # provider-wide (failover won't help — both OpenAI providers share the filter),
  # so it's neither Retryable nor Fatal: the pipeline SKIPS the affected item
  # (session/episode) and continues. A single one must NOT trip the circuit
  # breaker — only PaxelLlmError::Fatal does (pipeline_circuit_breaker.rb#failure!).
  # Raised on both LLM paths: AnthropicClient#normalize_sdk_error (SDK→proxy) and
  # OpenaiClient#handle_http_errors (server-direct). GPT-first regression: Anthropic
  # had no equivalent input filter.
  class ContentFiltered < Base; end

  class Fatal < Base; end

  class ClientOutOfDate     < Fatal; end
  class QuotaExceeded       < Fatal; end
  class AuthFailed          < Fatal; end
  class InputTooLarge       < Fatal; end
  class ModelNotAllowed     < Fatal; end
  class SystemPromptMissing < Fatal; end
  class ProtocolViolation   < Fatal; end
end
