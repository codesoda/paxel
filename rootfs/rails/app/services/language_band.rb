# Maps overall score to a band + allowed narrative vocabulary.
# compute() returns TWO bands: "band" is the pure score tier (display + the YC
# projection — monotonic in score), while "vocabulary_band" is demoted one tier
# when confidence < 0.70 and gates ONLY the narrative vocabulary. Do not use
# "vocabulary_band" for any user-facing/projected performance tier.
class LanguageBand
  BANDS = [
    { name: "WEAK",     range: (0...4),    vocabulary: %w[limited\ evidence early\ stage developing needs\ work] },
    { name: "LIMITED",  range: (4...6),    vocabulary: %w[shows\ potential competent functional adequate] },
    { name: "STRONG",   range: (6...8),    vocabulary: %w[strong promising above\ average interesting solid] },
    { name: "ELITE",    range: (8...9),    vocabulary: %w[elite rare\ combination exceptional unusually\ strong] },
    { name: "EXEMPLAR", range: (9..10),    vocabulary: %w[superlative frontier exemplar target\ phenotype benchmark] }
  ].freeze

  BANNED_BELOW = {
    "WEAK"     => %w[strong impressive exceptional elite rare exemplar superlative frontier],
    "LIMITED"  => %w[strong impressive exceptional elite rare exemplar superlative frontier],
    "STRONG"   => %w[elite rare exceptional exemplar superlative frontier target\ phenotype],
    "ELITE"    => %w[superlative frontier exemplar target\ phenotype],
    "EXEMPLAR" => []
  }.freeze

  def self.compute(score, confidence: 0.90)
    score_band = band_for_score(score)

    # Confidence < 0.70 demotes the band ONE tier -- but ONLY for narrative
    # VOCABULARY gating (so thin-evidence reports don't get "elite" prose). It
    # must NOT change the displayed/projected performance tier, which has to stay
    # monotonic in the score (an 8.26 can't read STRONG while an 8.01 reads ELITE).
    # So: "band" is the pure score tier (display + YC projection); "vocabulary_band"
    # is the confidence-demoted tier (narrative vocabulary only).
    vocabulary_band = confidence < 0.70 ? demote_band(score_band) : score_band

    {
      "band" => score_band,
      "vocabulary_band" => vocabulary_band,
      "vocabulary" => vocabulary_for(vocabulary_band),
      "banned" => BANNED_BELOW[vocabulary_band] || []
    }
  end

  def self.band_for_score(score)
    score = score.to_f
    BANDS.each do |b|
      return b[:name] if b[:range].cover?(score)
    end
    score >= 9 ? "EXEMPLAR" : "WEAK"
  end

  def self.vocabulary_for(band)
    BANDS.find { |b| b[:name] == band }&.dig(:vocabulary) || []
  end

  def self.demote_band(band)
    names = BANDS.map { |b| b[:name] }
    idx = names.index(band) || 0
    names[[ idx - 1, 0 ].max]
  end
end
