# Plan-quality signal patterns used by ClientPipeline + BuilderMetrics to
# score plan_files (has_verification, has_alternatives, has_edge_cases).
#
# Extracted from PlanTextDiarizer in the local-models cleanup (PR 2 of the
# series — see local_models_investigation_summary.md). PlanTextDiarizer is
# scheduled for deletion in the same PR; these constants live here so they
# outlive the diarizer service.
#
# Constants match on raw plan-file markdown. They are case-insensitive
# substring regexes, not full grammars — a plan line that mentions the
# concept anywhere counts.
module PlanPatterns
  VERIFICATION_PATTERN = /verif|test|check|confirm|\- \[ \]/i
  ALTERNATIVES_PATTERN = /alternativ|option|instead|tradeoff|approach [A-C]/i
  EDGE_CASES_PATTERN = /edge.case|corner.case|what.if|fallback|error.handling/i
end
