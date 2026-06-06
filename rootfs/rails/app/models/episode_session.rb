class EpisodeSession < ApplicationRecord
  belongs_to :episode
  belongs_to :transcript_session

  LINK_TYPES = %w[pr_match sha_match branch_match timestamp_overlap].freeze
  validates :link_type, inclusion: { in: LINK_TYPES }, allow_nil: true
end
