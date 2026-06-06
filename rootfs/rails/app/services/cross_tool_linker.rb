# Cross-tool session linker. Detects when a Codex session was launched from
# Claude Code (or other launcher) and links it to the specific parent Claude
# session that dispatched it.
#
# Runs as Pass 2 in TranscriptDiscoverer#discover! AFTER all per-project_dir
# Pass 1 calls have completed. Iterates by Project (not project_dir) so cross-
# project_dir linking works — Codex sessions live in `_codex_<bucket>` dirs
# while Claude sessions live in `<workspace_encoded>` dirs, but both collapse
# onto the same Project via find_or_create_by!(git_remote:).
#
# Server-side soft no-op: when raw JSONL paths aren't available (the path map
# is empty), every read short-circuits and the linker silently leaves columns
# null. This handles the harness/admin ProcessUploadJob path where archives
# may have been deleted, and the future ResultsController path where there
# was never raw JSONL on the server.
#
# See docs/designs/CROSS_TOOL_SESSION_LINKING.md for the full design.
class CrossToolLinker
  CROSS_TOOL_DISPATCH_WINDOW_S = 300   # 5 min — covers ~98% of local-ground-truth pairs (findings doc §3)
  CROSS_TOOL_POST_START_GRACE_S = 5    # tiny clock-skew tolerance after Codex start

  # Match real codex launches at executable position. The node-launch pattern
  # uses \S+ for the script path because real-world invocations reference the
  # codex-companion path through a variable (CODEX_SCRIPT="..." && node
  # "$CODEX_SCRIPT" task ...) rather than inline. We disambiguate by requiring
  # the SUBSTRING "codex-companion" to appear elsewhere in the same command —
  # see #codex_launch? below. The bare-codex branch is kept for the rare
  # `codex review` direct invocation.
  #
  # See spec/services/cross_tool_linker_spec.rb for the required corpus.
  NODE_LAUNCH_REGEX = /
    (?:\A|[\n;(|{]|&&|\|\|)          # logical command start
    \s*
    (?:[A-Z_][A-Z0-9_]*=\S+\s+)*     # optional env var prefix(es): VAR=val ...
    (?!\#)                            # not a comment line
    node\b\s+\S+\s+(?:review|task|task-resume|task-resume-candidate|exec)\b
  /mx

  BARE_CODEX_LAUNCH_REGEX = /
    (?:\A|[\n;(|{]|&&|\|\|)
    \s*
    (?:[A-Z_][A-Z0-9_]*=\S+\s+)*
    (?!\#)
    codex\b\s+(?:review|task-resume)\b   # excludes ambiguous `codex task <ID>` (status check vs launch)
  /mx

  # True for commands that launch codex via codex-companion or directly.
  # Combines a path-shape regex with a substring guard to avoid matching
  # `node my_script.js task` (no codex-companion in the command).
  def self.codex_launch?(command)
    return false if command.empty?
    if command.include?("codex-companion")
      NODE_LAUNCH_REGEX.match?(command)
    else
      BARE_CODEX_LAUNCH_REGEX.match?(command)
    end
  end

  # Kept as the public-facing constant for backwards-compat in tests; combines
  # both branches via codex_launch? for the substring guard.
  LAUNCH_REGEX = Regexp.union(NODE_LAUNCH_REGEX, BARE_CODEX_LAUNCH_REGEX).freeze

  # Standalone Codex originator values — sessions the user launched directly
  # (CLI `codex`, or the Codex Desktop GUI), NOT cross-tool dispatch. Returns
  # nil from detect_cross_tool_origin so the linker leaves cross_tool_origin
  # null. "Codex Desktop" is the Electron desktop app (verified 2026-06-03,
  # docs/designs/SESSION_DETECTION.md §3b): it writes to the same
  # ~/.codex/sessions tree as the CLI and is user-initiated, so it belongs here
  # rather than in the KNOWN_LAUNCHERS "unknown" forward-compat bucket.
  #
  # SYNC NOTE: app/views/home/upload_script.text.erb#codex_originator_is_standalone
  # deliberately does NOT mirror this allowlist verbatim. The picker buckets
  # only "Claude Code" originator as cross-tool because CrossToolLinker only
  # assigns triggered_by_id for Claude-origin parents (#link_for_project, line
  # 113-127). Cursor / unknown / future-launcher Codex sessions get
  # cross_tool_origin tagged here but stay as logical_roots server-side, so
  # the picker counts them as sessions (not subagents) to match scoring
  # semantics + avoid the zero-abort path on Cursor-only Codex users. v0.92
  # flat format (`originator: "codex_cli"`) is treated as standalone too —
  # the cross-tool detector at #detect_cross_tool_origin (line 164) skips it
  # via the `type == "session_meta"` gate, so it never gets a cross_tool_origin.
  # Plain array, not %w[] — "Codex Desktop" contains a space.
  STANDALONE_ORIGINATORS = [ "codex_cli_rs", "codex_exec", "codex-tui", "Codex Desktop" ].freeze

  # Map known cross-tool launching tools to canonical cross_tool_origin slugs.
  # Anything not in this map (and not in STANDALONE_ORIGINATORS) is logged and
  # tagged "unknown" — forward-compat for future launchers (VS Code, etc.)
  # without silently dropping signal.
  KNOWN_LAUNCHERS = {
    "Claude Code" => "claude_code",
    "Cursor"      => "cursor"
  }.freeze

  attr_reader :upload, :jsonl_paths_by_session_id

  # @param upload [Upload]
  # @param jsonl_paths_by_session_id [Hash{String=>String}] map from
  #   TranscriptSession#id (uuid) to absolute jsonl path. Built during
  #   TranscriptDiscoverer Pass 1 where Dir.glob already had the path.
  def initialize(upload, jsonl_paths_by_session_id)
    @upload = upload
    @jsonl_paths_by_session_id = jsonl_paths_by_session_id || {}
  end

  def link!
    upload.projects.includes(:transcript_sessions).each do |project|
      link_for_project(project)
    end
  end

  private

  def link_for_project(project)
    main_sessions = project.transcript_sessions.where(is_subagent: false).to_a
    main_sessions_by_id = main_sessions.index_by(&:id)
    project_remote = Repository.normalize_remote(project.git_remote)

    # Build dispatch index from Claude main sessions only. Group by
    # claude_session.id so 1:N (one Claude → many dispatch events) collapses
    # to a single parent candidate during confidence assignment.
    claude_dispatches_by_session = main_sessions
      .select { |s| s.agent_type == "claude_code" }
      .each_with_object({}) do |s, acc|
        path = jsonl_paths_by_session_id[s.id]
        next unless path && File.file?(path)   # null-safe + server-side soft skip
        events = extract_codex_dispatches(path)
        acc[s.id] = events if events.any?
      end

    main_sessions.select { |s| s.agent_type == "codex_cli" }.each do |codex|
      path = jsonl_paths_by_session_id[codex.id]
      next unless path && File.file?(path)
      origin = detect_cross_tool_origin(path)
      next unless origin   # nil = standalone or non-Codex JSONL

      codex.cross_tool_origin = origin[:origin]

      # Non-Claude launchers (origin "unknown" / "cursor"): record origin only;
      # no claude_dispatches data path for them in v1.
      unless origin[:origin] == "claude_code"
        codex.triggered_by_confidence = "low"
        codex.save!
        next
      end

      # Defensive: project_remote should already match origin[:git_repo] post
      # Pass 1 (sidecar bucketing), but cross-check anyway.
      next unless project_remote == origin[:git_repo]

      # Build candidate tuples: { parent:, matching_events: }. The cwd-arg
      # tiebreaker in pick_by_cwd_then_recency needs the matching events,
      # not just the parent session.
      candidates = claude_dispatches_by_session.each_with_object([]) do |(claude_id, events), acc|
        claude = main_sessions_by_id[claude_id]
        next unless claude
        in_window = events.select do |e|
          dt = e[:at] - origin[:started_at]
          dt <= CROSS_TOOL_POST_START_GRACE_S && dt >= -CROSS_TOOL_DISPATCH_WINDOW_S
        end
        acc << { parent: claude, matching_events: in_window } if in_window.any?
      end

      # Confidence by UNIQUE PARENT count, not dispatch-event count.
      case candidates.size
      when 0
        codex.triggered_by_confidence = "low"
      when 1
        codex.triggered_by = candidates.first[:parent]
        codex.triggered_by_confidence = "high"
      else
        codex.triggered_by = pick_by_cwd_then_recency(candidates, origin)
        codex.triggered_by_confidence = "medium"
      end
      codex.save!
    end
  end

  # Reads the first JSONL line of a Codex session and identifies the launching
  # tool. Returns nil for standalone sessions (codex_cli_rs / codex_exec /
  # codex-tui) so the linker doesn't tag them with cross_tool_origin.
  def detect_cross_tool_origin(codex_jsonl_path)
    first = read_first_jsonl_line(codex_jsonl_path)
    return nil unless first.is_a?(Hash) && first["type"] == "session_meta"

    payload = first["payload"] || {}
    originator = payload["originator"].to_s
    return nil if originator.empty?
    return nil if STANDALONE_ORIGINATORS.include?(originator)

    origin_slug = KNOWN_LAUNCHERS[originator] || "unknown"
    if origin_slug == "unknown"
      Rails.logger.info("[cross_tool] unknown launcher: #{originator.inspect}")
    end

    started_at = parse_ts(payload["timestamp"])
    return nil unless started_at

    {
      origin: origin_slug,
      cwd: payload["cwd"],
      git_repo: Repository.normalize_remote(payload.dig("git", "repository_url")),
      started_at: started_at,
      cli_version: payload["cli_version"]
    }
  end

  # Streaming JSONL read — extract Bash tool_use events whose command string
  # matches LAUNCH_REGEX. cmd_excerpt capped at 500 chars (enough for the
  # --cwd argument tiebreaker but bounded for memory).
  def extract_codex_dispatches(claude_jsonl_path)
    dispatches = []
    File.foreach(claude_jsonl_path) do |line|
      obj = JSON.parse(line) rescue nil
      next unless obj.is_a?(Hash)   # JSON.parse returns bare scalars (e.g. a quoted string line); skip non-objects
      content = obj.dig("message", "content")
      next unless content.is_a?(Array)
      content.each do |block|
        next unless block.is_a?(Hash) && block["type"] == "tool_use" && block["name"] == "Bash"
        cmd = block.dig("input", "command").to_s
        next unless self.class.codex_launch?(cmd)
        ts = parse_ts(obj["timestamp"])
        next unless ts
        dispatches << { at: ts, cmd_excerpt: cmd[0, 500] }
      end
    end
    dispatches
  rescue Errno::EACCES, Errno::ENOENT, IOError => e
    # An unreadable or vanished transcript file (e.g. a bind-mounted path the
    # container can't read) must not sink the whole upload (client_pipeline_fatal).
    # Skip it; mirrors read_first_jsonl_line. (PAXEL-CLIENT-1C)
    Rails.logger.warn("[CrossToolLinker] skipped unreadable #{claude_jsonl_path}: #{e.class}: #{e.message}")
    dispatches
  end

  # Tiebreaker for multi-candidate medium-confidence cases. Parses --cwd from
  # each candidate's matching dispatch events; prefers the parent whose
  # dispatch's --cwd matches Codex's payload.cwd. Falls back to the candidate
  # with the most recent dispatch before T_codex.
  #
  # @param candidates [Array<{parent:, matching_events:}>]
  # @param origin    [Hash] from detect_cross_tool_origin
  # @return [TranscriptSession] parent
  def pick_by_cwd_then_recency(candidates, origin)
    target_cwd = origin[:cwd].to_s

    if target_cwd.present?
      cwd_match = candidates.find do |c|
        c[:matching_events].any? { |e| parse_cwd_arg(e[:cmd_excerpt]) == target_cwd }
      end
      return cwd_match[:parent] if cwd_match
    end

    # Fallback: most-recent dispatch before T_codex.
    candidates.max_by { |c|
      c[:matching_events].map { |e| e[:at] }.max
    }[:parent]
  end

  # Best-effort parse of a `--cwd <path>` argument from a bash command. Handles
  # `--cwd /path`, `--cwd=/path`, `--cwd "/path with spaces"`, `--cwd '/path'`.
  def parse_cwd_arg(cmd)
    m = cmd.match(/--cwd[\s=]+(?:"([^"]+)"|'([^']+)'|(\S+))/)
    return nil unless m
    m[1] || m[2] || m[3]
  end

  def read_first_jsonl_line(path)
    File.foreach(path) do |line|
      stripped = line.scrub.strip
      next if stripped.empty?
      return JSON.parse(stripped)
    end
    nil
  rescue JSON::ParserError, Errno::EACCES, Errno::ENOENT, IOError
    nil
  end

  def parse_ts(value)
    return nil if value.blank?
    Time.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
