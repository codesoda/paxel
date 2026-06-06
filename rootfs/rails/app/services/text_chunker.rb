# Recursive text chunker ported from Chonkie's RecursiveChunker.
#
# Splits text hierarchically using structural delimiters (paragraphs -> sentences
# -> clauses -> words -> hard split), then greedily merges adjacent pieces that fit
# within chunk_size. Optionally prepends trailing context from the previous chunk
# as sentence-aware overlap.
#
# Invariants:
#   - Lossless: chunks.join("") == original_text (no text lost or duplicated) when overlap=0
#   - Bounded: each chunk <= chunk_size words (after overlap prepend)
#   - Graceful: falls through levels until text fits; Level 4 = hard word split
#
class TextChunker
  DEFAULT_CHUNK_SIZE = 300
  DEFAULT_CHUNK_OVERLAP = 50

  # 5-level delimiter hierarchy (most structural -> least)
  LEVELS = [
    { delimiters: [ "\n\n" ] },                                    # Level 0: paragraphs
    { delimiters: [ "\n" ] },                                      # Level 1: line breaks
    { delimiters: [ ". ", "! ", "? ", ".\n", "!\n", "?\n" ] },     # Level 2: sentences
    { delimiters: [ "; ", ": ", ", ", " — ", " - " ] },            # Level 3: clauses
    { whitespace: true }                                        # Level 4: words
  ].freeze

  class << self
    # Split text into chunks respecting structural boundaries.
    #
    # @param text [String] the text to chunk
    # @param chunk_size [Integer] max words per chunk (default: 300)
    # @param chunk_overlap [Integer] words of trailing context to prepend (default: 50)
    # @return [Array<String>] array of chunk strings; chunks.join("") == text when overlap=0
    def chunk(text, chunk_size: nil, chunk_overlap: nil)
      chunk_size ||= DEFAULT_CHUNK_SIZE
      chunk_overlap ||= DEFAULT_CHUNK_OVERLAP

      return [] if text.nil? || text.strip.empty?

      merge_target = [ chunk_size, 1 ].max

      pieces = recursive_split(text, 0, merge_target)

      return pieces if chunk_overlap == 0 || pieces.length <= 1

      apply_overlap(pieces, chunk_overlap)
    end

    private

    # Recursively split text at the current delimiter level, merge adjacent pieces
    # that fit, and recurse on oversized groups.
    def recursive_split(text, level, merge_target)
      return [ text ] if word_count(text) <= merge_target
      return hard_split(text, merge_target) if level >= LEVELS.length

      rule = LEVELS[level]

      pieces = if rule[:whitespace]
        split_on_whitespace(text)
      else
        split_at_delimiters(text, rule[:delimiters])
      end

      # If splitting produced nothing useful, try next level
      return recursive_split(text, level + 1, merge_target) if pieces.length <= 1

      merged = greedy_merge(pieces, merge_target)

      merged.flat_map do |group|
        if word_count(group) <= merge_target
          [ group ]
        else
          recursive_split(group, level + 1, merge_target)
        end
      end
    end

    # Split text at delimiters, keeping the delimiter attached to the preceding piece.
    # Ensures lossless reconstruction: pieces.join("") == text
    def split_at_delimiters(text, delimiters)
      pieces = []
      remaining = text

      while remaining && !remaining.empty?
        # Find the earliest delimiter match
        earliest_pos = nil
        earliest_delim = nil

        delimiters.each do |delim|
          pos = remaining.index(delim)
          if pos && (earliest_pos.nil? || pos < earliest_pos)
            earliest_pos = pos
            earliest_delim = delim
          end
        end

        if earliest_pos
          # Include everything up to and including the delimiter in this piece
          piece = remaining[0...(earliest_pos + earliest_delim.length)]
          pieces << piece unless piece.empty?
          remaining = remaining[(earliest_pos + earliest_delim.length)..]
        else
          # No more delimiters - remainder is the last piece
          pieces << remaining unless remaining.empty?
          remaining = nil
        end
      end

      pieces
    end

    # Split on whitespace, keeping the whitespace attached to the preceding word.
    # "hello world  test" -> ["hello ", "world  ", "test"]
    def split_on_whitespace(text)
      text.scan(/\S+\s*/)
    end

    # Greedily merge adjacent pieces that fit within merge_target words.
    def greedy_merge(pieces, merge_target)
      groups = []
      current = +""

      pieces.each do |piece|
        candidate = current + piece
        if word_count(candidate) <= merge_target
          current = candidate
        else
          groups << current unless current.empty?
          current = +piece.dup
        end
      end

      groups << current unless current.empty?
      groups
    end

    # Hard split by words when all delimiter levels are exhausted.
    def hard_split(text, merge_target)
      tokens = split_on_whitespace(text)
      groups = []
      current = +""
      current_words = 0

      tokens.each do |token|
        if current_words >= merge_target && current_words > 0
          groups << current
          current = +""
          current_words = 0
        end
        current << token
        current_words += 1
      end

      groups << current unless current.empty?
      groups
    end

    # Prepend trailing context from previous chunk as sentence-aware overlap.
    def apply_overlap(pieces, overlap_words)
      result = [ pieces.first ]

      (1...pieces.length).each do |i|
        context = extract_trailing_context(pieces[i - 1], overlap_words)
        result << context + pieces[i]
      end

      result
    end

    # Extract trailing context from a piece, preferring sentence boundaries.
    def extract_trailing_context(text, target_words)
      words = text.split(/\s+/)
      return text if words.length <= target_words

      # Take last N words
      tail = words.last(target_words).join(" ")

      # Try to start at a sentence boundary (after . ! ?)
      sentence_start = tail.index(/(?<=[.!?])\s+/)
      if sentence_start
        tail = tail[(sentence_start + 1)..]&.lstrip || tail
      end

      tail + " "
    end

    def word_count(text)
      text.split(/\s+/).length
    end
  end
end
