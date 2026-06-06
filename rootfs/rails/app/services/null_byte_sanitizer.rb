# Strips NUL bytes ("\x00", U+0000) from every String in a nested Hash / Array
# structure, returning a sanitized copy. PostgreSQL cannot store a NUL byte in a
# jsonb or text column — a payload carrying one raises
# `PG::UntranslatableCharacter: unsupported Unicode escape sequence` on INSERT,
# which surfaces as an HTTP 500 at the ingestion endpoints. JSON.parse decodes a
# wire `\x00` escape into a real NUL byte, so client-submitted text (decision
# snippets, session summaries, LLM responses) can carry one through to the DB.
#
# This is a pure function: it never mutates its argument. Callers depend on that
# (e.g. ClientPipeline sanitizes `@results` before both the upload POST and the
# failed-upload stash — an in-place mutation would corrupt the stashed copy).
#
# NUL-only by design. Invalid UTF-8 is a different Postgres error class
# (PG::CharacterNotInRepertoire) and `String#scrub` mutates content with the
# replacement character — out of scope here.
#
# The Symbol branch exists for the client-side payload, whose top-level keys are
# symbols; the server `/api/v1/results` path sanitizes the parsed JSON before
# `deep_symbolize_keys`, so its keys are still strings.
#
# Mirrors the existing `String#delete("\x00")` idiom in TranscriptChunker and the
# recursive walk in PaxelRetroScrub#walk_jsonb.
module NullByteSanitizer
  NULL_BYTE = "\x00"

  module_function

  def sanitize(obj)
    case obj
    when String
      obj.include?(NULL_BYTE) ? obj.delete(NULL_BYTE) : obj
    when Symbol
      str = obj.to_s
      str.include?(NULL_BYTE) ? str.delete(NULL_BYTE).to_sym : obj
    when Array
      obj.map { |v| sanitize(v) }
    when Hash
      obj.each_with_object({}) { |(k, v), h| h[sanitize(k)] = sanitize(v) }
    else
      obj
    end
  end
end
