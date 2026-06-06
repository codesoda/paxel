# Extracts typed events from JSONL transcript entries.
#
# Called by TranscriptChunker during parse_and_condense.
# Each event has: { type:, timestamp:, ...type-specific fields }
#
# Event types:
#   file_edit      - Edit tool: { path: }
#   file_create    - Write tool: { path: }
#   file_read      - Read tool: { path: }
#   git_commit     - git commit command: { message:, sha: }
#   git_branch_switch - checkout/switch: { branch: }
#   git_push       - git push: {}
#   test_run       - test results: { framework:, passed:, failed:, pending: }
#   error_encountered - error in output: { message: }
#   bash_command   - non-git bash: { command: (truncated) }
#   user_directive - user message text: { text: (truncated) }
#   agent_thinking - thinking block: { text: (truncated) }
#   agent_proposal - agent presenting options/questions: { text:, proposal_type:, option_count: }
#   subagent_dispatch - Task/Agent tool invocation: { subagent_id, description, prompt_hash, run_in_background, tool_use_id }
#   subagent_return   - tool_result matching a prior subagent_dispatch: { tool_use_id, return_text_length, indicates_error }
#
# Contract: events are append-only facts. Adding new types is additive.
# Consumers must handle absence of any type.
#
# Truncation: non-structural events past MAX_EVENTS are dropped silently and
# the session is flagged via quality_flags["session_events_truncated"]=true.
# Structural types (STRUCTURAL_EVENT_TYPES) bypass the cap so orchestration /
# shipping signals never disappear on heavy-swarm uploads (3-5k events).
#
class EventExtractor
  include TranscriptPatterns

  # Bumped 2026-04-23 per TODOS.md v1.0 Tier 1: 1M-token models + cheap
  # storage = keep more of the builder's own words. Old 500/2k limits
  # were calibrated for 100-200K context windows; complex directives and
  # thinking traces routinely exceed them.
  MAX_TEXT_LENGTH = 10_000       # user directives, task prompts, errors
  MAX_BASH_LENGTH = 5_000        # piped commands + curl headers fit here
  MAX_DESCRIPTION_LENGTH = 200   # short subagent description — unchanged
  MAX_THINKING_LENGTH = 20_000   # thinking blocks run 5-50K
  MAX_EVENTS = 3_000
  # Plan-file path signal. Matches Claude Code plan-mode output (.claude/plans/*.md)
  # AND conventional SCREAMING_CASE plan filenames any tool writes (CODEX_PLAN.md,
  # IMPLEMENTATION_PLAN.md, PLAN.md) as a basename. Shared by AgenticProficiencyScorer
  # + PlanModeAdoption via the constant, so broadening here lights up plan detection for
  # every tool's *_PLAN.md. Case-SENSITIVE on the basename on purpose: a lowercase
  # `plan.md` / `test_plan.md` is an ordinary doc, not a deliberate plan artifact.
  PLAN_PATH_PATTERN = %r{(?:\.claude/plans/[^/]+\.md|(?:\A|/)(?:[A-Z][A-Z0-9_]*_)?PLAN\.md)\z}

  # Load-bearing signals bypass MAX_EVENTS. Without this allowlist, a 3500-event
  # heavy-swarm session silently drops dispatch/return/commit events and the
  # scorer sees a phantom "no orchestration" profile.
  STRUCTURAL_EVENT_TYPES = %w[subagent_dispatch subagent_return git_commit].freeze

  # Matches the assistant-side tool_use block name across Claude Code versions
  # and Codex/Gemini variants that also expose a fan-out primitive. The raw
  # tool name shows up in `block["name"]`; unknown names fall through.
  SUBAGENT_TOOL_NAME_PATTERN = /\A(?:Task|Agent|subagent|[Aa]gent_?task)\z/

  attr_reader :events, :detected_branch, :git_commits, :plan_files, :dispatch_count, :truncated

  def initialize
    @events = []
    @git_commits = []
    @detected_branch = nil
    @pending_git_commit = false
    @files_modified = Set.new
    @plan_files = {}
    @dispatch_count = 0
    @return_count = 0
    @run_in_background_count = 0
    @unique_subagent_ids = Set.new
    @dispatched_tool_use_ids = Set.new
    @truncated = false
  end

  # Extract from a tool_use block (assistant message content)
  def extract_from_tool_use(block, timestamp)
    return unless block.is_a?(Hash) && block["type"] == "tool_use"

    tool_name = block["name"]
    input = block["input"]
    return unless tool_name && input.is_a?(Hash)

    case tool_name
    when "Edit"
      path = scrub_path(input["file_path"])
      if path.present?
        add_event("file_edit", timestamp, path: path)
        @files_modified << path
        if path.match?(PLAN_PATH_PATTERN)
          basename = File.basename(path)
          (@plan_files[basename] ||= []) << { edit: true, full_path: path, timestamp: timestamp }
        end
      end
    when "Write"
      path = scrub_path(input["file_path"])
      if path.present?
        add_event("file_create", timestamp, path: path)
        @files_modified << path
        if path.match?(PLAN_PATH_PATTERN)
          content = input["content"]
          if content.present?
            basename = File.basename(path)
            # Phase 2d (2026-04-23): scrub credentials from plan_files content
            # at the persistence boundary so PlanFile.content + EpisodeSummarizer
            # can't re-expose them. DecisionTextRedactor handles code identifiers
            # downstream via regex diarization; SecretScrubber handles API keys,
            # tokens, DB URLs, and env-var secrets that regex redaction misses.
            scrubbed = SecretScrubber.enabled? ? SecretScrubber.scrub(content) : content
            (@plan_files[basename] ||= []) << { content: scrubbed, full_path: path, timestamp: timestamp }
          end
        end
      end
    when "Read"
      path = scrub_path(input["file_path"])
      add_event("file_read", timestamp, path: path) if path.present?
    when /\A[Bb]ash\z/, "exec_command", "shell_command"
      command = input["command"].to_s
      extract_git_from_command(command, timestamp)
      unless command.include?("git ")
        # Redact before retaining — without this, a long retained command could
        # carry credentials into session_events. SecretScrubber handles
        # credentials (the primary risk); DecisionTextRedactor.regex_redact
        # handles code identifiers + file paths. Run SecretScrubber first so its
        # replacement markers ([REDACTED_…]) can't be mistaken for code
        # identifiers by regex_redact.
        scrubbed = SecretScrubber.enabled? ? SecretScrubber.scrub(command) : command
        redacted = DecisionTextRedactor.regex_redact(scrubbed).presence || scrubbed
        add_event("bash_command", timestamp, command: redacted.truncate(MAX_BASH_LENGTH))
      end
    when SUBAGENT_TOOL_NAME_PATTERN
      extract_subagent_dispatch(block, input, timestamp)
    end
  end

  # Extract dispatch metadata from a Task/Agent/subagent tool_use block.
  # Private-in-spirit but called from the public extract_from_tool_use above.
  def extract_subagent_dispatch(block, input, timestamp)
    tool_use_id = block["id"]
    return if tool_use_id.to_s.empty?

    description = input["description"].to_s
    # DecisionTextRedactor.regex_redact handles code identifiers / file paths;
    # SecretScrubber handles credentials if one ever ends up in a short
    # dispatch description. The Task description is typically 3-5 words
    # ("Lint check on changed files") but a model can and occasionally does
    # leak through it, so belt-and-suspenders. SHA1 the raw prompt (never
    # store the prompt).
    scrubbed_desc = SecretScrubber.enabled? ? SecretScrubber.scrub(description) : description
    safe_description = DecisionTextRedactor.regex_redact(scrubbed_desc).presence&.truncate(MAX_DESCRIPTION_LENGTH)
    prompt_hash = Digest::SHA1.hexdigest(input["prompt"].to_s)[0, 12] if input["prompt"].present?
    # `.presence` (not `||`) so `""` falls through to the default. Ruby's `||`
    # treats the empty string as truthy and would store `""` in unique_subagent_ids.
    subagent_id = (input["subagent_type"].presence || input["agent_type"].presence || "general-purpose").to_s.truncate(64)
    # Boolean coerces "true"/"false"/1/0 in addition to native bools — forward-
    # safe if an SDK ever ships run_in_background as a string.
    run_in_background = ActiveModel::Type::Boolean.new.cast(input["run_in_background"]) == true

    @dispatched_tool_use_ids << tool_use_id
    @dispatch_count += 1
    @run_in_background_count += 1 if run_in_background
    @unique_subagent_ids << subagent_id

    add_event("subagent_dispatch", timestamp,
      tool_use_id: tool_use_id,
      subagent_id: subagent_id,
      description: safe_description,
      prompt_hash: prompt_hash,
      run_in_background: run_in_background)
  end

  # Denormalized snapshot of dispatch activity for this session. Written to
  # TranscriptSession#dispatch_metadata so admin pages + ParallelismAnalyzer
  # don't re-walk session_events to count.
  def dispatch_metadata
    {
      "dispatch_count" => @dispatch_count,
      "return_count" => @return_count,
      "run_in_background_count" => @run_in_background_count,
      "unique_subagent_ids" => @unique_subagent_ids.to_a.sort
    }
  end

  # Extract from a tool_result block (user message content)
  def extract_from_tool_result(block, timestamp)
    return unless block.is_a?(Hash) && block["type"] == "tool_result"

    # Emit subagent_return for a tool_result whose tool_use_id matches a prior
    # dispatch. Emitted BEFORE we compose result_text so the return event is
    # captured even when the result body is an error with no prose to inspect.
    tool_use_id = block["tool_use_id"]
    if tool_use_id.present? && @dispatched_tool_use_ids.include?(tool_use_id)
      raw_content = block["content"]
      flattened_text = case raw_content
      when String then raw_content
      when Array then raw_content.filter_map { |b| b["text"].to_s if b.is_a?(Hash) }.join(" ")
      else ""
      end
      is_error = block["is_error"] == true || flattened_text.match?(ERROR_LINE)
      @return_count += 1
      add_event("subagent_return", timestamp,
        tool_use_id: tool_use_id,
        return_text_length: flattened_text.length,
        indicates_error: is_error)
    end

    result_text = case block["content"]
    when String then block["content"]
    when Array
                    block["content"].filter_map { |b| b["text"].to_s if b.is_a?(Hash) }.join(" ")
    else ""
    end
    return if result_text.blank?

    # Git SHA from commit output
    if result_text =~ GIT_COMMIT_OUTPUT
      sha = Regexp.last_match(1)
      if @pending_git_commit && @git_commits.any?
        @git_commits.last["sha"] = sha
        last_commit_event = @events.reverse.find { |e| e[:type] == "git_commit" && e[:sha].nil? }
        last_commit_event[:sha] = sha if last_commit_event
      end
    end

    # Branch from commit output
    if result_text =~ GIT_BRANCH_FROM_COMMIT
      @detected_branch = Regexp.last_match(1)
    end

    # Branch from git status
    if result_text =~ GIT_ON_BRANCH
      @detected_branch = Regexp.last_match(1)
    end

    # Branch from switch
    if result_text =~ GIT_SWITCH_BRANCH
      @detected_branch = Regexp.last_match(1)
    end

    # Test results
    extract_test_results(result_text, timestamp)

    # Errors
    if result_text =~ ERROR_LINE
      error_msg = result_text.lines.find { |l| l =~ ERROR_LINE }&.strip
      if error_msg
        scrubbed_error = SecretScrubber.enabled? ? SecretScrubber.scrub(error_msg) : error_msg
        add_event("error_encountered", timestamp, message: scrubbed_error&.truncate(MAX_TEXT_LENGTH))
      end
    end

    @pending_git_commit = false
  end

  # Extract user directive from user message text
  def extract_user_directive(text, timestamp)
    return if text.blank?
    scrubbed = SecretScrubber.enabled? ? SecretScrubber.scrub(text) : text
    add_event("user_directive", timestamp, text: scrubbed.truncate(MAX_TEXT_LENGTH))
  end

  # Extract agent proposal from assistant text blocks.
  # Detects when the agent is presenting options, asking questions, or discussing tradeoffs.
  def extract_agent_proposal(text, timestamp)
    return if text.blank?

    proposal_type = nil
    option_count = nil

    # Check option patterns first (highest signal)
    OPTION_PATTERNS.each do |pattern|
      if text.match?(pattern)
        proposal_type = "options"
        # Try to count options: numbered lists, lettered options
        option_count = text.scan(/^\s*(?:\d+[.)]\s|\*\s|-\s|[A-C][.)]\s)/m).size
        option_count = text.scan(/(?:option|approach|alternative)\s*(?:\d|[A-C])/i).size if option_count < 2
        option_count = nil if option_count < 2
        break
      end
    end

    # Check question patterns if no option match
    if proposal_type.nil?
      QUESTION_PATTERNS.each do |pattern|
        if text.match?(pattern)
          proposal_type = "question"
          break
        end
      end
    end

    # Check tradeoff patterns
    if proposal_type.nil? && text.match?(/(?:trade-?off|pros?\s+and\s+cons?|versus|vs\.?)\b/i)
      proposal_type = "tradeoff"
    end

    return unless proposal_type

    scrubbed = SecretScrubber.enabled? ? SecretScrubber.scrub(text) : text
    add_event("agent_proposal", timestamp,
      text: scrubbed.truncate(MAX_TEXT_LENGTH),
      proposal_type: proposal_type,
      option_count: option_count)
  end

  # Extract agent thinking block
  def extract_agent_thinking(block, timestamp)
    return unless block.is_a?(Hash) && block["type"] == "thinking"
    text = block["thinking"].to_s
    return if text.blank?
    scrubbed = SecretScrubber.enabled? ? SecretScrubber.scrub(text) : text
    add_event("agent_thinking", timestamp, text: scrubbed.truncate(MAX_THINKING_LENGTH))
  end

  # Summary for logging
  def summary
    counts = @events.group_by { |e| e[:type] }.transform_values(&:count)
    { event_count: @events.size, type_breakdown: counts, files_modified: @files_modified.to_a }
  end

  private

  # Scrub credentials from a file-path string before storing it into
  # `session_events`. Cross-site symmetry with ToolInputSummarizer#safe_path
  # so both sites treat a `/tmp/sk-ant-api03-…/foo.rb`-style path the same
  # way. Structural features used by deterministic scorers
  # (AgenticProficiencyScorer#codify_path?, #test_path?) survive scrub
  # because they look at `/.claude/`, `/test/`, `.rb`, basename — not the
  # full path string.
  def scrub_path(path)
    return path if path.nil? || !SecretScrubber.enabled?
    SecretScrubber.scrub(path.to_s)
  end

  def add_event(type, timestamp, **attrs)
    type_str = type.to_s
    if @events.size >= MAX_EVENTS
      # Structural types (orchestration, shipping) bypass the cap so they
      # remain observable on heavy-swarm sessions. Non-structural types drop
      # silently and we flag the session for admin visibility.
      unless STRUCTURAL_EVENT_TYPES.include?(type_str)
        @truncated = true
        return
      end
    end
    @events << { type: type_str, timestamp: timestamp, **attrs }
  end

  def extract_git_from_command(command, timestamp)
    # Branch from checkout/switch
    if command =~ GIT_CHECKOUT_CMD
      branch = Regexp.last_match(1)
      unless branch.start_with?("-")
        @detected_branch = branch
        add_event("git_branch_switch", timestamp, branch: branch)
      end
    end

    # Push
    if command =~ GIT_PUSH
      add_event("git_push", timestamp)
    end

    # Commit
    return unless command.include?("git commit")

    message = if command =~ GIT_COMMIT_MSG_DOUBLE
                Regexp.last_match(1)
    elsif command =~ GIT_COMMIT_MSG_SINGLE
                Regexp.last_match(1)
    elsif command =~ GIT_COMMIT_MSG_HEREDOC
                Regexp.last_match(1).strip
    else
                "[interactive commit]"
    end

    # Scrub credentials from commit messages — rare but possible if a user
    # pastes a secret into `git commit -m` or has an automated tool do it.
    # Opus review PR #706. Applied to both @git_commits AND the event so
    # the scrub is symmetric across consumers.
    message = SecretScrubber.scrub(message) if SecretScrubber.enabled?

    @git_commits << { "message" => message, "timestamp" => timestamp }
    add_event("git_commit", timestamp, message: message, sha: nil)
    @pending_git_commit = true
  end

  def extract_test_results(text, timestamp)
    # Order matters: check more specific patterns before generic ones.
    # PYTEST_RESULT ("N passed") matches too broadly, so check jest/cargo/rspec first.
    if text =~ RSPEC_RESULT
      add_event("test_run", timestamp,
        framework: "rspec",
        passed: Regexp.last_match(1).to_i - Regexp.last_match(2).to_i,
        failed: Regexp.last_match(2).to_i,
        pending: Regexp.last_match(3)&.to_i || 0)
    elsif text =~ JEST_RESULT
      add_event("test_run", timestamp,
        framework: "jest",
        passed: Regexp.last_match(2).to_i,
        failed: Regexp.last_match(1)&.to_i || 0)
    elsif text =~ CARGO_RESULT
      add_event("test_run", timestamp,
        framework: "cargo",
        passed: Regexp.last_match(1).to_i,
        failed: Regexp.last_match(2).to_i)
    elsif text =~ PYTEST_RESULT
      add_event("test_run", timestamp,
        framework: "pytest",
        passed: Regexp.last_match(1).to_i,
        failed: Regexp.last_match(2)&.to_i || 0)
    end
  end
end
