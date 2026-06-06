class DecisionEdge < ApplicationRecord
  belongs_to :source_decision, class_name: "Decision"
  belongs_to :target_decision, class_name: "Decision"

  EDGE_TYPES = %w[enables contradicts revisits supersedes compounds].freeze
  DISCOVERERS = %w[in_session cross_session periodic strategic].freeze

  validates :edge_type, inclusion: { in: EDGE_TYPES }
  validates :discovered_by, inclusion: { in: DISCOVERERS }
  validates :confidence, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
  validate :source_and_target_differ

  private

  def source_and_target_differ
    if source_decision_id == target_decision_id
      errors.add(:target_decision_id, "must differ from source decision")
    end
  end
end
