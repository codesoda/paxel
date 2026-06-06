class EpisodeCommitGroup < ApplicationRecord
  belongs_to :episode
  belongs_to :commit_group

  LINK_TYPES = %w[pr_match sha_match branch_match timestamp_overlap direct].freeze
  validates :link_type, inclusion: { in: LINK_TYPES }, allow_nil: true
end
