# Auto-generated from db/schema.rb by `rake client:generate_schema`
# DO NOT EDIT — changes will be overwritten.
#
# SQLite-compatible subset for the Docker client container.
# Run with: RAILS_ENV=client rails db:schema:load

ActiveRecord::Schema[8.1].define(version: 2026_06_05_104822) do
  create_table "chunks", id: :string, force: :cascade do |t|
    t.text "api_response"
    t.text "content", null: false
    t.integer "content_version"
    t.datetime "created_at", null: false
    t.integer "position", null: false
    t.string "status", default: "pending"
    t.integer "token_estimate", default: 0
    t.string "transcript_session_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_turns", default: 0
    t.index ["transcript_session_id", "position"], name: "index_chunks_on_transcript_session_id_and_position"
    t.index ["transcript_session_id"], name: "index_chunks_on_transcript_session_id"
  end

  create_table "commit_group_sessions", id: :string, force: :cascade do |t|
    t.string "commit_group_id", null: false
    t.float "confidence"
    t.datetime "created_at", null: false
    t.string "link_type"
    t.string "transcript_session_id", null: false
    t.datetime "updated_at", null: false
    t.index ["commit_group_id", "transcript_session_id"], name: "idx_cgs_group_session", unique: true
    t.index ["commit_group_id"], name: "index_commit_group_sessions_on_commit_group_id"
    t.index ["transcript_session_id"], name: "index_commit_group_sessions_on_transcript_session_id"
  end

  create_table "commit_groups", id: :string, force: :cascade do |t|
    t.string "branch"
    t.text "code_review"
    t.integer "code_review_cost_cents"
    t.string "code_review_model"
    t.text "combined_diff"
    t.json "commit_shas", default: []
    t.datetime "created_at", null: false
    t.integer "deletions", default: 0, null: false
    t.integer "diff_lines"
    t.datetime "earliest_commit_at"
    t.string "group_type", null: false
    t.integer "insertions", default: 0, null: false
    t.datetime "latest_commit_at"
    t.integer "pr_number"
    t.string "project_id", null: false
    t.string "status", default: "pending"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["project_id", "status"], name: "index_commit_groups_on_project_id_and_status"
    t.index ["project_id"], name: "index_commit_groups_on_project_id"
  end

  create_table "decisions", id: :string, force: :cascade do |t|
    t.boolean "agent_recognized", default: false, null: false
    t.integer "chain_position"
    t.string "classification_confidence"
    t.datetime "created_at", null: false
    t.text "decision_narrative"
    t.string "decision_type"
    t.string "domain", default: "general", null: false
    t.integer "event_index", null: false
    t.string "exchange_chain_id"
    t.string "law_key"
    t.integer "lock_version", default: 0, null: false
    t.integer "option_count"
    t.text "proposal_text", null: false
    t.string "proposal_type", null: false
    t.text "redacted_proposal_text"
    t.text "redacted_response_text"
    t.string "repository_id", null: false
    t.text "response_text", null: false
    t.integer "response_word_count", default: 0
    t.string "reversibility", default: "unknown", null: false
    t.string "significance", default: "tactical", null: false
    t.string "status", default: "open", null: false
    t.string "transcript_session_id", null: false
    t.datetime "updated_at", null: false
    t.string "upload_id", null: false
    t.index ["exchange_chain_id"], name: "index_decisions_on_exchange_chain_id"
    t.index ["repository_id", "status"], name: "idx_decisions_repo_status"
    t.index ["repository_id"], name: "index_decisions_on_repository_id"
    t.index ["transcript_session_id"], name: "index_decisions_on_transcript_session_id"
    t.index ["upload_id", "domain"], name: "idx_decisions_upload_domain"
    t.index ["upload_id", "law_key"], name: "idx_decisions_upload_law"
    t.index ["upload_id"], name: "index_decisions_on_upload_id"
  end

  create_table "episode_commit_groups", id: :string, force: :cascade do |t|
    t.string "commit_group_id", null: false
    t.datetime "created_at", null: false
    t.string "episode_id", null: false
    t.float "link_confidence"
    t.string "link_type"
    t.datetime "updated_at", null: false
    t.index ["commit_group_id"], name: "index_episode_commit_groups_on_commit_group_id"
    t.index ["episode_id", "commit_group_id"], name: "idx_episode_commit_groups_unique", unique: true
    t.index ["episode_id"], name: "index_episode_commit_groups_on_episode_id"
  end

  create_table "episode_sessions", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "episode_id", null: false
    t.float "link_confidence"
    t.string "link_type"
    t.string "transcript_session_id", null: false
    t.datetime "updated_at", null: false
    t.index ["episode_id", "transcript_session_id"], name: "idx_episode_sessions_unique", unique: true
    t.index ["episode_id"], name: "index_episode_sessions_on_episode_id"
    t.index ["transcript_session_id"], name: "index_episode_sessions_on_transcript_session_id"
  end

  create_table "episodes", id: :string, force: :cascade do |t|
    t.float "confidence"
    t.datetime "created_at", null: false
    t.json "dominant_traits", default: {}
    t.string "episode_type"
    t.json "scores"
    t.string "title", limit: 160
    t.datetime "updated_at", null: false
    t.string "upload_id", null: false
    t.index ["upload_id"], name: "index_episodes_on_upload_id"
  end

  create_table "llm_calls", id: :string, force: :cascade do |t|
    t.string "blob_s3_key"
    t.integer "blob_schema_version", default: 1, null: false
    t.integer "cache_creation_input_tokens"
    t.integer "cache_read_input_tokens"
    t.integer "cost_cents"
    t.datetime "created_at", null: false
    t.float "duration_ms"
    t.string "held_reason"
    t.datetime "held_until"
    t.integer "input_tokens"
    t.integer "max_tokens"
    t.json "messages", default: []
    t.string "model", null: false
    t.integer "output_tokens"
    t.string "provider"
    t.json "response_raw"
    t.text "response_text"
    t.string "service_name", null: false
    t.string "stop_reason"
    t.text "system_prompt"
    t.datetime "updated_at", null: false
    t.string "upload_id"
    t.index ["blob_s3_key"], name: "index_llm_calls_on_blob_s3_key"
    t.index ["created_at"], name: "index_llm_calls_on_created_at"
    t.index ["created_at"], name: "index_llm_calls_on_created_at_for_scrubber"
    t.index ["model"], name: "index_llm_calls_on_model"
    t.index ["service_name", "created_at"], name: "index_llm_calls_on_service_name_and_created_at"
    t.index ["service_name"], name: "index_llm_calls_on_service_name"
    t.index ["upload_id", "created_at"], name: "index_llm_calls_on_upload_id_and_created_at"
    t.index ["upload_id"], name: "index_llm_calls_on_upload_id"
  end

  create_table "outcome_analyses", id: :string, force: :cascade do |t|
    t.datetime "analyzed_at", null: false
    t.string "analyzer_type", null: false
    t.float "confidence", default: 0.5, null: false
    t.datetime "created_at", null: false
    t.string "decision_id", null: false
    t.text "evidence_text"
    t.string "outcome_signal", null: false
    t.string "temporal_layer", null: false
    t.datetime "updated_at", null: false
    t.index ["decision_id", "temporal_layer"], name: "idx_outcome_analyses_decision_layer"
    t.index ["decision_id"], name: "index_outcome_analyses_on_decision_id"
  end

  create_table "plan_files", id: :string, force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.text "diarized_content"
    t.string "filename", null: false
    t.string "full_path", null: false
    t.string "transcript_session_id", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
    t.string "write_timestamp"
    t.index ["transcript_session_id", "filename", "version"], name: "idx_plan_files_session_file_version", unique: true
    t.index ["transcript_session_id"], name: "index_plan_files_on_transcript_session_id"
  end

  create_table "projects", id: :string, force: :cascade do |t|
    t.json "author_recent_commits", default: []
    t.text "code_summary"
    t.json "codebase_profile", default: {}
    t.json "commit_diffs", default: {}
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "encoded_name", null: false
    t.json "git_metrics", default: {}
    t.string "git_remote"
    t.text "narrative_summary"
    t.string "original_path"
    t.json "recent_commits"
    t.text "repo_file_tree"
    t.string "repository_id"
    t.integer "sessions_count", default: 0
    t.datetime "updated_at", null: false
    t.string "upload_id", null: false
    t.index ["repository_id"], name: "index_projects_on_repository_id"
    t.index ["upload_id", "encoded_name"], name: "index_projects_on_upload_id_and_encoded_name", unique: true
    t.index ["upload_id"], name: "index_projects_on_upload_id"
  end

  create_table "repositories", id: :string, force: :cascade do |t|
    t.integer "committers_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.string "git_remote", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["git_remote"], name: "index_repositories_on_git_remote", unique: true
  end

  create_table "transcript_sessions", id: :string, force: :cascade do |t|
    t.json "active_time_windows", default: [], null: false
    t.string "agent_type", default: "claude_code", null: false
    t.integer "assistant_message_count", default: 0
    t.datetime "created_at", null: false
    t.string "cross_tool_origin"
    t.string "data_quality", default: "full", null: false
    t.json "dispatch_metadata", default: {}, null: false
    t.integer "file_mtime"
    t.integer "file_size_bytes", default: 0
    t.string "first_prompt", limit: 1000
    t.string "git_branch"
    t.json "git_commits", default: [], null: false
    t.boolean "is_subagent", default: false, null: false
    t.integer "message_count", default: 0
    t.json "models_used", default: {}, null: false
    t.text "narrative"
    t.datetime "narrative_completed_at"
    t.integer "narrative_cost_cents"
    t.text "narrative_eval"
    t.string "narrative_eval_model"
    t.integer "narrative_input_tokens"
    t.string "narrative_model"
    t.integer "narrative_output_tokens"
    t.text "narrative_raw_response"
    t.datetime "narrative_started_at"
    t.string "narrative_status", default: "pending"
    t.string "parent_session_id"
    t.text "pr_diff"
    t.integer "pr_number"
    t.string "pr_repo"
    t.string "pr_url"
    t.string "project_id", null: false
    t.json "quality_flags", default: {}, null: false
    t.datetime "session_created_at"
    t.json "session_events"
    t.string "session_id", null: false
    t.string "session_intent"
    t.datetime "session_modified_at"
    t.json "session_signals", default: {}
    t.integer "skipped_lines_count", default: 0
    t.string "source_dir"
    t.string "status", default: "pending"
    t.json "steering_trace", default: {}
    t.string "summary", limit: 2000
    t.integer "tool_use_count", default: 0
    t.json "tools_used"
    t.string "triggered_by_confidence"
    t.string "triggered_by_id"
    t.datetime "updated_at", null: false
    t.text "user_highlights"
    t.integer "user_message_count", default: 0
    t.index ["data_quality"], name: "index_transcript_sessions_on_data_quality"
    t.index ["parent_session_id"], name: "index_transcript_sessions_on_parent_session_id"
    t.index ["project_id", "session_id"], name: "index_transcript_sessions_on_project_id_and_session_id", unique: true
    t.index ["project_id"], name: "index_transcript_sessions_on_project_id"
    t.index ["session_intent"], name: "index_transcript_sessions_on_session_intent"
    t.index ["triggered_by_id"], name: "index_transcript_sessions_on_triggered_by_id"
  end

  create_table "uploads", id: :string, force: :cascade do |t|
    t.text "aggregate_narrative"
    t.integer "analyzed_sessions_count", default: 0
    t.bigint "api_token_id"
    t.json "badges", default: [], null: false
    t.json "builder_profile_data", default: {}
    t.datetime "builder_profile_generated_at"
    t.text "builder_profile_narrative"
    t.text "builder_profile_roast"
    t.string "builder_profile_status", default: "pending"
    t.json "builder_profile_vague_prompts"
    t.text "chat_greeting"
    t.json "claims_v1", default: {}, null: false
    t.string "client_request_id"
    t.json "client_telemetry"
    t.string "commit_group_status", default: "not_applicable"
    t.string "committer_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.json "decision_insights"
    t.text "error_message"
    t.boolean "eval_mode", default: false
    t.json "fact_check_results"
    t.text "growth_edge"
    t.json "judge_results", default: {}
    t.string "judge_status"
    t.text "key_decisions_narrative"
    t.json "metrics_manifest", default: {}
    t.json "parallelism_signals", default: {}, null: false
    t.json "previous_results"
    t.json "processing_log", default: [], null: false
    t.json "prompt_versions"
    t.integer "remaining_chunks_count", default: 0
    t.integer "remaining_commit_groups_count", default: 0
    t.integer "remaining_sessions_count", default: 0
    t.string "scoring_pipeline"
    t.boolean "shared", default: false, null: false
    t.string "slack_thread_ts"
    t.string "slug", null: false
    t.string "source", default: "direct_upload"
    t.string "status", default: "pending", null: false
    t.integer "subagent_analyzed_count", default: 0, null: false
    t.integer "subagent_sessions_count", default: 0, null: false
    t.json "throughput_report", default: {}
    t.integer "total_commit_groups_count", default: 0
    t.integer "total_cost_cents", default: 0
    t.integer "total_input_tokens", default: 0
    t.integer "total_output_tokens", default: 0
    t.integer "total_sessions_count", default: 0
    t.datetime "updated_at", null: false
    t.string "user_id"
    t.json "v3_results", default: {}
    t.string "v3_scoring_status"
    t.string "verdict_line"
    t.index ["api_token_id"], name: "index_uploads_on_api_token_id"
    t.index ["committer_id"], name: "index_uploads_on_committer_id"
    t.index ["created_at"], name: "index_uploads_on_created_at"
    t.index ["slug"], name: "index_uploads_on_slug", unique: true
    t.index ["user_id"], name: "index_uploads_on_user_id"
  end

end
