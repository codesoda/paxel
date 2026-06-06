class CommitGroup < ApplicationRecord
  belongs_to :project
  has_many :commit_group_sessions, dependent: :destroy
  has_many :transcript_sessions, through: :commit_group_sessions
  has_many :episode_commit_groups, dependent: :destroy
  has_many :episodes, through: :episode_commit_groups

  STATUSES = %w[pending reviewing scoring complete failed no_diff].freeze
  GROUP_TYPES = %w[pr commit_cluster single_commit].freeze

  validates :group_type, inclusion: { in: GROUP_TYPES }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
end
