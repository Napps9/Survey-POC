require "test_helper"

class SweepHeldTextsJobTest < ActiveJob::TestCase
  def setup
    @org    = Organisation.create!(name: "O", slug: "sw-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "open_ended", "text" => "Why?" } ])
    @resp = @survey.responses.create!(session_token: SecureRandom.uuid, status: "started",
                                      answers: { "0" => { "type" => "open_ended", "value" => nil, "held" => { "value" => true } } })
  end

  def held!(text, status:, age: 0.seconds, **attrs)
    row = @resp.held_texts.create!(survey: @survey, organisation: @org, card_index: 0, slot: "value", text: text,
                                   text_digest: HeldText.digest_for(text), status: status, **attrs)
    row.update_columns(updated_at: age.ago, created_at: age.ago) if age.positive?
    row
  end

  test "a claim left behind by a dead job is released, one attempt spent" do
    stale = held!("stale", status: "screening", age: Moderation::SCREENING_STALE_AFTER + 1.minute)
    fresh = held!("fresh", status: "screening")

    SweepHeldTextsJob.perform_now

    assert_equal "pending", stale.reload.status
    assert_equal 1, stale.screen_attempts
    assert_equal "screening", fresh.reload.status
  end

  test "a text left pending with nothing coming for it gets its screen re-enqueued" do
    held!("forgotten", status: "pending", age: SweepHeldTextsJob::PENDING_STALE_AFTER + 1.minute)

    SweepHeldTextsJob.perform_now

    assert_enqueued_with(job: ScreenHeldTextsJob, args: [ @resp.id ])
  end

  test "a text that has only just been held is left to its scheduled screen" do
    held!("new", status: "pending")

    SweepHeldTextsJob.perform_now

    assert_no_enqueued_jobs only: ScreenHeldTextsJob
  end

  test "removed and superseded texts past their retention are blanked; the rows stay" do
    due      = held!("gone soon", status: "removed", purge_after: 1.hour.ago)
    not_yet  = held!("later", status: "superseded", purge_after: 1.day.from_now)
    kept     = held!("must be read", status: "safeguarding")

    SweepHeldTextsJob.perform_now

    assert_nil due.reload.text
    assert_nil due.purge_after
    assert_equal "removed", due.status
    assert_equal "later", not_yet.reload.text
    assert_equal "must be read", kept.reload.text
  end
end
