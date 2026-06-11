# Free-function wrappers for the two non-merge rake callers (project filter
# at :44, since filter at :93). The merge block calls AnalyzeLocalMerge
# directly via the autoloaded module.
require_relative "../analyze_local_merge"

def mirror_tree_with_symlinks(source, target)
  AnalyzeLocalMerge.mirror_tree_with_symlinks(source, target)
end

namespace :client do
  desc "Run client-side analysis pipeline on local transcripts"
  task analyze: :environment do
    # Flush stdout/stderr immediately — critical for Docker pipe streaming
    $stdout.sync = true
    $stderr.sync = true

    # Suppress noisy Rails logger — only pipeline output matters
    Rails.logger.level = :error

    transcript_dir = ENV["TRANSCRIPT_DIR"] || File.expand_path("~/.claude/projects")
    token = ENV["YC_TOKEN"]
    results_endpoint = ENV["YC_RESULTS_ENDPOINT"]
    project_filter = ENV["PROJECT_NAME"]
    since_epoch = ENV["SINCE_EPOCH"]&.to_i

    unless Dir.exist?(transcript_dir)
      abort "Transcript directory not found: #{transcript_dir}\nSet TRANSCRIPT_DIR to override."
    end

    # Apply --project filter: mirror only matching project subdirectories
    # into a temp dir (transcripts mount is read-only, can't delete).
    # Uses real dirs + file symlinks because Dir.glob("**/*") won't follow directory symlinks.
    #
    # Skip when the host already filtered (CLAUDE_MOUNT_SCOPE=filtered): the host
    # has git-remote info we don't, so its filter is strictly more accurate than
    # our substring fallback, and re-filtering only risks dropping the sidecar.
    host_already_filtered = ENV["CLAUDE_MOUNT_SCOPE"] == "filtered"

    if project_filter.present? && project_filter != "all" && !host_already_filtered
      normalized_filter = project_filter.downcase.tr("-_", "-")
      matching_dirs = Dir.glob(File.join(transcript_dir, "*")).select do |d|
        next unless File.directory?(d)
        normalized_basename = File.basename(d).downcase.tr("-_", "-")
        normalized_basename.include?(normalized_filter)
      end

      if matching_dirs.empty?
        abort "No project matching '#{project_filter}' found in #{transcript_dir}"
      end
      filtered_dir = File.join(Dir.tmpdir, "paxel-filtered-#{SecureRandom.hex(4)}")
      FileUtils.mkdir_p(filtered_dir)
      matching_dirs.each { |d| mirror_tree_with_symlinks(d, File.join(filtered_dir, File.basename(d))) }

      # Preserve the sidecar so TranscriptDiscoverer can resolve git_remote per
      # workspace dir. Without it, every Conductor worktree of the same repo
      # becomes its own Project (one per encoded_name instead of one per remote),
      # scattering what should be a single project across many rows.
      # Copy rather than symlink — dereferencing chains through multiple tmp
      # dirs (--project then --since) has been fragile in practice.
      sidecar_src = File.join(transcript_dir, "_metadata.json")
      FileUtils.cp(sidecar_src, File.join(filtered_dir, "_metadata.json")) if File.exist?(sidecar_src)

      transcript_dir = filtered_dir
    end

    # Apply --since filter: symlink only recent JSONL files into a temp dir
    # (transcripts mount is read-only, can't delete old files)
    if since_epoch.present? && since_epoch > 0
      since_time = Time.at(since_epoch)
      filtered_dir = File.join(Dir.tmpdir, "paxel-since-#{SecureRandom.hex(4)}")
      FileUtils.mkdir_p(filtered_dir) # ensure it exists even when the source dir is empty (PAXEL-CLIENT-18)
      # Preserve directory structure with symlinks to recent files only
      Dir.glob(File.join(transcript_dir, "**", "*")).each do |f|
        relative = f.sub("#{transcript_dir}/", "")
        target = File.join(filtered_dir, relative)
        if File.directory?(f)
          FileUtils.mkdir_p(target)
        elsif f.end_with?(".jsonl")
          # Dir.glob matches dangling symlinks by name without statting them, so
          # File.mtime here can raise ENOENT — and this loop runs before logging
          # or Sentry context exists, so one stale link in ~/.claude killed the
          # whole --since run with a raw rake abort. Same class as
          # PAXEL-CLIENT-14 (#1060 guarded the discoverer's stat loops; this
          # filter predates that). A dangling link has no content: skip it.
          mtime = begin
            File.mtime(f)
          rescue SystemCallError
            nil
          end
          next if mtime.nil? || mtime < since_time
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.ln_s(f, target)
        else
          # Copy non-JSONL files (sessions-index.json, _metadata.json)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.ln_s(f, target)
        end
      end
      transcript_dir = filtered_dir
    end

    # Merge external-agent session mounts (Cursor at /cursor_sessions, Codex
    # at /codex_sessions — the latter restored post PR #604 gap, opencode at
    # /opencode_sessions, Gemini CLI at /gemini_sessions) into transcript_dir.
    # Delegated to AnalyzeLocalMerge so the logic has direct rspec coverage instead
    # of inline-duplicated test bodies.
    transcript_dir = AnalyzeLocalMerge.merge_agent_sessions!(
      transcript_dir,
      [
        [ ENV["CURSOR_SESSIONS_DIR"] || "/cursor_sessions", "_cursor_*" ],
        [ ENV["CODEX_SESSIONS_DIR"] || "/codex_sessions", "_codex_*" ],
        [ ENV["OPENCODE_SESSIONS_DIR"] || "/opencode_sessions", "_opencode_*" ],
        [ ENV["GEMINI_SESSIONS_DIR"] || "/gemini_sessions", "_gemini_*" ]
      ]
    )

    # Detect dev mode: localhost URLs mean we're running against a local server
    dev_mode = ENV.fetch("PAXEL_VERBOSE", "0") == "1" ||
      results_endpoint&.match?(/localhost|127\.0\.0\.1|host\.docker\.internal/)

    # Set up dual logging: stdout + file
    log_dir = ENV.fetch("PAXEL_LOG_DIR", "/logs")
    # /logs is a host-owned 0700 bind mount; when the host uid != the container's
    # uid 1000 (native Linux / CI / cloud / root-owned $HOME) it EXISTS but is not
    # writable by uid 1000. Guard on writability, not just existence, and fall back
    # to Rails.root/tmp (the image creates it writable for uid 1000) so an
    # unwritable log dir never aborts the whole upload (PAXEL-CLIENT-Y).
    log_dir = Rails.root.join("tmp").to_s unless Dir.exist?(log_dir) && File.writable?(log_dir)
    # Per-repo label for the log filename so a multi-repo run produces one
    # identifiable log per repo (e.g. myrepo-<ts>.log) instead of every repo writing
    # all-<ts>.log. PAXEL_LOG_LABEL is set per-repo by the host (MOUNT_LABEL in
    # prepare_and_run_for_repo); fall back to --project, then "all". Sanitized to a
    # filename-safe token.
    log_label = ENV["PAXEL_LOG_LABEL"].to_s.strip
    log_label = ENV.fetch("PROJECT_NAME", "all") if log_label.empty?
    log_label = log_label.gsub(/[^A-Za-z0-9._-]/, "_")
    timestamp = Time.current.strftime("%Y%m%d-%H%M%S")
    log_path = File.join(log_dir, "#{log_label}-#{timestamp}.log")
    log_file =
      begin
        File.open(log_path, "w")
      rescue SystemCallError
        # Belt-and-suspenders for the TOCTOU gap left by the writable? check above
        # (and read-only mounts, which raise here regardless): retry into
        # Rails.root/tmp, always writable for uid 1000 (PAXEL-CLIENT-Y).
        log_path = File.join(Rails.root.join("tmp").to_s, File.basename(log_path))
        File.open(log_path, "w")
      end
    log_file.sync = true

    require_relative "../pipeline_logger"
    log = PipelineLogger.new(log_file)

    begin
      task_start = Time.current

      # Initialize LLM result cache (persistent across Docker runs via host mount)
      LlmResultCache.setup!
      LlmResultCache.cleanup!(max_age_days: 30)

      proxy_label = ENV["YC_LLM_PROXY_URL"].present? ? "via proxy" : "direct"

      log.call "═" * 60
      log.call "▶ PAXEL CLIENT PIPELINE"
      log.call "  Transcripts: #{transcript_dir}"
      log.call "  Proxy:       #{ENV['YC_LLM_PROXY_URL'] || '(direct Anthropic)'}"
      log.call "  Cloud:       #{AnthropicClient::MODELS[:quality]} (narratives) + #{AnthropicClient::MODELS[:fast]} (episodes, decisions) (#{proxy_label})"
      log.call "  Upload:      #{results_endpoint || '(local only)'}"
      log.call "  Log file:    #{log_path}"
      log.call "  Mode:        #{dev_mode ? 'VERBOSE (dev)' : 'standard'}"
      if LlmResultCache.available?
        cache_size = File.size(LlmResultCache::CACHE_DB_PATH) rescue 0
        if cache_size > 1024
          log.call "  Cache:       #{(cache_size / 1024.0).round(1)}KB"
        else
          log.call "  Cache:       empty (new)"
        end
      else
        log.call "  Cache:       unavailable"
      end
      log.call "═" * 60

      # Loudly surface a non-functional cache. It's best-effort and won't crash
      # the run, but a silent miss means full re-spend every run and a large
      # history can exhaust the daily cost cap before finishing (zero output).
      # Also emits one PII-free Sentry warning so the fleet impact is visible.
      LlmResultCache.warn_if_unavailable!(logger: log)

      pipeline = ClientPipeline.new(
        transcript_dir: transcript_dir,
        results_endpoint: results_endpoint,
        token: token,
        logger: log,
        verbose: dev_mode
      )

      pipeline.run!

      # Write results JSON locally for inspection
      output_path = Rails.root.join("tmp", "client_results_#{pipeline.upload.slug}.json")
      File.write(output_path, JSON.pretty_generate(pipeline.results))

      total_duration = (Time.current - task_start).round(1)
      mins = (total_duration / 60).to_i
      secs = (total_duration % 60).round(0)
      human_duration = mins > 0 ? "#{mins}m #{secs}s" : "#{secs}s"
      log.call "═" * 60
      log.call "✓ PIPELINE COMPLETE (#{human_duration})"
      log.call "  Results: #{output_path}"
      log.call "═" * 60

      $stderr.print "\a" # terminal bell — tab flashes when run finishes
      $stderr.flush

      # Analysis finished but the upload to the server failed (non-fatal). Exit a
      # distinct code so the host script shows an honest message instead of "Upload
      # complete!" (PAXEL: a failed upload used to still print "complete" with nothing
      # at /reports): EXIT_UPLOAD_DEFERRED when it was stashed for auto-replay,
      # EXIT_UPLOAD_FAILED when there's no replay artifact and the user must re-run.
      # SystemExit skips the rescue below and still runs `ensure` (log/Sentry flush).
      exit ClientPipeline::EXIT_UPLOAD_DEFERRED if pipeline.upload_deferred
      exit ClientPipeline::EXIT_UPLOAD_FAILED if pipeline.upload_failed
    rescue ClientPipeline::NoAnalyzableSessions
      # Benign, expected outcome — the project had sessions but they were all
      # too short to analyze. NOT a failure: no Sentry capture (ClientPipeline#run!
      # already suppressed it) and no "email support" banner. Exit with a distinct
      # code so the host upload script shows a friendly "skipping" line and, in
      # `--all` mode, continues to the next repo. The `ensure` below still runs
      # (SystemExit triggers it) so the log + Sentry are flushed/closed.
      log.call ""
      log.call "No analyzable sessions found — the sessions in this project were too short to analyze."
      log.call "Nothing was uploaded. Try a project with longer Claude Code / Codex / Cursor sessions."
      exit ClientPipeline::EXIT_NO_ANALYZABLE_SESSIONS
    rescue => e
      # Dig out the underlying PaxelLlmError so the user sees concrete
      # remediation (user_action + request_id) instead of a wall of stack.
      # Source of the error, in precedence order:
      #   1. The raised exception itself (when a Fatal propagates past the
      #      circuit breaker — e.g. from EpisodeSummarizer or DecisionClassifier).
      #   2. ClientPipeline::PipelineCircuitBroken#original_error (narrative
      #      path — see client_pipeline.rb:analyze_sessions).
      #   3. Ruby's native `.cause` chain (defense in depth).
      llm_err =
        if defined?(PaxelLlmError) && e.is_a?(PaxelLlmError::Base)
          e
        elsif e.respond_to?(:original_error) && e.original_error.is_a?(defined?(PaxelLlmError) ? PaxelLlmError::Base : NilClass)
          e.original_error
        elsif defined?(PaxelLlmError) && e.cause.is_a?(PaxelLlmError::Base)
          e.cause
        end

      if defined?(Sentry) && Sentry.initialized?
        tags = { stage: "client_fatal_rake" }
        tags[:upload_slug] = pipeline.upload.slug if pipeline&.upload&.slug
        tags[:session_id] = e.session_id if e.respond_to?(:session_id) && e.session_id
        extra = {}
        # Mirror client_pipeline's diagnostic split: content_type + presence
        # boolean as low-cardinality tags, full scrubbed body text as extra.
        # Don't rely on sentry-ruby dedup — either capture may arrive first
        # depending on where the exception was rescued.
        if llm_err
          tags[:response_content_type] = llm_err.response_content_type if llm_err.response_content_type
          tags[:body_preview_present] = llm_err.body_preview ? "1" : "0"
          extra[:response_body_preview] = llm_err.body_preview if llm_err.body_preview
        end
        Sentry.capture_exception(e, tags: tags, extra: extra)
      end
      log.call "✗ FATAL: #{e.class}: #{SecretScrubber.scrub(e.message.to_s)}"
      log.call e.backtrace.first(5).join("\n")

      if llm_err
        rid = llm_err.request_id || "n/a"
        action = llm_err.user_action || PaxelLlmError::Base.default_user_action(rid)
        border = "─" * 61
        log.call border
        log.call "What happened: #{llm_err.message.to_s.truncate(180)}"
        log.call "What to do:    #{action}"
        # Response body only when present; no truncate — body_preview is
        # already capped at BODY_PREVIEW_LIMIT (500 chars) and scrubbed via
        # PaxelLlmError::Base.scrub. The user asked to see it; don't hide it.
        log.call "Response body: #{llm_err.body_preview}" if llm_err.body_preview
        log.call "Request id:    #{rid}   (include when emailing support)"
        log.call border
      end

      raise
    ensure
      # Wipe the live progress footer (TTY runs) so the completion banner /
      # error output / shell prompt lands on a clean line. No-op otherwise.
      log.clear_footer if log.respond_to?(:clear_footer)
      log_file.close
      # Sentry.close is a no-op with background_worker_threads=0 (sync transport).
      # Call defensively so a future config flip to async still flushes on exit.
      begin
        Sentry.close if defined?(Sentry) && Sentry.initialized?
      rescue StandardError
        # Never let Sentry shutdown raise — log is already closed, process exiting.
      end
    end
  end
end
