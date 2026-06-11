# Converts Gemini CLI transcripts to Claude Code canonical format.
#
# Current gemini-cli (chatRecordingService.ts) writes one JSONL file per session
# at ~/.gemini/tmp/<project-slug>/chats/session-<ISO>-<short>.jsonl (main) and
# .../chats/<parentSessionId>/<childSessionId>.jsonl (subagents). The client
# upload script (collect_gemini_sessions) copies these raw into the archive; this
# normalizer does ALL reconstruction. Line shapes:
#   header: {"sessionId","projectHash","startTime","lastUpdated","kind"[,"directories"]}  (NO "type")
#   mutate: {"$set":{"messages":[<MessageRecord>...]}}   FULL snapshot, last-write-wins
#           {"$set":{"lastUpdated":...}}                  ignored
#           {"$rewindTo":"<id>"}                          delete from id onward (clear if absent)
#   typed:  {"id","timestamp","type":"user","content": String|Part[]}
#           {"id","timestamp","type":"gemini","content": String|Part[],
#            "thoughts":[{subject,description,timestamp}],"toolCalls":[...],"model"}
#           {"type":"error"|"info"|"warning",...}         skipped
#
# Reconstruction is TWO-PHASE (matches gemini-cli's reader, which returns a
# messagesMap's insertion order — NOT a timestamp sort):
#   A) replay_records: replay every line into an insertion-ordered id->record map.
#      $set{messages} clears+rebuilds; typed user/gemini upsert by id (re-assign
#      keeps position); $rewindTo truncates from the id (clears all if absent).
#   B) convert each record. Conversion + the <session_context> preamble-skip MUST
#      run on the merged list, not per line: short/aborted sessions store the whole
#      conversation inside one $set{messages}, while subagents are pure typed lines.
#
# Tool calls live in a top-level `toolCalls` array (NOT inline functionCall) and
# reasoning in `thoughts`. gemini tool param names are already snake_case
# (file_path/old_string/command/...), so only invoke_agent needs a key remap
# (agent_name->subagent_type) to read as Claude's Task. The tool call `id` is
# threaded tool_use.id -> tool_result.tool_use_id so EventExtractor pairs
# subagent dispatch (invoke_agent->Task) with its return.
#
# Legacy monolithic .json sessions (pre-mutation-log) keep their own path.
#
class GeminiNormalizer
  include BaseNormalizer

  AGENT_TYPE = "gemini_cli".freeze
  SKIP_MESSAGE_TYPES = %w[error info warning].freeze
  # gemini-cli injects this as the first user turn (env + project tree). It is
  # synthetic context, not user intent, and carries the absolute tmp path — skip.
  SESSION_CONTEXT_PREFIX = "<session_context>".freeze

  # gemini tool name -> Claude canonical name. Unlisted names fall back to a
  # PascalCase form (still counts as a tool); only mapped names trigger
  # EventExtractor's file_edit / subagent / read signals + ToolInputSummarizer.
  TOOL_NAME_MAP = {
    "run_shell_command" => "Bash",
    "read_file" => "Read",
    "write_file" => "Write",
    "replace" => "Edit",
    "glob" => "Glob",
    "grep_search" => "Grep",
    "search_file_content" => "Grep",
    "list_directory" => "LS",
    "google_web_search" => "WebSearch",
    "web_fetch" => "WebFetch",
    "write_todos" => "TodoWrite",
    "invoke_agent" => "Task"
  }.freeze

  # Per-(canonical)-tool input-key remap. gemini params are already snake_case,
  # so only invoke_agent->Task needs it (EventExtractor reads subagent_type).
  INPUT_KEY_MAP = {
    "Task" => { "agent_name" => "subagent_type" }
  }.freeze

  def normalize(metadata: {})
    metadata[:agent_type] = AGENT_TYPE
    if jsonl_path.to_s.end_with?(".json")
      normalize_legacy_json(metadata)
    else
      normalize_jsonl(metadata)
    end
  end

  private

  def normalize_jsonl(metadata)
    records = replay_records(metadata)
    entries = []
    skipped = 0
    counts = Hash.new(0)

    records.each do |rec|
      metadata[:model] ||= rec["model"] if rec.is_a?(Hash) && rec["type"] == "gemini" && rec["model"].present?
      produced = convert_record(rec)
      if produced.empty?
        skipped += 1
      else
        produced.each { |e| counts[e["type"]] += 1 }
        entries.concat(produced)
      end
    rescue => e
      # One malformed record must not sink the whole upload. replay_records
      # scrubs each raw line, but a tool result reconstructed from nested parts
      # can still carry bytes a String op (e.g. #present?) chokes on
      # (PAXEL-CLIENT-2J: convert_tool_call → present? → invalid byte sequence).
      # Skip + count it, same as an empty conversion.
      skipped += 1
      Rails.logger.warn("GeminiNormalizer: record convert failed: #{e.class}: #{e.message}")
    end

    log_summary(metadata, entries.size, skipped, counts)
    entries
  end

  # Phase A: replay the mutation log into an insertion-ordered id->record map.
  def replay_records(metadata)
    msgs = {} # Ruby Hash preserves insertion order; re-assign keeps position.

    # encoding: "UTF-8" so `.scrub` cleans invalid bytes — the client Docker image
    # has no locale (default_external = ASCII-8BIT), under which scrub is a no-op and
    # invalid bytes crash a later String op (PAXEL-CLIENT-1G).
    File.foreach(jsonl_path, encoding: "UTF-8") do |line|
      line = line.scrub.strip
      next if line.empty?

      begin
        raw = JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      next unless raw.is_a?(Hash)

      if raw.key?("$set")
        apply_set(raw["$set"], msgs)
      elsif raw.key?("$rewindTo")
        apply_rewind(raw["$rewindTo"], msgs)
      elsif header?(raw)
        extract_header(raw, metadata)
      else
        type = raw["type"].to_s
        next if SKIP_MESSAGE_TYPES.include?(type)
        upsert(raw, msgs) if (type == "user" || type == "gemini") && raw["id"].present?
      end
    rescue => e
      Rails.logger.warn("GeminiNormalizer: replay line failed: #{e.message}")
    end

    msgs.values
  rescue SystemCallError, IOError, ArgumentError => e
    # The File.foreach call itself can raise on an unreadable / oddly-encoded
    # file or path (e.g. ArgumentError "negative string size"), escaping the
    # per-line rescue above and sinking the whole upload (PAXEL-CLIENT-19).
    Rails.logger.warn("[GeminiNormalizer] unreadable transcript #{jsonl_path}: #{e.class}: #{e.message}")
    msgs.values
  end

  # Header line: no "type", carries the session id + project hash. The AND is
  # load-bearing — Claude Code session lines have sessionId but never projectHash.
  def header?(raw)
    !raw.key?("type") && raw["sessionId"].is_a?(String) && raw["projectHash"].is_a?(String)
  end

  def apply_set(set, msgs)
    return unless set.is_a?(Hash) && set["messages"].is_a?(Array)
    msgs.clear
    set["messages"].each { |m| upsert(m, msgs) if m.is_a?(Hash) && m["id"].present? }
  end

  def apply_rewind(id, msgs)
    keys = msgs.keys
    idx = keys.index(id)
    if idx.nil?
      msgs.clear
    else
      keys[idx..].each { |k| msgs.delete(k) }
    end
  end

  def upsert(rec, msgs)
    msgs[rec["id"]] = rec
  end

  def extract_header(raw, metadata)
    metadata[:session_id] ||= raw["sessionId"]
    dirs = raw["directories"]
    metadata[:cwd] ||= dirs.first if dirs.is_a?(Array) && dirs.first.is_a?(String)
  end

  # Phase B: one record -> [primary entry, (optional) user tool_result entry].
  def convert_record(rec)
    return [] unless rec.is_a?(Hash)
    ts = rec["timestamp"]

    case rec["type"].to_s
    when "user"
      text = extract_text(rec["content"])
      return [] if text.blank?
      return [] if text.lstrip.start_with?(SESSION_CONTEXT_PREFIX)
      [ { "type" => "user", "message" => { "role" => "user", "content" => clean(text) }, "timestamp" => ts } ]
    when "gemini"
      convert_gemini(rec, ts)
    else
      []
    end
  end

  def convert_gemini(rec, timestamp)
    blocks = []

    Array(rec["thoughts"]).each do |thought|
      next unless thought.is_a?(Hash)
      text = [ thought["subject"], thought["description"] ].map { |s| clean(s.to_s) }.reject(&:blank?).join(": ")
      blocks << { "type" => "thinking", "thinking" => text } if text.present?
    end

    text = extract_text(rec["content"])
    blocks << { "type" => "text", "text" => clean(text) } if text.present?

    tool_results = []
    Array(rec["toolCalls"]).each do |tc|
      next unless tc.is_a?(Hash)
      block, result = convert_tool_call(tc)
      blocks << block if block
      tool_results << result if result
    end

    out = []
    if blocks.any?
      entry = {
        "type" => "assistant",
        "message" => { "role" => "assistant", "content" => blocks },
        "timestamp" => timestamp
      }
      entry["model"] = rec["model"] if rec["model"].present?
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

  # Returns [tool_use_block, tool_result_block_or_nil] for one gemini toolCall.
  def convert_tool_call(tc)
    raw_name = tc["name"].to_s
    name = TOOL_NAME_MAP[raw_name] || pascalize(raw_name)
    call_id = tc["id"].presence

    block = { "type" => "tool_use", "name" => name, "input" => clean_deep(remap_input(name, tc["args"])) }
    block["id"] = call_id if call_id

    result_text = extract_tool_result(tc["result"])
    result = nil
    if result_text.present?
      result = { "type" => "tool_result", "content" => clean(result_text) }
      result["tool_use_id"] = call_id if call_id
    end

    [ block, result ]
  end

  def remap_input(name, args)
    return {} unless args.is_a?(Hash)
    keymap = INPUT_KEY_MAP[name]
    return args unless keymap
    args.transform_keys { |k| keymap[k] || k }
  end

  # toolCall.result is a PartListUnion, in practice
  # [{"functionResponse":{"response":{"output": ...}}}]. Large outputs are masked
  # inline by gemini-cli (the full text spills to tool-outputs/, which we don't
  # copy); the masked indicator is acceptable.
  def extract_tool_result(result)
    case result
    when String
      result
    when Array
      result.filter_map { |part| tool_result_part_text(part) }.join("\n")
    when Hash
      stringify(result["output"] || result["error"] || result)
    else
      ""
    end
  end

  def tool_result_part_text(part)
    return nil unless part.is_a?(Hash)
    fr = part["functionResponse"]
    if fr.is_a?(Hash)
      resp = fr["response"]
      resp.is_a?(Hash) ? stringify(resp["output"] || resp["error"] || resp) : stringify(resp)
    elsif part.key?("text")
      part["text"].to_s
    end
  end

  def extract_text(content)
    case content
    when String
      content
    when Array
      content.filter_map { |part|
        if part.is_a?(Hash)
          part["text"]
        elsif part.is_a?(String)
          part
        end
      }.join("\n")
    when Hash
      content["text"].to_s
    else
      ""
    end
  end

  def stringify(value)
    value.is_a?(String) ? value : value.to_json
  end

  # Legacy monolithic .json (pre-mutation-log). Kept for the committed fixture +
  # any old-format file; current gemini-cli no longer writes this shape.
  def normalize_legacy_json(metadata)
    data = JSON.parse(File.read(jsonl_path, encoding: "utf-8"))
    metadata[:session_id] ||= data["id"] || data["session_id"]
    metadata[:model] ||= data["model"]
    metadata[:cwd] ||= data.dig("project", "path") || data.dig("metadata", "cwd")

    messages = data["messages"] || data["history"] || []
    entries = []
    skipped = 0
    counts = Hash.new(0)

    messages.each do |msg|
      canonical = convert_legacy_message(msg)
      if canonical
        entries << canonical
        counts[canonical["type"]] += 1
      else
        skipped += 1
      end
    rescue => e
      Rails.logger.warn("GeminiNormalizer: failed to convert legacy message: #{e.message}")
      skipped += 1
    end

    log_summary(metadata, entries.size, skipped, counts)
    entries
  rescue JSON::ParserError => e
    Rails.logger.warn("GeminiNormalizer: failed to parse JSON #{jsonl_path}: #{e.message}")
    []
  rescue => e
    Rails.logger.warn("GeminiNormalizer: unexpected error reading #{jsonl_path}: #{e.message}")
    []
  end

  def convert_legacy_message(msg)
    return nil unless msg.is_a?(Hash)
    type = msg["type"] || msg["role"]
    text = extract_text(msg["content"] || msg["text"] || msg["parts"])
    return nil if text.blank?
    timestamp = msg["timestamp"] || msg["ts"]

    case type
    when "user"
      { "type" => "user", "message" => { "role" => "user", "content" => clean(text) }, "timestamp" => timestamp }
    when "gemini", "model", "assistant"
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => clean(text) }, "timestamp" => timestamp }
    end
  end

  # NUL-strip every string we emit: session_events are persisted to Postgres
  # jsonb BEFORE the NullByteSanitizer upload boundary.
  def clean(str)
    str.to_s.delete("\x00")
  end

  # Recursively NUL-strip a tool_use input. EventExtractor persists tool args
  # (e.g. a Bash `command`) into session_events before the upload-boundary
  # sanitizer, so a decoded NUL in an arg must be stripped here too.
  def clean_deep(value)
    case value
    when String then value.delete("\x00")
    when Hash then value.transform_values { |v| clean_deep(v) }
    when Array then value.map { |v| clean_deep(v) }
    else value
    end
  end

  def pascalize(name)
    name.to_s.split(/[_\s-]+/).reject(&:empty?).map(&:capitalize).join.presence || "Tool"
  end

  def log_summary(metadata, entry_count, skipped, counts)
    Rails.logger.info(
      "GeminiNormalizer: session=#{metadata[:session_id]} " \
      "entries=#{entry_count} skipped=#{skipped} " \
      "user=#{counts['user']} assistant=#{counts['assistant']}"
    )
  end
end
