# Screens one response's held free text (HeldText) and acts on the verdicts.
#
# Enqueued by Moderation::Hold a few seconds after a write, once per response
# per window, so a respondent's answers arriving one card at a time are
# screened in one Claude call. The policy — what a verdict means — lives here:
#
#   safeguarding                        → status "safeguarding", for a person
#   review_all Verto, or certainty low  → status "review", for a person
#   clean, certain                      → released into the answer
#   a violation, certain                → removed (marker left in the answer)
#
# Everything that is not a decision leaves the text held: the screen being off,
# the daily budget spent, Claude erroring or returning no verdict. After
# MAX_ATTEMPTS failures a text goes to a person rather than looping.
class ScreenHeldTextsJob < ApplicationJob
  queue_as :default

  BATCH        = 20
  MAX_ATTEMPTS = 3
  RETRY_WAIT   = 2.minutes

  discard_on StandardError do |job, error|
    ErrorReporting.report("ScreenHeldTextsJob", error, response_id: job.arguments.first)
  end

  def perform(response_id)
    response = Response.find_by(id: response_id)
    return unless response

    @claimed = claim(response)
    return if @claimed.empty?

    survey   = response.survey
    deferred = false

    if !Moderation.screen_enabled?
      @claimed.each { |row| row.refer!(note: "Automated screen is off; needs a person.") }
    elsif !within_budget?(@claimed.size)
      @claimed.each { |row| row.refer!(note: "Daily screening budget reached; needs a person.") }
    else
      fresh = reuse_prior_decisions(@claimed)
      deferred = screen!(fresh, survey) if fresh.any?
    end

    # More to do for this response: a batch larger than BATCH, or texts put
    # back to pending for a retry. Retries wait; a plain continuation doesn't.
    return unless response.held_texts.screenable.exists?

    self.class.set(wait: deferred ? RETRY_WAIT : 0).perform_later(response.id)
  rescue => e
    release_claim!
    raise e
  end

  private

  # pending → screening for up to BATCH rows, so a second job for the same
  # response (the sweep re-enqueues generously) works a disjoint set or none.
  def claim(response)
    # The sweep spends an attempt each time it releases a dead job's claim, so
    # a text can reach the limit while still pending. It goes to a person here
    # rather than sitting unclaimable while the sweep re-enqueues it forever.
    response.held_texts.screenable.where(screen_attempts: MAX_ATTEMPTS..)
            .update_all(status: "review", verdict_note: "Automated screen failed #{MAX_ATTEMPTS} times; needs a person.",
                        updated_at: Time.current)

    ids = response.held_texts.screenable.order(:id).limit(BATCH).pluck(:id)
    return [] if ids.empty?

    HeldText.where(id: ids, status: "pending").update_all(status: "screening", updated_at: Time.current)
    HeldText.where(id: ids, status: "screening").order(:id).to_a
  end

  # Anything still claimed when the job dies goes back to pending; the
  # scheduled retry or the sweep picks it up.
  def release_claim!
    return if @claimed.blank?

    HeldText.where(id: @claimed.map(&:id), status: "screening")
            .update_all(status: "pending", updated_at: Time.current)
  end

  # A platform-wide cap on screening calls per UTC day (Moderation::DAILY_CAP).
  # Not atomic — two jobs can both read under the cap — but the cap is a
  # backstop against a runaway, not an accounting line.
  def within_budget?(count)
    key  = Moderation.daily_budget_key
    used = Rails.cache.read(key).to_i
    return false if used + count > Moderation::DAILY_CAP

    Rails.cache.write(key, used + count, expires_in: 2.days)
    true
  end

  # Identical text already decided in this Verto ("nothing", "idk", the same
  # pasted slogan) takes the same decision without another call. Safeguarding
  # is never reused: each disclosure is read by a person.
  def reuse_prior_decisions(rows)
    rows.reject do |row|
      prior = HeldText.where(survey_id: row.survey_id, text_digest: row.text_digest)
                      .where.not(id: row.id).where(status: %w[released removed])
                      .order(:id).last
      next false unless prior

      row.assign_attributes(category: prior.category, certainty: prior.certainty,
                            verdict_note: prior.verdict_note, screened_at: Time.current)
      note = "Same text as an earlier answer already #{prior.status}."
      prior.status == "released" ? row.release!(auto: true, note: note) : row.remove!(auto: true, note: note)
      true
    end
  end

  # Returns whether anything was deferred for a retry.
  def screen!(rows, survey)
    items  = rows.each_with_index.map { |row, i| { index: i + 1, text: row.text, question: row.question } }
    result = TextScreener.new.call(items, audience_age: survey.audience_age)

    deferred = false
    rows.each_with_index do |row, i|
      verdict = result[:ok] ? result[:verdicts][i + 1] : nil
      if verdict
        apply!(row, survey, verdict)
      else
        deferred |= defer!(row, result[:ok] ? "no verdict for this text" : result[:error])
      end
    end
    deferred
  end

  def apply!(row, survey, verdict)
    row.assign_attributes(category: verdict.category, certainty: verdict.certainty,
                          verdict_note: verdict.note, screened_at: Time.current)

    if verdict.category == "safeguarding"
      row.update!(status: "safeguarding")
    elsif survey.moderation_mode == "review_all" || verdict.certainty < Moderation::AUTO_THRESHOLD
      row.update!(status: "review")
    elsif verdict.category == "clean"
      row.release!(auto: true, note: verdict.note)
    elsif TextScreener::VIOLATIONS.include?(verdict.category)
      row.remove!(auto: true, note: verdict.note)
    else
      row.update!(status: "review")
    end
  end

  # Back to pending for another go, or to a person once the attempts are
  # spent. Returns true when a retry is due.
  def defer!(row, error)
    attempts = row.screen_attempts + 1
    if attempts >= MAX_ATTEMPTS
      row.update!(status: "review", screen_attempts: attempts, last_screen_error: error.to_s.first(200),
                  verdict_note: "Automated screen failed #{attempts} times; needs a person.")
      false
    else
      row.update!(status: "pending", screen_attempts: attempts, last_screen_error: error.to_s.first(200))
      true
    end
  end
end
