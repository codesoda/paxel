module TranscriptPatterns
  extend ActiveSupport::Concern

  # Tool use patterns (from raw JSONL tool_use input hashes — not condensed text)
  # These are only used as fallback when parsing condensed text.
  # EventExtractor reads structured tool_use blocks directly.

  # Test result patterns (from tool_result text / bash output)
  RSPEC_RESULT  = /(\d+)\s+examples?,\s+(\d+)\s+failures?(?:,\s+(\d+)\s+pending)?/
  PYTEST_RESULT = /(\d+)\s+passed(?:,\s+(\d+)\s+failed)?/
  JEST_RESULT   = /Tests:\s+(?:(\d+)\s+failed,\s+)?(\d+)\s+passed/
  CARGO_RESULT  = /test result:.*?(\d+)\s+passed;\s+(\d+)\s+failed/
  GO_TEST_RESULT = /^(ok|FAIL)\s+(\S+)\s+[\d.]+s/m

  # Git patterns
  GIT_COMMIT_OUTPUT = /\[[\w\/.-]+\s+(?:\(root-commit\)\s+)?([0-9a-f]{7,40})\]/
  GIT_BRANCH_FROM_COMMIT = /\[([\w\/.-]+)\s+(?:\(root-commit\)\s+)?[0-9a-f]{7,40}\]/
  GIT_ON_BRANCH = /On branch ([\w\/.-]+)/
  GIT_SWITCH_BRANCH = /Switched to (?:a new )?branch '([\w\/.-]+)'/
  GIT_CHECKOUT_CMD = /git (?:checkout|switch)\s+(?:-[bc]\s+)?(\S+)/
  GIT_COMMIT_MSG_DOUBLE = /git commit.*?-m\s+"((?:[^"\\]|\\.)*)"/
  GIT_COMMIT_MSG_SINGLE = /git commit.*?-m\s+'((?:[^'\\]|\\.)*)'/
  GIT_COMMIT_MSG_HEREDOC = /<<'?EOF'?\s*\n(.*?)\n\s*EOF/m
  GIT_DIFF_STAT = /(\d+)\s+files?\s+changed(?:,\s+(\d+)\s+insertions?\(\+\))?(?:,\s+(\d+)\s+deletions?\(-\))?/
  GIT_PUSH = /git push/

  # Error patterns (from tool_result content)
  ERROR_LINE = /(?:Error|Exception|FAILED|Errno|LoadError|NoMethodError|NameError|TypeError|ArgumentError|SyntaxError)[:!\s]/i

  # Redirect/reversal patterns (shared by SteeringTraceExtractor and InSessionAnalyzer)
  REDIRECT_INDICATORS = /\b(actually|instead|wait|change|switch|pivot|different approach|on second thought)\b/i
  REVERSAL_INDICATORS = /\b(actually|no|wait|scratch that|undo|revert|go back|different approach|instead|never mind)\b/i

  # Agent proposal patterns (for decision exchange detection)
  OPTION_PATTERNS = [
    /(?:option|approach|alternative|choice)\s*(?:\d|[A-C])/i,
    /\d+[.)]\s+\*\*[^*]+\*\*/,
    /(?:we could|you could|options are|alternatives):/i,
    /(?:here are|there are)\s+(?:\d+|several|a few)\s+(?:options|approaches|ways)/i,
    /(?:trade-?off|pros?\s+and\s+cons?|versus|vs\.?)\b/i
  ].freeze

  QUESTION_PATTERNS = [
    /(?:would you (?:like|prefer|rather)|what (?:do you think|approach)|should (?:I|we)|how (?:do you want|should))/i,
    /(?:which (?:option|approach)|do you want me to)\b/i
  ].freeze

  # Option reference patterns (user selecting from proposed options)
  OPTION_REFERENCE_PATTERNS = [
    /\b(?:option|approach|alternative|choice)\s*(?:[A-C]|\d)\b/i,
    /\bgo\s+with\s+(?:option|approach|#?\s*\d|[A-C])\b/i,
    /\b(?:the\s+)?(?:first|second|third|last)\s+(?:option|approach|one)\b/i,
    /\blet'?s?\s+(?:do|go|try)\s+(?:option|approach|#?\s*\d|[A-C])\b/i,
    /\b(?:prefer|like|pick|choose)\s+(?:option|approach)?\s*(?:\d|[A-C])\b/i
  ].freeze

  # Agent amplification patterns (agent recognizing user insight as pivotal)
  AMPLIFICATION_PATTERNS = [
    /\b(?:major|key|great|important|critical)\s+(?:insight|point|observation|suggestion)\b/i,
    /\bfundamentally\s+(?:different|change|better|rethink)\b/i,
    /\b(?:game\s+changer|breakthrough|paradigm)\b/i,
    /\b(?:you'?re?\s+right|excellent\s+(?:point|suggestion|idea)|this\s+changes)\b/i,
    /\b(?:this\s+is\s+(?:much\s+)?better|much\s+cleaner|significantly\s+(?:improve|better|cleaner))\b/i,
    /\b(?:hadn'?t?\s+(?:considered|thought)|never\s+(?:considered|occurred))\b/i,
    # Analytical recognition (agent analyzes rather than evaluates)
    /\b(?:completely|entirely|totally)\s+different\s+(?:task|approach|direction|problem|framing)\b/i,
    /\b(?:core|central|fundamental)\s+(?:insight|realization|observation)\b/i,
    /\bfundamental\s+(?:rearchitecture|reimagining|redesign|rebuild|rewrite|rethink|shift)\b/i,
    /\buser(?:'s|s)?\s+(?:core|key|main|primary|central)\s+(?:insight|point|ask|request|concern)\b/i
  ].freeze

  # Proactive reframe patterns (user-initiated paradigm shifts)
  PROACTIVE_REFRAME_PATTERNS = [
    /\b(?:instead\s+of|shift\s+to|the\s+real\s+(?:issue|problem|question)\s+is)\b/i,
    /\b(?:rethink|fundamentally|paradigm|categorically\s+different)\b/i,
    /\b(?:the\s+whole\s+approach|what\s+if\s+we|completely\s+different)\b/i,
    /\b(?:we\s+should\s+(?:actually|really)|the\s+better\s+way|forget\s+(?:that|this))\b/i
  ].freeze

  # Noise filters for proactive insight detection
  MIN_PROACTIVE_WORDS = 20
  SESSION_CONTINUATION_PREFIX = "This session is being continued".freeze
  PLAN_PASTE_PREFIX = "Implement the following plan".freeze
end
