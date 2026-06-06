# NOTE: CodebaseProfiler extracts structural signals from repo files (static analysis).
# CodeAnalyzer (separate service) generates LLM-based codebase summaries from code chunks.
class CodebaseProfiler
  MAX_FILE_READ = 100_000 # 100KB cap per file

  def self.profile(repo_path, file_tree)
    return {} unless repo_path && File.directory?(repo_path)
    new(repo_path, file_tree || "").profile
  end

  def initialize(repo_path, file_tree)
    @repo_path = repo_path
    @file_tree = file_tree
  end

  SOURCE_EXTENSIONS = %w[.rb .ts .tsx .js .jsx .py .go .rs .java .kt .swift .c .cpp .h].to_set.freeze
  MAX_SOURCE_FILES = 10_000

  # Agent configuration files by tool — used for Dimension 8 scoring.
  # Only instruction/behavior-configuring files, not ignore files or filters.
  AGENT_CONFIG_FILES = {
    "claude_code"    => { paths: [ "CLAUDE.md", ".claude/CLAUDE.md" ], type: :markdown },
    "codex"          => { paths: [ "AGENTS.md", "agents.md", "codex.md", "CODEX.md" ], type: :markdown },
    "cursor"         => { paths: [ ".cursorrules" ], globs: [ ".cursor/rules/*.mdc" ], type: :markdown },
    "windsurf"       => { paths: [ ".windsurfrules" ], type: :markdown },
    "github_copilot" => { paths: [ ".github/copilot-instructions.md" ], type: :markdown },
    "aider"          => { paths: [ ".aider.conf.yml" ], type: :yaml },
    "continue_dev"   => { paths: [ ".continuerc.json", ".continue/config.json" ], type: :json }
  }.freeze

  CONSTRAINT_PATTERN = /\bNEVER\b|\bALWAYS\b|\bMUST\b|\bDO NOT\b|\bREQUIRED\b|\bSHALL\b|\bIMPORTANT:|\bENSURE\b/i

  def profile
    agent_configs = analyze_agent_configs

    {
      "languages" => count_extensions_from_tree,
      "frameworks" => detect_frameworks,
      "dependency_count" => count_dependencies,
      "has_claude_md" => File.exist?(File.join(@repo_path, "CLAUDE.md")),
      "claude_md_stats" => analyze_claude_md,
      "has_agent_config" => agent_configs["exists"],
      "agent_config_stats" => agent_configs,
      "test_sophistication" => analyze_tests_from_tree,
      "architecture_signals" => analyze_architecture,
      "infra_signals" => detect_infrastructure_from_tree,
      "has_eval_infrastructure" => @file_tree.include?("eval"),
      "has_changelog" => File.exist?(File.join(@repo_path, "CHANGELOG.md")),
      "loc_stats" => count_source_loc,
      "documentation" => analyze_documentation
    }
  end

  # ── Public analysis methods (consumed by LocalCodeQualityAnalyzer) ──

  def detect_frameworks
    frameworks = []

    gemfile = safe_read("Gemfile")
    if gemfile
      frameworks << "rails" if gemfile.include?("rails")
      frameworks << "sinatra" if gemfile.include?("sinatra")
      frameworks << "rspec" if gemfile.include?("rspec")
      frameworks << "minitest" if gemfile.include?("minitest")
      frameworks << "sidekiq" if gemfile.include?("sidekiq")
    end

    pkg = safe_read("package.json")
    if pkg
      frameworks << "react" if pkg.include?("react")
      frameworks << "next" if pkg.include?("next")
      frameworks << "vue" if pkg.include?("vue")
      frameworks << "express" if pkg.include?("express")
      frameworks << "jest" if pkg.include?("jest")
      frameworks << "typescript" if pkg.include?("typescript")
    end

    frameworks.uniq
  end

  def count_dependencies
    count = 0

    gemfile = safe_read("Gemfile")
    count += gemfile.scan(/^\s*gem\s+/).size if gemfile

    pkg = safe_read("package.json")
    if pkg
      begin
        parsed = JSON.parse(pkg)
        count += (parsed["dependencies"]&.size || 0)
        count += (parsed["devDependencies"]&.size || 0)
      rescue JSON::ParserError
        # skip
      end
    end

    count
  end

  def analyze_claude_md
    content = safe_read("CLAUDE.md")
    return nil unless content

    {
      "word_count" => content.split(/\s+/).size,
      "line_count" => content.lines.size,
      "rules_count" => content.lines.count { |l| l.strip.start_with?("-", "*", "1", "2", "3", "4", "5", "6", "7", "8", "9") },
      "never_count" => content.scan(/\bNEVER\b/i).size,
      "always_count" => content.scan(/\bALWAYS\b/i).size,
      "must_count" => content.scan(/\bMUST\b/i).size,
      "explicit_constraints" => content.scan(/\bNEVER\b|\bALWAYS\b|\bMUST\b|\bDO NOT\b|\bREQUIRED\b|\bSHALL\b|\bIMPORTANT:|\bENSURE\b/i).size
    }
  end

  def analyze_agent_configs
    tools_found = []
    total_word_count = 0
    total_constraint_count = 0
    claude_stats = nil

    AGENT_CONFIG_FILES.each do |tool_name, config|
      found_any = false
      tool_words = 0
      tool_constraints = 0

      # Check fixed paths
      (config[:paths] || []).each do |rel_path|
        content = safe_read(rel_path)
        next unless content

        found_any = true
        stats = analyze_config_content(content, config[:type])
        tool_words += stats[:word_count]
        tool_constraints += stats[:constraint_count]

        # Capture CLAUDE.md-specific stats for backward compat
        # Prefer root CLAUDE.md, fall back to .claude/CLAUDE.md
        if tool_name == "claude_code" && (claude_stats.nil? || rel_path == "CLAUDE.md")
          claude_stats = analyze_claude_md_stats(content)
        end
      end

      # Check glob patterns
      (config[:globs] || []).each do |pattern|
        Dir.glob(File.join(@repo_path, pattern)).each do |full_path|
          next unless File.file?(full_path)
          next if File.size(full_path) > MAX_FILE_READ

          content = File.read(full_path, encoding: "utf-8", invalid: :replace, undef: :replace) rescue next
          found_any = true
          stats = analyze_config_content(content, config[:type])
          tool_words += stats[:word_count]
          tool_constraints += stats[:constraint_count]
        end
      end

      if found_any
        tools_found << tool_name
        total_word_count += tool_words
        total_constraint_count += tool_constraints
      end
    end

    result = {
      "exists" => tools_found.any?,
      "tools_configured" => tools_found,
      "tool_count" => tools_found.size,
      "total_word_count" => total_word_count,
      "total_constraint_count" => total_constraint_count
    }

    # Backward compat: populate legacy CLAUDE.md fields if present
    if claude_stats
      result.merge!(claude_stats)
    end

    result
  end

  def analyze_architecture
    framework = detect_project_framework
    patterns = architecture_patterns_for(framework)

    counts = {}
    patterns.each do |name, pattern|
      count = @file_tree.lines.count { |l| l.strip.match?(pattern) }
      counts[name] = count if count > 0
    end

    Rails.logger.info("CodebaseProfiler: #{framework} project — #{counts.values.sum} components across #{counts.size} types")
    if counts.empty? && @file_tree.lines.count > 100
      Rails.logger.warn("CodebaseProfiler: 0 architecture components for #{@file_tree.lines.count}-file repo — check file_tree path format")
    end
    counts
  end

  def analyze_documentation
    found_docs = []
    @file_tree.each_line do |line|
      path = line.strip
      next if path.empty?
      next unless path.match?(/\.md\z/i) || path.match?(/\AREADME/i)
      next if path.match?(%r{(?:test|spec|__tests__|evals?)/}i)
      next if path.match?(%r{(?:node_modules|vendor|\.github)/}i)
      found_docs << path
    end

    Rails.logger.info("CodebaseProfiler: #{found_docs.size} documentation files found")

    {
      "doc_count" => found_docs.size,
      "docs" => found_docs.first(30),
      "has_design_docs" => found_docs.any? { |d| d.match?(/design/i) },
      "has_architecture_doc" => found_docs.any? { |d| d.match?(/architect/i) },
      "has_testing_doc" => found_docs.any? { |d| d.match?(/testing/i) }
    }
  end

  def detect_infrastructure_from_tree
    signals = {}
    signals["docker"] = true if @file_tree.include?("Dockerfile") || @file_tree.include?("docker-compose")
    signals["ci"] = true if @file_tree.include?(".github/workflows") || @file_tree.include?(".circleci") || @file_tree.include?("Jenkinsfile")
    signals["terraform"] = true if @file_tree.include?(".tf")
    signals["kubernetes"] = true if @file_tree.include?("k8s") || @file_tree.include?("kubernetes")
    signals["monitoring"] = true if @file_tree.include?("datadog") || @file_tree.include?("sentry") || @file_tree.include?("newrelic")
    signals
  end

  private

  def count_extensions_from_tree
    counts = Hash.new(0)
    @file_tree.each_line do |line|
      path = line.strip
      next if path.empty?
      ext = File.extname(path).delete_prefix(".")
      counts[ext] += 1 if ext.present?
    end
    counts.sort_by { |_, v| -v }.first(20).to_h
  end

  def analyze_tests_from_tree
    test_files = 0
    test_dirs = Set.new
    test_frameworks = Set.new

    @file_tree.each_line do |line|
      path = line.strip
      next if path.empty?

      if path.match?(%r{(?:test|spec|__tests__)/}) || path.match?(/[._](?:test|spec)\.\w+$/)
        test_files += 1
        dir = path.split("/").first(2).join("/")
        test_dirs << dir
      end

      test_frameworks << "rspec" if path.match?(/spec.*_spec\.rb$/)
      test_frameworks << "jest" if path.match?(/\.test\.[jt]sx?$/)
      test_frameworks << "pytest" if path.match?(/test_.*\.py$/)
      test_frameworks << "minitest" if path.match?(/test.*_test\.rb$/)
      test_frameworks << "go_test" if path.match?(/_test\.go$/)
    end

    total_files = @file_tree.lines.count { |l| l.strip.present? }

    {
      "test_file_count" => test_files,
      "test_ratio" => total_files > 0 ? (test_files.to_f / total_files).round(3) : 0,
      "test_dirs" => test_dirs.to_a,
      "test_frameworks" => test_frameworks.to_a
    }
  end

  def detect_project_framework
    if @file_tree.include?("Gemfile") && @file_tree.include?("app/")
      :rails
    elsif @file_tree.include?("go.mod") || @file_tree.include?("go.sum")
      :go
    elsif @file_tree.include?("requirements.txt") || @file_tree.include?("pyproject.toml") || @file_tree.include?("setup.py")
      :python
    elsif @file_tree.include?("package.json")
      :node
    else
      :generic
    end
  end

  def architecture_patterns_for(framework)
    case framework
    when :rails
      {
        "services"    => %r{\Aapp/services/.+\.rb\z},
        "jobs"        => %r{\Aapp/jobs/.+\.rb\z},
        "models"      => %r{\Aapp/models/(?!concerns/).+\.rb\z},
        "controllers" => %r{\Aapp/controllers/.+_controller\.rb\z},
        "views"       => %r{\Aapp/views/.+\.(?:erb|haml|slim|jbuilder)\z},
        "concerns"    => %r{\Aapp/(?:models|controllers)/concerns/.+\.rb\z},
        "helpers"     => %r{\Aapp/helpers/.+\.rb\z},
        "channels"    => %r{\Aapp/channels/.+\.rb\z},
        "mailers"     => %r{\Aapp/mailers/.+\.rb\z},
        "middleware"   => %r{\Aapp/middleware/.+\.rb\z},
        "serializers" => %r{\Aapp/serializers/.+\.rb\z},
        "validators"  => %r{\Aapp/validators/.+\.rb\z},
        "decorators"  => %r{\Aapp/decorators/.+\.rb\z},
        "policies"    => %r{\Aapp/policies/.+\.rb\z},
        "components"  => %r{\Aapp/components/.+\.rb\z}
      }
    when :go
      {
        "commands"    => %r{\Acmd/[^/]+/main\.go\z},
        "packages"    => %r{\Ainternal/[^/]+/[^/]+\.go\z},
        "handlers"    => %r{handler[s]?/[^/]+\.go\z},
        "middleware"  => %r{middleware/[^/]+\.go\z},
        "models"      => %r{model[s]?/[^/]+\.go\z}
      }
    when :python
      {
        "models"      => %r{models?/[^/]+\.py\z},
        "views"       => %r{views?/[^/]+\.py\z},
        "services"    => %r{services?/[^/]+\.py\z},
        "tasks"       => %r{tasks?/[^/]+\.py\z},
        "serializers" => %r{serializers?/[^/]+\.py\z},
        "middleware"  => %r{middleware/[^/]+\.py\z}
      }
    when :node
      {
        "routes"      => %r{routes?/[^/]+\.[jt]sx?\z},
        "controllers" => %r{controllers?/[^/]+\.[jt]sx?\z},
        "services"    => %r{services?/[^/]+\.[jt]sx?\z},
        "models"      => %r{models?/[^/]+\.[jt]sx?\z},
        "middleware"   => %r{middleware/[^/]+\.[jt]sx?\z},
        "components"  => %r{components?/[^/]+\.[jt]sx?\z}
      }
    else # :generic — count common patterns but exclude test dirs
      {
        "services"    => %r{\A(?!(?:test|spec|__tests__)/)[^/]*/services?/[^/]+\.\w+\z},
        "models"      => %r{\A(?!(?:test|spec|__tests__)/)[^/]*/models?/[^/]+\.\w+\z},
        "controllers" => %r{\A(?!(?:test|spec|__tests__)/)[^/]*/controllers?/[^/]+\.\w+\z}
      }
    end
  end

  def count_source_loc
    source_files = []
    @file_tree.each_line do |line|
      path = line.strip
      next if path.empty?
      ext = File.extname(path)
      next unless SOURCE_EXTENSIONS.include?(ext)
      source_files << path
    end

    if source_files.size > MAX_SOURCE_FILES
      Rails.logger.warn("CodebaseProfiler: #{source_files.size} source files exceeds cap of #{MAX_SOURCE_FILES}, sampling")
      source_files = source_files.first(MAX_SOURCE_FILES)
    end

    production_loc = 0
    test_loc = 0
    eval_loc = 0
    eval_file_count = 0
    loc_by_language = Hash.new(0)

    source_files.each do |relative_path|
      full_path = File.join(@repo_path, relative_path)
      next unless File.exist?(full_path) && File.file?(full_path)

      begin
        lines = File.foreach(full_path).count
      rescue => e
        next
      end

      ext = File.extname(relative_path).delete_prefix(".")
      loc_by_language[ext] += lines

      if relative_path.match?(%r{(?:\A|/)evals?/})
        eval_loc += lines
        eval_file_count += 1
      elsif relative_path.match?(PrDiffStatsService::TEST_PATH_PATTERN)
        test_loc += lines
      else
        production_loc += lines
      end
    end

    # Second pass: count eval data files (YAML cases, JSON fixtures)
    @file_tree.each_line do |line|
      path = line.strip
      next if path.empty?
      ext = File.extname(path)
      next unless %w[.yml .yaml .json].include?(ext)
      next unless path.match?(%r{(?:\A|/)evals?/})

      full_path = File.join(@repo_path, path)
      next unless File.exist?(full_path) && File.file?(full_path)
      next if File.size(full_path) > MAX_FILE_READ

      begin
        lines = File.foreach(full_path).count
        eval_loc += lines
        eval_file_count += 1
      rescue => e
        next
      end
    end

    Rails.logger.info("CodebaseProfiler: LOC: #{production_loc} prod, #{test_loc} test, #{eval_loc} eval (#{eval_file_count} eval files) from #{source_files.size} source files")

    {
      "production_loc" => production_loc,
      "test_loc" => test_loc,
      "eval_loc" => eval_loc,
      "eval_file_count" => eval_file_count,
      "total_source_files" => source_files.size,
      "loc_by_language" => loc_by_language
    }
  rescue => e
    Rails.logger.warn("CodebaseProfiler: LOC counting failed: #{e.message}")
    {}
  end

  def analyze_config_content(content, type)
    word_count = content.split(/\s+/).size
    constraint_count = type == :markdown ? content.scan(CONSTRAINT_PATTERN).size : 0
    { word_count: word_count, constraint_count: constraint_count }
  end

  def analyze_claude_md_stats(content)
    {
      "word_count" => content.split(/\s+/).size,
      "line_count" => content.lines.size,
      "rules_count" => content.lines.count { |l| l.strip.start_with?("-", "*", "1", "2", "3", "4", "5", "6", "7", "8", "9") },
      "never_count" => content.scan(/\bNEVER\b/i).size,
      "always_count" => content.scan(/\bALWAYS\b/i).size,
      "must_count" => content.scan(/\bMUST\b/i).size,
      "explicit_constraints" => content.scan(CONSTRAINT_PATTERN).size
    }
  end

  def safe_read(filename)
    path = File.join(@repo_path, filename)
    return nil unless File.exist?(path)
    size = File.size(path)
    return nil if size > MAX_FILE_READ
    File.read(path, encoding: "utf-8", invalid: :replace, undef: :replace)
  rescue => e
    nil
  end
end
