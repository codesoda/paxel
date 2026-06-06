# On-device code quality analysis — 14 deterministic dimensions.
#
# Runs inside Docker container against /repo:ro mount.
# Produces ONLY aggregate metrics (counts, ratios, booleans).
# No file paths, no code snippets, no identifiers cross the wire.
#
# Data flow:
#   /repo:ro ──▶ discover_files ──▶ 14 L1 analyzers ──▶ { dimensions: { ... } }
#   /git_metrics.txt:ro ──▶ parse_git_metrics ──▶ git-based dimensions
#
# Graceful degradation:
#   no_repo     → { status: "no_repo", dimensions: {} }
#   empty_repo  → { status: "empty_repo", dimensions: {} }
#   error       → { status: "error", error: "...", dimensions: {} }
class LocalCodeQualityAnalyzer
  REPO_PATH = "/repo"
  GIT_METRICS_PATH = "/git_metrics.txt"
  MAX_FILES = 10_000
  MAX_FILE_SIZE = 100_000 # 100KB per file

  SOURCE_EXTENSIONS = CodebaseProfiler::SOURCE_EXTENSIONS

  # Languages where rescue/catch/except patterns apply
  RESCUE_LANGUAGES = %w[.rb .py .js .jsx .ts .tsx .java .kt .go .rs .swift .c .cpp].to_set.freeze

  def self.analyze(repo_path: REPO_PATH, git_metrics_path: GIT_METRICS_PATH, &progress)
    new(repo_path, git_metrics_path).analyze(&progress)
  end

  def initialize(repo_path, git_metrics_path)
    @repo_path = repo_path
    @git_metrics_path = git_metrics_path
  end

  def analyze(&progress)
    return { status: "no_repo", dimensions: {} } unless Dir.exist?(@repo_path)

    # @files = full filtered tree (path classification + counts, uncapped).
    # readable_source_files caps the subset whose CONTENTS get read (finding #4).
    @files = discover_files
    return { status: "empty_repo", dimensions: {} } if @files.empty?

    @git_metrics = parse_git_metrics
    @file_contents_cache = {}

    # Map dimension keys to analyzer method names (most match, a few differ)
    l1_analyzers = {
      commit_discipline: :analyze_commit_discipline,
      test_quality: :analyze_test_quality,
      code_quality: :analyze_code_quality,
      error_handling: :analyze_error_handling,
      security_signals: :analyze_security_signals,
      architecture: :analyze_architecture,
      documentation: :analyze_documentation,
      agent_config_quality: :analyze_agent_configs,
      infrastructure: :analyze_infrastructure,
      dependency_management: :analyze_dependencies,
      git_workflow: :analyze_git_workflow,
      code_evolution: :analyze_code_evolution,
      performance_awareness: :analyze_performance,
      production_readiness: :analyze_production_readiness
    }

    total_steps = l1_analyzers.size
    done = 0

    dims = {}
    l1_analyzers.each do |dim, method|
      dims[dim] = begin
        send(method)
      rescue => e
        # Fault-isolate one dimension: a crash here (e.g. an invalid-UTF-8 filename
        # tripping Regexp#match?) records an error for THIS dimension only, instead
        # of the top-level rescue aborting all 14 and nulling code_quality (audit C15).
        { status: "error", error: e.class.to_s }
      end
      done += 1
      progress&.call(done, total_steps, dim.to_s.tr("_", " "))
    end

    {
      status: "complete",
      file_count: @files.size,
      dimensions: dims
    }
  rescue => e
    { status: "error", error: "#{e.class}: #{e.message}", dimensions: {} }
  end

  private

  # ── File Discovery ──────────────────────────────────────────────────

  def discover_files
    files = if git_repo?
      IO.popen([ "git", "-C", @repo_path, "ls-files", "-z" ], err: File::NULL, &:read).split("\0")
    else
      Dir.glob(File.join(@repo_path, "**", "*"), File::FNM_DOTMATCH)
        .select { |f| File.file?(f) }
        .map { |f| f.sub("#{@repo_path}/", "") }
    end

    # Returns the FULL filtered path list — uncapped. The MAX_FILES cap moved to
    # the content-reading passes only (see readable_source_files). Classifying
    # test/source files and counting them is pure string work with no I/O, so it
    # must cover the whole tree: on a big monorepo the byte-sorted first MAX_FILES
    # paths are tiny generated files, and the real app/spec/lib trees sort AFTER
    # the cap. Capping here dropped them entirely — test_file_count read 55 vs the
    # true 630 on the same monorepo, and median_file_length pinned at 5 across
    # every capped upload (audit finding #4).
    files
      .map(&:scrub) # normalize non-UTF-8 bytes so downstream Regexp#match? can't raise (audit C15)
      .reject { |f| f.start_with?(".git/", "node_modules/", "vendor/", ".bundle/") }
      .reject { |f| f.include?("/node_modules/") || f.include?("/vendor/bundle/") }
      .select { |f| safe_path?(f) }
  end

  def git_repo?
    Dir.exist?(File.join(@repo_path, ".git"))
  end

  # Symlink guard: prevent path traversal outside repo mount
  def safe_path?(relative_path)
    full = File.join(@repo_path, relative_path)
    return false unless File.exist?(full)
    return true unless File.symlink?(full)
    File.realpath(full).start_with?(File.realpath(@repo_path))
  rescue Errno::ENOENT, Errno::ELOOP
    false
  end

  # Full source-extension list — path classification + counts (test_file_count,
  # total_source_files). No content I/O, so it stays uncapped (see discover_files).
  def source_files
    @source_files ||= @files.select { |f| SOURCE_EXTENSIONS.include?(File.extname(f)) }
  end

  # The subset of source files we actually READ (line counts, body regex scans).
  # Capped at MAX_FILES to bound File.read cost + the @file_contents_cache memory
  # footprint on huge repos. Capping at the SOURCE level — not the whole tree —
  # means generated/asset files (which often sort alphabetically before app/,
  # spec/, lib/) can no longer starve real source out of the read sample, which
  # is what truncated median_file_length to 5 on every capped upload (finding #4).
  def readable_source_files
    @readable_source_files ||= source_files.first(MAX_FILES)
  end

  def safe_read(relative_path)
    full = File.join(@repo_path, relative_path)
    return nil unless File.exist?(full) && File.file?(full)
    return nil if File.size(full) > MAX_FILE_SIZE
    return nil unless safe_path?(relative_path)
    @file_contents_cache[relative_path] ||= File.read(full, encoding: "utf-8", invalid: :replace, undef: :replace)
  rescue => e
    nil
  end

  # ── Git Metrics Parsing ─────────────────────────────────────────────

  def parse_git_metrics
    return {} unless File.exist?(@git_metrics_path)

    commits = []
    current_commit = nil

    File.foreach(@git_metrics_path, encoding: "utf-8", invalid: :replace, undef: :replace) do |line|
      line = line.chomp
      if line.include?("|") && !line.start_with?("\t") && line.count("|") >= 2
        parts = line.split("|", 3)
        current_commit = { hash: parts[0], date: parts[1], subject: parts[2] || "", files: [] }
        commits << current_commit
      elsif current_commit && line.match?(/\A\d+\t\d+\t/)
        parts = line.split("\t", 3)
        current_commit[:files] << { added: parts[0].to_i, deleted: parts[1].to_i, path: parts[2] || "" }
      elsif current_commit && line.match?(/\A-\t-\t/)
        # Binary file — skip numstat but count the file
        parts = line.split("\t", 3)
        current_commit[:files] << { added: 0, deleted: 0, path: parts[2] || "", binary: true }
      end
    end

    { commits: commits }
  rescue => e
    {}
  end

  # ── Dimension 1: Commit Discipline ──────────────────────────────────

  CONVENTIONAL_PATTERN = /\A(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)[\(:]/.freeze

  def analyze_commit_discipline
    commits = @git_metrics.dig(:commits) || []
    return { status: "no_git_data" } if commits.empty?

    conventional = commits.count { |c| c[:subject].match?(CONVENTIONAL_PATTERN) }
    reverts = commits.count { |c| c[:subject].match?(/\Arevert/i) }

    # Atomic = single-purpose commit (rough heuristic: <20 files changed)
    atomic = commits.count { |c| c[:files].size <= 20 }

    sizes = commits.map { |c| c[:files].sum { |f| f[:added] + f[:deleted] } }
    avg_size = sizes.any? ? (sizes.sum.to_f / sizes.size).round(0) : 0

    {
      total_commits: commits.size,
      conventional_commit_ratio: ratio(conventional, commits.size),
      revert_ratio: ratio(reverts, commits.size),
      atomic_commit_ratio: ratio(atomic, commits.size),
      avg_commit_size_lines: avg_size
    }
  end

  # ── Dimension 2: Test Quality ───────────────────────────────────────

  def analyze_test_quality
    all_test_files = @files.select { |f| test_file?(f) } # full count — classification only
    # For LOC ratio: use source-extension test files only for fair comparison.
    # LOC reads contents, so draw from the capped readable set.
    test_source_files = readable_source_files.select { |f| test_file?(f) }
    non_test_source = readable_source_files.reject { |f| test_file?(f) }

    test_loc = 0
    prod_loc = 0

    test_source_files.each { |f| test_loc += line_count(f) }
    non_test_source.each { |f| prod_loc += line_count(f) }

    test_dirs = all_test_files.map { |f| f.split("/").first }.uniq
    has_factories = @files.any? { |f| f.match?(%r{factories/|factory\.}) }
    has_fixtures = @files.any? { |f| f.match?(%r{fixtures/|fixture}) }

    frameworks = Set.new
    frameworks << "rspec" if @files.any? { |f| f.match?(/spec.*_spec\.rb$/) }
    frameworks << "jest" if @files.any? { |f| f.match?(/\.test\.[jt]sx?$/) }
    frameworks << "pytest" if @files.any? { |f| f.match?(/test_.*\.py$/) }
    frameworks << "minitest" if @files.any? { |f| f.match?(/test.*_test\.rb$/) }
    frameworks << "go_test" if @files.any? { |f| f.match?(/_test\.go$/) }
    frameworks << "bats" if @files.any? { |f| f.match?(/\.bats$/) }

    {
      test_file_count: all_test_files.size,
      test_ratio: ratio(test_loc, prod_loc),
      test_dirs: test_dirs.size,
      has_factories: has_factories,
      has_fixtures: has_fixtures,
      test_frameworks: frameworks.to_a
    }
  end

  # ── Dimension 3: Code Quality ───────────────────────────────────────

  def analyze_code_quality
    return { status: "no_source_files" } if source_files.empty?

    lengths = readable_source_files.map { |f| line_count(f) }

    god_objects = lengths.count { |l| l > 500 }
    long_files = lengths.count { |l| l > 300 }

    {
      total_source_files: source_files.size,
      avg_file_length: (lengths.sum.to_f / lengths.size).round(0),
      median_file_length: median(lengths),
      god_object_count: god_objects,
      long_file_count: long_files,
      max_file_length: lengths.max || 0
    }
  end

  # ── Dimension 4: Error Handling ─────────────────────────────────────

  RESCUE_PATTERNS = {
    ruby_bare: /rescue\s*($|\s*=>)/, # rescue without specific exception
    ruby_standard: /rescue\s+(?:StandardError|Exception)\b/,
    ruby_specific: /rescue\s+[A-Z]\w+(?:::\w+)*(?:\s*,\s*[A-Z]\w+(?:::\w+)*)*/,
    js_catch: /catch\s*\(\s*\w+\s*\)/,
    python_bare: /except\s*:/,
    python_exception: /except\s+Exception/,
    python_specific: /except\s+[A-Z]\w+/
  }.freeze

  def analyze_error_handling
    rescue_total = 0
    rescue_specific = 0
    rescue_generic = 0
    has_retry = false

    readable_source_files.each do |f|
      next unless RESCUE_LANGUAGES.include?(File.extname(f))
      content = safe_read(f)
      next unless content

      ext = File.extname(f)
      case ext
      when ".rb"
        bare = content.scan(RESCUE_PATTERNS[:ruby_bare]).size
        standard = content.scan(RESCUE_PATTERNS[:ruby_standard]).size
        specific = content.scan(RESCUE_PATTERNS[:ruby_specific]).size - standard
        rescue_generic += bare + standard
        rescue_specific += [ specific, 0 ].max
        rescue_total += bare + standard + [ specific, 0 ].max
      when ".js", ".jsx", ".ts", ".tsx"
        catches = content.scan(RESCUE_PATTERNS[:js_catch]).size
        rescue_total += catches
        # JS catch blocks are always specific (they catch the error object)
        rescue_specific += catches
      when ".py"
        bare = content.scan(RESCUE_PATTERNS[:python_bare]).size
        exception = content.scan(RESCUE_PATTERNS[:python_exception]).size
        specific = content.scan(RESCUE_PATTERNS[:python_specific]).size - exception
        rescue_generic += bare + exception
        rescue_specific += [ specific, 0 ].max
        rescue_total += bare + exception + [ specific, 0 ].max
      end

      has_retry = true if content.match?(/retry|retries|backoff|exponential/i)
    end

    {
      rescue_total: rescue_total,
      rescue_specific: rescue_specific,
      rescue_generic: rescue_generic,
      bare_rescue_ratio: ratio(rescue_generic, rescue_total),
      has_retry_logic: has_retry
    }
  end

  # ── Dimension 5: Security Signals ───────────────────────────────────

  def analyze_security_signals
    eval_count = 0
    exec_count = 0
    sql_interpolation = 0
    hardcoded_secret_patterns = 0
    has_security_config = false

    readable_source_files.reject { |f| test_file?(f) }.each do |f|
      content = safe_read(f)
      next unless content

      eval_count += content.scan(/\beval\s*\(/).size
      exec_count += content.scan(/\b(?:exec|system|popen|spawn)\s*\(/).size
      sql_interpolation += content.scan(/\bwhere\s*\(\s*"[^"]*#\{/).size
      hardcoded_secret_patterns += content.scan(/(?:password|secret|api_key|token)\s*=\s*["'][^"']{8,}["']/i).size
    end

    has_security_config = @files.any? { |f|
      f.match?(/security|cors|csp|rack.attack|rate.limit/i) && !test_file?(f)
    }

    {
      eval_usage: eval_count,
      exec_usage: exec_count,
      sql_interpolation_count: sql_interpolation,
      hardcoded_secret_patterns: hardcoded_secret_patterns,
      has_security_config: has_security_config
    }
  end

  def profiler
    @profiler ||= CodebaseProfiler.new(@repo_path, @files.join("\n"))
  end

  # ── Dimension 6: Architecture ───────────────────────────────────────

  def analyze_architecture
    arch = profiler.analyze_architecture

    total_components = arch.values.sum
    has_separation = arch.keys.size >= 3

    {
      components: arch,
      total_components: total_components,
      component_types: arch.keys.size,
      has_separation_of_concerns: has_separation
    }
  end

  # ── Dimension 7: Documentation ──────────────────────────────────────

  def analyze_documentation
    docs = profiler.analyze_documentation

    {
      doc_count: docs["doc_count"],
      has_readme: @files.any? { |f| f.match?(/\AREADME/i) },
      has_architecture_doc: docs["has_architecture_doc"],
      has_design_docs: docs["has_design_docs"],
      has_testing_doc: docs["has_testing_doc"],
      has_changelog: @files.any? { |f| f.match?(/\ACHANGELOG/i) }
    }
  end

  # ── Dimension 8: Agent Config Quality ──────────────────────────────

  def analyze_agent_configs
    profiler.analyze_agent_configs
  end

  # ── Dimension 9: Infrastructure ─────────────────────────────────────

  def analyze_infrastructure
    signals = profiler.detect_infrastructure_from_tree

    {
      "has_docker" => signals["docker"] || false,
      "has_ci" => signals["ci"] || false,
      "has_monitoring" => signals["monitoring"] || false,
      "has_linter" => signals["linter"] || false
    }
  end

  # ── Dimension 10: Dependency Management ─────────────────────────────

  def analyze_dependencies
    {
      dependency_count: profiler.count_dependencies,
      frameworks: profiler.detect_frameworks,
      has_lockfile: @files.any? { |f| f.match?(/Gemfile\.lock|package-lock\.json|yarn\.lock|pnpm-lock|poetry\.lock|go\.sum/i) }
    }
  end

  # ── Dimension 11: Git Workflow ──────────────────────────────────────

  def analyze_git_workflow
    commits = @git_metrics.dig(:commits) || []
    return { status: "no_git_data" } if commits.empty?

    # Tag/version bumps
    version_commits = commits.count { |c| c[:subject].match?(/bump|version|release|v\d+\.\d+/i) }

    # Days with commits
    dates = commits.filter_map { |c| c[:date]&.split("T")&.first }.uniq

    {
      version_commits: version_commits,
      active_days: dates.size,
      commits_per_active_day: dates.any? ? ratio(commits.size, dates.size) : 0
    }
  end

  # ── Dimension 12: Code Evolution ────────────────────────────────────

  def analyze_code_evolution
    commits = @git_metrics.dig(:commits) || []
    return { status: "no_git_data" } if commits.empty?

    total_added = 0
    total_deleted = 0
    refactor_commits = 0

    commits.each do |c|
      added = c[:files].sum { |f| f[:added] }
      deleted = c[:files].sum { |f| f[:deleted] }
      total_added += added
      total_deleted += deleted

      refactor_commits += 1 if c[:subject].match?(/refactor/i)
    end

    {
      total_lines_added: total_added,
      total_lines_deleted: total_deleted,
      deletion_ratio: ratio(total_deleted, total_added + total_deleted),
      refactor_commit_ratio: ratio(refactor_commits, commits.size),
      net_loc_change: total_added - total_deleted
    }
  end

  # ── Dimension 13: Performance Awareness ─────────────────────────────

  def analyze_performance
    has_caching = false
    has_indexing = false
    has_pagination = false
    has_connection_pooling = false
    has_eager_loading = false

    readable_source_files.each do |f|
      content = safe_read(f)
      next unless content

      has_caching = true if content.match?(/cache|memoize|Rails\.cache|redis/i)
      has_indexing = true if content.match?(/\badd_index\b|\bcreate_index\b|\bADD INDEX\b/i)
      has_pagination = true if content.match?(/paginate|pagy|kaminari|will_paginate|limit.*offset/i)
      has_connection_pooling = true if content.match?(/connection_pool|pool_size|ConnectionPool/i)
      has_eager_loading = true if content.match?(/includes\(|preload\(|eager_load\(/i)
    end

    {
      has_caching: has_caching,
      has_indexing: has_indexing,
      has_pagination: has_pagination,
      has_connection_pooling: has_connection_pooling,
      has_eager_loading: has_eager_loading
    }
  end

  # ── Dimension 14: Production Readiness ──────────────────────────────

  def analyze_production_readiness
    has_error_tracking = @files.any? { |f| f.match?(/sentry|bugsnag|rollbar|honeybadger|airbrake/i) } ||
      readable_source_files.any? { |f| safe_read(f)&.match?(/Sentry|Bugsnag|Rollbar|Honeybadger/i) }

    has_logging = readable_source_files.any? { |f| safe_read(f)&.match?(/logger|Rails\.logger|console\.log|logging/i) }

    has_health_check = @files.any? { |f| f.match?(/health|ping|heartbeat/i) } ||
      readable_source_files.any? { |f| safe_read(f)&.match?(/health_check|healthz|readiness/i) }

    has_rate_limiting = @files.any? { |f| f.match?(/rack.attack|rate.limit|throttle/i) } ||
      readable_source_files.any? { |f| safe_read(f)&.match?(/Rack::Attack|rate_limit|throttle/i) }

    has_env_config = @files.any? { |f| f.match?(/\.env\.example|\.env\.sample|env\.yml/) }

    {
      has_error_tracking: has_error_tracking,
      has_logging: has_logging,
      has_health_check: has_health_check,
      has_rate_limiting: has_rate_limiting,
      has_env_config: has_env_config
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  def test_file?(path)
    path.match?(%r{(?:test|spec|__tests__)/}) || path.match?(/[._](?:test|spec)\.\w+$/)
  end

  def line_count(relative_path)
    content = safe_read(relative_path)
    return 0 unless content
    content.lines.count
  end

  def ratio(numerator, denominator)
    return 0.0 if denominator.to_f.zero?
    (numerator.to_f / denominator.to_f).round(3)
  end

  def median(arr)
    return 0 if arr.empty?
    sorted = arr.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round(0)
  end
end
