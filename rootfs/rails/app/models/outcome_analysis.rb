class OutcomeAnalysis < ApplicationRecord
  belongs_to :decision

  ANALYZER_TYPES = %w[in_session cross_session periodic strategic].freeze
  TEMPORAL_LAYERS = %w[immediate short medium long strategic].freeze
  OUTCOME_SIGNALS = %w[positive negative neutral mixed].freeze

  validates :analyzer_type, inclusion: { in: ANALYZER_TYPES }
  validates :temporal_layer, inclusion: { in: TEMPORAL_LAYERS }
  validates :outcome_signal, inclusion: { in: OUTCOME_SIGNALS }
  validates :confidence, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
  validates :analyzed_at, presence: true
end
