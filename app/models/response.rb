class Response < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_share, optional: true
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
    return unless answered? # an empty, abandoned session isn't news

    ResultsActivity.broadcast(survey)
  rescue => e
    # A live counter is a nicety. It must never be able to fail the write that
    # stored a respondent's answers.
    ErrorReporting.report("Response#broadcast_results_activity", e, survey_id: survey_id)
  end
end
