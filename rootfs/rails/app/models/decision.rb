class Decision < ApplicationRecord
  # pgvector embedding — only available in Postgres (server-side)
  if connection.adapter_name.include?("PostgreSQL")
    has_neighbors :embedding
  end

  belongs_to :repository
  belongs_to :upload
  belongs_to :transcript_session

  has_many :outcome_analyses, dependent: :destroy
  has_many :outgoing_edges, class_name: "DecisionEdge", foreign_key: :source_decision_id, dependent: :destroy
  has_many :incoming_edges, class_name: "DecisionEdge", foreign_key: :target_decision_id, dependent: :destroy

  PROPOSAL_TYPES = %w[options question tradeoff counter_proposal proactive_insight].freeze
  DOMAINS = %w[architecture debugging scope quality product tooling general].freeze
  SIGNIFICANCE_LEVELS = %w[strategic moderate tactical].freeze
  REVERSIBILITY_LEVELS = %w[one_way reversible unknown].freeze
  STATUSES = %w[open confirmed reversed superseded evolved].freeze
  DECISION_TYPES = %w[strategic_redirect technical_catch product_insight option_selection].freeze

  validates :proposal_text, presence: true
  validates :response_text, presence: true
  validates :proposal_type, inclusion: { in: PROPOSAL_TYPES }
  validates :domain, inclusion: { in: DOMAINS }
  validates :significance, inclusion: { in: SIGNIFICANCE_LEVELS }
  validates :reversibility, inclusion: { in: REVERSIBILITY_LEVELS }
  validates :status, inclusion: { in: STATUSES }
  validates :event_index, presence: true
  validates :decision_type, inclusion: { in: DECISION_TYPES }, allow_nil: true
  validates :law_key, inclusion: { in: -> { DecisionLawCatalog.keys } }, allow_nil: true

  scope :open, -> { where(status: "open") }
  scope :strategic, -> { where(significance: "strategic") }
  scope :for_repository, ->(repo) { where(repository: repo) }
  scope :embedded, -> { where.not(embedding: nil) }
  scope :by_event_order, -> { order(:event_index) }
  scope :counter_proposals, -> { where(proposal_type: "counter_proposal") }
  scope :proactive_insights, -> { where(proposal_type: "proactive_insight") }
  scope :agent_recognized, -> { where(agent_recognized: true) }
  scope :in_chain, -> { where.not(exchange_chain_id: nil) }
  scope :for_chain, ->(chain_id) { where(exchange_chain_id: chain_id).order(:chain_position) }
  scope :high_value, -> { where(decision_type: %w[strategic_redirect technical_catch product_insight]) }
  scope :classified, -> { where.not(decision_type: nil) }
  scope :with_law, -> { where.not(law_key: nil) }
  scope :for_law, ->(key) { where(law_key: key) }

  # Find similar decisions within a repository using pgvector.
  # Returns decisions ordered by cosine similarity (closest first).
  def self.search_similar(query_embedding, repository:, limit: 3, exclude_ids: [])
    scope = for_repository(repository).embedded
    scope = scope.where.not(id: exclude_ids) if exclude_ids.any?
    scope.nearest_neighbors(:embedding, query_embedding, distance: "cosine")
         .limit(limit)
  end

  def strategic?
    significance == "strategic"
  end

  def counter_proposal?
    proposal_type == "counter_proposal"
  end

  def proactive_insight?
    proposal_type == "proactive_insight"
  end

  def in_chain?
    exchange_chain_id.present?
  end

  def chain_decisions
    return Decision.none unless in_chain?
    Decision.for_chain(exchange_chain_id)
  end

  def high_value?
    %w[strategic_redirect technical_catch product_insight].include?(decision_type)
  end

  def one_way_door?
    reversibility == "one_way"
  end

  def latest_outcome
    outcome_analyses.order(analyzed_at: :desc).first
  end

  def outcome_signal
    latest = latest_outcome
    latest&.outcome_signal || "unknown"
  end

  # Deterministic-offload companion signal. The LLM classifier tags
  # decisions with law_key "deterministic-offload" when the decision
  # text looks like the essay pattern (builder directs recurring latent
  # reasoning into a script / rake task / CLI tool). Classifier
  # precision on that tag is low (~0% on a 2026-04-23 prod sample) —
  # the LLM matches "write a script" without gating on the
  # recurring-reasoning clause. See docs/observations/classifier_law_
  # measurement_post_codify_offload.md.
  #
  # This method adds the deterministic *action* signal: did the
  # agent actually write to a scripts/lib-tasks/bin path within a few
  # events after the decision? Composing LLM intent × action gives a
  # high-precision "directive was followed by a durable script" signal
  # that survives the classifier's text-pattern-matching weakness.
  OFFLOAD_TASK_PATH_RE = %r{(^|/)(scripts/|lib/tasks/|bin/)}.freeze
  # Known false-positive path prefixes — the base pattern matches anywhere
  # the segment appears after a `/`, which catches vendored gem binaries
  # (`vendor/bin/rubocop`), tmp artifacts (`/tmp/bin/foo`), frontend bundles
  # (`app/javascript/scripts/index.js`), and test-fixture scripts. None of
  # those are "durable scripts the builder authored to offload recurring
  # reasoning." Reject them after the base match.
  OFFLOAD_EXCLUDE_RE = %r{(^|/)(vendor/|tmp/|node_modules/|app/javascript/|test/scripts/|spec/scripts/|lib/scripts/)}.freeze
  OFFLOAD_EVIDENCE_WINDOW = 5
  OFFLOAD_EVIDENCE_EVENT_TYPES = %w[file_edit file_create].freeze
  OFFLOAD_EVIDENCE_DIRECTIONS = %i[after before].freeze

  def self.offload_task_path?(path)
    s = path.to_s
    return false unless s.match?(OFFLOAD_TASK_PATH_RE)
    !s.match?(OFFLOAD_EXCLUDE_RE)
  end

  # Returns the list of file_edit / file_create events within
  # OFFLOAD_EVIDENCE_WINDOW events of this decision that touch an offload
  # task path, or [] if none. Nil-safe when session_events is missing or
  # event_index is out of range.
  #
  # direction:
  #   :after (default) — "did the agent create/edit a task script because
  #     of this directive?" — catches the offload pattern where the
  #     builder says "let's write a script for X" and the agent builds it.
  #   :before — "did this directive invoke a pre-existing task script?" —
  #     catches the companion pattern where the builder says
  #     "run bin/db-export" / "use scripts/context-now.mjs" to reuse a
  #     script that a prior session created. Observation doc
  #     (deterministic_offload_companion_signal.md) called this out as a
  #     follow-up; the LLM classifier can tag those as offload even
  #     though the action is an invocation, not a creation.
  def offload_file_edit_evidence(window: OFFLOAD_EVIDENCE_WINDOW, direction: :after)
    events = transcript_session&.session_events
    return [] unless events.is_a?(Array) && event_index.is_a?(Integer) && !event_index.negative?
    return [] unless OFFLOAD_EVIDENCE_DIRECTIONS.include?(direction)
    # :after clamps window_end at events.size - 1 naturally; :before does not
    # (its window_end = event_index - 1), so an event_index past the end of
    # events would produce a valid-looking range that slices past the array
    # and returns nil. Explicit guard keeps behavior symmetric.
    return [] if event_index >= events.size

    window_start, window_end = case direction
    when :after
      [ event_index + 1, [ event_index + window, events.size - 1 ].min ]
    when :before
      [ [ event_index - window, 0 ].max, event_index - 1 ]
    end
    return [] if window_start > window_end

    events[window_start..window_end].select do |e|
      e.is_a?(Hash) &&
        OFFLOAD_EVIDENCE_EVENT_TYPES.include?(e["type"]) &&
        self.class.offload_task_path?(e["path"])
    end
  end

  # Composite: LLM tagged as deterministic-offload AND at least one
  # file edit to an offload path immediately followed. This is the
  # high-precision "intent + action" cell of the 2×2 matrix. Default
  # direction is :after (script-creation pattern); callers that care
  # about script-invocation-of-pre-existing-scripts should invoke
  # `offload_file_edit_evidence(direction: :before)` explicitly.
  def deterministic_offload_verified?
    law_key == "deterministic-offload" && offload_file_edit_evidence.any?
  end

  # Enforce-safety-rails companion signal. The law (per
  # docs/decision_types/enforce-safety-rails.md) is about the builder
  # establishing checkpoints for destructive/autonomous/irreversible
  # actions. The LLM classifier tags both the verbal-rule variant
  # ("never kill jobs without asking") and the code-artifact variant
  # ("add a regression test so we can't hit this again").
  #
  # This composite fires when the verbal-rule OR code-artifact variant is
  # followed by a file edit to either a code-level check path (spec/,
  # test files, .rubocop.yml, constraint migrations, .github/workflows/)
  # OR a durable rule-storage path (CLAUDE.md, AGENTS.md, .cursorrules,
  # skills/, docs/runbooks/). Intentional overlap with a future
  # codify-the-lesson composite — the laws themselves overlap (a builder
  # who writes "never kill jobs" to CLAUDE.md demonstrates both), and
  # narrowing one composite at the expense of the other would be
  # arbitrary.
  SAFETY_RAILS_PATH_RE = %r{
    # Code-level checks
    (^|/)spec/ |
    (^|/)test/ |
    _spec\.rb\z |
    _test\.rb\z |
    (^|/)\.rubocop\.yml\z |
    # Constraint-adding migrations only (remove_constraint / drop_constraint
    # are the OPPOSITE of a safety rail; require an add-intent verb).
    (^|/)db/migrate/[^/]*(?:add|create|enforce|require)[^/]*constraint |
    (^|/)\.github/workflows/ |
    # Rule-storage files — durable artifacts read by future sessions
    (^|/)CLAUDE\.md\z |
    (^|/)AGENTS\.md\z |
    (^|/)\.cursorrules\z |
    # .claude/skills/ only (anchored); a bare top-level skills/ is too often
    # a product code directory in unrelated projects. All prod hits matched
    # .claude/skills/ variants anyway (measurement on 2026-04-24).
    (^|/)\.claude/skills/ |
    (^|/)docs/runbooks/
  }x.freeze
  SAFETY_RAILS_EVIDENCE_WINDOW = 5
  SAFETY_RAILS_EVIDENCE_EVENT_TYPES = %w[file_edit file_create].freeze

  def self.safety_rails_path?(path)
    path.to_s.match?(SAFETY_RAILS_PATH_RE)
  end

  # Returns the list of file_edit / file_create events within
  # SAFETY_RAILS_EVIDENCE_WINDOW events AFTER this decision that touch a
  # safety-rail path, or [] if none. Nil-safe when session_events is
  # missing or event_index is out of range. :after direction only —
  # `:before` (using a pre-existing safety rail) is a qualitatively
  # different move and not part of this composite.
  def safety_rails_file_edit_evidence(window: SAFETY_RAILS_EVIDENCE_WINDOW)
    events = transcript_session&.session_events
    return [] unless events.is_a?(Array) && event_index.is_a?(Integer) && !event_index.negative?
    return [] if event_index >= events.size

    window_start = event_index + 1
    window_end = [ event_index + window, events.size - 1 ].min
    return [] if window_start > window_end

    events[window_start..window_end].select do |e|
      e.is_a?(Hash) &&
        SAFETY_RAILS_EVIDENCE_EVENT_TYPES.include?(e["type"]) &&
        self.class.safety_rails_path?(e["path"])
    end
  end

  # Composite: LLM tagged as enforce-safety-rails AND at least one
  # file edit to a safety-rail path immediately followed. Tightens the
  # Rare Moves surface from the bare law_key match (v1) to the
  # "intent + action" subset where the rail is a concrete artifact.
  def safety_rails_verified?
    law_key == "enforce-safety-rails" && safety_rails_file_edit_evidence.any?
  end

  # Codify-the-lesson companion signal. Per
  # docs/decision_types/codify-the-lesson.md the law fires when the
  # builder directs the agent to write a rule/directive/procedure into
  # a DURABLE artifact that future sessions read — CLAUDE.md, AGENTS.md,
  # .cursorrules, skills, linter config, CI check, README. Counter-
  # examples (per the doc): plan files, handoff docs, feature docs, and
  # code comments — those are ephemeral notes, not standing rules.
  #
  # The bare law_key match was ~65% cohort-coverage on prod post-backfill
  # (#666 scan) — well above the "rare moves" threshold. The composite
  # filters to decisions that actually produced a durable-rule artifact
  # within 5 events.
  #
  # Overlaps intentionally with safety_rails_verified? (both include
  # CLAUDE.md/AGENTS.md/.cursorrules/.claude-skills/runbooks) — each is
  # gated by its own law_key so the same decision can't pass both. The
  # codify-specific additions here are `skills/**/SKILL.md` (non-.claude
  # skills), `docs/decision_types/`, and `README.md`; the codify-specific
  # omissions are spec/test files and constraint migrations.
  CODIFY_PATH_RE = %r{
    # Agent rule files
    (^|/)CLAUDE\.md\z |
    (^|/)AGENTS\.md\z |
    (^|/)\.cursorrules\z |
    # Skill artifacts — .claude/skills/ prefix OR any-depth skills/**/SKILL.md
    # (nested skill trees like skills/team/webhooks/SKILL.md are legit
    # per docs/decision_types/codify-the-lesson.md).
    (^|/)\.claude/skills/ |
    (^|/)skills/.+/SKILL\.md\z |
    # Runbooks and rule catalogs (standing instructions)
    (^|/)docs/runbooks/ |
    (^|/)docs/decision_types/ |
    # Linter config (per law doc: "a linter config")
    (^|/)\.rubocop\.yml\z |
    # CI checks (per law doc: "or a CI check")
    (^|/)\.github/workflows/
    #
    # README.md was previously a CODIFY_PATH_RE branch (per law Example 3:
    # "update the team's README so the next migration doesn't skip the
    # verification step"). Hand-grade of all 11 verified README hits on
    # 2026-04-26 (docs/observations/codify_readme_handgrade_2026_04_25.md)
    # showed strict precision of 18% (2/11 TP) — overwhelmingly dominated
    # by feature/setup-doc edits ("create a readme for the dev environment",
    # "create a readme that has install instructions") plus handoff-doc
    # READMEs explicitly excluded by Counter-Example 3 of the law. The 2-3
    # legitimate "leave a note for future reference" hits are
    # indistinguishable at the path level from the FPs, so the LLM tag is
    # the only place that signal can land. Removing the branch is the
    # cleaner trade-off than tightening to repo-root only — most user
    # repos have a top-level README that's still a feature doc.
  }x.freeze

  # Exclude known false-positive path prefixes that would otherwise match
  # CODIFY_PATH_RE branches — vendored gem READMEs, node_modules, spec
  # fixtures, tmp artifacts. Mirrors OFFLOAD_EXCLUDE_RE (PR #688). Dual-
  # review (Codex + Opus on PR #688) flagged that README.md was matching
  # `vendor/foo/README.md`, `node_modules/.../README.md`, etc.
  CODIFY_EXCLUDE_RE = %r{(^|/)(vendor/|tmp/|node_modules/|spec/fixtures/|test/fixtures/)}.freeze
  CODIFY_EVIDENCE_WINDOW = 5
  CODIFY_EVIDENCE_EVENT_TYPES = %w[file_edit file_create].freeze

  def self.codify_path?(path)
    s = path.to_s
    return false unless s.match?(CODIFY_PATH_RE)
    !s.match?(CODIFY_EXCLUDE_RE)
  end

  # Returns the list of file_edit / file_create events within
  # CODIFY_EVIDENCE_WINDOW events AFTER this decision that touch a
  # codify path, or [] if none. Nil-safe when session_events is missing
  # or event_index is out of range. :after direction only — "edit a
  # pre-existing CLAUDE.md" is not the codify move; the codify move is
  # CAUSING a rule to land.
  def codify_file_edit_evidence(window: CODIFY_EVIDENCE_WINDOW)
    events = transcript_session&.session_events
    return [] unless events.is_a?(Array) && event_index.is_a?(Integer) && !event_index.negative?
    return [] if event_index >= events.size

    window_start = event_index + 1
    window_end = [ event_index + window, events.size - 1 ].min
    return [] if window_start > window_end

    events[window_start..window_end].select do |e|
      e.is_a?(Hash) &&
        CODIFY_EVIDENCE_EVENT_TYPES.include?(e["type"]) &&
        self.class.codify_path?(e["path"])
    end
  end

  # Composite: LLM tagged as codify-the-lesson AND at least one
  # file edit to a rule-storage path immediately followed.
  def codify_verified?
    law_key == "codify-the-lesson" && codify_file_edit_evidence.any?
  end
end
