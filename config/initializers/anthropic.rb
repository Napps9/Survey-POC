# Central model selection for all Claude calls.
#
# Every service used to hardcode "claude-sonnet-4-6"; this puts the choice in one
# place so we can (a) flip a task between tiers without editing code and (b) keep
# the costlier Sonnet only where its quality is needed.
#
#   DEFAULT — Sonnet 4.6: complex, high-stakes generation (full survey design,
#             PDF parsing + classification).
#   FAST    — Haiku 4.5: ~1/3 the price, for well-constrained / conversational
#             tasks (single question, translation, results summary + chat).
#
# Both are overridable via ENV so a task can be retuned (or a model id updated)
# without a deploy. FAST defaults to the dated Haiku pin so the first call can't
# 404 on an unrecognised alias.
module ClaudeModels
  DEFAULT = ENV.fetch("CLAUDE_MODEL_DEFAULT", "claude-sonnet-4-6").freeze
  FAST    = ENV.fetch("CLAUDE_MODEL_FAST",    "claude-haiku-4-5-20251001").freeze
end
