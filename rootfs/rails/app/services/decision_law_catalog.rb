# Singleton catalog of the Laws of Vibe Coding.
# Reads docs/decision_types/*.md at boot, parses each into a structured hash.
# Cached in memory; dev mode reloads per-request.
#
#   DecisionLawCatalog.all        => [{ key:, title:, category:, pattern: }, ...]
#   DecisionLawCatalog.find(key)  => { key:, title:, category:, pattern: } or nil
#   DecisionLawCatalog.keys       => ["scope-unbundling", "iron-rule", ...]
#   DecisionLawCatalog.categories => { "Scope & Prioritization" => ["scope-unbundling", ...], ... }
#   DecisionLawCatalog.compact_prompt => condensed string for LLM prompts (~3,500 tokens)
#
class DecisionLawCatalog
  CATALOG_DIR = Rails.root.join("docs", "decision_types")
  # Client-image catalog digest: key/title/category/pattern only — the exact
  # fields this catalog exposes. The public client Docker image ships THIS in
  # place of the markdown, whose "## Observance" example sections quote private
  # development transcripts. Generated from the markdown via
  # `rake decision_catalog:generate`, so it parses to the identical laws (and
  # therefore the identical DecisionClassifier prompt signature).
  CATALOG_JSON = Rails.root.join("db", "decision_catalog.json")
  SKIP_FILES = %w[EXAMPLE_AND_FORMAT.md].freeze

  # Category mapping from EXAMPLE_AND_FORMAT.md
  CATEGORIES = {
    "Scope & Prioritization" => %w[
      scope-unbundling kill-the-feature revert-bad-decision
      collapse-unnecessary-steps kill-dead-complexity scope-creep-to-todos
    ],
    "Premise & Frame Challenging" => %w[
      challenge-the-constraint raise-the-abstraction
      full-stop-and-investigate reject-lazy-workaround resist-false-simplicity
    ],
    "Product & UX Thinking" => %w[
      workflow-from-user-backwards name-the-copy replace-jargon-with-intent
      instant-feedback-or-broken trace-the-stale-data follow-the-reference-product
      design-for-the-dgaf-user reference-the-working-version
      test-your-own-product
    ],
    "Code & Architecture" => %w[
      redirect-to-existing-tools explicit-over-clever name-the-code-smell
      correct-the-tool-choice demand-production-parity scope-the-version-boundary
      one-level-deeper cache-before-api generalize-from-rigid model-the-data-owner
      demand-idempotent-setup
    ],
    "State & Debugging" => %w[
      catch-the-state-bug cross-product-contamination
    ],
    "AI/LLM-Specific" => %w[
      model-as-shortcut spot-the-nonsequitur trace-the-input iron-rule
      respect-the-persona protect-the-token-budget score-with-your-eyes
      demand-before-after-proof failures-are-the-signal demand-actionable-diagnostics
      deterministic-offload
    ],
    "Safety & Process" => %w[
      demand-full-observability enforce-safety-rails audit-completeness
      preserve-artifacts codify-the-lesson
    ]
  }.freeze

  # Reverse lookup: key -> category
  KEY_TO_CATEGORY = CATEGORIES.each_with_object({}) do |(cat, keys), map|
    keys.each { |k| map[k] = cat }
  end.freeze

  class << self
    def all
      load_catalog unless catalog_fresh?
      @laws
    end

    def find(key)
      all.find { |law| law[:key] == key }
    end

    def keys
      all.map { |law| law[:key] }
    end

    def categories
      CATEGORIES
    end

    def category_for(key)
      KEY_TO_CATEGORY[key]
    end

    def category_names
      CATEGORIES.keys
    end

    # Condensed catalog for LLM prompts.
    # Format: "key (Category): pattern_text" — one per line.
    def compact_prompt
      all.map do |law|
        "#{law[:key]} (#{law[:category]}): #{law[:pattern]}"
      end.join("\n")
    end

    def reload!
      @laws = nil
      @loaded_at = nil
    end

    private

    def catalog_fresh?
      return false unless @laws
      return true if Rails.application.config.cache_classes
      # Dev mode: reload if any file changed since last load
      return false unless @loaded_at
      Dir.glob(CATALOG_DIR.join("*.md")).any? { |f| File.mtime(f) > @loaded_at } ? false : true
    end

    def load_catalog
      @laws = []
      md_paths = Dir.glob(CATALOG_DIR.join("*.md")).sort
                    .reject { |p| SKIP_FILES.include?(File.basename(p)) }

      if md_paths.any?
        # Server / dev: parse the authoritative markdown source.
        md_paths.each do |path|
          law = parse_law_file(path)
          if law
            @laws << law
          else
            Rails.logger.warn("DecisionLawCatalog: skipping malformed file #{File.basename(path)}")
          end
        end
      elsif File.exist?(CATALOG_JSON)
        # Client image: the markdown is not shipped (see CATALOG_JSON). Load the
        # generated digest, which parses to the same laws as the markdown.
        @laws = JSON.parse(File.read(CATALOG_JSON), symbolize_names: true)
      end

      @loaded_at = Time.current
      @laws
    end

    def parse_law_file(path)
      content = File.read(path)
      key = File.basename(path, ".md")

      # Extract title from first # heading
      title_match = content.match(/^#\s+(.+)$/)
      return nil unless title_match
      title = title_match[1].strip

      # Extract Pattern section
      pattern_match = content.match(/^##\s+Pattern\s*\n(.+?)(?=\n##\s|\z)/m)
      return nil unless pattern_match
      pattern = pattern_match[1].strip

      category = KEY_TO_CATEGORY[key] || "Uncategorized"

      { key: key, title: title, category: category, pattern: pattern }
    end
  end
end
