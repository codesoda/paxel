# Converts opencode (SQLite-backed AI coding agent) transcripts to Claude Code
# canonical format.
#
# opencode stores sessions in a SQLite DB (~/.local/share/opencode/opencode.db),
# not JSONL. The client upload script (extract_opencode_db in
# upload_script.text.erb) dumps each session to "opencode-native" JSONL:
#
#   line 1: {"type":"opencode_session_meta","id","title","first_prompt",
#            "directory","git_remote","model","agent","version"}
#   line N: {"type":"opencode_message","message":{<opencode message.data>},
#            "parts":[{"t":<part.time_created ms>,"p":{<opencode part.data>}}, ...]}
#
# Parts carry their DB `time_created` (the `t` key) and are sorted HERE, not in
# SQL — SQLite's `json_group_array(... ORDER BY ...)` does not reliably sort
# aggregate input across versions (verified on 3.51; the in-aggregate ORDER BY
# syntax only exists on 3.44+, and macOS pre-Sonoma ships 3.43).
#
# Conversion rules (one opencode message -> one canonical turn, NOT one per part,
# so message_count / models_used stay honest):
#   user text part            -> user entry (text block)
#   assistant text part       -> assistant entry (text block)
#   assistant reasoning part  -> assistant entry (thinking block)
#   assistant tool part       -> assistant entry (tool_use block, id=callID)
#                                + a following user entry (tool_result block,
#                                  tool_use_id=callID) from state.output/error
#   step-start/step-finish/snapshot/patch/file/agent/subtask/retry/compaction
#                             -> skip
#
# opencode tool ids are lowercase and inputs camelCase; both are remapped to the
# Claude canonical names/keys that EventExtractor + ToolInputSummarizer dispatch
# on (e.g. bash->Bash, edit filePath->file_path). Preserving callID as the
# tool_use `id` + tool_result `tool_use_id` is what lets EventExtractor pair
# subagent dispatch/return for opencode's `task` tool.
#
class OpencodeNormalizer
  include BaseNormalizer

  AGENT_TYPE = "opencode".freeze
  META_TYPE = "opencode_session_meta".freeze
  MESSAGE_TYPE = "opencode_message".freeze

  # opencode tool id -> Claude canonical tool name. Names not listed fall back to
  # a PascalCase form (so they still count as tools and render in chunks), but
  # only the mapped names trigger EventExtractor's file_edit / git_commit / test
  # / subagent signals + ToolInputSummarizer's safe per-tool summaries.
  TOOL_NAME_MAP = {
    "bash" => "Bash",
    "edit" => "Edit",
    "write" => "Write",
    "read" => "Read",
    "grep" => "Grep",
    "glob" => "Glob",
    "webfetch" => "WebFetch",
    "websearch" => "WebSearch",
    "todowrite" => "TodoWrite",
    "task" => "Task",
    "skill" => "Skill",
    # apply_patch's input is a unified-diff blob, not {file_path,...}, so mapping
    # it to Edit would NOT yield a file_edit event and would misreport it. Keep a
    # distinct name: it counts as a tool but is not treated as a file edit.
    "apply_patch" => "ApplyPatch"
  }.freeze

  # Per-(canonical)-tool input-key remap: opencode camelCase -> Claude snake_case.
  # Only keys that differ are listed; everything else passes through unchanged.
  INPUT_KEY_MAP = {
    "Edit" => { "filePath" => "file_path", "oldString" => "old_string", "newString" => "new_string", "replaceAll" => "replace_all" },
    "Write" => { "filePath" => "file_path" },
    "Read" => { "filePath" => "file_path" },
    "Grep" => { "include" => "glob" }
  }.freeze

  def normalize(metadata: {})
    metadata[:agent_type] = AGENT_TYPE
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

      case raw["type"]
      when META_TYPE
        extract_metadata(raw, metadata)
      when MESSAGE_TYPE
        produced = convert_message(raw)
        produced.each { |e| counts[e["type"]] += 1 }
        entries.concat(produced)
      else
        skipped += 1
      end
    rescue => e
      Rails.logger.warn("OpencodeNormalizer: failed to process line: #{e.message}")
      skipped += 1
    end

    log_summary(metadata, entries.size, skipped, counts)
    entries
  rescue SystemCallError, IOError, ArgumentError => e
    # The File.foreach call itself (not a single line) can raise on an unreadable
    # or oddly-encoded file/path (e.g. ArgumentError "negative string size") — that
    # escapes the per-line rescue above and would sink the whole upload
    # (PAXEL-CLIENT-19). Keep what parsed so far.
    Rails.logger.warn("[OpencodeNormalizer] unreadable transcript #{jsonl_path}: #{e.class}: #{e.message}")
    entries
  end

  private

  def extract_metadata(raw, metadata)
    metadata[:session_id] ||= raw["id"]
    metadata[:cwd] ||= raw["directory"]
    metadata[:git_remote] ||= raw["git_remote"]
    metadata[:model] ||= raw["model"]
  end

  # One opencode message -> [primary turn entry, (optional) user tool_result entry]
  def convert_message(raw)
    msg = raw["message"]
    return [] unless msg.is_a?(Hash)

    role = (msg["role"].to_s == "user") ? "user" : "assistant"
    timestamp = ms_to_iso8601(msg.dig("time", "created"))
    model = (role == "assistant") ? assistant_model(msg) : nil

    content_blocks = []
    tool_results = []

    sorted_parts(raw["parts"]).each do |part|
      case part["type"]
      when "text"
        text = clean(part["text"])
        content_blocks << { "type" => "text", "text" => text } if text.present?
      when "reasoning"
        next unless role == "assistant"
        text = clean(part["text"])
        content_blocks << { "type" => "thinking", "thinking" => text } if text.present?
      when "tool"
        next unless role == "assistant"
        block, result = convert_tool_part(part)
        content_blocks << block if block
        tool_results << result if result
        # step-start / step-finish / snapshot / patch / file / agent /
        # subtask / retry / compaction -> skip (control + not-yet-supported parts)
      end
    end

    out = []
    if content_blocks.any?
      entry = {
        "type" => role,
        "message" => { "role" => role, "content" => content_blocks },
        "timestamp" => timestamp
      }
      entry["model"] = model if model.present?
      out << entry
    end
    if tool_results.any?
      out << {
        "type" => "user",
        "message" => { "role" => "user", "content" => tool_results },
        "timestamp" => timestamp
      }
    end
    out
  end

  # Returns [tool_use_block, tool_result_block_or_nil] for one opencode tool part.
  def convert_tool_part(part)
    raw_tool = part["tool"].to_s
    name = TOOL_NAME_MAP[raw_tool] || pascalize(raw_tool)
    state = part["state"].is_a?(Hash) ? part["state"] : {}
    call_id = part["callID"].presence || part["id"].presence

    block = { "type" => "tool_use", "name" => name, "input" => remap_input(name, state["input"]) }
    block["id"] = call_id if call_id

    result_text =
      case state["status"]
      when "completed" then state["output"]
      when "error" then state["error"]
      end

    result = nil
    if result_text.present?
      result = { "type" => "tool_result", "content" => clean(result_text.to_s) }
      result["tool_use_id"] = call_id if call_id
    end

    [ block, result ]
  end

  def remap_input(name, input)
    return {} unless input.is_a?(Hash)
    keymap = INPUT_KEY_MAP[name]
    return input unless keymap
    input.transform_keys { |k| keymap[k] || k }
  end

  # opencode assistant message.data carries modelID + providerID at the top
  # level; user message.data nests them under "model".
  def assistant_model(msg)
    model_id = msg["modelID"] || msg.dig("model", "modelID")
    return nil if model_id.blank?
    provider = msg["providerID"] || msg.dig("model", "providerID")
    provider.present? ? "#{provider}/#{model_id}" : model_id.to_s
  end

  # parts elements are {"t"=><ms>, "p"=>{<part.data>}}; sort by t (DB
  # time_created), then unwrap to the part hashes.
  def sorted_parts(parts)
    return [] unless parts.is_a?(Array)
    parts.select { |x| x.is_a?(Hash) && x["p"].is_a?(Hash) }
         .sort_by { |x| numeric(x["t"]) }
         .map { |x| x["p"] }
  end

  def numeric(value)
    value.is_a?(Numeric) ? value : 0
  end

  def ms_to_iso8601(ms)
    return nil unless ms.is_a?(Numeric)
    Time.at(ms / 1000.0).utc.iso8601(3)
  rescue StandardError
    nil
  end

  # NUL-strip every string we emit: session_events (tool output/error/text) are
  # persisted to Postgres jsonb BEFORE the NullByteSanitizer upload boundary.
  def clean(str)
    str.to_s.delete("\x00")
  end

  def pascalize(name)
    name.to_s.split(/[_\s-]+/).reject(&:empty?).map(&:capitalize).join.presence || "Tool"
  end

  def log_summary(metadata, entry_count, skipped, counts)
    Rails.logger.info(
      "OpencodeNormalizer: session=#{metadata[:session_id]} " \
      "entries=#{entry_count} skipped=#{skipped} " \
      "user=#{counts['user']} assistant=#{counts['assistant']}"
    )
  end
end
