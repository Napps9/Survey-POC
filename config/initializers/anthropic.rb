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

  # Ask Verto's tool rounds only — the calls that pick search terms and question
  # ids, not the one that writes the answer. Defaults to DEFAULT, so out of the
  # box nothing is tiered; set it to FAST on Render to trade quality for speed
  # without a deploy.
  #
  # Two things to know before flipping it, because neither shows up as an error:
  #
  #   * Prompt caches are model-scoped, and Haiku needs a longer prefix than
  #     Sonnet before it caches at all. The ~1.8k-token system block that Sonnet
  #     caches today may simply stop being cached — visible only as
  #     cache_read=0 in the [AnthropicUsage] log line.
  #   * The judgement the rounds make IS the breadth behaviour: noticing that a
  #     search spans four Vertos and fetching across them. That is the first
  #     thing a smaller model drops, and the answer still reads fine when it
  #     does — it just quietly describes one survey again.
  #
  # So: flip it, then read `[AskVerto] turn done … vertos=` before and after.
  ASK_TOOL_ROUNDS = ENV.fetch("CLAUDE_MODEL_ASK_TOOL_ROUNDS", DEFAULT).freeze
end
