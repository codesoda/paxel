class Chunk < ApplicationRecord
  belongs_to :transcript_session

  STATUSES = %w[pending analyzed failed].freeze

  validates :position, presence: true
  validates :content, presence: true
  validates :status, inclusion: { in: STATUSES }
end
