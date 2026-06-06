module JsonExtractor
  extend ActiveSupport::Concern

  SCORE_DIMENSIONS = %w[architecture code_quality testing design_product problem_solving tool_mastery pragmatism].freeze

  def extract_json(text, required_key: nil)
    return nil if text.nil? || text.strip.empty?

    # Step 1: strip code fences and try direct parse
    cleaned = text.gsub(/```json\s*/i, "").gsub(/```\s*/, "").strip
    begin
      parsed = JSON.parse(cleaned)
      if parsed.is_a?(Hash) && (required_key.nil? || parsed.key?(required_key))
        return parsed
      end
    rescue JSON::ParserError
      # fall through to embedded extraction
    end

    # Step 2: find outermost JSON object via brace-depth scan
    find_json_object(text, required_key: required_key)
  end

  def find_json_object(text, required_key: nil)
    start_idx = text.index("{")
    return nil unless start_idx

    depth = 0
    in_string = false
    escape_next = false

    (start_idx...text.length).each do |i|
      char = text[i]
      if escape_next
        escape_next = false
        next
      end
      case char
      when "\\" then escape_next = true if in_string
      when '"'  then in_string = !in_string
      when "{"  then depth += 1 unless in_string
      when "}"
        unless in_string
          depth -= 1
          if depth == 0
            candidate = text[start_idx..i]
            begin
              parsed = JSON.parse(candidate)
              if parsed.is_a?(Hash) && (required_key.nil? || parsed.key?(required_key))
                return parsed
              end
            rescue JSON::ParserError
              # not valid JSON, try next opening brace
            end
            # Reset to find next candidate
            next_start = text.index("{", i + 1)
            return nil unless next_start
            start_idx = next_start
            depth = 0
          end
        end
      end
    end
    nil
  end

  def extract_scores(text)
    return nil if text.blank?

    # Try to find ```json ... ``` block first
    json_match = text.match(/```json\s*(\{.*?\})\s*```/m)
    if json_match
      begin
        raw = JSON.parse(json_match[1])
        scores = raw["scores"] || raw
        return validate_scores(scores)
      rescue JSON::ParserError
        # fall through to brace-depth scanner
      end
    end

    # Try direct JSON parse (scoring prompt asks for raw JSON, no fences)
    begin
      raw = JSON.parse(text.strip)
      scores = raw["scores"] || raw
      return validate_scores(scores)
    rescue JSON::ParserError
      # fall through to brace-depth scanner
    end

    # Fallback: use brace-depth scanner
    parsed = extract_json(text, required_key: "scores")
    return nil unless parsed
    validate_scores(parsed["scores"] || parsed)
  rescue => e
    Rails.logger.warn("JsonExtractor: Score extraction failed: #{e.message}")
    nil
  end

  def validate_scores(scores)
    return nil unless scores.is_a?(Hash)
    validated = {}
    SCORE_DIMENSIONS.each do |dim|
      entry = scores[dim]
      next unless entry.is_a?(Hash)
      score = entry["score"]
      confidence = entry["confidence"]
      score = nil unless score.is_a?(Numeric) && score.between?(1, 10)
      confidence = 0.0 unless confidence.is_a?(Numeric) && confidence.between?(0.0, 1.0)
      validated[dim] = {
        "score" => score,
        "confidence" => confidence.to_f.round(2),
        "reason" => entry["reason"].to_s.truncate(200)
      }
    end
    validated.presence
  end
end
