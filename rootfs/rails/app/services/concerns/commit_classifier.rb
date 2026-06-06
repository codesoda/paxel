module CommitClassifier
  COMMIT_TYPE_PATTERNS = {
    "feat"     => /\A(?:feat|add|implement|new|create|build)/i,
    "fix"      => /\A(?:fix|bug|patch|resolve|correct)/i,
    "refactor" => /\A(?:refactor|clean|reorganize|restructure|extract|simplify)/i,
    "test"     => /\A(?:test|spec|add test|fix test|coverage)/i,
    "chore"    => /\A(?:chore|update dep|bump|upgrade|maintenance|ci|version)/i,
    "docs"     => /\A(?:doc|readme|comment|changelog)/i
  }.freeze

  def self.classify(subject)
    COMMIT_TYPE_PATTERNS.each do |type, pattern|
      return type if subject&.match?(pattern)
    end
    "other"
  end

  def self.classify_batch(commits)
    counts = Hash.new(0)
    commits.each { |c| counts[classify(c["subject"] || c["message"])] += 1 }
    counts
  end
end
