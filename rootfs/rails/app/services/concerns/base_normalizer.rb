# Base interface for transcript normalizers.
#
# Each AI coding CLI stores transcripts differently. Normalizers convert
# CLI-specific JSONL/JSON into Claude Code's canonical format so the
# downstream pipeline (chunking, event extraction, narratives, scoring)
# works unchanged.
#
# To add a new CLI:
#   1. Create app/services/<cli>_normalizer.rb including BaseNormalizer
#   2. Implement #normalize(metadata:) returning Array<Hash>
#   3. Add detection case to TranscriptFormatDetector
#   4. Add upload script discovery function
#
# Canonical entry format (each Hash in the returned array):
#   { "type"      => "user" | "assistant",
#     "message"   => { "role" => "user"|"assistant",
#                      "content" => String | Array<Hash> },
#     "timestamp" => "ISO8601 string",
#     "model"     => "model-name" (optional) }
#
# Content blocks (when Array):
#   { "type" => "text",      "text" => "..." }
#   { "type" => "tool_use",  "name" => "Bash", "input" => { "command" => "..." } }
#   { "type" => "tool_result", "content" => "..." }
#   { "type" => "thinking",  "thinking" => "..." }
#
module BaseNormalizer
  extend ActiveSupport::Concern

  included do
    attr_reader :jsonl_path
  end

  def initialize(jsonl_path)
    @jsonl_path = jsonl_path
  end

  # Subclasses must implement this.
  # Returns Array<Hash> of canonical entries.
  # Populates metadata hash with: session_id, git_branch, git_remote, cwd, model, agent_type
  # Error handling: skip malformed entries with Rails.logger.warn, never raise.
  def normalize(metadata: {})
    raise NotImplementedError, "#{self.class}#normalize must be implemented"
  end
end
