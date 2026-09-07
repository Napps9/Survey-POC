# Free-text moderation for respondent answers — the switches and thresholds.
#
# A respondent's typed answer (an open_ended value, or an "Other" write-in) is
# the one place a participant can put anything at all into the platform. Until
# this existed it landed in `responses.answers` verbatim and was readable, that
# instant, on the creator's results page, in every export, and by every AI
# feature that reads answers. The moderator changes the order of events:
#
#   1. Moderation::Scrub    strips the shapes that are always contact details
#                           (emails, phone numbers, URLs, handles) before the
#                           text is stored anywhere. Deterministic, no model.
#   2. Moderation::Hold     moves what is left OUT of the answers JSON and into
#                           a HeldText row, leaving a marker in its place, so
#                           nothing downstream (results, exports, Ask Verto,
#                           the report) can read text nobody has passed yet.
#   3. ScreenHeldTextsJob   asks Claude (TextScreener) to classify each held
#                           text, then releases the clearly-clean ones back into
#                           the answer, removes the clearly-violating ones, and
#                           leaves the rest for a person.
#
# The old platform's moderator screened after the fact, so a flagged answer had
# already been visible. This one holds first: the default outcome for a text
# that nothing has looked at is "not shown", and every failure mode (Claude
# down, budget spent, the job lost to a restart) degrades to that same outcome
# rather than to "shown".
module Moderation
  # The hold itself. On by default everywhere; MODERATION_HOLD_ENABLED=0 is the
  # emergency brake that reverts to storing scrubbed text directly in the
  # answer (the scrub still runs — it has no failure mode worth a switch).
  # The test suite turns this off globally (test/test_helper.rb) and the
  # moderation tests turn it back on, because hundreds of older tests assert
  # the free text they posted is the free text they read back.
  mattr_accessor :hold_enabled, default: ENV.fetch("MODERATION_HOLD_ENABLED", "1") != "0"

  # How a Verto's held texts are decided. `assisted`: Claude's confident
  # verdicts are acted on and only the uncertain ones wait for a person.
  # `review_all`: Claude advises, a person decides every one.
  MODES = %w[assisted review_all].freeze

  # Below this certainty a verdict is advice, not a decision.
  AUTO_THRESHOLD = Float(ENV.fetch("MODERATION_AUTO_THRESHOLD", "0.85"))

  # Screening calls per UTC day, across the platform. A runaway (a bot filling
  # a public link with text) then costs at most a day's cap of Haiku calls and
  # everything past it waits, held, for the next day or a person.
  DAILY_CAP = Integer(ENV.fetch("MODERATION_DAILY_CAP", "2000"))

  # How long a removed text is kept, readable to staff, before the sweep
  # blanks it. Long enough to answer "why was my answer removed?", short
  # enough that the platform isn't warehousing the content it removed.
  REMOVED_RETENTION = 7.days

  # A batch stuck in "screening" this long was claimed by a job that died
  # (Solid Queue runs inside Puma; the memory watchdog restarts Puma).
  SCREENING_STALE_AFTER = 10.minutes

  def self.hold_enabled?
    hold_enabled ? true : false
  end

  # Whether the automated screen can run at all. Without it, held texts go
  # straight to a person (ScreenHeldTextsJob moves them to review), which is
  # the fail-closed outcome — never "unscreened means shown".
  def self.screen_enabled?
    ENV.fetch("MODERATION_SCREEN_ENABLED", "1") != "0" && ENV["ANTHROPIC_API_KEY"].present?
  end

  def self.daily_budget_key(date = Date.current)
    "moderation:screened:#{date.iso8601}"
  end
end
