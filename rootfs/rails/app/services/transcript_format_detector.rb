# Detects which AI coding CLI generated a transcript file.
#
# Reads the first few lines and returns :claude_code, :codex_cli, or :gemini_cli.
# Used by TranscriptChunker to route to the correct normalizer and by
# TranscriptDiscoverer to set agent_type at discovery time.
#
class TranscriptFormatDetector
  FORMATS = %i[claude_code codex_cli gemini_cli opencode].freeze

  def self.detect(file_path)
    new(file_path).detect
  end

  def initialize(file_path)
    @file_path = file_path
  end

  def detect
    # For .json files, try full-file parse (Gemini old format)
    if @file_path.to_s.end_with?(".json")
      return detect_json_format
    end

    lines = read_first_lines(3)
    return :claude_code if lines.empty?

    # Check first line for format-specific markers
    first = parse_json(lines[0])
    return :claude_code unless first

    # Codex: session_meta with originator containing "codex"
    if codex_format?(first)
      return :codex_cli
    end

    # Gemini: session_metadata type or user/gemini messages
    if gemini_format?(first, lines)
      return :gemini_cli
    end

    # opencode: synthetic marker we emit ourselves on line 1 of every session
    # file (extract_opencode_db). Deterministic + collision-free — no other tool
    # emits "opencode_session_meta".
    if opencode_format?(first)
      return :opencode
    end

    # Claude Code: type is "user" or "assistant" with a "message" hash
    :claude_code
  end

  private

  def opencode_format?(entry)
    entry.is_a?(Hash) && entry["type"] == "opencode_session_meta"
  end

  def detect_json_format
    content = File.read(@file_path, encoding: "utf-8")
    data = JSON.parse(content)
    messages = data["messages"] || data["history"] || []
    if messages.any? { |m| m.is_a?(Hash) && %w[user gemini model].include?(m["type"]) }
      return :gemini_cli
    end
    :claude_code
  rescue JSON::ParserError, Errno::EACCES, Errno::ENOENT => e
    Rails.logger.warn("TranscriptFormatDetector: cannot parse JSON #{@file_path}: #{e.message}")
    :claude_code
  end

  def codex_format?(entry)
    return false unless entry.is_a?(Hash) # non-Hash first line (bare array/scalar) -> not a codex header (PAXEL-CLIENT-1J)
    # New format (v0.115+): top-level type is "session_meta".
    # Claude Code never emits session_meta; Gemini uses "session_metadata" (plural).
    # The originator field is set by the LAUNCHING tool ("codex_cli_rs", "Claude Code",
    # "codex_exec", "codex-tui", ...) so we cannot gate detection on it — Codex
    # launched from Claude Code via codex-companion writes originator="Claude Code".
    return true if entry["type"] == "session_meta"

    # Old format (v0.92): raw metadata with no wrapping type. Pre-cross-tool era,
    # originator was reliably "codex_cli_rs" — substring check is still safe here.
    entry["originator"].to_s.include?("codex")
  end

  def gemini_format?(entry, lines)
    return false unless entry.is_a?(Hash) # non-Hash line 0 = corrupt file -> not a Gemini header (entry["sessionId"] etc. would raise); route to claude_code default (PAXEL-CLIENT-1J)
    # Current format (chatRecordingService.ts): line 1 is a bare session header
    # with BOTH sessionId and projectHash and NO "type". The AND is load-bearing —
    # Claude Code session lines carry sessionId but never projectHash, so keying on
    # sessionId alone would misdetect every Claude session as Gemini. The
    # !key?("type") guard keeps this aligned with the discoverer's header branch and
    # narrows it to the typeless header line (a typed line is matched separately).
    return true if entry["sessionId"].is_a?(String) && entry["projectHash"].is_a?(String) && !entry.key?("type")

    # Legacy JSONL: first entry has type "session_metadata"
    return true if entry["type"] == "session_metadata"

    # Check for "gemini" type (unique to Gemini CLI, never appears in Claude)
    return true if entry["type"] == "gemini"

    # Check subsequent lines for gemini-specific "gemini" type
    # NOTE: "user" type alone is ambiguous (Claude also uses it), so only match "gemini"
    lines[1..].compact.each do |line|
      parsed = parse_json(line)
      next unless parsed.is_a?(Hash) # a bare array/scalar JSONL line parses non-nil but parsed["type"] would raise TypeError (PAXEL-CLIENT-1J)
      return true if parsed["type"] == "gemini"
    end

    false
  end

  def read_first_lines(count)
    lines = []
    File.foreach(@file_path) do |line|
      stripped = line.scrub.strip
      next if stripped.empty?
      lines << stripped
      break if lines.size >= count
    end
    lines
  rescue Errno::EACCES, Errno::ENOENT => e
    Rails.logger.warn("TranscriptFormatDetector: cannot read #{@file_path}: #{e.message}")
    []
  end

  def parse_json(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end
end
