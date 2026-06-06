# Scrubs credentials out of free-text strings before they reach cloud LLM
# providers via TranscriptChunker, EventExtractor, or any other path that
# forwards user-supplied content. Sole authority for the Ruby-path pattern
# set.
#
# The `sed -E` block in upload_script.text.erb covers the DRY_RUN
# host-staged archive path (`run_dry_run_staging` → `build_archive`) and
# is maintained by hand in intentional near-parity with PATTERNS here —
# POSIX ERE can't express some of the Ruby features (lazy quantifiers,
# `\b`, multiline PEM), so the two drift slightly. If you widen PATTERNS,
# widen the sed too; both are tested.
#
# Fail-closed contract: a scrub call must not raise. On any input that can't
# be coerced into a String, returns "" rather than passing the original
# through. Callers that need the original length for a [N bytes] marker
# should capture it BEFORE calling scrub.
#
# Ordering is load-bearing. `anthropic_key` runs before `openai_key` so
# `sk-ant-…` gets consumed as an Anthropic key rather than an OpenAI one
# (the openai pattern accepts `sk-…` with an optional `proj-` prefix).
class SecretScrubber
  PATTERNS = {
    # -------- Vendor-prefixed keys --------
    # Anthropic: sk-ant-api03-… (95+ chars in practice).
    anthropic_key: [
      /sk-ant-[A-Za-z0-9_-]{20,}/,
      "[REDACTED_ANTHROPIC_KEY]"
    ],
    # OpenAI legacy (sk-…) and modern (sk-proj-…, sk-svcacct-…, sk-admin-…).
    # Char class allows _ and - to cover modern project keys — the old
    # upload_script sed missed `sk-proj-AbcD_efGh-…` because it used [A-Za-z0-9]
    # only. Order ensures sk-ant-… is consumed by anthropic_key first.
    openai_key: [
      /\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}/,
      "[REDACTED_OPENAI_KEY]"
    ],
    # AWS access key ID.
    aws_access_key: [
      /\bAKIA[A-Z0-9]{16,}/,
      "[REDACTED_AWS_ACCESS_KEY]"
    ],
    # GitHub fine-grained (ghp_, gho_, ghu_, ghs_, ghr_).
    github_token: [
      /\bgh[pousr]_[A-Za-z0-9_]{20,}/,
      "[REDACTED_GITHUB_TOKEN]"
    ],
    # Google Cloud / Firebase API key.
    google_api_key: [
      /\bAIza[A-Za-z0-9_-]{35}/,
      "[REDACTED_GOOGLE_API_KEY]"
    ],
    # JWT (three eyJ-prefixed base64 segments joined by dots).
    jwt: [
      /\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,
      "[REDACTED_JWT]"
    ],
    # Generic Bearer header. Widened char class to cover base64url +
    # padding (~, +, /, =) seen in OAuth2 opaque tokens. Case-insensitive
    # match — HTTP normalizes to capital `Bearer`, but informal prose
    # ("bearer token foo123…") does not. Must come after vendor-prefixed
    # keys so the vendor replacement wins for `Bearer sk-ant-…`.
    bearer_token: [
      /\b[Bb]earer[\s:=]+[A-Za-z0-9._\-~+\/=]{20,}/,
      "Bearer [REDACTED]"
    ],
    # PEM-encoded private keys (RSA, EC, OpenSSH, etc). Multiline.
    # `[A-Z0-9 ]*` (not `+`) so the bare, infix-less header
    # `-----BEGIN PRIVATE KEY-----` matches too — that's the default
    # `openssl genpkey` / PKCS#8 output AND the exact header embedded in
    # GCP service-account JSON (where the body uses literal `\n`, which
    # `[\s\S]+?` still spans). Not a ReDoS risk: the lazy body is anchored
    # by the literal `-----END`.
    private_key_block: [
      /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z0-9 ]*PRIVATE KEY-----/,
      "[REDACTED_PRIVATE_KEY]"
    ],
    # Database URLs with embedded credentials: postgres/redis/mongodb/mysql/mssql.
    # Captures the scheme so the replacement preserves the URL's shape.
    # `[^\s:@\/]*` allows empty user (`redis://:password@…`) which redis often
    # does — the empty-user form was silently bypassed by the original pattern.
    db_url_creds: [
      /\b(postgres(?:ql)?|redis|mongodb(?:\+srv)?|mysql|mssql|amqps?):\/\/[^\s:@\/]*:[^\s@]+@\S+/,
      '\1://[REDACTED]@host'
    ],
    # -------- More vendor-prefixed tokens (distinct patterns) --------
    # Placed AFTER bearer_token so `Bearer sk_live_…` still scrubs to the
    # generic `Bearer [REDACTED]` (preserved test), while a STANDALONE token
    # (not in a Bearer header / not in a VAR= assignment) is caught here.
    # All are distinct patterns — NOT loosenings of openai_key — and all run
    # BEFORE env_var_secret (which must stay last).
    #
    # Stripe secret/restricted keys: sk_live_… / rk_live_… / *_test_…
    # (underscore prefix, so openai_key's `sk-` hyphen pattern never matches).
    stripe_key: [
      /\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}/,
      "[REDACTED_STRIPE_KEY]"
    ],
    # Slack bot/user/app tokens: xoxb-/xoxp-/xoxa-/xoxr-/xoxs- and xapp-.
    slack_token: [
      /\b(?:xox[baprs]|xapp)-[A-Za-z0-9-]{10,}/,
      "[REDACTED_SLACK_TOKEN]"
    ],
    # HuggingFace user access tokens: hf_…
    huggingface_token: [
      /\bhf_[A-Za-z0-9]{20,}/,
      "[REDACTED_HF_TOKEN]"
    ],
    # npm automation/publish tokens: npm_… (36 chars in practice).
    npm_token: [
      /\bnpm_[A-Za-z0-9]{30,}/,
      "[REDACTED_NPM_TOKEN]"
    ],
    # PyPI upload tokens: pypi-…
    pypi_token: [
      /\bpypi-[A-Za-z0-9_-]{20,}/,
      "[REDACTED_PYPI_TOKEN]"
    ],
    # Paxel/YC API tokens: yk_ + 48 lowercase hex (ApiToken#generate_token =
    # "yk_" + SecureRandom.hex(24)). Users routinely paste the
    # `curl .../upload.sh?token=yk_…` command into a session, so the raw token
    # rides into the transcript → condensed_text → uploaded LLM prompt. The
    # {16,} hex floor matches the real 48-hex token while skipping short
    # placeholders (yk_abc123) and the redacted display form `yk_...<last8>`
    # (the `...` breaks the hex run). Distinct pattern; runs before
    # env_var_secret (which must stay last).
    yc_token: [
      /\byk_[0-9a-f]{16,}/,
      "[REDACTED_YC_TOKEN]"
    ],
    # Twilio Account SID (AC…) / API Key SID (SK…): prefix + 32 lowercase hex.
    twilio_key: [
      /\b(?:AC|SK)[0-9a-f]{32}\b/,
      "[REDACTED_TWILIO_KEY]"
    ],
    # Google OAuth refresh tokens: 1//0… (long base64url). Anchored on the
    # real `1//0` shape to avoid matching ordinary `1//` text.
    google_oauth_token: [
      %r{\b1//0[A-Za-z0-9_-]{20,}},
      "[REDACTED_GOOGLE_OAUTH]"
    ],
    # Azure Storage / connection-string AccountKey=… — mixed-case name, so
    # env_var_secret (ALL-CAPS names only) never catches it. Value is base64
    # (incl. + / =), delimited by `;` in the connection string.
    azure_account_key: [
      %r{\bAccountKey=[A-Za-z0-9+/=]{40,}},
      "AccountKey=[REDACTED]"
    ],
    # Environment-variable assignments for anything that looks secret.
    # Catches LIVEKIT_API_SECRET, STRIPE_SECRET_KEY, PG_PASSWORD, AUTH_TOKEN,
    # CLIENT_CREDENTIALS, OPENAI_API_KEY, OPENAI_API_KEYS (plural), etc.
    # First group is preserved so the user still sees which variable was
    # scrubbed.
    #
    # Lazy middle (`*?`) is load-bearing: `API_KEY=abc` requires the regex
    # to backtrack `[A-Z][A-Z0-9_]*` down to just `API_` so `KEY` can match
    # the suffix alternation. Greedy matching never reached the suffix.
    #
    # Trailing `S?` on the suffix alternation catches plural variants —
    # `API_KEYS=`, `TOKENS=`, `CREDENTIALS=`, `PASSWORDS=`. Opus review on
    # PR #706 flagged that `OPENAI_API_KEYS=abc` leaked because the prior
    # pattern required the suffix terminate immediately before `\s*=`.
    #
    # Value-side `[^\s"'\n,;.]+` deliberately stops at `.` so sentence-ending
    # periods (`...AUTH_TOKEN=abc.`) stay in the narrative. Real API tokens
    # use `-`, `_`, alphanumerics, base64 padding — rarely `.`. JWT is caught
    # by its own pattern above.
    #
    # Negative lookahead `(?!\[REDACTED)` prevents scanner re-matching our
    # own scrub placeholder. Post-scrub text `VAR=[REDACTED]` otherwise
    # satisfies `[^\s"'\n,;.]+` (brackets + letters are all non-excluded),
    # so `PaxelLeakScan` would report env_var_secret hits on already-
    # scrubbed rows and the retro-scrub runbook's "0 hits" verification
    # couldn't pass. Also covers vendor placeholders like
    # `VAR=[REDACTED_OPENAI_KEY]` that env_var_secret would otherwise
    # re-credit. Flagged by Codex on PR-retro-scrub-text review; latent
    # in 3a.1 as well but only surfaced here because :chunks version-
    # bumps those rows, blocking re-run eligibility.
    env_var_secret: [
      /\b([A-Z][A-Z0-9_]*?(?:SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY)S?)\s*=\s*(?!\[REDACTED)[^\s"'\n,;.]+/,
      '\1=[REDACTED]'
    ]
  }.freeze

  # Public API: scrub all known patterns from `text`. Returns a new String.
  # Preserves non-secret content; only the matched segments are replaced.
  #
  # Telemetry: emits `secret_scrubber.hit` via ActiveSupport::Notifications
  # with per-pattern hit counts when any pattern matched. Subscriber in
  # config/initializers/secret_scrubber_telemetry.rb persists to
  # `scrubber_hit_counters`. Fail-closed: telemetry emission is wrapped
  # in a rescue that never affects the scrubbed return value — if the
  # subscriber or DB is overloaded, the scrub still completes correctly.
  #
  # `emit_telemetry:` false suppresses the notification. PaxelRetroScrub
  # passes false: retro-scrub processes historical rows (some in dry-run
  # mode that must not write anywhere), and even the enforce path's
  # counts are retro-scan artifacts, not live forward-scrubber signal.
  # Mixing them would pollute the regression dashboard. (Codex P2 on
  # PR-scrubber-telemetry review.)
  #
  # @param text [String, nil] free-text to scrub
  # @param emit_telemetry [Boolean] whether to notify secret_scrubber.hit
  # @return [String] scrubbed copy (empty string on non-String / error)
  def self.scrub(text, emit_telemetry: true)
    return "" if text.nil?
    return "" unless text.respond_to?(:to_str)

    original = text.to_str
    result = original.dup
    PATTERNS.each_value do |(pattern, replacement)|
      result.gsub!(pattern, replacement)
    end
    emit_hit_telemetry(original, result) if emit_telemetry && result != original
    result
  rescue StandardError => e
    Rails.logger.warn("[SecretScrubber] scrub failed (#{e.class}): #{e.message.to_s.truncate(200)}") if defined?(Rails)
    ""
  end

  # Computes per-pattern hit counts for `original` (pre-scrub) via
  # PaxelLeakScan.pattern_counts (sequential-`.`-sentinel, so vendor
  # keys don't double-count as env_var_secret). Emits an
  # ActiveSupport::Notifications event — subscribers decide what to do
  # with it (persist, log, push to metrics).
  #
  # The `defined?(PaxelLeakScan)` guard is load-bearing for the client
  # Docker image: SecretScrubber IS copied into the client build but
  # PaxelLeakScan is NOT (server-only). Without the guard, client-side
  # scrubs would NameError and fall into the outer rescue. Client image
  # whitelist is enforced by Dockerfile.client — see BUILDING.md.
  #
  # Fails closed: any error here is logged + swallowed so the scrub
  # return value is unaffected.
  def self.emit_hit_telemetry(original, _scrubbed)
    return unless defined?(PaxelLeakScan) && defined?(ActiveSupport::Notifications)
    counts = PaxelLeakScan.pattern_counts(original)
    return if counts.empty?
    ActiveSupport::Notifications.instrument("secret_scrubber.hit", counts: counts)
  rescue StandardError => e
    Rails.logger.warn("[SecretScrubber] telemetry emit failed (#{e.class}): #{e.message.to_s.truncate(200)}") if defined?(Rails)
  end
  private_class_method :emit_hit_telemetry

  # Feature flag. Default on; set PAXEL_TOOL_OUTPUT_SCRUB=0 to bypass
  # (admin-only debugging). Callers MUST gate on this; the scrub itself
  # doesn't check because a few call sites want forced-on behavior
  # (e.g. retro-scrub rake).
  def self.enabled?
    ENV["PAXEL_TOOL_OUTPUT_SCRUB"] != "0"
  end
end
