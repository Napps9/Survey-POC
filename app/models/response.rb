class Response < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_share, optional: true
  # Which named send link this respondent arrived through, if any. Optional:
  # everyone on the Verto's own /play link has none, and so does every response
  # collected before send links existed.
  belongs_to :survey_link, optional: true
  validates :session_token, presence: true, uniqueness: true

  # The only two states a response is ever in: "started" once it has an answer,
  # "completed" once the respondent reaches the end. Every other model with a
  # status column already declared its values; this one didn't, so the P2-8
  # database CHECK would have surfaced a bad value as a raw DB exception rather
  # than an ordinary validation error.
  STATUSES = %w[started completed].freeze
  validates :status, inclusion: { in: STATUSES }

  # Small-cell suppression for region groupings: any region/results view
  # grouped by region_country should drop groups smaller than this before
  # display, so a single respondent (or a handful) is never singled out on a
  # map or in a per-country breakdown — the same threshold official
  # statistics bodies (e.g. the UK ONS) use for suppressing small cells.
  MIN_REGION_SAMPLE_SIZE = 5

  # Keep the denormalised `answered` flag (answered ≥1 question with a value) in
  # sync on every save, so the dashboard can count responders with a grouped SQL
  # query instead of loading every response's answers JSON. See the
  # add_answered_to_responses migration.
  before_save :sync_answered

  # Live results. Deliberately NOT on every save: /progress writes on each card,
  # so a single respondent saves a dozen times and broadcasting each one would
  # put a burst of renders on the instance for no new information.
  #
  # Only two transitions actually change what a creator sees — a response
  # becoming a responder (its first real answer) and a responder finishing — so
  # those are what broadcast, at most twice per respondent.
  after_commit :broadcast_results_activity, on: [ :create, :update ]

  # How long the respondent took, in whole seconds, or nil until both ends are
  # stamped. Derived rather than stored so there's no third column to keep in
  # sync with the two timestamps.
  #
  # Caveat worth knowing before reading these as engagement data: a submit that
  # was queued offline drains whenever the device next has a network, so
  # completed_at is server-receipt time and the duration can be wildly long.
  def duration_seconds
    return nil if started_at.blank? || completed_at.blank?

    (completed_at - started_at).round
  end

  # THE definition of "this card was answered", for the whole app.
  #
  # It used to exist twice in Ruby and once in JavaScript, and all three
  # disagreed. This one is the canonical Ruby copy: PlayerController#answered?
  # delegates to it, and _isAnswered in player_controller.js mirrors it (pinned
  # by test/system/answer_parity_test.rb).
  #
  # The two things it must get right, because getting them wrong is silent:
  #
  #   * an "Other" write-in IS an answer. `content_answered?` used to check only
  #     `value`, so a respondent whose single answer was typed into the Other
  #     box was stored with `answered = false` and disappeared from every
  #     responder-scoped view — undercounting real, completed responses.
  #   * `present?` is the wrong test for a value. `false.present?` is false in
  #     Rails, so a boolean answer read as unanswered. Emptiness is checked by
  #     shape here instead.
  def self.answered_entry?(entry)
    return false unless entry.is_a?(Hash)
    return true if entry["other"].to_s.strip != ""

    v = entry["value"]
    return v.any? if v.is_a?(Array) || v.is_a?(Hash)
    !(v.nil? || (v.is_a?(String) && v.strip.empty?))
  end

  # Declining consent is not just a timestamp — it means "do not collect my
  # data", so the data goes.
  #
  # A consent gate can sit after some questions on a deck built before gates
  # were hoisted ahead of the first question, and /progress persists answers on
  # every advance. So by the time a respondent read the sheet and declined,
  # their earlier answers were already stored, already counted as a responder,
  # and already feeding the public /results and /regions aggregates. Stamping
  # consent_declined_at changed none of that.
  #
  # The row itself stays: consent_declined_at plus the wording they saw is the
  # evidence that a decline was honoured, and the decline rate is worth knowing.
  # Everything they gave is cleared, including the denormalised region and
  # demographic columns — those are copies of answers, and leaving them would
  # keep exactly the personal data the gate exists to protect. Clearing
  # `answers` also drops `answered` to false via sync_answered, which is what
  # takes the row out of every responder-scoped view.
  def purge_for_declined_consent!
    self.answers = {}
    # status is deliberately left alone: STATUSES is a closed set with a DB
    # CHECK constraint behind it, and a declined respondent is by definition
    # mid-deck, so the row is "started" and already excluded from every
    # status: "completed" count. `answered` going false is what removes it from
    # the responder counts, which is the number that was wrong.
    self.region_country = nil
    self.region_label = nil
    self.demographic_gender = nil
    self.demographic_birth_year = nil
    self.demographic_heritage = nil
    self.demographic_neurodiversity = nil
    self.score = nil
    self.quiz_max = nil
    self.token_totals = {}
    self.respondent_code_digest = nil
    # The leaderboard identity is a durable handle on this person's plays —
    # exactly the kind of thing the decline purge exists to drop.
    self.player_key_digest = nil
  end

  # Whether this response holds a real answer to at least one question.
  # Drives the `answered` column / responder counts.
  def content_answered?
    answers.is_a?(Hash) && answers.values.any? { |a| self.class.answered_entry?(a) }
  end

  private

  def sync_answered
    self.answered = content_answered?
  end

  def broadcast_results_activity
    return unless saved_change_to_answered? || saved_change_to_status?
    # Broadcast when a response BECOMES answered, and also when it STOPS being
    # answered — the decline purge flips answered true→false, and that is the
    # one transition where a creator's live results screen is showing numbers
    # that must go DOWN. The old `return unless answered?` suppressed exactly
    # that broadcast. Still silent for an empty session that never answered.
    return unless answered? || saved_change_to_answered?

    ResultsActivity.broadcast(survey)
  rescue => e
    # A live counter is a nicety. It must never be able to fail the write that
    # stored a respondent's answers.
    ErrorReporting.report("Response#broadcast_results_activity", e, survey_id: survey_id)
  end
end
