# Generates a SQLite-compatible schema from the server's Postgres schema.rb.
#
# Transformations:
#   - Filters to client-needed tables only
#   - Replaces UUID primary keys with string IDs (Ruby-generated)
#   - Converts jsonb → json (SQLite treats both as text)
#   - Strips Postgres extensions (pgcrypto, vector, plpgsql)
#   - Removes vector columns, GIN/HNSW indexes, partial indexes
#   - Removes array columns (tools_used)
#   - Drops foreign keys (SQLite has limited FK support, not needed for client)
class ClientSchemaGenerator
  # Tables the client pipeline needs:
  #   uploads        - tracks the processing run
  #   projects       - groups sessions by repo
  #   transcript_sessions - core session data
  #   chunks         - session chunks for EpisodeSummarizer
  #   episodes       - episode groupings from EpisodeLinker
  #   episode_sessions - episode-session join table
  #   llm_calls      - records every AnthropicClient call for cost/latency stats
  CLIENT_TABLES = %w[
    uploads
    projects
    transcript_sessions
    chunks
    episodes
    episode_sessions
    commit_groups
    commit_group_sessions
    episode_commit_groups
    decisions
    repositories
    outcome_analyses
    plan_files
    llm_calls
  ].freeze

  attr_reader :table_count

  def initialize(source:, output:)
    @source = source
    @output = output
    @table_count = 0
  end

  def run
    source_lines = File.readlines(@source)
    output_lines = generate(source_lines)
    File.write(@output, output_lines.join)
  end

  private

  def generate(lines)
    result = []
    result << "# Auto-generated from db/schema.rb by `rake client:generate_schema`\n"
    result << "# DO NOT EDIT — changes will be overwritten.\n"
    result << "#\n"
    result << "# SQLite-compatible subset for the Docker client container.\n"
    result << "# Run with: RAILS_ENV=client rails db:schema:load\n"
    result << "\n"

    version = extract_version(lines)
    result << "ActiveRecord::Schema[8.1].define(version: #{version}) do\n"

    tables = extract_tables(lines)
    tables.each do |table|
      next unless CLIENT_TABLES.include?(table[:name])
      @table_count += 1
      result.concat(convert_table(table))
      result << "\n"
    end

    result << "end\n"
    result
  end

  def extract_version(lines)
    lines.each do |line|
      if line =~ /define\(version:\s*(.+?)\)\s*do/
        return $1
      end
    end
    "0"
  end

  def extract_tables(lines)
    tables = []
    current_table = nil

    lines.each do |line|
      if line =~ /create_table\s+"(\w+)"/
        current_table = { name: $1, lines: [ line ], columns: [], indexes: [] }
      elsif current_table
        current_table[:lines] << line
        if line.strip == "end"
          tables << current_table
          current_table = nil
        end
      end
    end

    tables
  end

  def convert_table(table)
    result = []
    name = table[:name]

    # Rewrite create_table line: replace UUID PKs with string
    create_line = table[:lines].first
    if create_line.include?("id: :uuid")
      create_line = create_line
        .gsub("id: :uuid", "id: :string")
        .gsub(/,?\s*default:\s*->\s*\{[^}]*\}/, "")
    end
    result << create_line

    # Process columns and indexes
    table[:lines][1..-2].each do |line|
      converted = convert_line(line, name)
      result << converted if converted
    end

    result << table[:lines].last # closing "end"
    result
  end

  def convert_line(line, table_name)
    stripped = line.strip

    # Skip vector columns
    return nil if stripped.include?("t.vector ")

    # Skip GIN and HNSW indexes
    return nil if stripped.include?("using: :gin")
    return nil if stripped.include?("using: :hnsw")

    # Skip partial indexes (where clause)
    return nil if stripped.include?(", where:")

    # Convert array columns to JSON (SQLite stores as text)
    if stripped.include?(", array: true")
      line = line.dup
      line.gsub!(/, default: \[\], array: true/, "")
      line.gsub!(/, array: true/, "")
      line.gsub!("t.string ", "t.json ")
      return line
    end

    line = line.dup

    # Convert jsonb to json
    line.gsub!("t.jsonb ", "t.json ")

    # Convert UUID references to string
    line.gsub!("t.uuid ", "t.string ")

    # Convert opclass options (leftover from vector indexes)
    line.gsub!(/, opclass: :\w+/, "")

    line
  end
end
