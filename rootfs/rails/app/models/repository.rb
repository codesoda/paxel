class Repository < ApplicationRecord
  has_many :projects, dependent: :nullify
  has_many :decisions, dependent: :destroy
  has_many :committers, dependent: :destroy
  has_many :committer_identities, dependent: :destroy
  has_many :users, through: :committers

  validates :git_remote, presence: true, uniqueness: true

  before_validation :normalize_git_remote, on: :create

  # Normalize a git remote URL to a canonical form:
  #   git@github.com:foo/bar.git  -> github.com/foo/bar
  #   https://github.com/foo/bar.git -> github.com/foo/bar
  #   ssh://git@github.com/foo/bar -> github.com/foo/bar
  def self.normalize_remote(url)
    return nil if url.blank?

    normalized = url.to_s.strip
    # Strip ssh:// prefix
    normalized = normalized.sub(%r{^ssh://}, "")
    # Strip https?://
    normalized = normalized.sub(%r{^https?://}, "")
    # Convert git@host:path to host/path
    normalized = normalized.sub(/^git@([^:]+):/, '\1/')
    # Strip trailing .git
    normalized = normalized.sub(/\.git$/, "")
    # Strip trailing slashes
    normalized = normalized.chomp("/")
    # Strip leading user@ (e.g., git@)
    normalized = normalized.sub(/^[^@]+@/, "")

    normalized.presence
  end

  # Find or create a Repository for a given git_remote URL.
  # Handles race conditions from concurrent uploads.
  def self.find_or_create_for(git_remote)
    normalized = normalize_remote(git_remote)
    return nil if normalized.blank?

    find_or_create_by!(git_remote: normalized) do |repo|
      repo.name = extract_name(normalized)
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(git_remote: normalized)
  end

  def self.extract_name(normalized_remote)
    normalized_remote.split("/").last.presence || normalized_remote
  end

  private

  def normalize_git_remote
    self.git_remote = self.class.normalize_remote(git_remote) if git_remote.present?
  end
end
