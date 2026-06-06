namespace :client do
  desc "Generate SQLite-compatible client_schema.rb from server schema.rb"
  task generate_schema: :environment do
    generator = ClientSchemaGenerator.new(
      source: Rails.root.join("db/schema.rb"),
      output: Rails.root.join("db/client_schema.rb")
    )
    generator.run
    puts "Generated db/client_schema.rb (#{generator.table_count} tables)"
  end
end
