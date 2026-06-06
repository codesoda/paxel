class Project < ApplicationRecord
  belongs_to :upload
  belongs_to :repository, optional: true
  has_many :transcript_sessions, dependent: :destroy
  has_many :commit_groups, dependent: :destroy

  validates :encoded_name, presence: true

  before_validation :set_display_name, on: :create

  private

  def set_display_name
    return if display_name.present?
    if git_remote.present?
      name = git_remote.sub(/\.git$/, "").split(%r{[/:]}).last
      self.display_name = name.presence || encoded_name.split("-").last
    elsif encoded_name.present?
      self.display_name = encoded_name.split("-").last
    end
  end
end
