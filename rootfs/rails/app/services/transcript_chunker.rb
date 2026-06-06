class TranscriptChunker
  include TranscriptPatterns

  # Scrub/summarization contract version stamped onto every new `chunks.content`
  # write. Bump this whenever the set of scrubber patterns OR the tool_use
  # dispatch table changes in a way that would affect already-persisted output.
  # Phase 3 retro-scrub targets rows with `content_version < CURRENT` (or NULL,
  # for pre-Phase 2 rows written before this column existed).
  #
  # Changelog:
  #   v3 (2026-06-05) — tool_result OUTPUT bodies (Read file contents, Edit
  #     updated-file snippets, Bash stdout, persisted-output sidecars) replaced
  #     with a content-free byte-count marker, mirroring ToolInputSummarizer's
  #     treatment of the INPUT side. Closes the last path by which source code /
  #     file contents could ride a chunk to the LLM proxy. See
  #     docs/designs/SECURE_UPLOAD.md.
  #     NOTE: this is a CONTENT contract, not a scrubber-pattern change, so
  #     PaxelRetroScrub#scrub_chunks (which scopes on content_version < this)
  #     can't deliver it for old rows — it only re-runs SecretScrubber and would
  #     stamp v3 while leaving old inlined tool output in place. Existing v2
  #     chunks get the v3 contract on RE-UPLOAD only. Moot in practice: no chunk
  #     rows persist server-side (the client holds them in ephemeral SQLite).
  #   v2 (2026-04-24, PR #706 + follow-ups) — SecretScrubber hooks at 4 ingestion
  #     points + ToolInputSummarizer dispatch replacing block["input"].to_s.
  #   v1 — implicit pre-fix baseline (never actually written; NULL in DB).
  CONDENSED_TEXT_VERSION = 3

  TOKEN_BUDGET = 5_000
  MIN_CHUNK_TOKENS = 200
  # Bumped 2K → 20K (2026-04-23) so long user messages (code pastes, detailed
  # requirements, plan file content) flow into `condensed_text` → scoring
  # prompts. Downstream caps lifted in lockstep: SessionSignalExtractor's
  # MAX_TEXT_FOR_REGEX → 20K, BuilderProfileService#collect_user_highlights
  # → 2K. See TODOS.md "Remove destructive truncation" Tier 1.
  MAX_TEXT_LENGTH = 20_000
  MAX_USER_TEXT_LENGTH = 20_000
  TOOL_SUMMARY_LENGTH = 500
  TASK_NOTIFICATION_PATTERN = /<task-notification\b[^>]*>.*?<\/task-notification>/m

  LOCAL_COMMAND_TAGS = %w[
    <local-command-caveat
    <command-name
    <command-message
    <command-args
    <local-command-stdout
  ].freeze

  attr_reader :transcript_session, :jsonl_path, :filtered_local_commands_count, :filtered_tool_only_count

  def initialize(transcript_session, jsonl_path, extract_dir: nil)
    @transcript_session = transcript_session
    @jsonl_path = jsonl_path
    @filtered_local_commands_count = 0
    @filtered_tool_only_count = 0
    @event_extractor = EventExtractor.new
    if extract_dir
      session_id = File.basename(jsonl_path, ".jsonl")
      @tool_results_dir = File.join(File.dirname(jsonl_path), session_id, "tool-results")
    end
  end

  def chunk!
    messages = parse_and_condense
    return mark_too_short if estimate_tokens(messages.join("\n")) < MIN_CHUNK_TOKENS

    # Prepend subagent context if applicable
    if transcript_session.is_subagent && transcript_session.parent_session
      parent_prompt = transcript_session.parent_session.first_prompt || "unknown"
      messages.unshift("[SUBAGENT TASK - Parent: #{parent_prompt}]")
    end

    chunks = group_into_chunks(messages)
    chunks.each_with_index do |chunk_content, index|
      text = chunk_content.join("\n").delete("\x00")
      transcript_session.chunks.create!(
        position: index,
        content: text,
        content_version: CONDENSED_TEXT_VERSION,
        token_estimate: estimate_tokens(text),
        user_turns: chunk_content.count { |line| line.start_with?("USER:") }
      )
    end

    update_session_stats

    begin
      extract_and_save_signals
    rescue => e
      Rails.logger.warn("TranscriptChunker: Signal extraction failed for #{transcript_session.session_id}: #{e.message}")
    end

    begin
      persist_plan_files
    rescue => e
      Rails.logger.warn("TranscriptChunker: Plan file persist failed for #{transcript_session.session_id}: #{e.message}")
    end

    transcript_session.update!(status: "chunked")
    transcript_session.chunks.count
  end

  private

  def parse_and_condense
    format = TranscriptFormatDetector.detect(jsonl_path)

    case format
    when :codex_cli
      @normalizer_meta = {}
      normalized = CodexNormalizer.new(jsonl_path).normalize(metadata: @normalizer_meta)
      parse_entries(normalized, agent_type: "codex_cli")
    when :gemini_cli
      @normalizer_meta = {}
      normalized = GeminiNormalizer.new(jsonl_path).normalize(metadata: @normalizer_meta)
      parse_entries(normalized, agent_type: "gemini_cli")
    when :opencode
      @normalizer_meta = {}
      normalized = OpencodeNormalizer.new(jsonl_path).normalize(metadata: @normalizer_meta)
      parse_entries(normalized, agent_type: "opencode")
    else
      parse_entries_from_file
    end
  end

  # Parse Claude Code JSONL from file (original path)
  def parse_entries_from_file
    entries = []
    skipped = 0

    unless File.exist?(jsonl_path)
      Rails.logger.warn("[TranscriptChunker] File not found, skipping: #{jsonl_path}")
      return entries
    end

    File.foreach(jsonl_path) do |line|
      line = line.scrub.delete("\x00").strip
      next if line.empty?

      begin
        entries << JSON.parse(line)
      rescue JSON::ParserError
        skipped += 1
      end
    end

    parse_entries(entries, skipped_count: skipped)
  end

  # Shared entry processing for all formats.
  # Claude path sends raw parsed JSON entries.
  # Codex/Gemini paths send normalized entries (already in Claude format).
  def parse_entries(entries, agent_type: nil, skipped_count: 0)
    messages = []
    skipped = skipped_count
    user_count = 0
    assistant_count = 0
    tool_count = 0
    tools_used = Set.new
    models_used = Hash.new(0)
    @raw_user_messages = []
    @first_timestamp = nil
    @last_timestamp = nil
    # Per-message timestamps (user + assistant + tool) feed gap-split
    # active-duration calculation in SessionSignalExtractor. All-message
    # rather than user-only so long Claude work periods between user
    # messages still count as active time.
    @all_message_timestamps = []

    entries.each do |entry|
      # A JSONL line that parses to a non-Hash (a bare array or scalar) survives
      # JSON.parse above but would raise TypeError on entry["type"] and sink the
      # whole upload (client_pipeline_fatal). Skip it. (PAXEL-CLIENT-1J)
      unless entry.is_a?(Hash)
        skipped += 1
        next
      end
      type = entry["type"]
      message = entry["message"]
      next unless message.is_a?(Hash)

      # Sidechain filter: entries tagged isSidechain=true in a MAIN session's
      # JSONL are subagent-turn echoes that duplicate content the subagent's
      # own file already has — filtering them keeps the main transcript clean.
      # But INSIDE a subagent's own JSONL, every entry is flagged
      # isSidechain=true because the whole file IS the sidechain. Applying the
      # filter there drops all messages → too_short → no narrative → the
      # subagent never reaches the server, breaking Orchestrator scoring
      # (PR 2.5 unblocks the feature PR #592 shipped).
      next if entry["isSidechain"] && !transcript_session.is_subagent

      content = message["content"]
      timestamp = entry["timestamp"]

      # Track first/last timestamps
      if timestamp
        @first_timestamp ||= timestamp
        @last_timestamp = timestamp
        @all_message_timestamps << timestamp
      end

      case type
      when "user"
        # Extract events from tool_result blocks
        if content.is_a?(Array)
          content.each do |block|
            begin
              @event_extractor.extract_from_tool_result(block, timestamp)
            rescue => e
              Rails.logger.warn("EventExtractor: tool_result extraction failed: #{e.message}")
            end
          end
        end

        condensed = condense_user_message(content)
        if condensed
          messages << "USER: #{condensed}"
          user_count += 1

          # Track raw user message for signal extraction + event extraction
          raw_text = extract_raw_user_text(content)
          if raw_text.present?
            @raw_user_messages << {
              text: raw_text.truncate(MAX_USER_TEXT_LENGTH),
              timestamp: timestamp,
              word_count: raw_text.split(/\s+/).size
            }
            begin
              @event_extractor.extract_user_directive(raw_text, timestamp)
            rescue => e
              Rails.logger.warn("EventExtractor: user_directive extraction failed: #{e.message}")
            end
          end
        end
      when "assistant"
        # Track model usage
        model = entry["model"]
        models_used[model] += 1 if model.present?

        # Extract events from tool_use, thinking, and text blocks
        if content.is_a?(Array)
          content.each do |block|
            begin
              if block.is_a?(Hash)
                if block["type"] == "tool_use"
                  @event_extractor.extract_from_tool_use(block, timestamp)
                elsif block["type"] == "thinking"
                  @event_extractor.extract_agent_thinking(block, timestamp)
                elsif block["type"] == "text" && block["text"].present?
                  @event_extractor.extract_agent_proposal(block["text"], timestamp)
                end
              end
            rescue => e
              Rails.logger.warn("EventExtractor: tool_use extraction failed: #{e.message}")
            end
          end
        elsif content.is_a?(String)
          # Some normalized assistant messages are plain strings rather than typed blocks.
          begin
            @event_extractor.extract_agent_proposal(content, timestamp)
          rescue => e
            Rails.logger.warn("EventExtractor: assistant text extraction failed: #{e.message}")
          end
        end

        condensed = condense_assistant_message(content, tools_used, timestamp)
        if condensed
          messages << "ASSISTANT: #{condensed}"
          assistant_count += 1
          tool_count += condensed.scan(/\[Tool:/).count
        end
      end
    end

    @tool_count = tool_count
    @assistant_count = assistant_count
    @git_commits = @event_extractor.git_commits
    @tools_used = tools_used.to_a

    attrs = {
      skipped_lines_count: skipped,
      user_message_count: user_count,
      assistant_message_count: assistant_count,
      tool_use_count: tool_count,
      tools_used: @tools_used,
      models_used: models_used,
      git_commits: @event_extractor.git_commits,
      session_events: @event_extractor.events,
      dispatch_metadata: @event_extractor.dispatch_metadata,
      active_time_windows: compute_active_time_windows
    }

    # quality_flags is merged (not overwritten) so downstream stages can
    # additively flag things like orphan_subagent without clobbering each other.
    if @event_extractor.truncated
      attrs[:quality_flags] = (transcript_session.quality_flags || {}).merge("session_events_truncated" => true)
    end

    # Set agent_type if detected
    attrs[:agent_type] = agent_type if agent_type.present?

    # Backfill git_branch from normalizer metadata or event extractor
    if transcript_session.git_branch.blank?
      if @normalizer_meta&.dig(:git_branch).present?
        attrs[:git_branch] = @normalizer_meta[:git_branch]
      elsif @event_extractor.detected_branch.present?
        attrs[:git_branch] = @event_extractor.detected_branch
      end
    end

    # Persist first/last timestamps for evidence linking
    if @first_timestamp.present?
      attrs[:session_created_at] = Time.parse(@first_timestamp) rescue nil
    end
    if @last_timestamp.present?
      attrs[:session_modified_at] = Time.parse(@last_timestamp) rescue nil
    end

    # Log extraction summary
    summary = @event_extractor.summary
    if summary[:event_count] > 0
      Rails.logger.info("EventExtractor: session=#{transcript_session.session_id} #{summary[:event_count]} events #{summary[:type_breakdown]}")
    end

    transcript_session.update!(attrs)

    messages
  end

  def condense_user_message(content)
    case content
    when String
      stripped = content.strip
      return nil if stripped.start_with?("<system_instruction")
      return nil if stripped.start_with?("<system-reminder")
      stripped = stripped.gsub(TASK_NOTIFICATION_PATTERN, "").strip
      return nil if stripped.empty?
      if local_command_content?(stripped)
        @filtered_local_commands_count += 1
        return nil
      end
      scrubbed_text(resolve_persisted_output(strip_null_bytes(stripped).truncate(MAX_TEXT_LENGTH)))
    when Array
      has_real_text = false
      parts = content.filter_map do |block|
        case block["type"]
        when "text"
          text = strip_null_bytes(block["text"].to_s)
          next if text.start_with?("<system_instruction")
          next if text.start_with?("<system-reminder")
          text = text.gsub(TASK_NOTIFICATION_PATTERN, "").strip
          next if text.empty?
          if local_command_content?(text)
            @filtered_local_commands_count += 1
            next
          end
          has_real_text = true
          scrubbed_text(resolve_persisted_output(text.truncate(MAX_TEXT_LENGTH)))
        when "tool_result"
          tool_result_marker(block["content"])
        end
      end

      # Skip tool-result-only messages (no real user text)
      unless has_real_text
        if parts.any? { |p| p&.start_with?("[ToolResult:") }
          @filtered_tool_only_count += 1
          return nil
        end
      end

      parts.join(" ").presence
    end
  end

  def condense_assistant_message(content, tools_used, timestamp)
    case content
    when String
      scrubbed_text(resolve_persisted_output(strip_null_bytes(content).truncate(MAX_TEXT_LENGTH)))
    when Array
      parts = content.filter_map do |block|
        case block["type"]
        when "text"
          scrubbed_text(resolve_persisted_output(strip_null_bytes(block["text"].to_s).truncate(MAX_TEXT_LENGTH))).presence
        when "tool_use"
          tool_name = block["name"]
          tools_used << tool_name if tool_name

          # Rev-5 Phase 2b: ToolInputSummarizer replaces the old
          # `block["input"].to_s` — which serialized the full Write/Edit
          # content, MultiEdit bodies, Task prompts, etc. into the
          # condensed chunk that Anthropic scored. Per-tool dispatch
          # keeps file paths + byte counts but drops content bodies.
          if SecretScrubber.enabled?
            ToolInputSummarizer.summarize(tool_name, block["input"])
          else
            input_summary = strip_null_bytes(block["input"].to_s).truncate(TOOL_SUMMARY_LENGTH)
            "[Tool: #{tool_name}(#{input_summary})]"
          end
        when "thinking"
          nil # Skip thinking blocks from condensed text
        end
      end
      parts.join(" ").presence
    end
  end

  # OUTPUT side of a tool call: a Read result is file contents, an Edit result
  # is the updated-file snippet, a Bash result is stdout. To honor the "your
  # source code never leaves your machine" guarantee we never inline the body —
  # we emit a content-free byte-count marker, mirroring ToolInputSummarizer's
  # treatment of the INPUT side (path + byte counts, never bodies). A large
  # output is referenced inline as a <persisted-output> block whose true bytes
  # live in a tool-results sidecar; we report that real size when resolvable.
  # Returns nil for an empty result so a tool-result-only user message still
  # collapses to nothing and gets dropped upstream.
  #
  # Unconditional (not gated on the PAXEL_TOOL_OUTPUT_SCRUB credential flag):
  # the body is dropped even with scrubbing disabled, so the privacy guarantee
  # holds regardless. Admins debugging locally still have the raw transcripts
  # on disk.
  def tool_result_marker(content)
    text = case content
    when String then strip_null_bytes(content)
    when Array  then content.filter_map { |b| strip_null_bytes(b["text"].to_s) if b.is_a?(Hash) }.join(" ")
    else ""
    end
    return nil if text.strip.empty?

    body = text[/<persisted-output>(.*?)<\/persisted-output>/m, 1]
    size = body ? persisted_output_size(body) : "#{text.bytesize} bytes"
    "[ToolResult: #{size}]"
  end

  # Content-free size of a <persisted-output> block: the real sidecar file size
  # when we can resolve it, else the human-readable hint in the block header
  # ("Output too large (87.7KB)"), else an opaque marker. NEVER reads the body
  # into the chunk.
  def persisted_output_size(block_body)
    if @tool_results_dir && (fname = block_body[/saved to:.*?tool-results\/(\S+\.txt)/, 1])
      filepath = File.join(@tool_results_dir, fname)
      begin
        return "#{File.size(filepath)} bytes" if File.exist?(filepath)
      rescue SystemCallError
        # fall through to the header hint
      end
    end
    hint = block_body[/Output too large \(([^)]+)\)/, 1]
    hint ? "~#{hint}" : "persisted"
  end

  # Defense-in-depth: replace any <persisted-output> reference that appears in
  # free user/assistant text (rare — these normally live in tool_result blocks,
  # handled by tool_result_marker) with a content-free size marker. Surrounding
  # prose is preserved; only the persisted body is dropped.
  def resolve_persisted_output(text)
    return text unless text.include?("<persisted-output>")

    text.gsub(/<persisted-output>(.*?)<\/persisted-output>/m) do
      "[PersistedOutput: #{persisted_output_size(Regexp.last_match(1))}]"
    end
  end

  def group_into_chunks(messages)
    chunks = []
    current_chunk = []
    current_tokens = 0

    messages.each do |msg|
      msg_tokens = estimate_tokens(msg)

      if current_tokens + msg_tokens > TOKEN_BUDGET && current_chunk.any?
        # Only break on user-turn boundaries
        if msg.start_with?("USER:")
          chunks << current_chunk
          current_chunk = [ msg ]
          current_tokens = msg_tokens
        else
          current_chunk << msg
          current_tokens += msg_tokens
        end
      else
        current_chunk << msg
        current_tokens += msg_tokens
      end
    end

    chunks << current_chunk if current_chunk.any?
    chunks
  end

  def estimate_tokens(text)
    (text.length / 4.0).ceil
  end

  def strip_null_bytes(str)
    str.delete("\x00")
  end

  def mark_too_short
    transcript_session.update!(status: "too_short", narrative_status: "skipped")
    0
  end

  def update_session_stats
    transcript_session.update!(
      message_count: transcript_session.user_message_count + transcript_session.assistant_message_count
    )
    if @filtered_local_commands_count > 0 || @filtered_tool_only_count > 0
      Rails.logger.info("TranscriptChunker: session=#{transcript_session.session_id} filtered_local_commands=#{@filtered_local_commands_count} filtered_tool_only=#{@filtered_tool_only_count}")
    end
  end

  def local_command_content?(text)
    LOCAL_COMMAND_TAGS.any? { |tag| text.start_with?(tag) }
  end

  # Skill templates get injected as user message text when a slash command expands.
  # These are system instructions, not developer decisions.
  SKILL_TEMPLATE_PATTERNS = [
    /\ABase directory for this skill:/,
    /<!-- AUTO-GENERATED from SKILL\.md/,
    /\A# \/\w+:.*\n\n.*skill/im
  ].freeze

  def skill_template_content?(text)
    SKILL_TEMPLATE_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def extract_raw_user_text(content)
    case content
    when String
      stripped = content.strip
      return nil if stripped.start_with?("<system_instruction", "<system-reminder")
      stripped = stripped.gsub(TASK_NOTIFICATION_PATTERN, "").strip
      return nil if stripped.empty?
      return nil if local_command_content?(stripped)
      return nil if skill_template_content?(stripped)
      scrubbed_text(strip_null_bytes(stripped))
    when Array
      parts = content.filter_map do |block|
        next unless block["type"] == "text"
        text = strip_null_bytes(block["text"].to_s)
        next if text.start_with?("<system_instruction", "<system-reminder")
        text = text.gsub(TASK_NOTIFICATION_PATTERN, "").strip
        next if text.empty?
        next if local_command_content?(text)
        next if skill_template_content?(text)
        scrubbed_text(text)
      end
      parts.join(" ").presence
    end
  end

  # Scrub credentials from `text` when the feature flag is on (default).
  # Applied to the free-text paths that survive condensing — user message text
  # and assistant text blocks — so a credential pasted into prose can't leave
  # the machine. (tool_use inputs are scrubbed inside ToolInputSummarizer;
  # tool_result OUTPUT bodies are dropped entirely by tool_result_marker.)
  # `SecretScrubber.scrub` is fail-closed — any error returns "" rather than
  # pass the raw string through.
  def scrubbed_text(text)
    return text unless SecretScrubber.enabled?
    SecretScrubber.scrub(text)
  end

  # Split the session's message timestamps into active intervals using
  # TranscriptSession::PARALLELISM_GAP_MINUTES (15min). Returns an array of
  # [start_ts, end_ts] pairs as ISO8601 strings for human-readable JSONB
  # storage. Parallelism overlap math (ParallelismAnalyzer) converts back to
  # Time via Time.parse. Empty if no timestamps survived parsing.
  def compute_active_time_windows
    ActiveTimeWindowsCalculator.from_timestamps(@all_message_timestamps)
  end

  def extract_and_save_signals
    return if @raw_user_messages.blank?

    signals = SessionSignalExtractor.extract(
      user_messages: @raw_user_messages,
      first_timestamp: @first_timestamp,
      last_timestamp: @last_timestamp,
      message_timestamps: @all_message_timestamps,
      tool_count: @tool_count,
      assistant_count: @assistant_count,
      git_commits: @git_commits,
      tools_used: @tools_used,
      pr_diff: transcript_session.pr_diff,
      events: @event_extractor.events
    )

    highlights = @raw_user_messages
      .select { |m| m[:word_count] > 15 }
      .map { |m| m[:text].truncate(2_000) }
      .first(50)
      .join("\n---\n")

    transcript_session.update!(
      session_signals: signals,
      user_highlights: highlights.presence
    )
  end

  def persist_plan_files
    return if @event_extractor.plan_files.blank?

    @event_extractor.plan_files.each do |filename, versions|
      version_num = 0
      versions.each do |entry|
        next if entry[:edit]
        version_num += 1
        transcript_session.plan_files.create!(
          filename: filename,
          full_path: entry[:full_path],
          content: entry[:content],
          version: version_num,
          write_timestamp: entry[:timestamp]
        )
      end
    end

    Rails.logger.info("TranscriptChunker: session=#{transcript_session.session_id} plan_files=#{@event_extractor.plan_files.keys}")
  end
end
