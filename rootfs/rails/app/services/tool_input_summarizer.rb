# Produces a short, safe string summary of a tool_use block's `input` hash
# instead of stringifying it whole. Write/Edit/Read tool inputs carry the file
# contents the coding agent saw during a session, so this keeps those contents
# out of the condensed transcript text — only path + size markers are retained.
#
# Dispatch rules (rev-5 Phase 2b):
#
#   Write, MultiEdit       -> file_path + byte-count marker; NEVER content
#   Edit                   -> file_path + "[N bytes]/[M bytes]"; NEVER diff bodies
#   NotebookEdit           -> notebook_path + cell id; drop new_source/old_source
#   Bash                   -> "cmd: <scrubbed command>"
#   Read, Grep, Glob       -> path/pattern passed through SecretScrubber
#   Task                   -> description + subagent_type + prompt-length-hash;
#                             NEVER raw prompt (mirrors EventExtractor's hash approach)
#   TodoWrite, ExitPlanMode,
#   Skill, ToolSearch      -> scrub short text fields only
#   <unknown>              -> "[Tool: NAME(<key1>, <key2>, ...)]" — keys only, no values
#
# Fail-closed contract: any bad input (nil, non-Hash, non-String tool_name,
# key with unexpected type) produces an opaque marker rather than leaking
# the raw value. Every branch must either handle the type explicitly or
# route to the unknown-tool path.
class ToolInputSummarizer
  # Cap per-field preview length to keep chunk sizes predictable. Bodies
  # that would exceed this get a byte count instead of a preview.
  MAX_PREVIEW = 160

  class << self
    # Produce a summary string for a tool_use block.
    #
    # @param tool_name [String, Symbol, nil] value of `block["name"]`
    # @param input [Hash, String, nil] value of `block["input"]` — parsed
    #   from JSONL, typically a Hash. String fallback triggers JSON.parse
    #   with rescue; non-Hash non-String falls to unknown-tool behavior.
    # @return [String] "[Tool: …(…)]" safe for inclusion in a condensed chunk
    def summarize(tool_name, input)
      name = tool_name.to_s.strip
      return "[Tool: <unknown>(<no input>)]" if name.empty?

      hash = coerce_to_hash(input)

      body =
        if hash.nil?
          fallback_unknown_tool(name, input)
        else
          case name
          when "Write"                       then summarize_write(hash)
          when "MultiEdit"                   then summarize_multi_edit(hash)
          when "Edit"                        then summarize_edit(hash)
          when "NotebookEdit"                then summarize_notebook_edit(hash)
          when "Bash"                        then summarize_bash(hash)
          when "Read"                        then summarize_read(hash)
          when "Grep"                        then summarize_grep(hash)
          when "Glob"                        then summarize_glob(hash)
          when "Task", "Agent"               then summarize_task(hash)
          when "TodoWrite", "TaskCreate",
               "TaskUpdate", "ExitPlanMode",
               "Skill", "ToolSearch"         then summarize_text_fields(hash)
          else
            fallback_unknown_tool(name, hash)
          end
        end

      "[Tool: #{name}(#{body})]"
    rescue => e
      # Fail-closed safety net: the per-tool branches aim to handle every
      # type, but agent-controlled input can always surprise one (this is
      # exactly what aborted a 763-session upload — a Read tool_use with an
      # Array `offset`). A raise here kills the whole upload mid-chunk, so
      # emit an opaque, value-free marker and log ONLY the error class +
      # code location. Deliberate divergence from the sibling EventExtractor
      # rescues (transcript_chunker.rb:207/230/238) which log e.message:
      # this class's contract is no-leak, and e.message can echo a user
      # value (e.g. a future KeyError) into GCL. Class + backtrace.first is
      # enough to reproduce.
      Rails.logger.warn("[ToolInputSummarizer] summarize failed: #{e.class} at #{e.backtrace&.first}")
      "[Tool: #{name}(<summary error>)]"
    end

    private

    def coerce_to_hash(input)
      case input
      when Hash then input
      when String
        parsed = JSON.parse(input) rescue nil
        parsed.is_a?(Hash) ? parsed : nil
      else nil
      end
    end

    # Write: file_path + content bytes (never content body)
    def summarize_write(h)
      path = safe_path(h["file_path"])
      content = h["content"].to_s
      "file_path=#{path}, content=[#{content.bytesize} bytes]"
    end

    # MultiEdit: file_path + count of edits + total byte count (never bodies)
    def summarize_multi_edit(h)
      path = safe_path(h["file_path"])
      edits = h["edits"]
      count = edits.is_a?(Array) ? edits.size : 0
      total_bytes = 0
      if edits.is_a?(Array)
        edits.each do |e|
          next unless e.is_a?(Hash)
          total_bytes += e["old_string"].to_s.bytesize
          total_bytes += e["new_string"].to_s.bytesize
        end
      end
      "file_path=#{path}, edits=#{count}, body=[#{total_bytes} bytes]"
    end

    # Edit: file_path + old/new byte counts (never the strings themselves)
    def summarize_edit(h)
      path = safe_path(h["file_path"])
      old_bytes = h["old_string"].to_s.bytesize
      new_bytes = h["new_string"].to_s.bytesize
      "file_path=#{path}, body=[#{old_bytes}]->[#{new_bytes}] bytes"
    end

    # NotebookEdit: path + cell id, drop new_source/old_source entirely
    def summarize_notebook_edit(h)
      path = safe_path(h["notebook_path"])
      cell = h["cell_id"].to_s.truncate(40)
      kind = h["edit_mode"].to_s.truncate(20)
      "notebook_path=#{path}, cell_id=#{cell}, mode=#{kind}"
    end

    # Bash: keep command but scrub credentials first. `description` is a
    # model-generated short string; scrub it too in case a token slips in.
    def summarize_bash(h)
      cmd = SecretScrubber.scrub(h["command"].to_s).truncate(MAX_PREVIEW)
      desc = SecretScrubber.scrub(h["description"].to_s).truncate(80)
      parts = [ "cmd=#{cmd.inspect}" ]
      parts << "desc=#{desc.inspect}" if desc.present?
      parts.join(", ")
    end

    # Read: path + optional offset/limit. Path scrubbed.
    def summarize_read(h)
      path = safe_path(h["file_path"])
      parts = [ "file_path=#{path}" ]
      # offset/limit are optional integers in Claude Code's Read schema. A
      # non-Claude tool sharing the "Read" name, or a malformed transcript,
      # can put an Array/Hash/bool/String here; Array#to_i doesn't exist and
      # would crash the whole upload. Guard on Numeric (the in-file
      # convention, see summarize_text_fields) and keep .to_i so Integer +
      # Float render exactly as before. Non-numeric types are dropped
      # (fail-closed) — this includes a numeric String like "100", which the
      # old code rendered as offset=100; conforming Read inputs are always
      # JSON integers, so only malformed transcripts hit that path.
      parts << "offset=#{h['offset'].to_i}" if h["offset"].is_a?(Numeric)
      parts << "limit=#{h['limit'].to_i}" if h["limit"].is_a?(Numeric)
      parts.join(", ")
    end

    # Grep: pattern + path + glob. All three are scrubbed — a user can spell
    # a credential into any of them (e.g. `--include` glob `/tmp/sk-ant-*/`
    # or a grep pattern literal-matching a token).
    def summarize_grep(h)
      pattern = SecretScrubber.scrub(h["pattern"].to_s).truncate(MAX_PREVIEW)
      parts = [ "pattern=#{pattern.inspect}" ]
      parts << "path=#{safe_path(h['path'])}" if h["path"]
      parts << "glob=#{SecretScrubber.scrub(h['glob'].to_s).truncate(80).inspect}" if h["glob"]
      parts.join(", ")
    end

    # Glob: pattern + path. Pattern scrubbed (user can paste a literal path
    # containing a credential).
    def summarize_glob(h)
      pattern = SecretScrubber.scrub(h["pattern"].to_s).truncate(MAX_PREVIEW)
      parts = [ "pattern=#{pattern.inspect}" ]
      parts << "path=#{safe_path(h['path'])}" if h["path"]
      parts.join(", ")
    end

    # Task: persist description + subagent_type + prompt byte count + sha256.
    # NEVER ships the raw prompt (may embed source code, credentials, etc).
    # `description` and `subagent_type` ARE retained — scrub both so a
    # credential-bearing description (e.g. `"rotate sk-ant-…"`) doesn't
    # reach chunks.content. Mirrors EventExtractor's scrub of the same
    # field at event_extractor.rb:136.
    def summarize_task(h)
      desc = SecretScrubber.scrub(h["description"].to_s).truncate(120)
      subagent = SecretScrubber.scrub(h["subagent_type"].to_s).truncate(40)
      prompt = h["prompt"].to_s
      sha = prompt.empty? ? "" : Digest::SHA256.hexdigest(prompt)[0, 12]
      parts = []
      parts << "description=#{desc.inspect}" if desc.present?
      parts << "subagent_type=#{subagent.inspect}" if subagent.present?
      parts << "prompt=[#{prompt.bytesize} bytes, sha=#{sha}]"
      parts.join(", ")
    end

    # TodoWrite / ExitPlanMode / Skill / ToolSearch: short text fields.
    # Scrub every String value to catch an embedded credential, truncate
    # long values, drop non-scalar values entirely.
    def summarize_text_fields(h)
      pairs = h.filter_map do |k, v|
        key = k.to_s.truncate(40)
        value =
          case v
          when String
            SecretScrubber.scrub(v).truncate(MAX_PREVIEW).inspect
          when Numeric, TrueClass, FalseClass
            v.to_s
          when Array
            "[Array, #{v.size}]"
          when Hash
            "[Hash, #{v.size}]"
          else
            nil
          end
        next nil if value.nil?
        "#{key}=#{value}"
      end
      pairs.join(", ")
    end

    # Unknown tool: just list the input-hash keys, no values. Returns the
    # INNER body only — the outer `"[Tool: name(...)]"` wrapping is added
    # by `summarize`. Returning a full marker here would double-wrap
    # (`[Tool: name([Tool: name(...)])]`) and skew downstream counters
    # that scan for `\[Tool:`. Flagged by Codex review, 2026-04-23.
    def fallback_unknown_tool(name, input)
      if input.is_a?(Hash)
        keys = input.keys.map { |k| k.to_s.truncate(40) }.join(", ")
        "<keys: #{keys}>"
      else
        "<#{input.class}>"
      end
    end

    # Scrub a path through SecretScrubber to catch any credential
    # accidentally spelled in the path itself. Also truncate.
    def safe_path(value)
      SecretScrubber.scrub(value.to_s).truncate(MAX_PREVIEW).inspect
    end
  end
end
