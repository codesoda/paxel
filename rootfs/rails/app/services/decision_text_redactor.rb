# Regex-redacts decision proposal/response text before server upload.
#
# Strips fenced code blocks, indented code, long inline-code spans, and file
# paths; replaces each with a descriptive placeholder. Never sends exact
# codebase identifiers, class names, variable names, function signatures, or
# file paths to the server.
#
# Also exposes `regex_redact` as a public utility for other services (e.g.
# `EventExtractor` scrubs bash commands + subagent descriptions through it
# before packaging session_events).
class DecisionTextRedactor
  # --- Regex patterns ---
  FENCED_CODE = /```[\w]*\n[\s\S]*?```/m
  INDENTED_CODE = /^[ \t]{2,}(?:def |class |module |end$|if |unless |do$|do |require |include |extend |attr_|private|protected|public|return |raise |rescue |begin$|ensure$|yield|puts |print |const |let |var |function |import |export |from |=>|->|\{|\}|<\/|\/>)/m
  # Long-form backticked code: 10+ non-backtick chars, two paths to match:
  #   (1) contiguous (no internal whitespace) — a single code token like
  #       `order-processor`, `some.long.dot.chain`, `count++`.
  #   (2) multi-token — content has at least one structure char (uppercase,
  #       underscore, colon, dot, slash, hash, brace, paren, bracket, angle,
  #       assignment/addition operator). Catches `count = total + 1`,
  #       `RedisCache.new(ttl: 300)`.
  # The two-path gate prevents LONG from spuriously eating prose that happens
  # to span multiple words between two separate backticked identifiers in
  # the same sentence (e.g. "`nil` (was `true`). Leave `id` alone, really
  # `hello`." would otherwise match as 20+ chars between the inner backticks).
  LONG_INLINE_CODE = %r{`(?:[^`\s]{10,}|(?=[^`]*[A-Z_:.#/(){}\[\]<>=+])[^`]{10,})`}
  # Short backticked code-looking identifier: any length, but must contain an
  # uppercase letter or underscore somewhere. Catches project-specific refs
  # like `User`, `user_account`, `ActiveRecord::Base`, `foo.bar` while
  # preserving plain prose words like `nil`, `true`, `id`, `hello`.
  SHORT_IDENTIFIER = /`(?=[\w:.#]*[A-Z_])[\w:.#]+`/
  # Leading char class widened beyond whitespace so parenthesized / bracketed /
  # comma-separated paths (`(app/models/user.rb)`, `[foo.rb]`) still strip.
  # Extension list includes rake + ruby + web + common config/data formats.
  FILE_PATHS = /(?:^|[\s(\[{,:;])(?:\/[\w\-.\/]+|[\w\-]+(?:\/[\w\-.]+)*\.(?:rb|rake|ru|gemspec|py|js|ts|jsx|tsx|go|rs|java|cpp|c|h|css|html|erb|yml|yaml|json|toml|sql|sh|bash))\b/

  class << self
    # Single decision redaction. Returns { proposal:, response: }.
    def redact(proposal_text, response_text)
      return { proposal: "", response: "" } if proposal_text.blank? && response_text.blank?

      { proposal: regex_redact(proposal_text), response: regex_redact(response_text) }
    end

    # Batch redaction. Input: array of { proposal:, response: } hashes.
    # Returns: array of { proposal:, response: } hashes in same order.
    def redact_batch(decisions, &progress)
      return [] if decisions.empty?

      decisions.each_with_index.map do |d, i|
        result = { proposal: regex_redact(d[:proposal]), response: regex_redact(d[:response]) }
        progress&.call(i + 1, decisions.size)
        result
      end
    end

    def regex_redact(text)
      return "" if text.blank?
      result = text.dup
      result.gsub!(FENCED_CODE) { |match|
        lang = match[/```(\w+)/, 1]
        lines = match.count("\n") - 1
        lang ? "[#{lang} code, ~#{lines} lines]" : "[code block, ~#{lines} lines]"
      }
      result.gsub!(INDENTED_CODE, "[code line]")
      # SHORT_IDENTIFIER must run BEFORE LONG_INLINE_CODE. Otherwise
      # LONG_INLINE_CODE greedily spans the prose between two separate
      # backticked identifiers in the same sentence (e.g.
      # `User` model in `Billing.validate` → the 12-char " model in "
      # stretch between the inner backticks qualifies as "long inline code"
      # and gets redacted as prose). SHORT running first replaces each
      # `CamelCase` token, so LONG never sees adjacent-backtick prose.
      result.gsub!(SHORT_IDENTIFIER, "[identifier]")
      result.gsub!(LONG_INLINE_CODE, "[identifier]")
      result.gsub!(FILE_PATHS, " [path]")
      result.gsub!(/(\[\w*\s*code[^\]]*\]\s*){2,}/, "[code] ")
      result.strip.truncate(2000)
    end
  end
end
