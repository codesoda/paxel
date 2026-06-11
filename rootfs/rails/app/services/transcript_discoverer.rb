class TranscriptDiscoverer
  attr_reader :upload, :extract_dir

  def initialize(upload, extract_dir)
    @upload = upload
    @extract_dir = extract_dir
  end

  # Cursor bucket Claude can't attribute to a workspace (no workspaceIdentifier).
  # We skip it during discovery because "unknown origin" sessions can't be
  # meaningfully merged with any repo — treating the bucket as its own Project
  # just scatters the results page.
  CURSOR_UNATTRIBUTED_DIR = "_cursor_unattributed".freeze

  # Codex sessions whose session_meta lacks a repository_url land here from the
  # client's --all bucketing. Same rationale as Cursor's equivalent — no repo
  # context means nothing meaningful to merge against.
  CODEX_UNATTRIBUTED_DIR = "_codex_unattributed".freeze

  def discover!
    @sidecar = read_sidecar
    @jsonl_paths_by_session_id = {}
    log_sidecar_status
    project_dirs = find_project_dirs
    project_dirs.each do |project_dir|
      process_project(project_dir)
    end
    # Pass 2: cross-tool linking — runs AFTER all process_project calls so it
    # can see Claude sessions and Codex sessions that landed in different
    # project_dirs but collapsed onto the same Project via git_remote.
    # See docs/designs/CROSS_TOOL_SESSION_LINKING.md §3 + §6.
    CrossToolLinker.new(upload, @jsonl_paths_by_session_id).link!
    apply_pr_links if @sidecar
  end

  private

  # Merge primary (archive-embedded) + secondary (client bind-mounted at
  # /paxel_sidecar) sidecars. Primary wins on `directories` key conflict;
  # secondary fills gaps. Covers the Docker --all + Cursor merge case
  # where analyze_local.rake rewrites transcript_dir/_metadata.json with
  # Cursor-only dirs, which would otherwise mask the host-resolved Claude
  # remotes. Top-level fields (pr_links, version, orphan_recovery_count)
  # stay with primary when present.
  def read_sidecar
    primary = parse_sidecar_file(File.join(extract_dir, "_metadata.json"))
    secondary = parse_sidecar_file(secondary_sidecar_path)
    return nil if primary.nil? && secondary.nil?
    return primary if secondary.nil?
    return secondary if primary.nil?

    primary.merge(
      "directories" => (secondary["directories"] || {}).merge(primary["directories"] || {})
    )
  end

  # Docker --all writes a host-side sidecar that gets bind-mounted into the
  # client container at /paxel_sidecar (read-only). Gated on CLIENT_MODE=1
  # (baked into Dockerfile.client) so a stray file at /paxel_sidecar on the
  # Rails server can never contaminate server-side uploads.
  def secondary_sidecar_path
    return nil unless ENV["CLIENT_MODE"] == "1"
    "/paxel_sidecar/_metadata.json"
  end

  def parse_sidecar_file(path)
    return nil unless path && File.exist?(path)
    data = JSON.parse(File.read(path))
    # Defense against non-Hash JSON bodies ("false", "[]", "null", etc.).
    # The downstream merge and `.dig("directories", ...)` consumers all
    # assume a Hash — bailing to nil here preserves the fall-through.
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError, SystemCallError, IOError
    # SystemCallError (⊇ Errno::ENOENT, Errno::EACCES) so an unreadable sidecar
    # is skipped, not fatal — same one-bad-file-can't-sink-the-upload contract.
    nil
  end

  # Debug-only: logs sidecar presence for scatter diagnosis. Never surfaced
  # to the user pipeline stream — read via Rails.logger in dev/tail.
  def log_sidecar_status
    dir_count = @sidecar&.dig("directories")&.size
    with_remote = @sidecar&.dig("directories")&.count { |_, v| v["git_remote"].to_s != "" } || 0
    if dir_count
      Rails.logger.debug { "[TranscriptDiscoverer] Sidecar present: #{dir_count} dirs (#{with_remote} with git_remote)" }
    else
      Rails.logger.debug { "[TranscriptDiscoverer] Sidecar NOT found (primary or /paxel_sidecar fallback) — Projects will scatter by encoded_name" }
    end
  rescue => e
    Rails.logger.warn("[TranscriptDiscoverer] sidecar log failed: #{e.message}")
  end

  def find_project_dirs
    Dir.glob(File.join(extract_dir, "**", "*.jsonl"))
      .reject { |f| f.include?("/_git/") }
      .map { |f| File.dirname(f) }
      .uniq
      .map { |dir| find_project_root(dir) }
      .uniq
  end

  def find_project_root(dir)
    current = dir
    while current != extract_dir && current.start_with?(extract_dir)
      parent = File.dirname(current)
      if parent == extract_dir || !Dir.glob(File.join(parent, "*.jsonl")).empty?
        return current
      end
      if File.exist?(File.join(parent, "sessions-index.json"))
        return parent
      end
      current = parent
    end
    dir
  end

  def process_project(project_dir)
    # Use the actual workspace directory name (not the project's encoded_name)
    dir_encoded_name = project_dir.sub("#{extract_dir}/", "").split("/").first
    return if dir_encoded_name.blank?
    return if dir_encoded_name == CURSOR_UNATTRIBUTED_DIR
    return if dir_encoded_name == CODEX_UNATTRIBUTED_DIR

    # Normalize the raw sidecar remote to the same canonical form Repository
    # uses, so that the same repo expressed as git@github.com:org/name.git or
    # https://github.com/org/name all collapse into one Project. Without this
    # normalization, workspaces with mixed URL formats scattered into duplicate
    # Project rows even though the sidecar had a remote for each.
    raw_remote = @sidecar&.dig("directories", dir_encoded_name, "git_remote")
    git_remote = Repository.normalize_remote(raw_remote)

    repository = git_remote.present? ? Repository.find_or_create_for(git_remote) : nil

    project = if git_remote.present?
      upload.projects.find_or_create_by!(git_remote: git_remote) do |p|
        p.encoded_name = dir_encoded_name
        p.original_path = @sidecar.dig("directories", dir_encoded_name, "cwd")
        p.repository = repository
      end
    else
      # No git remote → key the Project by its encoded dir name. Prefer the real
      # working directory from the sidecar (every collector writes a per-bucket "cwd")
      # so a cwd-named blank-remote bucket — e.g. a `_codex_<basename>_<hash>` /
      # opencode / gemini / cursor cwd bucket — shows the actual path instead of a
      # synthetic `gsub("-","/")` of the internal bucket name. Fall back to the gsub
      # when the sidecar carries no cwd for this dir.
      sidecar_cwd = @sidecar&.dig("directories", dir_encoded_name, "cwd")
      upload.projects.find_or_create_by!(encoded_name: dir_encoded_name) do |p|
        p.original_path = sidecar_cwd.presence || dir_encoded_name.gsub("-", "/")
      end
    end

    # Ensure repository is linked even for pre-existing projects
    if repository && project.repository_id != repository.id
      project.update_column(:repository_id, repository.id)
    end

    index_data = load_session_index(project_dir, dir_encoded_name)
    all_jsonl_files = find_all_jsonl_files(dir_encoded_name)

    main_files = all_jsonl_files.reject { |path| path.include?("/subagents/") }
    subagent_files = all_jsonl_files.select { |path| path.include?("/subagents/") }

    main_sessions_by_id = {}
    main_files.each do |jsonl_path|
      session_id = File.basename(jsonl_path, File.extname(jsonl_path))
      metadata = index_data[session_id] || {}

      # Detect agent type: prefer metadata hint (Cursor), fall back to format detection
      agent_type = metadata["agentType"] || begin
        TranscriptFormatDetector.detect(jsonl_path).to_s
      rescue
        "claude_code"
      end

      # A transcript file can vanish between Dir.glob enumeration and this stat:
      # session rotation, a deleted Conductor workspace, or a dangling symlink in
      # the --since/--project mirror tree (analyze_local.rake FileUtils.ln_s).
      # Skip the one bad session instead of failing the whole upload
      # (PAXEL-CLIENT-14; same family as PAXEL-CLIENT-10/#1057, CLIENT-12/#1059).
      begin
        current_mtime = File.mtime(jsonl_path).to_i
        current_size = File.size(jsonl_path)
      rescue SystemCallError => e
        Rails.logger.warn("[TranscriptDiscoverer] skipping unreadable session file #{jsonl_path}: #{e.class}")
        next
      end

      # Scrub first_prompt before persistence (Opus review, PR #706 follow-up).
      # first_prompt reaches Anthropic via SessionNarrativeAnalyzer and
      # EpisodeSummarizer prompt builders — a user who set up Claude Code
      # by pasting their API key into the first message would leak it.
      raw_first_prompt = metadata["firstPrompt"]
      scrubbed_first_prompt =
        if raw_first_prompt && SecretScrubber.enabled?
          SecretScrubber.scrub(raw_first_prompt)
        else
          raw_first_prompt
        end

      ts = project.transcript_sessions.find_or_create_by!(session_id: session_id) do |t|
        t.first_prompt = scrubbed_first_prompt&.truncate(1000)
        t.summary = metadata["summary"]&.truncate(2000)
        t.message_count = metadata["messageCount"] || 0
        t.git_branch = metadata["gitBranch"]
        t.file_size_bytes = current_size
        t.source_dir = dir_encoded_name
        t.agent_type = agent_type
        t.file_mtime = current_mtime if t.respond_to?(:file_mtime=)
      end

      # Incremental discovery: reset if file changed or session was previously
      # marked no_transcript (file is now present on disk).
      if !ts.previously_new_record? && (ts.status == "no_transcript" || (ts.respond_to?(:file_mtime) && ts.file_mtime != current_mtime))
        ts.update!(
          status: "pending",
          narrative: nil,
          narrative_status: "pending",
          file_mtime: current_mtime,
          file_size_bytes: current_size
        )
      end

      main_sessions_by_id[session_id] = ts
      # Memoize for CrossToolLinker Pass 2 — the linker needs to re-read the
      # raw JSONL but can't reconstruct the path from source_dir + session_id
      # alone (Codex sessions are date-bucketed under YYYY/MM/DD).
      @jsonl_paths_by_session_id[ts.id] = jsonl_path
    end

    subagent_files.each do |jsonl_path|
      session_id = File.basename(jsonl_path, File.extname(jsonl_path))

      relative = jsonl_path.sub("#{extract_dir}/#{dir_encoded_name}/", "")
      parts = relative.split("/")
      next unless parts.length >= 3 && parts[-2] == "subagents"

      parent_session_id = parts[-3] || parts[0]
      parent_session = main_sessions_by_id[parent_session_id]
      next unless parent_session

      # Same vanished/dangling-file guard as the main loop above (PAXEL-CLIENT-14).
      begin
        current_mtime = File.mtime(jsonl_path).to_i
        current_size = File.size(jsonl_path)
      rescue SystemCallError => e
        Rails.logger.warn("[TranscriptDiscoverer] skipping unreadable subagent file #{jsonl_path}: #{e.class}")
        next
      end

      # Detect agent_type from the file (opencode subagents carry the
      # opencode_session_meta marker). Without this the column defaults to
      # claude_code; the chunker later confirms it, but stamping at discovery
      # keeps the row correct for any pre-chunk reader. Claude subagents detect
      # as claude_code (unchanged).
      subagent_agent_type = begin
        TranscriptFormatDetector.detect(jsonl_path).to_s
      rescue
        "claude_code"
      end

      ts = project.transcript_sessions.find_or_create_by!(session_id: session_id) do |t|
        t.is_subagent = true
        t.parent_session = parent_session
        t.agent_type = subagent_agent_type
        t.file_size_bytes = current_size
        t.source_dir = dir_encoded_name
        t.file_mtime = current_mtime if t.respond_to?(:file_mtime=)
      end

      # Incremental discovery for subagents: reset if file changed or
      # session was previously marked no_transcript.
      if !ts.previously_new_record? && (ts.status == "no_transcript" || (ts.respond_to?(:file_mtime) && ts.file_mtime != current_mtime))
        ts.update!(
          status: "pending",
          narrative: nil,
          narrative_status: "pending",
          file_mtime: current_mtime,
          file_size_bytes: current_size
        )
      end
    end

    project.update!(sessions_count: project.transcript_sessions.main_sessions.count)
  end

  def apply_pr_links
    pr_links = @sidecar["pr_links"] || []
    pr_links.each do |link|
      session = TranscriptSession.joins(:project)
        .where(projects: { upload_id: upload.id })
        .find_by(session_id: link["session_id"])
      next unless session
      session.update!(
        pr_number: link["pr_number"],
        pr_url: link["pr_url"],
        pr_repo: link["pr_repo"]
      )
    end
  end

  def load_session_index(project_dir, encoded_name)
    index_path = File.join(extract_dir, encoded_name, "sessions-index.json")
    unless File.exist?(index_path)
      index_path = File.join(project_dir, "sessions-index.json")
    end

    if File.exist?(index_path)
      data = JSON.parse(File.read(index_path))
      entries = case data
      when Array then data
      when Hash then data["entries"] || []
      else []
      end
      return entries.each_with_object({}) { |entry, hash| hash[entry["sessionId"]] = entry }
    end

    # Fallback: parse session metadata from JSONL first lines (Codex/Gemini)
    build_index_from_jsonl_meta(project_dir, encoded_name)
  rescue JSON::ParserError, SystemCallError
    # A malformed OR permission-denied/unreadable sessions-index.json must not
    # sink the whole upload. Fall through to an empty index — process_project
    # tolerates missing metadata (`index_data[session_id] || {}`). SystemCallError
    # covers Errno::EACCES (PAXEL-CLIENT-1T) and ENOENT from the File.read.
    {}
  end

  # Build a session index by reading the first line of each JSONL file.
  # Used when sessions-index.json doesn't exist (Codex/Gemini/Cursor sessions).
  def build_index_from_jsonl_meta(project_dir, encoded_name)
    base_dir = File.join(extract_dir, encoded_name)
    Dir.glob(File.join(base_dir, "**", "*.{jsonl,json}")).each_with_object({}) do |path, hash|
      next if path.include?("/subagents/") || path.include?("/tool-results/")
      first_line = File.foreach(path).first rescue next
      next if first_line.blank?
      entry = JSON.parse(first_line) rescue next
      next unless entry.is_a?(Hash) # bare-scalar first line parses to a String/Array — entry.dig below would raise (PAXEL-CLIENT-12)

      file_id = File.basename(path, File.extname(path))

      # Cursor canonical JSONL: first line has _cursor_meta with composerId
      if entry.dig("_cursor_meta", "agent_type") == "cursor"
        cursor_meta = entry["_cursor_meta"]
        first_prompt = cursor_first_prompt(entry.dig("message", "content")).truncate(200)
        hash[file_id] = {
          "sessionId" => file_id,
          "firstPrompt" => first_prompt,
          "agentType" => "cursor"
        }
        next
      end

      # opencode JSONL: first line is an opencode_session_meta marker the client
      # emits (extract_opencode_db). first_prompt is the first user text part;
      # fall back to the LLM-generated session title.
      if entry["type"] == "opencode_session_meta"
        hash[file_id] = {
          "sessionId" => file_id,
          "firstPrompt" => (entry["first_prompt"].presence || entry["title"]).to_s.truncate(200),
          "agentType" => "opencode"
        }
        next
      end

      # Gemini CLI: line 1 is a native session header with sessionId + projectHash
      # and no "type". The Codex-shaped fallback below keys on meta["id"], which the
      # gemini header lacks, so without this branch the session gets no index entry.
      # firstPrompt isn't on line 1 (the conversation is a mutation log), so scan a
      # bounded window for the first real user turn — otherwise gemini sessions would
      # title as a bare UUID in the UI.
      if entry["sessionId"].is_a?(String) && entry["projectHash"].is_a?(String) && !entry.key?("type")
        hash[file_id] = {
          "sessionId" => file_id,
          "firstPrompt" => gemini_first_prompt(path),
          "agentType" => "gemini_cli"
        }
        next
      end

      meta = entry.dig("payload") || entry
      sid = meta["id"]
      next unless sid

      # Use the metadata ID as the session ID key
      hash[file_id] = {
        "sessionId" => file_id,
        "firstPrompt" => codex_first_prompt(path),
        "gitBranch" => meta.dig("git", "branch")
      }
    end
  end

  # Best-effort first user prompt for a Gemini session: scan a bounded window for
  # the first user message (a typed line or inside a $set{messages} snapshot),
  # skipping gemini's synthetic <session_context> preamble. Bounded so we never
  # read a multi-MB session in full just to title it. Self-contained (no normalizer
  # dependency) since the discoverer is also bundled into the client image.
  def gemini_first_prompt(path)
    scanned = 0
    File.foreach(path) do |line|
      break if scanned >= 200
      scanned += 1
      obj = JSON.parse(line) rescue next
      next unless obj.is_a?(Hash)

      candidates =
        if obj["$set"].is_a?(Hash) && obj["$set"]["messages"].is_a?(Array)
          obj["$set"]["messages"]
        elsif obj["type"] == "user"
          [ obj ]
        else
          []
        end

      candidates.each do |m|
        next unless m.is_a?(Hash) && m["type"] == "user"
        text = gemini_prompt_text(m["content"])
        next if text.blank? || text.lstrip.start_with?("<session_context>")
        return text.truncate(200)
      end
    end
    ""
  rescue StandardError
    ""
  end

  def gemini_prompt_text(content)
    case content
    when String then content
    when Array then content.filter_map { |p| p.is_a?(Hash) ? p["text"] : (p if p.is_a?(String)) }.join(" ")
    else ""
    end
  end

  # Codex injects an identical system preamble ("You are Codex…") as
  # base_instructions on every session. Capturing that as firstPrompt (the pre-fix
  # behavior) made episode scoring read five identical "duplicate, zero-direction"
  # prompts and penalize steering (audit CL41). Instead scan a bounded window for
  # the first REAL user turn, skipping the agent preamble, the codex-companion
  # safety-classifier block, and permission/environment boilerplate. Self-contained
  # (no CodexNormalizer dependency) since the discoverer ships in the client image.
  CODEX_SYSTEM_PROMPT_MARKERS = [
    "You are Codex, a coding agent",
    "The following is the Codex agent history whose request action you are assessing",
    "<permissions instructions>",
    "<environment_context>",
    "AGENTS.md instructions",
    "<skills_instructions>"
  ].freeze

  def codex_first_prompt(path)
    scanned = 0
    File.foreach(path) do |line|
      break if scanned >= 200
      scanned += 1
      obj = JSON.parse(line) rescue next
      next unless obj.is_a?(Hash)

      payload = obj["payload"].is_a?(Hash) ? obj["payload"] : obj
      text =
        case payload["type"].to_s
        when "user_message" then payload["message"].to_s
        when "message" then payload["role"] == "user" ? codex_message_text(payload["content"]) : next
        else next
        end

      next if text.blank?
      next if CODEX_SYSTEM_PROMPT_MARKERS.any? { |m| text.include?(m) }
      return text.truncate(200)
    end
    ""
  rescue StandardError
    ""
  end

  def codex_message_text(content)
    case content
    when String then content
    when Array
      content.filter_map { |b| b["text"] if b.is_a?(Hash) && %w[input_text text].include?(b["type"]) }.join("\n")
    else ""
    end
  end

  # First user prompt for a Cursor session. The first emitted line is the first
  # user turn, which stays String-content, but assistant turns are now block
  # arrays — tolerate an Array (first text block) so a future first-line shape
  # change never titles a session with a Ruby array inspect.
  def cursor_first_prompt(content)
    case content
    when String then content
    when Array then content.filter_map { |b| b["text"] if b.is_a?(Hash) && b["type"] == "text" }.first.to_s
    else content.to_s
    end
  end

  def find_all_jsonl_files(encoded_name)
    base_dir = File.join(extract_dir, encoded_name)
    Dir.glob(File.join(base_dir, "**", "*.{jsonl,json}"))
      .reject { |f| f.include?("/_git/") || f.include?("/tool-results/") || File.basename(f) == "sessions-index.json" || File.basename(f) == "_metadata.json" }
      # Drop dangling symlinks up front (the common case): the --since/--project
      # mirror trees are symlinks into the read-only /transcripts mount and can
      # point at a missing target. File.exist? follows the link and is false for a
      # dangling one. The per-session stat loops still rescue the TOCTOU race where
      # a file vanishes after this filter (PAXEL-CLIENT-14).
      .select { |f| File.exist?(f) }
  end
end
