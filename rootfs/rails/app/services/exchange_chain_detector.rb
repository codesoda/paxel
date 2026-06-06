# Detects exchange chains: sequences of 3+ decisions within a session
# where each builds on the prior (cosine similarity >= 0.6).
#
# Detection flow:
#   1. Clear prior chain data for this upload (idempotent)
#   2. Group decisions by session, sort by event_index
#   3. Greedy chain building: adjacent decisions connected if
#      both have embeddings AND cosine_similarity >= SIMILARITY_THRESHOLD
#      AND event gap <= MAX_EVENT_GAP
#   4. Persist chains of length >= MIN_CHAIN_LENGTH with shared UUID
#   5. Create "compounds" edges between consecutive chain members
#
# Pattern: self.detect! → new.detect! (idempotent entry point)
#
class ExchangeChainDetector
  SIMILARITY_THRESHOLD = 0.6
  MAX_EVENT_GAP = 20
  MIN_CHAIN_LENGTH = 3

  def self.detect!(upload)
    new(upload).detect!
  end

  def initialize(upload)
    @upload = upload
  end

  def detect!
    clear_prior_data!

    chain_count = 0
    decisions_by_session = @upload.decisions.order(:event_index).group_by(&:transcript_session_id)

    decisions_by_session.each_value do |decisions|
      next if decisions.size < MIN_CHAIN_LENGTH

      chains = build_chains(decisions)
      chains.each do |chain|
        persist_chain(chain)
        chain_count += 1
      end
    end

    chain_count
  end

  private

  def clear_prior_data!
    @upload.decisions.update_all(exchange_chain_id: nil, chain_position: nil)
    DecisionEdge.where(
      source_decision: @upload.decisions,
      edge_type: "compounds",
      discovered_by: "in_session"
    ).delete_all
  end

  def build_chains(decisions)
    chains = []
    current_chain = [ decisions.first ]

    decisions.each_cons(2) do |prev, curr|
      if connected?(prev, curr)
        current_chain << curr
      else
        chains << current_chain if current_chain.size >= MIN_CHAIN_LENGTH
        current_chain = [ curr ]
      end
    end
    chains << current_chain if current_chain.size >= MIN_CHAIN_LENGTH

    chains
  end

  def connected?(a, b)
    return false if (b.event_index - a.event_index) > MAX_EVENT_GAP
    return false if a.embedding.nil? || b.embedding.nil?
    return false if a.embedding.size != b.embedding.size

    cosine_similarity(a.embedding, b.embedding) >= SIMILARITY_THRESHOLD
  end

  def cosine_similarity(vec_a, vec_b)
    dot = 0.0
    mag_a = 0.0
    mag_b = 0.0

    vec_a.each_with_index do |a_val, i|
      b_val = vec_b[i]
      dot += a_val * b_val
      mag_a += a_val * a_val
      mag_b += b_val * b_val
    end

    magnitude = Math.sqrt(mag_a) * Math.sqrt(mag_b)
    return 0.0 if magnitude.zero?
    dot / magnitude
  end

  def persist_chain(chain)
    chain_id = SecureRandom.uuid

    chain.each_with_index do |decision, i|
      decision.update_columns(exchange_chain_id: chain_id, chain_position: i + 1)
    end

    chain.each_cons(2) do |source, target|
      DecisionEdge.find_or_create_by!(
        source_decision: source,
        target_decision: target,
        edge_type: "compounds"
      ) do |edge|
        edge.confidence = 0.8
        edge.discovered_by = "in_session"
      end
    end
  end
end
