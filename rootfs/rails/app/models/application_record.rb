class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # SQLite client schema uses id: :string (no auto-UUID like Postgres).
  # Generate UUIDs for all models when running on SQLite.
  before_create :generate_id_if_sqlite, if: -> { self.class.connection.adapter_name == "SQLite" && id.blank? }

  private

  def generate_id_if_sqlite
    self.id = SecureRandom.uuid
  end
end
