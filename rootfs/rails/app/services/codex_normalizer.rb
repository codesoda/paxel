# Converts Codex CLI JSONL transcripts to Claude Code canonical format.
#
# Codex JSONL structure:
#   { "timestamp": "ISO8601", "type": "session_meta"|"event_msg"|"response_item",
#     "payload": { "type": "user_message"|"agent_message"|"function_call"|... } }
#
# Older versions (v0.92) omit the type/payload wrapper; entries are raw objects.
#
# Entry flow:
#   session_meta        → skip (extract metadata)
#   user_message        → canonical user
#   agent_message       → canonical assistant
#   function_call       → tool_use Bash
#   function_call_output→ tool_result
#   reasoning           → thinking (from summary, skip encrypted)
#   agent_reasoning     → thinking
#   message role:user   → user (if real content, skip system/permissions)
#   message role:developer → skip
#   token_count, task_started, task_complete, turn_aborted, web_search_call → skip
#
class CodexNormalizer
  include BaseNormalizer

  # System message patterns to filter out. These mark agent/tool boilerplate that
  # Codex (and the codex-companion harness) inject as user-role turns; counting them
  # as user prompts inflates avg_prompt_length_words / substantive_ratio — the
  # safety-classifier block alone runs ~3,900 words (audit CL28). The classifier
  # phrase is long/specific enough for a substring match; both anchors are verbatim
  # from real prod transcripts.
  SYSTEM_PATTERNS = [
    "<permissions instructions>",
    "<environment_context>",
    "AGENTS.md instructions",
    "<skills_instructions>",
    "<turn_aborted>",
    "Filesystem sandboxing",
    "sandbox_mode",
    "The following is the Codex agent history whose request action you are assessing"
  ].freeze

  # The agent preamble always BEGINS the injected message, so match it start-anchored
  # rather than as a substring — otherwise a legit user prompt that merely QUOTES the
  # phrase (e.g. "change the line that says 'You are Codex, a coding agent…'") would be
  # dropped, distorting the very prompt metrics CL28 fixes, in the opposite direction.
  CODEX_PREAMBLE_ANCHOR = "You are Codex, a coding agent"

  # apply_patch envelope markers. Codex wraps file edits in a `shell` function_call
  # whose arguments are { "command": [ "apply_patch", "*** Begin Patch\n…" ] } —
  # the patch text is element 1+ of the command array (see SESSION_DETECTION.md §3).
  # Each "*** Add/Update/Delete File: <path>" line names one file (and a rename adds
  # "*** Move to: <dest>"); one envelope can touch several. Anchored to start-of-line
  # ($ is a line anchor in Ruby by default, so #scan walks every marker line).
  PATCH_BEGIN_MARKER = "*** Begin Patch"
  PATCH_FILE_MARKER = /^\*\*\* (Add File|Update File|Delete File|Move to): (.+)$/

  # Synthetic plan path for Codex's `update_plan` tool. Codex plans are structured
  # (a steps array), not a file write, so plan detection — which keys entirely off
  # file_create/file_edit events at EventExtractor::PLAN_PATH_PATTERN paths — was
  # blind to them, making every codex session read as "0 plans" (audit finding #5).
  # Mapping update_plan to a Write at this path lights up the SAME path-based plan
  # machinery (session_touched_plan_file? + plan_signal_observable?). The basename
  # matches PLAN_PATH_PATTERN's SCREAMING_CASE *_PLAN.md branch.
  PLAN_SIGNAL_PATH = "CODEX_PLAN.md"

  SKIP_TYPES = %w[
    session_meta token_count task_started task_complete
    turn_aborted web_search_call unknown
  ].freeze

  def normalize(metadata: {})
    entries = []
    skipped = 0
    counts = Hash.new(0)

    # encoding: "UTF-8" so `.scrub` cleans invalid bytes — the client Docker image
    # has no locale (default_external = ASCII-8BIT), under which scrub is a no-op and
    # invalid bytes crash a later String op (PAXEL-CLIENT-1G).
    File.foreach(jsonl_path, encoding: "UTF-8") do |line|
      line = line.scrub.strip
      next if line.empty?

      begin
        raw = JSON.parse(line)
      rescue JSON::ParserError
        skipped += 1
        next
      end

      # A syntactically valid JSON line can still be a bare scalar (string,
      # number, array) rather than an object. Calling Hash methods on it
      # (raw["timestamp"], extract_payload's raw.key?) would raise — skip it.
      # PAXEL-CLIENT-12.
      unless raw.is_a?(Hash)
        skipped += 1
        next
      end

      timestamp = raw["timestamp"]

      # Detect format: wrapped (v0.115+) vs raw (v0.92)
      payload = extract_payload(raw)
      next unless payload

      payload_type = payload["type"].to_s

      # Extract metadata from session_meta
      if payload_type == "session_meta" || raw["type"] == "session_meta"
        extract_metadata(payload, metadata)
        next
      end

      # Extract model from turn_context
      if payload.key?("model") && payload.key?("approval_policy")
        metadata[:model] ||= payload["model"]
        next
      end

      next if SKIP_TYPES.include?(payload_type)

      canonical = convert_entry(payload, timestamp)
      if canonical
        entries << canonical
        counts[canonical["type"]] += 1
      else
        skipped += 1
      end
    end

    metadata[:agent_type] = "codex_cli"

    Rails.logger.info(
      "CodexNormalizer: session=#{metadata[:session_id]} " \
      "entries=#{entries.size} skipped=#{skipped} " \
      "user=#{counts['user']} assistant=#{counts['assistant']}"
    )

    entries
  rescue SystemCallError, IOError, ArgumentError => e
    # One unreadable/oddly-encoded transcript file must not sink the whole upload
    # (e.g. File.foreach raising ArgumentError "negative string size" on a bad path
    # encoding) — PAXEL-CLIENT-19. Keep what parsed so far + the agent_type so
    # downstream detection still works.
    Rails.logger.warn("[CodexNormalizer] unreadable transcript #{jsonl_path}: #{e.class}: #{e.message}")
    metadata[:agent_type] = "codex_cli"
    entries
  end

  private

  def extract_payload(raw)
    if raw.key?("payload")
      raw["payload"]
    elsif raw.key?("type") && raw.key?("timestamp")
      # Wrapped entry without explicit payload (the entry IS the payload for some types)
      raw
    elsif raw.key?("originator") || raw.key?("id") && raw.key?("cwd")
      # Raw session_meta (old format)
      { "type" => "session_meta" }.merge(raw)
    elsif raw.key?("approval_policy") || raw.key?("model")
      # Turn context (old format)
      raw
    else
      raw
    end
  end

  def extract_metadata(payload, metadata)
    meta = payload.is_a?(Hash) ? payload : {}
    metadata[:session_id] ||= meta["id"]
    metadata[:cwd] ||= meta["cwd"]
    metadata[:model] ||= meta["model_provider"]

    git = meta["git"] || {}
    metadata[:git_branch] ||= git["branch"]
    metadata[:git_remote] ||= git["repository_url"]
  end

  def convert_entry(payload, timestamp)
    case payload["type"]
    when "user_message"
      convert_user_message(payload, timestamp)
    when "agent_message"
      convert_agent_message(payload, timestamp)
    when "function_call"
      convert_function_call(payload, timestamp)
    when "function_call_output"
      convert_function_call_output(payload, timestamp)
    when "reasoning"
      convert_reasoning(payload, timestamp)
    when "agent_reasoning"
      convert_agent_reasoning(payload, timestamp)
    when "message"
      convert_message(payload, timestamp)
    end
  rescue => e
    Rails.logger.warn("CodexNormalizer: failed to convert entry type=#{payload['type']}: #{e.message}")
    nil
  end

  def convert_user_message(payload, timestamp)
    text = payload["message"].to_s
    return nil if text.blank?
    # user_message payloads are NOT pre-filtered like role:user `message` entries
    # (convert_message). Drop injected agent/safety-classifier boilerplate here too
    # so it is never counted as a user prompt (audit CL28).
    return nil if system_content?(text)
    {
      "type" => "user",
      "message" => { "role" => "user", "content" => text },
      "timestamp" => timestamp
    }
  end

  def convert_agent_message(payload, timestamp)
    text = payload["message"].to_s
    return nil if text.blank?
    {
      "type" => "assistant",
      "message" => { "role" => "assistant", "content" => text },
      "timestamp" => timestamp
    }
  end

  def convert_function_call(payload, timestamp)
    name = payload["name"].to_s
    args_json = payload["arguments"].to_s

    begin
      args = JSON.parse(args_json)
    rescue JSON::ParserError
      args = {}
    end

    # apply_patch (file edits) and update_plan (structured plans) carry signals the
    # generic Bash flattening discards — file paths and plan-before-code (finding #5).
    # Detect + surface them before falling through to the Bash representation. If an
    # apply_patch envelope parses no file markers (empty/malformed), fall THROUGH to
    # Bash rather than dropping the entry (no silent data loss).
    patch_text = extract_patch_text(args)
    if patch_text
      apply_patch_entry = convert_apply_patch(patch_text, timestamp)
      return apply_patch_entry if apply_patch_entry
    end
    return convert_update_plan(args, timestamp) if name == "update_plan"

    # Extract command from exec_command or shell_command
    command = args["cmd"] || args["command"] || "[#{name}]"

    {
      "type" => "assistant",
      "message" => {
        "role" => "assistant",
        "content" => [
          {
            "type" => "tool_use",
            "name" => "Bash",
            "input" => { "command" => command.to_s }
          }
        ]
      },
      "timestamp" => timestamp
    }
  end

  # Returns the apply_patch envelope text if this function_call is a genuine
  # apply_patch invocation, else nil. The Codex contract is a command ARRAY whose
  # first element is the literal "apply_patch" (the patch text is element 1+). Gating
  # on command[0] — not merely on a "*** Begin Patch" substring — means a real shell
  # command that quotes/echoes the marker never misfires as a patch. Anything else
  # falls through to the Bash representation (no data loss).
  def extract_patch_text(args)
    cmd = args["cmd"] || args["command"]
    return nil unless cmd.is_a?(Array) && cmd.first.to_s == "apply_patch"
    patch = cmd[1..].find { |s| s.to_s.include?(PATCH_BEGIN_MARKER) } || cmd[1..].join("\n")
    patch.to_s if patch.to_s.include?(PATCH_BEGIN_MARKER)
  end

  # apply_patch → one Edit/Write tool_use per file in the envelope, so EventExtractor
  # emits file_edit/file_create events with real paths (lighting up plan detection +
  # test-after-edit). "Add File" → Write (file_create); "Update File"/"Delete File"/
  # "Move to" → Edit (file_edit) — a rename emits an edit for BOTH the source path and
  # the move destination, so the destination is never lost. Only the path is kept, not
  # the +/- diff body — that drops the patch's code from the upload payload (an
  # improvement over the Bash form, which shipped the whole diff). nil if no file
  # markers parse (an empty/malformed patch); the caller then falls through to Bash.
  def convert_apply_patch(patch_text, timestamp)
    blocks = patch_text.scan(PATCH_FILE_MARKER).map do |op, path|
      tool = op.start_with?("Add") ? "Write" : "Edit"
      { "type" => "tool_use", "name" => tool, "input" => { "file_path" => path.strip } }
    end
    return nil if blocks.empty?

    {
      "type" => "assistant",
      "message" => { "role" => "assistant", "content" => blocks },
      "timestamp" => timestamp
    }
  end

  # update_plan → a Write to the synthetic PLAN_SIGNAL_PATH carrying the rendered
  # plan, so the file_create event registers as a plan signal. file_create (not
  # file_edit) is deliberate: repeated update_plan calls must NOT count as code
  # edits in test-after-edit ratio (which keys off file_edit on non-test paths).
  def convert_update_plan(args, timestamp)
    plan = args["plan"]
    return nil unless plan.is_a?(Array) && plan.any?

    {
      "type" => "assistant",
      "message" => {
        "role" => "assistant",
        "content" => [
          {
            "type" => "tool_use",
            "name" => "Write",
            "input" => { "file_path" => PLAN_SIGNAL_PATH, "content" => render_plan(plan, args["explanation"]) }
          }
        ]
      },
      "timestamp" => timestamp
    }
  end

  def render_plan(plan, explanation)
    lines = plan.filter_map do |step|
      next unless step.is_a?(Hash)
      status = step["status"].to_s.presence || "pending"
      text = step["step"].to_s.strip
      "- [#{status}] #{text}" unless text.empty?
    end
    lines.unshift(explanation.to_s.strip) if explanation.to_s.strip.present?
    lines.join("\n")
  end

  def convert_function_call_output(payload, timestamp)
    output = payload["output"].to_s
    return nil if output.blank?
    {
      "type" => "user",
      "message" => {
        "role" => "user",
        "content" => [
          { "type" => "tool_result", "content" => output }
        ]
      },
      "timestamp" => timestamp
    }
  end

  def convert_reasoning(payload, timestamp)
    # Use summary text if available; skip if only encrypted
    summary = payload["summary"]
    text = if summary.is_a?(Array) && summary.any?
             summary.filter_map { |s| s["text"] if s.is_a?(Hash) }.join("\n")
    end

    return nil if text.blank?

    {
      "type" => "assistant",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "thinking", "thinking" => text }
        ]
      },
      "timestamp" => timestamp
    }
  end

  def convert_agent_reasoning(payload, timestamp)
    text = payload["text"].to_s
    return nil if text.blank?
    {
      "type" => "assistant",
      "message" => {
        "role" => "assistant",
        "content" => [
          { "type" => "thinking", "thinking" => text }
        ]
      },
      "timestamp" => timestamp
    }
  end

  def convert_message(payload, timestamp)
    role = payload["role"].to_s

    # Skip developer/system messages
    return nil if role == "developer"

    # Extract text from content
    content = payload["content"]
    text = case content
    when String
      content
    when Array
      content.filter_map { |block|
        block["text"] if block.is_a?(Hash) && %w[input_text text].include?(block["type"])
      }.join("\n")
    else
      ""
    end

    return nil if text.blank?

    # Filter system/permissions content injected as user messages
    return nil if system_content?(text)

    canonical_role = (role == "user") ? "user" : "assistant"
    {
      "type" => canonical_role,
      "message" => { "role" => canonical_role, "content" => text },
      "timestamp" => timestamp
    }
  end

  def system_content?(text)
    return true if text.lstrip.start_with?(CODEX_PREAMBLE_ANCHOR)
    SYSTEM_PATTERNS.any? { |pattern| text.include?(pattern) }
  end
end
