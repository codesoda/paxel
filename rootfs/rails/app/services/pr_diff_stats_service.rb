class PrDiffStatsService
  TEST_PATH_PATTERN = %r{(?:test|spec|__tests__|_test\.go|_test\.rb|\.test\.|\.spec\.)}i

  def self.parse(diff_text)
    return {} if diff_text.blank?
    new(diff_text).parse
  end

  def initialize(diff_text)
    @diff_text = diff_text
  end

  def parse
    insertions = 0
    deletions = 0
    test_insertions = 0
    test_deletions = 0
    files = Set.new
    current_file_is_test = false

    @diff_text.each_line do |line|
      case line
      when /\A\+\+\+ b\/(.+)/
        file_path = Regexp.last_match(1)
        files << file_path
        current_file_is_test = file_path.match?(TEST_PATH_PATTERN)
      when /\A\+(?!\+\+)/
        insertions += 1
        test_insertions += 1 if current_file_is_test
      when /\A-(?!--)/
        deletions += 1
        test_deletions += 1 if current_file_is_test
      end
    end

    total_insertions = insertions
    test_loc_ratio = total_insertions > 0 ? (test_insertions.to_f / total_insertions).round(3) : 0.0

    {
      "insertions" => insertions,
      "deletions" => deletions,
      "net_loc" => insertions - deletions,
      "files_changed" => files.size,
      "test_insertions" => test_insertions,
      "test_deletions" => test_deletions,
      "test_loc_ratio" => test_loc_ratio
    }
  end
end
