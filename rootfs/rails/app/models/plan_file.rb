class PlanFile < ApplicationRecord
  belongs_to :transcript_session

  validates :filename, presence: true
  validates :full_path, presence: true
  validates :content, presence: true
  validates :version, presence: true,
            uniqueness: { scope: [ :transcript_session_id, :filename ] }

  scope :latest_versions, -> {
    where("version = (SELECT MAX(pf2.version) FROM plan_files pf2
           WHERE pf2.transcript_session_id = plan_files.transcript_session_id
           AND pf2.filename = plan_files.filename)")
  }
  scope :by_version, -> { order(:version) }
  scope :for_file, ->(name) { where(filename: name) }
end
