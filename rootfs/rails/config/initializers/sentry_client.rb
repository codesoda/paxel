# Client-only Sentry initializer. Copied into the client Docker image via
# Dockerfile.client; this is the single exception to the "no initializers
# in the client image" rule — enforced by spec/docker/client_image_spec.rb
# and .github/workflows/build-client.yml.
#
# Two guards, both required:
#   - CLIENT_MODE=1 is set only by Dockerfile.client (never on dev machines).
#   - CLIENT_SENTRY_DSN is baked via --build-arg during prod publish; dev
#     builds leave it empty so local errors never reach prod Sentry.
#
# Opt-out: docker run -e CLIENT_SENTRY_DSN="" (or bin/upload --no-sentry,
# which sets that override via the rendered upload script).
#
# Note: the ClientSentryScrubber module is defined unconditionally so that
# specs can load this file and unit-test the scrubber without triggering
# Sentry.init. The Sentry.init call at the bottom is guarded instead.

require "sentry-ruby"

module ClientSentryScrubber
  HOME_RE       = %r{/(?:Users|home)/[^/\s"']+}
  WIN_HOME_RE   = %r{[A-Za-z]:\\Users\\[^\\"']+}i
  # Absolute NON-home filesystem paths (HOME_RE/WIN_HOME_RE cover the home dir).
  # A conservative root allowlist — NOT a blanket /\w+(/\w+)+ — so ordinary
  # prose and the proxy URL path (e.g. /v1/messages) aren't mangled. Collapses
  # the path to "<path>" so an exception like "Errno::ENOENT - /rails/app/x" or
  # a "/tmp/abc/y" / "/private/var/folders/..." temp path doesn't ship the
  # local tree via error telemetry. Applied LAST so it can't interfere with
  # git-remote / DB-URL / email detection above.
  ROOT_PATH_RE  = %r{/(?:tmp|var|private|opt|etc|usr|rails|srv|mnt|root)\b(?:/[^\s"':]*)*}
  YC_TOKEN_RE   = /yk_[A-Za-z0-9_]+/
  BEARER_RE     = /Bearer\s+[A-Za-z0-9._-]+/i
  ANTHROPIC_RE  = /sk-ant-[A-Za-z0-9_-]+/
  OPENAI_RE     = /\bsk-[A-Za-z0-9_-]{20,}\b/
  GITHUB_RE     = /\bgh[pousr]_[A-Za-z0-9]{20,}\b/
  JWT_RE        = /\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/
  # DB connection strings: scheme://user:password@host[:port]/db?params.
  # Must run before EMAIL_RE (which would otherwise eat `password@db.host.com`
  # as an email) and before GIT_REMOTE_RE. Mirrors SecretScrubber's pattern.
  DB_URL_RE     = %r{\b(postgres(?:ql)?|redis|mongodb(?:\+srv)?|mysql|mssql|amqps?)://[^\s:@/]*:[^\s@]+@\S+}
  EMAIL_RE      = /[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/
  # Four alternatives, split so `https://arbitrary-host/v1/messages` (the
  # Paxel LLM proxy URL) is NOT matched — the previous single-regex form
  # treated every `https://host/seg/seg` as a git remote, scrubbed the proxy
  # URL out of Sentry events, and made triage of ARGUS-CLIENT-1 impossible.
  #   1. ssh forms: `git@host:user/repo` or `ssh://git@host/user/repo`
  #   2. https on a well-known git hostname (github / gitlab / bitbucket /
  #      codeberg) — with optional subdomain and optional `:port`
  #   3. https on a `git.*` hostname (self-hosted GitLab/Gitea), with port
  #   4. any https URL whose path ends in `.git` (catch-all, with port)
  # The subdomain prefix in branch 2 requires a trailing `.` so hostnames
  # like `digit.example.com` or `legit.corp.com` don't false-match via the
  # substring "git".
  GIT_REMOTE_RE = %r{
    (?:git@|ssh://git@)[^\s/]+[:/][\w.-]+/[\w.-]+(?:\.git)?
    |
    https://(?:[\w.-]+\.)?(?:github|gitlab|bitbucket|codeberg)[\w-]*\.[\w.-]+(?::\d+)?/[\w.-]+/[\w.-]+(?:\.git)?
    |
    https://git\.[\w.-]+(?::\d+)?/[\w.-]+/[\w.-]+(?:\.git)?
    |
    https://[^\s/]+(?::\d+)?/[\w./-]+\.git\b
  }x
  MAX_STR = 500

  def self.scrub_string(s)
    return s unless s.is_a?(String) && !s.empty?

    # Order matters: git remote URLs contain "@" and would otherwise be
    # partially eaten by EMAIL_RE, so GIT_REMOTE_RE must run before EMAIL_RE.
    # Token / key / home-path regexes also run first so a URL like
    # `https://oauth2:yk_abc@github.com/org/repo` has the token scrubbed
    # before the rest of the URL matches GIT_REMOTE_RE.
    out = s.dup
    out.gsub!(HOME_RE,       "/~")
    out.gsub!(WIN_HOME_RE,   'C:\\~')
    out.gsub!(YC_TOKEN_RE,   "yk_***")
    out.gsub!(BEARER_RE,     "Bearer ***")
    out.gsub!(ANTHROPIC_RE,  "sk-ant-***")
    out.gsub!(OPENAI_RE,     "sk-***")
    out.gsub!(GITHUB_RE,     "gh_***")
    out.gsub!(JWT_RE,        "eyJ***")
    out.gsub!(DB_URL_RE,     '\1://[REDACTED]@host')
    out.gsub!(GIT_REMOTE_RE, "[git-remote]")
    out.gsub!(EMAIL_RE,      "[email]")
    out.gsub!(ROOT_PATH_RE,  "<path>")
    out.length > MAX_STR ? out[0, MAX_STR] + "…[truncated]" : out
  end

  def self.scrub_deep!(obj)
    case obj
    when String
      scrub_string(obj)
    when Array
      obj.map! { |v| scrub_deep!(v) }
      obj
    when Hash
      obj.each { |k, v| obj[k] = scrub_deep!(v) }
      obj
    else
      obj
    end
  end

  # Mutates the Sentry event in place. Verified against sentry-ruby 6.5.0:
  # - Event#WRITER_ATTRIBUTES covers message, transaction, contexts, user,
  #   tags, extra, fingerprint, breadcrumbs (all writable).
  # - Event#request is attr_reader only — nullified via instance_variable_set
  #   as defense-in-depth (send_default_pii=false is the primary gate).
  # - SingleExceptionInterface#value is attr_accessor (writable).
  # - StacktraceInterface::Frame has attr_accessor for all attributes we touch.
  def self.scrub_event!(event)
    if event.respond_to?(:request) && !event.request.nil?
      event.instance_variable_set(:@request, nil)
    end

    if event.respond_to?(:contexts) && event.contexts.is_a?(Hash)
      %i[os device runtime].each do |k|
        event.contexts.delete(k)
        event.contexts.delete(k.to_s)
      end
    end

    if event.respond_to?(:message=) && event.message.is_a?(String)
      event.message = scrub_string(event.message)
    end

    if event.respond_to?(:transaction=) && event.transaction.is_a?(String)
      event.transaction = scrub_string(event.transaction)
    end

    if event.respond_to?(:exception) && event.exception
      Array(event.exception.values).each do |ex|
        ex.value = scrub_string(ex.value) if ex.respond_to?(:value=) && ex.value.is_a?(String)
        next unless ex.respond_to?(:stacktrace) && ex.stacktrace.respond_to?(:frames)

        Array(ex.stacktrace.frames).each do |f|
          f.vars = nil if f.respond_to?(:vars=)
          %i[filename abs_path module function].each do |attr|
            setter = :"#{attr}="
            next unless f.respond_to?(attr) && f.respond_to?(setter)

            val = f.send(attr)
            f.send(setter, scrub_string(val)) if val.is_a?(String)
          end
        end
      end
    end

    # Sentry::BreadcrumbBuffer exposes .members (Array of Breadcrumbs) and
    # is Enumerable via .each. It does NOT have .values. Guard both shapes
    # so this works with Hash-style doubles in unit specs too.
    if event.respond_to?(:breadcrumbs) && event.breadcrumbs
      bc_container = event.breadcrumbs
      bcs = if bc_container.respond_to?(:members)
        bc_container.members
      elsif bc_container.respond_to?(:values)
        bc_container.values
      else
        []
      end
      Array(bcs).each { |bc| scrub_breadcrumb!(bc) }
    end

    %i[extra tags user fingerprint].each do |attr|
      next unless event.respond_to?(attr)

      val = event.send(attr)
      case val
      when Hash
        scrub_deep!(val)
      when Array
        val.map! { |v| scrub_deep!(v) }
      end
    end

    event
  end

  def self.scrub_breadcrumb!(bc)
    if bc.respond_to?(:message=) && bc.message.is_a?(String)
      bc.message = scrub_string(bc.message)
    end
    if bc.respond_to?(:data) && bc.data.is_a?(Hash)
      scrub_deep!(bc.data)
    end
    bc
  end
end

return unless ENV["CLIENT_MODE"] == "1"
return if ENV["CLIENT_SENTRY_DSN"].to_s.strip.empty?

Sentry.init do |config|
  config.dsn = ENV["CLIENT_SENTRY_DSN"]
  config.environment = "client-production"
  config.enabled_environments = %w[ client-production ]
  config.release = (File.read(Rails.root.join("VERSION")).strip rescue nil)

  config.send_default_pii = false
  config.include_local_variables = false
  config.send_modules = false

  config.breadcrumbs_logger = []
  config.max_breadcrumbs = 50
  config.traces_sample_rate = 0
  config.profiles_sample_rate = 0

  # Synchronous transport: capture_exception blocks on HTTP send. Sidesteps
  # the shutdown-flush question in a short-lived rake process. Error rate is
  # low (at most a handful per run), so the added latency is acceptable.
  config.background_worker_threads = 0

  config.before_send      = ->(event, _hint) { ClientSentryScrubber.scrub_event!(event) }
  config.before_breadcrumb = ->(bc, _hint) { ClientSentryScrubber.scrub_breadcrumb!(bc) }
end
